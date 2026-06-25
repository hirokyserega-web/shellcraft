-- startup.lua
-- Точка входа ShellCraft при загрузке компьютера.
-- Порядок: загрузка зависимостей -> автообновление -> запуск роли (core/worker).
-- Должен лежать в корне и (опц.) скопирован в /startup для автозапуска.

-- Пути поиска модулей
package.path = package.path
    .. ";?.lua;?/?.lua"
    .. ";lib/?.lua;core/?.lua;worker/?.lua;ui/?.lua;lang/?.lua"

-- Глобальные библиотеки (используются модулями без локального require)
util       = require("lib.util")
net        = require("lib.net")
config     = require("config")
updater    = require("updater")
ru         = require("lang.ru")
names      = require("lib.names")
lang       = names  -- алиас: lang.display / lang.localize (=display) доступны везде
widgets    = require("ui.widgets")
planner    = require("core.planner")
storage    = require("core.storage")
recipes    = require("core.recipes")
machines   = require("core.machines")
dispatcher = require("core.dispatcher")
ui         = require("ui.ui")

-- Версия (глобально, для воркеров)
_SHELLCRAFT_VERSION = updater.localVersion()

-- Загрузить кеш отображаемых имён и множество отсутствующих
names.init()

local function main()
    util.info("=== ShellCraft " .. _SHELLCRAFT_VERSION .. " ===")
    util.info("Computer #" .. os.getComputerID())

    -- Конфиг
    local cfg = config.load()
    if not cfg.role then
        cfg.role = "core"
        config.save(cfg)
    end
    util.info("Role: " .. cfg.role)

    -- Автообновление (перезагрузит компьютер если есть новая версия)
    local baseUrl = cfg.update_url or config.defaults.update_url
    if baseUrl then
        local ok = pcall(updater.run, baseUrl, true)
        if not ok then
            util.warn("Auto-update skipped (no network?)")
        end
    end

    -- Запуск роли
    if cfg.role == "worker" then
        local worker = require("worker.worker")
        util.ok("Starting worker...")
        local w = worker.new()
        if cfg.core_id then w:setCore(cfg.core_id) end
        w:run()
    else
        util.ok("Starting Core server...")
        server = require("core.server")
        server.run()
    end
end

main()
