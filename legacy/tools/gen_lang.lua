-- tools/gen_lang.lua
-- Генератор словаря lang/ru.lua из официальных файлов перевода Minecraft
-- (ru_ru.json — ванильные ассеты + lang-файлы модов).
--
-- Запуск:
--   в CraftOS / CraftOS-PC:
--     gen_lang.lua ru_ru.json lang/ru.lua
--     gen_lang.lua vanilla/ru_ru.json mods/create_ru.json lang/ru.lua
--   в обычной Lua 5.1+ (вне игры):
--     lua tools/gen_lang.lua ru_ru.json lang/ru.lua
--
-- Последний аргумент — выходной файл, остальные — входные JSON.
--
-- Сопоставление translation key -> item ID:
--   block.<namespace>.<path>  -> <namespace>:<path>
--   item.<namespace>.<path>   -> <namespace>:<path>
-- Приоритет: block.* выше item.* (каноническое имя блока).
-- Ключи с лишними сегментами (item.minecraft.potion.effect.leaping) пропускаются
-- — они не соответствуют реальным item ID.
--
-- Где взять ru_ru.json:
--   Ванильный: .minecraft/assets/objects/... (после запуска игры с русским языком)
--     либо https://github.com/InventivetalentDev/minecraft-assets (assets/minecraft/lang/ru_ru.json)
--     либо распаковав client.jar: assets/minecraft/lang/ru_ru.json
--   Моды: <mod>.jar/assets/<mod>/lang/ru_ru.json
-- Формат у всех одинаковый — плоский JSON {"key": "value"}.

local args = {...}
if #args < 2 then
    print("Использование: gen_lang.lua <input1.json> [input2.json ...] <output.lua>")
    return
end

local inputs = {}
for i = 1, #args - 1 do table.insert(inputs, args[i]) end
local output = args[#args]

----------------------------------------------------------------------
-- Мини-парсер плоского JSON-объекта {"key":"value", ...}.
-- ru_ru.json плоский, поэтому вложенность/массивы не поддерживаются.
----------------------------------------------------------------------
local function parseFlatJSON(text)
    local map = {}
    local pos = 1
    local len = #text

    local function skipWS()
        while pos <= len do
            local c = text:byte(pos)
            if c == 32 or c == 9 or c == 10 or c == 13 then pos = pos + 1
            else break end
        end
    end

    local function readString()
        skipWS()
        if pos > len or text:byte(pos) ~= 34 then return nil end -- "
        pos = pos + 1
        local out = {}
        while pos <= len do
            local c = text:byte(pos)
            if c == 92 then -- backslash
                pos = pos + 1
                if pos > len then break end
                local e = text:sub(pos, pos)
                if e == "n" then out[#out + 1] = "\n"
                elseif e == "t" then out[#out + 1] = "\t"
                elseif e == "r" then out[#out + 1] = "\r"
                elseif e == '"' then out[#out + 1] = '"'
                elseif e == "\\" then out[#out + 1] = "\\"
                elseif e == "/" then out[#out + 1] = "/"
                elseif e == "u" then
                    local hex = text:sub(pos + 1, pos + 4)
                    pos = pos + 4
                    local cp = tonumber(hex, 16)
                    if cp then
                        if cp < 0x80 then
                            out[#out + 1] = string.char(cp)
                        elseif cp < 0x800 then
                            out[#out + 1] = string.char(
                                0xC0 + math.floor(cp / 0x40),
                                0x80 + (cp % 0x40))
                        else
                            out[#out + 1] = string.char(
                                0xE0 + math.floor(cp / 0x1000),
                                0x80 + (math.floor(cp / 0x40) % 0x40),
                                0x80 + (cp % 0x40))
                        end
                    end
                else
                    out[#out + 1] = e
                end
                pos = pos + 1
            elseif c == 34 then -- "
                pos = pos + 1
                break
            else
                out[#out + 1] = text:sub(pos, pos)
                pos = pos + 1
            end
        end
        return table.concat(out)
    end

    skipWS()
    if pos > len or text:byte(pos) ~= 123 then return nil end -- {
    pos = pos + 1
    while true do
        skipWS()
        if pos > len then break end
        if text:byte(pos) == 125 then pos = pos + 1; break end -- }
        local key = readString()
        if not key then break end
        skipWS()
        if pos > len or text:byte(pos) ~= 58 then break end -- :
        pos = pos + 1
        local val = readString()
        if val then map[key] = val end
        skipWS()
        if pos <= len then
            if text:byte(pos) == 44 then pos = pos + 1       -- ,
            elseif text:byte(pos) == 125 then pos = pos + 1; break end -- }
        end
    end
    return map
end

----------------------------------------------------------------------
-- Чтение файла (CraftOS fs или обычная io)
----------------------------------------------------------------------
local function readFile(path)
    if fs and fs.open then
        if not fs.exists(path) then return nil end
        local f = fs.open(path, "r")
        if not f then return nil end
        local s = f.readAll()
        f.close()
        return s
    end
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function writeFile(path, content)
    if fs and fs.open then
        local dir = fs.getDir(path)
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        local f = fs.open(path, "w")
        if not f then return false end
        f.write(content)
        f.close()
        return true
    end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

----------------------------------------------------------------------
-- Сборка id -> name
----------------------------------------------------------------------
local byId = {}        -- [id] = name
local isBlock = {}     -- [id] = true если имя пришло из block.*

-- тип.namespace.path ; namespace/path = буквы/цифры/underscore/дефис
local PAT_BLOCK = "^block%.([%w_%-]+)%.([%w_%-]+)$"
local PAT_ITEM  = "^item%.([%w_%-]+)%.([%w_%-]+)$"

local totalMatched = 0
for _, path in ipairs(inputs) do
    local text = readFile(path)
    if not text then
        print("Не могу открыть " .. path .. " — пропуск")
    else
        local map = parseFlatJSON(text)
        if not map then
            print("Не удалось распарсить JSON: " .. path)
        else
            local count = 0
            for key, val in pairs(map) do
                local ns, p = key:match(PAT_BLOCK)
                if ns and p then
                    local id = ns .. ":" .. p
                    byId[id] = val
                    isBlock[id] = true
                    count = count + 1
                else
                    ns, p = key:match(PAT_ITEM)
                    if ns and p then
                        local id = ns .. ":" .. p
                        -- item: не перезаписывать каноничное block-имя
                        if not isBlock[id] then
                            byId[id] = val
                        end
                        count = count + 1
                    end
                end
            end
            print(string.format("%s: сопоставлено %d ключей", path, count))
            totalMatched = totalMatched + count
        end
    end
end

----------------------------------------------------------------------
-- Запись lang/ru.lua
----------------------------------------------------------------------
local out = {}
table.insert(out, "-- lang/ru.lua")
table.insert(out, "-- АВТОСГЕНЕРИРОВАНО tools/gen_lang.lua. Не редактируйте вручную —")
table.insert(out, "-- перегенерируйте: gen_lang.lua <ru_ru.json...> lang/ru.lua")
table.insert(out, "-- Источник: официальные файлы перевода Minecraft (ru_ru.json).")
table.insert(out, "-- Это словарь ID -> русское имя; используется модулем lib/names.lua.")
table.insert(out, "")
table.insert(out, "local ru = {}")
table.insert(out, "ru.dict = {")

local ids = {}
for id in pairs(byId) do table.insert(ids, id) end
table.sort(ids)

local function esc(s)
    return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

for _, id in ipairs(ids) do
    table.insert(out, string.format('  ["%s"] = "%s",', esc(id), esc(byId[id])))
end
table.insert(out, "}")
table.insert(out, "")
table.insert(out, "return ru")
local content = table.concat(out, "\n") .. "\n"

writeFile(output, content)
print(string.format("Готово: %d записей -> %s (всего сопоставлено %d ключей)",
    #ids, output, totalMatched))
