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

--- Очистить инвентарь черепахи (вернуть всё в... никуда, просто перенести в слоты 10-16).
-- Слоты 1-9 должны быть чистыми для раскладки pattern.
local function clearCraftingGrid()
    for s = 1, 9 do
        if turtle.getItemCount(s) > 0 then
            -- ищем свободный слот 10-16
            for dst = 10, 16 do
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

--- Найти слот 10-16 с предметом данного id и нужным количеством.
-- @return слот или nil
local function findSlotWith(id, fromSlot)
    fromSlot = fromSlot or 10
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
    -- Сначала убираем всё из слотов 1-9 в 10-16
    clearCraftingGrid()
    for i = 1, 9 do
        local row = math.ceil(i / 3)
        local col = ((i - 1) % 3) + 1
        local targetId = recipe.pattern[row] and recipe.pattern[row][col]
        if targetId then
            local need = crafts
            local searchFrom = 10
            while need > 0 do
                local s = findSlotWith(targetId, searchFrom)
                if not s then
                    return false, "не найден ингредиент " .. lang.localize(targetId) .. " в инвентаре черепахи"
                end
                local detail = turtle.getItemDetail(s)
                local take = math.min(need, detail.count)
                turtle.select(s)
                turtle.transferTo(i, take)
                need = need - take
                searchFrom = s + 1
            end
        end
    end
    turtle.select(1)
    return true
end

--- Разложить ингредиенты для shapeless рецепта (любые слоты 1-9).
-- Каждый ингредиент — в свой слот, количество = crafts * ing.count.
local function layoutShapeless(recipe, crafts)
    clearCraftingGrid()
    local slot = 1
    for _, ing in ipairs(recipe.ingredients or {}) do
        if slot > 9 then
            return false, "слишком много ингредиентов для shapeless (>9)"
        end
        local need = crafts * (ing.count or 1)
        if need > 64 then
            return false, "слишком много " .. lang.localize(ing.id) .. " (" .. need .. ">64) — уменьшите количество"
        end
        local searchFrom = 10
        while need > 0 do
            local s = findSlotWith(ing.id, searchFrom)
            if not s then
                return false, "не найден ингредиент " .. lang.localize(ing.id) .. " в инвентаре черепахи"
            end
            local detail = turtle.getItemDetail(s)
            local take = math.min(need, detail.count)
            turtle.select(s)
            turtle.transferTo(slot, take)
            need = need - take
            searchFrom = s + 1
        end
        slot = slot + 1
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
        return false, "нет рецепта"
    end
    if recipe.type == "machine" then
        return false, "машинные рецепты обрабатывает Core, не воркер"
    end
    local output = recipe.output or 1
    local crafts = math.ceil(count / output)
    self.crafting = true

    local t0 = os.clock()

    -- Раскладываем
    local ok, err
    if recipe.type == "shaped" then
        ok, err = layoutShaped(recipe, crafts)
    else
        ok, err = layoutShapeless(recipe, crafts)
    end
    if not ok then
        self.crafting = false
        return false, err
    end

    -- Крафтим (turtle.craft возвращает boolean, не число)
    turtle.select(1)
    local success = turtle.craft(crafts)
    local t1 = os.clock()
    self.crafting = false
    if not success then
        return false, "turtle.craft вернул 0 — неверная раскладка или не хватает"
    end
    local elapsed = t1 - t0
    if elapsed < 0 then elapsed = 0 end
    return true, crafts * output, elapsed, crafts
end

--- Главный цикл воркера.
function worker:run()
    util.ok("Воркер #" .. os.getComputerID() .. " запущен, жду задачи")
    -- Первичный HELLO (broadcast) — Core подхватит
    self:sayHello(nil)
    -- Периодический heartbeat
    local lastBeat = 0
    while true do
        local senderId, msg = net.receive(5)
        if senderId and msg then
            if msg.type == net.MSG.DISCOVER then
                self.core_id = (msg.payload and msg.payload.core) or senderId
                self:sayHello(senderId)
            elseif msg.type == net.MSG.CRAFT_REQUEST then
                local p = msg.payload or {}
                self.core_id = senderId
                util.info("Задача крафта: " .. tostring(p.recipe and p.recipe.id) .. " x" .. tostring(p.count))
                self:sendStatus(p.task_id, 0, "начинаю")
                local ok, res, elapsed, crafts = self:craft(p.recipe, p.count)
                if ok then
                    self:sendStatus(p.task_id, 100, "готово")
                    self:sendResult(p.task_id, true, {
                        task_id = p.task_id,
                        success = true,
                        count = res,
                        elapsed = elapsed,
                        crafts = crafts,
                    })
                    util.ok("Готово: " .. res .. " шт за " .. string.format("%.2f", elapsed or 0) .. "с")
                else
                    self:sendResult(p.task_id, false, {
                        task_id = p.task_id,
                        success = false,
                        error = res,
                    })
                    util.err("Ошибка крафта: " .. tostring(res))
                end
            elseif msg.type == net.MSG.PING then
                net.send(senderId, net.MSG.PONG, { id = os.getComputerID() })
            elseif msg.type == net.MSG.CRAFT_CANCEL then
                -- Отмена — не реализована полноценно, просто лог
                util.warn("Получен cancel для задачи " .. tostring(msg.payload and msg.payload.task_id))
            end
        end
        -- Heartbeat Core раз в 10 сек
        if self.core_id and os.clock() - lastBeat > 10 then
            net.send(self.core_id, net.MSG.HEARTBEAT, { id = os.getComputerID(), busy = self.crafting })
            lastBeat = os.clock()
        end
    end
end

return worker
