-- config.lua
-- Автогенерируемый конфиг с автоопределением периферии.
-- Локальные переопределения лежат в config.local.lua (в .gitignore).

local config = {}

--- Дефолтный конфиг.
config.defaults = {
    role = "core",             -- "core" | "worker"
    core_id = nil,             -- для worker: ID core-компьютера (число)
    recipes_file = "recipes.dat",
    workers_file = "workers.dat",
    log_file = "shellcraft.log",
    update_url = "https://raw.githubusercontent.com/hirokyserega-web/shellcraft/main/",
    update_interval = 300,     -- проверка обновлений раз в N секунд
    net_timeout = 5,
    heartbeat_interval = 10,
    task_timeout = 120,        -- per-task crafting deadline in seconds
    heartbeat_grace = 15,      -- seconds to ignore stale busy=false heartbeats after dispatch
    use_russian_names = false, -- Requires a Cyrillic font resource pack or transliteration
    text_scale = 0.5,          -- Text scale for monitor (e.g. 1.0 or 0.5)
    grid_chest = nil,          -- default storage grid chest for recording recipes
    grid_dank = nil,           -- default dank (fluid tank)
    github_token = nil,        -- GitHub PAT token for private repos or rate limit bypass
    import_chests = {},        -- list of import chests
    default_import = nil,      -- default import chest
    -- Ручное переопределение периферии (пусто = автоопределение)
    peripherals = {
        storage   = {},        -- список имён chest/barrel
        monitors  = {},
        modems    = {},
        machines  = {},
    },
}

--- Загрузить конфиг (с локальными переопределениями).
function config.load()
    local cfg = util.loadData("config.dat", config.defaults)
    -- config.local.lua — выполняемый lua, возвращает таблицу
    if util.fileExists("config.local.lua") then
        local ok, localCfg = pcall(function() return dofile("config.local.lua") end)
        if ok and type(localCfg) == "table" then
            for k, v in pairs(localCfg) do cfg[k] = v end
        end
    end
    return cfg
end

--- Сохранить конфиг.
function config.save(cfg)
    util.saveData("config.dat", cfg)
end

--- Проверить, является ли периферия инвентарём (chest/barrel/сундук).
-- Имеет методы list() и size().
local function isInventory(name)
    local ok = pcall(peripheral.wrap, name)
    if not ok then return false end
    local p = peripheral.wrap(name)
    if not p then return false end
    local ptype = peripheral.getType(name)
    if ptype == "create:item_vault" or ptype == "item_vault" then
        return true
    end
    return type(p.list) == "function" and type(p.size) == "function"
end

--- Проверить, является ли периферия машиной (печь и т.п.).
-- Имеет методы list/size и знает о слотах результата или burnTime.
local function isMachine(name)
    local p = peripheral.wrap(name)
    if not p then return false end
    if type(p.list) ~= "function" or type(p.size) ~= "function" then return false end
    local ptype = (peripheral.getType(name) or "unknown"):lower()
    
    -- Известные типы машин
    local known = {
        ["minecraft:furnace"] = true,
        ["minecraft:blast_furnace"] = true,
        ["minecraft:smoker"] = true,
        ["minecraft:brewer"] = true,
        ["create:millstone"] = true,
        ["create:crushing_wheels"] = true,
        furnace = true,
        blast_furnace = true,
        smoker = true,
        brewer = true,
    }
    if known[ptype] then return true end
    if type(p.getBurnTime) == "function" then return true end

    -- Если имя типа содержит слова-маркеры машин:
    local machineKeywords = {
        "furnace", "smelt", "mill", "crush", "press", "cook", "kiln", "grind",
        "pulveriz", "saw", "centrifug", "extract", "compress", "assembl", "machine",
        "alloy", "sieve", "enrich", "infus", "crystalliz", "dissolv", "washer",
        "purif", "recombin", "charg", "generat", "reactor", "combiner", "crafter", "metal"
    }
    for _, kw in ipairs(machineKeywords) do
        if ptype:find(kw) then
            return true
        end
    end

    -- Если это инвентарь, но НЕ является сундуком/бочкой/хранилищем
    local storageKeywords = {
        "chest", "barrel", "vault", "shulker", "crate", "storage", "drawer",
        "cabinet", "box", "bag", "dank", "safe", "pocket"
    }
    local isStorage = false
    for _, kw in ipairs(storageKeywords) do
        if ptype:find(kw) then
            isStorage = true
            break
        end
    end

    if not isStorage then
        local sz = p.size()
        if sz and sz <= 6 then
            return true
        end
    end
    
    return false
end

--- Автоопределение всей периферии.
-- Возвращает обновлённый список peripherals.
function config.detect()
    local detected = { storage = {}, monitors = {}, modems = {}, machines = {} }
    for _, name in ipairs(peripheral.getNames()) do
        local ptype = peripheral.getType(name)
        if ptype == "modem" then
            table.insert(detected.modems, name)
        elseif ptype == "monitor" then
            table.insert(detected.monitors, name)
        elseif isMachine(name) then
            table.insert(detected.machines, name)
        elseif isInventory(name) then
            table.insert(detected.storage, name)
        end
    end
    return detected
end

--- Объединить автоопределённое с ручным.
function config.resolve(cfg)
    local auto = config.detect()
    local result = { storage = {}, monitors = {}, modems = {}, machines = {} }
    
    -- 1. Сначала разрешаем машины
    local manualMachines = cfg.peripherals and cfg.peripherals.machines
    local machinesSet = {}
    
    -- Всегда добавляем ручные машины
    if manualMachines and #manualMachines > 0 then
        for _, name in ipairs(manualMachines) do
            if peripheral.isPresent(name) then
                table.insert(result.machines, name)
                machinesSet[name] = true
            end
        end
    end
    
    -- Всегда добавляем также автоопределённые машины
    for _, name in ipairs(auto.machines or {}) do
        if not machinesSet[name] then
            table.insert(result.machines, name)
            machinesSet[name] = true
        end
    end
    
    -- 2. Сбор импортных сундуков
    local importSet = {}
    if cfg.import_chests then
        for _, name in ipairs(cfg.import_chests) do
            importSet[name] = true
        end
    end
    if cfg.default_import then
        importSet[cfg.default_import] = true
    end
    
    -- 3. Разрешаем остальные категории
    for k in pairs(result) do
        if k ~= "machines" then
            local manual = cfg.peripherals and cfg.peripherals[k]
            if manual and #manual > 0 then
                for _, name in ipairs(manual) do
                    if peripheral.isPresent(name) then
                        local isExcluded = (k == "storage" and (cfg.grid_chest == name or machinesSet[name] or importSet[name]))
                        if not isExcluded then
                            table.insert(result[k], name)
                        end
                    end
                end
            else
                for _, name in ipairs(auto[k] or {}) do
                    local isExcluded = (k == "storage" and (cfg.grid_chest == name or machinesSet[name] or importSet[name]))
                    if not isExcluded then
                        table.insert(result[k], name)
                    end
                end
            end
        end
    end
    return result
end

return config
