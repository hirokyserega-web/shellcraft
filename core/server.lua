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

    local fl = fluids.new(cfg.peripherals, st)
    fl:scan()
    util.info("Fluids scanned: " .. #fl:fluids() .. " fluid types")

    local rec = recipes.new(cfg.recipes_file)
    util.info("Loaded recipes: " .. #(rec:all()))

    local mach = machines.new(cfg.peripherals, st, fl, cfg)

    local disp = dispatcher.new(st, mach, fl)
    disp.recipes = rec
    if cfg.task_timeout then disp.task_timeout = cfg.task_timeout end
    if cfg.heartbeat_grace then disp.heartbeat_grace = cfg.heartbeat_grace end

    -- 4. Связь событий -> UI + лог + прогресс
    local uiInstance = nil
    local activeGroups = {}

    local function getRecipeStats(recipeId)
        local total = 0
        local activeCount = 0
        local runningCount = 0
        local queuedCount = 0
        local failedCount = 0
        local doneCount = 0
        for _, t in pairs(disp.tasks) do
            if t.recipe.id == recipeId then
                total = total + t.count
                if t.status == "running" or t.status == "queued" then
                    activeCount = activeCount + t.count
                    if t.status == "running" then
                        runningCount = runningCount + t.count
                    else
                        queuedCount = queuedCount + t.count
                    end
                elseif t.status == "done" then
                    doneCount = doneCount + t.count
                elseif t.status == "failed" then
                    failedCount = failedCount + t.count
                end
            end
        end
        return {
            total = total,
            active = activeCount,
            running = runningCount,
            queued = queuedCount,
            done = doneCount,
            failed = failedCount
        }
    end

    local function onEvent(etype, payload)
        if etype == "task_queued" or etype == "task_requeued" then
            return
        end

        local rid = payload and payload.recipe
        local msg = etype
        local skipLog = false

        if rid then
            local stats = getRecipeStats(rid)

            if etype == "task_started" then
                if not activeGroups[rid] then
                    activeGroups[rid] = true
                    msg = "task_started " .. lang.display(rid) .. " x" .. stats.active
                    if payload.worker and payload.worker ~= "machine" then
                        msg = msg .. " [turtle #" .. tostring(payload.worker) .. "]"
                    end
                else
                    skipLog = true
                end

            elseif etype == "task_done" then
                local activeOther = 0
                for _, t in pairs(disp.tasks) do
                    if t.recipe.id == rid and (t.status == "running" or t.status == "queued") and t.id ~= payload.id then
                        activeOther = activeOther + t.count
                    end
                end

                if activeOther == 0 then
                    msg = "task_done " .. lang.display(rid) .. " x" .. stats.total
                    activeGroups[rid] = nil
                    if payload then
                        payload = { recipe = payload.recipe, count = stats.total, worker = payload.worker }
                    end
                else
                    skipLog = true
                end

            elseif etype == "task_failed" or etype == "task_timeout" then
                activeGroups[rid] = nil
            end
        end

        if skipLog then return end

        if msg == etype and payload then
            if payload.recipe then msg = msg .. " " .. lang.display(payload.recipe)
            elseif payload.id then msg = msg .. " " .. lang.display(payload.id)
            elseif payload.error then msg = msg .. " " .. tostring(payload.error) end
            if payload.error and not msg:find(tostring(payload.error), 1, true) then msg = msg .. " " .. tostring(payload.error) end
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
                local errStr = payload and tostring(payload.error) or ""
                if errStr:find("No matching recipe", 1, true) or errStr:find("rejected", 1, true) then
                    local taskRec = disp.tasks[payload.id] and disp.tasks[payload.id].recipe
                    local recId = taskRec and taskRec.id or "?"
                    uiInstance:addLog("Hint: Recipe " .. recId .. " may be a MACHINE/mod recipe - re-learn it as Machine, not Crafting.")
                end
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
        storage = st, fluids = fl, recipes = rec, dispatcher = disp,
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

    -- 6b. Helper to dynamically refresh peripherals
    local function refreshPeripherals()
        local currentCfg = config.load()
        local resolved = config.resolve(currentCfg)
        
        st.names = resolved.storage or {}
        st:scan()
        
        fl:resolvePool(resolved)
        fl:scan()
        
        mach.configData = currentCfg
        mach:refreshStations(resolved)
        
        if uiInstance then
            uiInstance.configData = currentCfg
            uiInstance:buildTabs()
            uiInstance.dirty = true
        end
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

    local function peripheralLoop()
        while true do
            local ev, name = os.pullEvent()
            if ev == "peripheral" or ev == "peripheral_detach" then
                pcall(refreshPeripherals)
                if uiInstance then
                    uiInstance:addLog("Peripherals updated: " .. tostring(name))
                end
            end
        end
    end

    local function schedulerLoop()
        local timeoutThreshold = (cfg.heartbeat_interval or 10) * 6
        local iter = 0
        local timer = os.startTimer(0.25)
        while true do
            local ok, err = pcall(function()
                disp:tick()
                iter = iter + 1
                -- checkTimeouts не на каждый тик, чтобы не гонять таймауты слишком часто
                if iter % 30 == 0 then
                    disp:checkTimeouts(timeoutThreshold)
                end
            end)
            if not ok then
                util.err("Scheduler loop error: " .. tostring(err))
            end
            -- Событийная побудка: tick() срабатывает сразу как освободилась черепаха,
            -- не дожидаясь следующего интервала. Запасной таймер ~0.25c как fallback.
            local ev, p1 = os.pullEventRaw()
            if ev == "timer" and p1 == timer then
                timer = os.startTimer(0.25)
            elseif ev == "shellcraft_dispatch" then
                -- немедленная дораздача
            elseif ev == "terminate" then
                error("Terminated", 0)
            end
        end
    end

    local function machineLoop()
        while true do
            local ok, err = pcall(function()
                mach:tick()
            end)
            if not ok then
                util.err("Machine loop error: " .. tostring(err))
            end
            os.sleep(0.25)
        end
    end

    local function storageScanLoop()
        local lastSaveTime = os.clock()
        local lastCfgLoad  = os.clock() - 31  -- force immediate load on first tick
        local cachedImportChest = nil
        local storageFullLogged = false
        while true do
            local ok, err = pcall(function()
                st:scan()
                fl:scan()
                mach:collectReady()
                -- Периодически пополняем кеш имён и сбрасываем на диск
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

                -- Перечитываем конфиг раз в 30с чтобы подхватить изменения из Settings
                if (now - lastCfgLoad) > 30 then
                    local freshCfg = config.load()
                    cachedImportChest = (freshCfg.default_import ~= nil and freshCfg.default_import ~= "")
                        and freshCfg.default_import or nil
                    lastCfgLoad = now
                end

                -- Авто-импорт: передаём имя сундука напрямую, не читаем конфиг внутри importFrom
                if cachedImportChest then
                    local count, impErr = st:importFrom(cachedImportChest, nil)
                    if impErr == "storage_full" then
                        if not storageFullLogged then
                            util.warn("Storage is full - auto-import paused")
                            storageFullLogged = true
                        end
                    elseif count and count > 0 then
                        if storageFullLogged then
                            util.info("Storage space available - auto-import resumed")
                            storageFullLogged = false
                        end
                    end
                end
            end)
            if not ok then
                util.err("Storage scan loop error: " .. tostring(err))
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
        machineLoop,
        storageScanLoop,
        discoveryLoop,
        peripheralLoop,
        uiLoop
    )
    util.warn("Server stopped")
end

return server
