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

local cyr_to_lat = {
    ["А"] = "A", ["Б"] = "B", ["В"] = "V", ["Г"] = "G", ["Д"] = "D", ["Е"] = "E", ["Ё"] = "Yo", ["Ж"] = "Zh",
    ["З"] = "Z", ["И"] = "I", ["Й"] = "Y", ["К"] = "K", ["Л"] = "L", ["М"] = "M", ["Н"] = "N", ["О"] = "O",
    ["П"] = "P", ["Р"] = "R", ["С"] = "S", ["Т"] = "T", ["У"] = "U", ["Ф"] = "F", ["Х"] = "Kh", ["Ц"] = "Ts",
    ["Ч"] = "Ch", ["Ш"] = "Sh", ["Щ"] = "Shch", ["Ъ"] = "", ["Ы"] = "Y", ["Ь"] = "", ["Э"] = "E", ["Ю"] = "Yu",
    ["Я"] = "Ya",
    ["а"] = "a", ["б"] = "b", ["в"] = "v", ["г"] = "g", ["д"] = "d", ["е"] = "e", ["ё"] = "yo", ["ж"] = "zh",
    ["з"] = "z", ["и"] = "i", ["й"] = "y", ["к"] = "k", ["л"] = "l", ["м"] = "m", ["н"] = "n", ["о"] = "o",
    ["п"] = "p", ["р"] = "r", ["с"] = "s", ["т"] = "t", ["у"] = "u", ["ф"] = "f", ["х"] = "kh", ["ц"] = "ts",
    ["ч"] = "ch", ["ш"] = "sh", ["щ"] = "shch", ["ъ"] = "", ["ы"] = "y", ["ь"] = "", ["э"] = "e", ["ю"] = "yu",
    ["я"] = "ya"
}

function names.transliterate(str)
    if not str then return "" end
    local result = {}
    local i = 1
    local len = #str
    
    local lat_upper = {
        "A", "B", "V", "G", "D", "E", "Zh", "Z", "I", "Y", "K", "L", "M", "N", "O", "P",
        "R", "S", "T", "U", "F", "Kh", "Ts", "Ch", "Sh", "Shch", "", "Y", "", "E", "Yu", "Ya"
    }
    local lat_lower = {
        "a", "b", "v", "g", "d", "e", "zh", "z", "i", "y", "k", "l", "m", "n", "o", "p",
        "r", "s", "t", "u", "f", "kh", "ts", "ch", "sh", "shch", "", "y", "", "e", "yu", "ya"
    }
    
    while i <= len do
        local b1 = str:byte(i)
        local done = false
        
        -- 1. UTF-8 Cyrillic
        if i < len and (b1 == 208 or b1 == 209) then
            local b2 = str:byte(i + 1)
            local char_str = nil
            if b1 == 208 then
                if b2 >= 144 and b2 <= 175 then
                    char_str = lat_upper[b2 - 144 + 1]
                elseif b2 >= 176 and b2 <= 191 then
                    char_str = lat_lower[b2 - 176 + 1]
                elseif b2 == 129 then
                    char_str = "Yo"
                end
            elseif b1 == 209 then
                if b2 >= 128 and b2 <= 143 then
                    char_str = lat_lower[b2 - 128 + 17]
                elseif b2 == 145 then
                    char_str = "yo"
                end
            end
            if char_str then
                table.insert(result, char_str)
                i = i + 2
                done = true
            end
        end
        
        -- 2. CP1251 Cyrillic
        if not done then
            local char_str = nil
            if b1 >= 192 and b1 <= 223 then
                char_str = lat_upper[b1 - 192 + 1]
            elseif b1 >= 224 and b1 <= 255 then
                char_str = lat_lower[b1 - 224 + 1]
            elseif b1 == 168 then
                char_str = "Yo"
            elseif b1 == 184 then
                char_str = "yo"
            end
            if char_str then
                table.insert(result, char_str)
                i = i + 1
                done = true
            end
        end
        
        -- 3. CP866 Cyrillic
        if not done then
            local char_str = nil
            if b1 >= 128 and b1 <= 143 then
                char_str = lat_upper[b1 - 128 + 1]
            elseif b1 >= 144 and b1 <= 159 then
                char_str = lat_upper[b1 - 144 + 17]
            elseif b1 >= 160 and b1 <= 175 then
                char_str = lat_lower[b1 - 160 + 1]
            elseif b1 >= 224 and b1 <= 239 then
                char_str = lat_lower[b1 - 224 + 17]
            elseif b1 == 240 then
                char_str = "Yo"
            elseif b1 == 241 then
                char_str = "yo"
            end
            if char_str then
                table.insert(result, char_str)
                i = i + 1
                done = true
            end
        end
        
        -- 4. Standard ASCII
        if not done then
            table.insert(result, string.char(b1))
            i = i + 1
        end
    end
    return table.concat(result)
end

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

local function isInvalidName(str)
    if not str then return true end
    if str:find("?") then return true end
    if str:gsub("%s+", "") == "" then return true end
    return false
end

--- Загрузить кеш имён и множество отсутствующих с диска.
function names.init()
    local cfg = config.load()
    names.use_russian_names = cfg and cfg.use_russian_names or false
    -- кеш
    if util.fileExists(names.CACHE_FILE) then
        local data = util.loadData(names.CACHE_FILE, {})
        if type(data) == "table" then
            for k, v in pairs(data) do
                if not isInvalidName(v) then
                    names.cache[k] = v
                else
                    dirty = true
                end
            end
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
    if not id or isInvalidName(displayName) then return end
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
    -- 1. Русское имя из автособранного словаря (только если разрешено)
    if names.use_russian_names and ru and ru.dict and ru.dict[s] and not isInvalidName(ru.dict[s]) then
        return ru.dict[s]
    end
    -- 2. displayName из detail (если передали) — заодно кешируем
    local dn = extractDisplay(detail)
    if dn and not isInvalidName(dn) then
        names.cacheName(s, dn)
        if not names.use_russian_names then
            return names.transliterate(dn)
        end
        return dn
    end
    -- 3. Кеш (собранный ранее из getItemDetail)
    if names.cache[s] and not isInvalidName(names.cache[s]) then
        local cached = names.cache[s]
        if not names.use_russian_names then
            return names.transliterate(cached)
        end
        return cached
    end
    -- 3.5. Запасной вариант: транслитерация русского имени, если нет оригинального
    if ru and ru.dict and ru.dict[s] and not isInvalidName(ru.dict[s]) then
        return names.transliterate(ru.dict[s])
    end
    -- 4. Fallback: красивый ID + лог отсутствия
    names.logMissing(s)
    return formatId(s)
end

-- Совместимый алиас: старый код звал lang.localize(id).
names.localize = names.display

--- Пройтись по предметам хранилища и заполнить кеш.
function names.collectNames(storageObj)
    if not storageObj or not storageObj.collectNames then return 0 end
    return storageObj:collectNames(names)
end

return names
