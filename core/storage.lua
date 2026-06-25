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
    for _, name in ipairs(self.names) do
        local p = wrap(name)
        if p and type(p.list) == "function" then
            local ok, items = pcall(p.list)
            if ok and items then
                for slot, info in pairs(items) do
                    local id = info.name
                    if id then
                        local qty = info.count or 0
                        if not map[id] then
                            map[id] = { total = 0, locations = {} }
                        end
                        map[id].total = map[id].total + qty
                        table.insert(map[id].locations, { p = name, s = slot, qty = qty })
                    end
                end
            end
        end
    end
    self.cache = map
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
    for _, loc in ipairs(info.locations) do
        if remaining <= 0 then break end
        local p = wrap(loc.p)
        if p and p.pushItems then
            local toMove = math.min(remaining, loc.qty)
            local ok, n = pcall(p.pushItems, targetPeripheral, loc.s, toMove, targetSlot)
            if ok and n then
                moved = moved + n
                remaining = remaining - n
                loc.qty = loc.qty - n
            end
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
    if not src or not src.getItemDetail then return 0 end
    local ok, detail = pcall(src.getItemDetail, sourceSlot)
    if not ok or not detail then return 0 end
    local toMove = count or detail.count or 0
    local id = detail.name
    local moved = 0
    -- Сначала пытаемся сложить в существующие стеки того же id
    for _, name in ipairs(self.names) do
        if toMove <= 0 then break end
        local p = wrap(name)
        if p and p.pullItems then
            local ok2, n = pcall(p.pullItems, sourcePeripheral, sourceSlot, toMove)
            if ok2 and n then
                moved = moved + n
                toMove = toMove - n
            end
        end
    end
    -- Обновляем кэш
    if moved > 0 then
        if not self.cache[id] then self.cache[id] = { total = 0, locations = {} } end
        self.cache[id].total = (self.cache[id].total or 0) + moved
    end
    return moved
end

--- Принять весь слот целиком (deposit всех предметов слота).
function storage:depositAll(sourcePeripheral, sourceSlot)
    return self:deposit(sourcePeripheral, sourceSlot, nil)
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
                        local ok2, det = pcall(p.getItemDetail, slot)
                        if ok2 and det and det.displayName then
                            return det.displayName
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
                    -- берём displayName только если ещё не в кеше и не в словаре
                    if id and not namesModule.cache[id]
                       and not (ru and ru.dict and ru.dict[id]) then
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
