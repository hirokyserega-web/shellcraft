-- core/fluids.lua
-- Управление хранилищем жидкостей (баки-хранилища, данки).
-- Поддержка pushFluid/pullFluid для перемещения жидкостей.

local fluids = {}
fluids.__index = fluids

local function wrap(name)
    if not peripheral.isPresent(name) then return nil end
    return peripheral.wrap(name)
end

local function loadLocalConfig()
    if fs.exists("config.local.lua") then
        local ok, res = pcall(dofile, "config.local.lua")
        if ok and type(res) == "table" then return res end
    end
    return {}
end

local function saveLocalConfig(cfg)
    local f = fs.open("config.local.lua", "w")
    if f then
        f.write("return " .. textutils.serialize(cfg))
        f.close()
        return true
    end
    return false
end

--- Создать менеджер жидкостей.
function fluids.new(peripherals, storageObj)
    local self = setmetatable({}, fluids)
    self.storage = storageObj
    self.pool_names = {}   -- имена баков общего пула
    self.danks = {}        -- { { periph = "...", fluid = "...", target = 16000 } }
    self.cache = {}        -- { [fluid] = { total = mb, locations = { {periph, amount}, ... } } }
    self.dank_cache = {}   -- { [periph] = { fluid, current_mb, target_mb, percent } }

    self:loadConfig()
    self:resolvePool(peripherals)
    return self
end

--- Загрузить конфигурацию данков и ручных переопределений баков.
function fluids:loadConfig()
    local localCfg = loadLocalConfig()
    self.danks = localCfg.danks or {}
    self.manual_pool = localCfg.fluid_storage
end

--- Разрешить список баков общего пула и данков.
function fluids:resolvePool(peripherals)
    self.pool_names = {}
    
    -- Получаем все danks в виде set для быстрого поиска
    local dankSet = {}
    for _, dk in ipairs(self.danks) do
        dankSet[dk.periph] = true
    end

    -- Также исключаем default dank из настроек
    local mainCfg = {}
    if fs.exists("config.dat") then
        local f = fs.open("config.dat", "r")
        if f then
            mainCfg = textutils.unserialize(f.readAll()) or {}
            f.close()
        end
    end
    if mainCfg.grid_dank then
        dankSet[mainCfg.grid_dank] = true
    end

    -- Если есть ручное переопределение общего пула
    if self.manual_pool and #self.manual_pool > 0 then
        for _, name in ipairs(self.manual_pool) do
            if peripheral.isPresent(name) and not dankSet[name] then
                table.insert(self.pool_names, name)
            end
        end
        return
    end

    -- Иначе автоопределение:
    -- Все fluid_storage, которые не являются станцией и не являются данком.
    -- Станция = (inventory или fluid) и не входит в storage (предметы).
    for _, name in ipairs(peripheral.getNames()) do
        if not dankSet[name] then
            local isItemStorage = false
            if self.storage and self.storage.names then
                for _, sn in ipairs(self.storage.names) do
                    if sn == name then isItemStorage = true; break end
                end
            end

            if not isItemStorage then
                local p = wrap(name)
                local hasFluid = peripheral.hasType(name, "fluid_storage") or (p and type(p.tanks) == "function")
                local hasInv = peripheral.hasType(name, "inventory") or (p and p.list ~= nil)
                
                -- Если это чисто бак (есть жидкость, но нет инвентаря)
                if hasFluid and not hasInv then
                    table.insert(self.pool_names, name)
                end
            end
        end
    end
end

--- Сканирование всех баков и данков.
function fluids:scan()
    -- Перезагружаем конфиг, чтобы подхватить изменения из UI
    self:loadConfig()
    
    local count = 0
    -- 1. Сканируем данки
    self.dank_cache = {}
    for _, dk in ipairs(self.danks) do
        count = count + 1
        if count % 8 == 0 then
            os.sleep(0)
        end
        local p = wrap(dk.periph)
        local cur = 0
        if p and p.tanks then
            local ok, tks = pcall(p.tanks)
            if ok and tks then
                for _, t in ipairs(tks) do
                    if t.name == dk.fluid or t.fluid == dk.fluid then
                        cur = cur + (t.amount or 0)
                    end
                end
            end
        end
        local pct = dk.target > 0 and math.floor(cur / dk.target * 100) or 0
        self.dank_cache[dk.periph] = {
            periph = dk.periph,
            fluid = dk.fluid,
            current_mb = cur,
            target_mb = dk.target,
            percent = pct
        }
    end

    -- 2. Сканируем общий пул
    local map = {}
    for _, name in ipairs(self.pool_names) do
        count = count + 1
        if count % 8 == 0 then
            os.sleep(0)
        end
        local p = wrap(name)
        if p and p.tanks then
            local ok, tks = pcall(p.tanks)
            if ok and tks then
                for _, t in ipairs(tks) do
                    local fluidName = t.name or t.fluid
                    if fluidName then
                        local amt = t.amount or 0
                        if amt > 0 then
                            if not map[fluidName] then
                                map[fluidName] = { total = 0, locations = {} }
                            end
                            map[fluidName].total = map[fluidName].total + amt
                            table.insert(map[fluidName].locations, { periph = name, amount = amt })
                        end
                    end
                end
            end
        end
    end
    self.cache = map
    return map
end

--- Получить сводку данков для UI.
function fluids:dankInfo()
    local arr = {}
    for _, dk in ipairs(self.danks) do
        local info = self.dank_cache[dk.periph]
        if not info then
            info = { periph = dk.periph, fluid = dk.fluid, current_mb = 0, target_mb = dk.target, percent = 0 }
        end
        table.insert(arr, info)
    end
    table.sort(arr, function(a, b) return a.periph < b.periph end)
    return arr
end

--- Количество доступной жидкости (пул + данки).
function fluids:count(fluidName)
    local total = 0
    -- Пул
    if self.cache[fluidName] then
        total = total + self.cache[fluidName].total
    end
    -- Данки
    for _, dk in ipairs(self.danks) do
        if dk.fluid == fluidName then
            local info = self.dank_cache[dk.periph]
            if info then
                total = total + info.current_mb
            end
        end
    end
    return total
end

--- Список всех жидкостей и их количества.
function fluids:fluids()
    local agg = {}
    -- Пул
    for fluid, info in pairs(self.cache) do
        agg[fluid] = (agg[fluid] or 0) + info.total
    end
    -- Данки
    for _, dk in ipairs(self.danks) do
        local info = self.dank_cache[dk.periph]
        if info and info.current_mb > 0 then
            agg[dk.fluid] = (agg[dk.fluid] or 0) + info.current_mb
        end
    end

    local result = {}
    for fluid, mb in pairs(agg) do
        table.insert(result, { fluid = fluid, mb = mb })
    end
    table.sort(result, function(a, b) return a.mb > b.mb end)
    return result
end

--- Извлечь N мБ жидкости и перекачать в целевую периферию.
-- Сначала забирает из данка этой жидкости, затем из общего пула.
function fluids:extractFluid(fluidName, mb, targetPeriph)
    local remaining = mb
    local moved = 0

    -- 1. Сначала тянем из Danks, закрепленных за этой жидкостью
    for _, dk in ipairs(self.danks) do
        if remaining <= 0 then break end
        if dk.fluid == fluidName then
            local p = wrap(dk.periph)
            if p then
                local info = self.dank_cache[dk.periph]
                local avail = info and info.current_mb or 0
                if avail > 0 then
                    local toMove = math.min(remaining, avail)
                    local ok, n = false, 0
                    if p.pushFluid then
                        ok, n = pcall(p.pushFluid, targetPeriph, toMove, fluidName)
                    end
                    if not ok or not n or n == 0 then
                        -- Fallback pull
                        local target = wrap(targetPeriph)
                        if target and target.pullFluid then
                            ok, n = pcall(target.pullFluid, dk.periph, toMove, fluidName)
                        end
                    end
                    if ok and n and n > 0 then
                        moved = moved + n
                        remaining = remaining - n
                        if info then info.current_mb = info.current_mb - n end
                    end
                end
            end
        end
    end

    -- 2. Если нужно ещё, тянем из общего пула
    local info = self.cache[fluidName]
    if info and remaining > 0 then
        local poolMoved = 0
        for _, loc in ipairs(info.locations) do
            if remaining <= 0 then break end
            local p = wrap(loc.periph)
            if p then
                local toMove = math.min(remaining, loc.amount)
                local ok, n = false, 0
                if p.pushFluid then
                    ok, n = pcall(p.pushFluid, targetPeriph, toMove, fluidName)
                end
                if not ok or not n or n == 0 then
                    -- Fallback pull
                    local target = wrap(targetPeriph)
                    if target and target.pullFluid then
                        ok, n = pcall(target.pullFluid, loc.periph, toMove, fluidName)
                    end
                end
                if ok and n and n > 0 then
                    moved = moved + n
                    poolMoved = poolMoved + n
                    remaining = remaining - n
                    loc.amount = loc.amount - n
                end
            end
        end
        info.total = info.total - poolMoved
    end

    return moved
end

--- Вернуть жидкость из внешней периферии (выход станции) в хранилище.
-- Сначала наполняет подходящий данк до targetVolume, остальное в общий пул.
function fluids:depositFluid(fromPeriph, fluidName, mb)
    local targetFluid = fluidName
    local limit = mb or 2000000000 -- без лимита

    -- Если fluidName не задан, опрашиваем баки источника
    if not targetFluid then
        local src = wrap(fromPeriph)
        if src and src.tanks then
            local ok, tks = pcall(src.tanks)
            if ok and tks and tks[1] then
                targetFluid = tks[1].name or tks[1].fluid
                if not mb then
                    limit = tks[1].amount or 0
                end
            end
        end
    end

    if not targetFluid or limit <= 0 then return 0 end

    local remaining = limit
    local moved = 0

    -- 1. Пытаемся заполнить подходящие Danks
    for _, dk in ipairs(self.danks) do
        if remaining <= 0 then break end
        if dk.fluid == targetFluid then
            local info = self.dank_cache[dk.periph]
            local current = info and info.current_mb or 0
            local targetVol = dk.target
            if current < targetVol then
                local toFill = math.min(remaining, targetVol - current)
                local p = wrap(dk.periph)
                if p then
                    local ok, n = false, 0
                    if p.pullFluid then
                        ok, n = pcall(p.pullFluid, fromPeriph, toFill, targetFluid)
                    end
                    if not ok or not n or n == 0 then
                        -- Fallback push
                        local src = wrap(fromPeriph)
                        if src and src.pushFluid then
                            ok, n = pcall(src.pushFluid, dk.periph, toFill, targetFluid)
                        end
                    end
                    if ok and n and n > 0 then
                        moved = moved + n
                        remaining = remaining - n
                        if info then info.current_mb = info.current_mb + n end
                    end
                end
            end
        end
    end

    -- 2. Остатки сливаем в общий пул
    if remaining > 0 then
        for _, name in ipairs(self.pool_names) do
            if remaining <= 0 then break end
            local p = wrap(name)
            if p then
                local ok, n = false, 0
                if p.pullFluid then
                    ok, n = pcall(p.pullFluid, fromPeriph, remaining, targetFluid)
                end
                if not ok or not n or n == 0 then
                    -- Fallback push
                    local src = wrap(fromPeriph)
                    if src and src.pushFluid then
                        ok, n = pcall(src.pushFluid, name, remaining, targetFluid)
                    end
                end
                if ok and n and n > 0 then
                    moved = moved + n
                    remaining = remaining - n
                    
                    -- Обновляем кеш пула
                    if not self.cache[targetFluid] then
                        self.cache[targetFluid] = { total = 0, locations = {} }
                    end
                    local locFound = false
                    for _, loc in ipairs(self.cache[targetFluid].locations) do
                        if loc.periph == name then
                            loc.amount = loc.amount + n
                            locFound = true
                            break
                        end
                    end
                    if not locFound then
                        table.insert(self.cache[targetFluid].locations, { periph = name, amount = n })
                    end
                    self.cache[targetFluid].total = self.cache[targetFluid].total + n
                end
            end
        end
    end

    return moved
end

--- Назначить данк.
function fluids:assignDank(periph, fluid, target)
    local localCfg = loadLocalConfig()
    localCfg.danks = localCfg.danks or {}
    
    local found = false
    for _, dk in ipairs(localCfg.danks) do
        if dk.periph == periph then
            dk.fluid = fluid
            dk.target = target
            found = true
            break
        end
    end
    if not found then
        table.insert(localCfg.danks, { periph = periph, fluid = fluid, target = target })
    end
    
    saveLocalConfig(localCfg)
    self:loadConfig()
    self:resolvePool()
    self:scan()
end

--- Снять назначение данка.
function fluids:clearDank(periph)
    local localCfg = loadLocalConfig()
    localCfg.danks = localCfg.danks or {}
    
    for i, dk in ipairs(localCfg.danks) do
        if dk.periph == periph then
            table.remove(localCfg.danks, i)
            break
        end
    end
    
    saveLocalConfig(localCfg)
    self:loadConfig()
    self:resolvePool()
    self:scan()
end

return fluids
