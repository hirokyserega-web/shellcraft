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
        for _, row in ipairs(recipe.pattern) do
            for _, cell in ipairs(row) do
                if cell and cell.id then
                    agg[cell.id] = (agg[cell.id] or 0) + (cell.count or 1)
                elseif cell and type(cell) == "string" then
                    agg[cell] = (agg[cell] or 0) + 1
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

--- Alias для UI (список рецептов как массив).
recipes.list = recipes.all

--- Обучить рецепт из текущей раскладки черепахи (слоты 1..9).
-- 1) читает слоты 1..9 (запоминает pattern),
-- 2) делает turtle.craft(1),
-- 3) находит результат (предмет, которого не было в слотах),
-- 4) строит и сохраняет рецепт.
-- @return true, recipe | false, ошибка
function recipes:learnFromTurtle()
    if not turtle then
        return false, "обучение доступно только на черепахе"
    end
    local slots = {}
    for i = 1, 9 do
        local ok, det = pcall(turtle.getItemDetail, i)
        if ok and det and det.name then
            slots[i] = { id = det.name, count = det.count, displayName = det.displayName }
        end
    end
    local hasItems = false
    for _ in pairs(slots) do hasItems = true; break end
    if not hasItems then
        return false, "слоты 1..9 пусты - положите предметы как в верстаке"
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
        return false, "крафт не удался (неверная раскладка?)"
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
        return false, "не удалось определить результат крафта"
    end
    local recipe = recipes.buildFromTurtle(slots, resultId, resultCount, resultName)
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
    r.timingCount = (r.timingCount or 0) + 1
    self:save()
end

return recipes
