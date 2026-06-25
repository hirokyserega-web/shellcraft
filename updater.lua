-- updater.lua
-- Автообновление ShellCraft с GitHub.
-- Скачивает только изменённые файлы, не трогает локальные данные.
-- После обновления сам перезагружает компьютер.

local updater = {}

--- Список всех файлов проекта (относительно update_url).
updater.FILES = {
    "startup.lua",
    "updater.lua",
    "config.lua",
    "version",
    "core/server.lua",
    "core/storage.lua",
    "core/recipes.lua",
    "core/planner.lua",
    "core/machines.lua",
    "core/dispatcher.lua",
    "worker/worker.lua",
    "ui/ui.lua",
    "ui/widgets.lua",
    "lang/ru.lua",
    "lib/net.lua",
    "lib/util.lua",
    "lib/names.lua",
    "tools/gen_lang.lua",
}

--- Файлы, которые НИКОГДА не перезаписываются при обновлении
--- (локальные данные пользователя).
updater.PROTECTED = {
    ["config.dat"] = true,
    ["recipes.dat"] = true,
    ["workers.dat"] = true,
    ["config.local.lua"] = true,
    ["shellcraft.log"] = true,
    ["lang/missing.txt"] = true,
    ["lang/cache"] = true,
    ["lang/missing.log"] = true,
}

--- Прочитать локальную версию.
function updater.localVersion()
    if not util.fileExists("version") then return "0.0.0" end
    local f = fs.open("version", "r")
    if not f then return "0.0.0" end
    local v = f.readAll()
    f.close()
    return (v:gsub("%s", ""))
end

--- Скачать текстовый файл с URL (с 3 попытками, кэш-бастингом и экспоненциальным бэкоффом).
-- @return content или nil
function updater.fetch(url)
    local t = tostring(math.random(100000, 999999))
    if os.epoch then
        pcall(function() t = tostring(os.epoch("utc")) end)
    end
    local separator = url:find("%?") and "&" or "?"
    local busterUrl = url .. separator .. "t=" .. t
    
    local headers = {
        ["Cache-Control"] = "no-cache, no-store, must-revalidate",
        ["Pragma"] = "no-cache",
        ["Expires"] = "0"
    }
    
    if config and config.load then
        local ok, cfg = pcall(config.load)
        if ok and cfg and cfg.github_token and cfg.github_token ~= "" then
            headers["Authorization"] = "token " .. cfg.github_token
        end
    end
    
    local retries = 3
    for attempt = 1, retries do
        local response = http.get(busterUrl, headers)
        if response then
            local body = response.readAll()
            response.close()
            return body
        end
        if attempt < retries then
            os.sleep(0.5 * attempt)
        end
    end
    return nil
end

--- Прочитать удалённую версию с GitHub.
function updater.remoteVersion(baseUrl)
    local body = updater.fetch(baseUrl .. "version")
    if not body then return nil end
    return (body:gsub("%s", ""))
end

--- Сравнение версий вида "1.2.3".
-- @return true если remote новее local
function updater.isNewer(local_, remote)
    local function parse(v)
        local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)")
        if not a then return 0, 0, 0 end
        return tonumber(a), tonumber(b), tonumber(c)
    end
    local la, lb, lc = parse(local_)
    local ra, rb, rc = parse(remote or "0.0.0")
    if ra > la then return true end
    if ra < la then return false end
    if rb > lb then return true end
    if rb < lb then return false end
    return rc > lc
end

--- Скачать и записать один файл (с защитой локальных данных).
function updater.downloadFile(baseUrl, relPath)
    if updater.PROTECTED[relPath] then
        return false, "protected"
    end
    local content = updater.fetch(baseUrl .. relPath)
    if not content then
        return false, "fetch failed: " .. relPath
    end
    util.ensureDir(fs.getDir(relPath))
    local f = fs.open(relPath, "w")
    if not f then return false, "cannot write: " .. relPath end
    f.write(content)
    f.close()
    return true
end

--- Полное обновление: сравнить версию и скачать все файлы.
-- @param baseUrl URL папки (с trailing slash)
-- @param force скачать даже если версия та же
-- @return true если обновлено, false если не требовалось
function updater.update(baseUrl, force)
    baseUrl = baseUrl or config.defaults.update_url
    util.info("Checking updates from " .. baseUrl)

    local local_ = updater.localVersion()
    local remote = updater.remoteVersion(baseUrl)
    if not remote then
        util.warn("Could not get remote version")
        return false, "no remote version"
    end
    util.info(string.format("Local: %s | Remote: %s", local_, remote))

    if not force and not updater.isNewer(local_, remote) then
        util.ok("Update not required")
        return false, "up-to-date"
    end

    util.info("Downloading update...")
    local okCount, failCount = 0, 0
    for _, relPath in ipairs(updater.FILES) do
        local ok, err = updater.downloadFile(baseUrl, relPath)
        if ok then
            okCount = okCount + 1
        else
            failCount = failCount + 1
            util.warn("  " .. relPath .. ": " .. tostring(err))
        end
    end

    util.ok(string.format("Files updated: %d, errors: %d", okCount, failCount))
    if failCount == 0 then
        -- Обновляем локальный version только если все файлы скачались успешно
        util.writeFile("version", remote)
        return true
    end
    return false, "partial update failed"
end

--- Точка входа: проверить, обновить, перезагрузить.
-- @param baseUrl URL
-- @param rebootAfter перезагрузить компьютер после обновления
function updater.run(baseUrl, rebootAfter)
    rebootAfter = (rebootAfter ~= false) -- по умолчанию true
    local updated, err = updater.update(baseUrl, false)
    if updated then
        util.ok("Update installed. Rebooting...")
        if rebootAfter then
            os.sleep(1)
            os.reboot()
        end
        return true
    end
    util.debug("Обновление не требуется: " .. tostring(err))
    return false
end

return updater
