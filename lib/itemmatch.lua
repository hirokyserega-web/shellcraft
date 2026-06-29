-- lib/itemmatch.lua
-- Нормализация и сравнение предметных спецификаций.
-- Используется для рецептов, резервирования и точного сопоставления stack detail.

local itemmatch = {}

local function stableScalar(v)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "nil" then
        return "nil"
    else
        return string.format("<%s>", t)
    end
end

local function stableSerialize(value, seen)
    if type(value) ~= "table" then
        return stableScalar(value)
    end
    seen = seen or {}
    if seen[value] then
        return '"<cycle>"'
    end
    seen[value] = true
    local keys = {}
    for k in pairs(value) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta == tb then
            return tostring(a) < tostring(b)
        end
        return ta < tb
    end)
    local parts = { "{" }
    for i, k in ipairs(keys) do
        if i > 1 then parts[#parts + 1] = "," end
        parts[#parts + 1] = "[" .. stableSerialize(k, seen) .. "]=" .. stableSerialize(value[k], seen)
    end
    parts[#parts + 1] = "}"
    seen[value] = nil
    return table.concat(parts)
end

local function clone(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do
        out[k] = clone(x)
    end
    return out
end

local function isArray(t)
    if type(t) ~= "table" then return false end
    local max, n = 0, 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        if k > max then max = k end
        n = n + 1
    end
    return max == n
end

local function normalizeTags(tags)
    if not tags then return nil end
    local out = {}
    if isArray(tags) then
        for _, tag in ipairs(tags) do
            if tag ~= nil then out[tostring(tag)] = true end
        end
    else
        for k, v in pairs(tags) do
            if v then out[tostring(k)] = true end
        end
    end
    return next(out) and out or nil
end

local function normalizeExact(detail)
    if type(detail) ~= "table" then return nil end
    local out = {
        name = detail.name,
        damage = detail.damage,
        maxDamage = detail.maxDamage,
        nbt = detail.nbt,
        components = detail.components,
        tags = normalizeTags(detail.tags),
    }
    if detail.displayName then out.displayName = detail.displayName end
    if detail.lore then out.lore = clone(detail.lore) end
    return out
end

local function normalizeOne(spec)
    if spec == nil then return nil end
    if type(spec) == "string" then
        if spec:sub(1, 1) == "#" then
            return { tag = spec:sub(2) }
        end
        return { name = spec }
    end
    if type(spec) ~= "table" then
        return { name = tostring(spec) }
    end

    if spec.variants then
        local variants = {}
        for _, variant in ipairs(spec.variants) do
            local norm = normalizeOne(variant)
            if norm then variants[#variants + 1] = norm end
        end
        return {
            variants = variants,
            count = spec.count or 1,
            tags = normalizeTags(spec.tags),
            name = spec.name,
            tag = spec.tag,
        }
    end

    local out = {
        name = spec.name or spec.id,
        tag = spec.tag,
        damage = spec.damage,
        maxDamage = spec.maxDamage,
        nbt = spec.nbt,
        components = spec.components,
        tags = normalizeTags(spec.tags),
        displayName = spec.displayName,
        count = spec.count or 1,
    }
    if spec.any then out.any = true end
    return out
end

function itemmatch.normalize(spec)
    if type(spec) == "table" and (spec.name or spec.id or spec.tag or spec.variants or spec.any) then
        return normalizeOne(spec)
    end
    return normalizeOne(spec)
end

function itemmatch.fromDetail(detail)
    return normalizeExact(detail)
end

function itemmatch.detailTags(detail)
    local tags = {}
    if type(detail) ~= "table" or type(detail.tags) ~= "table" then
        return tags
    end
    for k, v in pairs(detail.tags) do
        if v then tags[tostring(k)] = true end
    end
    return tags
end

function itemmatch.detailKey(detail)
    if type(detail) ~= "table" or not detail.name then
        return ""
    end
    local parts = {
        "name=" .. tostring(detail.name),
        "damage=" .. tostring(detail.damage),
        "maxDamage=" .. tostring(detail.maxDamage),
        "nbt=" .. stableSerialize(detail.nbt),
        "components=" .. stableSerialize(detail.components),
    }
    return table.concat(parts, "|")
end

function itemmatch.specKey(spec)
    local s = itemmatch.normalize(spec)
    if not s then return "" end
    if s.variants then
        local keys = {}
        for _, variant in ipairs(s.variants) do
            keys[#keys + 1] = itemmatch.specKey(variant)
        end
        table.sort(keys)
        return "variants(" .. table.concat(keys, ",") .. ")"
    end
    if s.any then return "any" end
    if s.tag then return "tag:" .. tostring(s.tag) end
    local parts = {
        "name=" .. tostring(s.name or s.id or ""),
        "damage=" .. tostring(s.damage),
        "maxDamage=" .. tostring(s.maxDamage),
        "nbt=" .. stableSerialize(s.nbt),
        "components=" .. stableSerialize(s.components),
    }
    return table.concat(parts, "|")
end

function itemmatch.describe(spec)
    local s = itemmatch.normalize(spec)
    if not s then return "?" end
    if s.variants and #s.variants > 0 then
        return itemmatch.describe(s.variants[1])
    end
    if s.any then return "any item" end
    if s.tag then return "#" .. tostring(s.tag) end
    return tostring(s.name or s.id or "?")
end

function itemmatch.matches(detail, spec)
    local s = itemmatch.normalize(spec)
    if not s then return false end
    if type(detail) ~= "table" or not detail.name then
        return false
    end
    if s.any then return true end
    if s.variants then
        for _, variant in ipairs(s.variants) do
            if itemmatch.matches(detail, variant) then return true end
        end
        return false
    end
    if s.tag then
        local tags = itemmatch.detailTags(detail)
        return tags[s.tag] == true
    end
    if s.tags then
        local tags = itemmatch.detailTags(detail)
        for tag in pairs(s.tags) do
            if tags[tag] then return true end
        end
        return false
    end
    if s.name and detail.name ~= s.name then return false end
    if s.damage ~= nil and detail.damage ~= s.damage then return false end
    if s.maxDamage ~= nil and detail.maxDamage ~= s.maxDamage then return false end
    if s.nbt ~= nil and stableSerialize(detail.nbt) ~= stableSerialize(s.nbt) then return false end
    if s.components ~= nil and stableSerialize(detail.components) ~= stableSerialize(s.components) then return false end
    return true
end

function itemmatch.isTagSpec(spec)
    local s = itemmatch.normalize(spec)
    return s and (s.tag ~= nil or (s.variants == nil and s.name == nil and s.any ~= true)) or false
end

function itemmatch.keyForReservation(spec)
    return itemmatch.specKey(spec)
end

function itemmatch.cloneSpec(spec)
    return clone(spec)
end

return itemmatch
