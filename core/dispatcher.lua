-- core/dispatcher.lua
-- Раздача задач крафта воркерам-черепахам через rednet.
-- Очередь задач, учёт занятых/свободных воркеров, повтор при падении.
--
-- Перемещение предметов: Core pushItems'ает ингредиенты ПРЯМО в инвентарь черепахи
-- (по проводному модему, имя = "turtle_<id>"), а после крафта pullItems'ает результат
-- обратно. Воркеру не нужны буферные сундуки — только wired+wireless модемы.

local dispatcher = {}
dispatcher.__index = dispatcher

local taskSeq = 0
local function newTaskId()
    taskSeq = taskSeq + 1
    return "task_" .. os.getComputerID() .. "_" .. taskSeq .. "_" .. math.floor(os.clock() * 1000)
end

--- Создать диспетчер.
-- @param storage объект storage
-- @param machines объект machines (опц., для машинных рецептов)
function dispatcher.new(storage, machines, fluids)
    local self = setmetatable({}, dispatcher)
    self.storage = storage
    self.machines = machines
    self.fluids = fluids
    self.workers = {}     -- [id] = { info, state, current_task, last_seen, task_started_at, task_deadline, turtle_name }
    self.tasks = {}       -- [task_id] = task
    self.queue = {}       -- массив task_id
    self.maxAttempts = 3
    self.task_timeout = 120  -- fallback per-task deadline in seconds (configurable)
    self.heartbeat_grace = 15  -- seconds to ignore stale busy=false heartbeats after dispatch
    self.onEvent = nil
    return self
end

function dispatcher:setEventHandler(fn)
    self.onEvent = fn
end

local function emit(self, etype, payload)
    if self.onEvent then self.onEvent(etype, payload) end
end

--- Найти сетевое имя черепахи по её id.
-- Перебирает peripheral.getNames(), ищет turtle/computer с matching getID().
function dispatcher:findTurtleName(workerId)
    for _, name in ipairs(peripheral.getNames()) do
        local ptype = peripheral.getType(name)
        if ptype == "turtle" or ptype == "computer" then
            local ok, id = pcall(peripheral.call, name, "getID")
            if ok and id == workerId then
                return name
            end
        end
    end
    return nil
end

--- Сетевое имя воркера (с кэшем).
function dispatcher:workerName(workerId)
    local w = self.workers[workerId]
    if not w then return nil end
    if w.turtle_name then return w.turtle_name end
    local name = self:findTurtleName(workerId)
    w.turtle_name = name
    return name
end

--- Зарегистрировать воркера.
function dispatcher:addWorker(id, info)
    if not self.workers[id] then
        self.workers[id] = { info = info or {}, state = "free", current_task = nil, last_seen = os.clock(), turtle_name = nil }
        emit(self, "worker_join", { id = id, info = info })
    else
        self.workers[id].info = info or self.workers[id].info
        self.workers[id].last_seen = os.clock()
    end
end

function dispatcher:removeWorker(id)
    if self.workers[id] then
        if self.workers[id].current_task then
            self:requeue(self.workers[id].current_task)
        end
        self.workers[id] = nil
        emit(self, "worker_leave", { id = id })
    end
end

function dispatcher:workerList()
    local arr = {}
    for id, w in pairs(self.workers) do
        table.insert(arr, { id = id, state = w.state, info = w.info, current = w.current_task and w.current_task.id or nil })
    end
    table.sort(arr, function(a, b) return a.id < b.id end)
    return arr
end

function dispatcher:freeCount()
    local n = 0
    for _, w in pairs(self.workers) do
        if w.state == "free" then n = n + 1 end
    end
    return n
end

--- Полное число зарегистрированных воркеров (для оценки параллельности).
function dispatcher:workerCount()
    local n = 0
    for _ in pairs(self.workers) do n = n + 1 end
    return n
end

function dispatcher:findFree()
    for id, w in pairs(self.workers) do
        if w.state == "free" then return id, w end
    end
    return nil
end

--- Поставить задачу в очередь.
function dispatcher:queueTask(recipe, count, stepInfo)
    local task = {
        id = newTaskId(),
        recipe = recipe,
        count = count,
        status = "queued",
        attempts = 0,
        step = stepInfo,
        progress = 0,
        result = nil,
    }
    self.tasks[task.id] = task
    table.insert(self.queue, task.id)
    emit(self, "task_queued", { id = task.id, recipe = recipe.id, count = count })
    return task.id
end

function dispatcher:requeue(task, reason)
    task.status = "queued"
    task.worker_id = nil
    table.insert(self.queue, task.id)
    emit(self, "task_requeued", { id = task.id, reason = reason or "unknown" })
end

--- Отменить активную задачу.
-- Если задача выполняется на воркере, шлёт net.MSG.CRAFT_CANCEL.
-- Помечает задачу как failed и отменяет зависимые задачи.
function dispatcher:cancelTask(taskId, reason)
    reason = reason or "Cancelled by user"
    local task = self.tasks[taskId]
    if not task then
        return false, "Task not found"
    end
    
    if task.status == "done" or task.status == "failed" then
        return false, "Task already finished"
    end
    
    -- Если назначена воркеру, шлём отмену и освобождаем его
    if task.worker_id then
        if task.worker_id ~= "machine" then
            local w = self.workers[task.worker_id]
            if w and w.current_task and w.current_task.id == taskId then
                pcall(function()
                    net.send(task.worker_id, net.MSG.CRAFT_CANCEL, { task_id = taskId })
                end)
                self:collectResult(task.worker_id)
                w.state = "free"
                w.current_task = nil
                w.task_started_at = nil
                w.task_deadline = nil
            end
        end
    end
    
    -- Удаляем из очереди
    for i, qid in ipairs(self.queue) do
        if qid == taskId then
            table.remove(self.queue, i)
            break
        end
    end
    
    task.status = "failed"
    task.result = reason
    emit(self, "task_failed", { id = taskId, error = reason })
    self:failDependents(taskId, reason)
    
    return true
end

--- Подготовить ингредиенты: extract из хранилища ПРЯМО в инвентарь черепахи.
function dispatcher:prepareIngredients(workerId, task)
    local turtleName = self:workerName(workerId)
    if not turtleName then
        return false, "Worker #" .. tostring(workerId) .. " not found on the wired network"
    end
    local p = peripheral.wrap(turtleName)
    if not p then
        return false, "Turtle #"..tostring(workerId).." is not reachable. Connect the turtle to a WIRED modem and ENABLE it (right-click the modem, it must glow red)."
    end
    -- Очистить инвентарь черепахи от старых предметов
    self:collectResult(workerId)
    local ings = recipes.ingredientsFor(task.recipe, task.count)
    for _, ing in ipairs(ings) do
        -- Кладём без указания слота — pushItems сам распределит
        local moved = self.storage:extract(ing.id, ing.count, turtleName, nil)
        util.info(string.format("Ingredient: moved %d/%d %s -> %s", moved, ing.count, lang.localize(ing.id), turtleName))
        if moved < ing.count then
            -- Не хватило — откат (вернуть всё из черепахи в хранилище)
            self:collectResult(workerId)
            local errMsg = string.format("Missing %d %s (moved %d/%d -> %s)",
                ing.count - moved, lang.localize(ing.id), moved, ing.count, turtleName)
            return false, errMsg
        end
    end
    return true
end

--- Забрать ВСЕ предметы из инвентаря черепахи в хранилище (результат + остатки).
function dispatcher:collectResult(workerId)
    local turtleName = self:workerName(workerId)
    if not turtleName then return 0 end
    local total = 0
    for slot = 1, 16 do
        total = total + self.storage:deposit(turtleName, slot, nil)
    end
    return total
end

function dispatcher:isTaskReady(task)
    if not task.dependencies or #task.dependencies == 0 then
        return true
    end
    for _, depId in ipairs(task.dependencies) do
        local depTask = self.tasks[depId]
        if not depTask or depTask.status ~= "done" then
            return false
        end
    end
    return true
end

function dispatcher:failDependents(failedTaskId, reason)
    for _, task in pairs(self.tasks) do
        if task.status == "queued" and task.dependencies then
            for _, depId in ipairs(task.dependencies) do
                if depId == failedTaskId then
                    task.status = "failed"
                    task.result = "Dependency task " .. failedTaskId .. " failed: " .. tostring(reason)
                    -- Remove from queue
                    for i, qid in ipairs(self.queue) do
                        if qid == task.id then
                            table.remove(self.queue, i)
                            break
                        end
                    end
                    emit(self, "task_failed", { id = task.id, error = task.result })
                    self:failDependents(task.id, reason)
                    break
                end
            end
        end
    end
end

--- Один тик планировщика.
function dispatcher:tick()
    if #self.queue == 0 then return end

    -- 1. Обработать ready-задачи типа "machine"/"station" (без участия воркеров)
    local i = 1
    while i <= #self.queue do
        local tid = self.queue[i]
        local task = self.tasks[tid]
        if task and task.status == "queued" and self:isTaskReady(task) and (task.recipe.type == "machine" or task.recipe.type == "station") then
            -- Avoid double craft: if requeued task's output is already in storage, skip
            local skip = false
            if task.attempts > 0 and task.recipe and task.recipe.id then
                local have = self.storage:count(task.recipe.id)
                if have >= task.count then
                    util.info("Task " .. task.id .. " already fulfilled (have " .. have .. "), marking done")
                    task.status = "done"
                    task.result = { success = true, count = task.count, skipped = true }
                    emit(self, "task_done", { id = task.id, recipe = task.recipe.id, count = task.count })
                    table.remove(self.queue, i)
                    skip = true
                end
            end

            if not skip then
                if not self.machines then
                    task.status = "failed"
                    task.result = "machine module not connected"
                    emit(self, "task_failed", { id = task.id, error = task.result })
                    self:failDependents(task.id, task.result)
                    table.remove(self.queue, i)
                else
                    local jobId, err = self.machines:submit(task.recipe, task.count, function(success, res, elapsed, cycles)
                        if success then
                            -- Обновляем avgTime рецепта (время на 1 цикл машины)
                            if self.recipes and elapsed and cycles and cycles > 0 then
                                self.recipes:updateTiming(task.recipe.id, elapsed / cycles)
                            end
                            task.status = "done"
                            task.result = { success = true, count = res }
                            emit(self, "task_done", { id = task.id, recipe = task.recipe.id, count = res })
                        else
                            task.status = "failed"
                            task.result = { success = false, error = res }
                            emit(self, "task_failed", { id = task.id, error = tostring(res) })
                            self:failDependents(task.id, tostring(res))
                        end
                    end)
                    if jobId then
                        task.status = "running"
                        task.worker_id = "machine"
                        emit(self, "task_started", { id = task.id, worker = "machine", recipe = task.recipe.id, count = task.count })
                        table.remove(self.queue, i)
                    else
                        -- Если нет свободной машины, оставляем в очереди (не удаляем), пробуем в следующий раз
                        i = i + 1
                    end
                end
            end
        else
            i = i + 1
        end
    end

    -- 2. Обработать крафтовые задачи черепахой (только shaped/shapeless)
    local workerId = self:findFree()
    if not workerId then return end

    local readyIdx = nil
    local task = nil
    for j, tid in ipairs(self.queue) do
        local t = self.tasks[tid]
        if t and t.status == "queued" and self:isTaskReady(t) and (t.recipe.type == "shaped" or t.recipe.type == "shapeless") then
            readyIdx = j
            task = t
            break
        end
    end
    if not task then return end

    table.remove(self.queue, readyIdx)

    -- Avoid double craft: if requeued task's output is already in storage, skip
    if task.attempts > 0 and task.recipe and task.recipe.id then
        local have = self.storage:count(task.recipe.id)
        if have >= task.count then
            util.info("Task " .. task.id .. " already fulfilled (have " .. have .. "), marking done")
            task.status = "done"
            task.result = { success = true, count = task.count, skipped = true }
            emit(self, "task_done", { id = task.id, recipe = task.recipe.id, count = task.count })
            return
        end
    end

    -- Обычный крафт черепахой
    local ok, err = self:prepareIngredients(workerId, task)
    if not ok then
        task.attempts = task.attempts + 1
        if task.attempts >= self.maxAttempts then
            task.status = "failed"
            task.result = err
            emit(self, "task_failed", { id = task.id, error = err })
            self:failDependents(task.id, err)
        else
            table.insert(self.queue, task.id)
            emit(self, "task_retry", { id = task.id, error = err })
        end
        return
    end
    local w = self.workers[workerId]
    w.state = "busy"
    w.current_task = task
    w.task_started_at = os.clock()  -- per-task deadline start (heartbeat does NOT reset this)
    -- Dynamic deadline: based on avgTime if available, otherwise fallback to self.task_timeout
    local crafts = math.ceil(task.count / (task.recipe.output or 1))
    local avgTime = task.recipe.avgTime or 5
    w.task_deadline = math.max(60, avgTime * crafts * 3)
    task.status = "running"
    task.worker_id = workerId
    task.attempts = task.attempts + 1
    net.send(workerId, net.MSG.CRAFT_REQUEST, {
        recipe = task.recipe,
        count = task.count,
        task_id = task.id,
    })
    emit(self, "task_started", { id = task.id, worker = workerId, recipe = task.recipe.id, count = task.count })
end


--- Обработать входящее сообщение (вызывается сервером).
function dispatcher:handleMessage(senderId, msg)
    if not msg or not msg.type then return end
    if msg.type == net.MSG.WORKER_HELLO then
        self:addWorker(senderId, msg.payload)
        -- Send a discover back only if the worker does not have our Core ID registered to prevent recursive loop
        local p = msg.payload or {}
        if p.core ~= os.getComputerID() then
            net.send(senderId, net.MSG.DISCOVER, { core = os.getComputerID() })
        end
    elseif msg.type == net.MSG.WORKER_BYE then
        self:removeWorker(senderId)
    elseif msg.type == net.MSG.STATUS then
        local p = msg.payload or {}
        local w = self.workers[senderId]
        if w and w.current_task and w.current_task.id == p.task_id then
            w.current_task.progress = p.progress or w.current_task.progress
            emit(self, "task_progress", { id = p.task_id, progress = p.progress })
        end
    elseif msg.type == net.MSG.RESULT then
        local p = msg.payload or {}
        local w = self.workers[senderId]
        -- Normal path: worker's current_task matches the result
        local task = nil
        if w and w.current_task and w.current_task.id == p.task_id then
            task = w.current_task
        elseif p.task_id and self.tasks[p.task_id] then
            -- Orphaned RESULT recovery: current_task was nil'd (e.g. by stale heartbeat requeue)
            -- but the task still exists — accept the result to avoid wasted work
            local orphan = self.tasks[p.task_id]
            if orphan.status == "running" or orphan.status == "queued" then
                util.info("Recovering orphaned RESULT for task " .. p.task_id .. " from worker #" .. tostring(senderId))
                task = orphan
                -- Remove from queue if it was requeued
                for i, qid in ipairs(self.queue) do
                    if qid == p.task_id then
                        table.remove(self.queue, i)
                        break
                    end
                end
            end
        end
        if task then
            if p.success then
                self:collectResult(senderId)
                task.status = "done"
                task.result = p
                -- Обновляем avgTime рецепта (время на 1 крафт черепахи)
                if self.recipes and p.elapsed and p.crafts and p.crafts > 0 then
                    self.recipes:updateTiming(task.recipe.id, p.elapsed / p.crafts)
                end
                emit(self, "task_done", { id = task.id, recipe = task.recipe.id, count = p.count })
            else
                -- При ошибке тоже забираем остатки
                self:collectResult(senderId)
                task.status = "failed"
                task.result = p
                local err = p.error or "worker returned error"
                emit(self, "task_failed", { id = task.id, error = err })
                self:failDependents(task.id, err)
            end
            -- Free the worker (only if this worker was assigned to the task)
            if w then
                w.state = "free"
                w.current_task = nil
                w.task_started_at = nil
                w.task_deadline = nil
            end
        end
    elseif msg.type == net.MSG.HEARTBEAT then
        local w = self.workers[senderId]
        if w then
            w.last_seen = os.clock()
            local p = msg.payload or {}
            if p.busy == false and w.state == "busy" then
                local now = os.clock()
                local taskAge = w.task_started_at and (now - w.task_started_at) or 999
                local taskId = w.current_task and w.current_task.id
                local reportedId = p.current_task_id
                -- If worker reports the SAME task_id as assigned, it's just a stale busy flag — ignore
                if reportedId and reportedId == taskId then
                    -- Worker is working on our task but crafting flag not yet set; ignore
                elseif taskAge < self.heartbeat_grace then
                    -- Within grace period after dispatch — stale heartbeat, ignore
                    util.info("Stale heartbeat from #" .. tostring(senderId) .. " (task assigned " .. math.floor(taskAge) .. "s ago < grace " .. self.heartbeat_grace .. "s), ignoring")
                else
                    -- Grace expired AND worker truly reports idle for a different/no task — safe to reset
                    util.warn("Worker #" .. tostring(senderId) .. " confirmed idle after grace (" .. math.floor(taskAge) .. "s), requeuing task")
                    if w.current_task then
                        self:requeue(w.current_task, "stale_heartbeat")
                    end
                    w.state = "free"
                    w.current_task = nil
                    w.task_started_at = nil
                    w.task_deadline = nil
                end
            end
        end
    end
end

--- Проверить зависших воркеров.
-- Два независимых таймаута:
--   1) Worker liveness: если heartbeat не приходил дольше `timeout` — воркер мёртв
--   2) Per-task deadline: динамический (w.task_deadline) или self.task_timeout как fallback
-- Heartbeat обновляет ТОЛЬКО last_seen, НЕ продлевает task_started_at.
function dispatcher:checkTimeouts(timeout)
    timeout = timeout or 60
    local now = os.clock()
    for id, w in pairs(self.workers) do
        if w.state == "busy" then
            -- 1) Worker liveness: heartbeat не приходил слишком долго
            if (now - (w.last_seen or now)) > timeout then
                util.warn("Worker #" .. id .. " not responding (no heartbeat for " .. timeout .. "s), returning task to queue")
                if w.current_task then
                    emit(self, "task_timeout", { id = w.current_task.id, worker = id, reason = "worker_dead" })
                    self:requeue(w.current_task, "worker_dead")
                end
                w.state = "free"
                w.current_task = nil
                w.task_started_at = nil
                w.task_deadline = nil
            -- 2) Per-task deadline: dynamic or fallback
            elseif w.task_started_at then
                local deadline = w.task_deadline or self.task_timeout
                local elapsed = now - w.task_started_at
                if elapsed > deadline then
                    local elapsedInt = math.floor(elapsed)
                    util.warn("Task on worker #" .. id .. " exceeded deadline (" .. elapsedInt .. "s > " .. math.floor(deadline) .. "s), returning to queue")
                    if w.current_task then
                        emit(self, "task_timeout", { id = w.current_task.id, worker = id, reason = "task_deadline", elapsed = elapsedInt })
                        self:requeue(w.current_task, "task_deadline")
                    end
                    w.state = "free"
                    w.current_task = nil
                    w.task_started_at = nil
                    w.task_deadline = nil
                end
            end
        end
    end
end

function dispatcher:activeTasks()
    local arr = {}
    for _, task in pairs(self.tasks) do
        if task.status == "running" or task.status == "queued" then
            table.insert(arr, task)
        end
    end
    return arr
end

function dispatcher:allTasks()
    local arr = {}
    for _, task in pairs(self.tasks) do
        table.insert(arr, task)
    end
    table.sort(arr, function(a, b) return a.id < b.id end)
    return arr
end

local SLOT = 64
local MAX_OUT_ITEMS = 8 * SLOT   -- не больше 8 слотов под выход
local MAX_IN_ITEMS  = 4 * SLOT   -- не больше 4 слотов под вход

function dispatcher:batchCrafts(recipe)
    local out = recipe.output or 1
    local inPer = recipes.itemsPerCraft(recipe)
    local byOut = math.floor(MAX_OUT_ITEMS / math.max(1, out))
    local byIn  = inPer > 0 and math.floor(MAX_IN_ITEMS / inPer) or byOut
    return math.max(1, math.min(byOut, byIn))   -- макс. крафтов в одной задаче
end

--- Запрос крафта: строит план, ставит шаги в очередь.
-- @param id ID предмета
-- @param count сколько
-- @param recipes объект recipes
-- @return task_ids список, либо nil + сообщение об ошибке
function dispatcher:requestCraft(id, count, recipes)
    if not recipes:has(id) then
        return nil, "No recipe for " .. lang.localize(id)
    end
    local tree = planner.buildTree(id, count, recipes, self.storage, self.fluids)
    local can, avail = planner.canCraft(tree, self.storage, self.fluids)
    if not can then
        local missing = {}
        for mid, info in pairs(avail.items) do
            if info.missing > 0 then
                table.insert(missing, lang.localize(mid) .. " (need " .. info.needed .. ", have " .. info.available .. ", missing " .. info.missing .. ")")
            end
        end
        for mfluid, info in pairs(avail.fluids) do
            if info.missing > 0 then
                table.insert(missing, lang.localize("fluid:" .. mfluid) .. " (need " .. info.needed .. "mB, have " .. info.available .. "mB, missing " .. info.missing .. "mB)")
            end
        end
        return nil, "Missing resources: " .. table.concat(missing, "; ")
    end

    local taskIds = {}
    local nodeToTaskIds = {}

    local function createTasks(node)
        if not node or not node.has_recipe then return nil end
        if nodeToTaskIds[node] then return nodeToTaskIds[node] end

        local deps = {}
        for _, child in ipairs(node.children) do
            local depIds = createTasks(child)
            if depIds then
                for _, depId in ipairs(depIds) do
                    table.insert(deps, depId)
                end
            end
        end

        local batchItems = node.count
        if node.recipe.type == "shaped" or node.recipe.type == "shapeless" then
            local out = node.recipe.output or 1
            local batch = self:batchCrafts(node.recipe)
            batchItems = batch * out
        end

        local tids = {}
        local remaining = node.count
        while remaining > 0 do
            local countPart = math.min(remaining, batchItems)
            remaining = remaining - countPart

            local tid = newTaskId()
            local task = {
                id = tid,
                recipe = node.recipe,
                count = countPart,
                status = "queued",
                attempts = 0,
                progress = 0,
                result = nil,
                dependencies = deps,
            }
            self.tasks[tid] = task
            table.insert(tids, tid)
            table.insert(taskIds, tid)
            table.insert(self.queue, tid)
            emit(self, "task_queued", { id = tid, recipe = node.recipe.id, count = countPart })
        end

        nodeToTaskIds[node] = tids
        return tids
    end

    createTasks(tree)

    if #taskIds == 0 then
        return {}, "Already in storage"
    end

    emit(self, "craft_planned", { id = id, count = count, steps = #taskIds })
    return taskIds, "Planned steps: " .. #taskIds
end

return dispatcher
