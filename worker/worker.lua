-- worker/worker.lua
-- Черепаха-воркер ShellCraft (крафт-FSM).
--
-- Transport-режимы:
--   * buffer (default): ингредиенты воркер засасывает сам из назначенного
--     ВХОДНОГО сундука (turtle.suck*), результат сбрасывает в ВЫХОДНОЙ сундук
--     (turtle.drop*). Сундуки-буферы физически смежны с черепахой и одновременно
--     висят на проводной сети (Core заполняет вход / опустошает выход).
--     Черепахе нужен ТОЛЬКО модем для rednet (беспроводной) — проводной не нужен.
--   * wired (legacy): Core кладёт ингредиенты прямо в инвентарь черепахи по
--     проводной сети; воркер только крафтит, результат забирает Core.
--
-- FSM: idle -> loading -> crafting -> unloading -> idle.
-- Любая turtle-операция под pcall; ошибка -> честный RESULT + чистый инвентарь.

local worker = {}
worker.__index = worker

-- Слоты 3x3 крафтовой сетки и свободные «карманы».
local GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
local EXTRA = { 4, 8, 12, 13, 14, 15, 16 }
worker.GRID = GRID
worker.EXTRA = EXTRA

-- Множество grid-слотов для быстрой проверки.
local GRID_SET = {}
for _, s in ipairs(GRID) do GRID_SET[s] = true end

----------------------------------------------------------------
-- СОЗДАНИЕ / СОСТОЯНИЕ
----------------------------------------------------------------

function worker.new()
    local self = setmetatable({}, worker)
    self.core_id = nil
    self.state = "idle"            -- idle | loading | crafting | unloading
    self.busy = false
    self.current_task_id = nil
    self.cancelled = false
    self.canCraft = true           -- false если нет turtle.craft (крафт-стола)
    self.buffer = nil              -- { input, output, input_side, output_side }
    self.transfer_mode = "buffer"
    self.lastBeat = 0
    self.lastDiscover = 0
    return self
end

function worker:setCore(id)
    self.core_id = id
end

----------------------------------------------------------------
-- СЕТЕВЫЕ ОТПРАВКИ
----------------------------------------------------------------

function worker:sayHello(target)
    local payload = {
        id = os.getComputerID(),
        role = "worker",
        busy = self.busy,
        state = self.state,
        version = _SHELLCRAFT_VERSION,
        current_task_id = self.current_task_id,
        core = self.core_id,
        buffer = self.buffer,
    }
    if target then
        net.send(target, net.MSG.WORKER_HELLO, payload)
    else
        net.broadcast(net.MSG.WORKER_HELLO, payload)
    end
end

local function sendAck(self, taskId)
    if not self.core_id then return end
    net.send(self.core_id, net.MSG.CRAFT_ACK, { task_id = taskId })
end

local function sendStatus(self, taskId, progress, message)
    if not self.core_id then return end
    net.send(self.core_id, net.MSG.STATUS, {
        task_id = taskId, progress = progress, message = message, state = self.state,
    })
end

local function sendResult(self, taskId, payload)
    if not self.core_id then return end
    payload = payload or {}
    payload.task_id = taskId
    net.send(self.core_id, net.MSG.RESULT, payload)
end

local function sendHeartbeat(self)
    if not self.core_id then return end
    net.send(self.core_id, net.MSG.HEARTBEAT, {
        id = os.getComputerID(),
        busy = self.busy,
        state = self.state,
        current_task_id = self.current_task_id,
    })
end

--- Периодический heartbeat с троттлингом по cfg.heartbeat_interval.
-- Вызывается из длинных циклов (chunkLoop, offload-retry), чтобы диспетчер
-- не счёл воркера пропавшим во время долгого крафта/выгрузки.
local function maybeBeat(self)
    local interval = (config.load().heartbeat_interval or 10)
    if (os.clock() - (self.lastBeat or 0)) >= interval then
        sendHeartbeat(self)
        self.lastBeat = os.clock()
    end
end

----------------------------------------------------------------
-- ИНВЕНТАРЬ: БАЗОВЫЕ ОПЕРАЦИИ
----------------------------------------------------------------

local function itemCount(slot)
    local ok, n = pcall(turtle.getItemCount, slot)
    return (ok and n) or 0
end

local function itemDetail(slot)
    local ok, d = pcall(turtle.getItemDetail, slot)
    if ok and d and d.name then return d end
    return nil
end

local function itemSpace(slot)
    local ok, n = pcall(turtle.getItemSpace, slot)
    return (ok and n) or 0
end

--- Найти EXTRA-слот с предметом данного id (источник для переноса; NBT-нейтрально).
local function findExtraWith(id, fromIdx)
    fromIdx = fromIdx or 1
    for i = fromIdx, #EXTRA do
        local s = EXTRA[i]
        local d = itemDetail(s)
        if d and d.name == id and itemCount(s) > 0 then return s, i end
    end
    return nil
end

--- Найти свободный EXTRA-слот.
local function findEmptyExtra(fromIdx)
    fromIdx = fromIdx or 1
    for i = fromIdx, #EXTRA do
        local s = EXTRA[i]
        if itemCount(s) == 0 then return s, i end
    end
    return nil
end

--- Найти EXTRA-слот того же id со свободным местом (для слияния).
local function findExtraMerge(id)
    for _, s in ipairs(EXTRA) do
        local d = itemDetail(s)
        if d and d.name == id and itemSpace(s) > 0 then return s end
    end
    return nil
end

--- EXTRA-слот под приём ingredient id: сначала слияние в тот же id, иначе пустой.
local function extraSlotFor(id)
    local s = findExtraMerge(id)
    if s then return s end
    return findEmptyExtra()
end

--- Выбрать слот и сделать transferTo в grid-слот.
local function transferInto(gridSlot, n)
    turtle.select(1)
    return pcall(turtle.transferTo, gridSlot, n)
end

----------------------------------------------------------------
-- СТОРОНЫ И СМЕЖНЫЕ СУНДУКИ (buffer-режим, без проводного модема)
----------------------------------------------------------------

-- suck по стороне: top -> suckUp, bottom -> suckDown, front -> suck.
local function suckBySide(side, n)
    if side == "top" then return turtle.suckUp(n)
    elseif side == "bottom" then return turtle.suckDown(n)
    else return turtle.suck(n) end
end

-- drop по стороне.
local function dropBySide(side, n)
    if side == "top" then return turtle.dropUp(n)
    elseif side == "bottom" then return turtle.dropDown(n)
    else return turtle.drop(n) end
end

local function sideInventory(side)
    if not side then return nil end
    local ok, p = pcall(peripheral.wrap, side)
    if ok and p and type(p.list) == "function" and type(p.size) == "function" then
        return p
    end
    return nil
end

--- Собственное wired-имя черепахи (nil если нет проводного модема).
local function selfName()
    local ok, name = pcall(peripheral.getNameLocal)
    return (ok and name) or nil
end

----------------------------------------------------------------
-- BUFFER: ВЗАИМОДЕЙСТВИЕ СО СУНДУКАМИ
----------------------------------------------------------------

--- Засосать ровно need предметов spec из входного сундука в EXTRA-слот.
-- Сначала пробуем смежный suck по input_side; если там нет инвентаря —
-- fallback на pushItems по wired-имени (если есть проводной модем).
local function pullFromInput(self, need, spec, buffer)
    local id = spec.id or spec.name
    if not id then return false, "bad ingredient spec" end
    local inputSide = buffer and buffer.input_side or "top"
    local inputName = buffer and buffer.input or nil
    local have = 0
    local attempts = 0
    local deadline = os.clock() + (config.load().worker_buffer_timeout or 10)

    local function gotEnough() return have >= need end

    while have < need and os.clock() < deadline do
        attempts = attempts + 1
        if attempts > 256 then break end

        -- 1) Смежный suck.
        local adj = sideInventory(inputSide)
        if adj then
            local dst = extraSlotFor(id) or findEmptyExtra()
            if not dst then return false, "no free EXTRA slot to receive input" end
            local space = itemSpace(dst)
            local toSuck = math.min(need - have, space)
            if toSuck <= 0 then return false, "EXTRA slot full" end

            turtle.select(dst)
            local before = itemCount(dst)
            local ok, done = pcall(suckBySide, inputSide, toSuck)
            local moved = itemCount(dst) - before

            if moved > 0 then
                -- Проверяем что засосали нужный предмет (id + NBT).
                local d = itemDetail(dst)
                if d and itemmatch.matches(d, spec) then
                    have = have + moved
                else
                    -- Чужой предмет (другой NBT) — сбрасываем в выходной и пробуем снова.
                    pcall(dropBySide, buffer and buffer.output_side or "bottom", moved)
                end
            else
                os.sleep(0.05)  -- в сундуке пока нет нужного — уступаем цикл
            end
        elseif inputName and selfName() then
            -- 2) Fallback: проводной модем есть — тянем из входного сундука по имени.
            local ok, p = pcall(peripheral.wrap, inputName)
            if ok and p and p.pushItems then
                local dst = extraSlotFor(id) or findEmptyExtra()
                if not dst then return false, "no free EXTRA slot to receive input" end
                local movedAny = 0
                local okL, list = pcall(p.list)
                if okL and list then
                    for srcSlot, info in pairs(list) do
                        if have >= need then break end
                        if info and info.name == id then
                            local okD, det = pcall(p.getItemDetail, srcSlot)
                            if (okD and det and itemmatch.matches(det, spec)) or (not okD) then
                                local want = math.min(need - have, info.count or 0)
                                if want > 0 then
                                    local okP, n = pcall(p.pushItems, selfName(), srcSlot, want, dst)
                                    n = (okP and n) or 0
                                    movedAny = movedAny + n
                                    have = have + n
                                end
                            end
                        end
                    end
                end
                if movedAny == 0 then os.sleep(0) end
            else
                return false, "input chest '" .. tostring(inputName) .. "' not reachable"
            end
        else
            return false, "no adjacent input on side '" .. tostring(inputSide)
                .. "' and no wired modem for '" .. tostring(inputName) .. "'"
        end
    end

    if have < need then
        return false, string.format("not enough %s from input: need %d, got %d", id, need, have)
    end
    return true
end

--- Сбросить содержимое слота в выходной сундук.
-- Смежный drop по output_side; fallback на pullItems по wired-имени.
local function pushToOutput(self, slot, n, buffer)
    local outputSide = buffer and buffer.output_side or "bottom"
    local outputName = buffer and buffer.output or nil
    turtle.select(slot)
    local limit = n or itemCount(slot)

    -- 1) Смежный drop.
    if sideInventory(outputSide) then
        local ok, moved = pcall(dropBySide, outputSide, limit)
        moved = (ok and moved) or 0
        if moved >= itemCount(slot) then return true, moved end
        if moved > 0 then return true, moved end
    end

    -- 2) Fallback: выходной сундук по wired-имени.
    if outputName and selfName() then
        local ok, p = pcall(peripheral.wrap, outputName)
        if ok and p and p.pullItems then
            local okP, moved = pcall(p.pullItems, selfName(), slot, limit)
            moved = (okP and moved) or 0
            if moved > 0 then return true, moved end
        end
    end
    return false, 0
end

--- Полностью очистить инвентарь в выходной сундук (перед крафтом).
local function clearAllToOutput(self, buffer)
    for s = 1, 16 do
        if itemCount(s) > 0 then
            local ok = false
            for _ = 1, 3 do
                local done, _mv = pushToOutput(self, s, nil, buffer)
                if done and itemCount(s) == 0 then ok = true; break end
                os.sleep(0)
            end
            if not ok and itemCount(s) > 0 then
                return false, "cannot clear slot " .. s .. " to output (output full?)"
            end
        end
    end
    return true
end

--- Выгрузить все не-grid слоты (результат + остатки ингредиентов) в выходной сундук.
local function evacuateToOutput(self, buffer)
    local leftover = 0
    for _, s in ipairs(EXTRA) do
        while itemCount(s) > 0 do
            local done, moved = pushToOutput(self, s, nil, buffer)
            if not done or moved == 0 then
                leftover = leftover + itemCount(s)
                break  -- выходной полон — остаток оставляем в слоте
            end
        end
    end
    -- Также grid мог остаться с мусором — пробуем выгрузить.
    for _, s in ipairs(GRID) do
        if itemCount(s) > 0 then pushToOutput(self, s, nil, buffer) end
    end
    return leftover
end

----------------------------------------------------------------
-- РАСКЛАДКА / КРАФТ (общий для buffer и wired)
----------------------------------------------------------------

--- Очистить крафтовую сетку: перенести grid-слоты в EXTRA, иначе сбросить наружу.
local function clearCraftingGrid(buffer, self)
    for _, s in ipairs(GRID) do
        if itemCount(s) > 0 then
            local d = itemDetail(s)
            if d then
                for _, dst in ipairs(EXTRA) do
                    if itemCount(dst) == 0 or (itemDetail(dst) and itemDetail(dst).name == d.name and itemSpace(dst) > 0) then
                        turtle.select(s)
                        pcall(turtle.transferTo, dst)
                        if itemCount(s) == 0 then break end
                    end
                end
            end
            if itemCount(s) > 0 and buffer then
                -- buffer: сбрасываем в выходной; wired: drop в любой смежный
                pushToOutput(self, s, nil, buffer)
            elseif itemCount(s) > 0 then
                pcall(turtle.drop)
            end
            if itemCount(s) > 0 then
                local d2 = itemDetail(s)
                return false, "cannot clear grid slot " .. s .. ": " .. tostring(d2 and d2.name)
            end
        end
    end
    return true
end

--- Разложить ингредиенты по shaped-паттерну из EXTRA-слотов.
local function layoutShaped(recipe, crafts, buffer, self)
    local cok, cerr = clearCraftingGrid(buffer, self)
    if not cok then return false, cerr end
    for i = 1, 9 do
        local row = math.ceil(i / 3)
        local col = ((i - 1) % 3) + 1
        local prow = recipe.pattern and recipe.pattern[row]
        local cell = prow and prow[col]
        if cell then
            local id = cell.id or cell.name
            local need = (cell.count or 1) * crafts
            local fromIdx = 1
            local gridSlot = GRID[i]
            while need > 0 do
                local s, sIdx = findExtraWith(id, fromIdx)
                if not s then
                    return false, "ingredient not in turtle: " .. tostring(id)
                end
                local d = itemDetail(s)
                local take = math.min(need, d.count or 0)
                turtle.select(s)
                pcall(turtle.transferTo, gridSlot, take)
                need = need - take
                fromIdx = sIdx + 1
            end
        end
    end
    turtle.select(1)
    return true
end

--- Разложить shapeless-ингредиенты по сетке.
local function layoutShapeless(recipe, crafts, buffer, self)
    local cok, cerr = clearCraftingGrid(buffer, self)
    if not cok then return false, cerr end
    local idx = 1
    for _, ing in ipairs(recipe.ingredients or {}) do
        if idx > 9 then return false, "too many shapeless ingredients (>9)" end
        local id = ing.id or ing.name
        local need = (ing.count or 1) * crafts
        if need > 64 then return false, "too many " .. tostring(id) .. " (" .. need .. ">64)" end
        local fromIdx = 1
        local gridSlot = GRID[idx]
        while need > 0 do
            local s, sIdx = findExtraWith(id, fromIdx)
            if not s then return false, "ingredient not in turtle: " .. tostring(id) end
            local d = itemDetail(s)
            local take = math.min(need, d.count or 0)
            turtle.select(s)
            pcall(turtle.transferTo, gridSlot, take)
            need = need - take
            fromIdx = sIdx + 1
        end
        idx = idx + 1
    end
    turtle.select(1)
    return true
end

--- Проверить соответствие сетки рецепту (по id + NBT через itemmatch).
local function verifyGridMatches(recipe)
    local function cellSpec(cell)
        if not cell then return nil end
        return { id = cell.id or cell.name, nbt = cell.nbt, components = cell.components, damage = cell.damage }
    end
    if recipe.type == "shaped" then
        for i = 1, 9 do
            local row = math.ceil(i / 3)
            local col = ((i - 1) % 3) + 1
            local prow = recipe.pattern and recipe.pattern[row]
            local cell = prow and prow[col]
            local spec = cellSpec(cell)
            local gridSlot = GRID[i]
            local d = itemDetail(gridSlot)
            if spec then
                if not d or not itemmatch.matches(d, spec) then
                    return false, "grid mismatch slot " .. gridSlot .. ": expected " .. tostring(spec.id)
                end
            else
                if d then return false, "grid mismatch slot " .. gridSlot .. ": expected empty" end
            end
        end
    else
        local ings = recipe.ingredients or {}
        for i = 1, 9 do
            local spec = cellSpec(ings[i])
            local gridSlot = GRID[i]
            local d = itemDetail(gridSlot)
            if spec then
                if not d or not itemmatch.matches(d, spec) then
                    return false, "grid mismatch slot " .. gridSlot .. ": expected " .. tostring(spec.id)
                end
            else
                if d then return false, "grid mismatch slot " .. gridSlot .. ": expected empty" end
            end
        end
    end
    return true
end

--- Свободное место под результат recipe.id в EXTRA-слотах.
local function outputCapacityFor(recipeId)
    local cap = 0
    for _, s in ipairs(EXTRA) do
        local d = itemDetail(s)
        if not d then
            cap = cap + 64
        elseif d.name == recipeId then
            cap = cap + itemSpace(s)
        end
    end
    return cap
end

--- Перенести результат из слота 1 в EXTRA (слияние или пустой).
local function moveResultToExtra(recipeId)
    if itemCount(1) == 0 then return true end
    local d = itemDetail(1)
    if not d then return true end
    -- Сначала сливаем в существующий стак того же id.
    for _, dst in ipairs(EXTRA) do
        if itemCount(dst) > 0 then
            local dd = itemDetail(dst)
            if dd and dd.name == d.name and itemSpace(dst) > 0 then
                turtle.select(1)
                pcall(turtle.transferTo, dst)
                if itemCount(1) == 0 then return true end
            end
        end
    end
    -- Иначе в пустой EXTRA.
    for _, dst in ipairs(EXTRA) do
        if itemCount(dst) == 0 then
            turtle.select(1)
            pcall(turtle.transferTo, dst)
            return itemCount(1) == 0
        end
    end
    return false
end

--- Цикл крафта чанками. Возвращает true, totalCrafted, elapsed, crafts | false, err.
local function chunkLoop(self, recipe, count)
    local output = recipe.output or 1
    local crafts = math.ceil(count / output)
    local t0 = os.epoch("utc")
    local totalCrafted = 0
    local remaining = crafts
    local stepNum = 1
    while remaining > 0 do
        if self.cancelled then
            return false, "cancelled"
        end
        local maxChunk = math.floor(64 / math.max(1, output))
        if maxChunk < 1 then maxChunk = 1 end
        local chunk = math.min(maxChunk, remaining)

        -- Гарантируем место под результат до раскладки.
        if outputCapacityFor(recipe.id) < chunk * output then
            -- В buffer-режиме пробуем сбросить лишнее в выходной (если он задан).
            if self.buffer then
                for _, s in ipairs(EXTRA) do
                    local d = itemDetail(s)
                    if d and d.name ~= recipe.id then pushToOutput(self, s, nil, self.buffer) end
                end
            end
            if outputCapacityFor(recipe.id) < chunk * output then
                local cap = outputCapacityFor(recipe.id)
                local maxBySpace = math.floor(cap / output)
                if maxBySpace < 1 then
                    return false, "no room for crafted output (inventory full)"
                end
                chunk = math.min(chunk, maxBySpace)
            end
        end

        local lok, lerr
        if recipe.type == "shaped" then
            lok, lerr = layoutShaped(recipe, chunk, self.buffer, self)
        else
            lok, lerr = layoutShapeless(recipe, chunk, self.buffer, self)
        end
        if not lok then return false, lerr end

        local vok, verr = verifyGridMatches(recipe)
        if not vok then return false, verr end

        turtle.select(1)
        local okCraft, reason = pcall(turtle.craft, chunk * output)
        if not okCraft then
            return false, "turtle.craft crashed: " .. tostring(reason)
        end
        -- turtle.craft возвращает true/false (pcall вернул ok+результат).
        -- pcall выше уже развёрнут: okCraft=true, reason=результат craft.
        if reason == false then
            return false, "turtle.craft rejected step " .. stepNum .. " (" .. tostring(recipe.id) .. ")"
        end

        if not moveResultToExtra(recipe.id) then
            return false, "failed to move result out of slot 1 (inventory full)"
        end

        totalCrafted = totalCrafted + chunk * output
        remaining = remaining - chunk
        stepNum = stepNum + 1
        maybeBeat(self)
        sendStatus(self, self.current_task_id,
            math.floor(100 * (crafts - remaining) / crafts), "crafting")
    end

    local t1 = os.epoch("utc")
    local elapsed = (t1 - t0) / 1000
    if elapsed < 0 then elapsed = 0 end
    return true, totalCrafted, elapsed, crafts
end

----------------------------------------------------------------
-- РЕЖИМЫ КРАФТА
----------------------------------------------------------------

--- BUFFER: засосать ингредиенты из входного сундука, скрафтить, выгрузить в выходной.
function worker:craftBuffer(recipe, count, buffer)
    self.buffer = buffer
    self.state = "loading"

    -- 1. Очистить инвентарь в выходной сундук.
    local ok, err = clearAllToOutput(self, buffer)
    if not ok then
        return false, "clear failed: " .. tostring(err)
    end

    -- 2. Засосать ингредиенты (по конкретному рецепту).
    local ings, crafts = recipes.ingredientsFor(recipe, count)
    for _, ing in ipairs(ings) do
        local spec = ing.spec or { id = ing.id }
        local okS, errS = pullFromInput(self, ing.count, spec, buffer)
        if not okS then
            pcall(evacuateToOutput, self, buffer)
            return false, errS
        end
    end

    -- 3. Крафт.
    self.state = "crafting"
    local cok, c1, c2, c3 = chunkLoop(self, recipe, count)
    if not cok then
        -- При провале/отмене выгружаем остатки в выходной.
        self.state = "unloading"
        pcall(evacuateToOutput, self, buffer)
        return false, c1
    end

    -- 4. Выгрузка результата + остатков в выходной сундук.
    self.state = "unloading"
    local leftover = evacuateToOutput(self, buffer)
    if leftover > 0 then
        -- Выходной сундук полон = хранилище забито. Core на тиках опустошает
        -- выходной сундук в хранилище (collectResult); ждём освобождения места,
        -- ретраим выгрузку. Один WARN на инцидент, heartbeat шлём чтобы Core
        -- не счёл воркера мёртвым. Жёсткий кап — чтобы не висеть вечно.
        util.warn(string.format("Storage full: could not offload %d items", leftover))
        local warned = true
        local waitDeadline = os.clock() + ((config.load().task_timeout) or 120)
        while leftover > 0 and os.clock() < waitDeadline do
            if self.cancelled then
                pcall(evacuateToOutput, self, buffer)
                return false, "cancelled"
            end
            maybeBeat(self)
            os.sleep(1)
            leftover = evacuateToOutput(self, buffer)
        end
        if leftover > 0 then
            -- Хранилище так и не освободилось — честный storage_full, остаток
            -- остаётся в черепахе; Core поставит воркера в draining и ретраит.
            return false, "storage_full", c1, c3
        end
    end

    return true, c1, c2, c3
end

--- WIRED (legacy): ингредиенты уже в EXTRA (их положил Core). Крафтим, результат
-- оставляем в EXTRA — Core заберёт через collectResult.
function worker:craftWired(recipe, count)
    self.state = "loading"
    -- Сбросить чужие предметы (не ингредиенты рецепта) в любой смежный инвентарь.
    local allowed = {}
    for _, ing in ipairs(recipes.ingredientsFor(recipe, count)) do
        if ing.id then allowed[ing.id] = true end
    end
    for s = 1, 16 do
        local d = itemDetail(s)
        if d and not allowed[d.name] then
            turtle.select(s)
            -- пробуем сбросить в любой смежный инвентарь (wired-режим)
            for _, fn in ipairs({ turtle.drop, turtle.dropUp, turtle.dropDown }) do
                pcall(fn)
                if itemCount(s) == 0 then break end
            end
        end
    end

    self.state = "crafting"
    local cok, c1, c2, c3 = chunkLoop(self, recipe, count)
    if not cok then
        self.state = "unloading"
        return false, c1
    end
    self.state = "unloading"
    return true, c1, c2, c3
end

--- Точка входа в крафт по задаче.
function worker:craft(recipe, count, mode, buffer)
    if not recipe then return false, "No recipe" end
    if recipe.type == "machine" or recipe.type == "station" then
        return false, "Machine recipes are handled by Core, not worker"
    end
    if not self.canCraft then
        return false, "This turtle has no crafting table - cannot craft"
    end
    maybeRefuel()
    if mode == "wired" then
        return self:craftWired(recipe, count)
    end
    if not buffer or not buffer.input or not buffer.output then
        return false, "buffer chest missing"
    end
    return self:craftBuffer(recipe, count, buffer)
end

----------------------------------------------------------------
-- ТОПЛИВО
----------------------------------------------------------------

local function maybeRefuel()
    if not turtle or not turtle.refuel then return end
    local okF, fuel = pcall(turtle.getFuelLevel)
    if not okF or not fuel then return end
    if fuel == "unlimited" then return end
    if (fuel or 0) >= 5 then return end
    -- Пробуем заправиться из EXTRA-слотов (только если там лежит топливо).
    for _, s in ipairs(EXTRA) do
        if itemCount(s) > 0 then
            turtle.select(s)
            local okR = pcall(turtle.refuel, 1)
            if okR then
                local okF2, fuel2 = pcall(turtle.getFuelLevel)
                if okF2 and fuel2 and fuel2 ~= "unlimited" and fuel2 > (fuel or 0) then
                    return  -- заправились
                end
            end
        end
    end
end

----------------------------------------------------------------
-- ГЛАВНЫЙ ЦИКЛ
----------------------------------------------------------------

function worker:run()
    if not net.open() then
        util.warn("No modem! Attach a wired or wireless modem to the turtle.")
    end

    -- Проверка крафт-стола.
    if type(turtle) ~= "table" or type(turtle.craft) ~= "function" then
        util.err("========================================")
        util.err("This turtle has NO crafting table.")
        util.err("Equip a Crafting Table to make a")
        util.err("Crafting Turtle, or craft requests")
        util.err("will be rejected with an error.")
        util.err("========================================")
        self.canCraft = false
    end

    util.ok("Worker #" .. os.getComputerID() .. " started, waiting for tasks")
    self:sayHello(nil)
    self.lastBeat = os.clock()
    self.lastDiscover = os.clock()

    local cfg = config.load()
    local beatInterval = cfg.heartbeat_interval or 10
    local discoverInterval = 45

    while true do
        local senderId, msg = net.receive(2)
        if senderId and msg then
            self:handleMessage(senderId, msg)
        end

        -- Heartbeat / авто-усыновление.
        local now = os.clock()
        if self.core_id and (now - self.lastBeat) >= beatInterval then
            sendHeartbeat(self)
            self.lastBeat = now
        elseif (not self.core_id) and (now - self.lastDiscover) >= discoverInterval then
            self:sayHello(nil)
            self.lastDiscover = now
        end
    end
end

--- Обработка одного сообщения.
function worker:handleMessage(senderId, msg)
    if not msg or not msg.type then return end
    local payload = msg.payload or {}

    if msg.type == net.MSG.DISCOVER then
        self.core_id = (payload.core) or senderId
        self:sayHello(senderId)

    elseif msg.type == net.MSG.CRAFT_REQUEST then
        self.core_id = senderId
        local p = payload
        self.cancelled = false
        self.current_task_id = p.task_id
        self.transfer_mode = p.transfer_mode or "buffer"
        self.buffer = p.buffer
        self.busy = true
        self.state = "loading"

        -- CRAFT_ACK ПЕРВЫМ — до любых turtle-операций.
        sendAck(self, p.task_id)

        local recipe = p.recipe
        local count = p.count or 1
        util.info("Craft: " .. tostring(recipe and recipe.id) .. " x" .. tostring(count)
            .. " (" .. tostring(self.transfer_mode) .. ")")

        -- Весь крафт под pcall: любая ошибка -> честный RESULT + сброс состояния.
        local ok, res1, res2, res3, res4 = pcall(self.craft, self, recipe, count,
            self.transfer_mode, self.buffer)

        self.busy = false
        self.state = "idle"
        local taskId = self.current_task_id
        self.current_task_id = nil
        self.buffer = self.buffer  -- сохраняем привязку буферов для следующих задач

        if not ok then
            util.err("Worker crash: " .. tostring(res1))
            sendResult(self, taskId, { success = false, error = "worker crash: " .. tostring(res1) })
            return
        end
        -- res1 = true/false, res2 = count|error, res3 = elapsed|nil, res4 = crafts|nil
        if res1 == true then
            sendStatus(self, taskId, 100, "done")
            sendResult(self, taskId, {
                success = true,
                count = res2,
                elapsed = res3,
                crafts = res4,
            })
            util.ok("Done: " .. tostring(res2) .. " pcs in "
                .. string.format("%.2f", res3 or 0) .. "s")
        else
            util.err("Craft error: " .. tostring(res2))
            sendResult(self, taskId, {
                success = false,
                error = tostring(res2),
                count = res3,  -- сколько успели скрафтить (для storage_full)
            })
        end

    elseif msg.type == net.MSG.CRAFT_CANCEL or msg.type == net.MSG.CANCEL then
        local tid = payload.task_id
        if tid and tid == self.current_task_id then
            self.cancelled = true
            util.warn("Cancel requested for task " .. tostring(tid))
        end

    elseif msg.type == net.MSG.LEARN_CRAFT_REQUEST then
        self.core_id = senderId
        turtle.select(1)
        local ok2 = turtle.craft(1)
        if ok2 then
            local found = nil
            for s = 1, 16 do
                local det = itemDetail(s)
                if det and det.name then found = det; break end
            end
            if found then
                net.send(senderId, net.MSG.LEARN_CRAFT_RESPONSE,
                    { success = true, name = found.name, displayName = found.displayName,
                      count = found.count, slot = s })
            else
                net.send(senderId, net.MSG.LEARN_CRAFT_RESPONSE,
                    { success = false, error = "could not find crafted item" })
            end
        else
            net.send(senderId, net.MSG.LEARN_CRAFT_RESPONSE,
                { success = false, error = "turtle.craft failed (invalid grid)" })
        end

    elseif msg.type == net.MSG.PING then
        net.send(senderId, net.MSG.PONG, { id = os.getComputerID() })
    end
end

return worker
