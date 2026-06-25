-- install.lua
-- Первичная установка ShellCraft одной командой:
--   wget run https://raw.githubusercontent.com/<user>/shellcraft/main/install.lua
--
-- Скрипт:
--   1) спрашивает роль (core/worker) и при необходимости ID core;
--   2) скачивает все файлы проекта;
--   3) создаёт config.dat;
--   4) настраивает startup.lua как автозапуск (через копирование в startup).
--
-- Повторный запуск обновляет файлы, не трогая config.dat/recipes.dat.

-- Базовый URL проекта на GitHub.
-- Если запускаешь с форка — поменяй USER.
local USER = "hirokyserega-web"
local BASE = "https://raw.githubusercontent.com/" .. USER .. "/shellcraft/main/"

-- Список файлов для установки.
local FILES = {
    "startup.lua", "updater.lua", "config.lua", "version",
    "core/server.lua", "core/storage.lua", "core/recipes.lua",
    "core/planner.lua", "core/machines.lua", "core/dispatcher.lua",
    "worker/worker.lua", "ui/ui.lua", "ui/widgets.lua",
    "lang/ru.lua", "lib/net.lua", "lib/util.lua",
    "lib/names.lua", "tools/gen_lang.lua",
}

-- Защищённые файлы (не перезаписывать).
local PROTECTED = {
    ["config.dat"] = true, ["recipes.dat"] = true, ["workers.dat"] = true,
    ["config.local.lua"] = true, ["shellcraft.log"] = true,
    ["lang/missing.log"] = true, ["lang/cache"] = true,
}

local function ensureDir(path)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and not fs.exists(dir) then fs.makeDir(dir) end
end

local function fetch(url)
    local r = http.get(url)
    if not r then return nil end
    local body = r.readAll()
    r.close()
    return body
end

local function writeFile(path, content)
    ensureDir(path)
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(content)
    f.close()
    return true
end

local function ask(prompt, default)
    write(prompt)
    if default then write(" [" .. default .. "]") end
    write(": ")
    local line = read()
    line = line and line:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if line == "" then return default end
    return line
end

print("=== Установка ShellCraft ===")
print("Источник: " .. BASE)
print()

-- Скачивание файлов
print("Скачиваю файлы проекта...")
local okCount, failCount = 0, 0
for _, relPath in ipairs(FILES) do
    if PROTECTED[relPath] then
        -- пропускаем
    else
        local content = fetch(BASE .. relPath)
        if content then
            if writeFile(relPath, content) then
                okCount = okCount + 1
                print("  [OK] " .. relPath)
            else
                failCount = failCount + 1
                print("  [FAIL запись] " .. relPath)
            end
        else
            failCount = failCount + 1
            print("  [FAIL сеть] " .. relPath)
        end
    end
end

if failCount > 0 then
    print()
    print("Внимание: " .. failCount .. " файл(ов) не скачались.")
    print("Проверь подключение к интернету и что репозиторий публичный.")
end

print()
print("Скачано файлов: " .. okCount)

-- Настройка роли
print()
print("Выбери роль этого компьютера:")
print("  1) core   — главный сервер системы (с монитором и хранилищем)")
print("  2) worker — черепаха-крафтер")
local roleChoice = ask("Роль [1/2]", "1")
local role = "core"
if roleChoice == "2" or roleChoice:lower() == "worker" then
    role = "worker"
end

local coreId = nil
if role == "worker" then
    coreId = tonumber(ask("ID компьютера Core (число, см. label/core)"))
end

-- Создаём config.dat если его нет
local cfg
if fs.exists("config.dat") then
    local f = fs.open("config.dat", "r")
    cfg = textutils.unserialize(f.readAll()) or {}
    f.close()
else
    cfg = {}
end
cfg.role = role
cfg.core_id = coreId
cfg.update_url = BASE
ensureDir("config.dat")
local f = fs.open("config.dat", "w")
f.write(textutils.serialize(cfg))
f.close()

-- Настройка автозапуска: startup.lua уже на месте.
-- В CC:Tweaked файл startup.lua в корне запускается автоматически.

print()
print("=== Готово! ===")
print("Роль: " .. role)
if coreId then print("Core ID: " .. coreId) end
print()
if role == "core" then
    print("Подключи к компьютеру:")
    print("  - проводной модем (для rednet с воркерами)")
    print("  - монитор (для UI)")
    print("  - сундуки/бочки (хранилище)")
    print("  - при необходимости печь/механизмы")
    print()
    print("Для добавления крафтеров поставь черепаху,")
    print("повтори эту установку с ролью worker и укажи ID этого Core.")
else
    print("Убедись, что у черепахи есть проводной/беспроводной модем")
    print("и она в одной rednet-сети с Core.")
end
print()
print("Перезагрузи компьютер/черепаху — ShellCraft запустится автоматически.")
print("(Команда: reboot)")
