-- lib/net.lua
-- Протокол rednet для общения Core <-> Worker.
-- Все сообщения — таблицы с полем type.

local net = {}

--- Имя протокола.
net.PROTOCOL = "shellcraft"

--- Типы сообщений.
net.MSG = {
    DISCOVER       = "discover",        -- Core ищет воркеров
    WORKER_HELLO   = "worker_hello",    -- Воркер отвечает Core
    WORKER_BYE     = "worker_bye",      -- Воркер уходит
    CRAFT_REQUEST  = "craft_request",   -- Core -> воркер: скрафти N шт
    CRAFT_CANCEL   = "craft_cancel",    -- Core -> воркер: отмена
    STATUS         = "status",          -- воркер -> Core: прогресс
    RESULT         = "result",          -- воркер -> Core: готово/ошибка
    PING           = "ping",
    PONG           = "pong",
    HEARTBEAT      = "heartbeat",
}

--- Открыть rednet на всех доступных модемах.
-- @return true если хоть один модем открыт
function net.open()
    local opened = false
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            if not rednet.isOpen(side) then
                rednet.open(side)
            end
            opened = true
        end
    end
    return opened
end

function net.close()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" and rednet.isOpen(side) then
            rednet.close(side)
        end
    end
end

--- Отправить сообщение конкретному получателю.
function net.send(targetId, msgType, payload)
    local msg = { type = msgType, payload = payload or {}, from = os.getComputerID(), ts = os.clock() }
    rednet.send(targetId, msg, net.PROTOCOL)
    return msg
end

--- Широковещательная рассылка.
function net.broadcast(msgType, payload)
    local msg = { type = msgType, payload = payload or {}, from = os.getComputerID(), ts = os.clock() }
    rednet.broadcast(msg, net.PROTOCOL)
    return msg
end

--- Приём сообщения с таймаутом.
-- @param timeout секунд (nil = ждать вечно)
-- @return senderId, msg или nil при таймауте
function net.receive(timeout)
    local senderId, msg, proto = rednet.receive(net.PROTOCOL, timeout)
    if senderId == nil then return nil end
    if type(msg) ~= "table" or not msg.type then
        return senderId, { type = "unknown", payload = msg }
    end
    return senderId, msg
end

--- Поиск воркеров через broadcast DISCOVER.
-- Core рассылает DISCOVER и собирает ответы.
-- @param timeout сколько ждать ответов
-- @return таблица { [workerId] = { capabilities = ... } }
function net.discoverWorkers(timeout)
    timeout = timeout or 3
    local workers = {}
    net.broadcast(net.MSG.DISCOVER, { core = os.getComputerID() })
    local deadline = os.clock() + timeout
    while os.clock() < deadline do
        local senderId, msg = net.receive(deadline - os.clock())
        if senderId and msg.type == net.MSG.WORKER_HELLO then
            workers[senderId] = msg.payload or {}
        end
    end
    return workers
end

return net
