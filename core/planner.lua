-- core/planner.lua
-- Дерево зависимостей, расчёт потребности (BOM), проверка наличия.
-- Использует storage:available() (с учётом резерва) при наличии — это даёт
-- корректный учёт между одновременными заказами; иначе fallback на count().
--
-- buildTree аккумулирует выделение (allocated) ВНУТРИ дерева, а базовое наличие
-- берёт через availableFn, чтобы новый план не «видел» уже зарезервированное
-- другими заказами.

local planner = {}

--- Наличие предмета: предпочитаем available() (с учётом резерва), иначе count().
local function itemAvailable(storage, id)
    if not storage then return 0 end
    if type(storage.available) == "function" then
        return storage:available(id)
    end
    return storage:count(id)
end

--- Построить дерево зависимостей.
-- @param id ID предмета (или "fluid:<name>")
-- @param count сколько нужно
-- @param recipes объект recipes
-- @param storage объект storage
-- @param fluids объект fluids
-- @param depth защита от зацикливания
-- @param allocated аккумулятор уже выделенного наличия { [id] = qty }
-- @param stack множество id в текущей ветке (защита от циклов)
function planner.buildTree(id, count, recipes, storage, fluids, depth, allocated, stack)
    depth = depth or 0
    allocated = allocated or {}
    stack = stack or {}
    if depth > 32 then
        return { id = id, count = count, has_recipe = false, error = "Dependency too deep", missing = count, needed = count, available = 0 }
    end

    local isFluid = (type(id) == "string" and id:sub(1, 6) == "fluid:")
    local kind = isFluid and "fluid" or "item"
    local actualId = isFluid and id:sub(7) or id

    local node = { id = id, count = count, kind = kind, children = {} }
    local recipe = recipes:get(id)

    -- Защита от циклов: если id уже в текущей ветке — не углубляемся.
    if recipe and stack[id] then
        recipe = nil
        node.cycle = true
    end

    local available
    if isFluid then
        available = fluids and fluids:count(actualId) or 0
    else
        available = itemAvailable(storage, id)
    end

    local alreadyAllocated = allocated[id] or 0
    local remaining = math.max(0, available - alreadyAllocated)
    local taken = math.min(count, remaining)
    allocated[id] = alreadyAllocated + taken
    local deficit = count - taken

    if recipe and deficit > 0 then
        node.has_recipe = true
        node.recipe = recipe
        node.count = deficit
        node.crafts = recipes.craftsNeeded(recipe, deficit)
        node.output = recipe.output or 1

        stack[id] = true
        local ings = recipes.ingredientsFor(recipe, deficit)
        for _, ing in ipairs(ings) do
            local child = planner.buildTree(ing.id, ing.count, recipes, storage, fluids, depth + 1, allocated, stack)
            child.spec = ing.spec
            node.children[#node.children + 1] = child
        end
        local fls = recipes.fluidsFor(recipe, deficit)
        for _, fl in ipairs(fls) do
            local child = planner.buildTree("fluid:" .. fl.fluid, fl.mb, recipes, storage, fluids, depth + 1, allocated, stack)
            node.children[#node.children + 1] = child
        end
        stack[id] = nil
    else
        node.has_recipe = false
        node.needed = count
        node.available = available
        node.missing = deficit
    end
    return node
end

----------------------------------------------------------------
-- BOM (bill of materials)
----------------------------------------------------------------

function planner.bom(node)
    local items = {}
    local fluids = {}
    local function traverse(n)
        if not n then return end
        if n.has_recipe then
            for _, child in ipairs(n.children) do traverse(child) end
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

function planner.calculateBOM(node)
    local map = planner.bom(node)
    local items = {}
    for id, count in pairs(map.items) do
        items[#items + 1] = { id = id, count = count }
    end
    table.sort(items, function(a, b) return a.id < b.id end)
    local fluids = {}
    for fluid, mb in pairs(map.fluids) do
        fluids[#fluids + 1] = { fluid = fluid, mb = mb }
    end
    table.sort(fluids, function(a, b) return a.fluid < b.fluid end)
    return { items = items, fluids = fluids }
end

--- Проверка наличия базовых ресурсов по BOM (учёт резерва через available).
function planner.checkAvailability(bom, storage, fluids)
    local itemAvail = {}
    for id, count in pairs(bom.items) do
        local available = itemAvailable(storage, id)
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

----------------------------------------------------------------
-- ШАГИ КРАФТА
----------------------------------------------------------------

--- Упорядоченный список шагов крафта (от листьев к корню).
function planner.craftSteps(node)
    local steps = {}
    local function traverse(n)
        if not n then return end
        if n.has_recipe then
            for _, child in ipairs(n.children) do traverse(child) end
            steps[#steps + 1] = { id = n.id, count = n.count, recipe = n.recipe, crafts = n.crafts }
        end
    end
    traverse(node)
    return steps
end

function planner.describe(node, indent)
    indent = indent or ""
    local lines = {}
    local name = util.formatId(node.id)
    if node.has_recipe then
        lines[#lines + 1] = indent .. "• " .. name .. " x" .. node.count .. " (craft, " .. (node.crafts or 0) .. ")"
        for _, child in ipairs(node.children) do
            for _, l in ipairs(planner.describe(child, indent .. "  ")) do lines[#lines + 1] = l end
        end
    else
        local miss = node.missing or 0
        local status = miss > 0 and ("  [MISSING " .. miss .. "]") or ("  [have " .. (node.available or 0) .. "]")
        lines[#lines + 1] = indent .. "o " .. name .. " x" .. node.count .. status
    end
    return lines
end

----------------------------------------------------------------
-- ОЦЕНКА ВРЕМЕНИ
----------------------------------------------------------------

planner.DEFAULT_TIME = { crafting = 1.0, machine = 10.0 }

local function nodeTimePerOp(n, recipes)
    if n.recipe and recipes then
        return recipes.avgTimeFor(n.recipe)
    end
    return planner.DEFAULT_TIME.crafting, true
end

local function nodeLevel(n)
    if not n or not n.has_recipe then return 0 end
    local max = 0
    for _, c in ipairs(n.children) do
        local l = nodeLevel(c)
        if l > max then max = l end
    end
    return max + 1
end

function planner.formatDuration(seconds, approx)
    local s = math.floor(seconds or 0)
    if s < 0 then s = 0 end
    local prefix = approx and "~" or ""
    if s < 60 then
        return prefix .. s .. "s"
    end
    local m = math.floor(s / 60)
    local rem = s % 60
    if rem > 0 then
        return prefix .. m .. "m " .. rem .. "s"
    end
    return prefix .. m .. "m"
end

function planner.estimateTime(node, numWorkers, recipes)
    numWorkers = math.max(1, numWorkers or 1)
    local byLevel = {}
    local function visit(n)
        if not n or not n.has_recipe then return end
        local lvl = nodeLevel(n)
        byLevel[lvl] = byLevel[lvl] or {}
        byLevel[lvl][#byLevel[lvl] + 1] = n
        for _, c in ipairs(n.children) do visit(c) end
    end
    visit(node)

    local maxLvl = 0
    for lvl in pairs(byLevel) do if lvl > maxLvl then maxLvl = lvl end end

    local total = 0
    local approximate = false
    local levels = {}
    for lvl = 1, maxLvl do
        local nodes = byLevel[lvl] or {}
        local work = 0
        local approx = false
        for _, n in ipairs(nodes) do
            local perOp, ap = nodeTimePerOp(n, recipes)
            work = work + perOp * (n.crafts or 1)
            if ap then approx = true end
        end
        local parallel = math.min(numWorkers, math.max(1, #nodes))
        local lvlTime = work / parallel
        total = total + lvlTime
        if approx then approximate = true end
        levels[#levels + 1] = { level = lvl, time = lvlTime, work = work, tasks = #nodes, parallel = parallel }
    end
    return total, approximate, levels
end

return planner
