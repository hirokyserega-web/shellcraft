-- ui/ui.lua
-- Главный UI ShellCraft: вкладки на мониторе, тач-управление.
-- Табы генерируются динамически (вкладка механизмов появляется при наличии машин).

local ui = {}
ui.__index = ui

--- Создать UI.
-- @param monitor объект монитора (term.redirect)
-- @param deps { storage, recipes, dispatcher, machines, lang }
function ui.new(monitor, deps)
    local self = setmetatable({}, ui)
    self.monitor = monitor
    self.deps = deps
    self.activeTab = "craft"
    self.tabs = {}
    self.tabBounds = {}
    self.state = {
        craft    = { scroll = 0, selected = 1, mode = "list", qty = "1", active = nil },
        storage  = { scroll = 0, selected = 1, search = "" },
        machines = { scroll = 0, selected = 1 },
        recipes  = { scroll = 0, selected = 1, mode = "list" },
        log      = { scroll = 0 },
    }
    self.log = {}
    self.buttons = {}  -- кнопки текущего экрана для hit-test {rect=, action=}
    return self
end

--- Добавить запись в лог UI.
function ui:addLog(msg)
    table.insert(self.log, { time = util.now(), msg = tostring(msg) })
    if #self.log > 200 then table.remove(self.log, 1) end
end

--- Шаг крафта завершён успешно (вызывается из onEvent сервера).
function ui:taskDone()
    local a = self.state.craft.active
    if a then a.done = (a.done or 0) + 1 end
end

--- Шаг крафта завершён с ошибкой.
function ui:taskFailed()
    local a = self.state.craft.active
    if a then a.failed = (a.failed or 0) + 1 end
end

--- Число доступных исполнителей (воркеры + машины) — для оценки параллельности.
function ui:workersCount()
    local n = 1
    if self.deps.dispatcher then n = math.max(1, self.deps.dispatcher:workerCount()) end
    if self.deps.machines then n = n + self.deps.machines:count() end
    return n
end

--- Сгенерировать список вкладок (динамически).
function ui:buildTabs()
    self.tabs = {
        { id = "craft",   title = "Craft" },
        { id = "storage", title = "Storage" },
    }
    if self.deps.machines and self.deps.machines:count() > 0 then
        table.insert(self.tabs, { id = "machines", title = "Machines" })
    end
    table.insert(self.tabs, { id = "recipes", title = "Recipes" })
    table.insert(self.tabs, { id = "log",     title = "Log" })
end

--- Переключиться на вкладку (если существует).
function ui:switchTab(id)
    for _, t in ipairs(self.tabs) do
        if t.id == id then self.activeTab = id; return true end
    end
    return false
end

--- Отрисовать полосу вкладок.
function ui:drawTabs(y)
    self.tabBounds = {}
    local w, _ = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setCursorPos(1, y)
    term.write(string.rep(" ", w))
    local x = 2
    for _, t in ipairs(self.tabs) do
        local label = " " .. t.title .. " "
        local active = (t.id == self.activeTab)
        local bg = active and colors.lightBlue or colors.gray
        local fg = active and colors.black or colors.white
        term.setBackgroundColor(bg)
        term.setTextColor(fg)
        term.setCursorPos(x, y)
        term.write(label)
        self.tabBounds[#self.tabBounds + 1] = { x = x, y = y, w = #label, id = t.id }
        x = x + #label + 1
    end
end

--- Зарегистрировать кнопку для hit-test.
function ui:button(x, y, w, label, selected, action, opts)
    local rect = widgets.button(x, y, w, label, selected, opts)
    table.insert(self.buttons, { rect = rect, action = action })
    return rect
end

--- Сбросить список кнопок (в начале каждого render).
function ui:resetButtons()
    self.buttons = {}
end

--- Главная отрисовка.
function ui:render()
    if not self.monitor then return end
    local old = term.redirect(self.monitor)
    self:resetButtons()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()

    -- Header Bar background (solid gray)
    term.setBackgroundColor(colors.gray)
    term.setCursorPos(1, 1)
    term.write(string.rep(" ", w))

    -- Title left-aligned
    term.setTextColor(colors.yellow)
    term.setCursorPos(2, 1)
    term.write(" ShellCraft")

    -- Status right-aligned
    local status = ""
    if self.deps.dispatcher then
        local free = self.deps.dispatcher:freeCount()
        local total = 0
        for _ in pairs(self.deps.dispatcher.workers) do total = total + 1 end
        local active = #self.deps.dispatcher:activeTasks()
        status = string.format("Workers: %d/%d [Act: %d]", total - free, total, active)
    end
    term.setTextColor(colors.white)
    term.setCursorPos(math.max(2, w - #status - 4), 1)
    term.write(status)

    -- Red exit button on-screen
    self:button(w - 2, 1, 3, "X", false, function()
        os.queueEvent("shellcraft_quit")
    end, { bg = colors.red, fg = colors.white })

    -- Вкладки
    self:buildTabs()
    self:drawTabs(2)

    -- Separator line at Row 3
    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.gray)
    term.write(string.rep("-", w))

    -- Контент
    local tab = self.activeTab
    if tab == "craft" then self:renderCraft(4, h - 1, w)
    elseif tab == "storage" then self:renderStorage(4, h - 1, w)
    elseif tab == "machines" then self:renderMachines(4, h - 1, w)
    elseif tab == "recipes" then self:renderRecipes(4, h - 1, w)
    elseif tab == "log" then self:renderLog(4, h - 1, w)
    end

    -- Подвал: прогресс активного крафта ИЛИ подсказка
    term.setBackgroundColor(colors.black)
    term.clearLine()  -- на строке h
    term.setCursorPos(1, h)
    local a = self.state.craft.active
    if a and (a.done + a.failed) < a.total then
        local completed = a.done + a.failed
        local pct = a.total > 0 and math.floor(completed / a.total * 100) or 0
        -- ETA: пока нет завершённых — берём начальную оценку, потом уточняем по факту
        local now = os.epoch("utc")
        local elapsed = (now - (a.started or now)) / 1000
        local eta
        if completed > 0 then
            eta = (elapsed / completed) * (a.total - completed)
        else
            eta = a.etaTotal or 0
        end
        -- текстовая полоса прогресса
        local etaStr = planner.formatDuration(eta)
        local rightLen = #etaStr + 10
        local barLen = math.max(8, w - rightLen)
        local filled = math.floor(barLen * completed / math.max(1, a.total))
        local bar = string.rep("█", filled) .. string.rep("░", barLen - filled)
        term.setTextColor(colors.green)
        term.write(bar)
        term.setTextColor(colors.lightGray)
        term.write(string.format(" %3d%% ETA %s", pct, etaStr))
    else
        if a and (a.done + a.failed) >= a.total then
            self.state.craft.active = nil
        end
        term.setTextColor(colors.lightGray)
        term.write(self:footerHint())
    end

    term.redirect(old)
end

--- Подсказка в подвале.
function ui:footerHint()
    local tab = self.activeTab
    if tab == "craft" then
        local m = self.state.craft.mode
        if m == "list" then return "Tap - select recipe. X - exit." end
        return "Tap digits/OK. Cancel - back."
    elseif tab == "storage" then return "Scroll by tapping edges. X - exit."
    elseif tab == "machines" then return "Tap - refresh status."
    elseif tab == "recipes" then return "Tap - select. [+Learn] - new recipe."
    elseif tab == "log" then return "Scroll by tapping edges."
    end
    return ""
end

----------------------------------------------------------------
-- Вкладка КРАФТ
----------------------------------------------------------------
function ui:renderCraft(yTop, yBot, w)
    local st = self.state.craft
    local recipes = self.deps.recipes
    local list = recipes:all()
    if #list == 0 then
        widgets.center(math.floor((yTop + yBot) / 2), "No recipes. Go to Recipes tab.", colors.red)
        return
    end
    if st.mode == "list" then
        -- Список рецептов
        local items = {}
        for _, r in ipairs(list) do
            local name = self.deps.lang.display(r.id, r.name)
            local have = self.deps.storage:count(r.id)
            local type = r.type == "machine" and " [M]" or ""
            local tStr = ""
            if r.avgTime then
                tStr = string.format(" ~%.0fs", r.avgTime * (r.crafts or 1))
            end
            table.insert(items, string.format("%-22s x%-3d%s have:%d%s", name:sub(1, 22), r.output or 1, type, have, tStr))
        end
        local h = yBot - yTop + 1
        widgets.list(1, yTop, w, h, items, st.scroll, st.selected)
        -- Кнопки прокрутки
        self:button(w - 4, yTop, 4, " Up ", false, function() st.scroll = math.max(0, st.scroll - (h - 2)) end)
        self:button(w - 4, yBot, 4, " Down ", false, function()
            if st.scroll + h < #items then st.scroll = st.scroll + (h - 2) end
        end)
    elseif st.mode == "quantity" then
        local r = list[st.selected]
        if not r then st.mode = "list"; return end
        
        -- Draw dialog box
        term.setTextColor(colors.cyan)
        widgets.box(2, yTop, w - 2, yBot - yTop + 1, "Craft Order", "double")
        
        local name = self.deps.lang.display(r.id, r.name)
        local inStore = self.deps.storage:count(r.id)
        local qty = tonumber(st.qty) or 1
        
        local showNumpad = (w >= 32)
        local numpadX = w - 13
        local leftW = showNumpad and (numpadX - 4) or (w - 6)
        
        -- Left side info
        widgets.text(4, yTop + 1, "Item: " .. name:sub(1, leftW), colors.white, colors.black)
        widgets.text(4, yTop + 2, string.format("Have: %d  Out: %d", inStore, r.output or 1):sub(1, leftW), colors.lightGray, colors.black)
        widgets.text(4, yTop + 3, ("Qty: " .. st.qty):sub(1, leftW), colors.yellow, colors.black)
        
        -- Numpad on the right
        if showNumpad then
            local keys_num = {
                {"1", "2", "3"},
                {"4", "5", "6"},
                {"7", "8", "9"},
                {"<-", "0", "C"}
            }
            for rowIdx, rKeys in ipairs(keys_num) do
                local ry = yTop + rowIdx
                for colIdx, k in ipairs(rKeys) do
                    local rx = numpadX + (colIdx - 1) * 4
                    local btnW = 3
                    self:button(rx, ry, btnW, k, false, function()
                        if k == "<-" then
                            st.qty = st.qty:sub(1, -2)
                            if st.qty == "" then st.qty = "1" end
                        elseif k == "C" then
                            st.qty = "1"
                        else
                            if st.qty == "0" or (st.qty == "1" and #st.qty == 1) then
                                st.qty = k
                            else
                                st.qty = st.qty .. k
                            end
                        end
                    end)
                end
            end
        end
        
        -- BOM & Timing Details on the left (if detailed layout)
        if h >= 14 then
            if qty > 0 then
                local tree = planner.buildTree(r.id, qty, recipes, self.deps.storage)
                local bom = planner.calculateBOM(tree)
                local estTime, approx = planner.estimateTime(tree, self:workersCount(), self.deps.recipes)
                widgets.text(4, yTop + 4, ("ETA: " .. planner.formatDuration(estTime, approx)):sub(1, leftW), approx and colors.yellow or colors.green, colors.black)
                
                -- Draw BOM list if we have height
                local y = yTop + 6
                if h >= 16 then
                    widgets.text(4, y, "Requires:", colors.cyan, colors.black)
                    y = y + 1
                    local itemW = leftW - 10
                    if itemW >= 4 then
                        for _, info in ipairs(bom) do
                            if y < yBot - 3 then
                                local have = self.deps.storage:count(info.id)
                                local col = have >= info.count and colors.green or colors.red
                                widgets.text(4, y, string.format("  %-" .. itemW .. "s %d/%d", 
                                    self.deps.lang.display(info.id):sub(1, itemW), have, info.count):sub(1, leftW), col, colors.black)
                                y = y + 1
                            end
                        end
                    end
                end
            end
        end
        
        -- Incremental Adjustment Buttons
        local btnY = yTop + 5
        if not showNumpad then
            if btnY < yBot - 1 then
                self:button(4, btnY, 5, "-10", false, function() st.qty = tostring(math.max(1, qty - 10)) end)
                self:button(10, btnY, 4, "-1", false, function() st.qty = tostring(math.max(1, qty - 1)) end)
                self:button(15, btnY, 4, "+1", false, function() st.qty = tostring(qty + 1) end)
                self:button(20, btnY, 5, "+10", false, function() st.qty = tostring(qty + 10) end)
                self:button(4, btnY + 1, 6, "+64", false, function() st.qty = tostring(qty + 64) end)
                self:button(11, btnY + 1, 6, "Reset", false, function() st.qty = "1" end)
            else
                self:button(4, yTop + 4, 4, "-1", false, function() st.qty = tostring(math.max(1, qty - 1)) end)
                self:button(9, yTop + 4, 4, "+1", false, function() st.qty = tostring(qty + 1) end)
            end
        else
            if h >= 14 and btnY < yBot - 1 then
                self:button(4, yBot - 3, 5, "+1", false, function() st.qty = tostring(qty + 1) end)
                self:button(10, yBot - 3, 5, "+10", false, function() st.qty = tostring(qty + 10) end)
                self:button(16, yBot - 3, 5, "+64", false, function() st.qty = tostring(qty + 64) end)
            end
        end
        
        -- OK / Cancel (yBot - 1)
        local okW = math.min(10, math.floor((w - 6) / 2))
        local okX = 4
        local cancelX = w - okW - 2
        
        self:button(okX, yBot - 1, okW, "OK", true, function()
            local n = tonumber(st.qty) or 0
            if n > 0 then
                local tree = planner.buildTree(r.id, n, recipes, self.deps.storage)
                local estTime, approx = planner.estimateTime(tree, self:workersCount(), self.deps.recipes)
                local ids, err = self.deps.dispatcher:requestCraft(r.id, n, recipes)
                if ids then
                    self:addLog("Order: " .. name .. " x" .. n .. " (" .. #ids .. " steps)")
                    self.state.craft.active = {
                        total = #ids, done = 0, failed = 0,
                        etaTotal = estTime, started = os.epoch("utc"),
                    }
                else
                    self:addLog("Error: " .. tostring(err))
                end
            end
            st.mode = "list"; st.qty = "1"
        end, { bgActive = colors.green })
        
        self:button(cancelX, yBot - 1, okW, "Cancel", false, function()
            st.mode = "list"; st.qty = "1"
        end, { bg = colors.red })
    end
end

----------------------------------------------------------------
-- Вкладка ХРАНИЛИЩЕ
----------------------------------------------------------------
function ui:drawKeyboard(x, y)
    local keys_row1 = {"q", "w", "e", "r", "t", "y", "u", "i", "o", "p"}
    local keys_row2 = {"a", "s", "d", "f", "g", "h", "j", "k", "l", "_"}
    local keys_row3 = {"z", "x", "c", "v", "b", "n", "m", "-", ".", "<-"}
    
    local startX = x
    local btnW = 2
    local st = self.state.storage
    
    -- Draw row 1
    for idx, k in ipairs(keys_row1) do
        local bx = startX + (idx - 1) * 3
        self:button(bx, y, btnW, k, false, function()
            st.search = st.search .. k
            st.scroll = 0
            st.selected = 1
        end)
    end
    
    -- Draw row 2
    for idx, k in ipairs(keys_row2) do
        local bx = startX + (idx - 1) * 3
        local action = function()
            if k == "_" then
                st.search = st.search .. " "
            else
                st.search = st.search .. k
            end
            st.scroll = 0
            st.selected = 1
        end
        local label = (k == "_") and "sp" or k
        self:button(bx, y + 1, btnW, label, false, action)
    end
    
    -- Draw row 3
    for idx, k in ipairs(keys_row3) do
        local bx = startX + (idx - 1) * 3
        local action = function()
            if k == "<-" then
                st.search = st.search:sub(1, -2)
            else
                st.search = st.search .. k
            end
            st.scroll = 0
            st.selected = 1
        end
        self:button(bx, y + 2, btnW, k, false, action)
    end
    
    -- Draw row 4: Clear and Hide
    self:button(startX, y + 3, 8, " Clear ", false, function()
        st.search = ""
        st.scroll = 0
        st.selected = 1
    end, { bg = colors.red })
    
    self:button(startX + 10, y + 3, 8, " Hide ", false, function()
        st.showKeyboard = false
    end, { bg = colors.green })
end

function ui:renderStorage(yTop, yBot, w)
    local st = self.state.storage
    local items = self.deps.storage:items()
    
    -- Keyboard toggle and Clear buttons
    if w >= 39 then
        self:button(w - 21, yTop, 8, "Keyboard", st.showKeyboard, function()
            st.showKeyboard = not st.showKeyboard
        end)
        self:button(w - 12, yTop, 8, " Clear ", false, function()
            st.search = ""
            st.scroll = 0
            st.selected = 1
        end, { bg = colors.red })
    else
        self:button(w - 15, yTop, 7, "Keybrd", st.showKeyboard, function()
            st.showKeyboard = not st.showKeyboard
        end)
        self:button(w - 7, yTop, 6, "Clear", false, function()
            st.search = ""
            st.scroll = 0
            st.selected = 1
        end, { bg = colors.red })
    end

    -- Draw search bar
    widgets.text(1, yTop, "Search: " .. st.search .. "_", colors.yellow)
    local search = st.search:lower()
    
    -- Filter
    local filtered = {}
    for _, it in ipairs(items) do
        local name = self.deps.lang.display(it.id):lower()
        if search == "" or name:find(search, 1, true) or it.id:lower():find(search, 1, true) then
            table.insert(filtered, it)
        end
    end
    
    -- Height calculation (list height is reduced if virtual keyboard is open)
    local listH = yBot - yTop
    local listBot = yBot
    if st.showKeyboard then
        listH = yBot - yTop - 4
        listBot = yBot - 4
    end
    
    local rows = {}
    for _, it in ipairs(filtered) do
        local name = self.deps.lang.display(it.id)
        table.insert(rows, string.format("%-26s x%d", name:sub(1, 26), it.count))
    end
    
    if #rows == 0 then
        widgets.clearArea(1, yTop + 1, w, listH)
        widgets.center(math.floor((yTop + listBot) / 2), "Nothing found", colors.gray)
        -- Still draw keyboard if needed
        if st.showKeyboard then
            self:drawKeyboard(math.max(2, math.floor((w - 29) / 2) + 1), yBot - 3)
        end
        return
    end
    
    widgets.list(1, yTop + 1, w, listH, rows, st.scroll, st.selected)
    
    self:button(w - 4, yTop + 1, 4, " Up ", false, function()
        st.scroll = math.max(0, st.scroll - (listH - 2))
    end)
    self:button(w - 4, listBot, 4, " Down ", false, function()
        if st.scroll + listH < #rows then
            st.scroll = st.scroll + (listH - 2)
        end
    end)
    
    if st.showKeyboard then
        self:drawKeyboard(math.max(2, math.floor((w - 29) / 2) + 1), yBot - 3)
    end
end

----------------------------------------------------------------
-- Вкладка МЕХАНИЗМЫ
----------------------------------------------------------------
function ui:renderMachines(yTop, yBot, w)
    local st = self.state.machines
    local mach = self.deps.machines
    local h = yBot - yTop + 1
    local rows = {}
    for _, name in ipairs(mach.names) do
        local info = mach:status(name)
        local busy = info.busy and "BUSY" or "FREE"
        local what = info.cooking and (" (" .. self.deps.lang.display(info.cooking) .. ")") or ""
        table.insert(rows, string.format("%-20s %-6s%s", name:sub(1, 20), busy, what))
    end
    widgets.list(1, yTop, w, h, rows, st.scroll, st.selected)
    self:button(2, yBot, 14, " Refresh ", false, function()
        -- пересканируем машины (статус обновится при следующем render)
    end)
end

----------------------------------------------------------------
-- Вкладка РЕЦЕПТЫ
----------------------------------------------------------------
function ui:renderRecipes(yTop, yBot, w)
    local st = self.state.recipes
    local recipes = self.deps.recipes
    local list = recipes:all()
    local h = yBot - yTop + 1
    
    if st.mode == "learn_select" then
        term.setTextColor(colors.cyan)
        local titles = {
            [1] = "1/3 Choose Mode",
            [2] = "2/3 Choose Grid Chest",
            [3] = (st.learnType == 2) and "3/3 Choose Machine" or "3/3 Choose Worker"
        }
        widgets.box(2, yTop, w - 2, yBot - yTop + 1, titles[st.wizardStep or 1], "double")
        
        local helpTexts = {
            [1] = "Select learning method:",
            [2] = "Select chest used as grid:",
            [3] = (st.learnType == 2) and "Select furnace machine:" or "Select worker turtle:"
        }
        widgets.text(3, yTop + 1, helpTexts[st.wizardStep or 1], colors.lightGray, colors.black)
        
        local rows = {}
        if st.wizardStep == 1 then
            rows = { "Read Chest (Static)", "Active Smelt (Machine)", "Active Craft (Turtle)" }
        elseif st.wizardStep == 2 then
            for _, name in ipairs(peripheral.getNames()) do
                local ok, p = pcall(peripheral.wrap, name)
                if ok and p and type(p.list) == "function" and type(p.size) == "function" then
                    local isMach = false
                    if self.deps.machines then
                        for _, mn in ipairs(self.deps.machines.names) do
                            if mn == name then isMach = true; break end
                        end
                    end
                    if not isMach then
                        table.insert(rows, name)
                    end
                end
            end
        elseif st.wizardStep == 3 then
            if st.learnType == 2 then
                if self.deps.machines then
                    for _, name in ipairs(self.deps.machines.names) do
                        table.insert(rows, name)
                    end
                end
            elseif st.learnType == 3 then
                if self.deps.dispatcher then
                    local wList = self.deps.dispatcher:workerList()
                    for _, workerInfo in ipairs(wList) do
                        table.insert(rows, "Worker #" .. workerInfo.id)
                    end
                end
            end
        end
        
        local listH = yBot - yTop + 1 - 4
        widgets.list(3, yTop + 2, w - 4, listH, rows, st.wizardScroll or 0, st.wizardSelected or 1)
        
        if #rows > listH then
            self:button(w - 7, yTop + 2, 4, "Up", false, function()
                st.wizardScroll = math.max(0, (st.wizardScroll or 0) - 1)
            end)
            self:button(w - 7, yBot - 2, 4, "Dn", false, function()
                if (st.wizardScroll or 0) + listH < #rows then
                    st.wizardScroll = (st.wizardScroll or 0) + 1
                end
            end)
        end
        
        local btnW = 8
        local startX = math.floor((w - (btnW * 3 + 2)) / 2) + 1
        
        if st.wizardStep > 1 then
            self:button(startX, yBot - 1, btnW, "Back", false, function()
                st.wizardStep = st.wizardStep - 1
                st.wizardSelected = 1
                st.wizardScroll = 0
            end, { bg = colors.gray })
        end
        
        self:button(startX + btnW + 1, yBot - 1, btnW, "Cancel", false, function()
            st.mode = "list"
        end, { bg = colors.red })
        
        local isLastStep = (st.wizardStep == 3) or (st.wizardStep == 2 and st.learnType == 1)
        local btnLabel = isLastStep and "Learn" or "Next"
        self:button(startX + (btnW + 1) * 2, yBot - 1, btnW, btnLabel, true, function()
            local selectedVal = rows[st.wizardSelected or 1]
            if not selectedVal and not isLastStep then return end
            
            if st.wizardStep == 1 then
                st.learnType = st.wizardSelected or 1
                st.wizardStep = 2
                st.wizardSelected = 1
                st.wizardScroll = 0
            elseif st.wizardStep == 2 then
                st.tempStorage = selectedVal
                if st.learnType == 1 then
                    local ok, recipe = recipes:learnFromStorage(selectedVal)
                    if ok then
                        self:addLog("Saved: " .. self.deps.lang.display(recipe.id))
                    else
                        self:addLog("Error: " .. tostring(recipe))
                    end
                    st.mode = "list"
                else
                    st.wizardStep = 3
                    st.wizardSelected = 1
                    st.wizardScroll = 0
                end
            elseif st.wizardStep == 3 then
                if st.learnType == 2 then
                    st.tempMachine = selectedVal
                    self:addLog("Processing smelting...")
                    local ok, recipe = recipes:activeLearnMachine(st.tempStorage, selectedVal)
                    if ok then
                        self:addLog("Smelt Saved: " .. self.deps.lang.display(recipe.id))
                    else
                        self:addLog("Smelt Error: " .. tostring(recipe))
                    end
                elseif st.learnType == 3 then
                    local workerId = tonumber(selectedVal:match("#(%d+)"))
                    if workerId then
                        self:addLog("Executing craft on turtle...")
                        local ok, recipe = recipes:activeLearnCraft(st.tempStorage, workerId, self.deps.dispatcher)
                        if ok then
                            self:addLog("Craft Saved: " .. self.deps.lang.display(recipe.id))
                        else
                            self:addLog("Craft Error: " .. tostring(recipe))
                        end
                    else
                        self:addLog("Invalid worker selected")
                    end
                end
                st.mode = "list"
            end
        end, { bgActive = colors.green })
        return
    end

    local rows = {}
    for _, r in ipairs(list) do
        local name = self.deps.lang.display(r.id, r.name)
        local type = r.type == "machine" and "M" or (r.type == "shaped" and "S" or "L")
        table.insert(rows, string.format("[%s] %-24s x%d", type, name:sub(1, 24), r.output or 1))
    end
    if #rows == 0 then
        widgets.center(yTop + 1, "No recipes", colors.gray)
    else
        widgets.list(1, yTop, w, h - 2, rows, st.scroll, st.selected)
    end
    -- Кнопки внизу
    self:button(2, yBot - 1, 16, " + Learn ", false, function()
        st.mode = "learn_select"
        st.wizardStep = 1
        st.learnType = 1
        st.tempStorage = nil
        st.tempMachine = nil
        st.tempWorker = nil
        st.wizardScroll = 0
        st.wizardSelected = 1
    end, { bgActive = colors.green })
    self:button(20, yBot - 1, 14, " - Delete ", false, function()
        if list[st.selected] then
            recipes:remove(list[st.selected].id)
            self:addLog("Deleted recipe: " .. self.deps.lang.display(list[st.selected].id))
        end
    end, { bg = colors.red })
end

----------------------------------------------------------------
-- Вкладка ЛОГ
----------------------------------------------------------------
function ui:renderLog(yTop, yBot, w)
    local st = self.state.log
    local h = yBot - yTop + 1
    local rows = {}
    -- последние снизу
    for i = #self.log, 1, -1 do
        table.insert(rows, self.log[i].time .. " " .. self.log[i].msg)
    end
    if #rows == 0 then
        widgets.center(math.floor((yTop + yBot) / 2), "Log is empty", colors.gray)
        return
    end
    widgets.list(1, yTop, w, h, rows, st.scroll, nil)
    self:button(w - 4, yTop, 4, " Up ", false, function() st.scroll = math.max(0, st.scroll - (h - 2)) end)
    self:button(w - 4, yBot, 4, " Down ", false, function()
        if st.scroll + h < #rows then st.scroll = st.scroll + (h - 2) end
    end)
end

----------------------------------------------------------------
-- Обработка событий
----------------------------------------------------------------
--- Обработать тач по монитору.
function ui:handleTouch(side, x, y)
    -- Тап по вкладкам (строка 2)
    if y == 2 then
        for _, b in ipairs(self.tabBounds) do
            if widgets.hit(b, x, y) then
                self:switchTab(b.id)
                return
            end
        end
        return
    end
    -- Тап по кнопкам текущего экрана
    for _, b in ipairs(self.buttons) do
        if widgets.hit(b.rect, x, y) then
            if b.action then b.action() end
            return
        end
    end
    -- Тап по списку (выбор элемента)
    self:handleListTouch(x, y)
end

--- Обработать тап внутри списка (выбор элемента).
function ui:handleListTouch(x, y)
    local w, _ = self.monitor.getSize()
    -- не обрабатываем тапы по кнопкам прокрутки (правый край)
    if x > w - 5 then return end
    local tab = self.activeTab
    local st = self.state[tab]
    if not st then return end
    if tab == "recipes" and st.mode == "learn_select" then
        local yTop = 4
        local yListTop = yTop + 2
        local idx = y - yListTop + 1 + (st.wizardScroll or 0)
        local rows = {}
        if st.wizardStep == 1 then
            rows = { "Read Chest (Static)", "Active Smelt (Machine)", "Active Craft (Turtle)" }
        elseif st.wizardStep == 2 then
            for _, name in ipairs(peripheral.getNames()) do
                local ok, p = pcall(peripheral.wrap, name)
                if ok and p and type(p.list) == "function" and type(p.size) == "function" then
                    local isMach = false
                    if self.deps.machines then
                        for _, mn in ipairs(self.deps.machines.names) do
                            if mn == name then isMach = true; break end
                        end
                    end
                    if not isMach then table.insert(rows, name) end
                end
            end
        elseif st.wizardStep == 3 then
            if st.learnType == 2 then
                if self.deps.machines then
                    for _, name in ipairs(self.deps.machines.names) do
                        table.insert(rows, name)
                    end
                end
            elseif st.learnType == 3 then
                if self.deps.dispatcher then
                    local wList = self.deps.dispatcher:workerList()
                    for _, workerInfo in ipairs(wList) do
                        table.insert(rows, "Worker #" .. workerInfo.id)
                    end
                end
            end
        end
        if rows[idx] then
            st.wizardSelected = idx
        end
        return
    end
    if not st.selected then return end
    local yTop = 4
    local idx = y - yTop + 1 + (st.scroll or 0)
    local list
    if tab == "craft" and self.state.craft.mode == "list" then
        list = self.deps.recipes:all()
        if list[idx] then
            st.selected = idx
            self.state.craft.mode = "quantity"
            self.state.craft.qty = "1"
        end
    elseif tab == "storage" then
        list = self.deps.storage:items()
        if list[idx] then st.selected = idx end
    elseif tab == "machines" then
        list = self.deps.machines.names
        if list[idx] then st.selected = idx end
    elseif tab == "recipes" then
        list = self.deps.recipes:all()
        if list[idx] then st.selected = idx end
    end
end

--- Обработать ввод символа (на компьютере с клавиатурой).
-- Используется для ввода количества в режиме заказа и поиска в хранилище.
function ui:handleChar(ch)
    local tab = self.activeTab
    if tab == "craft" and self.state.craft.mode == "quantity" then
        local st = self.state.craft
        if ch:match("%d") then
            -- цифра: дописать к количеству (если текущее "0" — заменить)
            if st.qty == "0" then st.qty = ch else st.qty = st.qty .. ch end
        elseif ch == "\b" or ch == "\8" then
            -- backspace
            st.qty = st.qty:sub(1, -2)
            if st.qty == "" then st.qty = "0" end
        end
    elseif tab == "storage" then
        local st = self.state.storage
        if ch == "\b" or ch == "\8" then
            st.search = st.search:sub(1, -2)
        elseif ch:match("%S") then
            st.search = st.search .. ch
        end
        st.scroll = 0
        st.selected = 1
    end
end

--- Обработать событие клавиатуры (на компьютере).
function ui:handleKey(key)
    if key == keys.q then
        os.queueEvent("shellcraft_quit")
    elseif key == keys.up then
        self:moveSelection(-1)
    elseif key == keys.down then
        self:moveSelection(1)
    elseif key == keys.left then
        self:moveTab(-1)
    elseif key == keys.right then
        self:moveTab(1)
    end
end

function ui:moveSelection(delta)
    local st = self.state[self.activeTab]
    if not st then return end
    if self.activeTab == "recipes" and st.mode == "learn_select" then
        local rowsCount = 0
        if st.wizardStep == 1 then
            rowsCount = 3
        elseif st.wizardStep == 2 then
            for _, name in ipairs(peripheral.getNames()) do
                local ok, p = pcall(peripheral.wrap, name)
                if ok and p and type(p.list) == "function" and type(p.size) == "function" then
                    local isMach = false
                    if self.deps.machines then
                        for _, mn in ipairs(self.deps.machines.names) do
                            if mn == name then isMach = true; break end
                        end
                    end
                    if not isMach then rowsCount = rowsCount + 1 end
                end
            end
        elseif st.wizardStep == 3 then
            if st.learnType == 2 then
                rowsCount = self.deps.machines and self.deps.machines:count() or 0
            elseif st.learnType == 3 then
                if self.deps.dispatcher then
                    local wList = self.deps.dispatcher:workerList()
                    rowsCount = #wList
                end
            end
        end
        st.wizardSelected = util.clamp((st.wizardSelected or 1) + delta, 1, math.max(1, rowsCount))
        return
    end
    if not st.selected then return end
    local list
    if self.activeTab == "craft" then list = self.deps.recipes:all()
    elseif self.activeTab == "storage" then list = self.deps.storage:items()
    elseif self.activeTab == "recipes" then list = self.deps.recipes:all()
    else return end
    st.selected = util.clamp(st.selected + delta, 1, math.max(1, #list))
end

function ui:moveTab(delta)
    local idx = 1
    for i, t in ipairs(self.tabs) do
        if t.id == self.activeTab then idx = i; break end
    end
    idx = util.clamp(idx + delta, 1, #self.tabs)
    self:switchTab(self.tabs[idx].id)
end

return ui
