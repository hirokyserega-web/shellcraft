-- core/recipes.lua
-- Хранение, загрузка, сохранение рецептов. Режим обучения.
--
-- Формат рецепта:
--   {
--     id       = "minecraft:oak_planks",   -- ID результата
--     name     = "Дубовые доски",           -- русское имя (опц.)
--     type     = "shaped" | "shapeless" | "machine",
--     output   = 4,                          -- сколько выходит за 1 крафт
--     pattern  = {{id,id,nil},{id,nil,nil},{nil,nil,nil}},  -- для shaped
--     ingredients = {{id="minecraft:oak_log", count=1}},    -- для shapeless
--     machine  = "minecraft:furnace",        -- для machine
--     input    = {{id, count}},              -- для machine
--   }

local recipes = {}
recipes.__index = recipes

function recipes.new(path)
    local self = setmetatable({}, recipes)
    self.path = path or "recipes.dat"
    self.list = {}            -- { [id] = recipe }
    self:load()
    return self
end

--- Загрузить из файла.
function recipes:load()
    if not fs.exists(self.path) then self.list = {}; return end
    local f = fs.open(self.path, "r")
    if not f then return end
    local content = f.readAll()
    f.close()
    local data = textutils.unserialize(content)
    if type(data) == "table" then
        self.list = data
    end
end

--- Сохранить в файл.
function recipes:save()
    local f = fs.open(self.path, "w")
    if not f then return false end
    f.write(textutils.serialize(self.list))
    f.close()
    return true
end

--- Добавить/обновить рецепт.
-- Статистику времени (avgTime, timingCount) переносим из старой версии рецепта:
-- обновление раскладки не обнуляет накопленные замеры.
function recipes:add(recipe)
    if not recipe or not recipe.id then return false end
    local old = self.list[recipe.id]
    recipe.output = recipe.output or 1
    recipe.type = recipe.type or "shaped"
    if old and old.avgTime and not recipe.avgTime then
        recipe.avgTime = old.avgTime
        recipe.samples = old.samples
        recipe.timingCount = old.timingCount
    end
    self.list[recipe.id] = recipe
    self:save()
    return true
end

--- Удалить рецепт.
function recipes:remove(id)
    if self.list[id] then
        self.list[id] = nil
        self:save()
        return true
    end
    return false
end

--- Получить рецепт по id.
function recipes:get(id)
    return self.list[id]
end

--- Список всех рецептов (массив).
function recipes:all()
    local arr = {}
    for id, r in pairs(self.list) do
        table.insert(arr, r)
    end
    table.sort(arr, function(a, b) return (a.id or "") < (b.id or "") end)
    return arr
end

--- Есть ли рецепт для id?
function recipes:has(id)
    return self.list[id] ~= nil
end

--- Нормализованный список ингредиентов рецепта.
-- Возвращает массив { {id=..., count=...}, ... }.
function recipes.ingredientsOf(recipe)
    local result = {}
    local agg = {}  -- [id] = count
    if recipe.type == "shaped" and recipe.pattern then
        for r = 1, 3 do
            local row = recipe.pattern[r]
            if row then
                for c = 1, 3 do
                    local cell = row[c]
                    if cell then
                        if type(cell) == "table" and cell.id then
                            agg[cell.id] = (agg[cell.id] or 0) + (cell.count or 1)
                        elseif type(cell) == "string" then
                            agg[cell] = (agg[cell] or 0) + 1
                        end
                    end
                end
            end
        end
    elseif recipe.type == "shapeless" and recipe.ingredients then
        for _, ing in ipairs(recipe.ingredients) do
            local iid = ing.id or ing
            agg[iid] = (agg[iid] or 0) + (ing.count or 1)
        end
    elseif recipe.type == "machine" and recipe.input then
        for _, ing in ipairs(recipe.input) do
            local iid = ing.id or ing
            agg[iid] = (agg[iid] or 0) + (ing.count or 1)
        end
    end
    for id, count in pairs(agg) do
        table.insert(result, { id = id, count = count })
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

--- Сколько крафтов нужно для wantCount штук результата.
function recipes.craftsNeeded(recipe, wantCount)
    return math.ceil(wantCount / (recipe.output or 1))
end

--- Полная потребность в ингредиентах для wantCount штук результата.
-- Возвращает массив { {id, count} }.
function recipes.ingredientsFor(recipe, wantCount)
    local crafts = recipes.craftsNeeded(recipe, wantCount)
    local ings = recipes.ingredientsOf(recipe)
    local result = {}
    for _, ing in ipairs(ings) do
        table.insert(result, { id = ing.id, count = ing.count * crafts })
    end
    return result, crafts
end

--- Построить рецепт из раскладки черепахи (слоты 1..9).
-- @param slots таблица { [1..9] = {id, count} } (только занятые)
-- @param resultId ID результата
-- @param resultCount сколько вышло
-- @param resultName русское имя (опц.)
-- @return рецепт
function recipes.buildFromTurtle(slots, resultId, resultCount, resultName)
    local pattern = {}
    for row = 0, 2 do
        local r = {}
        for col = 1, 3 do
            local idx = row * 3 + col
            local s = slots[idx]
            if s and s.id then
                r[col] = { id = s.id, count = s.count or 1 }
            else
                r[col] = nil
            end
        end
        table.insert(pattern, r)
    end
    return {
        id = resultId,
        name = resultName,
        type = "shaped",
        output = resultCount or 1,
        pattern = pattern,
    }
end



--- Обучить рецепт из текущей раскладки черепахи (слоты 1..9).
-- 1) читает слоты 1..9 (запоминает pattern),
-- 2) делает turtle.craft(1),
-- 3) находит результат (предмет, которого не было в слотах),
-- 4) строит и сохраняет рецепт.
-- @return true, recipe | false, ошибка
function recipes:learnFromTurtle()
    if not turtle then
        return false, "learning is only available on a turtle"
    end
    local GRID = {1, 2, 3, 5, 6, 7, 9, 10, 11}
    local slots = {}
    for i = 1, 9 do
        local slot = GRID[i]
        local ok, det = pcall(turtle.getItemDetail, slot)
        if ok and det and det.name then
            slots[i] = { id = det.name, count = det.count, displayName = det.displayName }
        end
    end
    local hasItems = false
    for _ in pairs(slots) do hasItems = true; break end
    if not hasItems then
        return false, "slots 1-9 are empty - place items like in a crafting table"
    end
    local snapshot = {}
    for i = 1, 16 do
        local ok, det = pcall(turtle.getItemDetail, i)
        if ok and det and det.name then
            snapshot[i] = { name = det.name, count = det.count }
        end
    end
    turtle.select(1)
    local ok = turtle.craft(1)
    if not ok then
        return false, "crafting failed (invalid layout?)"
    end
    local resultId, resultCount, resultName
    for i = 1, 16 do
        local ok2, det = pcall(turtle.getItemDetail, i)
        if ok2 and det and det.name then
            local snap = snapshot[i]
            local isNew = (not snap) or (snap.name ~= det.name)
            if isNew then
                resultId = det.name
                resultCount = det.count
                resultName = det.displayName
                break
            end
        end
    end
    if not resultId then
        return false, "could not determine crafting result"
    end
    local recipe = recipes.buildFromTurtle(slots, resultId, resultCount, resultName)
    self:add(recipe)
    return true, recipe
end

--- Обучить рецепт из подключенного хранилища (сундук/бочка).
-- Первые 3 ряда (слоты 1-27) используются для 3x3 сетки крафта.
-- Любой предмет вне колонок сетки крафта (или ниже 3 ряда) считается результатом.
-- @param invName имя периферии хранилища
-- @return true, recipe | false, ошибка
function recipes:learnFromStorage(invName)
    local p = peripheral.wrap(invName)
    if not p
       or type(p.list) ~= "function"
       or type(p.size) ~= "function"
       or type(p.pushItems) ~= "function"
       or type(p.pullItems) ~= "function" then
        return false, "Storage chest is not reachable as an inventory. Connect the storage peripheral to the wired network and enable it."
    end
    
    local size = p.size()
    local inventoryList = p.list()
    
    -- Для маленьких сундуков (до 27 слотов): слоты 1-9 = 3x3 сетка, слот 10+ = результат
    -- Для больших (54 слота, двойной сундук): 9-колоночная раскладка как раньше
    local pattern = {}
    for r = 1, 3 do
        pattern[r] = {}
        for c = 1, 3 do
            pattern[r][c] = nil
        end
    end
    
    local outputSlot = nil
    local outputItem = nil
    local hasRecipeItems = false
    
    if size < 27 then
        -- Simple mode: slots 1-9 = 3x3 grid
        for slot = 1, math.min(9, size) do
            local item = inventoryList[slot]
            if item then
                local row = math.floor((slot - 1) / 3) + 1
                local col = (slot - 1) % 3 + 1
                pattern[row][col] = { id = item.name, count = item.count or 1 }
                hasRecipeItems = true
            end
        end
        -- Результат ищем в слотах 10+
        for slot = 10, size do
            local item = inventoryList[slot]
            if item and not outputSlot then
                outputSlot = slot
                outputItem = item
            end
        end
    else
        -- Режим 9-колоночного сундука (двойной сундук):
        -- Первые 3 ряда по 9 колонок, крайние левые 3 колонки = сетка
        local colMin = 9
        for slot = 1, math.min(27, size) do
            local item = inventoryList[slot]
            if item then
                local col = (slot - 1) % 9 + 1
                if col < colMin then colMin = col end
                hasRecipeItems = true
            end
        end
        if colMin > 7 then colMin = 7 end
        
        local gridCols = {
            [colMin] = 1,
            [colMin + 1] = 2,
            [colMin + 2] = 3
        }
        
        for slot = 1, size do
            local item = inventoryList[slot]
            if item then
                local row = math.floor((slot - 1) / 9) + 1
                local col = (slot - 1) % 9 + 1
                
                local isRecipeSlot = (row <= 3) and gridCols[col]
                if isRecipeSlot then
                    local gridCol = gridCols[col]
                    pattern[row][gridCol] = { id = item.name, count = item.count or 1 }
                else
                    if not outputSlot then
                        outputSlot = slot
                        outputItem = item
                    end
                end
            end
        end
    end
    
    if not hasRecipeItems then
        return false, "no items in crafting grid (place items in slots 1-9)"
    end
    
    if not outputSlot or not outputItem then
        return false, "no output item found (place result in slot 10+)"
    end
    
    local displayName = nil
    if p.getItemDetail then
        local ok, detail = pcall(p.getItemDetail, outputSlot)
        if ok and detail and detail.displayName then
            displayName = detail.displayName
        end
    end
    
    local recipe = {
        id = outputItem.name,
        name = displayName or outputItem.name,
        type = "shaped",
        output = outputItem.count or 1,
        pattern = pattern,
    }
    
    self:add(recipe)
    return true, recipe
end

--- Активное обучение рецепта для печи/механизма.
-- Перемещает 1 предмет из хранилища в механизм, запускает переработку,
-- забирает результат обратно в хранилище и сохраняет рецепт.
-- @param storageName имя сундука/бочки с исходным сырьем
-- @param machineName имя механизма (печки)
-- @return true, recipe | false, ошибка
function recipes:activeLearnMachine(storageName, machineName)
    local pStorage = peripheral.wrap(storageName)
    if not pStorage
       or type(pStorage.list) ~= "function"
       or type(pStorage.size) ~= "function"
       or type(pStorage.pushItems) ~= "function"
       or type(pStorage.pullItems) ~= "function" then
        return false, "Storage chest is not reachable as an inventory."
    end
    local pMachine = peripheral.wrap(machineName)
    if not pMachine
       or type(pMachine.list) ~= "function"
       or type(pMachine.size) ~= "function"
       or type(pMachine.pushItems) ~= "function"
       or type(pMachine.pullItems) ~= "function" then
        return false, "Machine is not reachable as an inventory."
    end
    
    local storageList = pStorage.list()
    local inputSlot = nil
    local inputItem = nil
    for slot, item in pairs(storageList) do
        if item then
            inputSlot = slot
            inputItem = item
            break
        end
    end
    if not inputSlot then
        return false, "storage chest is empty (place the item to process inside it)"
    end
    
    -- Определяем слоты печи
    local sz = pMachine.size()
    local mSlots = { input = 1, output = 3 }
    if sz == 3 then
        mSlots = { input = 1, output = 3 }
    elseif sz and sz > 1 then
        mSlots = { input = 1, output = sz }
    end
    
    -- Очищаем слоты печи
    local machineList = pMachine.list()
    if machineList[mSlots.output] then
        pMachine.pushItems(storageName, mSlots.output)
    end
    if machineList[mSlots.input] then
        pMachine.pushItems(storageName, mSlots.input)
    end
    
    -- Перемещаем 1 сырье
    local pushed = pStorage.pushItems(machineName, inputSlot, 1, mSlots.input)
    if pushed == 0 then
        return false, "could not push item to machine"
    end
    
    local outputItemDetail = nil
    local deadline = os.clock() + 60
    while os.clock() < deadline do
        if pMachine.list then
            local ok, items = pcall(pMachine.list)
            if ok and items and items[mSlots.output] then
                outputItemDetail = items[mSlots.output]
                if pMachine.getItemDetail then
                    local ok2, det = pcall(pMachine.getItemDetail, mSlots.output)
                    if ok2 and det and det.displayName then
                        outputItemDetail.displayName = det.displayName
                    end
                end
                break
            end
        end
        os.sleep(0.5)
    end
    
    if not outputItemDetail then
        pMachine.pushItems(storageName, mSlots.input) -- возвращаем назад сырье
        return false, "timeout waiting for machine processing"
    end
    
    -- Забираем результат в сундук
    pMachine.pushItems(storageName, mSlots.output)
    
    local mType = peripheral.getType(machineName)
    local recipe = {
        id = outputItemDetail.name,
        name = outputItemDetail.displayName or outputItemDetail.name,
        type = "machine",
        machine = mType,
        input = { { id = inputItem.name, count = 1 } },
        output = outputItemDetail.count or 1,
    }
    self:add(recipe)
    return true, recipe
end

--- Активное обучение крафтового рецепта на удаленной черепахе.
-- Читает 3x3 раскладку из хранилища, очищает черепаху,
-- раскладывает ингредиенты в черепаху, посылает Rednet-команду скрафтить,
-- забирает результат и остатки назад в хранилище и сохраняет рецепт.
-- @param storageName имя сундука/бочки с ингредиентами
-- @param workerId ID черепахи-воркера
-- @param dispatcherObj объект dispatcher
-- @return true, recipe | false, ошибка
function recipes:activeLearnCraft(storageName, workerId, dispatcherObj)
    local pStorage = peripheral.wrap(storageName)
    if not pStorage
       or type(pStorage.list) ~= "function"
       or type(pStorage.size) ~= "function"
       or type(pStorage.pushItems) ~= "function"
       or type(pStorage.pullItems) ~= "function" then
        return false, "Storage chest is not reachable as an inventory."
    end
    
    local turtleName = dispatcherObj:workerName(workerId)
    if not turtleName then
        return false, "turtle worker is not attached to the wired modem network"
    end
    local pTurtle = peripheral.wrap(turtleName)
    if not pTurtle then
       return false, "Turtle #"..tostring(workerId).." is not reachable. Connect the turtle to a WIRED modem and ENABLE it (right-click the modem, it must glow red)."
    end
    
    -- 1. Читаем раскладку из сундука
    local storageSize = pStorage.size()
    local storageList = pStorage.list()
    
    local pattern = {}
    local transfers = {}
    local GRID = {1, 2, 3, 5, 6, 7, 9, 10, 11}
    
    for r = 1, 3 do
        pattern[r] = {}
        for c = 1, 3 do
            pattern[r][c] = nil
        end
    end
    
    local hasRecipeItems = false
    
    if storageSize < 27 then
        -- Simple mode: slots 1-9 = 3x3 grid
        for slot = 1, math.min(9, storageSize) do
            local item = storageList[slot]
            if item then
                local row = math.floor((slot - 1) / 3) + 1
                local col = (slot - 1) % 3 + 1
                pattern[row][col] = { id = item.name, count = 1 }
                local gridIdx = (row - 1) * 3 + col
                local turtleSlot = GRID[gridIdx]
                table.insert(transfers, { srcSlot = slot, dstSlot = turtleSlot })
                hasRecipeItems = true
            end
        end
    else
        -- Режим 9-колоночного двойного сундука
        local colMin = 9
        for slot = 1, math.min(27, storageSize) do
            local item = storageList[slot]
            if item then
                local col = (slot - 1) % 9 + 1
                if col < colMin then colMin = col end
                hasRecipeItems = true
            end
        end
        if colMin > 7 then colMin = 7 end
        
        local gridCols = {
            [colMin] = 1,
            [colMin + 1] = 2,
            [colMin + 2] = 3
        }
        
        for slot = 1, math.min(27, storageSize) do
            local item = storageList[slot]
            if item then
                local row = math.floor((slot - 1) / 9) + 1
                local col = (slot - 1) % 9 + 1
                if gridCols[col] then
                    local gridCol = gridCols[col]
                    pattern[row][gridCol] = { id = item.name, count = 1 }
                    local gridIdx = (row - 1) * 3 + gridCol
                    local turtleSlot = GRID[gridIdx]
                    table.insert(transfers, { srcSlot = slot, dstSlot = turtleSlot })
                end
            end
        end
    end
    
    if not hasRecipeItems then
        return false, "no items in crafting grid (place items in slots 1-9)"
    end
    
    -- Очищаем черепаху в сундук
    for s = 1, 16 do
        pStorage.pullItems(turtleName, s)
    end
    
    -- Раскладываем ингредиенты
    for _, trans in ipairs(transfers) do
        local pushed = pStorage.pushItems(turtleName, trans.srcSlot, 1, trans.dstSlot)
        if pushed == 0 then
            -- Возврат в случае ошибки
            for s = 1, 16 do
                pStorage.pullItems(turtleName, s)
            end
            return false, "could not transfer ingredients to turtle slots"
        end
    end
    
    -- Посылаем запрос крафта по rednet
    local net = _G.net or require("lib.net")
    net.send(workerId, net.MSG.LEARN_CRAFT_REQUEST, {})
    
    -- Ждем ответа
    local responseMsg = nil
    local deadline = os.clock() + 15
    while os.clock() < deadline do
        local senderId, msg = net.receive(1)
        if senderId == workerId and msg.type == net.MSG.LEARN_CRAFT_RESPONSE then
            responseMsg = msg.payload
            break
        end
    end
    
    if not responseMsg then
        for s = 1, 16 do
            pStorage.pullItems(turtleName, s)
        end
        return false, "timeout waiting for turtle craft response"
    end
    
    if not responseMsg.success then
        for s = 1, 16 do
            pStorage.pullItems(turtleName, s)
        end
        return false, tostring(responseMsg.error)
    end
    
    -- Забираем все предметы (результат и остатки) назад в сундук
    for s = 1, 16 do
        pStorage.pullItems(turtleName, s)
    end
    
    local recipe = {
        id = responseMsg.name,
        name = responseMsg.displayName or responseMsg.name,
        type = "shaped",
        output = responseMsg.count or 1,
        pattern = pattern
    }
    self:add(recipe)
    return true, recipe
end

----------------------------------------------------------------
-- ВРЕМЯ КРАФТА
----------------------------------------------------------------

--- Оценка времени на 1 операцию (крафт/cycle) для рецепта.
-- Если реальных замеров нет — возвращает дефолт по типу + approximate=true.
-- @return secondsPerOp, approximate(bool)
function recipes.avgTimeFor(recipe)
    if not recipe then return 1.0, true end
    if recipe.avgTime and recipe.avgTime > 0 then
        return recipe.avgTime, false
    end
    local def = (recipe.type == "machine") and 10.0 or 1.0
    return def, true
end

--- Обновить скользящее среднее времени на 1 операцию.
-- @param id ID рецепта
-- @param perOpSec время на 1 крафт/cycle (сек)
function recipes:updateTiming(id, perOpSec)
    local r = self.list[id]
    if not r or not perOpSec or perOpSec <= 0 then return end
    if not r.avgTime then
        r.avgTime = perOpSec
    else
        -- экспоненциальное скользящее среднее (alpha=0.3)
        r.avgTime = 0.3 * perOpSec + 0.7 * r.avgTime
    end
    r.samples = (r.samples or 0) + 1
    r.timingCount = r.samples
    self:save()
end

return recipes
