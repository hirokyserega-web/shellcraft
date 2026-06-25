-- ui/widgets.lua
-- Примитивы отрисовки для монитора: рамки, текст, кнопки, списки, поля.

local widgets = {}

--- Очистить область.
function widgets.clearArea(x, y, w, h)
    local old_bg = term.getBackgroundColor()
    term.setBackgroundColor(colors.black)
    for row = y, y + h - 1 do
        term.setCursorPos(x, row)
        term.write(string.rep(" ", w))
    end
    term.setBackgroundColor(old_bg)
end

--- Рамка из одинарных/двойных символов.
-- @param x,y,w,h координаты
-- @param title заголовок (опц.)
-- @param style "single" | "double"
function widgets.box(x, y, w, h, title, style)
    local chars = style == "double" and {
        tl = "+", tr = "+", bl = "+", br = "+",
        h = "=", v = "|",
    } or {
        tl = "+", tr = "+", bl = "+", br = "+",
        h = "-", v = "|",
    }
    -- Верх
    term.setCursorPos(x, y)
    term.write(chars.tl .. string.rep(chars.h, w - 2) .. chars.tr)
    -- Бока
    for row = y + 1, y + h - 2 do
        term.setCursorPos(x, row)
        term.write(chars.v)
        term.setCursorPos(x + w - 1, row)
        term.write(chars.v)
    end
    -- Низ
    term.setCursorPos(x, y + h - 1)
    term.write(chars.bl .. string.rep(chars.h, w - 2) .. chars.br)
    -- Заголовок
    if title then
        local t = " " .. title .. " "
        if #t > w - 2 then t = t:sub(1, w - 2) end
        term.setCursorPos(x + 2, y)
        term.write(t)
    end
end

--- Текст с цветами.
function widgets.text(x, y, str, fg, bg)
    if fg then term.setTextColor(fg) end
    if bg then term.setBackgroundColor(bg) end
    term.setCursorPos(x, y)
    term.write(str)
end

--- Центрированный текст.
function widgets.center(y, str, fg, bg)
    local w, _ = term.getSize()
    local x = math.floor((w - #str) / 2) + 1
    widgets.text(x, y, str, fg, bg)
end

--- Кнопка. Возвращает свои границы для hit-test.
function widgets.button(x, y, w, label, selected, opts)
    opts = opts or {}
    local fg = opts.fg or colors.white
    local bg
    if selected then
        bg = opts.bgActive or colors.blue
        fg = opts.fgActive or colors.white
    else
        bg = opts.bg or colors.gray
    end
    local label = " " .. label .. " "
    if #label > w then label = label:sub(1, w) end
    local pad = math.floor((w - #label) / 2)
    term.setTextColor(fg)
    term.setBackgroundColor(bg)
    term.setCursorPos(x, y)
    term.write(string.rep(" ", pad) .. label .. string.rep(" ", w - pad - #label))
    return { x = x, y = y, w = w, h = 1 }
end

--- Hit-test: попал ли (mx, my) в прямоугольник.
function widgets.hit(rect, mx, my)
    return mx >= rect.x and mx < rect.x + (rect.w or 1)
       and my >= rect.y and my < rect.y + (rect.h or 1)
end

--- Список с прокруткой и выделением.
-- @param x,y,w,h область
-- @param items массив строк (или {text=, fg=, bg=})
-- @param scroll смещение прокрутки
-- @param selected индекс выделенного (опц.)
-- @return ничего
function widgets.list(x, y, w, h, items, scroll, selected)
    scroll = scroll or 0
    local visible = math.max(0, #items - scroll)
    for i = 1, h do
        local idx = i + scroll
        local item = items[idx]
        term.setCursorPos(x, y + i - 1)
        if item then
            local text, fg, bg
            if type(item) == "table" then
                text = item.text or ""
                fg = item.fg or colors.white
                bg = item.bg or colors.black
            else
                text = tostring(item)
                fg = colors.white
                bg = colors.black
            end
            if idx == selected then
                bg = colors.lightBlue
                fg = colors.black
            end
            text = text:sub(1, w)
            term.setTextColor(fg)
            term.setBackgroundColor(bg)
            term.write(text .. string.rep(" ", w - #text))
        else
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.write(string.rep(" ", w))
        end
    end
end

--- Полоса прокрутки (визуальная).
function widgets.scrollbar(x, y, h, total, scroll)
    term.setTextColor(colors.darkGray)
    term.setBackgroundColor(colors.black)
    for i = 0, h - 1 do
        term.setCursorPos(x, y + i)
        term.write("|")
    end
    if total > h then
        local thumbPos = y + math.floor(scroll / (total - h) * (h - 1))
        term.setCursorPos(x, thumbPos)
        term.setBackgroundColor(colors.gray)
        term.write(" ")
    end
end

--- Полоса прогресса.
function widgets.progress(x, y, w, value, max)
    local filled = max > 0 and math.floor(value / max * w) or 0
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(x, y)
    term.write(string.rep("░", w))
    term.setBackgroundColor(colors.green)
    term.setCursorPos(x, y)
    term.write(string.rep("█", math.min(filled, w)))
end

return widgets
