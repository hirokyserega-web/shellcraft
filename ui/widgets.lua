-- ui/widgets.lua
-- Примитивы отрисовки для монитора: рамки, текст, кнопки, списки, поля.
-- Все тексты переведены на английский язык. Все элементы регистрируют hits.

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
function widgets.box(x, y, w, h, title, style)
    widgets.clearArea(x, y, w, h)
    local chars = style == "double" and {
        tl = "+", tr = "+", bl = "+", br = "+",
        h = "=", v = "|",
    } or {
        tl = "+", tr = "+", bl = "+", br = "+",
        h = "-", v = "|",
    }
    -- Вверх
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
    widgets.text(math.max(1, x), y, str, fg, bg)
end

--- Обрезка строки до максимальной ширины.
function widgets.clip(str, maxW)
    if not str then return "" end
    if #str <= maxW then return str end
    return str:sub(1, maxW)
end

--- Кнопка с автоматической шириной, переносом и регистрацией hits.
function widgets.button(ui, x, y, w, label, opts, action)
    opts = opts or {}
    local scrW, scrH = term.getSize()
    
    local minW = #label + 2
    w = math.max(w or minW, minW)
    
    -- Если кнопка выходит за край, пытаемся перенести или сжать
    if x + w - 1 > scrW then
        if x > 2 and scrW - x + 1 < minW then
            x = 2
            y = y + 1
        end
        w = math.min(w, scrW - x + 1)
    end
    
    if w <= 0 or y > scrH then return { x = x, y = y, w = 0, h = 0 } end
    
    local fg = opts.fg or colors.white
    local bg = opts.bg or colors.gray
    
    if opts.kind == "active" or opts.selected then
        bg = opts.bgActive or colors.green
        fg = opts.fgActive or colors.white
    elseif opts.kind == "danger" then
        bg = colors.red
        fg = colors.white
    elseif opts.kind == "normal" then
        bg = colors.gray
        fg = colors.white
    end
    
    local cleanLabel = label
    if #cleanLabel > w then
        cleanLabel = cleanLabel:sub(1, w)
    end
    local pad = math.floor((w - #cleanLabel) / 2)
    local text = string.rep(" ", pad) .. cleanLabel .. string.rep(" ", w - pad - #cleanLabel)
    
    term.setTextColor(fg)
    term.setBackgroundColor(bg)
    term.setCursorPos(x, y)
    term.write(text)
    
    if ui and action then
        ui:addHit(x, y, w, 1, action)
    end
    return { x = x, y = y, w = w, h = 1 }
end

--- Лента вкладок с поддержкой скроллинга кнопками < и >.
function widgets.tabs(ui, y, items, activeId, tabState, onSelect)
    local scrW, _ = term.getSize()
    tabState = tabState or { scroll = 1 }
    tabState.scroll = tabState.scroll or 1
    
    local totalW = 0
    for _, item in ipairs(items) do
        local label = " " .. item.title .. " "
        totalW = totalW + #label + 1
    end
    
    local needsScroll = totalW > scrW
    local startX = 1
    local availableW = scrW
    
    if needsScroll then
        widgets.button(ui, 1, y, 2, "<", { kind = tabState.scroll > 1 and "active" or "normal" }, function()
            tabState.scroll = math.max(1, tabState.scroll - 1)
        end)
        startX = 4
        availableW = scrW - 6
    end
    
    local currentX = startX
    local tabCount = #items
    local lastTabIdx = tabCount
    
    for i = tabState.scroll, tabCount do
        local item = items[i]
        local label = " " .. item.title .. " "
        
        if currentX + #label - 1 > startX + availableW - 1 then
            lastTabIdx = i - 1
            break
        end
        
        local active = (item.id == activeId)
        local bg = active and colors.lightBlue or colors.gray
        local fg = active and colors.black or colors.white
        
        term.setBackgroundColor(bg)
        term.setTextColor(fg)
        term.setCursorPos(currentX, y)
        term.write(label)
        
        ui:addHit(currentX, y, #label, 1, function()
            onSelect(item.id)
        end)
        
        currentX = currentX + #label + 1
    end
    
    if needsScroll then
        widgets.button(ui, scrW - 1, y, 2, ">", { kind = lastTabIdx < tabCount and "active" or "normal" }, function()
            if lastTabIdx < tabCount then
                tabState.scroll = tabState.scroll + 1
            end
        end)
    end
end

--- Список с прокруткой, выделением и кнопками прокрутки.
function widgets.scrollList(ui, x, y, w, h, items, state, onSelect)
    state.scroll = state.scroll or 0
    state.selected = state.selected or 1
    
    local total = #items
    local showScroll = total > h
    local listW = showScroll and (w - 4) or w
    
    for i = 1, h do
        local idx = i + state.scroll
        local item = items[idx]
        local rowY = y + i - 1
        
        term.setCursorPos(x, rowY)
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
            
            if idx == state.selected then
                bg = colors.lightBlue
                fg = colors.black
            end
            
            text = widgets.clip(text, listW)
            term.setTextColor(fg)
            term.setBackgroundColor(bg)
            term.write(text .. string.rep(" ", listW - #text))
            
            ui:addHit(x, rowY, listW, 1, function()
                state.selected = idx
                if onSelect then onSelect(idx, item) end
            end)
        else
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.write(string.rep(" ", listW))
        end
    end
    
    if showScroll then
        local scrollX = x + w - 3
        widgets.button(ui, scrollX, y, 3, "^", { kind = state.scroll > 0 and "active" or "normal" }, function()
            state.scroll = math.max(0, state.scroll - 1)
        end)
        widgets.button(ui, scrollX, y + h - 1, 3, "v", { kind = state.scroll + h < total and "active" or "normal" }, function()
            if state.scroll + h < total then
                state.scroll = state.scroll + 1
            end
        end)
        
        if h > 2 then
            local barH = h - 2
            local barY = y + 1
            term.setTextColor(colors.darkGray)
            term.setBackgroundColor(colors.black)
            for i = 0, barH - 1 do
                term.setCursorPos(scrollX + 1, barY + i)
                term.write("|")
            end
            
            local maxScroll = total - h
            local thumbPos = math.floor(state.scroll / maxScroll * (barH - 1))
            term.setCursorPos(scrollX + 1, barY + thumbPos)
            term.setBackgroundColor(colors.gray)
            term.write(" ")
        end
    end
end

--- Степпер для регулирования количества.
function widgets.stepper(ui, x, y, w, value, onChange)
    local valStr = tostring(value)
    
    if w >= 22 then
        widgets.button(ui, x, y, 5, "-10", { kind = "normal" }, function() onChange(-10) end)
        widgets.button(ui, x + 6, y, 4, "-1", { kind = "normal" }, function() onChange(-1) end)
        
        local labelW = w - 22
        widgets.text(x + 11, y, string.format("%" .. labelW .. "s", valStr):sub(1, labelW), colors.yellow, colors.black)
        
        widgets.button(ui, x + 11 + labelW + 1, y, 4, "+1", { kind = "normal" }, function() onChange(1) end)
        widgets.button(ui, x + 11 + labelW + 6, y, 5, "+10", { kind = "normal" }, function() onChange(10) end)
    else
        widgets.button(ui, x, y, 4, "-1", { kind = "normal" }, function() onChange(-1) end)
        
        local labelW = w - 10
        widgets.text(x + 5, y, string.format("%" .. labelW .. "s", valStr):sub(1, labelW), colors.yellow, colors.black)
        
        widgets.button(ui, x + 5 + labelW + 1, y, 4, "+1", { kind = "normal" }, function() onChange(1) end)
    end
end

--- Цифровая клавиатура (Numpad).
function widgets.numpad(ui, x, y, onKey)
    local keys_num = {
        {"1", "2", "3"},
        {"4", "5", "6"},
        {"7", "8", "9"},
        {"<-", "0", "C"}
    }
    for rowIdx, rKeys in ipairs(keys_num) do
        local ry = y + rowIdx - 1
        for colIdx, k in ipairs(rKeys) do
            local rx = x + (colIdx - 1) * 4
            widgets.button(ui, rx, ry, 3, k, { kind = "normal" }, function()
                onKey(k)
            end)
        end
    end
end

--- Модальное диалоговое окно.
function widgets.dialog(ui, title, bodyFn, buttons)
    local scrW, scrH = term.getSize()
    local dw = math.max(24, scrW - 4)
    local dh = math.max(10, scrH - 4)
    local dx = math.floor((scrW - dw) / 2) + 1
    local dy = math.floor((scrH - dh) / 2) + 1
    
    widgets.box(dx, dy, dw, dh, title, "double")
    
    local cx = dx + 1
    local cy = dy + 1
    local cw = dw - 2
    local ch = dh - 3
    
    if bodyFn then
        bodyFn(cx, cy, cw, ch)
    end
    
    local btnY = dy + dh - 2
    if buttons and #buttons > 0 then
        local totalBtnW = 0
        local minBtnW = 6
        for _, btn in ipairs(buttons) do
            local bw = math.max(minBtnW, #btn.label + 2)
            totalBtnW = totalBtnW + bw + 1
        end
        totalBtnW = totalBtnW - 1
        
        local btnStartX = dx + math.floor((dw - totalBtnW) / 2)
        local curX = btnStartX
        for _, btn in ipairs(buttons) do
            local bw = math.max(minBtnW, #btn.label + 2)
            widgets.button(ui, curX, btnY, bw, btn.label, { kind = btn.kind }, btn.action)
            curX = curX + bw + 1
        end
    end
end

--- Полоса прогресса.
function widgets.progress(x, y, w, value, max)
    local filled = max > 0 and math.floor(value / max * w) or 0
    term.setCursorPos(x, y)
    term.setBackgroundColor(colors.gray)
    term.write(string.rep(" ", w))
    if filled > 0 then
        term.setBackgroundColor(colors.green)
        term.setCursorPos(x, y)
        term.write(string.rep(" ", math.min(filled, w)))
    end
end

--- Сегментированный переключатель.
function widgets.segmented(ui, y, items, activeId, onSelect)
    local scrW, _ = term.getSize()
    local currentX = 2
    local currentY = y
    
    term.setCursorPos(1, currentY)
    term.setTextColor(colors.gray)
    term.setBackgroundColor(colors.black)
    term.write("[")
    
    for idx, item in ipairs(items) do
        local label = " " .. item.title .. " "
        local active = (item.id == activeId)
        
        local requiredW = #label + 1
        if currentX + requiredW > scrW then
            term.setCursorPos(currentX, currentY)
            term.setTextColor(colors.gray)
            term.setBackgroundColor(colors.black)
            term.write("]")
            
            currentY = currentY + 1
            currentX = 2
            
            term.setCursorPos(1, currentY)
            term.setTextColor(colors.gray)
            term.setBackgroundColor(colors.black)
            term.write("[")
        end
        
        local bg = active and colors.lightBlue or colors.black
        local fg = active and colors.black or colors.white
        
        term.setBackgroundColor(bg)
        term.setTextColor(fg)
        term.setCursorPos(currentX, currentY)
        term.write(label)
        
        if ui and onSelect then
            ui:addHit(currentX, currentY, #label, 1, function()
                onSelect(item.id)
            end)
        end
        
        currentX = currentX + #label
        
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.gray)
        term.setCursorPos(currentX, currentY)
        if idx < #items then
            term.write("|")
            currentX = currentX + 1
        else
            term.write("]")
        end
    end
    return currentY
end

return widgets
