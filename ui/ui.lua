-- ui/ui.lua
-- Главный UI ShellCraft: вкладки на мониторе, тач-управление.
-- Вся отрисовка идет через буфер (window API), а хит-тест через self.hits = {}.
-- Весь текст выводится на английском языке.

local ui = {}
ui.__index = ui

--- Создать UI.
function ui.new(monitor, deps)
    local self = setmetatable({}, ui)
    self.monitor = monitor
    self.deps = deps
    self.activeTab = "craft"
    self.tabs = {}
    self.hits = {}
    self.dirty = true
    self.configData = config.load()
    self.settingsLoaded = false
    
    self.state = {
        craft    = { scroll = 0, selected = 1, mode = "list", qty = "1", active = nil },
        active   = { scroll = 0, selected = 1 },
        storage  = { scroll = 0, selected = 1, search = "", showKeyboard = false, tab = "items", mode = "list" },
        machines = { scroll = 0, selected = 1, recordMode = false, recordStage = "idle" },
        recipes  = { scroll = 0, selected = 1, mode = "list", wizardStep = 1, learnType = 1, wizardScroll = 0, wizardSelected = 1 },
        log      = { scroll = 0 },
        settings = { scroll = 0, selected = 1 },
        tabScrollState = { scroll = 1 },
    }
    self.log = {}
    self.toast = nil
    
    return self
end

--- Добавить запись в лог UI.
function ui:addLog(msg)
    table.insert(self.log, { time = util.now(), msg = tostring(msg) })
    if #self.log > 200 then table.remove(self.log, 1) end
    self.dirty = true
end

--- Шаг крафта завершён успешно.
function ui:taskDone()
    local a = self.state.craft.active
    if a then a.done = (a.done or 0) + 1 end
    self.dirty = true
end

--- Шаг крафта завершён с ошибкой.
function ui:taskFailed(err)
    local a = self.state.craft.active
    if a then a.failed = (a.failed or 0) + 1 end
    self.dirty = true
    if err then
        self:showToast("Craft failed: " .. tostring(err), "danger")
    end
end

--- Шаг крафта начат на воркере.
function ui:taskStarted(recipeName, workerId)
    self.dirty = true
    self:showToast("Crafting " .. tostring(recipeName) .. " on turtle #" .. tostring(workerId), "info")
end

--- Шаг крафта истёк по таймауту.
function ui:taskTimedOut(reason, workerId)
    self.dirty = true
    local msg = "Task timeout on turtle #" .. tostring(workerId)
    if reason == "worker_dead" then
        msg = "Worker #" .. tostring(workerId) .. " not responding - task returned to queue"
    elseif reason == "task_deadline" then
        msg = "Task on turtle #" .. tostring(workerId) .. " exceeded deadline - returned to queue"
    end
    self:showToast(msg, "danger")
end

--- Показать всплывающее Toast сообщение.
function ui:showToast(msg, kind)
    self.toast = {
        msg = msg,
        kind = kind or "info",
        expires = os.clock() + 3
    }
    self.dirty = true
end

--- Число доступных исполнителей.
function ui:workersCount()
    local n = 1
    if self.deps.dispatcher then n = math.max(1, self.deps.dispatcher:workerCount()) end
    if self.deps.machines then n = n + self.deps.machines:count() end
    return n
end

--- Сгенерировать список вкладок.
function ui:buildTabs()
    self.tabs = {
        { id = "craft",   title = "Craft" },
        { id = "active",  title = "Active" },
        { id = "storage", title = "Storage" },
    }
    if self.deps.machines and self.deps.machines:count() > 0 then
        table.insert(self.tabs, { id = "machines", title = "Machines" })
    end
    table.insert(self.tabs, { id = "recipes", title = "Recipes" })
    table.insert(self.tabs, { id = "log",     title = "Log" })
    table.insert(self.tabs, { id = "settings", title = "Settings" })
end

--- Переключиться на вкладку.
function ui:switchTab(id)
    for _, t in ipairs(self.tabs) do
        if t.id == id then
            self.activeTab = id
            self.dirty = true
            return true
        end
    end
    return false
end

--- Зарегистрировать хит-зону.
function ui:addHit(x, y, w, h, action)
    if not action then return end
    table.insert(self.hits, { x = x, y = y, w = w, h = h, action = action })
end

--- Главная функция отрисовки кадра с двойной буферизацией.
function ui:render()
    local parent = self.monitor or term.current()
    local w, h = parent.getSize()
    
    -- Инициализация / изменение размеров буфера
    if not self.win or self.winWidth ~= w or self.winHeight ~= h then
        self.win = window.create(parent, 1, 1, w, h, false)
        self.winWidth = w
        self.winHeight = h
    end
    
    -- Перенаправляем вывод в буфер
    local old = term.redirect(self.win)
    self.hits = {} -- очищаем хит-цели для нового кадра
    
    local minW, minH = 29, 12
    if w < minW or h < minH then
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.red)
        term.clear()
        widgets.center(math.floor(h / 2), "Enlarge monitor: need >= 3x2 blocks", colors.red)
        widgets.button(self, math.floor((w - 8) / 2) + 1, math.floor(h / 2) + 2, 8, "Exit", { kind = "danger" }, function()
            os.queueEvent("shellcraft_quit")
        end)
    else
        self:drawFrame(w, h)
    end
    
    -- Выводим буфер разом
    self.win.setVisible(true)
    term.redirect(old)
end

--- Отрисовка элементов интерфейса.
function ui:drawFrame(w, h)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    
    -- 1. Шапка (Header)
    term.setBackgroundColor(colors.gray)
    term.setCursorPos(1, 1)
    term.write(string.rep(" ", w))
    
    term.setTextColor(colors.yellow)
    term.setCursorPos(2, 1)
    term.write("ShellCraft")
    
    local status = ""
    if self.deps.dispatcher then
        local free = self.deps.dispatcher:freeCount()
        local total = 0
        for _ in pairs(self.deps.dispatcher.workers) do total = total + 1 end
        local active = #self.deps.dispatcher:activeTasks()
        status = string.format("Workers: %d/%d [Act:%d]", total - free, total, active)
    end
    term.setTextColor(colors.white)
    term.setCursorPos(math.max(12, w - #status - 5), 1)
    term.write(status)
    
    -- Кнопка выхода [X]
    widgets.button(self, w - 2, 1, 3, "X", { bg = colors.red, fg = colors.white }, function()
        os.queueEvent("shellcraft_quit")
    end)
    
    -- 2. Лента вкладок (Tabs)
    self:buildTabs()
    widgets.tabs(self, 2, self.tabs, self.activeTab, self.state.tabScrollState, function(tabId)
        self:switchTab(tabId)
    end)
    
    -- Разделительная линия
    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.gray)
    term.write(string.rep("-", w))
    
    -- Перезагрузка конфига при входе в Settings
    if self.activeTab == "settings" then
        if not self.settingsLoaded then
            self.configData = config.load()
            self.settingsLoaded = true
        end
    else
        self.settingsLoaded = false
    end
    
    -- 3. Отрисовка контента активной вкладки
    local bodyY = 4
    local yBot = h - 1
    local footerY = h
    
    local tab = self.activeTab
    if tab == "craft" then
        self:renderCraft(bodyY, yBot, w)
    elseif tab == "active" then
        self:renderActive(bodyY, yBot, w)
    elseif tab == "storage" then
        self:renderStorage(bodyY, yBot, w)
    elseif tab == "machines" then
        self:renderMachines(bodyY, yBot, w)
    elseif tab == "recipes" then
        self:renderRecipes(bodyY, yBot, w)
    elseif tab == "log" then
        self:renderLog(bodyY, yBot, w)
    elseif tab == "settings" then
        self:renderSettings(bodyY, yBot, w)
    end
    
    -- 4. Подвал (Footer)
    term.setBackgroundColor(colors.black)
    term.setCursorPos(1, footerY)
    term.clearLine()
    
    local a = self.state.craft.active
    if a and (a.done + a.failed) < a.total then
        local completed = a.done + a.failed
        local pct = a.total > 0 and math.floor(completed / a.total * 100) or 0
        local now = os.epoch("utc")
        local elapsed = (now - (a.started or now)) / 1000
        local eta = (completed > 0) and ((elapsed / completed) * (a.total - completed)) or (a.etaTotal or 0)
        
        local etaStr = planner.formatDuration(eta)
        local rightLen = #etaStr + 10
        local barLen = math.max(6, w - rightLen)
        
        widgets.progress(1, footerY, barLen, completed, a.total)
        term.setTextColor(colors.lightGray)
        term.setBackgroundColor(colors.black)
        term.write(string.format(" %3d%% ETA %s", pct, etaStr))
    else
        if a and (a.done + a.failed) >= a.total then
            self.state.craft.active = nil
        end
        term.setTextColor(colors.lightGray)
        term.setBackgroundColor(colors.black)
        term.write(self:footerHint())
    end
    
    -- 5. Toast Overlay (перекрывает подвал)
    if self.toast and os.clock() < self.toast.expires then
        local bg = colors.blue
        local fg = colors.white
        if self.toast.kind == "ok" or self.toast.kind == "success" then
            bg = colors.green
        elseif self.toast.kind == "err" or self.toast.kind == "error" or self.toast.kind == "danger" then
            bg = colors.red
        end
        term.setBackgroundColor(bg)
        term.setTextColor(fg)
        term.setCursorPos(1, footerY)
        term.clearLine()
        
        local msg = " " .. self.toast.msg
        if #msg > w then msg = msg:sub(1, w) end
        term.write(msg .. string.rep(" ", w - #msg))
        
        -- Клик по Toast скрывает его
        self:addHit(1, footerY, w, 1, function()
            self.toast = nil
        end)
    end
end

--- Английские подсказки в подвале.
function ui:footerHint()
    local tab = self.activeTab
    if tab == "craft" then
        return "Tap recipe to order. X - Exit."
    elseif tab == "active" then
        return "Tap task to select. Cancel to abort."
    elseif tab == "storage" then
        return "Scroll list. Toggle Keyboard to search."
    elseif tab == "machines" then
        return "List of connected machines. Tap Refresh."
    elseif tab == "recipes" then
        return "Manage recipes. Tap Record to auto-learn."
    elseif tab == "log" then
        return "Scroll through system event log."
    elseif tab == "settings" then
        return "Select default crafting grid chest."
    end
    return ""
end

----------------------------------------------------------------
-- Вкладка КРАФТ (Craft)
----------------------------------------------------------------
function ui:renderCraft(yTop, yBot, w)
    local st = self.state.craft
    local recipes = self.deps.recipes
    local list = recipes:all()
    local h = yBot - yTop + 1
    
    if #list == 0 then
        widgets.center(math.floor((yTop + yBot) / 2), "No recipes found. Go to Recipes tab.", colors.red)
        return
    end
    
    -- 1. Сбор категорий по префиксу ID (modID)
    local categories = { "All" }
    local catSet = {}
    for _, r in ipairs(list) do
        local mod = r.id:match("^([^:]+):") or "minecraft"
        if not catSet[mod] then
            catSet[mod] = true
            table.insert(categories, mod)
        end
    end
    table.sort(categories, function(a, b)
        if a == "All" then return true end
        if b == "All" then return false end
        return a < b
    end)
    
    local catIdx = st.categoryIdx or 1
    if catIdx > #categories then catIdx = 1 end
    st.categoryIdx = catIdx
    local currentCat = categories[catIdx]
    
    -- Отрисовка строки категорий
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, yTop)
    term.clearLine()
    
    term.setCursorPos(2, yTop)
    term.write("<")
    self:addHit(1, yTop, 3, 1, function()
        st.categoryIdx = st.categoryIdx - 1
        if st.categoryIdx < 1 then st.categoryIdx = #categories end
        st.selected = 1
        st.scroll = 0
        self.dirty = true
    end)
    
    term.setCursorPos(w - 1, yTop)
    term.write(">")
    self:addHit(w - 2, yTop, 3, 1, function()
        st.categoryIdx = st.categoryIdx + 1
        if st.categoryIdx > #categories then st.categoryIdx = 1 end
        st.selected = 1
        st.scroll = 0
        self.dirty = true
    end)
    
    local catLabel = "[" .. currentCat .. "]"
    local labelX = math.floor((w - #catLabel) / 2) + 1
    if labelX < 4 then labelX = 4 end
    term.setCursorPos(labelX, yTop)
    term.write(widgets.clip(catLabel, w - 8))
    
    -- 2. Фильтрация списка рецептов
    local filteredList = {}
    for _, r in ipairs(list) do
        local mod = r.id:match("^([^:]+):") or "minecraft"
        if currentCat == "All" or mod == currentCat then
            table.insert(filteredList, r)
        end
    end
    
    local listY = yTop + 1
    local listH = h - 1
    
    if #filteredList == 0 then
        widgets.center(math.floor((listY + yBot) / 2), "No recipes in this category", colors.red)
    else
        -- В режиме списка показываем ScrollList
        local items = {}
        for _, r in ipairs(filteredList) do
            local name = self.deps.lang.display(r.id, r.name)
            local have = self.deps.storage:count(r.id)
            local typeStr = r.type == "machine" and " [M]" or ""
            local tStr = r.avgTime and string.format(" ~%.0fs", r.avgTime) or ""
            table.insert(items, string.format("%s x%d%s (Have:%d)%s", name, r.output or 1, typeStr, have, tStr))
        end
        
        widgets.scrollList(self, 1, listY, w, listH, items, st, function(idx)
            st.selected = idx
            st.mode = "quantity"
            st.qty = "1"
        end)
    end
    
    -- Отрисовка модального диалога заказа крафта
    if st.mode == "quantity" then
        local r = filteredList[st.selected]
        if not r then st.mode = "list"; return end
        
        local name = self.deps.lang.display(r.id, r.name)
        local inStore = self.deps.storage:count(r.id)
        local qty = tonumber(st.qty) or 1
        
        -- Проверяем, влезает ли Numpad
        -- Для Numpad требуется 11 символов ширины и 4 строки высоты
        local showNumpad = (w >= 30 and h >= 10)
        
        local bodyFn = function(cx, cy, cw, ch)
            widgets.text(cx, cy, "Item: " .. widgets.clip(name, cw), colors.white, colors.black)
            widgets.text(cx, cy + 1, string.format("Have: %d  Output: %d", inStore, r.output or 1), colors.lightGray, colors.black)
            
            local crafts = math.ceil(qty / (r.output or 1))
            local actualQty = crafts * (r.output or 1)
            local qtyText = "Qty: " .. st.qty
            if actualQty ~= qty then
                qtyText = qtyText .. " (Yields: " .. actualQty .. ")"
            end
            widgets.text(cx, cy + 2, qtyText, colors.yellow, colors.black)
            
            -- Вычисляем ETA и BOM
            if qty > 0 then
                local tree = planner.buildTree(r.id, qty, recipes, self.deps.storage, self.deps.fluids)
                local bom = planner.calculateBOM(tree)
                local estTime, approx = planner.estimateTime(tree, self:workersCount(), recipes)
                widgets.text(cx, cy + 3, "ETA: " .. planner.formatDuration(estTime, approx), approx and colors.yellow or colors.green, colors.black)
                
                -- Вывод BOM требований если есть место по высоте
                if ch >= 7 then
                    widgets.text(cx, cy + 4, "Requires:", colors.cyan, colors.black)
                    local yLine = cy + 5
                    -- Items
                    for _, info in ipairs(bom.items) do
                        if yLine <= cy + ch - 1 then
                            local have = self.deps.storage:count(info.id)
                            local col = have >= info.count and colors.green or colors.red
                            widgets.text(cx, yLine, string.format(" %s %d/%d", widgets.clip(self.deps.lang.display(info.id), cw - 10), have, info.count), col, colors.black)
                            yLine = yLine + 1
                        end
                    end
                    -- Fluids
                    for _, info in ipairs(bom.fluids) do
                        if yLine <= cy + ch - 1 then
                            local have = self.deps.fluids:count(info.fluid)
                            local col = have >= info.mb and colors.green or colors.red
                            widgets.text(cx, yLine, string.format(" %s %d/%d mB", widgets.clip(util.formatId(info.fluid), cw - 14), have, info.mb), col, colors.black)
                            yLine = yLine + 1
                        end
                    end
                end
            end
            
            -- Рисуем Numpad или Stepper
            if showNumpad then
                widgets.numpad(self, cx + cw - 11, cy, function(key)
                    if key == "<-" then
                        st.qty = st.qty:sub(1, -2)
                        if st.qty == "" then st.qty = "1" end
                    elseif key == "C" then
                        st.qty = "1"
                    else
                        if st.qty == "0" or st.qty == "1" then st.qty = key else st.qty = st.qty .. key end
                    end
                end)
                -- Также добавляем компактный Stepper внизу
                local step = r.output or 1
                widgets.stepper(self, cx, cy + 4, cw - 13, qty, function(delta)
                    st.qty = tostring(math.max(step, qty + delta * step))
                end)
            else
                -- Если Numpad не влезает, используем только Stepper на всю ширину
                local step = r.output or 1
                widgets.stepper(self, cx, cy + 4, cw, qty, function(delta)
                    st.qty = tostring(math.max(step, qty + delta * step))
                end)
            end
        end
        
        local buttons = {
            {
                label = "Craft",
                kind = "active",
                action = function()
                    local n = tonumber(st.qty) or 0
                    if n > 0 then
                        local ids, err = self.deps.dispatcher:requestCraft(r.id, n, recipes)
                        if ids then
                            self:showToast(string.format("Queued: %s x%d (%d steps)", widgets.clip(name, 12), n, #ids), "success")
                            self:addLog("Queued order: " .. name .. " x" .. n)
                            local tree = planner.buildTree(r.id, n, recipes, self.deps.storage, self.deps.fluids)
                            local estTime = planner.estimateTime(tree, self:workersCount(), recipes)
                            self.state.craft.active = {
                                total = #ids, done = 0, failed = 0,
                                etaTotal = estTime, started = os.epoch("utc"),
                            }
                            st.mode = "list"
                            st.qty = "1"
                        else
                            -- Toast об ошибке, но ДИАЛОГ ОСТАВЛЯЕМ ОТКРЫТЫМ!
                            self:showToast(tostring(err), "danger")
                            self:addLog("Order Error: " .. tostring(err))
                        end
                    else
                        st.mode = "list"
                    end
                end
            },
            {
                label = "Cancel",
                kind = "danger",
                action = function()
                    st.mode = "list"
                    st.qty = "1"
                end
            }
        }
        
        widgets.dialog(self, "Craft Order", bodyFn, buttons)
    end
end

----------------------------------------------------------------
-- Вкладка АКТИВНЫЕ (Active)
----------------------------------------------------------------
function ui:renderActive(yTop, yBot, w)
    local st = self.state.active
    local disp = self.deps.dispatcher
    local h = yBot - yTop + 1
    
    if not disp then
        widgets.center(math.floor((yTop + yBot) / 2), "Dispatcher not connected", colors.red)
        return
    end
    
    local list = disp:activeTasks()
    table.sort(list, function(a, b) return a.id < b.id end)
    
    if #list == 0 then
        widgets.center(math.floor((yTop + yBot) / 2), "No active crafts", colors.gray)
        return
    end
    
    local isSplit = (w >= 34)
    
    if isSplit then
        local wLeft = math.floor(w * 0.45)
        local startX = wLeft + 2
        local wRight = w - wLeft - 1
        
        -- Left column: List of active tasks
        local rows = {}
        for _, t in ipairs(list) do
            local name = self.deps.lang.display(t.recipe.id, t.recipe.name)
            local statusChar = t.status == "running" and "R" or "Q"
            table.insert(rows, string.format("[%s] %s x%d", statusChar, name, t.count))
        end
        
        widgets.scrollList(self, 1, yTop, wLeft, h, rows, st, function(idx)
            st.selected = idx
        end)
        
        -- Vertical separator
        term.setBackgroundColor(colors.black)
        for cy = yTop, yBot do
            term.setCursorPos(wLeft + 1, cy)
            term.setTextColor(colors.gray)
            term.write("|")
        end
        
        -- Right column: Selected task details
        widgets.clearArea(startX, yTop, wRight, h)
        
        local t = list[st.selected]
        if not t then
            st.selected = 1
            t = list[1]
        end
        
        if t then
            local name = self.deps.lang.display(t.recipe.id, t.recipe.name)
            widgets.text(startX, yTop, "Task: " .. widgets.clip(name, wRight - 6), colors.cyan, colors.black)
            widgets.text(startX, yTop + 1, "ID: " .. t.id, colors.lightGray, colors.black)
            widgets.text(startX, yTop + 2, "Count: " .. t.count, colors.white, colors.black)
            
            local statusStr = t.status == "running" and ("Running on #" .. tostring(t.worker_id)) or "Queued"
            local statusCol = t.status == "running" and colors.yellow or colors.lightGray
            widgets.text(startX, yTop + 3, "Status: " .. statusStr, statusCol, colors.black)
            
            widgets.text(startX, yTop + 4, "Attempts: " .. t.attempts .. "/" .. disp.maxAttempts, colors.lightGray, colors.black)
            
            if t.status == "running" and t.progress then
                widgets.text(startX, yTop + 5, "Progress: " .. t.progress .. "%", colors.green, colors.black)
            end
            
            -- Cancel button at the bottom of the right column
            widgets.button(self, startX, yBot, wRight, "Cancel Task", { kind = "danger" }, function()
                local ok, err = disp:cancelTask(t.id)
                if ok then
                    self:showToast("Task cancelled", "success")
                    st.selected = math.max(1, st.selected - 1)
                else
                    self:showToast(tostring(err), "danger")
                end
            end)
        end
    else
        -- Compact layout
        local rows = {}
        for _, t in ipairs(list) do
            local name = self.deps.lang.display(t.recipe.id, t.recipe.name)
            local statusStr = t.status == "running" and ("R:" .. tostring(t.worker_id)) or "Q"
            table.insert(rows, string.format("[%s] %s x%d", statusStr, name, t.count))
        end
        
        widgets.scrollList(self, 1, yTop, w, h - 2, rows, st, function(idx)
            st.selected = idx
        end)
        
        -- Cancel button at the bottom
        widgets.button(self, 1, yBot, w, "Cancel Selected", { kind = "danger" }, function()
            local t = list[st.selected]
            if t then
                local ok, err = disp:cancelTask(t.id)
                if ok then
                    self:showToast("Task cancelled", "success")
                    st.selected = math.max(1, st.selected - 1)
                else
                    self:showToast(tostring(err), "danger")
                end
            else
                self:showToast("No task selected", "danger")
            end
        end)
    end
end

----------------------------------------------------------------
-- Вкладка ХРАНИЛИЩЕ (Storage)
----------------------------------------------------------------
function ui:drawKeyboard(x, y)
    local rows = {
        {"q", "w", "e", "r", "t", "y", "u", "i", "o", "p"},
        {"a", "s", "d", "f", "g", "h", "j", "k", "l", "_"},
        {"z", "x", "c", "v", "b", "n", "m", "-", ".", "<-"}
    }
    
    local st = self.state.storage
    for rowIdx, keys in ipairs(rows) do
        local ry = y + rowIdx - 1
        for colIdx, k in ipairs(keys) do
            local rx = x + (colIdx - 1) * 3
            local kw = (k == "<-") and 3 or 2
            widgets.button(self, rx, ry, kw, k, { kind = "normal" }, function()
                if k == "<-" then
                    st.search = st.search:sub(1, -2)
                else
                    st.search = st.search .. k
                end
                st.scroll = 0
                st.selected = 1
            end)
        end
    end
end

function ui:assignDankDialog(periphName, currentFluid, currentTarget)
    local st = self.state.storage
    st.dankEditFluid = currentFluid or "minecraft:water"
    st.dankEditTarget = tostring(currentTarget or 16000)
    st.mode = "dank_edit"
    
    local bodyFn = function(cx, cy, cw, ch)
        widgets.text(cx, cy, "Dank: " .. periphName, colors.cyan, colors.black)
        widgets.text(cx, cy + 2, "Fluid: " .. st.dankEditFluid, colors.yellow, colors.black)
        widgets.text(cx, cy + 4, "Target (mB): " .. st.dankEditTarget, colors.yellow, colors.black)
        
        widgets.button(self, cx, cy + 6, 8, "Water", { kind = "normal" }, function() st.dankEditFluid = "minecraft:water" end)
        widgets.button(self, cx + 9, cy + 6, 7, "Lava", { kind = "normal" }, function() st.dankEditFluid = "minecraft:lava" end)
        
        local val = tonumber(st.dankEditTarget) or 16000
        widgets.stepper(self, cx, cy + 8, cw, val, function(delta)
            st.dankEditTarget = tostring(math.max(1000, val + delta * 1000))
        end)
    end
    
    local buttons = {
        {
            label = "Save",
            kind = "active",
            action = function()
                local t = tonumber(st.dankEditTarget) or 16000
                self.deps.fluids:assignDank(periphName, st.dankEditFluid, t)
                self:showToast("Assigned " .. periphName .. " -> " .. st.dankEditFluid, "success")
                st.mode = "list"
            end
        },
        {
            label = "Cancel",
            kind = "danger",
            action = function()
                st.mode = "list"
            end
        }
    end
    
    widgets.dialog(self, "Assign Dank", bodyFn, buttons)
end

function ui:renderStorageFluids(yTop, yBot, w)
    local st = self.state.storage
    local h = yBot - yTop + 1
    
    local wLeft = math.floor(w * 0.55)
    local startX = wLeft + 2
    local wRight = w - wLeft - 1
    
    widgets.text(1, yTop, "Danks:", colors.cyan, colors.black)
    
    local danksList = self.deps.fluids:dankInfo()
    local assignedSet = {}
    for _, dk in ipairs(danksList) do
        assignedSet[dk.periph] = true
    end
    local unassigned = {}
    for _, name in ipairs(peripheral.getNames()) do
        if not assignedSet[name] then
            local isItemStorage = false
            if self.deps.storage and self.deps.storage.names then
                for _, sn in ipairs(self.deps.storage.names) do
                    if sn == name then isItemStorage = true; break end
                end
            end
            local isMachine = false
            if self.deps.machines and self.deps.machines.names then
                for _, mn in ipairs(self.deps.machines.names) do
                    if mn == name then isMachine = true; break end
                end
            end
            local isPool = false
            if self.deps.fluids and self.deps.fluids.pool_names then
                for _, pn in ipairs(self.deps.fluids.pool_names) do
                    if pn == name then isPool = true; break end
                end
            end
            if not isItemStorage and not isMachine and not isPool then
                if peripheral.hasType(name, "fluid_storage") then
                    table.insert(unassigned, name)
                end
            end
        end
    end
    
    local leftRows = {}
    for _, dk in ipairs(danksList) do
        table.insert(leftRows, {
            type = "dank",
            name = dk.periph,
            fluid = dk.fluid,
            current = dk.current_mb,
            target = dk.target_mb,
            percent = dk.percent
        })
    end
    for _, name in ipairs(unassigned) do
        table.insert(leftRows, {
            type = "unassigned",
            name = name
        })
    end
    
    st.danksScroll = st.danksScroll or { scroll = 0, selected = 1 }
    local scrollState = st.danksScroll
    
    local listY = yTop + 1
    local listH = h - 2
    
    local maxVisible = math.floor(listH / 4)
    if maxVisible < 1 then maxVisible = 1 end
    local offset = scrollState.scroll or 0
    if offset < 0 then offset = 0 end
    
    term.setBackgroundColor(colors.black)
    widgets.clearArea(1, listY, wLeft, listH)
    
    local yCurr = listY
    for idx = offset + 1, math.min(#leftRows, offset + maxVisible) do
        local row = leftRows[idx]
        if yCurr + 3 > listY + listH then break end
        
        if row.type == "dank" then
            term.setCursorPos(1, yCurr)
            term.setTextColor(colors.white)
            term.write(widgets.clip(util.formatId(row.fluid) .. " (" .. row.name .. ")", wLeft))
            
            yCurr = yCurr + 1
            term.setCursorPos(1, yCurr)
            term.setTextColor(colors.lightGray)
            local barW = math.floor(wLeft * 0.35)
            if barW < 4 then barW = 4 end
            local filled = math.min(barW, math.floor(row.percent / 100 * barW))
            term.write("[")
            term.setTextColor(colors.blue)
            term.write(string.rep("=", filled) .. string.rep(" ", barW - filled))
            term.setTextColor(colors.lightGray)
            term.write(string.format("] %d%% (%d/%d)", row.percent, row.current, row.target))
            
            yCurr = yCurr + 1
            widgets.button(self, 1, yCurr, 6, "Edit", { kind = "normal" }, function()
                self:assignDankDialog(row.name, row.fluid, row.target)
            end)
            widgets.button(self, 8, yCurr, 7, "Clear", { kind = "danger" }, function()
                self.deps.fluids:clearDank(row.name)
                self:showToast("Cleared dank " .. row.name, "info")
            end)
            
            yCurr = yCurr + 2
        else
            term.setCursorPos(1, yCurr)
            term.setTextColor(colors.yellow)
            term.write(widgets.clip("Unassigned dank " .. row.name, wLeft))
            
            yCurr = yCurr + 1
            widgets.button(self, 1, yCurr, 8, "Assign", { kind = "active" }, function()
                self:assignDankDialog(row.name, nil, 16000)
            end)
            
            yCurr = yCurr + 2
        end
    end
    
    if #leftRows > 0 then
        if offset > 0 then
            widgets.button(self, wLeft - 1, listY, 2, "^", { kind = "normal" }, function()
                scrollState.scroll = math.max(0, offset - 1)
            end)
        end
        if offset + maxVisible < #leftRows then
            widgets.button(self, wLeft - 1, listY + listH - 1, 2, "v", { kind = "normal" }, function()
                scrollState.scroll = offset + 1
            end)
        end
    else
        widgets.text(2, listY + 2, "No tanks connected", colors.gray, colors.black)
    end
    
    term.setBackgroundColor(colors.black)
    for cy = yTop, yBot do
        term.setCursorPos(wLeft + 1, cy)
        term.setTextColor(colors.gray)
        term.write("|")
    end
    
    widgets.text(startX, yTop, "Pool:", colors.cyan, colors.black)
    
    local poolFluids = self.deps.fluids:fluids()
    local poolRows = {}
    for _, f in ipairs(poolFluids) do
        table.insert(poolRows, string.format("%s: %d mB", util.formatId(f.fluid), f.mb))
    end
    
    st.poolScroll = st.poolScroll or { scroll = 0, selected = 1 }
    widgets.clearArea(startX, yTop + 1, wRight, h - 1)
    if #poolRows == 0 then
        widgets.text(startX, yTop + 2, "Pool is empty", colors.gray, colors.black)
    else
        widgets.scrollList(self, startX, yTop + 1, wRight, h - 1, poolRows, st.poolScroll, function(idx) end)
    end
end

function ui:renderStorage(yTop, yBot, w)
    local st = self.state.storage
    local subTab = st.tab or "items"
    st.tab = subTab
    
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, yTop)
    term.clearLine()
    
    widgets.button(self, 1, yTop, 9, "Items", { selected = (subTab == "items") }, function()
        st.tab = "items"
        st.scroll = 0
        st.selected = 1
    end)
    widgets.button(self, 11, yTop, 10, "Fluids", { selected = (subTab == "fluids") }, function()
        st.tab = "fluids"
        st.scroll = 0
        st.selected = 1
    end)
    
    if subTab == "fluids" then
        self:renderStorageFluids(yTop + 1, yBot, w)
    else
        local listY = yTop + 1
        local listH = yBot - listY + 1
        
        local keyLabel = (w >= 39) and "Keyboard" or "Keybrd"
        local clearLabel = "Clear"
        local w1 = #keyLabel + 2
        local w2 = #clearLabel + 2
        
        widgets.button(self, w - w1 - w2 - 2, listY, w1, keyLabel, { selected = st.showKeyboard }, function()
            st.showKeyboard = not st.showKeyboard
        end)
        widgets.button(self, w - w2 - 1, listY, w2, clearLabel, { kind = "danger" }, function()
            st.search = ""
            st.scroll = 0
            st.selected = 1
        end)
        
        widgets.text(1, listY, "Search: " .. st.search .. "_", colors.yellow, colors.black)
        local search = st.search:lower()
        
        local items = self.deps.storage:items()
        local filtered = {}
        for _, it in ipairs(items) do
            local name = self.deps.lang.display(it.id):lower()
            if search == "" or name:find(search, 1, true) or it.id:lower():find(search, 1, true) then
                table.insert(filtered, it)
            end
        end
        
        local listRealH = listH - 1
        local listBot = yBot
        if st.showKeyboard then
            listRealH = listH - 4
            listBot = yBot - 3
        end
        
        local rows = {}
        for _, it in ipairs(filtered) do
            local name = self.deps.lang.display(it.id)
            table.insert(rows, string.format("%s x%d", name, it.count))
        end
        
        if #rows == 0 then
            widgets.clearArea(1, listY + 1, w, listRealH)
            widgets.center(math.floor((listY + 1 + listBot) / 2), "No items found", colors.gray)
        else
            widgets.scrollList(self, 1, listY + 1, w, listRealH, rows, st, function(idx)
                st.selected = idx
            end)
        end
        
        if st.showKeyboard then
            self:drawKeyboard(math.max(2, math.floor((w - 29) / 2) + 1), yBot - 2)
        end
    end
end

----------------------------------------------------------------
-- Вкладка МЕХАНИЗМЫ (Machines)
----------------------------------------------------------------
function ui:startRecordWizard(stationName)
    local st = self.state.machines
    st.recordMode = true
    st.recordStage = "select_fluids"
    st.recordStation = stationName
    st.recordFluidsSelection = {}
    st.recordDanks = self.deps.fluids.danks or {}
end

function ui:renderRecordFSM(yTop, yBot, w)
    local st = self.state.machines
    local h = yBot - yTop + 1
    local gridChest = self.configData.grid_chest
    
    if st.recordStage == "select_fluids" then
        widgets.text(1, yTop, "Record: Send Input Fluids", colors.cyan, colors.black)
        
        local listY = yTop + 1
        local listH = h - 3
        
        local danks = st.recordDanks
        local yCurr = listY
        for _, dk in ipairs(danks) do
            if yCurr < listY + listH then
                local isSelected = (st.recordFluidsSelection[dk.periph] ~= nil)
                local val = st.recordFluidsSelection[dk.periph] or 1000
                
                widgets.button(self, 1, yCurr, 3, isSelected and "*" or " ", { selected = isSelected }, function()
                    if isSelected then
                        st.recordFluidsSelection[dk.periph] = nil
                    else
                        st.recordFluidsSelection[dk.periph] = 1000
                    end
                end)
                
                term.setCursorPos(5, yCurr)
                term.setTextColor(colors.white)
                term.write(widgets.clip(util.formatId(dk.fluid) .. " (" .. dk.periph .. ")", w - 18))
                
                if isSelected then
                    widgets.stepper(self, w - 12, yCurr, 12, val, function(delta)
                        st.recordFluidsSelection[dk.periph] = math.max(1000, val + delta * 1000)
                    end)
                end
                yCurr = yCurr + 1
            end
        end
        
        if #danks == 0 then
            widgets.text(2, listY + 1, "No danks set - items only.", colors.yellow, colors.black)
        end
        
        widgets.button(self, 1, yBot, 15, "Send & Start", { kind = "active" }, function()
            if not gridChest then
                self:showToast("Set grid chest in Settings first", "danger")
                return
            end
            
            st.recordSnapshotBefore = recipes.snapshotAll(st.recordStation, gridChest, self.deps.storage, self.deps.fluids)
            st.recordStationBefore = recipes.snapshotStation(st.recordStation)
            
            -- Push items
            local p = wrap(gridChest)
            if p and p.list then
                local list = p.list()
                for slot, info in pairs(list) do
                    p.pushItems(st.recordStation, slot)
                end
            end
            
            -- Push fluids
            for periph, mb in pairs(st.recordFluidsSelection) do
                local fluidName = nil
                for _, dk in ipairs(danks) do
                    if dk.periph == periph then fluidName = dk.fluid; break end
                end
                if fluidName and mb > 0 then
                    self.deps.fluids:extractFluid(fluidName, mb, st.recordStation)
                end
            end
            
            st.recordStage = "processing"
            self:showToast("Sent inputs to station!", "success")
        end)
        
        widgets.button(self, 18, yBot, 10, "Cancel", { kind = "danger" }, function()
            st.recordMode = false
        end)
        
    elseif st.recordStage == "processing" then
        widgets.text(1, yTop, "Capture: Processing manual run", colors.yellow, colors.black)
        widgets.text(1, yTop + 2, "Please let the station complete 1 cycle.", colors.white, colors.black)
        widgets.text(1, yTop + 3, "Press 'Finish' when done.", colors.white, colors.black)
        
        widgets.button(self, 1, yBot, 15, "Finish & Save", { kind = "active" }, function()
            local after = recipes.snapshotAll(st.recordStation, gridChest, self.deps.storage, self.deps.fluids)
            local stationAfter = recipes.snapshotStation(st.recordStation)
            local before = st.recordSnapshotBefore
            local stationBefore = st.recordStationBefore
            
            local consumedItems = {}
            for id, countBefore in pairs(before.items) do
                local countAfter = after.items[id] or 0
                if countBefore > countAfter then
                    table.insert(consumedItems, { id = id, count = countBefore - countAfter })
                end
            end
            
            local consumedFluids = {}
            for f, mbBefore in pairs(before.fluids) do
                local mbAfter = after.fluids[f] or 0
                if mbBefore > mbAfter then
                    table.insert(consumedFluids, { fluid = f, mb = mbBefore - mbAfter })
                end
            end
            
            local producedItems = {}
            for id, countAfter in pairs(stationAfter.items) do
                local countBefore = stationBefore.items[id] or 0
                if countAfter > countBefore then
                    table.insert(producedItems, { id = id, count = countAfter - countBefore })
                end
            end
            
            local producedFluids = {}
            for f, mbAfter in pairs(stationAfter.fluids) do
                local mbBefore = stationBefore.fluids[f] or 0
                if mbAfter > mbBefore then
                    table.insert(producedFluids, { fluid = f, mb = mbAfter - mbBefore })
                end
            end
            
            if #consumedItems == 0 and #consumedFluids == 0 and #producedItems == 0 and #producedFluids == 0 then
                self:showToast("No changes detected - did it finish?", "danger")
                return
            end
            
            st.recordConsumedItems = consumedItems
            st.recordConsumedFluids = consumedFluids
            st.recordProducedItems = producedItems
            st.recordProducedFluids = producedFluids
            st.recordStage = "review"
        end)
        
        widgets.button(self, 18, yBot, 10, "Abort", { kind = "danger" }, function()
            self.deps.machines:collect(st.recordStation, { itemInput = {}, fluidOutput = {} })
            st.recordMode = false
            self:showToast("Recording aborted", "info")
        end)
        
    elseif st.recordStage == "review" then
        widgets.text(1, yTop, "Review recorded recipe:", colors.cyan, colors.black)
        
        local yLine = yTop + 2
        widgets.text(1, yLine, "Inputs:", colors.yellow, colors.black)
        yLine = yLine + 1
        for _, it in ipairs(st.recordConsumedItems) do
            if yLine < yBot - 1 then
                widgets.text(2, yLine, string.format(" - %s x%d", widgets.clip(util.formatId(it.id), w - 10), it.count), colors.lightGray, colors.black)
                yLine = yLine + 1
            end
        end
        for _, fl in ipairs(st.recordConsumedFluids) do
            if yLine < yBot - 1 then
                widgets.text(2, yLine, string.format(" - %s %d mB", widgets.clip(util.formatId(fl.fluid), w - 10), fl.mb), colors.lightGray, colors.black)
                yLine = yLine + 1
            end
        end
        
        widgets.text(1, yLine, "Outputs:", colors.yellow, colors.black)
        yLine = yLine + 1
        for _, it in ipairs(st.recordProducedItems) do
            if yLine < yBot - 1 then
                widgets.text(2, yLine, string.format(" - %s x%d", widgets.clip(util.formatId(it.id), w - 10), it.count), colors.lightGray, colors.black)
                yLine = yLine + 1
            end
        end
        for _, fl in ipairs(st.recordProducedFluids) do
            if yLine < yBot - 1 then
                widgets.text(2, yLine, string.format(" - %s %d mB", widgets.clip(util.formatId(fl.fluid), w - 10), fl.mb), colors.lightGray, colors.black)
                yLine = yLine + 1
            end
        end
        
        widgets.button(self, 1, yBot, 10, "Save", { kind = "active" }, function()
            local recId = nil
            local recName = nil
            local outYield = 1
            if #st.recordProducedItems > 0 then
                recId = st.recordProducedItems[1].id
                recName = lang.display(recId)
                outYield = st.recordProducedItems[1].count
            elseif #st.recordProducedFluids > 0 then
                recId = "fluid:" .. st.recordProducedFluids[1].fluid
                recName = util.formatId(st.recordProducedFluids[1].fluid)
                outYield = 1
            end
            
            if not recId then
                self:showToast("No output found!", "danger")
                return
            end
            
            local recipe = {
                id = recId,
                name = recName,
                type = "station",
                station = peripheral.getType(st.recordStation) or "any",
                itemInput = st.recordConsumedItems,
                fluidInput = st.recordConsumedFluids,
                itemOutput = st.recordProducedItems,
                fluidOutput = st.recordProducedFluids,
                output = outYield
            }
            self.deps.recipes:add(recipe)
            self:showToast("Saved: " .. recName, "success")
            st.recordMode = false
        end)
        
        widgets.button(self, 13, yBot, 10, "Cancel", { kind = "danger" }, function()
            self.deps.machines:collect(st.recordStation, { itemInput = {}, fluidOutput = {} })
            st.recordMode = false
        end)
    end
end

function ui:renderMachines(yTop, yBot, w)
    local st = self.state.machines
    if st.recordMode then
        self:renderRecordFSM(yTop, yBot, w)
        return
    end

    local mach = self.deps.machines
    local h = yBot - yTop + 1
    
    local list = mach.names
    if #list == 0 then
        widgets.center(math.floor((yTop + yBot) / 2), "No machines connected", colors.gray)
        return
    end
    
    local isSplit = (w >= 34)
    if isSplit then
        local wLeft = math.floor(w * 0.4)
        local startX = wLeft + 2
        local wRight = w - wLeft - 1
        
        local rows = {}
        for _, name in ipairs(list) do
            local info = mach:status(name)
            local statusStr = "FREE"
            if info then
                statusStr = info.busy and "BUSY" or "FREE"
            end
            table.insert(rows, string.format("%s: %s", name, statusStr))
        end
        
        widgets.scrollList(self, 1, yTop, wLeft, h - 2, rows, st, function(idx)
            st.selected = idx
        end)
        
        widgets.button(self, 1, yBot, wLeft, "Refresh", { kind = "normal" }, function()
            if self.deps.storage then self.deps.storage:scan() end
            if self.deps.fluids then self.deps.fluids:scan() end
            if self.deps.machines then self.deps.machines:collectReady() end
            self:showToast("Refreshed", "info")
        end)
        
        term.setBackgroundColor(colors.black)
        for cy = yTop, yBot do
            term.setCursorPos(wLeft + 1, cy)
            term.setTextColor(colors.gray)
            term.write("|")
        end
        
        widgets.clearArea(startX, yTop, wRight, h)
        local selectedName = list[st.selected or 1]
        if selectedName then
            local info = mach:status(selectedName)
            if info then
                widgets.text(startX, yTop, "Machine: " .. selectedName, colors.cyan, colors.black)
                widgets.text(startX, yTop + 1, "Type: " .. info.type, colors.lightGray, colors.black)
                
                if info.energy then
                    local pct = info.energy.max > 0 and math.floor(info.energy.current / info.energy.max * 100) or 0
                    widgets.text(startX, yTop + 2, string.format("FE: %d/%d (%d%%)", info.energy.current, info.energy.max, pct), colors.yellow, colors.black)
                else
                    widgets.text(startX, yTop + 2, "FE: N/A", colors.lightGray, colors.black)
                end
                
                local yLine = yTop + 3
                if info.tanks and #info.tanks > 0 then
                    widgets.text(startX, yLine, "Tanks:", colors.cyan, colors.black)
                    yLine = yLine + 1
                    for _, t in ipairs(info.tanks) do
                        if yLine < yBot - 2 then
                            local fName = t.name or t.fluid
                            local amt = t.amount or 0
                            local cap = t.capacity or 16000
                            widgets.text(startX, yLine, string.format(" - %s: %d/%d", widgets.clip(util.formatId(fName), wRight - 14), amt, cap), colors.lightGray, colors.black)
                            yLine = yLine + 1
                        end
                    end
                end
                
                local jobFound = nil
                for _, job in pairs(mach.jobs) do
                    if job.name == selectedName then jobFound = job; break end
                end
                if jobFound then
                    widgets.text(startX, yLine, "State: " .. jobFound.state .. " x" .. jobFound.count, colors.green, colors.black)
                    widgets.text(startX, yLine + 1, "Recipe: " .. jobFound.recipe.id, colors.green, colors.black)
                else
                    widgets.text(startX, yLine, "State: Idle", colors.lightGray, colors.black)
                end
                
                widgets.button(self, startX, yBot, wRight, "Record Recipe", { kind = "active" }, function()
                    self:startRecordWizard(selectedName)
                end)
            end
        end
    else
        local rows = {}
        for _, name in ipairs(list) do
            local info = mach:status(name)
            local statusStr = info.busy and "BUSY" or "FREE"
            table.insert(rows, string.format("%s: %s", name, statusStr))
        end
        widgets.scrollList(self, 1, yTop, w, h - 2, rows, st, function(idx)
            st.selected = idx
        end)
        
        local selectedName = list[st.selected or 1]
        widgets.button(self, 1, yBot, math.floor(w / 2), "Refresh", { kind = "normal" }, function()
            if self.deps.storage then self.deps.storage:scan() end
            if self.deps.fluids then self.deps.fluids:scan() end
            if self.deps.machines then self.deps.machines:collectReady() end
            self:showToast("Refreshed", "info")
        end)
        widgets.button(self, math.floor(w / 2) + 2, yBot, w - math.floor(w / 2) - 1, "Record", { kind = "active" }, function()
            if selectedName then
                self:startRecordWizard(selectedName)
            end
        end)
    end
end

----------------------------------------------------------------
-- Вкладка РЕЦЕПТЫ (Recipes)
----------------------------------------------------------------
function ui:quickRecord()
    local gridChest = self.configData.grid_chest
    if not gridChest then
        self:showToast("Set grid chest in Settings first", "danger")
        return
    end
    
    local pGrid = peripheral.wrap(gridChest)
    if not pGrid or type(pGrid.list) ~= "function" then
        self:showToast("Grid chest not reachable", "danger")
        return
    end
    
    local gridList = pGrid.list()
    local hasItems = false
    for slot = 1, math.min(9, pGrid.size()) do
        if gridList[slot] then hasItems = true; break end
    end
    if not hasItems then
        self:showToast("Place items in slots 1-9 of grid chest", "danger")
        return
    end
    
    if not self.deps.dispatcher then
        self:showToast("No dispatcher", "danger")
        return
    end
    
    local wList = self.deps.dispatcher:workerList()
    if #wList == 0 then
        self:showToast("No workers connected", "danger")
        return
    end
    
    local workerId = wList[1].id
    self:showToast("Auto-learning via Worker #" .. workerId .. "...", "info")
    
    local ok, recipe = self.deps.recipes:activeLearnCraft(gridChest, workerId, self.deps.dispatcher)
    if ok then
        self:showToast("Saved: " .. self.deps.lang.display(recipe.id), "success")
        self:addLog("Auto-learned recipe: " .. recipe.id)
        local st = self.state.recipes
        st.mode = "saved_dialog"
        st.savedRecipe = recipe
    else
        self:showToast(tostring(recipe), "danger")
    end
end

function ui:startWizard()
    local st = self.state.recipes
    st.mode = "learn_select"
    st.wizardStep = 1
    st.learnType = 1
    st.wizardScroll = 0
    st.wizardSelected = 1
    
    if self.configData.grid_chest then
        st.tempStorage = self.configData.grid_chest
    else
        st.tempStorage = nil
    end
    st.tempMachine = nil
    st.tempWorker = nil
end

function ui:wizardNext(wRows)
    local st = self.state.recipes
    local recipes = self.deps.recipes
    local selectedVal = wRows[st.wizardSelected or 1]
    
    if not selectedVal then return end
    
    if st.wizardStep == 1 then
        st.learnType = st.wizardSelected or 1
        st.wizardStep = 2
        st.wizardSelected = 1
        st.wizardScroll = 0
    elseif st.wizardStep == 2 then
        st.tempStorage = selectedVal
        st.wizardStep = 3
        st.wizardSelected = 1
        st.wizardScroll = 0
    elseif st.wizardStep == 3 then
        if st.learnType == 1 then
            if st.wizardSelected == 1 then
                -- Crafting (turtle)
                self:showToast("Reading chest...", "info")
                local ok, recipe = recipes:learnFromStorage(st.tempStorage, "shaped")
                if ok then
                    self:showToast("Saved: " .. self.deps.lang.display(recipe.id), "success")
                    self:addLog("Static recipe learned: " .. recipe.id)
                    st.mode = "saved_dialog"
                    st.savedRecipe = recipe
                else
                    self:showToast(tostring(recipe), "danger")
                    st.mode = "list"
                end
            else
                -- Machine (furnace/processor)
                st.tempRecipeType = "machine"
                st.wizardStep = 4
                st.wizardSelected = 1
                st.wizardScroll = 0
            end
        elseif st.learnType == 2 then
            st.tempMachine = selectedVal
            self:showToast("Machine processing...", "info")
            local ok, recipe = recipes:activeLearnMachine(st.tempStorage, selectedVal)
            if ok then
                self:showToast("Smelt Saved: " .. self.deps.lang.display(recipe.id), "success")
                self:addLog("Machine recipe learned: " .. recipe.id)
                st.mode = "saved_dialog"
                st.savedRecipe = recipe
            else
                self:showToast(tostring(recipe), "danger")
                st.mode = "list"
            end
        elseif st.learnType == 3 then
            local workerId = tonumber(selectedVal:match("#(%d+)"))
            if workerId then
                self:showToast("Turtle crafting...", "info")
                local ok, recipe = recipes:activeLearnCraft(st.tempStorage, workerId, self.deps.dispatcher)
                if ok then
                    self:showToast("Craft Saved: " .. self.deps.lang.display(recipe.id), "success")
                    self:addLog("Turtle recipe learned: " .. recipe.id)
                    st.mode = "saved_dialog"
                    st.savedRecipe = recipe
                else
                    self:showToast(tostring(recipe), "danger")
                    st.mode = "list"
                end
            else
                self:showToast("Invalid worker selected", "danger")
                st.mode = "list"
            end
        end
    elseif st.wizardStep == 4 then
        if st.learnType == 1 and st.tempRecipeType == "machine" then
            self:showToast("Reading chest...", "info")
            local ok, recipe = recipes:learnFromStorage(st.tempStorage, "machine", selectedVal)
            if ok then
                self:showToast("Saved: " .. self.deps.lang.display(recipe.id), "success")
                self:addLog("Static machine recipe learned: " .. recipe.id)
                st.mode = "saved_dialog"
                st.savedRecipe = recipe
            else
                self:showToast(tostring(recipe), "danger")
                st.mode = "list"
            end
        end
    end
end

function ui:renderRecipes(yTop, yBot, w)
    local st = self.state.recipes
    local recipes = self.deps.recipes
    local list = recipes:all()
    local h = yBot - yTop + 1
    
    if st.mode == "saved_dialog" then
        local r = st.savedRecipe
        if not r then st.mode = "list"; return end
        
        local name = self.deps.lang.display(r.id, r.name)
        local bodyFn = function(cx, cy, cw, ch)
            widgets.text(cx, cy, "Recipe saved successfully!", colors.green, colors.black)
            widgets.text(cx, cy + 2, "Result: " .. widgets.clip(name, cw - 8), colors.white, colors.black)
            widgets.text(cx, cy + 3, "Output yield: x" .. (r.output or 1), colors.lightGray, colors.black)
            widgets.text(cx, cy + 4, "Type: " .. tostring(r.type), colors.lightGray, colors.black)
            
            if ch >= 8 then
                widgets.text(cx, cy + 5, "Ingredients:", colors.cyan, colors.black)
                local ings = recipes.ingredientsOf(r)
                local yLine = cy + 6
                for _, ing in ipairs(ings) do
                    if yLine <= cy + ch - 1 then
                        widgets.text(cx, yLine, string.format(" - %s x%d", widgets.clip(self.deps.lang.display(ing.id), cw - 12), ing.count), colors.lightGray, colors.black)
                        yLine = yLine + 1
                    end
                end
            end
        end
        
        local buttons = {
            {
                label = "OK",
                kind = "active",
                action = function()
                    st.mode = "list"
                    st.savedRecipe = nil
                end
            }
        }
        widgets.dialog(self, "Recipe Saved", bodyFn, buttons)
        return
    end
    
    local isSplit = (w >= 34)
    
    if isSplit then
        local wLeft = math.floor(w * 0.45)
        local startX = wLeft + 2
        local wRight = w - wLeft - 1
        
        -- Левая колонка: список рецептов
        local rows = {}
        for _, r in ipairs(list) do
            local name = self.deps.lang.display(r.id, r.name)
            local typeStr = r.type == "machine" and "M" or (r.type == "shaped" and "S" or "L")
            table.insert(rows, string.format("[%s] %s", typeStr, name))
        end
        
        widgets.scrollList(self, 1, yTop, wLeft, h - 1, rows, st, function(idx)
            st.selected = idx
        end)
        if #rows == 0 then
            widgets.text(2, yTop + 2, "No recipes", colors.gray, colors.black)
        end
        
        widgets.button(self, 1, yBot, 8, "Delete", { kind = "danger" }, function()
            local r = list[st.selected]
            if r then
                recipes:remove(r.id)
                self:showToast("Deleted recipe", "success")
                st.selected = math.max(1, st.selected - 1)
            end
        end)
        
        -- Вертикальный разделитель
        term.setBackgroundColor(colors.black)
        for cy = yTop, yBot do
            term.setCursorPos(wLeft + 1, cy)
            term.setTextColor(colors.gray)
            term.write("|")
        end
        
        -- Правая колонка: Детали / Мастер обучения
        widgets.clearArea(startX, yTop, wRight, h)
        
        if st.mode == "learn_select" then
            -- Determine step titles and rows
            local maxStep = 3
            if st.learnType == 1 then
                if st.wizardStep >= 3 and st.tempRecipeType == "machine" then
                    maxStep = 4
                else
                    maxStep = 3
                end
            end
            
            local titles = {
                [1] = "1/"..maxStep.." Mode",
                [2] = "2/"..maxStep.." Grid Chest",
                [3] = (st.learnType == 1) and "3/"..maxStep.." Recipe Type" or ((st.learnType == 2) and "3/3 Machine" or "3/3 Worker"),
                [4] = "4/4 Machine Type",
            }
            widgets.text(startX, yTop, titles[st.wizardStep or 1], colors.cyan, colors.black)
            
            -- Получаем строки для текущего шага мастера
            local wRows = {}
            if st.wizardStep == 1 then
                wRows = { "Read Chest (Static)", "Active Smelt (Machine)", "Active Craft (Turtle)" }
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
                        if not isMach then table.insert(wRows, name) end
                    end
                end
            elseif st.wizardStep == 3 then
                if st.learnType == 1 then
                    wRows = { "Crafting (turtle)", "Machine (furnace/processor)" }
                elseif st.learnType == 2 then
                    if self.deps.machines then
                        for _, name in ipairs(self.deps.machines.names) do
                            table.insert(wRows, name)
                        end
                    end
                elseif st.learnType == 3 then
                    if self.deps.dispatcher then
                        local wList = self.deps.dispatcher:workerList()
                        for _, workerInfo in ipairs(wList) do
                            table.insert(wRows, "Worker #" .. workerInfo.id)
                        end
                    end
                end
            elseif st.wizardStep == 4 then
                if st.learnType == 1 and st.tempRecipeType == "machine" then
                    local types = {}
                    local typeSet = { ["furnace"] = true }
                    table.insert(types, "furnace")
                    if self.deps.machines then
                        for _, mname in ipairs(self.deps.machines.names) do
                            local ptype = peripheral.getType(mname)
                            if ptype and not typeSet[ptype] then
                                typeSet[ptype] = true
                                table.insert(types, ptype)
                            end
                        end
                    end
                    wRows = types
                end
            end
            
            local wizardState = { scroll = st.wizardScroll, selected = st.wizardSelected }
            widgets.scrollList(self, startX, yTop + 1, wRight, h - 3, wRows, wizardState, function(idx)
                st.wizardSelected = idx
            end)
            st.wizardScroll = wizardState.scroll
            st.wizardSelected = wizardState.selected
            
            -- Кнопки мастера (динамический расчет ширины для исключения перекрытия)
            local label1 = "Back"
            local label2 = "Cancel"
            
            local isLastStep = false
            if st.wizardStep == maxStep then
                isLastStep = true
            elseif st.learnType == 1 and st.wizardStep == 3 and st.wizardSelected == 1 then
                isLastStep = true
            end
            
            local label3 = isLastStep and "Record" or "Next"
            
            local w1 = #label1 + 2
            local w2 = #label2 + 2
            local w3 = #label3 + 2
            
            if w1 + w2 + w3 + 2 > wRight then
                label1 = "Bk"
                label2 = "Can"
                label3 = isLastStep and "Rec" or "Nxt"
                w1 = #label1 + 2
                w2 = #label2 + 2
                w3 = #label3 + 2
            end
            
            local totalW = w1 + w2 + w3 + 2
            local btnStartX = startX + math.floor((wRight - totalW) / 2)
            
            widgets.button(self, btnStartX, yBot, w1, label1, { kind = "normal" }, function()
                st.wizardStep = math.max(1, st.wizardStep - 1)
                st.wizardSelected = 1
                st.wizardScroll = 0
            end)
            widgets.button(self, btnStartX + w1 + 1, yBot, w2, label2, { kind = "danger" }, function()
                st.mode = "list"
            end)
            widgets.button(self, btnStartX + w1 + w2 + 2, yBot, w3, label3, { kind = "active" }, function()
                self:wizardNext(wRows)
            end)
        else
            -- Режим просмотра рецепта
            local r = list[st.selected]
            if r then
                local displayName = self.deps.lang.display(r.id, r.name)
                widgets.text(startX, yTop, "Recipe: " .. widgets.clip(displayName, wRight - 8), colors.white, colors.black)
                widgets.text(startX, yTop + 1, "Type: " .. r.type, colors.lightGray, colors.black)
                widgets.text(startX, yTop + 2, "Output: " .. (r.output or 1), colors.lightGray, colors.black)
                if r.avgTime then
                    widgets.text(startX, yTop + 3, "Avg Time: " .. string.format("%.1fs", r.avgTime), colors.lightGray, colors.black)
                end
                
                -- Ингредиенты и жидкости
                widgets.text(startX, yTop + 5, "Ingredients / Fluids:", colors.cyan, colors.black)
                local ings = recipes.ingredientsOf(r)
                local yLine = yTop + 6
                for _, ing in ipairs(ings) do
                    if yLine <= yBot - 2 then
                        widgets.text(startX, yLine, string.format(" - %s x%d", widgets.clip(self.deps.lang.display(ing.id), wRight - 8), ing.count), colors.lightGray, colors.black)
                        yLine = yLine + 1
                    end
                end
                local fls = recipes.fluidsOf(r)
                for _, fl in ipairs(fls) do
                    if yLine <= yBot - 2 then
                        widgets.text(startX, yLine, string.format(" - %s %d mB", widgets.clip(util.formatId(fl.fluid), wRight - 12), fl.mb), colors.lightGray, colors.black)
                        yLine = yLine + 1
                    end
                end
            else
                widgets.text(startX, yTop + 2, "No recipe selected", colors.gray, colors.black)
            end
            
            -- Кнопки действий (динамический расчет ширины)
            local label1 = "Record"
            local label2 = "Wizard"
            local w1 = #label1 + 2
            local w2 = #label2 + 2
            
            if w1 + w2 + 1 > wRight then
                label1 = "Rec"
                label2 = "Wiz"
                w1 = #label1 + 2
                w2 = #label2 + 2
            end
            
            local totalW = w1 + w2 + 1
            local btnStartX = startX + math.floor((wRight - totalW) / 2)
            
            widgets.button(self, btnStartX, yBot, w1, label1, { kind = "active" }, function()
                self:quickRecord()
            end)
            widgets.button(self, btnStartX + w1 + 1, yBot, w2, label2, { kind = "normal" }, function()
                self:startWizard()
            end)
        end
    else
        -- Упрощенный режим (если ширина слишком маленькая для колонок)
        local rows = {}
        for _, r in ipairs(list) do
            local name = self.deps.lang.display(r.id, r.name)
            table.insert(rows, name)
        end
        
        widgets.scrollList(self, 1, yTop, w, h - 1, rows, st, function(idx)
            st.selected = idx
        end)
        if #rows == 0 then
            widgets.text(2, yTop + 2, "No recipes", colors.gray, colors.black)
        end
        
        -- Кнопки действий (динамический расчет ширины для малых экранов)
        local label1 = "Record"
        local label2 = "Wizard"
        local label3 = "Delete"
        local w1 = #label1 + 2
        local w2 = #label2 + 2
        local w3 = #label3 + 2
        
        if w1 + w2 + w3 + 2 > w then
            label1 = "Rec"
            label2 = "Wiz"
            label3 = "Del"
            w1 = #label1 + 2
            w2 = #label2 + 2
            w3 = #label3 + 2
        end
        
        local totalW = w1 + w2 + w3 + 2
        local btnStartX = math.floor((w - totalW) / 2) + 1
        
        widgets.button(self, btnStartX, yBot, w1, label1, { kind = "active" }, function()
            self:quickRecord()
        end)
        widgets.button(self, btnStartX + w1 + 1, yBot, w2, label2, { kind = "normal" }, function()
            self:startWizard()
        end)
        widgets.button(self, btnStartX + w1 + w2 + 2, yBot, w3, label3, { kind = "danger" }, function()
            local r = list[st.selected]
            if r then
                recipes:remove(r.id)
                self:showToast("Deleted recipe", "success")
                st.selected = math.max(1, st.selected - 1)
            end
        end)
    end
end

----------------------------------------------------------------
-- Вкладка ЛОГ (Log)
----------------------------------------------------------------
function ui:renderLog(yTop, yBot, w)
    local st = self.state.log
    local h = yBot - yTop + 1
    local rows = {}
    for i = #self.log, 1, -1 do
        table.insert(rows, self.log[i].time .. " " .. self.log[i].msg)
    end
    
    if #rows == 0 then
        widgets.center(math.floor((yTop + yBot) / 2), "Log is empty", colors.gray)
        return
    end
    
    widgets.scrollList(self, 1, yTop, w, h, rows, st, function(idx) end)
end

----------------------------------------------------------------
-- Вкладка НАСТРОЙКИ (Settings)
----------------------------------------------------------------
function ui:renderSettings(yTop, yBot, w)
    local st = self.state.settings
    local h = yBot - yTop
    
    local rows = {}
    local inventories = {}
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
                table.insert(inventories, name)
            end
        end
    end
    
    local currentGrid = self.configData.grid_chest
    for _, name in ipairs(inventories) do
        local label = name
        if name == currentGrid then
            label = "[*] " .. name .. " (Default)"
        else
            label = "[ ] " .. name
        end
        table.insert(rows, label)
    end
    
    widgets.text(1, yTop, "Choose Crafting Grid Chest:", colors.cyan, colors.black)
    
    if #rows == 0 then
        widgets.center(math.floor((yTop + yBot) / 2), "No chests found", colors.gray)
    else
        widgets.scrollList(self, 1, yTop + 1, w, h, rows, st, function(idx)
            st.selected = idx
            local selectedChest = inventories[idx]
            self.configData.grid_chest = selectedChest
            config.save(self.configData)
            self:addLog("Default grid chest: " .. selectedChest)
            self:showToast("Saved default grid chest", "success")
        end)
    end
end

----------------------------------------------------------------
-- Обработка событий
----------------------------------------------------------------
--- Обработать тач по экрану.
function ui:handleTouch(x, y)
    -- Ищем цели с КОНЦА списка (верхние слои перекрывают нижние)
    for i = #self.hits, 1, -1 do
        local h = self.hits[i]
        if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then
            local ok, err = pcall(h.action)
            if not ok then
                self:showToast("Error: " .. tostring(err), "danger")
                self:addLog("Action error: " .. tostring(err))
            end
            self.dirty = true
            return true
        end
    end
    return false
end

--- Обработать ввод символа с клавиатуры.
function ui:handleChar(ch)
    local tab = self.activeTab
    if tab == "craft" and self.state.craft.mode == "quantity" then
        local st = self.state.craft
        if ch:match("%d") then
            if st.qty == "0" or st.qty == "1" then
                st.qty = ch
            else
                st.qty = st.qty .. ch
            end
            self.dirty = true
        end
    elseif tab == "storage" then
        local st = self.state.storage
        if st.mode == "dank_edit" then
            st.dankEditFluid = (st.dankEditFluid or "") .. ch
            self.dirty = true
        elseif ch:match("%S") or ch == " " then
            st.search = st.search .. ch
            st.scroll = 0
            st.selected = 1
            self.dirty = true
        end
    end
end

--- Обработать нажатие специальной клавиши.
function ui:handleKey(key)
    local tab = self.activeTab
    if key == keys.q then
        os.queueEvent("shellcraft_quit")
        self.dirty = true
    elseif key == keys.backspace then
        if tab == "craft" and self.state.craft.mode == "quantity" then
            local st = self.state.craft
            st.qty = st.qty:sub(1, -2)
            if st.qty == "" then st.qty = "1" end
            self.dirty = true
        elseif tab == "storage" then
            local st = self.state.storage
            if st.mode == "dank_edit" then
                st.dankEditFluid = (st.dankEditFluid or ""):sub(1, -2)
                self.dirty = true
            else
                st.search = st.search:sub(1, -2)
                st.scroll = 0
                st.selected = 1
                self.dirty = true
            end
        end
    elseif key == keys.up then
        self:moveSelection(-1)
        self.dirty = true
    elseif key == keys.down then
        self:moveSelection(1)
        self.dirty = true
    elseif key == keys.left then
        self:moveTab(-1)
        self.dirty = true
    elseif key == keys.right then
        self:moveTab(1)
        self.dirty = true
    end
end

function ui:moveSelection(delta)
    local tab = self.activeTab
    local st = self.state[tab]
    if not st or not st.selected then return end
    
    local listSize = 0
    if tab == "craft" then
        listSize = #self.deps.recipes:all()
    elseif tab == "storage" then
        -- Фильтруем как в render
        local items = self.deps.storage:items()
        local search = st.search:lower()
        local count = 0
        for _, it in ipairs(items) do
            local name = self.deps.lang.display(it.id):lower()
            if search == "" or name:find(search, 1, true) or it.id:lower():find(search, 1, true) then
                count = count + 1
            end
        end
        listSize = count
    elseif tab == "machines" then
        listSize = #self.deps.machines.names
    elseif tab == "recipes" then
        listSize = #self.deps.recipes:all()
    elseif tab == "settings" then
        local count = 0
        for _, name in ipairs(peripheral.getNames()) do
            local ok, p = pcall(peripheral.wrap, name)
            if ok and p and type(p.list) == "function" and type(p.size) == "function" then
                local isMach = false
                if self.deps.machines then
                    for _, mn in ipairs(self.deps.machines.names) do
                        if mn == name then isMach = true; break end
                    end
                end
                if not isMach then count = count + 1 end
            end
        end
        listSize = count
    end
    
    if listSize > 0 then
        st.selected = util.clamp(st.selected + delta, 1, listSize)
    end
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
