-- lang/ru.lua
-- Словарь переводов: item ID -> русское имя.
--
-- ЭТОТ ФАЙЛ АВТОСГЕНЕРИРУЕТСЯ tools/gen_lang.lua из официальных файлов
-- перевода Minecraft (ru_ru.json). Не редактируйте вручную — перегенерируйте:
--
--     lua tools/gen_lang.lua ru_ru.json lang/ru.lua
--     lua tools/gen_lang.lua vanilla/ru_ru.json create_ru.json lang/ru.lua
--
-- Ниже приведён базовый ванильный словарь как запасной вариант: он используется
-- до первого запуска генератора и корректен для типовых предметов.
-- Полнота покрытия (включая предметы модов) достигается запуском генератора
-- с lang-файлами нужных модов.
--
-- Логика отображения имени (приоритеты, кеш, fallback) живёт в lib/names.lua
-- (names.display). Здесь — ТОЛЬКО данные.

local ru = {}

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
    ["minecraft:blast_furnace"] = "Плавильная печь",
    ["minecraft:smoker"] = "Коптильня",

    -- Слитки/материалы
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
    ["minecraft:quartz"] = "Кварц",
    ["minecraft:lapis_lazuli"] = "Лазурит",
    ["minecraft:brick"] = "Кирпич",
    ["minecraft:nether_brick"] = "Незерский кирпич",
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

    -- Базовые блоки
    ["minecraft:cobblestone"] = "Булыжник",
    ["minecraft:stone"] = "Камень",
    ["minecraft:dirt"] = "Земля",
    ["minecraft:sand"] = "Песок",
    ["minecraft:gravel"] = "Гравий",
    ["minecraft:tnt"] = "ТНТ",
    ["minecraft:torch"] = "Факел",
    ["minecraft:bookshelf"] = "Книжный шкаф",

    -- Редстоун
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
    ["minecraft:minecart"] = "Вагонетка",
    ["minecraft:rail"] = "Рельсы",
    ["minecraft:powered_rail"] = "Электрические рельсы",
}

return ru
