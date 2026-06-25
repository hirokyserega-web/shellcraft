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

--- Скачать текстовый файл с URL.
-- @return content или nil
function updater.fetch(url)
    local response = http.get(url)
    if not response then return nil end
    local body = response.readAll()
    response.close()
    return body
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
    util.info("Проверка обновлений с " .. baseUrl)

    local local_ = updater.localVersion()
    local remote = updater.remoteVersion(baseUrl)
    if not remote then
        util.warn("Не удалось получить удалённую версию")
        return false, "no remote version"
    end
    util.info(string.format("Локально: %s | Удалённо: %s", local_, remote))

    if not force and not updater.isNewer(local_, remote) then
        util.ok("Обновление не требуется")
        return false, "up-to-date"
    end

    util.info("Скачиваю обновление...")
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

    -- Обновляем локальный version
    util.writeFile("version", remote)

    util.ok(string.format("Обновлено файлов: %d, ошибок: %d", okCount, failCount))
    if failCount == 0 then
        return true
    end
    return true, "partial"
end

--- Точка входа: проверить, обновить, перезагрузить.
-- @param baseUrl URL
-- @param rebootAfter перезагрузить компьютер после обновления
function updater.run(baseUrl, rebootAfter)
    rebootAfter = (rebootAfter ~= false) -- по умолчанию true
    local updated, err = updater.update(baseUrl, false)
    if updated then
        util.ok("Обновление установлено. Перезагрузка...")
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
