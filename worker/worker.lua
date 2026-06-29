local net = require("lib.net")
local util = require("lib.util")

local worker = {
    id = os.getComputerID(),
    state = "IDLE",
    current_task = nil
}

function worker.run()
    util.log("Worker started, ID: " .. worker.id)
    while true do
        if worker.state == "IDLE" then
            net.send(0, { type = "WORKER_READY", id = worker.id })
            local id, msg = net.receive(nil, 5)
            if msg and msg.type == "TASK_ASSIGN" then
                worker.current_task = msg.task
                worker.state = "LOADING"
            end
        elseif worker.state == "LOADING" then
            util.log("Loading resources for " .. worker.current_task.item)
            -- Здесь будет логика забора из входного сундука
            worker.state = "CRAFTING"
        elseif worker.state == "CRAFTING" then
            util.log("Crafting " .. worker.current_task.item)
            -- Здесь будет логика расстановки в сетку и craft()
            worker.state = "UNLOADING"
        elseif worker.state == "UNLOADING" then
            util.log("Unloading result")
            -- Выгрузка в выходной сундук
            net.send(0, { type = "TASK_DONE", id = worker.id })
            worker.state = "IDLE"
        end
        sleep(1)
    end
end

return worker
