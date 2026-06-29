local net = {}
function net.init(modem) net.modem = modem end
function net.send(id, msg, protocol)
    if net.modem then rednet.send(id, msg, protocol or "shellcraft_v3") end
end
function net.broadcast(msg, protocol)
    if net.modem then rednet.broadcast(msg, protocol or "shellcraft_v3") end
end
function net.receive(protocol, timeout)
    return rednet.receive(protocol or "shellcraft_v3", timeout)
end
return net
