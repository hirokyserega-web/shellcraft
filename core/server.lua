-- core/server.lua
-- Главный сервер ShellCraft (роль core).
-- Связывает хранилище, рецепты, машины, диспетчер и UI через parallel-корутины.

local server = {}

--- Запустить сервер.
function server.run()
    util.ok("=== ShellCraft Core starting ===")

    -- 1. Конфиг + периферия
    local cfg = config.load()
    cfg.peripherals = config.resolve(cfg)
    util.info(string.format("Peripherals: chests=%d, monitors=%d, modems=%d, machines=%d",
        #cfg.peripherals.storage, #cfg.peripherals.monitors,
        #cfg.peripherals.modems, #cfg.peripherals.machines))

    -- 2. Rednet
    if not net.open() then
        util.err("No modem! Please attach a wired or wireless modem.")
        return
    end

    -- 3. Подсистемы
    local st = storage.new(cfg.peripherals)
    st:scan()
    util.info("Storage scanned: " .. #st:items() .. " item types")

    local rec = recipes.new(cfg.recipes_file)
    util.info("Loaded recipes: " .. #(rec:all()))

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
        local scale = cfg.text_scale
        if not scale then
            pcall(monitor.setTextScale, 1.0)
            local w, h = monitor.getSize()
            if w >= 78 then
                scale = 1.5
            elseif w >= 48 then
                scale = 1.0
            else
                scale = 0.5
            end
        end
        pcall(monitor.setTextScale, scale)
    end
    uiInstance = ui.new(monitor, {
        storage = st, recipes = rec, dispatcher = disp,
        machines = mach, lang = names,
    })
    uiInstance:addLog("ShellCraft Core started")

    -- 5b. Собираем кеш отображаемых имён из хранилища (один раз)
    st:collectNames(names)
    names.saveCache()
    util.info("Name cache: " .. #util.keys(names.cache) .. " items")

    -- 6. Поиск воркеров при старте
    local found = net.discoverWorkers(3)
    for wid, info in pairs(found) do
        disp:addWorker(wid, info)
        uiInstance:addLog("Found worker #" .. wid)
    end
    if next(found) == nil then
        uiInstance:addLog("Workers not found - please enable turtle workers")
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
                    uiInstance:addLog("Worker #" .. wid .. " connected")
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
        uiInstance.dirty = true
        local timer = os.startTimer(0.5)
        while true do
            if uiInstance.dirty then
                local renderOk, renderErr = pcall(function() uiInstance:render() end)
                if not renderOk then
                    util.err("UI render crashed: " .. tostring(renderErr))
                end
                uiInstance.dirty = false
            end
            local ev, p1, p2, p3 = os.pullEvent()
            if ev == "monitor_touch" then
                -- monitor_touch: side (p1), x (p2), y (p3)
                uiInstance:handleTouch(p2, p3)
                uiInstance.dirty = true
            elseif ev == "mouse_click" then
                -- mouse_click: button (p1), x (p2), y (p3)
                uiInstance:handleTouch(p2, p3)
                uiInstance.dirty = true
            elseif ev == "key" then
                uiInstance:handleKey(p1)
                uiInstance.dirty = true
            elseif ev == "char" then
                uiInstance:handleChar(p1)
                uiInstance.dirty = true
            elseif ev == "timer" and p1 == timer then
                uiInstance.dirty = true
                timer = os.startTimer(0.5)
            elseif ev == "shellcraft_quit" then
                util.info("Exiting on user request")
                break
            end
        end
    end

    -- Запускаем всё параллельно
    util.ok("Starting server coroutines...")
    parallel.waitForAny(
        netListener,
        schedulerLoop,
        storageScanLoop,
        discoveryLoop,
        uiLoop
    )
    util.warn("Server stopped")
end

return server
