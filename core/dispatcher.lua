local util = require("lib.util")

local dispatcher = {
    queue = {},
    workers = {}, -- [id] = { status, task }
}

function dispatcher.addTask(task)
    table.insert(dispatcher.queue, task)
end

function dispatcher.registerWorker(id)
    dispatcher.workers[id] = { status = "IDLE", task = nil }
end

function dispatcher.update()
    for id, worker in pairs(dispatcher.workers) do
        if worker.status == "IDLE" and #dispatcher.queue > 0 then
            local task = table.remove(dispatcher.queue, 1)
            worker.status = "BUSY"
            worker.task = task
            -- Отправка задачи воркеру будет в server.lua через net
            return id, task
        end
    end
end

return dispatcher
