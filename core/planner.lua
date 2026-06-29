local recipes = require("core.recipes")
local storage = require("core.storage")

local planner = {}

function planner.plan(item_key, count, tasks)
    tasks = tasks or {}
    
    local avail = storage.getAvailable(item_key)
    if avail >= count then
        return tasks -- Уже есть
    end
    
    local needed = count - avail
    local recipe = recipes.get(item_key)
    
    if not recipe then
        error("Нет рецепта для " .. item_key)
    end
    
    local ops = math.ceil(needed / recipe.output_count)
    
    -- Сначала планируем ингредиенты
    for _, ing in ipairs(recipe.ingredients) do
        planner.plan(ing.key, ing.count * ops, tasks)
    end
    
    -- Добавляем задачу в конец (LIFO-ish order for dependencies)
    table.insert(tasks, {
        item = item_key,
        count = ops * recipe.output_count,
        ops = ops,
        recipe = recipe
    })
    
    return tasks
end

return planner
