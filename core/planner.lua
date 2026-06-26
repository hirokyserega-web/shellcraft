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
function planner.buildTree(id, count, recipes, storage, fluids, depth, allocated)
    depth = depth or 0
    allocated = allocated or {}
    if depth > 32 then
        return { id = id, count = count, has_recipe = false, error = "Dependency too deep" }
    end
    
    local isFluid = (type(id) == "string" and id:sub(1, 6) == "fluid:")
    local kind = isFluid and "fluid" or "item"
    local actualId = isFluid and id:sub(7) or id
    
    local node = { id = id, count = count, kind = kind, children = {} }
    local recipe = recipes:get(id)

    local available = 0
    if isFluid then
        available = fluids and fluids:count(actualId) or 0
    else
        available = storage and storage:count(id) or 0
    end
    
    local alreadyAllocated = allocated[id] or 0
    local remaining = math.max(0, available - alreadyAllocated)
    local taken = math.min(count, remaining)
    allocated[id] = alreadyAllocated + taken
    local deficit = count - taken

    if recipe then
        if deficit == 0 then
            node.has_recipe = false
            node.needed = count
            node.available = available
            node.missing = 0
        else
            node.has_recipe = true
            node.recipe = recipe
            node.count = deficit
            node.crafts = recipes.craftsNeeded(recipe, deficit)
            node.output = recipe.output or 1
            
            -- Ingredients (items)
            local ings = recipes.ingredientsFor(recipe, deficit)
            for _, ing in ipairs(ings) do
                local child = planner.buildTree(ing.id, ing.count, recipes, storage, fluids, depth + 1, allocated)
                table.insert(node.children, child)
            end
            
            -- Fluids (liquids)
            local fls = recipes.fluidsFor(recipe, deficit)
            for _, fl in ipairs(fls) do
                local fluidNodeId = "fluid:" .. fl.fluid
                local child = planner.buildTree(fluidNodeId, fl.mb, recipes, storage, fluids, depth + 1, allocated)
                table.insert(node.children, child)
            end
        end
    else
        -- Base resource: no recipe.
        node.has_recipe = false
        node.needed = count
        node.available = available
        node.missing = deficit
    end
    return node
end

--- Суммарная потребность в базовых ресурсах (bill of materials).
-- @param node дерево из buildTree
-- @return таблица { items = { [id] = count }, fluids = { [fluid] = mb } }
function planner.bom(node)
    local items = {}
    local fluids = {}
    local function traverse(n)
        if not n then return end
        if n.has_recipe then
            for _, child in ipairs(n.children) do
                traverse(child)
            end
        else
            if n.kind == "fluid" then
                local fName = n.id:sub(7)
                fluids[fName] = (fluids[fName] or 0) + n.count
            else
                items[n.id] = (items[n.id] or 0) + n.count
            end
        end
    end
    traverse(node)
    return { items = items, fluids = fluids }
end

--- Суммарная потребность в базовых ресурсах как ОТСОРТИРОВАННЫЙ МАССИВ.
-- Удобно для UI (отображение списка потребности).
-- @param node дерево из buildTree
-- @return таблица { items = { {id, count}, ... }, fluids = { {fluid, mb}, ... } }
function planner.calculateBOM(node)
    local map = planner.bom(node)
    
    local items = {}
    for id, count in pairs(map.items) do
        table.insert(items, { id = id, count = count })
    end
    table.sort(items, function(a, b) return a.id < b.id end)
    
    local fluids = {}
    for fluid, mb in pairs(map.fluids) do
        table.insert(fluids, { fluid = fluid, mb = mb })
    end
    table.sort(fluids, function(a, b) return a.fluid < b.fluid end)
    
    return { items = items, fluids = fluids }
end

--- Проверить наличие базовых ресурсов по bom.
-- @param bom таблица из bom()
-- @param storage объект storage
-- @param fluids объект fluids
-- @return { items = { [id] = { needed, available, missing } }, fluids = { [fluid] = { needed, available, missing } } }
function planner.checkAvailability(bom, storage, fluids)
    local itemAvail = {}
    for id, count in pairs(bom.items) do
        local available = storage and storage:count(id) or 0
        itemAvail[id] = {
            needed = count,
            available = available,
            missing = math.max(0, count - available),
        }
    end
    
    local fluidAvail = {}
    for fluid, mb in pairs(bom.fluids) do
        local available = fluids and fluids:count(fluid) or 0
        fluidAvail[fluid] = {
            needed = mb,
            available = available,
            missing = math.max(0, mb - available),
        }
    end
    
    return { items = itemAvail, fluids = fluidAvail }
end

--- Можно ли скрафтить (хватает ли базовых ресурсов)?
function planner.canCraft(node, storage, fluids)
    local bom = planner.bom(node)
    local avail = planner.checkAvailability(bom, storage, fluids)
    for _, info in pairs(avail.items) do
        if info.missing > 0 then return false, avail end
    end
    for _, info in pairs(avail.fluids) do
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

----------------------------------------------------------------
-- ОЦЕНКА ВРЕМЕНИ КРАФТА
----------------------------------------------------------------

--- Дефолтное время на 1 операцию (сек) если avgTime не измерен.
planner.DEFAULT_TIME = { crafting = 1.0, machine = 10.0 }

--- Время на 1 операцию для узла (через recipes.avgTimeFor).
-- @return secondsPerOp, approximate
local function nodeTimePerOp(n, recipes)
    if n.recipe and recipes then
        return recipes.avgTimeFor(n.recipe)
    end
    return planner.DEFAULT_TIME.crafting, true
end

--- Глубина узла от листьев (лист-базовый-ресурс = 0, корень = max).
local function nodeLevel(n)
    if not n or not n.has_recipe then return 0 end
    local max = 0
    for _, c in ipairs(n.children) do
        local l = nodeLevel(c)
        if l > max then max = l end
    end
    return max + 1
end

--- Человекочитаемая длительность.
-- @param sec секунды
-- @param approximate пометить как приблизительную
function planner.formatDuration(seconds, approx)
    local s = math.floor(seconds or 0)
    if s < 0 then s = 0 end
    local prefix = approx and "~" or ""
    if s < 60 then
        return prefix .. s .. "s"
    else
        local m = math.floor(s / 60)
        local remainingSec = s % 60
        if remainingSec > 0 then
            return prefix .. m .. "m " .. remainingSec .. "s"
        else
            return prefix .. m .. "m"
        end
    end
end

--- Оценка общего времени крафта по дереву зависимостей.
-- Независимые задачи (один уровень дерева) считаются ПАРАЛЛЕЛЬНО — общая
-- работа уровня делится на число доступных исполнителей (воркеров+машин).
-- Зависимые уровни суммируются последовательно (критический путь).
-- @param node дерево из buildTree
-- @param numWorkers число параллельных исполнителей (>=1)
-- @param recipes объект recipes (для avgTimeFor)
-- @return totalSec, approximate(bool), levels(массив {level,time,work,tasks,parallel})
function planner.estimateTime(node, numWorkers, recipes)
    numWorkers = math.max(1, numWorkers or 1)
    -- Группируем узлы-с-рецептом по уровню.
    local byLevel = {}
    local function visit(n)
        if not n or not n.has_recipe then return end
        local lvl = nodeLevel(n)
        if not byLevel[lvl] then byLevel[lvl] = {} end
        byLevel[lvl][#byLevel[lvl] + 1] = n
        for _, c in ipairs(n.children) do visit(c) end
    end
    visit(node)

    local maxLvl = 0
    for lvl in pairs(byLevel) do
        if lvl > maxLvl then maxLvl = lvl end
    end

    local total = 0
    local approximate = false
    local levels = {}
    -- Считаем снизу вверх: уровень 1 (ближайшие к листьям) крафтится первым.
    for lvl = 1, maxLvl do
        local nodes = byLevel[lvl] or {}
        local work = 0
        local approx = false
        for _, n in ipairs(nodes) do
            local perOp, ap = nodeTimePerOp(n, recipes)
            local crafts = n.crafts or 1
            work = work + perOp * crafts
            if ap then approx = true end
        end
        local parallel = math.min(numWorkers, math.max(1, #nodes))
        local lvlTime = work / parallel
        total = total + lvlTime
        if approx then approximate = true end
        levels[#levels + 1] = {
            level = lvl, time = lvlTime, work = work,
            tasks = #nodes, parallel = parallel,
        }
    end
    return total, approximate, levels
end

return planner
