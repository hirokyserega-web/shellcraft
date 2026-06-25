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
    use_russian_names = false, -- Requires a Cyrillic font resource pack or transliteration
    text_scale = 0.5,          -- Text scale for monitor (e.g. 1.0 or 0.5)
    grid_chest = nil,          -- default storage grid chest for recording recipes
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
    return type(p.list) == "function" and type(p.size) == "function"
end

--- Проверить, является ли периферия машиной (печь и т.п.).
-- Имеет методы list/size и знает о слотах результата или burnTime.
local function isMachine(name)
    local p = peripheral.wrap(name)
    if not p then return false end
    if type(p.list) ~= "function" or type(p.size) ~= "function" then return false end
    local ptype = peripheral.getType(name)
    -- Известные типы машин
    local known = {
        ["minecraft:furnace"] = true,
        ["minecraft:blast_furnace"] = true,
        ["minecraft:smoker"] = true,
        ["minecraft:brewer"] = true,
        ["create:millstone"] = true,
        ["create:crushing_wheels"] = true,
        -- Для обратной совместимости
        furnace = true,
        blast_furnace = true,
        smoker = true,
        brewer = true,
    }
    if known[ptype] then return true end
    -- Эвристика: печь имеет getBurnTime или getSize возвращает 3
    if type(p.getBurnTime) == "function" then return true end
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
    for k in pairs(result) do
        -- Если в конфиге есть ручной список и он непуст — используем его
        local manual = cfg.peripherals and cfg.peripherals[k]
        if manual and #manual > 0 then
            -- фильтруем существующие
            for _, name in ipairs(manual) do
                if peripheral.isPresent(name) then
                    table.insert(result[k], name)
                end
            end
        else
            for _, name in ipairs(auto[k] or {}) do
                table.insert(result[k], name)
            end
        end
    end
    return result
end

return config
