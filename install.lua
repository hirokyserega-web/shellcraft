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
    local t = tostring(math.random(100000, 999999))
    if os.epoch then
        pcall(function() t = tostring(os.epoch("utc")) end)
    end
    local separator = url:find("%?") and "&" or "?"
    local busterUrl = url .. separator .. "t=" .. t
    
    local retries = 3
    for attempt = 1, retries do
        local r = http.get(busterUrl)
        if r then
            local body = r.readAll()
            r.close()
            return body
        end
        if attempt < retries then
            os.sleep(0.5 * attempt)
        end
    end
    return nil
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

print("=== ShellCraft Installation ===")
print("Source: " .. BASE)
print()

-- Скачивание файлов
print("Downloading project files...")
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
                print("  [FAIL write] " .. relPath)
            end
        else
            failCount = failCount + 1
            print("  [FAIL network] " .. relPath)
        end
    end
end

if failCount > 0 then
    print()
    print("Warning: " .. failCount .. " file(s) failed to download.")
    print("Check internet connection and that the repository is public.")
end

print()
print("Downloaded files: " .. okCount)

-- Настройка роли
print()
print("Select role for this computer:")
print("  1) core   - main system server (with monitor and storage)")
print("  2) worker - turtle crafter")
local roleChoice = ask("Role [1/2]", "1")
local role = "core"
if roleChoice == "2" or roleChoice:lower() == "worker" then
    role = "worker"
end

local coreId = nil
if role == "worker" then
    coreId = tonumber(ask("Core computer ID (number, see label/core)"))
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
print("=== Done! ===")
print("Role: " .. role)
if coreId then print("Core ID: " .. coreId) end
print()
if role == "core" then
    print("Connect to computer:")
    print("  - wired modem (for rednet with workers)")
    print("  - monitor (for UI)")
    print("  - chests/barrels (storage)")
    print("  - furnace/machines if needed")
    print()
    print("To add crafters place a turtle,")
    print("repeat this installation with role 'worker' and specify this Core ID.")
else
    print("Make sure the turtle has a wired/wireless modem")
    print("and is in the same rednet network as Core.")
end
print()
print("Reboot computer/turtle - ShellCraft will start automatically.")
print("(Command: reboot)")

