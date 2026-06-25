-- core/machines.lua
-- Работа со спец-механизмами (печь, blast_furnace, smoker, и т.п.).
-- Цикл: положить вход -> дождаться -> забрать результат -> вернуть в хранилище.

local machines = {}
machines.__index = machines

--- Раскладка слотов по типу машины.
-- {input=..., fuel=..., output=...}
machines.SLOTS = {
    ["minecraft:furnace"]       = { input = {1}, fuel = {2}, output = {3} },
    ["minecraft:blast_furnace"] = { input = {1}, fuel = {2}, output = {3} },
    ["minecraft:smoker"]        = { input = {1}, fuel = {2}, output = {3} },
    ["minecraft:brewer"]        = { input = {1, 2, 3}, fuel = {4}, output = {5} },
    furnace       = { input = {1}, fuel = {2}, output = {3} },
    blast_furnace = { input = {1}, fuel = {2}, output = {3} },
    smoker        = { input = {1}, fuel = {2}, output = {3} },
    brewer        = { input = {1, 2, 3}, fuel = {4}, output = {5} },
}

--- Создать объект управления машинами.
-- @param peripherals таблица из config.resolve() -> .machines = {имена}
-- @param storage объект storage
function machines.new(peripherals, storage)
    local self = setmetatable({}, machines)
    self.storage = storage
    self.names = {}
    if peripherals and peripherals.machines then
        for _, name in ipairs(peripherals.machines) do
            table.insert(self.names, name)
        end
    end
    self.onEvent = nil
    return self
end

function machines:setEventHandler(fn)
    self.onEvent = fn
end

local function emit(self, etype, payload)
    if self.onEvent then self.onEvent(etype, payload) end
end

local function wrap(name)
    if not peripheral.isPresent(name) then return nil end
    return peripheral.wrap(name)
end

--- Определить слоты для машины по типу.
function machines:_slots(name)
    local ptype = peripheral.getType(name)
    if machines.SLOTS[ptype] then
        return machines.SLOTS[ptype], ptype
    end
    -- Check base type if namespaced type not found in SLOTS
    local _, base = ptype:match("^([^:]+):(.+)$")
    if base and machines.SLOTS[base] then
        return machines.SLOTS[base], ptype
    end
    -- Эвристика: size() == 3 -> печь, иначе input=первый, output=последний
    local p = wrap(name)
    if not p or not p.size then return nil, ptype end
    local sz = p.size()
    if sz == 3 then
        return { input = {1}, fuel = {2}, output = {3} }, ptype
    elseif sz and sz > 1 then
        return { input = {1}, fuel = {}, output = {sz} }, ptype
    end
    return { input = {1}, fuel = {}, output = {2} }, ptype
end

--- Информация о машине (тип, занятость, что готовится).
-- @return { name, type, busy, cooking, input_items, output_items, fuel }
function machines:info(name)
    local p = wrap(name)
    if not p or not p.list then return nil end
    local slots, ptype = self:_slots(name)
    local list = p.list()
    local info = {
        name = name,
        type = ptype,
        slots = slots,
        busy = false,
        cooking = false,
        input_items = {},
        output_items = {},
        fuel = 0,
    }
    local function isFilled(slot)
        return list[slot] ~= nil
    end
    -- Проверяем топливо
    if slots.fuel and #slots.fuel > 0 then
        for _, s in ipairs(slots.fuel) do
            if isFilled(s) then info.fuel = info.fuel + 1 end
        end
    end
    -- Вход
    for _, s in ipairs(slots.input) do
        if isFilled(s) then
            table.insert(info.input_items, list[s].name)
            info.cooking = true
        end
    end
    -- Выход
    for _, s in ipairs(slots.output) do
        if isFilled(s) then
            table.insert(info.output_items, list[s].name .. " x" .. list[s].count)
        end
    end
    info.busy = info.cooking and #info.output_items == 0
    -- Если есть результат, но нет входа — готово, ждёт извлечения
    info.ready = #info.output_items > 0
    return info
end

--- Список всех машин с информацией (для UI).
function machines:list()
    local arr = {}
    for _, name in ipairs(self.names) do
        local inf = self:info(name)
        if inf then table.insert(arr, inf) end
    end
    return arr
end

--- Сколько машин подключено.
function machines:count()
    return #self.names
end

--- Alias info -> status (для UI, более короткое имя).
machines.status = machines.info

--- Найти свободную машину нужного типа.
-- @param machineType тип (например "furnace")
-- @return имя машины или nil
function machines:findFree(machineType)
    local function matchType(ptype, mtype)
        if not ptype or not mtype then return false end
        if ptype == mtype then return true end
        local p_ns, p_base = ptype:match("^([^:]+):(.+)$")
        local m_ns, m_base = mtype:match("^([^:]+):(.+)$")
        p_base = p_base or ptype
        m_base = m_base or mtype
        if p_ns and m_ns and p_ns ~= m_ns then return false end
        return p_base == m_base
    end

    for _, name in ipairs(self.names) do
        local ptype = peripheral.getType(name)
        local match = (machineType == nil) or matchType(ptype, machineType) or
                      (ptype and machineType and ptype:find(machineType, 1, true) ~= nil)
        if match then
            local inf = self:info(name)
            if inf and not inf.cooking and not inf.ready then
                return name
            end
        end
    end
    return nil
end

--- Положить входные предметы в машину.
-- @param name имя машины
-- @param ingredients массив { {id, count} }
-- @return true если всё положили
function machines:_feed(name, ingredients)
    local slots = self:_slots(name)
    if not slots then return false, "unknown slot layout" end
    for i, ing in ipairs(ingredients) do
        local targetSlot = slots.input[i] or slots.input[1]
        local moved = self.storage:extract(ing.id, ing.count, name, targetSlot)
        if moved < ing.count then
            return false, "missing " .. (ing.count - moved) .. " " .. lang.localize(ing.id)
        end
    end
    return true
end

--- Ждать результат с таймаутом.
-- @param name имя машины
-- @param timeout секунд
-- @return true если результат появился
function machines:_waitResult(name, timeout)
    timeout = timeout or 60
    local slots = self:_slots(name)
    if not slots then return false end
    local p = wrap(name)
    if not p then return false end
    local deadline = os.clock() + timeout
    while os.clock() < deadline do
        local list = p.list()
        local hasResult = false
        for _, s in ipairs(slots.output) do
            if list[s] ~= nil then hasResult = true; break end
        end
        if hasResult then return true end
        os.sleep(0.5)
    end
    return false, "timeout waiting for result"
end

--- Забрать результат из машины в хранилище.
-- @return сколько перемещено
function machines:_collect(name)
    local slots = self:_slots(name)
    if not slots then return 0 end
    local total = 0
    for _, s in ipairs(slots.output) do
        local n = self.storage:deposit(name, s, nil)
        total = total + n
    end
    return total
end

--- Полный цикл обработки машиной.
-- @param recipe рецепт типа "machine" (machine, input, output, id)
-- @param count сколько штук результата нужно
-- @return true, перемещено | false, ошибка
function machines:process(recipe, count)
    if not recipe or recipe.type ~= "machine" then
        return false, "recipe not for machine"
    end
    -- Сколько циклов машины нужно
    local output = recipe.output or 1
    local cycles = math.ceil(count / output)
    local need = cycles * output
    -- Масштабируем вход на cycles
    local input = {}
    for _, ing in ipairs(recipe.input or {}) do
        table.insert(input, { id = ing.id, count = ing.count * cycles })
    end
    -- Ищем свободную машину
    local machineName = self:findFree(recipe.machine)
    if not machineName then
        return false, "no free machine of type " .. tostring(recipe.machine)
    end
    emit(self, "machine_start", { name = machineName, recipe = recipe.id, count = need })
    local t0 = os.epoch("utc")
    -- Кладём вход
    local ok, err = self:_feed(machineName, input)
    if not ok then
        emit(self, "machine_error", { name = machineName, error = err })
        return false, err
    end
    -- Ждём (таймаут ~ 10 сек на цикл)
    local waitOk, werr = self:_waitResult(machineName, math.max(60, cycles * 10))
    if not waitOk then
        emit(self, "machine_error", { name = machineName, error = werr })
        return false, werr
    end
    -- Забираем результат
    local moved = self:_collect(machineName)
    local t1 = os.epoch("utc")
    local elapsed = (t1 - t0) / 1000
    if elapsed < 0 then elapsed = 0 end
    emit(self, "machine_done", { name = machineName, recipe = recipe.id, count = moved })
    return true, moved, elapsed, cycles
end

--- Проверка/перебор готовых машин (собрать результаты, что уже готовы).
-- Вызывается сервером периодически.
function machines:collectReady()
    local total = 0
    for _, name in ipairs(self.names) do
        local inf = self:info(name)
        if inf and inf.ready then
            total = total + self:_collect(name)
        end
    end
    return total
end

return machines
