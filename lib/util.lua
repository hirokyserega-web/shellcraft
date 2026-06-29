local util = {}
function util.log(msg, lvl) print("["..os.date("%H:%M:%S").."] ["..(lvl or "INFO").."] "..msg) end
function util.deepCopy(o)
    if type(o) ~= 'table' then return o end
    local r = {} for k,v in pairs(o) do r[util.deepCopy(k)] = util.deepCopy(v) end
    return r
end
function util.serialize(t) return textutils.serialize(t) end
function util.unserialize(s) return textutils.unserialize(s) end
function util.saveFile(path, data)
    local f = fs.open(path, "w")
    if f then f.write(util.serialize(data)) f.close() return true end
    return false
end
function util.loadFile(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if f then local d = util.unserialize(f.readAll()) f.close() return d end
    return nil
end
return util
