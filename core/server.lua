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
    if cfg.task_timeout then disp.task_timeout = cfg.task_timeout end
    if cfg.heartbeat_grace then disp.heartbeat_grace = cfg.heartbeat_grace end

    -- 4. Связь событий -> UI + лог + прогресс
    local uiInstance = nil
    local function onEvent(etype, payload)
        local msg = etype
        if payload then
            if payload.recipe then msg = msg .. " " .. lang.display(payload.recipe)
            elseif payload.id then msg = msg .. " " .. lang.display(payload.id)
            elseif payload.error then msg = msg .. " " .. tostring(payload.error) end
            if payload.count then msg = msg .. " x" .. payload.count end
            if payload.worker and payload.worker ~= "machine" then
                msg = msg .. " [turtle #" .. tostring(payload.worker) .. "]"
            end
        end
        util.info("[event] " .. msg, true)
        if uiInstance then
            uiInstance:addLog(msg)
            if etype == "task_started" then
                local name = payload and payload.recipe and lang.display(payload.recipe) or "?"
                local wStr = payload and payload.worker or "?"
                uiInstance:taskStarted(name, wStr)
            elseif etype == "task_done" then
                local name = payload and payload.recipe and lang.display(payload.recipe) or "?"
                uiInstance:taskDone()
                uiInstance:showToast("Done: " .. name .. (payload and payload.count and (" x" .. payload.count) or ""), "success")
            elseif etype == "task_failed" then
                uiInstance:taskFailed(payload and payload.error)
            elseif etype == "task_timeout" then
                local reason = payload and payload.reason or "unknown"
                local wStr = payload and payload.worker or "?"
                uiInstance:taskTimedOut(reason, wStr)
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
        local lastSaveTime = os.clock()
        while true do
            st:scan()
            mach:collectReady()
            -- Периодически пополняем кеш имён и сбрасываем на диск только при новых ID или раз в 60с
            local newItems = false
            for id in pairs(st.cache) do
                if not names.cache[id] then
                    newItems = true
                    break
                end
            end
            local now = os.clock()
            if newItems or (now - lastSaveTime) > 60 then
                st:collectNames(names)
                names.saveCache()
                lastSaveTime = now
            end
            os.sleep(2)
        end
    end

    local function discoveryLoop()
        while true do
            -- Неблокирующий broadcast DISCOVER; ответы обрабатывает netListener через handleMessage
            net.broadcast(net.MSG.DISCOVER, { core = os.getComputerID() })
            os.sleep(45)
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
