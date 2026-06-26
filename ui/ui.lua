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
        storage  = { scroll = 0, selected = 1, search = "", showKeyboard = false },
        machines = { scroll = 0, selected = 1 },
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
function ui:taskFailed()
    local a = self.state.craft.active
    if a then a.failed = (a.failed or 0) + 1 end
    self.dirty = true
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
            widgets.text(cx, cy + 2, "Qty: " .. st.qty, colors.yellow, colors.black)
            
            -- Вычисляем ETA и BOM
            if qty > 0 then
                local tree = planner.buildTree(r.id, qty, recipes, self.deps.storage)
                local bom = planner.calculateBOM(tree)
                local estTime, approx = planner.estimateTime(tree, self:workersCount(), recipes)
                widgets.text(cx, cy + 3, "ETA: " .. planner.formatDuration(estTime, approx), approx and colors.yellow or colors.green, colors.black)
                
                -- Вывод BOM требований если есть место по высоте
                if ch >= 7 then
                    widgets.text(cx, cy + 4, "Requires:", colors.cyan, colors.black)
                    local yLine = cy + 5
                    for _, info in ipairs(bom) do
                        if yLine <= cy + ch - 1 then
                            local have = self.deps.storage:count(info.id)
                            local col = have >= info.count and colors.green or colors.red
                            widgets.text(cx, yLine, string.format(" %s %d/%d", widgets.clip(self.deps.lang.display(info.id), cw - 10), have, info.count), col, colors.black)
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
                widgets.stepper(self, cx, cy + 4, cw - 13, qty, function(delta)
                    st.qty = tostring(math.max(1, qty + delta))
                end)
            else
                -- Если Numpad не влезает, используем только Stepper на всю ширину
                widgets.stepper(self, cx, cy + 4, cw, qty, function(delta)
                    st.qty = tostring(math.max(1, qty + delta))
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
                            local tree = planner.buildTree(r.id, n, recipes, self.deps.storage)
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

function ui:renderStorage(yTop, yBot, w)
    local st = self.state.storage
    local items = self.deps.storage:items()
    local h = yBot - yTop + 1
    
    -- Кнопки Toggle Keyboard и Clear (динамический расчет ширины)
    local keyLabel = (w >= 39) and "Keyboard" or "Keybrd"
    local clearLabel = "Clear"
    local w1 = #keyLabel + 2
    local w2 = #clearLabel + 2
    
    widgets.button(self, w - w1 - w2 - 2, yTop, w1, keyLabel, { selected = st.showKeyboard }, function()
        st.showKeyboard = not st.showKeyboard
    end)
    widgets.button(self, w - w2 - 1, yTop, w2, clearLabel, { kind = "danger" }, function()
        st.search = ""
        st.scroll = 0
        st.selected = 1
    end)
    
    widgets.text(1, yTop, "Search: " .. st.search .. "_", colors.yellow, colors.black)
    local search = st.search:lower()
    
    -- Фильтрация
    local filtered = {}
    for _, it in ipairs(items) do
        local name = self.deps.lang.display(it.id):lower()
        if search == "" or name:find(search, 1, true) or it.id:lower():find(search, 1, true) then
            table.insert(filtered, it)
        end
    end
    
    -- Расчет высоты с учетом клавиатуры (размещаем клавиатуру до yBot)
    local listH = h - 1
    local listBot = yBot
    if st.showKeyboard then
        listH = h - 4
        listBot = yBot - 3
    end
    
    local rows = {}
    for _, it in ipairs(filtered) do
        local name = self.deps.lang.display(it.id)
        table.insert(rows, string.format("%s x%d", name, it.count))
    end
    
    if #rows == 0 then
        widgets.clearArea(1, yTop + 1, w, listH)
        widgets.center(math.floor((yTop + listBot) / 2), "No items found", colors.gray)
    else
        widgets.scrollList(self, 1, yTop + 1, w, listH, rows, st, function(idx)
            st.selected = idx
        end)
    end
    
    if st.showKeyboard then
        self:drawKeyboard(math.max(2, math.floor((w - 29) / 2) + 1), yBot - 2)
    end
end

----------------------------------------------------------------
-- Вкладка МЕХАНИЗМЫ (Machines)
----------------------------------------------------------------
function ui:renderMachines(yTop, yBot, w)
    local st = self.state.machines
    local mach = self.deps.machines
    local h = yBot - yTop
    
    local rows = {}
    for _, name in ipairs(mach.names) do
        local info = mach:status(name)
        local statusStr = info.busy and "BUSY" or "FREE"
        local what = info.cooking and (" (" .. self.deps.lang.display(info.cooking) .. ")") or ""
        table.insert(rows, string.format("%s: %s%s", name, statusStr, what))
    end
    
    widgets.scrollList(self, 1, yTop, w, h, rows, st, function(idx)
        st.selected = idx
    end)
    
    widgets.button(self, 1, yBot, 10, "Refresh", { kind = "normal" }, function()
        if self.deps.storage then self.deps.storage:scan() end
        if self.deps.machines then self.deps.machines:collectReady() end
        self:showToast("Refreshed statuses", "info")
    end)
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
    local isLastStep = (st.wizardStep == 3) or (st.wizardStep == 2 and st.learnType == 1)
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
                self:showToast("Saved: " .. self.deps.lang.display(recipe.id), "success")
                self:addLog("Static recipe learned: " .. recipe.id)
            else
                self:showToast(tostring(recipe), "danger")
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
            self:showToast("Machine processing...", "info")
            local ok, recipe = recipes:activeLearnMachine(st.tempStorage, selectedVal)
            if ok then
                self:showToast("Smelt Saved: " .. self.deps.lang.display(recipe.id), "success")
                self:addLog("Machine recipe learned: " .. recipe.id)
            else
                self:showToast(tostring(recipe), "danger")
            end
        elseif st.learnType == 3 then
            local workerId = tonumber(selectedVal:match("#(%d+)"))
            if workerId then
                self:showToast("Turtle crafting...", "info")
                local ok, recipe = recipes:activeLearnCraft(st.tempStorage, workerId, self.deps.dispatcher)
                if ok then
                    self:showToast("Craft Saved: " .. self.deps.lang.display(recipe.id), "success")
                    self:addLog("Turtle recipe learned: " .. recipe.id)
                else
                    self:showToast(tostring(recipe), "danger")
                end
            else
                self:showToast("Invalid worker selected", "danger")
            end
        end
        st.mode = "list"
    end
end

function ui:renderRecipes(yTop, yBot, w)
    local st = self.state.recipes
    local recipes = self.deps.recipes
    local list = recipes:all()
    local h = yBot - yTop + 1
    
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
            local titles = {
                [1] = "1/3 Mode",
                [2] = "2/3 Grid Chest",
                [3] = (st.learnType == 2) and "3/3 Machine" or "3/3 Worker"
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
                if st.learnType == 2 then
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
            local label3 = (st.wizardStep == 3 or (st.wizardStep == 2 and st.learnType == 1)) and "Record" or "Next"
            
            local w1 = #label1 + 2
            local w2 = #label2 + 2
            local w3 = #label3 + 2
            
            if w1 + w2 + w3 + 2 > wRight then
                label1 = "Bk"
                label2 = "Can"
                label3 = (label3 == "Record") and "Rec" or "Nxt"
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
                widgets.text(startX, yTop, "Recipe: " .. widgets.clip(r.id, wRight - 8), colors.white, colors.black)
                widgets.text(startX, yTop + 1, "Type: " .. r.type, colors.lightGray, colors.black)
                widgets.text(startX, yTop + 2, "Output: " .. (r.output or 1), colors.lightGray, colors.black)
                if r.avgTime then
                    widgets.text(startX, yTop + 3, "Avg Time: " .. string.format("%.1fs", r.avgTime), colors.lightGray, colors.black)
                end
                
                -- Ингредиенты
                widgets.text(startX, yTop + 5, "Ingredients:", colors.cyan, colors.black)
                local ings = recipes.ingredientsOf(r)
                local yLine = yTop + 6
                for _, ing in ipairs(ings) do
                    if yLine <= yBot - 2 then
                        widgets.text(startX, yLine, string.format(" - %s x%d", widgets.clip(self.deps.lang.display(ing.id), wRight - 8), ing.count), colors.lightGray, colors.black)
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
        if ch:match("%S") or ch == " " then
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
            st.search = st.search:sub(1, -2)
            st.scroll = 0
            st.selected = 1
            self.dirty = true
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
