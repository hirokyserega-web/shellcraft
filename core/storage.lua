local itemmatch = require("lib.itemmatch")
local util = require("lib.util")

local storage = {
    cache = {},
    reservations = {},
    peripherals = {}
}

function storage.init(pList)
    storage.peripherals = pList
end

function storage.scan()
    storage.cache = {}
    for _, pName in ipairs(storage.peripherals) do
        local p = peripheral.wrap(pName)
        if p and p.list then
            local list = p.list()
            for slot, item in pairs(list) do
                local key = itemmatch.getKey(item)
                if not storage.cache[key] then
                    storage.cache[key] = { count = 0, detail = item }
                end
                storage.cache[key].count = storage.cache[key].count + item.count
            end
        end
    end
end

function storage.getAvailable(key)
    local total = (storage.cache[key] and storage.cache[key].count) or 0
    local reserved = storage.reservations[key] or 0
    return total - reserved
end

function storage.reserve(key, count)
    local avail = storage.getAvailable(key)
    if avail >= count then
        storage.reservations[key] = (storage.reservations[key] or 0) + count
        return true
    end
    return false
end

function storage.release(key, count)
    if storage.reservations[key] then
        storage.reservations[key] = math.max(0, storage.reservations[key] - count)
    end
end

return storage
