-- core/server.lua
-- Главный сервер ShellCraft (роль core).
-- Связывает хранилище, рецепты, машины, диспетчер и UI через parallel-корутины.

local server = {}

--- Запустить сервер.
function server.run()
    util.ok("=== ShellCraft Core запускается ===")

    -- 1. Конфиг + периферия
    local cfg = config.load()
    cfg.peripherals = config.resolve(cfg)
    util.info(string.format("Периферия: сундуков=%d, мониторов=%d, модемов=%d, машин=%d",
        #cfg.peripherals.storage, #cfg.peripherals.monitors,
        #cfg.peripherals.modems, #cfg.peripherals.machines))

    -- 2. Rednet
    if not net.open() then
        util.err("Нет модема! Поставьте проводной или беспроводной модем.")
        return
    end

    -- 3. Подсистемы
    local st = storage.new(cfg.peripherals)
    st:scan()
    util.info("Хранилище отсканировано: " .. #st:items() .. " типов предметов")

    local rec = recipes.new(cfg.recipes_file)
    util.info("Загружено рецептов: " .. #(rec:all()))

    local mach = machines.new(cfg.peripherals, st)

    local disp = dispatcher.new(st)
    disp.machines = mach
    disp.recipes = rec

    -- 4. Связь событий -> UI + лог + прогресс
    local uiInstance = nil
    local function onEvent(etype, payload)
        local msg = etype
        if payload then
            if payload.recipe then msg = msg .. " " .. lang.display(payload.recipe)
            elseif payload.id then msg = msg .. " " .. lang.display(payload.id)
            elseif payload.error then msg = msg .. " " .. tostring(payload.error) end
            if payload.count then msg = msg .. " x" .. payload.count end
        end
        util.info("[система] " .. msg, true)
        if uiInstance then
            uiInstance:addLog(msg)
            if etype == "task_done" then
                uiInstance:taskDone()
            elseif etype == "task_failed" then
                uiInstance:taskFailed()
            end
        end
    end
    disp:setEventHandler(onEvent)
    mach:setEventHandler(onEvent)

    -- 5. UI (если есть монитор)
    local monitor = nil
    if #cfg.peripherals.monitors > 0 then
        monitor = peripheral.wrap(cfg.peripherals.monitors[1])
        pcall(monitor.setTextScale, 0.5)
    end
    uiInstance = ui.new(monitor, {
        storage = st, recipes = rec, dispatcher = disp,
        machines = mach, lang = names,
    })
    uiInstance:addLog("ShellCraft Core запущен")

    -- 5b. Собираем кеш отображаемых имён из хранилища (один раз)
    st:collectNames(names)
    names.saveCache()
    util.info("Кеш имён: " .. #util.keys(names.cache) .. " предметов")

    -- 6. Поиск воркеров при старте
    local found = net.discoverWorkers(3)
    for wid, info in pairs(found) do
        disp:addWorker(wid, info)
        uiInstance:addLog("Найден воркер #" .. wid)
    end
    if next(found) == nil then
        uiInstance:addLog("Воркеры не найдены - включите черепах-воркеров")
    end

    -- 7. Корутины
    local function netListener()
        while true do
            local senderId, msg = net.receive(nil)
            if senderId and msg then
                disp:handleMessage(senderId, msg)
            end
        end
    end

    local function schedulerLoop()
        while true do
            disp:tick()
            disp:checkTimeouts((cfg.heartbeat_interval or 10) * 6)
            os.sleep(0.5)
        end
    end

    local function storageScanLoop()
        while true do
            st:scan()
            mach:collectReady()
            -- Периодически пополняем кеш имён и сбрасываем на диск
            st:collectNames(names)
            names.saveCache()
            -- Периодический rediscovery воркеров
            os.sleep(2)
        end
    end

    local function discoveryLoop()
        while true do
            os.sleep(cfg.heartbeat_interval or 10)
            local found2 = net.discoverWorkers(2)
            for wid, info in pairs(found2) do
                if not disp.workers[wid] then
                    disp:addWorker(wid, info)
                    uiInstance:addLog("Подключился воркер #" .. wid)
                end
            end
        end
    end

    local function uiLoop()
        if not monitor then
            -- Без монитора — тихий режим, только логи в shellcraft.log
            while true do os.sleep(1) end
            return
        end
        local timer = os.startTimer(0.5)
        while true do
            uiInstance:render()
            local ev, p1, p2, p3 = os.pullEvent()
            if ev == "monitor_touch" then
                uiInstance:handleTouch(p1, p2, p3)
            elseif ev == "key" then
                uiInstance:handleKey(p1)
            elseif ev == "char" then
                uiInstance:handleChar(p1)
            elseif ev == "timer" and p1 == timer then
                timer = os.startTimer(0.5)
            elseif ev == "shellcraft_quit" then
                util.info("Завершение по запросу пользователя")
                break
            end
        end
    end

    -- Запускаем всё параллельно
    util.ok("Запуск корутин сервера...")
    parallel.waitForAny(
        netListener,
        schedulerLoop,
        storageScanLoop,
        discoveryLoop,
        uiLoop
    )
    util.warn("Сервер остановлен")
end

return server
