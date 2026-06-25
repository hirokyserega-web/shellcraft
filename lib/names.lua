-- lib/names.lua
-- Отображаемые имена предметов.
--
-- ПРАВИЛО: внутри системы (рецепты, хранилище, конфиг, сообщения протокола)
-- ВСЕГДА используется item ID (minecraft:oak_planks) как ключ. Имя — только для
-- вывода пользователю и ЛОГируется отсутствующее, но никогда не служит ключом.
--
-- Приоритет имени в names.display(id, detail):
--   a) русское имя из автособранного словаря lang/ru.lua (ru.dict);
--   b) displayName из getItemDetail (передан в detail или лежит в кеше lang/cache);
--   c) fallback: красиво отформатированный ID (убрать namespace, _ -> пробел,
--      каждое слово с заглавной).
--
-- Кеш lang/cache собирается один раз (storage:collectNames) и не дёргает
-- getItemDetail каждый кадр. Отсутствующие имена логируются без дублей в
-- lang/missing.log.

local names = {}

names.CACHE_FILE   = "lang/cache"
names.MISSING_FILE = "lang/missing.log"

--- Кеш displayName: [id] = "Дубовые доски" (из getItemDetail).
names.cache = {}

--- Множество уже залогированных отсутствующих ID (чтобы не дублировать).
names.loggedMissing = {}

local dirty = false

--- Красивый fallback из ID через util.
local function formatId(id)
    return util.formatId(id)
end

--- Извлечь displayName из аргумента detail.
-- detail может быть: nil | строка | таблица с .displayName (как из getItemDetail).
local function extractDisplay(detail)
    if not detail then return nil end
    if type(detail) == "string" then
        if detail ~= "" then return detail end
        return nil
    end
    if type(detail) == "table" then
        local dn = detail.displayName
        if dn and dn ~= "" then return dn end
    end
    return nil
end

--- Дописать отсутствующий ID в лог (без дублей — проверяет loggedMissing).
function names.logMissing(id)
    if not id then return end
    local s = tostring(id)
    if names.loggedMissing[s] then return end
    names.loggedMissing[s] = true
    util.ensureDir(fs.getDir(names.MISSING_FILE))
    local f = fs.open(names.MISSING_FILE, "a")
    if f then
        f.writeLine(s)
        f.close()
    end
end

--- Загрузить кеш имён и множество отсутствующих с диска.
function names.init()
    -- кеш
    if util.fileExists(names.CACHE_FILE) then
        local data = util.loadData(names.CACHE_FILE, {})
        if type(data) == "table" then
            names.cache = data
        end
    end
    -- множество уже залогированных отсутствующих
    if util.fileExists(names.MISSING_FILE) then
        local f = fs.open(names.MISSING_FILE, "r")
        if f then
            local line = f.readLine()
            while line do
                local id = line:gsub("^%s+", ""):gsub("%s+$", "")
                if id ~= "" then names.loggedMissing[id] = true end
                line = f.readLine()
            end
            f.close()
        end
    end
end

--- Запомнить displayName предмета (из getItemDetail / сканирования).
function names.cacheName(id, displayName)
    if not id or not displayName or displayName == "" then return end
    local s = tostring(id)
    if names.cache[s] ~= displayName then
        names.cache[s] = displayName
        dirty = true
    end
end

--- Сбросить кеш на диск (если были изменения).
function names.saveCache()
    if not dirty then return true end
    util.saveData(names.CACHE_FILE, names.cache)
    dirty = false
    return true
end

--- Главное: отображаемое имя предмета.
-- @param id item ID (minecraft:oak_planks)
-- @param detail опц.: displayName (строка) или таблица из getItemDetail
-- @return строка имени
function names.display(id, detail)
    if not id then return "?" end
    local s = tostring(id)
    -- 1. Русское имя из автособранного словаря
    if ru and ru.dict and ru.dict[s] then
        return ru.dict[s]
    end
    -- 2. displayName из detail (если передали) — заодно кешируем
    local dn = extractDisplay(detail)
    if dn then
        names.cacheName(s, dn)
        return dn
    end
    -- 3. Кеш (собранный ранее из getItemDetail)
    if names.cache[s] then
        return names.cache[s]
    end
    -- 4. Fallback: красивый ID + лог отсутствия
    names.logMissing(s)
    return formatId(s)
end

-- Совместимый алиас: старый код звал lang.localize(id).
names.localize = names.display

return names
