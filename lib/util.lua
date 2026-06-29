-- lib/util.lua
-- Базовые утилиты ShellCraft: логи, файлы, форматирование.

local util = {}

--- Текущая метка времени (часы:минуты:секунды).
function util.now()
    local t = os.time()
    local h = math.floor(t)
    local m = math.floor((t - h) * 60)
    local s = math.floor((((t - h) * 60) - m) * 60)
    return string.format("%02d:%02d:%02d", h, m, s)
end

--- Путь к файлу лога.
local LOG_FILE = "shellcraft.log"

--- Запись в лог + опционально на экран.
-- @param msg сообщение
-- @param level "INFO"|"WARN"|"ERROR"|"DEBUG"
-- @param silent если true — не печатать на экран
function util.log(msg, level, silent)
    level = level or "INFO"
    local line = string.format("[%s] [%s] %s", util.now(), level, tostring(msg))
    -- Файл
    local f = fs.open(LOG_FILE, "a")
    if f then
        f.writeLine(line)
        f.close()
    end
    -- Экран (только если есть term)
    if not silent and term then
        local color = colors.white
        if level == "WARN" then color = colors.yellow
        elseif level == "ERROR" then color = colors.red
        elseif level == "DEBUG" then color = colors.lightGray
        elseif level == "OK" then color = colors.green end
        local old = term.getTextColor()
        term.setTextColor(color)
        print(line)
        term.setTextColor(old)
    end
    return line
end

function util.info(msg, silent)  return util.log(msg, "INFO", silent)  end
function util.warn(msg, silent)  return util.log(msg, "WARN", silent)  end
function util.err(msg, silent)   return util.log(msg, "ERROR", silent) end
function util.debug(msg, silent) return util.log(msg, "DEBUG", silent) end
function util.ok(msg, silent)    return util.log(msg, "OK", silent)    end

--- Проверка существования файла.
function util.fileExists(path)
    return fs.exists(path) and not fs.isDir(path)
end

--- Гарантированное создание директории.
function util.ensureDir(path)
    if not fs.exists(path) then
        fs.makeDir(path)
    end
end

--- Загрузка конфига/данных с дефолтами.
-- @param path путь к файлу
-- @param defaults таблица-дефолт
function util.loadData(path, defaults)
    if not util.fileExists(path) then
        return defaults or {}
    end
    local f = fs.open(path, "r")
    if not f then return defaults or {} end
    local content = f.readAll()
    f.close()
    local data = textutils.unserialize(content)
    if type(data) ~= "table" then
        return defaults or {}
    end
    -- Слияние с дефолтами (дефолты используются как fallback)
    if defaults then
        for k, v in pairs(defaults) do
            if data[k] == nil then data[k] = v end
        end
    end
    return data
end

--- Сохранение данных.
function util.saveData(path, data)
    util.ensureDir(fs.getDir(path))
    
    -- We must break ALL shared references because textutils.serialize (old versions) 
    -- will throw "repeated entries" even if they are not circular.
    -- util.deepCopy(data) creates a new table tree where every node is unique.
    local safeData = util.deepCopy(data)
    
    -- Attempt serialization. Use pcall to catch "repeated entries" or other errors.
    local ok, res = pcall(textutils.serialize, safeData, { compact = false, allow_repeated = true })
    if not ok or type(res) ~= "string" then
        -- Fallback for very old versions or if something went wrong
        ok, res = pcall(textutils.serialize, safeData)
    end
    
    if not ok or type(res) ~= "string" then
        return false, "Serialization failed: " .. tostring(res)
    end

    local f = fs.open(path, "w")
    if not f then return false, "Cannot open " .. path end
    f.write(res)
    f.close()
    return true
end
    return true
end

function util.deepCopy(obj)
    if type(obj) ~= "table" then return obj end
    local copy = {}
    for k, v in pairs(obj) do
        copy[k] = util.deepCopy(v)
    end
    return copy
end

--- Красивое форматирование ID предмета без перевода.
-- "minecraft:oak_planks" -> "Oak planks"
-- "create:cogwheel" -> "Create cogwheel"
function util.formatId(id)
    if not id then return "?" end
    local s = tostring(id)
    -- Убираем namespace до двоеточия
    local ns, name = s:match("^([^:]+):(.+)$")
    if name then s = name end
    -- Подчёркивания -> пробелы
    s = s:gsub("_", " ")
    -- Каждое слово с заглавной
    s = s:gsub("(%a)([%w_]*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)
    return s
end

--- Ограничение значения.
function util.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Округление.
function util.round(v)
    return math.floor(v + 0.5)
end

--- Список ключей таблицы (для упорядоченного перебора).
function util.keys(t)
    local ks = {}
    for k in pairs(t) do ks[#ks + 1] = k end
    return ks
end

--- Сортировка таблицы по ключу.
function util.sortedKeys(t, cmp)
    local ks = util.keys(t)
    table.sort(ks, cmp)
    return ks
end

--- Чтение всего файла в строку.
function util.readFile(path)
    if not util.fileExists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end

--- Запись строки в файл.
function util.writeFile(path, content)
    util.ensureDir(fs.getDir(path))
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(content)
    f.close()
    return true
end

return util
