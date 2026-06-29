-- core/dispatcher.lua
-- Очередь задач, планирование, резервирование и раздача craft-задач воркерам.
--
-- Поддерживает два transport mode:
--   * buffer (default): Core кладёт ингредиенты в входной сундук воркера,
--     воркер работает только с соседними сундуками через turtle.suck/drop.
--   * wired: legacy direct pushItems/pullItems into turtle inventory.
--
-- Public API retained where practical:
--   new, setEventHandler, addWorker, removeWorker, workerList, freeCount,
--   workerCount, queueTask, requestCraft, tick, handleMessage, checkTimeouts,
--   activeTasks, allTasks, cancelTask, batchCrafts, workerName, findTurtleName.

local dispatcher = {}
dispatcher.__index = dispatcher

local function now()
    if os.epoch then return os.epoch("utc") / 1000 end
    return os.clock()
end

local function emit(self, etype, payload)
    if self.onEvent then self.onEvent(etype, payload) end
end

local seq = 0
local function newTaskId()
    seq = seq + 1
    return string.format("task_%d_%d_%d", os.getComputerID(), seq, math.floor(now() * 1000))
end

local function clone(t)
    return util.deepCopy and util.deepCopy(t) or textutils.unserialize(textutils.serialize(t))
end

local function listContains(arr, value)
    for _, v in ipairs(arr or {}) do
        if v == value then return true end
    end
    return false
end

local function removeValue(arr, value)
    for i, v in ipairs(arr or {}) do
        if v == value then table.remove(arr, i); return true end
    end
    return false
end

function dispatcher.new(storage, machines, fluids)
    local self = setmetatable({}, dispatcher)
    self.storage = storage
    self.machines = machines
    self.fluids = fluids
    self.recipes = nil
    self.workers = {}        -- [id] = worker state
    self.tasks = {}          -- [task_id] = task
    self.queue = {}          -- array of task ids
    self.task_order = 0
    self.maxAttempts = 3
    self.task_timeout = 120
    self.heartbeat_grace = 15
    self.transport_mode = (config and config.load and config.load().transfer_mode) or "buffer"
    self._rrCursor = 0
    self._persistencePath = (config and config.load and config.load().queue_file) or "queue.dat"
    self._lastSave = 0
    self._dirty = false
    self.onEvent = nil
    self._workerSeq = 0
    return self
end

function dispatcher:setEventHandler(fn)
    self.onEvent = fn
end

----------------------------------------------------------------
-- WORKER REGISTRY
----------------------------------------------------------------

function dispatcher:findTurtleName(workerId)
    for _, name in ipairs(peripheral.getNames()) do
        local ptype = (peripheral.getType(name) or ""):lower()
        if ptype == "turtle" or ptype == "computer" then
            local ok, id = pcall(peripheral.call, name, "getID")
            if ok and id == workerId then return name end
        end
    end
    return nil
end

function dispatcher:workerName(workerId)
    local w = self.workers[workerId]
    if not w then return nil end
    if w.turtle_name then return w.turtle_name end
    w.turtle_name = self:findTurtleName(workerId)
    return w.turtle_name
end

local function workerState(nowTs)
    return {
        state = "free",
        current_task = nil,
        last_seen = nowTs,
        turtle_name = nil,
        buffer = nil,
        busy = false,
        task_started_at = nil,
        task_deadline = nil,
        handshake = nil,
        current_task_id = nil,
        ready = false,
    }
end

function dispatcher:addWorker(id, info)
    local ts = now()
    if not self.workers[id] then
        self.workers[id] = workerState(ts)
        self.workers[id].info = info or {}
        emit(self, "worker_join", { id = id, info = info })
    else
        self.workers[id].info = info or self.workers[id].info
        self.workers[id].last_seen = ts
    end
    self._dirty = true
end

function dispatcher:removeWorker(id)
    local w = self.workers[id]
    if not w then return end
    if w.current_task then
        self:requeue(w.current_task, "worker_removed")
    end
    self.workers[id] = nil
    emit(self, "worker_leave", { id = id })
    self._dirty = true
end

function dispatcher:workerList()
    local arr = {}
    for id, w in pairs(self.workers) do
        arr[#arr + 1] = {
            id = id,
            state = w.state,
            info = w.info,
            current = w.current_task and w.current_task.id or nil,
            busy = w.busy,
            ready = w.ready,
            buffer = clone(w.buffer),
            last_seen = w.last_seen,
        }
    end
    table.sort(arr, function(a, b) return a.id < b.id end)
    return arr
end

function dispatcher:freeCount()
    local n = 0
    for _, w in pairs(self.workers) do
        if w.state == "free" and w.ready ~= false then n = n + 1 end
    end
    return n
end

function dispatcher:workerCount()
    local n = 0
    for _ in pairs(self.workers) do n = n + 1 end
    return n
end

function dispatcher:findFree()
    local ids = {}
    for id, w in pairs(self.workers) do
        if w.state == "free" and w.ready ~= false then ids[#ids + 1] = id end
    end
    if #ids == 0 then return nil end
    table.sort(ids)
    self._rrCursor = (self._rrCursor % #ids) + 1
    local idx = self._rrCursor
    return ids[idx], self.workers[ids[idx]]
end

----------------------------------------------------------------
-- PERSISTENCE
----------------------------------------------------------------

function dispatcher:markDirty()
    self._dirty = true
end

function dispatcher:serialize()
    local tasks = {}
    for id, task in pairs(self.tasks) do
        tasks[id] = {
            id = task.id,
            recipe = task.recipe,
            count = task.count,
            status = task.status,
            attempts = task.attempts,
            step = task.step,
            progress = task.progress,
            result = task.result,
            dependencies = task.dependencies,
            dependents = task.dependents,
            worker_id = task.worker_id,
            batch_index = task.batch_index,
            batch_total = task.batch_total,
            reservation_id = task.reservation_id,
            plan = task.plan,
            task_type = task.task_type,
            created_at = task.created_at,
            updated_at = task.updated_at,
            requested = task.requested,
            crafts = task.crafts,
            requested_root = task.requested_root,
            source_id = task.source_id,
            transfer_mode = task.transfer_mode,
            concrete_recipe = task.concrete_recipe,
            reservation_key = task.reservation_key,
            _resById = task._resById,
        }
    end
    local workers = {}
    for id, w in pairs(self.workers) do
        workers[id] = {
            info = w.info,
            state = w.state,
            current_task_id = w.current_task and w.current_task.id or nil,
            last_seen = w.last_seen,
            buffer = w.buffer,
            turtle_name = w.turtle_name,
            busy = w.busy,
            ready = w.ready,
            task_started_at = w.task_started_at,
            task_deadline = w.task_deadline,
            handshake = w.handshake,
            current_task_id_reported = w.current_task_id,
            transfer_mode = w.transfer_mode,
        }
    end
    local queue = {}
    for i, tid in ipairs(self.queue) do queue[i] = tid end
    return {
        version = 2,
        transport_mode = self.transport_mode,
        seq = seq,
        rrCursor = self._rrCursor,
        tasks = tasks,
        queue = queue,
        workers = workers,
        reservations = self.storage and self.storage:reservationSnapshot() or {},
    }
end

function dispatcher:save()
    if not self._dirty and (now() - self._lastSave) < 1 then return true end
    local data = self:serialize()
    local ok, err = util.saveData(self._persistencePath, data)
    if ok then
        self._dirty = false
        self._lastSave = now()
        return true
    end
    util.warn("Could not save queue state: " .. tostring(err))
    return false, err
end

function dispatcher:load()
    if not util.fileExists(self._persistencePath) then return false end
    local data = util.loadData(self._persistencePath, {})
    if type(data) ~= "table" then return false, "bad state" end
    if type(data.transport_mode) == "string" then self.transport_mode = data.transport_mode end
    if type(data.rrCursor) == "number" then self._rrCursor = data.rrCursor end
    if type(data.seq) == "number" then seq = data.seq end
    -- Восстанавливаем резервации из снапшота (переживают рестарт Core).
    if self.storage and type(data.reservations) == "table"
       and self.storage.restoreReservations then
        self.storage:restoreReservations(data.reservations)
    end
    if type(data.tasks) == "table" then
        self.tasks = data.tasks
    end
    -- После ребута running-задачи неизвестно в каком состоянии: воркеры ещё
    -- не пере-HELLO. Сбрасываем их в queued — tick переотправит после HELLO.
    for _, task in pairs(self.tasks) do
        if task.status == "running" then
            task.status = "queued"
            task.worker_id = nil
            task.acked = false
            task.ack_attempts = 0
            task.ack_deadline = 0
            task.sent_at = 0
        end
    end
    if type(data.queue) == "table" then
        self.queue = data.queue
    end
    -- Гарантируем, что все queued-задачи есть в очереди (на случай рассинхрона).
    for id, task in pairs(self.tasks) do
        if task.status == "queued" and not listContains(self.queue, id) then
            self.queue[#self.queue + 1] = id
        end
    end
    if type(data.workers) == "table" then
        self.workers = {}
        for id, w in pairs(data.workers) do
            local wid = tonumber(id) or id
            self.workers[wid] = workerState(now())
            for k, v in pairs(w) do self.workers[wid][k] = v end
            -- Воркер после ребута неизвестен как ready — ждём свежий HELLO.
            self.workers[wid].ready = false
            if self.workers[wid].state == "busy" then
                self.workers[wid].state = "free"
                self.workers[wid].busy = false
                self.workers[wid].current_task = nil
                self.workers[wid].current_task_id = nil
                self.workers[wid].task_started_at = nil
                self.workers[wid].task_deadline = nil
            end
        end
    end
    self._dirty = false
    return true
end

----------------------------------------------------------------
-- TASK HELPERS
----------------------------------------------------------------

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
        dependencies = {},
        dependents = {},
        worker_id = nil,
        batch_index = 1,
        batch_total = 1,
        reservation_id = nil,
        plan = nil,
        task_type = recipe and recipe.type or "craft",
        created_at = now(),
        updated_at = now(),
        requested = count,
        acked = false,
        ack_attempts = 0,
        ack_deadline = 0,
        sent_at = 0,
    }
    self.tasks[task.id] = task
    self.queue[#self.queue + 1] = task.id
    self._dirty = true
    emit(self, "task_queued", { id = task.id, recipe = recipe and recipe.id or nil, count = count })
    return task.id
end

function dispatcher:requeue(task, reason)
    if not task or task.status == "done" or task.status == "failed" then return end
    task.status = "queued"
    task.worker_id = nil
    task.updated_at = now()
    task.sent_at = 0
    task.acked = false
    task.ack_attempts = 0
    task.ack_deadline = 0
    if not listContains(self.queue, task.id) then
        self.queue[#self.queue + 1] = task.id
    end
    self._dirty = true
    emit(self, "task_requeued", { id = task.id, reason = reason or "unknown" })
end

function dispatcher:cancelTask(taskId, reason)
    reason = reason or "Cancelled by user"
    local task = self.tasks[taskId]
    if not task then return false, "Task not found" end
    if task.status == "done" or task.status == "failed" then return false, "Task already finished" end
    if task.worker_id and self.workers[task.worker_id] then
        local w = self.workers[task.worker_id]
        pcall(function()
            net.send(task.worker_id, net.MSG.CRAFT_CANCEL, { task_id = taskId, reason = reason })
        end)
        w.state = "free"
        w.current_task = nil
        w.busy = false
        w.task_started_at = nil
        w.task_deadline = nil
        w.current_task_id = nil
    end
    removeValue(self.queue, taskId)
    task.status = "failed"
    task.result = { success = false, error = reason }
    task.updated_at = now()
    -- Отпускаем резервы заказа, если весь заказ закрыт.
    self:releaseOrderIfDone(task)
    self._dirty = true
    self:save()
    emit(self, "task_failed", { id = taskId, error = reason })
    self:failDependents(taskId, reason)
    return true
end

function dispatcher:isTaskReady(task)
    if not task.dependencies or #task.dependencies == 0 then return true end
    for _, depId in ipairs(task.dependencies) do
        local depTask = self.tasks[depId]
        if not depTask or depTask.status ~= "done" then return false end
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
                    removeValue(self.queue, task.id)
                    emit(self, "task_failed", { id = task.id, error = task.result })
                    self:failDependents(task.id, reason)
                    break
                end
            end
        end
    end
end

function dispatcher:activeTasks()
    local arr = {}
    for _, task in pairs(self.tasks) do
        if task.status == "running" or task.status == "queued" then
            arr[#arr + 1] = task
        end
    end
    table.sort(arr, function(a, b) return a.id < b.id end)
    return arr
end

function dispatcher:allTasks()
    local arr = {}
    for _, task in pairs(self.tasks) do arr[#arr + 1] = task end
    table.sort(arr, function(a, b) return a.id < b.id end)
    return arr
end

function dispatcher:batchCrafts(recipe)
    local out = recipe and recipe.output or 1
    local inPer = recipes.itemsPerCraft(recipe)
    local byOut = math.floor(64 / math.max(1, out))
    local byIn = inPer > 0 and math.floor(64 / math.max(1, inPer)) or byOut
    return math.max(1, math.min(byOut, byIn))
end

----------------------------------------------------------------
-- BUFFER / WIREDED TRANSFER HELPERS
----------------------------------------------------------------

local function turtleHasCraftingTable()
    return type(turtle) == "table" and type(turtle.craft) == "function"
end

local function turtleInventoryFullCheck()
    for s = 1, 16 do
        if turtle.getItemCount(s) == 0 then return false end
    end
    return true
end

local function clearTurtle()
    local moved = 0
    for s = 1, 16 do
        if turtle.getItemCount(s) > 0 then
            turtle.select(s)
            if turtle.drop() or turtle.dropUp() or turtle.dropDown() then
                moved = moved + 1
            end
        end
    end
    return moved
end

function dispatcher:resolveWorkerBuffers(workerId)
    local cfg = config.load()
    local workerCfg = type(cfg.workers) == "table" and cfg.workers[workerId] or nil
    if type(workerCfg) == "table" and workerCfg.input and workerCfg.output then
        return workerCfg.input, workerCfg.output
    end
    if cfg.worker_buffers and cfg.worker_buffers[workerId] then
        local pair = cfg.worker_buffers[workerId]
        if type(pair) == "table" then return pair.input, pair.output end
    end
    if cfg.transfer_mode == "buffer" then
        local manual = cfg.peripherals or {}
        if type(manual.buffer_inputs) == "table" and type(manual.buffer_outputs) == "table" then
            local idx = 1 + ((workerId - 1) % math.max(1, math.min(#manual.buffer_inputs, #manual.buffer_outputs)))
            return manual.buffer_inputs[idx], manual.buffer_outputs[idx]
        end
    end
    return nil, nil
end

function dispatcher:workerSupportsWired(workerId)
    local name = self:workerName(workerId)
    if not name then return false, "Worker not visible on wired network" end
    local p = peripheral.wrap(name)
    if not p then return false, "Worker peripheral unavailable" end
    return true
end

function dispatcher:prepareBufferTask(workerId, task)
    local cfg = config.load()
    local inputChest, outputChest = self:resolveWorkerBuffers(workerId)
    if not inputChest or not outputChest then
        return false, "No buffer chests assigned for worker #" .. tostring(workerId) ..
            "; set config.workers[" .. tostring(workerId) .. "] = { input = ..., output = ... }"
    end
    if not peripheral.isPresent(inputChest) then
        return false, "Input buffer '" .. tostring(inputChest) .. "' is not present"
    end
    if not peripheral.isPresent(outputChest) then
        return false, "Output buffer '" .. tostring(outputChest) .. "' is not present"
    end
    local inputP = peripheral.wrap(inputChest)
    if not inputP or type(inputP.pushItems) ~= "function" or type(inputP.pullItems) ~= "function" then
        return false, "Input buffer '" .. tostring(inputChest) .. "' is not a container"
    end
    local outputP = peripheral.wrap(outputChest)
    if not outputP or type(outputP.pushItems) ~= "function" or type(outputP.pullItems) ~= "function" then
        return false, "Output buffer '" .. tostring(outputChest) .. "' is not a container"
    end
    return true, { input = inputChest, output = outputChest }
end

function dispatcher:prepareWiredTask(workerId, task)
    local turtleName = self:workerName(workerId)
    if not turtleName then
        return false, "Worker #" .. tostring(workerId) .. " not found on wired network"
    end
    local p = peripheral.wrap(turtleName)
    if not p then
        return false, "Worker #" .. tostring(workerId) .. " is not reachable on wired network"
    end
    return true, { turtle = turtleName, peripheral = p }
end

function dispatcher:countRequirementForTask(task)
    if not task.plan or not task.plan.items then return {} end
    local req = {}
    for _, ing in ipairs(task.plan.items) do
        req[ing.id] = (req[ing.id] or 0) + (ing.count or 0)
    end
    return req
end

function dispatcher:reserveForTaskTree(tree, key)
    if not self.storage then return true, nil, {} end
    -- Обходим листья дерева, разрешаем spec -> конкретный id (через resolveSpec,
    -- чтобы теги/варианты резервировались по реальному стоку) и агрегируем
    -- потребность по конкретному id.
    local perId = {}
    local order = {}
    local function visit(n)
        if not n then return end
        if n.has_recipe then
            for _, c in ipairs(n.children or {}) do visit(c) end
        else
            if n.kind ~= "fluid" and (n.count or 0) > 0 then
                local spec = n.spec or { id = n.id }
                local id = self.storage:resolveSpec(spec, n.count)
                if not id then id = n.id end  -- фолбэк: проверка ниже провалится по available
                if not perId[id] then perId[id] = 0; order[#order + 1] = id end
                perId[id] = perId[id] + n.count
            end
        end
    end
    visit(tree)

    local resById = {}
    local resIds = {}
    for _, id in ipairs(order) do
        local needed = perId[id]
        local avail = self.storage:available(id)
        if avail < needed then
            for _, rid in ipairs(resIds) do self.storage:release(rid) end
            local missing = needed - avail
            return false, string.format("Not enough %s: need %d, available %d, missing %d",
                lang.display(id), needed, avail, missing), nil
        end
        local rid = self.storage:reserve(id, needed, key)
        if rid then
            resIds[#resIds + 1] = rid
            resById[id] = rid
        end
    end
    return true, nil, resById
end

function dispatcher:releaseTaskReservations(task)
    if not task or not self.storage then return 0 end
    local released = 0
    if task._resById then
        for id, rid in pairs(task._resById) do
            released = released + self.storage:release(rid)
        end
    elseif task._reservations then
        for _, rid in ipairs(task._reservations) do
            released = released + self.storage:release(rid)
        end
    elseif task.reservation_id then
        released = released + self.storage:release(task.reservation_id)
    end
    task.reservation_id = nil
    task._reservations = nil
    task._resById = nil
    return released
end

function dispatcher:releaseOrderIfDone(task)
    if not task or not task.reservation_key or not self.storage then return end
    for _, t in pairs(self.tasks) do
        if t.reservation_key == task.reservation_key
           and (t.status == "queued" or t.status == "running")
           and t.id ~= task.id then
            return  -- в заказе ещё есть активные задачи
        end
    end
    self.storage:releaseByKey(task.reservation_key)
end

--- Потребовать резервации задачи при успехе: уменьшить резервации под реально
--- израсходованные предметы. Воркер уже извлёк ингредиенты, поэтому consume.
function dispatcher:consumeReserved(task)
    if not task or not self.storage then return end
    if task._resById then
        for id, rid in pairs(task._resById) do
            -- Сколько этой задачей израсходовано: считаем по BOM подзадачи.
            -- task.concrete_recipe уже зафиксирован, считаем ingredientsFor.
            local used = 0
            if task.concrete_recipe then
                for _, ing in ipairs(recipes.ingredientsFor(task.concrete_recipe, task.count)) do
                    if ing.id == id then used = used + ing.count end
                end
            end
            if used > 0 then
                self.storage:consumeReservation(rid, used)
            end
        end
    elseif task.reservation_id then
        -- legacy single reservation
        self.storage:consumeReservation(task.reservation_id, task.count or 0)
    end
end

--- Отпустить ВСЕ резервации заказа (по order-key) — при cancel всего заказа
--- или когда последняя задача закрыта/провалена.
function dispatcher:releaseOrderReservations(task)
    if not task or not task.reservation_key or not self.storage then return 0 end
    return self.storage:releaseByKey(task.reservation_key)
end

----------------------------------------------------------------
-- TASK PLANNING
----------------------------------------------------------------

local function flattenTree(node, arr)
    arr = arr or {}
    if not node then return arr end
    if node.has_recipe then
        for _, child in ipairs(node.children or {}) do flattenTree(child, arr) end
        arr[#arr + 1] = node
    end
    return arr
end

function dispatcher:enqueueTree(root)
    local nodes = flattenTree(root, {})
    local tasks = {}
    local nodeToTask = {}

    for _, node in ipairs(nodes) do
        local crafts = node.crafts or recipes.craftsNeeded(node.recipe, node.count)
        local task = {
            id = newTaskId(),
            recipe = node.recipe,
            count = node.count,
            crafts = crafts,
            requested = node.count,
            status = "queued",
            attempts = 0,
            step = nil,
            progress = 0,
            result = nil,
            dependencies = {},
            dependents = {},
            worker_id = nil,
            batch_index = 1,
            batch_total = 1,
            reservation_id = nil,
            plan = nil,
            task_type = node.recipe and node.recipe.type or "craft",
            created_at = now(),
            updated_at = now(),
            node = node,
        }
        tasks[#tasks + 1] = task
        self.tasks[task.id] = task
        nodeToTask[node] = task.id
    end

    -- Build dependencies by tree edges.
    local function link(node)
        local tid = nodeToTask[node]
        local task = self.tasks[tid]
        if not task then return end
        for _, child in ipairs(node.children or {}) do
            if child.has_recipe then
                local depId = nodeToTask[child]
                if depId then
                    task.dependencies[#task.dependencies + 1] = depId
                    local dep = self.tasks[depId]
                    dep.dependents[#dep.dependents + 1] = tid
                end
                link(child)
            end
        end
    end
    link(root)

    for _, task in ipairs(tasks) do
        self.queue[#self.queue + 1] = task.id
    end
    self._dirty = true
    return tasks
end

function dispatcher:prepareCraftPlan(tree)
    local steps = planner.craftSteps(tree)
    return steps
end

function dispatcher:requestCraft(id, count, recipesObj)
    recipesObj = recipesObj or self.recipes
    if not recipesObj then return nil, "recipes module missing" end
    local recipe = recipesObj:get(id)
    if not recipe then
        return nil, "No recipe for " .. lang.display(id)
    end

    local tree = planner.buildTree(id, count, recipesObj, self.storage, self.fluids)
    local can, avail = planner.canCraft(tree, self.storage, self.fluids)
    if not can then
        local missing = {}
        for mid, info in pairs(avail.items) do
            if info.missing > 0 then
                missing[#missing + 1] = string.format("%s (need %d, have %d, missing %d)", lang.display(mid), info.needed, info.available, info.missing)
            end
        end
        for f, info in pairs(avail.fluids) do
            if info.missing > 0 then
                missing[#missing + 1] = string.format("%s (need %dmB, have %dmB, missing %dmB)", lang.display("fluid:" .. f), info.needed, info.available, info.missing)
            end
        end
        return nil, "Missing resources: " .. table.concat(missing, "; ")
    end

    -- Резервируем базовые ресурсы заказа АТОМАРНО (до создания задач), чтобы
    -- два одновременных заказа не прошли canCraft на одном и том же стоке.
    local orderKey = "order_" .. newTaskId()
    local okRes, errRes, resById = self:reserveForTaskTree(tree, orderKey)
    if not okRes then
        -- частичное резервирование уже откачено в helper'е
        return nil, errRes or "reservation failed"
    end

    local steps = planner.craftSteps(tree)
    local taskIds = {}
    local prevTaskId = nil
    local batchMap = {}

    for _, step in ipairs(steps) do
        local stepRecipe = step.recipe
        local totalResult = step.count
        local output = stepRecipe.output or 1
        local totalCrafts = math.ceil(totalResult / output)
        local batch = self:batchCrafts(stepRecipe)
        local remainingCrafts = totalCrafts
        local stepTaskIds = {}

        while remainingCrafts > 0 do
            local batchCrafts = math.min(batch, remainingCrafts)
            local batchCount = batchCrafts * output
            local task = {
                id = newTaskId(),
                recipe = stepRecipe,
                count = batchCount,
                requested = batchCount,
                crafts = batchCrafts,
                status = "queued",
                attempts = 0,
                step = step,
                progress = 0,
                result = nil,
                dependencies = {},
                dependents = {},
                worker_id = nil,
                batch_index = (#stepTaskIds + 1),
                batch_total = math.ceil(totalCrafts / batch),
                reservation_id = nil,
                plan = nil,
                task_type = stepRecipe.type,
                created_at = now(),
                updated_at = now(),
                source_id = id,
                requested_root = count,
                reservation_key = orderKey,
                _resById = resById,
            }
            if prevTaskId then
                task.dependencies[#task.dependencies + 1] = prevTaskId
                self.tasks[prevTaskId].dependents[#self.tasks[prevTaskId].dependents + 1] = task.id
            end
            self.tasks[task.id] = task
            self.queue[#self.queue + 1] = task.id
            taskIds[#taskIds + 1] = task.id
            stepTaskIds[#stepTaskIds + 1] = task.id
            prevTaskId = task.id
            remainingCrafts = remainingCrafts - batchCrafts
            emit(self, "task_queued", { id = task.id, recipe = stepRecipe.id, count = batchCount })
        end
        batchMap[stepRecipe.id] = stepTaskIds
    end

    if #taskIds == 0 then
        return {}, "Already in storage"
    end

    self:markDirty()
    self:save()
    emit(self, "craft_planned", { id = id, count = count, steps = #taskIds })
    return taskIds, "Planned steps: " .. #taskIds
end

----------------------------------------------------------------
-- ПОДГОТОВКА ИНГРЕДИЕНТОВ И СБОР РЕЗУЛЬТАТА
----------------------------------------------------------------

--- Проверка: задача уже удовлетворена наличием в хранилище (например, после ребута).
function dispatcher:taskAlreadySatisfied(task)
    if not task or not task.recipe or not task.recipe.id then return false end
    local have = self.storage and self.storage:count(task.recipe.id) or 0
    return have >= (task.requested or task.count or 0)
end

--- Списать зарезервированный базовый ресурс при фактическом извлечении.
local function consumeReserved(self, task, id, amount)
    if not task or not task._resById or not self.storage or amount <= 0 then return end
    local rid = task._resById[id]
    if rid then self.storage:consumeReservation(rid, amount) end
end

--- Разрешить конкретный рецепт под задачу (теги/варианты/NBT -> конкретный id).
function dispatcher:resolveTaskConcrete(task)
    if task.concrete_recipe then return task.concrete_recipe end
    local crafts = task.crafts or math.ceil((task.count or 1) / math.max(1, (task.recipe and task.recipe.output) or 1))
    local concrete, err = recipes.resolveConcrete(task.recipe, crafts, self.storage)
    if not concrete then return nil, err or "tag_unresolved" end
    task.concrete_recipe = concrete
    return concrete
end

--- Извлечь ингредиент из хранилища в целевой инвентарь со списанием резерва.
local function extractIngredient(self, task, ing, target, slot)
    local spec = ing.spec or { id = ing.id }
    local got = self.storage:extract(spec, ing.count, target, slot)
    if got > 0 then consumeReserved(self, task, ing.id, got) end
    return got
end

--- BUFFER: разложить ингредиенты во ВХОДНОЙ сундук воркера.
function dispatcher:stageBuffer(workerId, task, ings)
    local ok, buff = self:prepareBufferTask(workerId, task)
    if not ok then return false, buff end
    local cfg = config.load()
    local wcfg = type(cfg.workers) == "table" and cfg.workers[workerId] or nil
    buff.input_side = (wcfg and wcfg.input_side) or "top"
    buff.output_side = (wcfg and wcfg.output_side) or "bottom"
    task.buffer = buff
    if self.workers[workerId] then self.workers[workerId].buffer = buff end

    local inputChest = buff.input
    for _, ing in ipairs(ings) do
        local got = extractIngredient(self, task, ing, inputChest, nil)
        local remaining = ing.count - got
        if remaining > 0 then
            self.storage:rescanItem(ing.id)
            self.storage:refreshEmptySlots()
            got = extractIngredient(self, task, ing, inputChest, nil)
            remaining = remaining - got
        end
        if remaining > 0 then
            local avail = self.storage:available(ing.id)
            if avail < ing.count then
                return false, string.format("Not enough %s: need %d, available %d",
                    lang.display(ing.id), ing.count, avail)
            end
            return false, string.format("Could not stage %s into input buffer", lang.display(ing.id))
        end
    end
    return true, buff
end

--- WIRED: разложить ингредиенты в EXTRA-слоты черепахи (legacy-алгоритм).
local TURTLE_EXTRA_SLOTS = { 4, 8, 12, 13, 14, 15, 16 }
function dispatcher:stageWired(workerId, task, ings)
    local ok, wired = self:prepareWiredTask(workerId, task)
    if not ok then return false, wired end
    local turtleName = wired.turtle
    local p = wired.peripheral

    local function turtleHasItems()
        local okL, list = pcall(p.list)
        return okL and list and next(list) ~= nil
    end
    if turtleHasItems() then
        self:collectResult(workerId)
        if turtleHasItems() then
            self.storage:refreshEmptySlots()
            self:collectResult(workerId)
            if turtleHasItems() then
                local free = self.storage:refreshEmptySlots()
                if not free or #free == 0 then
                    return false, "Storage full: no free slots to offload turtle before crafting"
                end
                return false, "Turtle blocked: could not clear inventory before crafting"
            end
        end
    end

    local freePool = {}
    for _, s in ipairs(TURTLE_EXTRA_SLOTS) do freePool[#freePool + 1] = s end
    local function syncPool()
        local kept = {}
        for _, s in ipairs(freePool) do
            local okC, c = pcall(p.getItemCount, s)
            if not (okC and c and c > 0) then kept[#kept + 1] = s end
        end
        freePool = kept
    end

    for _, ing in ipairs(ings) do
        local remaining = ing.count
        syncPool()
        local poolIdx = 1
        while remaining > 0 and poolIdx <= #freePool do
            local slot = freePool[poolIdx]
            local got = extractIngredient(self, task, ing, turtleName, slot)
            remaining = remaining - got
            poolIdx = poolIdx + 1
        end
        if remaining > 0 then
            self.storage:rescanItem(ing.id)
            self.storage:refreshEmptySlots()
            syncPool()
            poolIdx = 1
            while remaining > 0 and poolIdx <= #freePool do
                local slot = freePool[poolIdx]
                local got = extractIngredient(self, task, ing, turtleName, slot)
                remaining = remaining - got
                poolIdx = poolIdx + 1
            end
            if remaining > 0 then
                self:collectResult(workerId)
                return false, string.format("Not enough %s: need %d, could not stage to turtle",
                    lang.display(ing.id), ing.count)
            end
        end
        syncPool()
    end

    -- Физическая проверка раскладки.
    local present = {}
    local okL, list = pcall(p.list)
    if okL and list then
        for _, item in pairs(list) do
            if item and item.name then
                present[item.name] = (present[item.name] or 0) + (item.count or 0)
            end
        end
    end
    for _, ing in ipairs(ings) do
        if (present[ing.id] or 0) < ing.count then
            self:collectResult(workerId)
            return false, string.format("Ingredient layout incomplete: %s need %d, only %d reached turtle",
                lang.display(ing.id), ing.count, present[ing.id] or 0)
        end
    end
    return true, wired
end

function dispatcher:prepareIngredients(workerId, task)
    local cfg = config.load()
    local mode = task.transfer_mode or cfg.transfer_mode or self.transport_mode or "buffer"
    task.transfer_mode = mode

    -- После ребута результат мог уже лежать в хранилище — не крафтим повторно.
    if self:taskAlreadySatisfied(task) then
        task.status = "done"
        task.result = { success = true, count = task.count, elapsed = 0, crafts = 0 }
        removeValue(self.queue, task.id)
        self:releaseOrderIfDone(task)
        self._dirty = true
        emit(self, "task_done", { id = task.id, recipe = task.recipe and task.recipe.id,
            count = task.count, worker = "storage" })
        return true, { satisfied = true }
    end

    local concrete, cerr = self:resolveTaskConcrete(task)
    if not concrete then
        return false, cerr or "tag_unresolved"
    end
    local ings = recipes.ingredientsFor(concrete, task.count)

    if mode == "wired" then
        return self:stageWired(workerId, task, ings)
    end
    return self:stageBuffer(workerId, task, ings)
end

function dispatcher:collectResult(workerId)
    local w = self.workers[workerId]
    if not w then return 0, 0 end
    local mode = w.transfer_mode or self.transport_mode or "buffer"
    if mode == "wired" then
        local turtleName = self:workerName(workerId)
        if not turtleName then return 0, 0 end
        local p = peripheral.wrap(turtleName)
        if not p or not p.list then return 0, 0 end
        local ok, list = pcall(p.list)
        if not ok or not list then return 0, 0 end
        local total = 0
        for slot in pairs(list) do
            local moved = self.storage and self.storage:deposit(turtleName, slot, nil) or 0
            total = total + moved
        end
        local leftover = 0
        local okL, list2 = pcall(p.list)
        if okL and list2 then
            for _, item in pairs(list2) do leftover = leftover + (item.count or 0) end
        end
        return total, leftover
    end

    local buffer = w.buffer
    if not buffer or not buffer.output then return 0, 0 end
    local outChest = buffer.output
    local p = peripheral.wrap(outChest)
    if not p or type(p.list) ~= "function" then return 0, 0 end
    local ok, list = pcall(p.list)
    if not ok or not list then return 0, 0 end
    local total = 0
    for slot, item in pairs(list) do
        if item and item.count and item.count > 0 then
            total = total + (self.storage and self.storage:deposit(outChest, slot, nil) or 0)
        end
    end
    local leftover = 0
    local ok2, list2 = pcall(p.list)
    if ok2 and list2 then
        for _, item in pairs(list2) do leftover = leftover + (item.count or 0) end
    end
    return total, leftover
end

----------------------------------------------------------------
-- MESSAGE HANDLING
----------------------------------------------------------------

function dispatcher:handleMessage(senderId, msg)
    if not msg or not msg.type then return end
    local payload = msg.payload or {}
    local w = self.workers[senderId]

    if msg.type == net.MSG.HELLO or msg.type == net.MSG.WORKER_HELLO then
        -- Re-HELLO после ребута Core: НЕ сбрасываем busy/state, если воркер
        -- сейчас занят нашей задачей — пусть heartbeat подхватит реальное
        -- состояние. Только обновляем ready/buffer/last_seen.
        local existing = self.workers[senderId]
        self:addWorker(senderId, payload)
        local worker = self.workers[senderId]
        worker.ready = payload.ready ~= false
        worker.last_seen = now()
        if payload.state and not existing then
            worker.state = payload.state
        end
        if payload.buffer then worker.buffer = payload.buffer end
        if payload.current_task_id then worker.current_task_id = payload.current_task_id end
        if payload.core and payload.core ~= os.getComputerID() then
            net.send(senderId, net.MSG.DISCOVER, { core = os.getComputerID() })
        end
        self._dirty = true
        self:save()
        return
    elseif msg.type == net.MSG.BYE or msg.type == net.MSG.WORKER_BYE then
        self:removeWorker(senderId)
        self._dirty = true
        self:save()
        return
    elseif msg.type == net.MSG.PONG then
        if w then w.last_seen = now(); self._dirty = true; self:save() end
        return
    elseif msg.type == net.MSG.PING then
        net.send(senderId, net.MSG.PONG, { task_id = payload.task_id, busy = w and w.busy or false, current_task_id = w and w.current_task and w.current_task.id or nil })
        return
    elseif msg.type == net.MSG.HEARTBEAT then
        if w then
            w.last_seen = now()
            -- Маппим FSM-состояние воркера на наше (idle/busy/draining/free).
            -- РЕАЛЬНОЕ состояние из heartbeat, не производный busy-флаг.
            local incoming = payload.state
            if incoming == "idle" or incoming == "loading"
               or incoming == "crafting" or incoming == "unloading" then
                -- Если у нас была задача на этом воркере — сверяем id.
                if w.current_task and payload.current_task_id
                   and payload.current_task_id == w.current_task.id then
                    local prevState = w.state
                    w.state = incoming
                    -- Логируем переход на задачу (первое loading после free).
                    if prevState ~= incoming and prevState == "free" then
                        util.info("[worker #" .. tostring(senderId) .. "] state " .. tostring(prevState) .. " -> " .. incoming)
                    end
                    w.busy = (incoming ~= "idle")
                elseif not w.current_task then
                    -- Задачи нет, но воркер занят у другого/старого core —
                    -- доверяем его busy, но не перебиваем state без нужды.
                    w.busy = payload.busy == true
                    if not w.busy then w.state = "free" end
                end
                w.current_task_id = payload.current_task_id or w.current_task_id
            end
            -- Защита от stale heartbeat (busy=false, но мы думаем busy)
            if payload.busy == false and w.state ~= "free" and (not w.current_task or (payload.current_task_id and payload.current_task_id ~= w.current_task.id)) then
                local age = w.task_started_at and (now() - w.task_started_at) or 9999
                if age > self.heartbeat_grace then
                    if w.current_task then self:requeue(w.current_task, "stale_heartbeat") end
                    w.state = "free"
                    w.current_task = nil
                    w.busy = false
                    w.current_task_id = nil
                    w.task_started_at = nil
                    w.task_deadline = nil
                end
            end
            self._dirty = true
            self:save()
        end
        return
    elseif msg.type == net.MSG.CRAFT_ACK then
        local task = payload.task_id and self.tasks[payload.task_id] or nil
        if task then
            task.acked = true
            task.ack_time = now()
            task.updated_at = now()
            if w then w.last_seen = now() end
            self._dirty = true
            self:save()
        end
        return
    elseif msg.type == net.MSG.STATUS then
        local task = payload.task_id and self.tasks[payload.task_id] or nil
        if task then
            task.progress = payload.progress or task.progress or 0
            task.status_message = payload.message or task.status_message
            task.updated_at = now()
            emit(self, "task_progress", { id = task.id, progress = task.progress })
            self._dirty = true
            self:save()
        end
        return
    elseif msg.type == net.MSG.RESULT then
        local task = payload.task_id and self.tasks[payload.task_id] or nil
        if not task and w and w.current_task and payload.task_id == w.current_task.id then
            task = w.current_task
        end
        if not task then return end
        if payload.success then
            task.status = "done"
            task.result = payload
            task.updated_at = now()
            -- Потребляем резервацию заказа (по общему order-key).
            self:consumeReserved(task)
            -- Если весь заказ закрыт — отпускаем хвостовые резервы.
            self:releaseOrderIfDone(task)
            emit(self, "task_done", { id = task.id, recipe = task.recipe and task.recipe.id, count = payload.count or task.count, worker = senderId })
        else
            task.status = "failed"
            task.result = payload
            task.updated_at = now()
            local errStr = payload.error or "worker returned error"
            -- storage_full — воркер ещё не выгрузил остаток; ставим draining,
            -- Core ретраит collectResult на тиках, не выдаёт новую задачу.
            if w and errStr == "storage_full" then
                w.state = "draining"
                w.busy = true  -- занят, но не новой задачей
                w.current_task = task
                w.current_task_id = task.id
                w.task_started_at = nil
                w.task_deadline = nil
                emit(self, "task_failed", { id = task.id, error = errStr })
                self._dirty = true
                self:save()
                return
            end
            -- Отпускаем хвостовые резервы заказа, только если в нём больше нет
            -- активных задач (параллельные батчи того же заказа продолжаются).
            self:releaseOrderIfDone(task)
            emit(self, "task_failed", { id = task.id, error = errStr })
            self:failDependents(task.id, errStr)
        end
        if w then
            w.current_task = nil
            w.current_task_id = nil
            w.busy = false
            w.state = "free"
            w.task_started_at = nil
            w.task_deadline = nil
            w.last_seen = now()
        end
        removeValue(self.queue, task.id)
        self._dirty = true
        self:save()
        return
    end
end

----------------------------------------------------------------
-- DISPATCH LOOP
----------------------------------------------------------------

function dispatcher:_dispatchTaskToWorker(workerId, task)
    local cfg = config.load()
    local mode = task.transfer_mode or cfg.transfer_mode or self.transport_mode or "buffer"
    task.updated_at = now()
    task.sent_at = now()
    task.ack_attempts = (task.ack_attempts or 0) + 1
    task.ack_deadline = now() + math.max(1, cfg.net_timeout or 5)
    task.acked = false

    local payload = {
        task_id = task.id,
        recipe = task.concrete_recipe or task.recipe,
        count = task.count,
        crafts = task.crafts,
        transfer_mode = mode,
        buffer = nil,
    }
    if mode == "buffer" then
        payload.buffer = task.buffer
        if self.workers[workerId] then self.workers[workerId].buffer = task.buffer end
    else
        payload.turtle = self:workerName(workerId)
    end

    net.send(workerId, net.MSG.CRAFT_REQUEST, payload)
    task.worker_id = workerId
    task.status = "running"
    task.sent_at = now()
    task.updated_at = now()

    local w = self.workers[workerId]
    if w then
        w.state = "busy"
        w.busy = true
        w.current_task = task
        w.current_task_id = task.id
        w.task_started_at = now()
        local crafts = task.crafts or math.ceil((task.count or 1) / math.max(1, task.recipe.output or 1))
        local avg = (self.recipes and task.recipe and self.recipes.avgTimeFor and self.recipes.avgTimeFor(task.recipe)) or planner.DEFAULT_TIME.crafting
        if type(avg) == "table" then avg = avg[1] or 1 end
        w.task_deadline = math.max(60, (avg or 1) * crafts * 3)
        w.transfer_mode = mode
    end
    emit(self, "task_started", { id = task.id, worker = workerId, recipe = task.recipe and task.recipe.id, count = task.count, transfer_mode = mode, crafts = task.crafts })
    return true
end

function dispatcher:_readyQueue()
    local ready = {}
    for _, tid in ipairs(self.queue) do
        local task = self.tasks[tid]
        if task and task.status == "queued" and self:isTaskReady(task) then
            ready[#ready + 1] = task
        end
    end
    table.sort(ready, function(a, b)
        if a.created_at == b.created_at then return a.id < b.id end
        return a.created_at < b.created_at
    end)
    return ready
end

function dispatcher:_ackRetryLoop()
    local cfg = config.load()
    local timeout = math.max(1, cfg.net_timeout or 5)
    for _, task in pairs(self.tasks) do
        if task.status == "running" and not task.acked and task.ack_deadline > 0 and now() > task.ack_deadline then
            if task.ack_attempts < 3 then
                local workerId = task.worker_id
                local w = workerId and self.workers[workerId] or nil
                if workerId and w then
                    task.ack_attempts = task.ack_attempts + 1
                    task.ack_deadline = now() + timeout
                    net.send(workerId, net.MSG.CRAFT_REQUEST, {
                        task_id = task.id,
                        recipe = task.recipe,
                        count = task.count,
                        crafts = task.crafts,
                        transfer_mode = task.transfer_mode or cfg.transfer_mode or "buffer",
                        buffer = w.buffer,
                        retry = true,
                    })
                end
            else
                if task.worker_id and self.workers[task.worker_id] then
                    self:requeue(task, "ack_timeout")
                    local w = self.workers[task.worker_id]
                    w.state = "free"
                    w.busy = false
                    w.current_task = nil
                    w.current_task_id = nil
                    w.task_started_at = nil
                    w.task_deadline = nil
                end
            end
        end
    end
end

function dispatcher:tick()
    self.transport_mode = (config.load().transfer_mode or self.transport_mode or "buffer")
    self:_ackRetryLoop()

    -- Retrying drain of workers that had leftovers.
    for id, w in pairs(self.workers) do
        if w.state == "draining" then
            local _, leftover = self:collectResult(id)
            if (leftover or 0) <= 0 then
                w.state = "free"
                w.busy = false
                w.current_task = nil
                w.current_task_id = nil
                emit(self, "worker_drain_done", { id = id })
            end
        end
    end

    local ready = self:_readyQueue()
    if #ready == 0 then
        self:save()
        return
    end

    local freeWorkers = {}
    for id, w in pairs(self.workers) do
        if w.state == "free" and w.ready ~= false then
            freeWorkers[#freeWorkers + 1] = id
        end
    end
    table.sort(freeWorkers)

    local idx = 1
    while #ready > 0 and idx <= #freeWorkers do
        local workerId = freeWorkers[idx]
        local task = table.remove(ready, 1)
        removeValue(self.queue, task.id)
        -- После ребута задача могла стать удовлетворённой физически (результат
        -- уже в хранилище). Короткое замыкание: помечаем done, потребляем резерв.
        if self:taskAlreadySatisfied(task) then
            task.status = "done"
            task.result = { success = true, count = task.count }
            task.updated_at = now()
            self:consumeReserved(task)
            self:releaseOrderIfDone(task)
            emit(self, "task_done", { id = task.id, recipe = task.recipe and task.recipe.id,
                count = task.count, worker = "cache" })
            idx = idx + 1
            if idx % 4 == 0 then os.sleep(0) end
        elseif task.attempts >= self.maxAttempts then
            task.status = "failed"
            task.result = { success = false, error = "max attempts exceeded" }
            self:releaseOrderIfDone(task)
            emit(self, "task_failed", { id = task.id, error = "max attempts exceeded" })
            self:failDependents(task.id, "max attempts exceeded")
            idx = idx + 1
            if idx % 4 == 0 then os.sleep(0) end
        else
            local ok, prep = self:prepareIngredients(workerId, task)
            if not ok then
                task.attempts = task.attempts + 1
                if task.attempts >= self.maxAttempts then
                    task.status = "failed"
                    task.result = { success = false, error = prep }
                    self:releaseOrderIfDone(task)
                    emit(self, "task_failed", { id = task.id, error = prep })
                    self:failDependents(task.id, prep)
                else
                    task.status = "queued"
                    self.queue[#self.queue + 1] = task.id
                    emit(self, "task_retry", { id = task.id, error = prep })
                end
            else
                task.attempts = task.attempts + 1
                local sent, err = self:_dispatchTaskToWorker(workerId, task)
                if not sent then
                    task.status = "queued"
                    self.queue[#self.queue + 1] = task.id
                    task.attempts = math.max(0, task.attempts - 1)
                    emit(self, "task_retry", { id = task.id, error = err or "dispatch failed" })
                end
            end
            idx = idx + 1
            if idx % 4 == 0 then os.sleep(0) end
        end
    end

    self:save()
end

function dispatcher:checkTimeouts(timeout)
    timeout = timeout or 60
    local ts = now()
    for id, w in pairs(self.workers) do
        if w.state == "busy" then
            if (ts - (w.last_seen or ts)) > timeout then
                if w.current_task then
                    self:requeue(w.current_task, "worker_dead")
                    emit(self, "task_timeout", { id = w.current_task.id, worker = id, reason = "worker_dead" })
                end
                w.state = "free"
                w.busy = false
                w.current_task = nil
                w.current_task_id = nil
                w.task_started_at = nil
                w.task_deadline = nil
            elseif w.task_started_at and (ts - w.task_started_at) > (w.task_deadline or self.task_timeout) then
                if w.current_task then
                    self:requeue(w.current_task, "task_deadline")
                    emit(self, "task_timeout", { id = w.current_task.id, worker = id, reason = "task_deadline" })
                end
                w.state = "free"
                w.busy = false
                w.current_task = nil
                w.current_task_id = nil
                w.task_started_at = nil
                w.task_deadline = nil
            end
        elseif w.state == "draining" then
            if (ts - (w.last_seen or ts)) > timeout then
                w.state = "free"
                w.busy = false
                w.current_task = nil
                w.current_task_id = nil
            end
        end
    end
    self:save()
end

return dispatcher
