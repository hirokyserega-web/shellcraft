-- lang/ru.lua
-- Словарь переводов item ID -> русское имя + функция локализации.

local ru = {}

--- Основной словарь: ID -> русское название.
ru.dict = {
    -- Дерево
    ["minecraft:oak_log"] = "Дубовое бревно",
    ["minecraft:spruce_log"] = "Еловое бревно",
    ["minecraft:birch_log"] = "Берёзовое бревно",
    ["minecraft:jungle_log"] = "Бревно тропического дерева",
    ["minecraft:acacia_log"] = "Акациевое бревно",
    ["minecraft:dark_oak_log"] = "Бревно тёмного дуба",
    ["minecraft:oak_planks"] = "Дубовые доски",
    ["minecraft:spruce_planks"] = "Еловые доски",
    ["minecraft:birch_planks"] = "Берёзовые доски",
    ["minecraft:jungle_planks"] = "Тропические доски",
    ["minecraft:acacia_planks"] = "Акациевые доски",
    ["minecraft:dark_oak_planks"] = "Доски тёмного дуба",
    ["minecraft:stick"] = "Палка",
    ["minecraft:oak_slab"] = "Дубовая плита",
    ["minecraft:chest"] = "Сундук",
    ["minecraft:barrel"] = "Бочка",
    ["minecraft:crafting_table"] = "Верстак",
    ["minecraft:furnace"] = "Печь",
    ["minecraft:blast_furnace"] = "Доменная печь",
    ["minecraft:smoker"] = "Коптильня",

    -- Инструменты/крафт-материалы
    ["minecraft:iron_ingot"] = "Железный слиток",
    ["minecraft:gold_ingot"] = "Золотой слиток",
    ["minecraft:copper_ingot"] = "Медный слиток",
    ["minecraft:netherite_ingot"] = "Незеритовый слиток",
    ["minecraft:iron_nugget"] = "Железный самородок",
    ["minecraft:gold_nugget"] = "Золотой самородок",
    ["minecraft:iron_block"] = "Блок железа",
    ["minecraft:gold_block"] = "Блок золота",
    ["minecraft:diamond"] = "Алмаз",
    ["minecraft:diamond_block"] = "Алмазный блок",
    ["minecraft:emerald"] = "Изумруд",
    ["minecraft:coal"] = "Уголь",
    ["minecraft:charcoal"] = "Древесный уголь",
    ["minecraft:redstone"] = "Редстоун",
    ["minecraft:redstone_block"] = "Блок редстоуна",
    ["minecraft:quartz"] = "Кварц",
    ["minecraft:lapis_lazuli"] = "Лазурит",
    ["minecraft:glowstone_dust"] = "Светокаменная пыль",
    ["minecraft:clay_ball"] = "Глина",
    ["minecraft:brick"] = "Кирпич",
    ["minecraft:nether_brick"] = "Незерский кирпич",
    ["minecraft:netherrack"] = "Незеррак",
    ["minecraft:obsidian"] = "Обсидиан",
    ["minecraft:glass"] = "Стекло",
    ["minecraft:paper"] = "Бумага",
    ["minecraft:book"] = "Книга",
    ["minecraft:leather"] = "Кожа",
    ["minecraft:string"] = "Нить",
    ["minecraft:feather"] = "Перо",
    ["minecraft:gunpowder"] = "Порох",
    ["minecraft:blaze_rod"] = "Стержень ифрита",
    ["minecraft:ender_pearl"] = "Жемчуг Края",
    ["minecraft:ender_eye"] = "Око Края",
    ["minecraft:bone"] = "Кость",
    ["minecraft:bone_meal"] = "Костная мука",
    ["minecraft:slime_ball"] = "Слизь",

    -- Инструменты/оружие/броня (минимально)
    ["minecraft:wooden_pickaxe"] = "Деревянная кирка",
    ["minecraft:stone_pickaxe"] = "Каменная кирка",
    ["minecraft:iron_pickaxe"] = "Железная кирка",
    ["minecraft:diamond_pickaxe"] = "Алмазная кирка",
    ["minecraft:netherite_pickaxe"] = "Незеритовая кирка",
    ["minecraft:wooden_sword"] = "Деревянный меч",
    ["minecraft:stone_sword"] = "Каменный меч",
    ["minecraft:iron_sword"] = "Железный меч",
    ["minecraft:bow"] = "Лук",
    ["minecraft:arrow"] = "Стрела",
    ["minecraft:shield"] = "Щит",
    ["minecraft:fishing_rod"] = "Удочка",

    -- Блоки базовые
    ["minecraft:cobblestone"] = "Булыжник",
    ["minecraft:stone"] = "Камень",
    ["minecraft:dirt"] = "Земля",
    ["minecraft:sand"] = "Песок",
    ["minecraft:gravel"] = "Гравий",
    ["minecraft:tnt"] = "ТНТ",
    ["minecraft:torch"] = "Факел",
    ["minecraft:bookshelf"] = "Книжный шкаф",
    ["minecraft:torch"] = "Факел",

    -- Транспорт/редстоун
    ["minecraft:minecart"] = "Вагонетка",
    ["minecraft:rail"] = "Рельсы",
    ["minecraft:powered_rail"] = "Электрические рельсы",
    ["minecraft:repeater"] = "Повторитель",
    ["minecraft:comparator"] = "Компаратор",
    ["minecraft:redstone_torch"] = "Редстоуновый факел",
    ["minecraft:lever"] = "Рычаг",
    ["minecraft:piston"] = "Поршень",
    ["minecraft:sticky_piston"] = "Липкий поршень",
    ["minecraft:hopper"] = "Воронка",
    ["minecraft:dropper"] = "Выбрасыватель",
    ["minecraft:dispenser"] = "Раздатчик",
    ["minecraft:observer"] = "Наблюдатель",
}

--- Путь к файлу лога отсутствующих переводов.
ru.MISSING_FILE = "lang/missing.txt"

--- Сет уже залогированных отсутствующих ID (чтобы не дублировать).
local loggedMissing = {}

--- Локализация ID предмета.
-- @param id item ID (minecraft:oak_planks)
-- @param displayName запасной displayName из getItemDetail
-- @return русское имя
function ru.localize(id, displayName)
    if not id then return "?" end
    local s = tostring(id)
    -- 1. Точный перевод
    if ru.dict[s] then return ru.dict[s] end
    -- 2. displayName из getItemDetail (часто уже локализован игрой/ресурс-паком)
    if displayName and displayName ~= "" then return displayName end
    -- 3. Красивое форматирование ID
    local pretty = util.formatId(s)
    -- Логируем отсутствие перевода
    if not loggedMissing[s] then
        loggedMissing[s] = true
        util.ensureDir("lang")
        local f = fs.open(ru.MISSING_FILE, "a")
        if f then
            f.writeLine(s)
            f.close()
        end
    end
    return pretty
end

return ru
