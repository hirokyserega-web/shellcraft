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

--- Очистить инвентарь черепахи (вернуть всё из слотов сетки в слоты 13-16).
local function clearCraftingGrid()
    for _, s in ipairs(GRID) do
        if turtle.getItemCount(s) > 0 then
            -- ищем свободный слот 13-16
            for dst = 13, 16 do
                if turtle.getItemSpace(dst) > 0 then
                    turtle.select(s)
                    local detail = turtle.getItemDetail(s)
                    local dstDetail = turtle.getItemDetail(dst)
                    -- только если тот же тип или пусто
                    if not dstDetail or (detail and dstDetail.name == detail.name) then
                        turtle.transferTo(dst)
                        if turtle.getItemCount(s) == 0 then break end
                    end
                end
            end
        end
    end
    turtle.select(1)
end

--- Найти слот 1-16 с предметом данного id.
-- @return слот или nil
local function findSlotWith(id, fromSlot)
    fromSlot = fromSlot or 1
    for s = fromSlot, 16 do
        local detail = turtle.getItemDetail(s)
        if detail and detail.name == id then
            return s
        end
    end
    return nil
end

--- Разложить ингредиенты по shaped pattern (слоты 1-9).
-- @param recipe рецепт с .pattern (3x3)
-- @param crafts сколько крафтов
-- @return true | false, ошибка
local function layoutShaped(recipe, crafts)
    -- Сначала убираем всё из слотов сетки в 13-16
    clearCraftingGrid()
    for i = 1, 9 do
        local row = math.ceil(i / 3)
        local col = ((i - 1) % 3) + 1
        local targetId = recipe.pattern[row] and recipe.pattern[row][col]
        if targetId then
            local need = crafts
            local searchFrom = 1
            local gridSlot = GRID[i]
            while need > 0 do
                local s = findSlotWith(targetId, searchFrom)
                if not s then
                    return false, "ingredient not found in turtle inventory: " .. lang.localize(targetId)
                end
                if s == gridSlot then
                    local detail = turtle.getItemDetail(s)
                    local existing = detail and detail.count or 0
                    local take = math.min(need, existing)
                    need = need - take
                    searchFrom = s + 1
                else
                    local detail = turtle.getItemDetail(s)
                    local take = math.min(need, detail.count)
                    turtle.select(s)
                    turtle.transferTo(gridSlot, take)
                    need = need - take
                    searchFrom = s + 1
                end
            end
        end
    end
    turtle.select(1)
    return true
end

--- Разложить ингредиенты для shapeless рецепта (любые слоты сетки).
-- Каждый ингредиент — в свой слот, количество = crafts * ing.count.
local function layoutShapeless(recipe, crafts)
    clearCraftingGrid()
    local idx = 1
    for _, ing in ipairs(recipe.ingredients or {}) do
        if idx > 9 then
            return false, "too many ingredients for shapeless (>9)"
        end
        local need = crafts * (ing.count or 1)
        if need > 64 then
            return false, "too many " .. lang.localize(ing.id) .. " (" .. need .. ">64)"
        end
        local searchFrom = 1
        local gridSlot = GRID[idx]
        while need > 0 do
            local s = findSlotWith(ing.id, searchFrom)
            if not s then
                return false, "ingredient not found in turtle inventory: " .. lang.localize(ing.id)
            end
            if s == gridSlot then
                local detail = turtle.getItemDetail(s)
                local existing = detail and detail.count or 0
                local take = math.min(need, existing)
                need = need - take
                searchFrom = s + 1
            else
                local detail = turtle.getItemDetail(s)
                local take = math.min(need, detail.count)
                turtle.select(s)
                turtle.transferTo(gridSlot, take)
                need = need - take
                searchFrom = s + 1
            end
        end
        idx = idx + 1
    end
    turtle.select(1)
    return true
end

--- Сложить весь результат в слоты 10-16 и оставить слот 1 с результатом.
-- На самом деле просто считаем, что после craft результат в слоте 1.
-- Core заберёт всё. Ничего не делаем.

--- Выполнить один крафт.
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

    while remainingCrafts > 0 do
        local chunk = math.min(64, remainingCrafts)
        -- Layout
        local ok, err
        if recipe.type == "shaped" then
            ok, err = layoutShaped(recipe, chunk)
        else
            ok, err = layoutShapeless(recipe, chunk)
        end
        if not ok then
            self.crafting = false
            return false, err
        end

        -- Craft
        turtle.select(1)
        local success = turtle.craft(chunk)
        if not success then
            self.crafting = false
            return false, "turtle.craft failed for chunk " .. chunk
        end
        totalCrafted = totalCrafted + chunk * output
        remainingCrafts = remainingCrafts - chunk
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
                util.info("Craft task: " .. tostring(p.recipe and p.recipe.id) .. " x" .. tostring(p.count))
                self:sendStatus(p.task_id, 0, "starting")
                local ok, res, elapsed, crafts = self:craft(p.recipe, p.count)
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
                net.send(self.core_id, net.MSG.HEARTBEAT, { id = os.getComputerID(), busy = self.crafting })
            else
                self:sayHello(nil)
            end
            lastBeat = os.clock()
        end
    end
end

return worker
