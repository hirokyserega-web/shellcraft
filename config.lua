local config = {
    roles = {
        storage = {},
        monitor = nil,
        modem = nil,
        buffer_in = {},
        buffer_out = {}
    }
}
function config.resolvePeripherals()
    local names = peripheral.getNames()
    for _, name in ipairs(names) do
        local type = peripheral.getType(name)
        if type == "modem" then config.roles.modem = name
        elseif type == "monitor" then config.roles.monitor = name
        elseif type == "drive" then -- skip
        else table.insert(config.roles.storage, name) end
    end
end
return config
