-- core/recipes.lua
-- Хранение, загрузка, обучение рецептов + современная модель ингредиентов.
--
-- Формат ячейки ингредиента (cell) — любое из:
--   * "minecraft:oak_log"                          — простой id
--   * { id = "minecraft:oak_log", count = 1 }      — id + количество
--   * { tag = "minecraft:planks", count = 1 }      — тег (любой предмет тега)
--   * { variants = { id1, id2, ... }, count = 1 }  — любой из перечисленных
--   * { id = ..., nbt = ..., components = ... }     — точное совпадение по NBT
--
-- Рецепт:
--   {
--     id      = "minecraft:chest",
--     name    = "...",                  -- displayName (опц.)
--     type    = "shaped" | "shapeless" | "machine" | "station",
--     output  = 1,                       -- сколько ВЫХОДНЫХ предметов за 1 операцию
--     pattern = {{cell,cell,cell}, ...}, -- 3x3 для shaped
--     ingredients = { cell, cell, ... }, -- для shapeless
--     input   = { cell, ... },           -- для machine
--     schema_version = 2,
--   }
--
-- Семантика count: запрошенное число ВЫХОДНЫХ предметов. Число операций =
-- ceil(want / output). Последняя операция может дать небольшой излишек, но
-- суммарный выход всегда >= запрошенного.

local itemmatch = require("lib.itemmatch")

local recipes = {}
recipes.__index = recipes

recipes.SCHEMA_VERSION = 2

local GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
recipes.GRID = GRID

function recipes.new(path)
    local self = setmetatable({}, recipes)
    self.path = path or "recipes.dat"
    self.list = {}
    self:load()
    return self
end

----------------------------------------------------------------
-- НОРМАЛИЗАЦИЯ / МИГРАЦИЯ
----------------------------------------------------------------

--- Привести ячейку к каноническому виду (или nil для пустой).
function recipes.normalizeCell(cell)
    if cell == nil then return nil end
    if type(cell) == "string" then
        if cell == "" then return nil end
        if cell:sub(1, 1) == "#" then
            return { tag = cell:sub(2), count = 1 }
        end
        return { id = cell, count = 1 }
    end
    if type(cell) ~= "table" then
        return { id = tostring(cell), count = 1 }
    end
    local out = { count = cell.count or 1 }
    if cell.variants then
        out.variants = {}
        for _, v in ipairs(cell.variants) do
            local nv = recipes.normalizeCell(v)
            if nv then out.variants[#out.variants + 1] = nv end
        end
    end
    if cell.tag then out.tag = cell.tag end
    if cell.id or cell.name then out.id = cell.id or cell.name end
    if cell.nbt ~= nil then out.nbt = cell.nbt end
    if cell.components ~= nil then out.components = cell.components end
    if cell.any then out.any = true end
    if not (out.id or out.tag or out.variants or out.any) then
        return nil
    end
    return out
end

--- Миграция одного рецепта к актуальной схеме (на месте, возвращает рецепт).
function recipes.migrate(r)
    if type(r) ~= "table" then return r end
    r.type = r.type or "shaped"
    r.output = r.output or 1
    if r.type == "shaped" and r.pattern then
        for row = 1, 3 do
            local prow = r.pattern[row]
            if prow then
                for col = 1, 3 do
                    prow[col] = recipes.normalizeCell(prow[col])
                end
            end
        end
    elseif r.type == "shapeless" and r.ingredients then
        local norm = {}
        for _, ing in ipairs(r.ingredients) do
            local c = recipes.normalizeCell(ing)
            if c then norm[#norm + 1] = c end
        end
        r.ingredients = norm
    elseif (r.type == "machine" or r.type == "station") then
        if r.input then
            local norm = {}
            for _, ing in ipairs(r.input) do
                local c = recipes.normalizeCell(ing)
                if c then norm[#norm + 1] = c end
            end
            r.input = norm
        end
        if r.itemInput then
            local norm = {}
            for _, ing in ipairs(r.itemInput) do
                local c = recipes.normalizeCell(ing)
                if c then norm[#norm + 1] = c end
            end
            r.itemInput = norm
        end
    end
    r.schema_version = recipes.SCHEMA_VERSION
    return r
end

function recipes:load()
    if not fs.exists(self.path) then self.list = {}; return end
    local f = fs.open(self.path, "r")
    if not f then return end
    local content = f.readAll()
    f.close()
    local data = textutils.unserialize(content)
    if type(data) ~= "table" then self.list = {}; return end
    local migrated = false
    for id, r in pairs(data) do
        if type(r) == "table" then
            if (r.schema_version or 1) < recipes.SCHEMA_VERSION then
                recipes.migrate(r)
                migrated = true
            end
        end
    end
    self.list = data
    if migrated then self:save() end
end

function recipes:save()
    local f = fs.open(self.path, "w")
    if not f then return false end
    f.write(textutils.serialize(self.list))
    f.close()
    return true
end

function recipes:add(recipe)
    if not recipe or not recipe.id then return false end
    local old = self.list[recipe.id]
    recipe.output = recipe.output or 1
    recipe.type = recipe.type or "shaped"
    recipes.migrate(recipe)
    if old and old.avgTime and not recipe.avgTime then
        recipe.avgTime = old.avgTime
        recipe.samples = old.samples
        recipe.timingCount = old.timingCount
    end
    self.list[recipe.id] = recipe
    self:save()
    return true
end

function recipes:remove(id)
    if self.list[id] then
        self.list[id] = nil
        self:save()
        return true
    end
    return false
end

function recipes:get(id)
    if self.list[id] then return self.list[id] end
    if type(id) == "string" and id:sub(1, 6) == "fluid:" then
        local fluidName = id:sub(7)
        for _, r in pairs(self.list) do
            if r.fluidOutput then
                for _, fo in ipairs(r.fluidOutput) do
                    if fo.fluid == fluidName then return r end
                end
            end
        end
    end
    return nil
end

function recipes:all()
    local arr = {}
    for _, r in pairs(self.list) do arr[#arr + 1] = r end
    table.sort(arr, function(a, b) return (a.id or "") < (b.id or "") end)
    return arr
end

function recipes:has(id)
    return self:get(id) ~= nil
end

----------------------------------------------------------------
-- ЯЧЕЙКИ И ИНГРЕДИЕНТЫ
----------------------------------------------------------------

--- Представительный id ячейки (для UI/логов/учёта).
function recipes.cellId(cell)
    local c = recipes.normalizeCell(cell)
    if not c then return nil end
    if c.id then return c.id end
    if c.variants and c.variants[1] then return recipes.cellId(c.variants[1]) end
    if c.tag then return "#" .. c.tag end
    if c.any then return "*" end
    return nil
end

--- Массив ячеек в порядке сетки (1..9) для shaped; для shapeless — по ингредиентам.
function recipes.cells(recipe)
    local out = {}
    if recipe.type == "shaped" and recipe.pattern then
        for i = 1, 9 do
            local row = math.ceil(i / 3)
            local col = ((i - 1) % 3) + 1
            local cell = recipe.pattern[row] and recipe.pattern[row][col]
            out[i] = recipes.normalizeCell(cell)
        end
    elseif recipe.type == "shapeless" and recipe.ingredients then
        for idx, ing in ipairs(recipe.ingredients) do
            out[idx] = recipes.normalizeCell(ing)
        end
    end
    return out
end

--- Агрегированные ингредиенты рецепта на 1 операцию: { {id, count, spec, key} }.
function recipes.ingredientsOf(recipe)
    local agg = {}     -- key -> { id, count, spec }
    local order = {}
    local function addCell(cell)
        local c = recipes.normalizeCell(cell)
        if not c then return end
        local key = itemmatch.specKey(c)
        if not agg[key] then
            agg[key] = { id = recipes.cellId(c), count = 0, spec = c, key = key }
            order[#order + 1] = key
        end
        agg[key].count = agg[key].count + (c.count or 1)
    end

    if recipe.type == "shaped" and recipe.pattern then
        for r = 1, 3 do
            local row = recipe.pattern[r]
            if row then
                for col = 1, 3 do addCell(row[col]) end
            end
        end
    elseif recipe.type == "shapeless" and recipe.ingredients then
        for _, ing in ipairs(recipe.ingredients) do addCell(ing) end
    elseif (recipe.type == "station" or recipe.type == "machine") then
        local src = recipe.itemInput or recipe.input
        if src then for _, ing in ipairs(src) do addCell(ing) end end
    end

    local result = {}
    for _, key in ipairs(order) do result[#result + 1] = agg[key] end
    table.sort(result, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return result
end

function recipes.fluidsOf(recipe)
    local result = {}
    if recipe.fluidInput then
        for _, f in ipairs(recipe.fluidInput) do
            result[#result + 1] = { fluid = f.fluid, mb = f.mb }
        end
    end
    table.sort(result, function(a, b) return a.fluid < b.fluid end)
    return result
end

--- Сколько операций (крафтов/циклов) нужно для want штук/мБ результата.
function recipes.craftsNeeded(recipe, want)
    if recipe.type == "station" then
        if recipe.output and recipe.output > 0 then
            return math.ceil(want / recipe.output)
        elseif recipe.fluidOutput and recipe.fluidOutput[1] then
            return math.ceil(want / recipe.fluidOutput[1].mb)
        end
        return want
    end
    return math.ceil(want / (recipe.output or 1))
end

function recipes.itemsPerCraft(recipe)
    local inPer = 0
    if not recipe then return 0 end
    for _, ing in ipairs(recipes.ingredientsOf(recipe)) do
        inPer = inPer + (ing.count or 1)
    end
    return inPer
end

--- Полная потребность в ингредиентах для want штук результата.
-- @return массив { {id, count, spec} }, crafts
function recipes.ingredientsFor(recipe, wantCount)
    local crafts = recipes.craftsNeeded(recipe, wantCount)
    local ings = recipes.ingredientsOf(recipe)
    local result = {}
    for _, ing in ipairs(ings) do
        result[#result + 1] = { id = ing.id, count = ing.count * crafts, spec = ing.spec }
    end
    return result, crafts
end

function recipes.fluidsFor(recipe, wantCount)
    local crafts = recipes.craftsNeeded(recipe, wantCount)
    local fls = recipes.fluidsOf(recipe)
    local result = {}
    for _, f in ipairs(fls) do
        result[#result + 1] = { fluid = f.fluid, mb = f.mb * crafts }
    end
    return result, crafts
end

----------------------------------------------------------------
-- РАЗРЕШЕНИЕ СПЕЦИФИКАЦИЙ В КОНКРЕТНЫЙ КРАФТ
----------------------------------------------------------------

--- Построить «конкретный» рецепт: каждая ячейка-спецификация заменяется на
-- конкретный id, выбранный по доступному запасу через storage:resolveSpec.
-- Это то, что отправляется воркеру (он работает только с id).
-- @param recipe исходный рецепт
-- @param crafts число операций (для оценки потребности при выборе варианта)
-- @param storageObj объект storage (с resolveSpec); может быть nil — тогда
--        берём представительный id ячейки без проверки запаса.
-- @return concreteRecipe | nil, errorMessage
function recipes.resolveConcrete(recipe, crafts, storageObj)
    crafts = crafts or 1
    local function pick(cell)
        local c = recipes.normalizeCell(cell)
        if not c then return nil end
        local need = (c.count or 1) * crafts
        if storageObj and storageObj.resolveSpec then
            local id = storageObj:resolveSpec(c, need)
            if id then return { id = id, count = c.count or 1 } end
            -- не нашли в запасе — вернём представительный (план проверит наличие)
        end
        local rep = recipes.cellId(c)
        if rep and rep:sub(1, 1) ~= "#" and rep ~= "*" then
            return { id = rep, count = c.count or 1 }
        end
        return nil, "Unresolved ingredient: " .. tostring(rep)
    end

    local out = {
        id = recipe.id,
        name = recipe.name,
        type = recipe.type,
        output = recipe.output or 1,
        avgTime = recipe.avgTime,
    }

    if recipe.type == "shaped" and recipe.pattern then
        out.pattern = {}
        for row = 1, 3 do
            out.pattern[row] = {}
            local prow = recipe.pattern[row]
            for col = 1, 3 do
                if prow and prow[col] then
                    local concrete, err = pick(prow[col])
                    if not concrete then
                        return nil, err or ("Unresolved cell " .. row .. "," .. col)
                    end
                    out.pattern[row][col] = concrete
                else
                    out.pattern[row][col] = nil
                end
            end
        end
    elseif recipe.type == "shapeless" and recipe.ingredients then
        out.ingredients = {}
        for _, ing in ipairs(recipe.ingredients) do
            local concrete, err = pick(ing)
            if not concrete then return nil, err or "Unresolved ingredient" end
            out.ingredients[#out.ingredients + 1] = concrete
        end
    else
        return nil, "resolveConcrete supports shaped/shapeless only"
    end

    return out
end

----------------------------------------------------------------
-- ОБУЧЕНИЕ
----------------------------------------------------------------

function recipes.buildFromTurtle(slots, resultId, resultCount, resultName)
    local pattern = {}
    for row = 0, 2 do
        local r = {}
        for col = 1, 3 do
            local idx = row * 3 + col
            local s = slots[idx]
            if s and s.id then
                r[col] = { id = s.id, count = s.count or 1 }
            end
        end
        pattern[#pattern + 1] = r
    end
    return {
        id = resultId,
        name = resultName,
        type = "shaped",
        output = resultCount or 1,
        pattern = pattern,
        schema_version = recipes.SCHEMA_VERSION,
    }
end

function recipes:learnFromTurtle()
    if not turtle then
        return false, "learning is only available on a turtle"
    end
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
            if (not snap) or (snap.name ~= det.name) then
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

function recipes:learnFromStorage(invName, recipeType, machineType)
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

    local pattern = {}
    for r = 1, 3 do
        pattern[r] = {}
    end

    local outputSlot, outputItem
    local hasRecipeItems = false

    if size < 27 then
        for slot = 1, math.min(9, size) do
            local item = inventoryList[slot]
            if item then
                local row = math.floor((slot - 1) / 3) + 1
                local col = (slot - 1) % 3 + 1
                pattern[row][col] = { id = item.name, count = item.count or 1 }
                hasRecipeItems = true
            end
        end
        for slot = 10, size do
            local item = inventoryList[slot]
            if item and not outputSlot then
                outputSlot = slot
                outputItem = item
            end
        end
    else
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
        local gridCols = { [colMin] = 1, [colMin + 1] = 2, [colMin + 2] = 3 }
        for slot = 1, size do
            local item = inventoryList[slot]
            if item then
                local row = math.floor((slot - 1) / 9) + 1
                local col = (slot - 1) % 9 + 1
                local isRecipeSlot = (row <= 3) and gridCols[col]
                if isRecipeSlot then
                    pattern[row][gridCols[col]] = { id = item.name, count = item.count or 1 }
                elseif not outputSlot then
                    outputSlot = slot
                    outputItem = item
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

    local displayName
    if p.getItemDetail then
        local ok, detail = pcall(p.getItemDetail, outputSlot)
        if ok and detail and detail.displayName then displayName = detail.displayName end
    end

    local recipe
    if recipeType == "machine" then
        local agg = {}
        for r = 1, 3 do
            for c = 1, 3 do
                local item = pattern[r][c]
                if item and item.id then
                    agg[item.id] = (agg[item.id] or 0) + (item.count or 1)
                end
            end
        end
        local input = {}
        for id, count in pairs(agg) do input[#input + 1] = { id = id, count = count } end
        table.sort(input, function(a, b) return a.id < b.id end)
        recipe = {
            id = outputItem.name,
            name = displayName or outputItem.name,
            type = "machine",
            machine = machineType or "furnace",
            input = input,
            output = outputItem.count or 1,
        }
    else
        recipe = {
            id = outputItem.name,
            name = displayName or outputItem.name,
            type = "shaped",
            output = outputItem.count or 1,
            pattern = pattern,
        }
    end

    self:add(recipe)
    return true, recipe
end

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
    local inputSlot, inputItem
    for slot, item in pairs(storageList) do
        if item then inputSlot = slot; inputItem = item; break end
    end
    if not inputSlot then
        return false, "storage chest is empty (place the item to process inside it)"
    end

    local sz = pMachine.size() or 0
    local machineList = pMachine.list() or {}
    for s = 1, sz do
        if machineList[s] then pcall(pMachine.pushItems, storageName, s) end
    end

    local pushed = pStorage.pushItems(machineName, inputSlot, 1, 1)
    if pushed == 0 then pushed = pStorage.pushItems(machineName, inputSlot, 1) end
    if pushed == 0 then return false, "could not push item to machine" end

    local outputItemDetail, outputSlot
    local deadline = os.clock() + 60
    while os.clock() < deadline do
        local ok, items = pcall(pMachine.list)
        if ok and items then
            for slot, item in pairs(items) do
                if item and item.name ~= inputItem.name then
                    outputItemDetail = item
                    outputSlot = slot
                    break
                end
            end
        end
        if outputItemDetail then
            if pMachine.getItemDetail then
                local ok2, det = pcall(pMachine.getItemDetail, outputSlot)
                if ok2 and det and det.displayName then outputItemDetail.displayName = det.displayName end
            end
            break
        end
        os.sleep(0.5)
    end

    if not outputItemDetail then
        local list = pMachine.list() or {}
        for s = 1, sz do
            if list[s] then pcall(pMachine.pushItems, storageName, s) end
        end
        return false, "timeout waiting for machine processing"
    end

    pMachine.pushItems(storageName, outputSlot)

    local mType = peripheral.getType(machineName)
    local targetMachine = mType
    local ptypeLower = (mType or ""):lower()
    local isSpecific = false
    if ptypeLower:find("chest") or ptypeLower:find("barrel") or ptypeLower:find("vault") or ptypeLower:find("cabinet") then
        isSpecific = true
    end
    local cfg = (_G.config or require("config")).load()
    if cfg and cfg.peripherals and cfg.peripherals.machines then
        for _, name in ipairs(cfg.peripherals.machines) do
            if name == machineName then isSpecific = true; break end
        end
    end
    if isSpecific then targetMachine = machineName end

    local recipe = {
        id = outputItemDetail.name,
        name = outputItemDetail.displayName or outputItemDetail.name,
        type = "machine",
        machine = targetMachine,
        input = { { id = inputItem.name, count = 1 } },
        output = outputItemDetail.count or 1,
    }
    self:add(recipe)
    return true, recipe
end

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
       return false, "Turtle #" .. tostring(workerId) .. " is not reachable on the wired network."
    end

    local storageSize = pStorage.size()
    local storageList = pStorage.list()

    local pattern = {}
    local transfers = {}
    for r = 1, 3 do pattern[r] = {} end
    local hasRecipeItems = false

    if storageSize < 27 then
        for slot = 1, math.min(9, storageSize) do
            local item = storageList[slot]
            if item then
                local row = math.floor((slot - 1) / 3) + 1
                local col = (slot - 1) % 3 + 1
                pattern[row][col] = { id = item.name, count = 1 }
                local gridIdx = (row - 1) * 3 + col
                transfers[#transfers + 1] = { srcSlot = slot, dstSlot = GRID[gridIdx] }
                hasRecipeItems = true
            end
        end
    else
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
        local gridCols = { [colMin] = 1, [colMin + 1] = 2, [colMin + 2] = 3 }
        for slot = 1, math.min(27, storageSize) do
            local item = storageList[slot]
            if item and gridCols[(slot - 1) % 9 + 1] then
                local row = math.floor((slot - 1) / 9) + 1
                local gridCol = gridCols[(slot - 1) % 9 + 1]
                pattern[row][gridCol] = { id = item.name, count = 1 }
                local gridIdx = (row - 1) * 3 + gridCol
                transfers[#transfers + 1] = { srcSlot = slot, dstSlot = GRID[gridIdx] }
            end
        end
    end

    if not hasRecipeItems then
        return false, "no items in crafting grid (place items in slots 1-9)"
    end

    for s = 1, 16 do pStorage.pullItems(turtleName, s) end
    for _, trans in ipairs(transfers) do
        local pushed = pStorage.pushItems(turtleName, trans.srcSlot, 1, trans.dstSlot)
        if pushed == 0 then
            for s = 1, 16 do pStorage.pullItems(turtleName, s) end
            return false, "could not transfer ingredients to turtle slots"
        end
    end

    local netmod = _G.net or require("lib.net")
    netmod.send(workerId, netmod.MSG.LEARN_CRAFT_REQUEST, {})

    local responseMsg
    local deadline = os.clock() + 15
    while os.clock() < deadline do
        local senderId, msg = netmod.receive(1)
        if senderId == workerId and msg and msg.type == netmod.MSG.LEARN_CRAFT_RESPONSE then
            responseMsg = msg.payload
            break
        end
    end

    if not responseMsg then
        for s = 1, 16 do pStorage.pullItems(turtleName, s) end
        return false, "timeout waiting for turtle craft response"
    end
    if not responseMsg.success then
        for s = 1, 16 do pStorage.pullItems(turtleName, s) end
        return false, tostring(responseMsg.error)
    end

    for s = 1, 16 do pStorage.pullItems(turtleName, s) end

    local recipe = {
        id = responseMsg.name,
        name = responseMsg.displayName or responseMsg.name,
        type = "shaped",
        output = responseMsg.count or 1,
        pattern = pattern,
    }
    self:add(recipe)
    return true, recipe
end

----------------------------------------------------------------
-- ВРЕМЯ КРАФТА
----------------------------------------------------------------

function recipes.avgTimeFor(recipe)
    if not recipe then return 1.0, true end
    if recipe.avgTime and recipe.avgTime > 0 then
        return recipe.avgTime, false
    end
    local def = (recipe.type == "machine") and 10.0 or 1.0
    return def, true
end

function recipes:updateTiming(id, perOpSec)
    local r = self.list[id]
    if not r or not perOpSec or perOpSec <= 0 then return end
    if not r.avgTime then
        r.avgTime = perOpSec
    else
        r.avgTime = 0.3 * perOpSec + 0.7 * r.avgTime
    end
    r.samples = (r.samples or 0) + 1
    r.timingCount = r.samples
    self:save()
end

----------------------------------------------------------------
-- СНИМКИ ДЛЯ ОБУЧЕНИЯ СТАНЦИЙ (совместимость с UI)
----------------------------------------------------------------

local function wrap(name)
    if not peripheral.isPresent(name) then return nil end
    return peripheral.wrap(name)
end

function recipes.snapshotStation(name)
    local p = wrap(name)
    if not p then return { items = {}, fluids = {} } end
    local items = {}
    local fluids = {}
    if p.list and p.size then
        local ok, list = pcall(p.list)
        if ok and list then
            for _, info in pairs(list) do
                if info.name then items[info.name] = (items[info.name] or 0) + (info.count or 0) end
            end
        end
    end
    if p.tanks then
        local ok, tks = pcall(p.tanks)
        if ok and tks then
            for _, t in ipairs(tks) do
                local fName = t.name or t.fluid
                if fName and t.amount and t.amount > 0 then
                    fluids[fName] = (fluids[fName] or 0) + t.amount
                end
            end
        end
    end
    return { items = items, fluids = fluids }
end

function recipes.snapshotAll(stationName, inputChestName, storageObj, fluidsObj)
    local items = {}
    local fluids = {}
    if inputChestName then
        local p = wrap(inputChestName)
        if p and p.list then
            local ok, list = pcall(p.list)
            if ok and list then
                for _, info in pairs(list) do
                    if info.name then items[info.name] = (items[info.name] or 0) + (info.count or 0) end
                end
            end
        end
    end
    if stationName then
        local snap = recipes.snapshotStation(stationName)
        for id, qty in pairs(snap.items) do items[id] = (items[id] or 0) + qty end
        for f, mb in pairs(snap.fluids) do fluids[f] = (fluids[f] or 0) + mb end
    end
    if fluidsObj then
        fluidsObj:scan()
        if fluidsObj.cache then
            for f, info in pairs(fluidsObj.cache) do fluids[f] = (fluids[f] or 0) + info.total end
        end
        if fluidsObj.danks then
            for _, dk in ipairs(fluidsObj.danks) do
                local info = fluidsObj.dank_cache[dk.periph]
                if info and info.current_mb > 0 then
                    fluids[dk.fluid] = (fluids[dk.fluid] or 0) + info.current_mb
                end
            end
        end
    end
    return { items = items, fluids = fluids }
end

return recipes
