-- worker/worker.lua
-- Черепаха-воркер ShellCraft.
-- Ждёт задачи от Core через rednet, крафтит, отчитывается.
-- Ингредиенты кладутся Core прямо в инвентарь черепахи (по проводному модему),
-- результат Core забирает сам. Воркеру нужны только краснет-модем и проводной модем.

local worker = {}
worker.__index = worker

--- Создать воркера.
function worker.new()
    local self = setmetatable({}, worker)
    self.core_id = nil
    self.crafting = false
    self.current_task_id = nil  -- task ID currently being worked on (for heartbeat matching)
    self.canCraft = true  -- set to false if turtle lacks crafting table
    return self
end

--- Установить ID core.
function worker:setCore(id)
    self.core_id = id
end

--- Ответить на DISCOVER / отправить HELLO.
function worker:sayHello(target)
    local payload = {
        id = os.getComputerID(),
        role = "worker",
        busy = self.crafting,
        version = _SHELLCRAFT_VERSION,
        core = self.core_id,
    }
    if target then
        net.send(target, net.MSG.WORKER_HELLO, payload)
    else
        net.broadcast(net.MSG.WORKER_HELLO, payload)
    end
end

--- Отправить статус Core.
function worker:sendStatus(taskId, progress, message)
    if not self.core_id then return end
    net.send(self.core_id, net.MSG.STATUS, {
        task_id = taskId,
        progress = progress,
        message = message,
    })
end

--- Отправить результат Core.
function worker:sendResult(taskId, success, payload)
    if not self.core_id then return end
    net.send(self.core_id, net.MSG.RESULT, payload)
end

local GRID = {1, 2, 3, 5, 6, 7, 9, 10, 11}
local EXTRA_SLOTS = {4, 8, 12, 13, 14, 15, 16}

local function hasContainer(dir)
    local p = peripheral.wrap(dir)
    return p ~= nil and type(p.list) == "function" and type(p.size) == "function"
end

--- Попытаться сбросить предмет во внешний инвентарь (соседний или на сети).
local function dropToExternal(slot)
    turtle.select(slot)
    if hasContainer("front") and turtle.drop() then return true end
    if hasContainer("top") and turtle.dropUp() then return true end
    if hasContainer("bottom") and turtle.dropDown() then return true end
    
    local inv = peripheral.find("inventory")
    if inv then
        local modem = peripheral.find("modem")
        if modem then
            local myName = modem.getNameLocal()
            if myName then
                local ok, moved = pcall(inv.pullItems, myName, slot)
                if ok and moved and moved > 0 then
                    return true
                end
            end
        end
    end
    return false
end

--- Очистить инвентарь черепахи (вернуть всё из слотов сетки в EXTRA_SLOTS).
local function clearCraftingGrid()
    for _, s in ipairs(GRID) do
        if turtle.getItemCount(s) > 0 then
            -- 1. Try to transfer to EXTRA_SLOTS
            local item = turtle.getItemDetail(s)
            if item then
                for _, dst in ipairs(EXTRA_SLOTS) do
                    local dstItem = turtle.getItemDetail(dst)
                    if not dstItem or (dstItem.name == item.name and turtle.getItemSpace(dst) > 0) then
                        turtle.select(s)
                        turtle.transferTo(dst)
                        if turtle.getItemCount(s) == 0 then break end
                    end
                end
            end
            
            -- 2. If still has items, try to drop to external inventory
            if turtle.getItemCount(s) > 0 then
                dropToExternal(s)
            end
            
            -- 3. If still has items, return error
            if turtle.getItemCount(s) > 0 then
                local detail = turtle.getItemDetail(s)
                local name = detail and detail.name or "unknown item"
                return false, "cannot clear crafting grid: slot " .. s .. " still has " .. name .. " (inventory full)"
            end
        end
    end
    
    -- Verify grid is empty
    for _, s in ipairs(GRID) do
        if turtle.getItemCount(s) > 0 then
            local detail = turtle.getItemDetail(s)
            local name = detail and detail.name or "unknown item"
            return false, "cannot clear crafting grid: slot " .. s .. " still has " .. name .. " (verification failed)"
        end
    end
    
    turtle.select(1)
    return true
end

--- Найти слот в EXTRA_SLOTS с предметом данного id.
-- @param id ID предмета
-- @param fromIdx индекс в EXTRA_SLOTS, с которого начинать поиск
-- @return слот, индекс в EXTRA_SLOTS или nil
local function findSlotWith(id, fromIdx)
    fromIdx = fromIdx or 1
    for i = fromIdx, #EXTRA_SLOTS do
        local s = EXTRA_SLOTS[i]
        local detail = turtle.getItemDetail(s)
        if detail and detail.name == id then
            return s, i
        end
    end
    return nil
end

--- Разложить ингредиенты по shaped pattern (слоты 1-9).
-- @param recipe рецепт с .pattern (3x3)
-- @param crafts сколько крафтов
-- @return true | false, ошибка
local function layoutShaped(recipe, crafts)
    local cok, cerr = clearCraftingGrid()
    if not cok then return false, cerr end
    
    for i = 1, 9 do
        local row = math.ceil(i / 3)
        local col = ((i - 1) % 3) + 1
        local cell = recipe.pattern[row] and recipe.pattern[row][col]
        local targetId = cell and (type(cell) == "table" and cell.id or cell)
        if targetId then
            local need = crafts
            local searchFromIdx = 1
            local gridSlot = GRID[i]
            while need > 0 do
                local s, sIdx = findSlotWith(targetId, searchFromIdx)
                if not s then
                    return false, "ingredient not found in turtle inventory: " .. lang.localize(targetId)
                end
                local detail = turtle.getItemDetail(s)
                local take = math.min(need, detail.count)
                turtle.select(s)
                turtle.transferTo(gridSlot, take)
                need = need - take
                searchFromIdx = sIdx + 1
            end
        end
    end
    turtle.select(1)
    return true
end

--- Разложить ингредиенты для shapeless рецепта (любые слоты сетки).
-- Каждый ингредиент — в свой слот, количество = crafts * ing.count.
local function layoutShapeless(recipe, crafts)
    local cok, cerr = clearCraftingGrid()
    if not cok then return false, cerr end
    
    local idx = 1
    for _, ing in ipairs(recipe.ingredients or {}) do
        if idx > 9 then
            return false, "too many ingredients for shapeless (>9)"
        end
        local need = crafts * (ing.count or 1)
        if need > 64 then
            return false, "too many " .. lang.localize(ing.id) .. " (" .. need .. ">64)"
        end
        local searchFromIdx = 1
        local gridSlot = GRID[idx]
        while need > 0 do
            local s, sIdx = findSlotWith(ing.id, searchFromIdx)
            if not s then
                return false, "ingredient not found in turtle inventory: " .. lang.localize(ing.id)
            end
            local detail = turtle.getItemDetail(s)
            local take = math.min(need, detail.count)
            turtle.select(s)
            turtle.transferTo(gridSlot, take)
            need = need - take
            searchFromIdx = sIdx + 1
        end
        idx = idx + 1
    end
    turtle.select(1)
    return true
end

--- Проверить соответствие предметов в сетке рецепту.
local function verifyGridMatches(recipe)
    if recipe.type == "shaped" then
        for i = 1, 9 do
            local row = math.ceil(i / 3)
            local col = ((i - 1) % 3) + 1
            local cell = recipe.pattern[row] and recipe.pattern[row][col]
            local expectedId = cell and (type(cell) == "table" and cell.id or cell)
            
            local gridSlot = GRID[i]
            local detail = turtle.getItemDetail(gridSlot)
            local actualId = detail and detail.name
            
            if expectedId then
                if not actualId then
                    return false, "grid mismatch at slot " .. gridSlot .. ": got empty, expected " .. expectedId
                elseif actualId ~= expectedId then
                    return false, "grid mismatch at slot " .. gridSlot .. ": got " .. actualId .. ", expected " .. expectedId
                end
            else
                if actualId then
                    return false, "grid mismatch at slot " .. gridSlot .. ": got " .. actualId .. ", expected empty"
                end
            end
        end
    else
        -- Shapeless
        local expected = {}
        for idx, ing in ipairs(recipe.ingredients or {}) do
            expected[idx] = ing.id
        end
        
        for i = 1, 9 do
            local gridSlot = GRID[i]
            local detail = turtle.getItemDetail(gridSlot)
            local actualId = detail and detail.name
            local expectedId = expected[i]
            
            if expectedId then
                if not actualId then
                    return false, "grid mismatch at slot " .. gridSlot .. ": got empty, expected " .. expectedId
                elseif actualId ~= expectedId then
                    return false, "grid mismatch at slot " .. gridSlot .. ": got " .. actualId .. ", expected " .. expectedId
                end
            else
                if actualId then
                    return false, "grid mismatch at slot " .. gridSlot .. ": got " .. actualId .. ", expected empty"
                end
            end
        end
    end
    return true
end

--- Выполнить один крафт в чанках (до 64 за раз).
-- @param recipe рецепт
-- @param count сколько штук результата
-- @return true, howMany | false, ошибка
function worker:craft(recipe, count)
    if not recipe then
        return false, "No recipe"
    end
    if recipe.type == "machine" then
        return false, "Machine recipes are handled by Core, not worker"
    end
    local output = recipe.output or 1
    local crafts = math.ceil(count / output)
    self.crafting = true

    local t0 = os.epoch("utc")
    local totalCrafted = 0
    local remainingCrafts = crafts
    local stepNum = 1

    while remainingCrafts > 0 do
        local chunk = math.min(64, remainingCrafts)
        
        -- 1. Layout chunk worth of ingredients
        local lok, lerr = (recipe.type == "shaped") and layoutShaped(recipe, chunk) or layoutShapeless(recipe, chunk)
        if not lok then
            self.crafting = false
            return false, lerr
        end
        
        -- 2. Verify grid matches exactly
        local vok, verr = verifyGridMatches(recipe)
        if not vok then
            self.crafting = false
            return false, verr
        end
        
        -- 3. Perform craft
        turtle.select(1)
        local ok, reason = turtle.craft(chunk)
        if not ok then
            self.crafting = false
            -- Dump current grid contents for diagnosis
            local dump = {}
            for _, s in ipairs(GRID) do
                local d = turtle.getItemDetail(s)
                if d then dump[#dump+1] = "slot" .. s .. "=" .. d.name .. "x" .. d.count end
            end
            local gridStr = #dump > 0 and table.concat(dump, ", ") or "empty"
            return false, "turtle.craft rejected step " .. stepNum ..
                " (recipe " .. tostring(recipe.id) .. "): " .. tostring(reason) .. " | grid: " .. gridStr
        end
        
        -- 4. Move result out of slot 1 to a non-grid slot
        if turtle.getItemCount(1) > 0 then
            local moved = false
            for _, dst in ipairs(EXTRA_SLOTS) do
                local detail = turtle.getItemDetail(dst)
                local resDetail = turtle.getItemDetail(1)
                if not detail or (resDetail and detail.name == resDetail.name and turtle.getItemSpace(dst) > 0) then
                    turtle.select(1)
                    if turtle.transferTo(dst) then
                        moved = true
                        break
                    end
                end
            end
            if not moved then
                dropToExternal(1)
                if turtle.getItemCount(1) == 0 then
                    moved = true
                end
            end
            if not moved then
                self.crafting = false
                return false, "failed to move crafted item from slot 1 to non-grid slots (inventory full)"
            end
        end
        
        totalCrafted = totalCrafted + chunk * output
        remainingCrafts = remainingCrafts - chunk
        stepNum = stepNum + 1
    end

    local t1 = os.epoch("utc")
    self.crafting = false
    local elapsed = (t1 - t0) / 1000
    if elapsed < 0 then elapsed = 0 end
    return true, totalCrafted, elapsed, crafts
end

--- Главный цикл воркера.
function worker:run()
    -- Открываем модемы
    if not net.open() then
        util.warn("No modem! Please attach a wired or wireless modem to the turtle.")
    end

    util.ok("Worker #" .. os.getComputerID() .. " started, waiting for tasks")

    -- Validate turtle APIs at startup
    if type(turtle) ~= "table" then
        util.err("ERROR: 'turtle' API not available. This program must run on a turtle!")
        self.canCraft = false
    else
        if type(turtle.craft) ~= "function" then
            util.err("========================================")
            util.err("WARNING: turtle.craft is NOT available!")
            util.err("This turtle has no crafting table.")
            util.err("Equip a Crafting Table to make a")
            util.err("Crafting Turtle, or craft requests")
            util.err("will be rejected with an error.")
            util.err("========================================")
            self.canCraft = false
        end
        if type(turtle.getItemDetail) ~= "function" then
            util.warn("WARNING: turtle.getItemDetail not available")
        end
        if type(turtle.transferTo) ~= "function" then
            util.warn("WARNING: turtle.transferTo not available")
        end
        if type(turtle.select) ~= "function" then
            util.warn("WARNING: turtle.select not available")
        end
    end

    -- Первичный HELLO (broadcast) — Core подхватит
    self:sayHello(nil)
    -- Периодический heartbeat
    local lastBeat = os.clock()
    while true do
        local senderId, msg = net.receive(5)
        if senderId and msg then
            if msg.type == net.MSG.DISCOVER then
                self.core_id = (msg.payload and msg.payload.core) or senderId
                self:sayHello(senderId)
            elseif msg.type == net.MSG.CRAFT_REQUEST then
                local p = msg.payload or {}
                self.core_id = senderId
                -- Set busy flag IMMEDIATELY before any work (prevents stale heartbeat race)
                self.crafting = true
                self.current_task_id = p.task_id
                -- Wrap entire CRAFT_REQUEST handling in pcall to prevent silent crashes
                local handlerOk, handlerErr = pcall(function()
                    util.info("Craft task: " .. tostring(p.recipe and p.recipe.id) .. " x" .. tostring(p.count))
                    -- Check if this turtle can craft
                    if not self.canCraft then
                        self.crafting = false
                        self.current_task_id = nil
                        self:sendResult(p.task_id, false, {
                            task_id = p.task_id,
                            success = false,
                            error = "This turtle has no crafting table (not a Crafting Turtle) - cannot craft.",
                        })
                        util.err("Rejected craft: no crafting table")
                        return
                    end
                    self:sendStatus(p.task_id, 0, "starting")
                    -- pcall around craft() to catch any runtime errors
                    local craftOk, ok, res, elapsed, crafts = pcall(self.craft, self, p.recipe, p.count)
                    self.crafting = false
                    self.current_task_id = nil
                    if not craftOk then
                        -- craft() itself threw an error (crash)
                        local errText = "Worker crash in craft(): " .. tostring(ok)
                        self:sendResult(p.task_id, false, {
                            task_id = p.task_id,
                            success = false,
                            error = errText,
                        })
                        util.err(errText)
                        return
                    end
                    if ok then
                        self:sendStatus(p.task_id, 100, "done")
                        self:sendResult(p.task_id, true, {
                            task_id = p.task_id,
                            success = true,
                            count = res,
                            elapsed = elapsed,
                            crafts = crafts,
                        })
                        util.ok("Done: " .. res .. " pcs in " .. string.format("%.2f", elapsed or 0) .. "s")
                    else
                        self:sendResult(p.task_id, false, {
                            task_id = p.task_id,
                            success = false,
                            error = res,
                        })
                        util.err("Craft error: " .. tostring(res))
                    end
                end)
                if not handlerOk then
                    -- Outer pcall caught an error in the handler itself
                    self.crafting = false
                    self.current_task_id = nil
                    local errText = "Worker crash handling CRAFT_REQUEST: " .. tostring(handlerErr)
                    pcall(function()
                        self:sendResult(p.task_id, false, {
                            task_id = p.task_id,
                            success = false,
                            error = errText,
                        })
                    end)
                    util.err(errText)
                end
            elseif msg.type == net.MSG.LEARN_CRAFT_REQUEST then
                self.core_id = senderId
                turtle.select(1)
                local ok2 = turtle.craft(1)
                if ok2 then
                    local foundDetail = nil
                    local foundSlot = nil
                    for s = 1, 16 do
                        local det = turtle.getItemDetail(s)
                        if det and det.name then
                            foundDetail = det
                            foundSlot = s
                            break
                        end
                    end
                    if foundDetail then
                        net.send(senderId, net.MSG.LEARN_CRAFT_RESPONSE, {
                            success = true,
                            name = foundDetail.name,
                            displayName = foundDetail.displayName,
                            count = foundDetail.count,
                            slot = foundSlot,
                        })
                    else
                        net.send(senderId, net.MSG.LEARN_CRAFT_RESPONSE, {
                            success = false,
                            error = "could not find crafted item in slots",
                        })
                    end
                else
                    net.send(senderId, net.MSG.LEARN_CRAFT_RESPONSE, {
                        success = false,
                        error = "turtle.craft failed (invalid grid layout)",
                    })
                end
            elseif msg.type == net.MSG.PING then
                net.send(senderId, net.MSG.PONG, { id = os.getComputerID() })
            elseif msg.type == net.MSG.CRAFT_CANCEL then
                -- Отмена — не реализована полноценно, просто лог
                util.warn("Received cancel for task " .. tostring(msg.payload and msg.payload.task_id))
            end
        end
        -- Heartbeat Core или трансляция присутствия раз в 10 сек
        if os.clock() - lastBeat > 10 then
            if self.core_id then
                net.send(self.core_id, net.MSG.HEARTBEAT, { id = os.getComputerID(), busy = self.crafting, current_task_id = self.current_task_id })
            else
                self:sayHello(nil)
            end
            lastBeat = os.clock()
        end
    end
end

return worker
