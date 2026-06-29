-- lib/net.lua
-- Версионированный rednet-протокол ShellCraft (Core <-> Worker).
--
-- Каждое сообщение — конверт вида:
--   { v = PROTO_VERSION, type = <MSG>, payload = {...},
--     from = <computerId>, ts = <os.epoch ms>, msg_id = <строка> }
--
-- Ключевые принципы:
--   * Все ответы воркера несут payload.task_id — Core матчит результат по task_id,
--     а НЕ по «текущей задаче воркера».
--   * CRAFT_REQUEST подтверждается CRAFT_ACK; диспетчер ретраит до получения ACK.
--   * HEARTBEAT несёт busy + current_task_id, чтобы отличать «свободен» от
--     «занят моей задачей, но флаг ещё не выставлен».

local net = {}

--- Имя протокола rednet.
net.PROTOCOL = "shellcraft"

--- Версия протокола. Поднимать при несовместимых изменениях формата.
net.VERSION = 2

--- Типы сообщений.
net.MSG = {
    -- обнаружение / присутствие
    DISCOVER             = "discover",        -- Core -> all: ищу воркеров
    WORKER_HELLO         = "worker_hello",    -- Worker -> Core: я здесь (+capabilities)
    WORKER_BYE           = "worker_bye",      -- Worker -> Core: ухожу
    -- крафт
    CRAFT_REQUEST        = "craft_request",   -- Core -> Worker: скрафти recipe x count
    CRAFT_ACK            = "craft_ack",       -- Worker -> Core: принял task_id
    CRAFT_CANCEL         = "craft_cancel",    -- Core -> Worker: отмени task_id
    STATUS               = "status",          -- Worker -> Core: прогресс по task_id
    RESULT               = "result",          -- Worker -> Core: итог по task_id
    -- здоровье
    HEARTBEAT            = "heartbeat",        -- Worker -> Core: busy + current_task_id
    PING                 = "ping",
    PONG                 = "pong",
    -- обучение рецептов
    LEARN_CRAFT_REQUEST  = "learn_craft_request",  -- Core -> Worker: крафт из текущей сетки
    LEARN_CRAFT_RESPONSE = "learn_craft_response", -- Worker -> Core: результат обучения
}

local function newMsgId()
    return tostring(os.getComputerID()) .. "_" .. tostring(os.epoch and os.epoch("utc") or os.clock())
        .. "_" .. tostring(math.random(1000, 9999))
end

--- Открыть rednet на всех модемах (проводных и беспроводных).
-- @return true если хоть один модем открыт
function net.open()
    local opened = false
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            if not rednet.isOpen(side) then
                pcall(rednet.open, side)
            end
            if rednet.isOpen(side) then opened = true end
        end
    end
    return opened
end

function net.close()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" and rednet.isOpen(side) then
            pcall(rednet.close, side)
        end
    end
end

--- Собрать конверт сообщения.
local function envelope(msgType, payload)
    return {
        v = net.VERSION,
        type = msgType,
        payload = payload or {},
        from = os.getComputerID(),
        ts = os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000),
        msg_id = newMsgId(),
    }
end

--- Отправить сообщение конкретному получателю.
function net.send(targetId, msgType, payload)
    local msg = envelope(msgType, payload)
    rednet.send(targetId, msg, net.PROTOCOL)
    return msg
end

--- Широковещательная рассылка.
function net.broadcast(msgType, payload)
    local msg = envelope(msgType, payload)
    rednet.broadcast(msg, net.PROTOCOL)
    return msg
end

--- Приём сообщения с таймаутом.
-- @param timeout секунд (nil = ждать вечно)
-- @return senderId, msg или nil при таймауте
function net.receive(timeout)
    local senderId, msg = rednet.receive(net.PROTOCOL, timeout)
    if senderId == nil then return nil end
    if type(msg) ~= "table" or not msg.type then
        return senderId, { type = "unknown", payload = msg, v = 0 }
    end
    -- Версия отсутствует у старых клиентов — считаем v1 для совместимости.
    if msg.v == nil then msg.v = 1 end
    msg.payload = msg.payload or {}
    return senderId, msg
end

--- Поиск воркеров через broadcast DISCOVER.
-- @param timeout сколько ждать ответов
-- @return таблица { [workerId] = capabilities }
function net.discoverWorkers(timeout)
    timeout = timeout or 3
    local workers = {}
    net.broadcast(net.MSG.DISCOVER, { core = os.getComputerID() })
    local deadline = os.clock() + timeout
    while os.clock() < deadline do
        local senderId, msg = net.receive(deadline - os.clock())
        if senderId and msg and msg.type == net.MSG.WORKER_HELLO then
            workers[senderId] = msg.payload or {}
        end
    end
    return workers
end

return net
