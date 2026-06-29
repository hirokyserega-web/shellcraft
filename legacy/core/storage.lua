-- core/storage.lua
-- Учёт предметов в хранилище (несколько сундуков/бочек по проводной сети) +
-- глобальный менеджер резерваций.
--
-- Ключевые обязанности:
--   * scan()  — полное сканирование инвентарей, кэш { [id] = {total, locations} }
--   * count(id) / available(id) — физическое и доступное (за вычетом резерва) число
--   * reserve / release — глобальные резервации, чтобы несколько задач не делили
--     один и тот же сток (устранение гонок «Not enough X»)
--   * extract(...) — перенести предметы в целевой инвентарь/слот с проверкой id
--   * deposit(...) — принять предметы из внешнего инвентаря
--
-- Совместимость с UI: count, items, scan, importFrom, names — сохранены.

local storage = {}
storage.__index = storage

--- Создать объект хранилища.
-- @param peripherals таблица из config.resolve() (поле .storage)
function storage.new(peripherals)
    local self = setmetatable({}, storage)
    self.names = {}
    self.cache = {}            -- { [id] = { total = n, locations = {{p,s,qty}} } }
    self.empty_slots = {}      -- { {p, s} } — кэш свободных слотов
    self.dirty = {}            -- { [id] = true } протухшие записи
    self.reservations = {}     -- { [resId] = { id, count, key } }
    self.reservedById = {}     -- { [id] = total_reserved }
    self._resSeq = 0
    if peripherals and peripherals.storage then
        for _, name in ipairs(peripherals.storage) do
            self.names[#self.names + 1] = name
        end
    end
    return self
end

local function wrap(name)
    if not peripheral.isPresent(name) then return nil end
    return peripheral.wrap(name)
end

----------------------------------------------------------------
-- СКАНИРОВАНИЕ
----------------------------------------------------------------

function storage:scan()
    local map = {}
    local empty = {}
    local iter = 0
    for _, name in ipairs(self.names) do
        iter = iter + 1
        if iter % 4 == 0 then os.sleep(0) end
        local p = wrap(name)
        if p and type(p.list) == "function" and type(p.size) == "function" then
            local ok, items = pcall(p.list)
            if ok and items then
                local size = p.size() or 0
                for slot, info in pairs(items) do
                    if info and info.name then
                        local id = info.name
                        local qty = info.count or 0
                        if not map[id] then map[id] = { total = 0, locations = {} } end
                        map[id].total = map[id].total + qty
                        map[id].locations[#map[id].locations + 1] = { p = name, s = slot, qty = qty }
                    end
                end
                for slot = 1, size do
                    if not items[slot] then
                        empty[#empty + 1] = { p = name, s = slot }
                    end
                end
            end
        end
    end
    self.cache = map
    self.empty_slots = empty
    self.dirty = {}
    self:clearDetailCache()
    return map
end

function storage:refreshEmptySlots()
    local empty = {}
    local count = 0
    for _, name in ipairs(self.names) do
        count = count + 1
        if count % 8 == 0 then os.sleep(0) end
        local p = wrap(name)
        if p and type(p.list) == "function" and type(p.size) == "function" then
            local ok, items = pcall(p.list)
            if ok and items then
                local size = p.size() or 0
                for slot = 1, size do
                    if not items[slot] then
                        empty[#empty + 1] = { p = name, s = slot }
                    end
                end
            end
        end
    end
    self.empty_slots = empty
    return empty
end

function storage:rescanItem(id)
    if not id then return 0 end
    local total = 0
    local locations = {}
    local count = 0
    for _, name in ipairs(self.names) do
        count = count + 1
        if count % 8 == 0 then os.sleep(0) end
        local p = wrap(name)
        if p and type(p.list) == "function" then
            local ok, items = pcall(p.list)
            if ok and items then
                for slot, info in pairs(items) do
                    if info and info.name == id then
                        local qty = info.count or 0
                        total = total + qty
                        locations[#locations + 1] = { p = name, s = slot, qty = qty }
                    end
                end
            end
        end
    end
    if total > 0 then
        self.cache[id] = { total = total, locations = locations }
    else
        self.cache[id] = nil
    end
    if self.dirty then self.dirty[id] = nil end
    return total
end

----------------------------------------------------------------
-- ЗАПРОСЫ КОЛИЧЕСТВА
----------------------------------------------------------------

--- Физическое количество предмета (без учёта резерва).
function storage:count(id)
    if self.dirty and self.dirty[id] then
        return self:rescanItem(id)
    end
    if self.cache[id] then return self.cache[id].total end
    return 0
end

--- Сколько зарезервировано предмета id.
function storage:reserved(id)
    return self.reservedById[id] or 0
end

--- Доступно для новых планов = физическое - зарезервированное.
function storage:available(id)
    local total = self:count(id)
    local res = self.reservedById[id] or 0
    local avail = total - res
    if avail < 0 then avail = 0 end
    return avail
end

function storage:items()
    local result = {}
    for id, info in pairs(self.cache) do
        result[#result + 1] = { id = id, count = info.total, reserved = self.reservedById[id] or 0 }
    end
    table.sort(result, function(a, b) return a.count > b.count end)
    return result
end

----------------------------------------------------------------
-- РЕЗЕРВАЦИИ
----------------------------------------------------------------

--- Зарезервировать count единиц предмета id под задачу.
-- Возвращает resId (строка) для последующего consume/release.
-- НЕ проверяет физическое наличие — это делает планировщик. Здесь только учёт.
function storage:reserve(id, count, key)
    if not id or not count or count <= 0 then return nil end
    self._resSeq = self._resSeq + 1
    local resId = "res_" .. self._resSeq
    self.reservations[resId] = { id = id, count = count, key = key }
    self.reservedById[id] = (self.reservedById[id] or 0) + count
    return resId
end

--- Полностью снять резервацию (отмена/провал задачи).
function storage:release(resId)
    local r = self.reservations[resId]
    if not r then return 0 end
    local released = r.count
    self.reservedById[r.id] = math.max(0, (self.reservedById[r.id] or 0) - released)
    self.reservations[resId] = nil
    return released
end

--- Уменьшить резервацию на amount (при фактическом extract).
-- Когда резервация исчерпана — удаляется.
function storage:consumeReservation(resId, amount)
    local r = self.reservations[resId]
    if not r then return 0 end
    amount = math.min(amount or r.count, r.count)
    r.count = r.count - amount
    self.reservedById[r.id] = math.max(0, (self.reservedById[r.id] or 0) - amount)
    if r.count <= 0 then
        self.reservations[resId] = nil
    end
    return amount
end

--- Снять все резервации по ключу (например, по task_id).
function storage:releaseByKey(key)
    if key == nil then return 0 end
    local released = 0
    for resId, r in pairs(self.reservations) do
        if r.key == key then
            released = released + self:release(resId)
        end
    end
    return released
end

--- Полная сводка резерваций (для отладки/персиста).
function storage:reservationSummary()
    local out = {}
    for id, qty in pairs(self.reservedById) do
        if qty > 0 then out[id] = qty end
    end
    return out
end

--- Снимок таблицы резерваций для персиста (переживает ребут Core).
function storage:reservationSnapshot()
    return {
        reservations = self.reservations,
        reservedById = self.reservedById,
        seq = self._resSeq,
    }
end

--- Восстановить таблицу резерваций из снимка (при загрузке очереди).
function storage:restoreReservations(snap)
    if type(snap) ~= "table" then return end
    self.reservations = type(snap.reservations) == "table" and snap.reservations or {}
    self.reservedById = type(snap.reservedById) == "table" and snap.reservedById or {}
    self._resSeq = tonumber(snap.seq) or 0
end

----------------------------------------------------------------
-- СОПОСТАВЛЕНИЕ ПО СПЕЦИФИКАЦИИ (теги / NBT / варианты)
----------------------------------------------------------------

local itemmatch = require("lib.itemmatch")

--- Получить (и закешировать) detail предмета по id из любого слота хранилища.
-- Нужен для сопоставления по тегам/NBT, которых нет в обычном list().
function storage:detailFor(id)
    if not id then return nil end
    self._detailCache = self._detailCache or {}
    if self._detailCache[id] ~= nil then
        return self._detailCache[id] or nil
    end
    local info = self.cache[id]
    if info and info.locations then
        for _, loc in ipairs(info.locations) do
            local p = wrap(loc.p)
            if p and p.getItemDetail then
                local ok, det = pcall(p.getItemDetail, loc.s)
                if ok and det and det.name == id then
                    self._detailCache[id] = det
                    return det
                end
            end
        end
    end
    -- Запомним «нет detail», чтобы не сканировать каждый раз.
    self._detailCache[id] = false
    return nil
end

--- Сбросить кеш detail (после scan, чтобы подхватить новые предметы).
function storage:clearDetailCache()
    self._detailCache = {}
end

--- Является ли spec простым именем (без тегов/вариантов/NBT)?
local function isPlainName(spec)
    return type(spec) == "string" or (type(spec) == "table" and (spec.id or spec.name)
        and not spec.variants and not spec.tag and not spec.tags
        and spec.nbt == nil and spec.components == nil and not spec.any)
end

--- Подобрать конкретный id под спецификацию ингредиента, учитывая доступный
-- (за вычетом резерва) запас. Для простого имени возвращает само имя.
-- @param spec спецификация (строка/таблица/variants/tag)
-- @param needed сколько нужно (для выбора варианта с достаточным запасом)
-- @return concreteId, availableCount  (или nil, 0 если нет подходящего)
function storage:resolveSpec(spec, needed)
    needed = needed or 1
    -- Быстрый путь: простое имя.
    if isPlainName(spec) then
        local id = type(spec) == "string" and spec or (spec.id or spec.name)
        return id, self:available(id)
    end

    local norm = itemmatch.normalize(spec)
    if not norm then return nil, 0 end

    -- Кандидаты: явные имена вариантов, иначе — все id в кэше.
    local candidates = {}
    local function addCandidate(id)
        if id then candidates[#candidates + 1] = id end
    end
    if norm.variants then
        for _, v in ipairs(norm.variants) do
            local vn = itemmatch.normalize(v)
            if vn and vn.name then addCandidate(vn.name) end
        end
    elseif norm.name then
        addCandidate(norm.name)
    end

    -- Если кандидаты не заданы именами (тег/any) — перебираем кэш.
    local scanCache = (#candidates == 0)
    local best, bestAvail = nil, 0
    local function consider(id)
        local det = self:detailFor(id)
        if not det then det = { name = id } end
        if itemmatch.matches(det, spec) then
            local avail = self:available(id)
            -- Предпочитаем вариант, которого хватает целиком; иначе максимум.
            if avail >= needed and (best == nil or bestAvail < needed) then
                best, bestAvail = id, avail
            elseif avail > bestAvail and not (best and bestAvail >= needed) then
                best, bestAvail = id, avail
            end
        end
    end

    if scanCache then
        for id in pairs(self.cache) do consider(id) end
    else
        for _, id in ipairs(candidates) do consider(id) end
    end
    return best, bestAvail
end

--- Сумма доступного по спецификации (по всем подходящим вариантам).
function storage:availableSpec(spec)
    if isPlainName(spec) then
        local id = type(spec) == "string" and spec or (spec.id or spec.name)
        return self:available(id)
    end
    local total = 0
    local norm = itemmatch.normalize(spec)
    if not norm then return 0 end
    if norm.variants then
        for _, v in ipairs(norm.variants) do
            local id, avail = self:resolveSpec(v, 1)
            if id then total = total + (self:available(id)) end
        end
        return total
    end
    for id in pairs(self.cache) do
        local det = self:detailFor(id) or { name = id }
        if itemmatch.matches(det, spec) then
            total = total + self:available(id)
        end
    end
    return total
end

----------------------------------------------------------------
-- EXTRACT / DEPOSIT
----------------------------------------------------------------

--- Извлечь предметы id/spec в целевой инвентарь.
-- @param id ID предмета или spec-таблица
-- @param count сколько
-- @param targetPeripheral имя целевого инвентаря
-- @param targetSlot номер слота (целое) или nil (любой слот)
-- @return сколько реально перемещено
function storage:extract(id, count, targetPeripheral, targetSlot)
    local spec = nil
    if type(id) == "table" then
        spec = id
        id = self:resolveSpec(spec, count)
        if type(id) ~= "string" then return 0 end
    end
    local info = self.cache[id]
    if not info or info.total <= 0 then return 0 end

    local remaining = count
    local moved = 0
    local removedStale = false
    local i = 1
    while i <= #info.locations do
        if remaining <= 0 then break end
        local loc = info.locations[i]
        local p = wrap(loc.p)
        if not p then
            table.remove(info.locations, i)
            removedStale = true
        else
            -- Сверяем реальный id слота-источника перед переносом.
            local realId, realQty, realDet = nil, 0, nil
            if p.getItemDetail then
                local okD, det = pcall(p.getItemDetail, loc.s)
                if okD and det then realId, realQty, realDet = det.name, det.count or 0, det end
            elseif p.list then
                local okLs, ls = pcall(p.list)
                if okLs and ls and ls[loc.s] then realId, realQty = ls[loc.s].name, ls[loc.s].count or 0 end
            end
            if realId ~= nil and realId ~= id then
                table.remove(info.locations, i)
                removedStale = true
            elseif spec and realDet and not itemmatch.matches(realDet, spec) then
                -- Тот же id, но другой NBT/компоненты — не берём этот слот.
                i = i + 1
            else
                local toMove = math.min(remaining, loc.qty)
                if realId == id and realQty < toMove then toMove = realQty end
                local ok, n = false, 0
                if p.pushItems then
                    if targetSlot then
                        ok, n = pcall(p.pushItems, targetPeripheral, loc.s, toMove, targetSlot)
                    else
                        ok, n = pcall(p.pushItems, targetPeripheral, loc.s, toMove)
                    end
                end
                if (not ok or not n or n == 0) then
                    local target = wrap(targetPeripheral)
                    if target and target.pullItems then
                        if targetSlot then
                            ok, n = pcall(target.pullItems, loc.p, loc.s, toMove, targetSlot)
                        else
                            ok, n = pcall(target.pullItems, loc.p, loc.s, toMove)
                        end
                    end
                end
                if ok and n and n > 0 then
                    moved = moved + n
                    remaining = remaining - n
                    loc.qty = loc.qty - n
                    if loc.qty <= 0 then
                        self.empty_slots[#self.empty_slots + 1] = { p = loc.p, s = loc.s }
                        table.remove(info.locations, i)
                    else
                        i = i + 1
                    end
                else
                    -- Слот ничего не отдал: либо протух, либо целевой занят.
                    table.remove(info.locations, i)
                    removedStale = true
                end
            end
        end
    end
    if info then info.total = math.max(0, (info.total or 0) - moved) end
    if moved < count or removedStale then
        self.dirty = self.dirty or {}
        self.dirty[id] = true
    end
    return moved
end

--- Принять предметы из внешнего инвентаря в хранилище.
-- @param sourcePeripheral имя источника
-- @param sourceSlot слот источника
-- @param count сколько (nil = весь слот)
-- @return сколько перемещено
function storage:deposit(sourcePeripheral, sourceSlot, count)
    local src = wrap(sourcePeripheral)
    if not src then return 0 end

    local id, toMove
    if type(src.getItemDetail) == "function" then
        local ok, detail = pcall(src.getItemDetail, sourceSlot)
        if ok then
            if detail then
                id = detail.name
                toMove = count or detail.count or 0
            else
                return 0
            end
        end
    end
    if not id and type(src.list) == "function" then
        local ok, list = pcall(src.list)
        if ok and list then
            local item = list[sourceSlot]
            if item then
                id = item.name
                toMove = count or item.count or 0
            else
                return 0
            end
        end
    end
    if not id or not toMove or toMove <= 0 then return 0 end

    local moved = 0

    -- 1) Доложить в существующие стаки того же id.
    if self.cache[id] and self.cache[id].locations then
        for _, loc in ipairs(self.cache[id].locations) do
            if toMove <= 0 then break end
            if loc.p ~= sourcePeripheral then
                local p = wrap(loc.p)
                if p then
                    local ok2, n = false, 0
                    if p.pullItems then
                        ok2, n = pcall(p.pullItems, sourcePeripheral, sourceSlot, toMove, loc.s)
                    end
                    if (not ok2 or not n or n == 0) and src.pushItems then
                        ok2, n = pcall(src.pushItems, loc.p, sourceSlot, toMove, loc.s)
                    end
                    if ok2 and n and n > 0 then
                        moved = moved + n
                        toMove = toMove - n
                        loc.qty = loc.qty + n
                    end
                end
            end
        end
    end

    -- 2) Заполнить пустые слоты.
    local function fillEmptySlots()
        if not (toMove > 0) then return end
        local i = 1
        while i <= #self.empty_slots and toMove > 0 do
            local slotInfo = self.empty_slots[i]
            if slotInfo.p ~= sourcePeripheral then
                local p = wrap(slotInfo.p)
                if p then
                    local ok2, n = false, 0
                    if p.pullItems then
                        ok2, n = pcall(p.pullItems, sourcePeripheral, sourceSlot, toMove, slotInfo.s)
                    end
                    if (not ok2 or not n or n == 0) and src.pushItems then
                        ok2, n = pcall(src.pushItems, slotInfo.p, sourceSlot, toMove, slotInfo.s)
                    end
                    if ok2 and n and n > 0 then
                        moved = moved + n
                        toMove = toMove - n
                        if not self.cache[id] then self.cache[id] = { total = 0, locations = {} } end
                        self.cache[id].locations[#self.cache[id].locations + 1] = { p = slotInfo.p, s = slotInfo.s, qty = n }
                        table.remove(self.empty_slots, i)
                    else
                        i = i + 1
                    end
                else
                    i = i + 1
                end
            else
                i = i + 1
            end
        end
    end

    fillEmptySlots()

    if moved == 0 and toMove > 0 then
        self:refreshEmptySlots()
        fillEmptySlots()
    end

    if moved > 0 then
        if not self.cache[id] then self.cache[id] = { total = 0, locations = {} } end
        self.cache[id].total = (self.cache[id].total or 0) + moved
    end
    return moved
end

function storage:depositAll(sourcePeripheral, sourceSlot)
    return self:deposit(sourcePeripheral, sourceSlot, nil)
end

----------------------------------------------------------------
-- ИМПОРТ
----------------------------------------------------------------

function storage:importFrom(chestName, slotLimit)
    local targetChest = chestName
    if not targetChest or targetChest == "" then
        local cfg = config.load()
        targetChest = cfg.default_import
        if (not targetChest or targetChest == "") and cfg.import_chests then
            for _, name in ipairs(cfg.import_chests) do
                if peripheral.isPresent(name) then targetChest = name; break end
            end
        end
    end
    if not targetChest or targetChest == "" then
        return 0, "No import chest configured"
    end
    if not peripheral.isPresent(targetChest) then
        return 0, "Import chest '" .. tostring(targetChest) .. "' is not present on the network"
    end
    local p = wrap(targetChest)
    if not p or not p.size or not p.list then
        return 0, "Chest " .. tostring(targetChest) .. " is not reachable or not a container"
    end
    if not self.names or #self.names == 0 then
        return 0, "No storage chests/barrels connected to the network"
    end

    local list = p.list()
    local size = p.size()
    local totalMoved = 0
    local slotsProcessed = 0
    local hasItems = false
    local anyFull = false

    for slot = 1, size do
        if list[slot] then
            local itemCount = list[slot].count or 0
            if itemCount > 0 then
                hasItems = true
                if slotLimit and slotsProcessed >= slotLimit then break end
                local n = self:deposit(targetChest, slot, nil)
                if n > 0 then
                    totalMoved = totalMoved + n
                    slotsProcessed = slotsProcessed + 1
                    if n < itemCount then anyFull = true end
                    os.sleep(0)
                else
                    anyFull = true
                end
            end
        end
    end

    if hasItems and totalMoved == 0 then
        return 0, "storage_full"
    end
    return totalMoved, anyFull and "partial" or nil
end

----------------------------------------------------------------
-- ИМЕНА
----------------------------------------------------------------

function storage:displayName(id)
    for _, name in ipairs(self.names) do
        local p = wrap(name)
        if p and p.list then
            local ok, items = pcall(p.list)
            if ok and items then
                for slot, info in pairs(items) do
                    if info.name == id and p.getItemDetail then
                        local ok2, det = pcall(p.getItemDetail, slot)
                        if ok2 and det and det.displayName then return det.displayName end
                    end
                end
            end
        end
    end
    return nil
end

function storage:collectNames(namesModule)
    if not namesModule then return 0 end
    local collected = 0
    for _, name in ipairs(self.names) do
        local p = wrap(name)
        if p and p.list and p.getItemDetail then
            local ok, items = pcall(p.list)
            if ok and items then
                for slot, info in pairs(items) do
                    local id = info.name
                    if id and not namesModule.cache[id] then
                        local ok2, det = pcall(p.getItemDetail, slot)
                        if ok2 and det and det.displayName then
                            namesModule.cacheName(id, det.displayName)
                            collected = collected + 1
                        end
                    end
                end
            end
        end
    end
    return collected
end

return storage
