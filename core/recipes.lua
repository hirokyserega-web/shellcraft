local util = require("lib.util")
local itemmatch = require("lib.itemmatch")

local recipes = {
    data = {},
    path = "recipes.dat"
}

function recipes.init(path)
    recipes.path = path or "recipes.dat"
    recipes.load()
end

function recipes.load()
    recipes.data = util.loadFile(recipes.path) or {}
end

function recipes.save()
    util.saveFile(recipes.path, recipes.data)
end

function recipes.add(recipe)
    if not recipe.output_item then return false end
    recipes.data[recipe.output_item] = recipe
    recipes.save()
    return true
end

function recipes.get(item_key)
    return recipes.data[item_key]
end

return recipes
