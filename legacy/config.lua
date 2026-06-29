-- config.lua
-- ShellCraft config + auto-detection.
-- Local overrides live in config.local.lua (ignored by git).
--
-- Important transport options:
--   transfer_mode = "buffer" | "wired"
--     * buffer: default, uses a dedicated input chest + output chest for each worker
--     * wired : legacy direct pushItems/pullItems into turtle inventory
--   workers: optional explicit buffer assignments for turtles
--     workers = {
--       [turtleId] = { input = "chest_name", output = "chest_name" },
--     }

local config = {}

config.defaults = {
    role = "core",             -- "core" | "worker"
    core_id = nil,              -- worker: ID of the core computer

    recipes_file = "recipes.dat",
    workers_file = "workers.dat",
    queue_file = "queue.dat",
    storage_state_file = "storage_state.dat",
    log_file = "shellcraft.log",

    update_url = "https://raw.githubusercontent.com/hirokyserega-web/shellcraft/main/",
    update_interval = 300,
    net_timeout = 5,
    heartbeat_interval = 10,
    task_timeout = 120,
    heartbeat_grace = 15,

    -- Crafting transport
    transfer_mode = "buffer",  -- "buffer" | "wired"
    worker_buffer_mode = "auto", -- "auto" | "manual"
    worker_buffer_timeout = 10,
    worker_buffer_wait = 2,

    -- Auto-import / auxiliary chests
    grid_chest = nil,
    recipe_input_chest = nil,
    grid_dank = nil,
    default_import = nil,
    import_chests = {},

    -- Human display
    use_russian_names = false,
    text_scale = 0.5,

    -- Optional manual IDs for explicit per-worker buffer pairing.
    workers = {},

    -- Peripheral overrides.
    peripherals = {
        storage = {},
        monitors = {},
        modems = {},
        machines = {},
        buffers = {},
        buffer_inputs = {},
        buffer_outputs = {},
        turtles = {},
    },

    -- Optional names the operator wants to exclude from auto detection.
    manual_roles = {},
}

local function shallowCopy(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

function config.load()
    local cfg = util.loadData("config.dat", config.defaults)
    if util.fileExists("config.local.lua") then
        local ok, localCfg = pcall(function() return dofile("config.local.lua") end)
        if ok and type(localCfg) == "table" then
            for k, v in pairs(localCfg) do cfg[k] = v end
        end
    end
    if type(cfg.workers) ~= "table" then cfg.workers = {} end
    if type(cfg.peripherals) ~= "table" then cfg.peripherals = shallowCopy(config.defaults.peripherals) end
    return cfg
end

function config.save(cfg)
    local toSave = {}
    for k, v in pairs(cfg or {}) do
        if k ~= "peripherals" then
            toSave[k] = v
        end
    end
    util.saveData("config.dat", toSave)
end

local function isInventory(name)
    local p = peripheral.wrap(name)
    if not p then return false end
    if type(p.list) ~= "function" or type(p.size) ~= "function" then return false end
    return true
end

local function isFluidStorage(name)
    local p = peripheral.wrap(name)
    if not p then return false end
    if type(p.tanks) == "function" then return true end
    local ptype = (peripheral.getType(name) or ""):lower()
    return ptype:find("fluid") ~= nil or ptype:find("tank") ~= nil or ptype:find("dank") ~= nil
end

local function isMonitor(name)
    return peripheral.getType(name) == "monitor"
end

local function isModem(name)
    return peripheral.getType(name) == "modem"
end

local function isCraftingTurtle(name)
    local ptype = (peripheral.getType(name) or ""):lower()
    if ptype ~= "turtle" then return false end
    local p = peripheral.wrap(name)
    return p and type(p.craft) == "function"
end

local function isMachine(name)
    local p = peripheral.wrap(name)
    if not p then return false end
    if type(p.list) ~= "function" or type(p.size) ~= "function" then return false end
    local ptype = (peripheral.getType(name) or "unknown"):lower()

    local storageKeywords = {
        "chest", "barrel", "vault", "shulker", "crate", "storage", "drawer",
        "cabinet", "box", "bag", "dank", "safe", "pocket", "backpack", "tank", "drum"
    }
    for _, kw in ipairs(storageKeywords) do
        if ptype:find(kw) then
            return false
        end
    end

    local machineKeywords = {
        "furnace", "smelt", "mill", "crush", "press", "cook", "kiln", "grind",
        "pulveriz", "saw", "centrifug", "extract", "compress", "assembl", "machine",
        "alloy", "sieve", "enrich", "infus", "crystalliz", "dissolv", "washer",
        "purif", "recombin", "charg", "generat", "reactor", "combiner", "crafter", "metal"
    }
    for _, kw in ipairs(machineKeywords) do
        if ptype:find(kw) then return true end
    end

    if type(p.getBurnTime) == "function" then return true end
    if ptype:find("furnace") or ptype:find("smoker") or ptype:find("brewer") then return true end
    return false
end

local function isStorage(name)
    local ptype = (peripheral.getType(name) or ""):lower()
    local storageKeywords = {
        "chest", "barrel", "vault", "shulker", "crate", "storage", "drawer",
        "cabinet", "box", "bag", "dank", "safe", "pocket", "backpack", "tank", "drum"
    }
    for _, kw in ipairs(storageKeywords) do
        if ptype:find(kw) then return true end
    end
    return isInventory(name) and not isMachine(name) and not isCraftingTurtle(name) and not isFluidStorage(name)
end

local function pushUnique(list, seen, name)
    if name and not seen[name] then
        seen[name] = true
        list[#list + 1] = name
    end
end

function config.detect()
    local detected = {
        storage = {},
        monitors = {},
        modems = {},
        machines = {},
        buffers = {},
        buffer_inputs = {},
        buffer_outputs = {},
        turtles = {},
    }
    for _, name in ipairs(peripheral.getNames()) do
        if isModem(name) then
            pushUnique(detected.modems, detected, name)
        elseif isMonitor(name) then
            pushUnique(detected.monitors, detected, name)
        elseif isCraftingTurtle(name) then
            pushUnique(detected.turtles, detected, name)
        elseif isMachine(name) then
            pushUnique(detected.machines, detected, name)
        elseif isStorage(name) then
            pushUnique(detected.storage, detected, name)
        elseif isInventory(name) then
            pushUnique(detected.buffers, detected, name)
        end
        if peripheral.hasType(name, "inventory") and not isStorage(name) and not isCraftingTurtle(name) then
            local ptype = (peripheral.getType(name) or ""):lower()
            if ptype:find("buffer") or ptype:find("input") or ptype:find("output") then
                if ptype:find("input") then pushUnique(detected.buffer_inputs, detected, name) end
                if ptype:find("output") then pushUnique(detected.buffer_outputs, detected, name) end
            end
        end
    end
    return detected
end

function config.resolve(cfg)
    cfg = cfg or config.load()
    local auto = config.detect()
    local result = {
        storage = {},
        monitors = {},
        modems = {},
        machines = {},
        buffers = {},
        buffer_inputs = {},
        buffer_outputs = {},
        turtles = {},
    }
    -- Один набор «уже добавлено» на каждую категорию.
    local seen = {}
    for k in pairs(result) do seen[k] = {} end

    local function add(dst, name)
        if name and peripheral.isPresent(name) and result[dst] then
            pushUnique(result[dst], seen[dst], name)
        end
    end

    local manual_roles = cfg.manual_roles or {}
    local manual = cfg.peripherals or {}

    -- 1. Явные ручные списки в cfg.peripherals.
    for _, name in ipairs(manual.modems or {}) do add("modems", name) end
    for _, name in ipairs(manual.monitors or {}) do add("monitors", name) end
    for _, name in ipairs(manual.storage or {}) do if manual_roles[name] ~= "ignored" then add("storage", name) end end
    for _, name in ipairs(manual.machines or {}) do add("machines", name) end
    for _, name in ipairs(manual.buffers or {}) do add("buffers", name) end
    for _, name in ipairs(manual.buffer_inputs or {}) do add("buffer_inputs", name) end
    for _, name in ipairs(manual.buffer_outputs or {}) do add("buffer_outputs", name) end
    for _, name in ipairs(manual.turtles or {}) do add("turtles", name) end

    -- 2. Ручные роли (manual_roles) переопределяют автоопределение.
    local roleToDst = {
        storage = "storage", machine = "machines", buffer = "buffers",
        buffer_input = "buffer_inputs", buffer_output = "buffer_outputs",
        monitor = "monitors", modem = "modems", turtle = "turtles",
    }
    for name, role in pairs(manual_roles) do
        local dst = roleToDst[role]
        if dst then add(dst, name) end
    end

    -- 3. Автоопределённые — только если для имени НЕТ ручной роли.
    local function appendAuto(dst, names)
        for _, name in ipairs(names or {}) do
            if not manual_roles[name] then add(dst, name) end
        end
    end
    appendAuto("storage", auto.storage)
    appendAuto("monitors", auto.monitors)
    appendAuto("modems", auto.modems)
    appendAuto("machines", auto.machines)
    appendAuto("buffers", auto.buffers)
    appendAuto("buffer_inputs", auto.buffer_inputs)
    appendAuto("buffer_outputs", auto.buffer_outputs)
    appendAuto("turtles", auto.turtles)

    -- 4. Буферные сундуки и служебные сундуки не должны считаться хранилищем.
    local exclude = {}
    for _, name in ipairs(result.buffers) do exclude[name] = true end
    for _, name in ipairs(result.buffer_inputs) do exclude[name] = true end
    for _, name in ipairs(result.buffer_outputs) do exclude[name] = true end
    -- Явно назначенные буферы воркеров в cfg.workers тоже исключаем из склада.
    if type(cfg.workers) == "table" then
        for _, w in pairs(cfg.workers) do
            if type(w) == "table" then
                if w.input then exclude[w.input] = true end
                if w.output then exclude[w.output] = true end
            end
        end
    end
    if cfg.grid_chest then exclude[cfg.grid_chest] = true end
    if cfg.recipe_input_chest then exclude[cfg.recipe_input_chest] = true end
    if cfg.default_import then exclude[cfg.default_import] = true end
    if type(cfg.import_chests) == "table" then
        for _, name in ipairs(cfg.import_chests) do exclude[name] = true end
    end

    local filteredStorage = {}
    local filteredSeen = {}
    for _, name in ipairs(result.storage) do
        if not exclude[name] then
            pushUnique(filteredStorage, filteredSeen, name)
        end
    end
    result.storage = filteredStorage

    return result
end

return config
