local itemmatch = {}
function itemmatch.getKey(details)
    if not details then return nil end
    return details.name -- Базовая реализация, позже добавим NBT/Tags
end
function itemmatch.matches(item, filter)
    if not item or not filter then return false end
    if filter.name and item.name ~= filter.name then return false end
    return true
end
return itemmatch
