-- core/storage.lua
-- Работа с хранилищем предметов (несколько сундуков/бочек по проводному модему).
-- Поддержка pushItems/pullItems для перемещения между инвентарями.

local storage = {}
storage.__index = storage

--- Создать объект хранилища.
-- @param peripherals таблица из config.resolve() -> .storage = {имена инвентарей}
function storage.new(peripherals)
    local self = setmetatable({}, storage)
    self.names = {}      -- список имён инвентарей
    self.cache = {}      -- { [id] = { total = n, locations = {{p,s,qty},...} } }
    self.empty_slots = {} -- кэш свободных слотов для ускорения импорта/депозита
    if peripherals and peripherals.storage then
        for _, name in ipairs(peripherals.storage) do
            table.insert(self.names, name)
        end
    end
    return self
end

--- Обёртка: безопасно получить объект периферии.
local function wrap(name)
    if not peripheral.isPresent(name) then return nil end
    return peripheral.wrap(name)
end

--- Полное сканирование всех инвентарей.
-- Возвращает карту { [id] = { total = n, locations = {{p,s,qty}}, name = ... } }.
function storage:scan()
    local map = {}
    local empty = {}
    local count = 0
    for _, name in ipairs(self.names) do
        count = count + 1
        if count % 8 == 0 then
            os.sleep(0)
        end
        local p = wrap(name)
        if p and type(p.list) == "function" and type(p.size) == "function" then
            local ok, items = pcall(p.list)
            if ok and items then
                local size = p.size() or 0
                for slot = 1, size do
                    local info = items[slot]
                    if info then
                        local id = info.name
                        if id then
                            local qty = info.count or 0
                            if not map[id] then
                                map[id] = { total = 0, locations = {} }
                            end
                            map[id].total = map[id].total + qty
                            table.insert(map[id].locations, { p = name, s = slot, qty = qty })
                        end
                    else
                        table.insert(empty, { p = name, s = slot })
                    end
                end
            end
        end
    end
    self.cache = map
    self.empty_slots = empty
    return map
end

--- Сколько всего предмета id в хранилище.
function storage:count(id)
    if self.cache[id] then return self.cache[id].total end
    -- fallback: быстрый пересчёт
    local total = 0
    for _, name in ipairs(self.names) do
        local p = wrap(name)
        if p and p.list then
            local ok, items = pcall(p.list)
            if ok and items then
                for _, info in pairs(items) do
                    if info.name == id then total = total + (info.count or 0) end
                end
            end
        end
    end
    return total
end

--- Список всех ID с количеством (отсканированных).
function storage:items()
    local result = {}
    for id, info in pairs(self.cache) do
        table.insert(result, { id = id, count = info.total })
    end
    table.sort(result, function(a, b) return a.count > b.count end)
    return result
end

--- Извлечь N предметов с данным id и положить в целевой инвентарь/слот.
-- @param id ID предмета
-- @param count сколько
-- @param targetPeripheral имя целевого инвентаря (куда класть)
-- @param targetSlot слот назначения (опц.)
-- @return сколько реально перемещено
function storage:extract(id, count, targetPeripheral, targetSlot)
    local info = self.cache[id]
    if not info or info.total <= 0 then return 0 end
    local remaining = count
    local moved = 0
    local i = 1
    while i <= #info.locations do
        if remaining <= 0 then break end
        local loc = info.locations[i]
        local p = wrap(loc.p)
        if p then
            local toMove = math.min(remaining, loc.qty)
            local ok, n = false, 0
            if p.pushItems then
                if targetSlot then
                    ok, n = pcall(p.pushItems, targetPeripheral, loc.s, toMove, targetSlot)
                else
                    ok, n = pcall(p.pushItems, targetPeripheral, loc.s, toMove)
                end
            end
            if not ok or not n or n == 0 then
                -- Fallback: pull from target peripheral
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
                if loc.qty == 0 then
                    if self.empty_slots then
                        table.insert(self.empty_slots, { p = loc.p, s = loc.s })
                    end
                    table.remove(info.locations, i)
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
    if info then info.total = (info.total or 0) - moved end
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
    local hasGetItemDetail = type(src.getItemDetail) == "function"
    local hasList = type(src.list) == "function"
    local queried = false
    
    if hasGetItemDetail then
        local ok, detail = pcall(src.getItemDetail, sourceSlot)
        if ok then
            queried = true
            if detail then
                id = detail.name
                toMove = count or detail.count or 0
            else
                -- Slot is definitely empty!
                return 0
            end
        end
    end
    
    if not queried and hasList then
        local ok, list = pcall(src.list)
        if ok and list then
            queried = true
            local item = list[sourceSlot]
            if item then
                id = item.name
                toMove = count or item.count or 0
            else
                -- Slot is definitely empty!
                return 0
            end
        end
    end

    local moved = 0

    if id and toMove and toMove > 0 then
        -- 1. Try to deposit into existing slots of the same item ID
        if self.cache[id] and self.cache[id].locations then
            for _, loc in ipairs(self.cache[id].locations) do
                if toMove <= 0 then break end
                -- Skip depositing into the source peripheral itself
                if loc.p ~= sourcePeripheral then
                    local p = wrap(loc.p)
                    if p then
                        local ok2, n = false, 0
                        if p.pullItems then
                            ok2, n = pcall(p.pullItems, sourcePeripheral, sourceSlot, toMove, loc.s)
                        end
                        if not ok2 or not n or n == 0 then
                            -- Fallback: push from source peripheral
                            if src.pushItems then
                                ok2, n = pcall(src.pushItems, loc.p, sourceSlot, toMove, loc.s)
                            end
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

        -- 2. If there are still items left to move, find empty slots using cached self.empty_slots
        if toMove > 0 and self.empty_slots then
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
                        if not ok2 or not n or n == 0 then
                            if src.pushItems then
                                ok2, n = pcall(src.pushItems, slotInfo.p, sourceSlot, toMove, slotInfo.s)
                            end
                        end
                        if ok2 and n and n > 0 then
                            moved = moved + n
                            toMove = toMove - n
                            
                            -- Update cache
                            if not self.cache[id] then
                                self.cache[id] = { total = 0, locations = {} }
                            end
                            table.insert(self.cache[id].locations, { p = slotInfo.p, s = slotInfo.s, qty = n })
                            
                            -- Since we put items in this slot, it's no longer empty. Remove it from empty_slots.
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

        -- 3. Update the total cache count
        if moved > 0 then
            if not self.cache[id] then
                self.cache[id] = { total = 0, locations = {} }
            end
            self.cache[id].total = (self.cache[id].total or 0) + moved
        end
    elseif not queried then
        -- Fallback path: We do not know what item is in the source slot.
        -- We will pull from sourceSlot into empty slots of our storage chests using cached empty_slots.
        local limit = count or 64
        if self.empty_slots then
            local i = 1
            while i <= #self.empty_slots and limit > 0 do
                local slotInfo = self.empty_slots[i]
                if slotInfo.p ~= sourcePeripheral then
                    local p = wrap(slotInfo.p)
                    if p then
                        local ok2, n = false, 0
                        if p.pullItems then
                            ok2, n = pcall(p.pullItems, sourcePeripheral, sourceSlot, limit, slotInfo.s)
                        end
                        if ok2 and n and n > 0 then
                            moved = moved + n
                            limit = limit - n
                            
                            -- Now wrap/query chest to find out what item we just pulled
                            local detail
                            if p.getItemDetail then
                                local ok3, det = pcall(p.getItemDetail, slotInfo.s)
                                if ok3 and det then detail = det end
                            end
                            if detail and detail.name then
                                local item_id = detail.name
                                if not self.cache[item_id] then
                                    self.cache[item_id] = { total = 0, locations = {} }
                                end
                                self.cache[item_id].total = (self.cache[item_id].total or 0) + n
                                table.insert(self.cache[item_id].locations, { p = slotInfo.p, s = slotInfo.s, qty = n })
                            end
                            
                            table.remove(self.empty_slots, i)
                        else
                            -- If we couldn't pull anything, the source slot is likely empty or we can't pull at all.
                            -- Break out immediately.
                            break
                        end
                    else
                        i = i + 1
                    end
                else
                    i = i + 1
                end
            end
        end
    end

    return moved
end

--- Принять весь слот целиком (deposit всех предметов слота).
function storage:depositAll(sourcePeripheral, sourceSlot)
    return self:deposit(sourcePeripheral, sourceSlot, nil)
end

--- Импортировать предметы из импортного сундука в хранилище.
-- @param chestName имя сундука (опц., если пусто — автовыбор из конфига)
-- @param slotLimit лимит обрабатываемых заполненных слотов (опц.)
-- @return перемещено предметов, nil | 0, ошибка
function storage:importFrom(chestName, slotLimit)
    local targetChest = chestName
    -- Только если имя не передано явно — смотрим в конфиг
    if not targetChest or targetChest == "" then
        local cfg = config.load()
        targetChest = cfg.default_import
        if not targetChest or targetChest == "" then
            if cfg.import_chests and #cfg.import_chests > 0 then
                for _, name in ipairs(cfg.import_chests) do
                    if peripheral.isPresent(name) then
                        targetChest = name
                        break
                    end
                end
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


    -- Сканируем содержимое импорт-сундука ОДНИРАЗ (не повторяем после каждого хода)
    local list = p.list()
    local size = p.size()
    local totalMoved = 0
    local slotsProcessed = 0
    local hasItems = false
    local anyFull = false  -- хоть один слот не удалось полностью перелить

    for slot = 1, size do
        if list[slot] then
            local itemCount = list[slot].count or 0
            if itemCount > 0 then
                hasItems = true
                if slotLimit and slotsProcessed >= slotLimit then
                    break
                end
                local n = self:deposit(targetChest, slot, nil)
                if n > 0 then
                    totalMoved = totalMoved + n
                    slotsProcessed = slotsProcessed + 1
                    -- Если перенесли не всё — хранилище полное
                    if n < itemCount then
                        anyFull = true
                    end
                    os.sleep(0)
                elseif n == 0 then
                    -- Не удалось перенести ни одного — хранилище полное
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

--- Получить displayName предмета из getItemDetail (fallback для локализации).
function storage:displayName(id)
    for _, name in ipairs(self.names) do
        local p = wrap(name)
        if p and p.list then
            local ok, items = pcall(p.list)
            if ok and items then
                for slot, info in pairs(items) do
                    if info.name == id then
                        if p.getItemDetail then
                            local ok2, det = pcall(p.getItemDetail, slot)
                            if ok2 and det and det.displayName then
                                return det.displayName
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

--- Собрать displayName для всех уникальных предметов в хранилище
-- и закешировать их через модуль names. Вызывается сервером один раз
-- при старте (и периодически), чтобы UI не дёргал getItemDetail каждый кадр.
-- @param namesModule объект names (lib/names.lua)
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
                    -- берём displayName только если ещё не в кеше
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
