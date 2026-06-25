-- core/planner.lua
-- Построение дерева зависимостей, расчёт потребности, проверка наличия.
-- Рекурсивный крафт: если промежуточного предмета нет — крафтим его сначала.

local planner = {}

--- Построить дерево зависимостей.
-- @param id ID предмета
-- @param count сколько нужно
-- @param recipes объект recipes
-- @param storage объект storage (опц., для проверки наличия базовых)
-- @param depth защита от зацикливания
-- @return node = { id, count, has_recipe, recipe, children, needed, available, missing, crafts }
function planner.buildTree(id, count, recipes, storage, depth)
    depth = depth or 0
    if depth > 32 then
        return { id = id, count = count, has_recipe = false, error = "Слишком глубокая зависимость" }
    end
    local node = { id = id, count = count, children = {} }
    local recipe = recipes:get(id)
    if recipe then
        node.has_recipe = true
        node.recipe = recipe
        node.crafts = recipes.craftsNeeded(recipe, count)
        node.output = recipe.output or 1
        local ings = recipes.ingredientsFor(recipe, count)
        for _, ing in ipairs(ings) do
            local child = planner.buildTree(ing.id, ing.count, recipes, storage, depth + 1)
            table.insert(node.children, child)
        end
    else
        -- Базовый ресурс: нет рецепта.
        node.has_recipe = false
        node.needed = count
        if storage then
            node.available = storage:count(id) or 0
            node.missing = math.max(0, count - node.available)
        else
            node.available = 0
            node.missing = count
        end
    end
    return node
end

--- Суммарная потребность в базовых ресурсах (bill of materials).
-- @param node дерево из buildTree
-- @return таблица { [id] = total_count }
function planner.bom(node)
    local result = {}
    local function traverse(n)
        if not n then return end
        if n.has_recipe then
            for _, child in ipairs(n.children) do
                traverse(child)
            end
        else
            result[n.id] = (result[n.id] or 0) + n.count
        end
    end
    traverse(node)
    return result
end

--- Суммарная потребность в базовых ресурсах как ОТСОРТИРОВАННЫЙ МАССИВ.
-- Удобно для UI (отображение списка потребности).
-- @param node дерево из buildTree
-- @return массив { { id = ..., count = ... } }, отсортированный по id
function planner.calculateBOM(node)
    local map = planner.bom(node)
    local arr = {}
    for id, count in pairs(map) do
        table.insert(arr, { id = id, count = count })
    end
    table.sort(arr, function(a, b) return a.id < b.id end)
    return arr
end

--- Проверить наличие базовых ресурсов по bom.
-- @param bom таблица из bom()
-- @param storage объект storage
-- @return { [id] = { needed, available, missing } }
function planner.checkAvailability(bom, storage)
    local result = {}
    for id, count in pairs(bom) do
        local available = storage:count(id) or 0
        result[id] = {
            needed = count,
            available = available,
            missing = math.max(0, count - available),
        }
    end
    return result
end

--- Можно ли скрафтить (хватает ли базовых ресурсов)?
function planner.canCraft(node, storage)
    local bom = planner.bom(node)
    local avail = planner.checkAvailability(bom, storage)
    for _, info in pairs(avail) do
        if info.missing > 0 then return false, avail end
    end
    return true, avail
end

--- Упорядоченный список крафта (от листьев к корню).
-- Каждый шаг: { id, count, recipe, crafts }.
-- @return массив шагов в порядке выполнения (сначала промежуточные).
function planner.craftSteps(node)
    local steps = {}
    local function traverse(n)
        if not n then return end
        if n.has_recipe then
            -- Сначала крафтим детей
            for _, child in ipairs(n.children) do
                traverse(child)
            end
            -- Потом сам узел
            table.insert(steps, {
                id = n.id,
                count = n.count,
                recipe = n.recipe,
                crafts = n.crafts,
            })
        end
    end
    traverse(node)
    return steps
end

--- Человекочитаемое описание дерева.
function planner.describe(node, indent)
    indent = indent or ""
    local lines = {}
    local name = util.formatId(node.id)
    if node.has_recipe then
        table.insert(lines, indent .. "• " .. name .. " x" .. node.count .. " (крафт, " .. node.crafts .. " шт)")
        for _, child in ipairs(node.children) do
            local sub = planner.describe(child, indent .. "  ")
            for _, l in ipairs(sub) do table.insert(lines, l) end
        end
    else
        local miss = node.missing or 0
        local status = ""
        if miss > 0 then
            status = "  [НЕ ХВАТАЕТ " .. miss .. "]"
        else
            status = "  [есть " .. node.available .. "]"
        end
        table.insert(lines, indent .. "○ " .. name .. " x" .. node.count .. status)
    end
    return lines
end

return planner
