-- ui/ui.lua
-- Главный UI ShellCraft: вкладки на мониторе, тач-управление.
-- Вся отрисовка идет через буфер (window API), а хит-тест через self.hits = {}.
-- Весь текст выводится на английском языке.

local ui = {}
ui.__index = ui

local function formatPeriphName(name)
    local ptype = peripheral.getType(name) or "unknown"
    if ptype:find(":") then
        ptype = ptype:match(":(.+)$")
    end
    return string.format("%s (%s)", name, ptype)
end

local function prettyModName(mod)
    if mod == "all" then return "All" end
    if mod == "minecraft" then return "MC" end
    if mod == "create" then return "Create" end
    if mod == "industrialupgrade" then return "IU" end
    if #mod > 8 then
        return mod:sub(1, 1):upper() .. mod:sub(2, 7) .. "."
    else
        return mod:sub(1, 1):upper() .. mod:sub(2)
    end
end

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
        queue    = { scroll = 0, selected = 1 },
        storage  = { scroll = 0, selected = 1, search = "", showKeyboard = false, tab = "items" },
        machines = { scroll = 0, selected = 1 },
        recipes  = { scroll = 0, selected = 1, mode = "list", wizard = nil },
        log      = { scroll = 0 },
        settings = { scroll = 0, selected = 1, showDialog = false },
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
        { id = "queue",   title = "Queue" },
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
    elseif tab == "queue" then
        self:renderQueue(bodyY, yBot, w)
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
    elseif tab == "queue" then
        return "Tap task to select. Cancel to abort."
    elseif tab == "storage" then
        return "Scroll list. Toggle Keyboard to search."
    elseif tab == "machines" then
        return "List of connected machines. Tap Refresh."
    elseif tab == "recipes" then
        return "Manage recipes. Tap + Learn to add new."
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
                local estTime, approx = planner.estimateTime(tree, self:workersCount(), recipes)
                widgets.text(cx, cy + 3, "ETA: " .. planner.formatDuration(estTime, approx), approx and colors.yellow or colors.green, colors.black)

                -- BOM: показываем только то, что реально нужно дополнительно добыть/скрафтить
                -- Используем planner.bom() — он возвращает базовые ресурсы (листья без рецепта)
                local rawBom = planner.bom(tree)
                -- Строим отсортированный список: сначала нехватает, потом всё остальное
                local bomList = {}
                for id, need in pairs(rawBom.items) do
                    -- Скрываем сам крафтуемый предмет из BOM (он не является ингредиентом)
                    if id ~= r.id then
                        table.insert(bomList, { id = id, need = need })
                    end
                end
                table.sort(bomList, function(a, b)
                    local ha = self.deps.storage:count(a.id)
                    local hb = self.deps.storage:count(b.id)
                    local misA = ha < a.need
                    local misB = hb < b.need
                    if misA ~= misB then return misA end  -- нехватка — вверх
                    return a.id < b.id
                end)

                -- Оставляем место для Stepper (cy+4) и кнопок (cy+ch-1)
                local bomYStart = cy + 5
                local bomYMax   = cy + ch - 2  -- -2 чтобы не налезать на Stepper

                if ch >= 7 and #bomList > 0 then
                    widgets.text(cx, cy + 4, "Requires:", colors.cyan, colors.black)
                    local yLine = bomYStart
                    for _, info in ipairs(bomList) do
                        if yLine > bomYMax then break end
                        local have = self.deps.storage:count(info.id)
                        local col = have >= info.need and colors.green or colors.red
                        widgets.text(cx, yLine,
                            string.format(" %s %d/%d",
                                widgets.clip(self.deps.lang.display(info.id), cw - 10),
                                have, info.need),
                            col, colors.black)
                        yLine = yLine + 1
                    end
                    -- Жидкости
                    for _, info in ipairs(rawBom.fluids or {}) do
                        if yLine > bomYMax then break end
                        local have = self.deps.fluids:count(info.fluid)
                        local col = have >= info.mb and colors.green or colors.red
                        widgets.text(cx, yLine,
                            string.format(" %s %d/%d mB",
                                widgets.clip(util.formatId(info.fluid), cw - 14),
                                have, info.mb),
                            col, colors.black)
                        yLine = yLine + 1
                    end
                elseif ch >= 6 and #bomList == 0 then
                    widgets.text(cx, cy + 4, "All resources available", colors.green, colors.black)
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
function ui:renderQueue(yTop, yBot, w)
    local st = self.state.queue
    local disp = self.deps.dispatcher
    local h = yBot - yTop + 1
    
    if not disp then
        widgets.center(math.floor((yTop + yBot) / 2), "Dispatcher not connected", colors.red)
        return
    end
    
    local rawList = disp:activeTasks()
    if #rawList == 0 then
        widgets.center(math.floor((yTop + yBot) / 2), "No active tasks", colors.gray)
        return
    end

    -- Group tasks by recipe ID to keep UI clean and prevent overflow
    local grouped = {}
    local list = {}
    for _, t in ipairs(rawList) do
        local key = t.recipe.id
        if not grouped[key] then
            grouped[key] = {
                recipe = t.recipe,
                count = 0,
                status = "queued",
                attempts = 0,
                progress = 0,
                worker_ids = {},
                ids = {},
                is_group = true
            }
            table.insert(list, grouped[key])
        end
        local g = grouped[key]
        g.count = g.count + t.count
        table.insert(g.ids, t.id)
        g.attempts = math.max(g.attempts, t.attempts or 0)
        
        if t.status == "running" then
            g.status = "running"
            if t.worker_id then
                g.worker_ids[t.worker_id] = true
            end
            g.progress = g.progress + (t.progress or 0)
        elseif t.status == "paused" and g.status ~= "running" then
            g.status = "paused"
        end
    end

    -- Finalize progress and workers for each grouped task
    for _, g in ipairs(list) do
        local wList = {}
        for wId in pairs(g.worker_ids) do
            table.insert(wList, tostring(wId))
        end
        table.sort(wList)
        g.worker_str = #wList > 0 and table.concat(wList, ", ") or nil

        local runningCount = 0
        for _, t in ipairs(rawList) do
            if t.recipe.id == g.recipe.id and t.status == "running" then
                runningCount = runningCount + 1
            end
        end
        if runningCount > 0 then
            g.progress = math.floor(g.progress / runningCount)
        else
            g.progress = nil
        end
        g.id = g.ids[1] -- fallback for selection/compatibility
    end

    table.sort(list, function(a, b) return a.recipe.id < b.recipe.id end)
    
    local isSplit = (w >= 34)
    local startXLeft = 1
    local wLeft = w
    local startX = 1
    local wRight = 0
    local sepX = 0
    
    if isSplit then
        local maxLeft = 24
        local maxRight = 32
        local totalSplitW = maxLeft + 1 + maxRight
        if w > totalSplitW then
            startXLeft = math.floor((w - totalSplitW) / 2) + 1
            wLeft = maxLeft
        else
            wLeft = math.floor(w * 0.45)
        end
        sepX = startXLeft + wLeft
        startX = sepX + 1
        wRight = w - sepX
        if wRight > maxRight then
            wRight = maxRight
        end
    end
    
    if isSplit then
        -- Left column: List of active tasks
        local rows = {}
        for _, t in ipairs(list) do
            local name = self.deps.lang.display(t.recipe.id, t.recipe.name)
            local statusChar = "Q"
            if t.status == "running" then statusChar = "R"
            elseif t.status == "paused" then statusChar = "P"
            elseif t.status == "done" then statusChar = "D"
            elseif t.status == "failed" then statusChar = "F"
            elseif t.status == "canceled" then statusChar = "C"
            end
            table.insert(rows, string.format("[%s] %s x%d", statusChar, name, t.count))
        end
        
        widgets.scrollList(self, startXLeft, yTop, wLeft, h, rows, st, function(idx)
            st.selected = idx
        end)
        
        -- Vertical separator
        term.setBackgroundColor(colors.black)
        for cy = yTop, yBot do
            term.setCursorPos(sepX, cy)
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
            if t.is_group and #t.ids > 1 then
                widgets.text(startX, yTop + 1, "Subtasks: " .. #t.ids, colors.lightGray, colors.black)
            else
                widgets.text(startX, yTop + 1, "ID: " .. t.id, colors.lightGray, colors.black)
            end
            widgets.text(startX, yTop + 2, "Count: " .. t.count, colors.white, colors.black)
            
            local statusStr = t.status
            if t.status == "running" then
                statusStr = "Running on #" .. (t.worker_str or tostring(t.worker_id or "?"))
            elseif t.status == "queued" then
                statusStr = "Queued"
            elseif t.status == "paused" then
                statusStr = "Paused"
            end
            
            local statusCol = colors.lightGray
            if t.status == "running" then
                statusCol = colors.yellow
            elseif t.status == "paused" then
                statusCol = colors.orange
            end
            widgets.text(startX, yTop + 3, "Status: " .. statusStr, statusCol, colors.black)
            
            widgets.text(startX, yTop + 4, "Attempts: " .. t.attempts .. "/" .. disp.maxAttempts, colors.lightGray, colors.black)
            
            if t.status == "running" and t.progress then
                widgets.text(startX, yTop + 5, "Progress: " .. t.progress .. "%", colors.green, colors.black)
            end
            
            -- Cancel button at the bottom of the right column (cancels all subtasks in group)
            widgets.button(self, startX, yBot, wRight, "Cancel Task", { kind = "danger" }, function()
                local anyOk = false
                local lastErr = nil
                for _, tid in ipairs(t.ids) do
                    local ok, err = disp:cancelTask(tid)
                    if ok then
                        anyOk = true
                    else
                        lastErr = err
                    end
                end
                if anyOk then
                    self:showToast("Task cancelled", "success")
                    st.selected = math.max(1, st.selected - 1)
                else
                    self:showToast(tostring(lastErr or "Failed to cancel"), "danger")
                end
            end)
        end
    else
        -- Compact layout
        local rows = {}
        for _, t in ipairs(list) do
            local name = self.deps.lang.display(t.recipe.id, t.recipe.name)
            local statusStr = "Q"
            if t.status == "running" then
                statusStr = "R:" .. (t.worker_str or tostring(t.worker_id or "?"))
            elseif t.status == "paused" then
                statusStr = "P"
            end
            table.insert(rows, string.format("[%s] %s x%d", statusStr, name, t.count))
        end
        
        widgets.scrollList(self, 1, yTop, w, h - 2, rows, st, function(idx)
            st.selected = idx
        end)
        
        -- Cancel button at the bottom (cancels all subtasks in group)
        widgets.button(self, 1, yBot, w, "Cancel Selected", { kind = "danger" }, function()
            local t = list[st.selected]
            if t then
                local anyOk = false
                local lastErr = nil
                for _, tid in ipairs(t.ids) do
                    local ok, err = disp:cancelTask(tid)
                    if ok then
                        anyOk = true
                    else
                        lastErr = err
                    end
                end
                if anyOk then
                    self:showToast("Task cancelled", "success")
                    st.selected = math.max(1, st.selected - 1)
                else
                    self:showToast(tostring(lastErr or "Failed to cancel"), "danger")
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

function ui:renderStorage(yTop, yBot, w)
    local st = self.state.storage
    local subTab = st.tab or "items"
    st.tab = subTab
    
    local segY = widgets.segmented(self, yTop, {
        { id = "items", title = "Items" },
        { id = "fluids", title = "Fluids" }
    }, subTab, function(id)
        st.tab = id
        st.scroll = 0
        st.selected = 1
    end)
    
    local controlY = segY + 1
    local listY = controlY + 1
    local listH = yBot - listY + 1
    
    local keyLabel = (w >= 39) and "Keyboard" or "Keybrd"
    local clearLabel = "Clear"
    local importLabel = "Import"
    local w1 = #keyLabel + 2
    local w2 = #clearLabel + 2
    local w3 = #importLabel + 2
    
    widgets.button(self, w - w1 - w2 - w3 - 3, controlY, w1, keyLabel, { selected = st.showKeyboard }, function()
        st.showKeyboard = not st.showKeyboard
    end)
    widgets.button(self, w - w2 - w3 - 2, controlY, w2, clearLabel, { kind = "danger" }, function()
        st.search = ""
        st.scroll = 0
        st.selected = 1
    end)
    widgets.button(self, w - w3 - 1, controlY, w3, importLabel, { kind = "active" }, function()
        local chest = self.configData and self.configData.default_import
        if not chest or chest == "" then
            self:showToast("Set Import Chest in Settings first", "danger")
            return
        end
        local count, err = self.deps.storage:importFrom(chest, nil)
        if count and count > 0 then
            self:showToast(string.format("Imported %d items", count), "success")
        elseif err == "storage_full" then
            self:showToast("Storage is full!", "warning")
        elseif err and err ~= "partial" then
            self:showToast(tostring(err), "danger")
        else
            self:showToast("No items to import", "warning")
        end
    end)

    
    widgets.text(1, controlY, "Search: " .. st.search .. "_", colors.yellow, colors.black)
    local search = st.search:lower()
    
    local rows = {}
    if subTab == "items" then
        local items = self.deps.storage and self.deps.storage:items() or {}
        local filtered = {}
        for _, it in ipairs(items) do
            local name = self.deps.lang.display(it.id):lower()
            if search == "" or name:find(search, 1, true) or it.id:lower():find(search, 1, true) then
                table.insert(filtered, it)
            end
        end
        for _, it in ipairs(filtered) do
            local name = self.deps.lang.display(it.id)
            table.insert(rows, string.format("%s x%d", name, it.count))
        end
    else
        local fluidsList = self.deps.fluids and self.deps.fluids:fluids() or {}
        local filtered = {}
        for _, fl in ipairs(fluidsList) do
            local name = util.formatId(fl.fluid):lower()
            if search == "" or name:find(search, 1, true) or fl.fluid:lower():find(search, 1, true) then
                table.insert(filtered, fl)
            end
        end
        for _, fl in ipairs(filtered) do
            local name = util.formatId(fl.fluid)
            table.insert(rows, string.format("%s %d mB", name, fl.mb))
        end
    end
    
    local listRealH = listH
    local listBot = yBot
    if st.showKeyboard then
        listRealH = listH - 3
        listBot = yBot - 3
    end
    
    if #rows == 0 then
        widgets.clearArea(1, listY, w, listRealH)
        widgets.center(math.floor((listY + listBot) / 2), "No items found", colors.gray)
    else
        widgets.scrollList(self, 1, listY, w, listRealH, rows, st, function(idx)
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
function ui:startRecordWizard(stationName)
    local st = self.state.machines
    st.recordMode = true
    st.recordStage = "choose_type"
    st.recordStation = stationName
    st.recordFluidsSelection = {}
    
    -- Сбор всех возможных баков с жидкостями (назначенные данки + любые другие баки)
    local danks = {}
    local assignedSet = {}
    for _, dk in ipairs(self.deps.fluids.danks or {}) do
        table.insert(danks, { periph = dk.periph, fluid = dk.fluid, target = dk.target })
        assignedSet[dk.periph] = true
    end
    for _, name in ipairs(peripheral.getNames()) do
        if not assignedSet[name] then
            local p = peripheral.wrap(name)
            if p and (peripheral.hasType(name, "fluid_storage") or type(p.tanks) == "function") then
                local fluidName = "any"
                local ok, tks = pcall(p.tanks)
                if ok and tks and tks[1] then
                    fluidName = tks[1].name or tks[1].fluid or "any"
                end
                table.insert(danks, { periph = name, fluid = fluidName, target = 16000 })
            end
        end
    end
    st.recordDanks = danks
end

function ui:recordSendAndStart()
    local st = self.state.machines
    local gridChest = self.configData.grid_chest
    if not gridChest then
        self:showToast("Set grid chest in Settings first", "danger")
        return false
    end
    
    st.recordSnapshotBefore = recipes.snapshotAll(st.recordStation, gridChest, self.deps.storage, self.deps.fluids)
    st.recordStationBefore = recipes.snapshotStation(st.recordStation)
    
    -- Push items
    local p = peripheral.wrap(gridChest)
    if p and p.list then
        local list = p.list()
        for slot, info in pairs(list) do
            p.pushItems(st.recordStation, slot)
        end
    end
    
    -- Push fluids
    local danks = st.recordDanks or {}
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
    return true
end

function ui:renderRecordFSM(yTop, yBot, w)
    local st = self.state.machines
    local h = yBot - yTop + 1
    local gridChest = self.configData.grid_chest
    
    if st.recordStage == "choose_type" then
        widgets.text(1, yTop, "Record: Recipe Type", colors.cyan, colors.black)
        widgets.text(1, yTop + 2, "Does this recipe require input fluids?", colors.white, colors.black)
        
        widgets.button(self, 1, yTop + 4, 15, "Items Only", { kind = "active" }, function()
            st.recordFluidsSelection = {}
            self:recordSendAndStart()
        end)
        
        widgets.button(self, 18, yTop + 4, 15, "Items & Fluids", { kind = "normal" }, function()
            st.recordStage = "select_fluids"
        end)
        
        widgets.button(self, 1, yBot, 10, "Cancel", { kind = "danger" }, function()
            st.recordMode = false
        end)
        
    elseif st.recordStage == "select_fluids" then
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
                term.write(widgets.clip(util.formatId(dk.fluid) .. " (" .. dk.periph .. ")", w - 20))
                
                if isSelected then
                    widgets.stepper(self, w - 16, yCurr, 16, val, function(delta)
                        st.recordFluidsSelection[dk.periph] = math.max(1000, val + delta * 1000)
                    end)
                end
                yCurr = yCurr + 1
            end
        end
        
        if #danks == 0 then
            widgets.text(2, listY + 1, "No fluid storages on network.", colors.yellow, colors.black)
        end
        
        widgets.button(self, 1, yBot, 15, "Send & Start", { kind = "active" }, function()
            self:recordSendAndStart()
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
            
            local targetMachine = st.recordStation
            local ptype = st.recordStation and peripheral.getType(st.recordStation)
            local isChestType = false
            local storageKeywords = { "chest", "barrel", "vault", "shulker", "crate", "storage", "drawer", "cabinet", "box", "bag", "dank", "safe", "pocket" }
            if ptype then
                local plower = ptype:lower()
                for _, kw in ipairs(storageKeywords) do
                    if plower:find(kw) then isChestType = true; break end
                end
            end
            if ptype and not isChestType then
                targetMachine = ptype
            end
            
            local recipe = {
                id = recId,
                name = recName,
                type = "station",
                station = targetMachine or "any",
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
    local mach = self.deps.machines
    local h = yBot - yTop + 1
    
    local list = mach and mach.names or {}
    if #list == 0 then
        widgets.center(math.floor((yTop + yBot) / 2), "No machines registered", colors.gray)
        return
    end
    
    local isSplit = (w >= 34)
    local startXLeft = 1
    local wLeft = w
    local startX = 1
    local wRight = 0
    local sepX = 0
    
    if isSplit then
        local maxLeft = 24
        local maxRight = 32
        local totalSplitW = maxLeft + 1 + maxRight
        if w > totalSplitW then
            startXLeft = math.floor((w - totalSplitW) / 2) + 1
            wLeft = maxLeft
        else
            wLeft = math.floor(w * 0.4)
        end
        sepX = startXLeft + wLeft
        startX = sepX + 1
        wRight = w - sepX
        if wRight > maxRight then
            wRight = maxRight
        end
    end
    
    if isSplit then
        local rows = {}
        for _, name in ipairs(list) do
            local info = mach:status(name)
            local statusStr = "FREE"
            if info then
                statusStr = info.busy and "BUSY" or "FREE"
            end
            table.insert(rows, string.format("%s: %s", name, statusStr))
        end
        
        widgets.scrollList(self, startXLeft, yTop, wLeft, h - 2, rows, st, function(idx)
            st.selected = idx
        end)
        
        widgets.button(self, startXLeft, yBot, wLeft, "Refresh", { kind = "normal" }, function()
            if self.deps.storage then self.deps.storage:scan() end
            if self.deps.fluids then self.deps.fluids:scan() end
            if self.deps.machines then self.deps.machines:collectReady() end
            self:showToast("Refreshed", "info")
        end)
        
        term.setBackgroundColor(colors.black)
        for cy = yTop, yBot do
            term.setCursorPos(sepX, cy)
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
                    self.activeTab = "recipes"
                    self:startLearnWizard(selectedName)
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
                self.activeTab = "recipes"
                self:startLearnWizard(selectedName)
            end
        end)
    end
end

----------------------------------------------------------------
-- Вкладка РЕЦЕПТЫ (Recipes)
----------------------------------------------------------------
function ui:startLearnWizard(optMachineName)
    local st = self.state.recipes
    st.mode = "learn_wizard"
    st.wizard = {
        step = optMachineName and 2 or 1,
        recipeType = optMachineName and "machine" or "crafting",
        gridChest = self.configData.grid_chest or "",
        worker = nil,
        machine = optMachineName,
        learnType = "static",
        activeOption = "automated",
        manualFluidOption = "items_only",
        manualFluids = {},
        danksList = {},
        scroll = 0,
        selected = 1
    }
end

function ui:wizardStartManualRun()
    local wiz = self.state.recipes.wizard
    local gridChest = wiz.gridChest
    if not gridChest or gridChest == "" then
        self:showToast("Set grid chest first", "danger")
        return false
    end
    
    wiz.snapshotBefore = self.deps.recipes.snapshotAll(wiz.machine, gridChest, self.deps.storage, self.deps.fluids)
    wiz.stationBefore = self.deps.recipes.snapshotStation(wiz.machine)
    
    local p = peripheral.wrap(gridChest)
    if p and p.list then
        local list = p.list()
        for slot, info in pairs(list) do
            p.pushItems(wiz.machine, slot)
        end
    end
    
    for periph, mb in pairs(wiz.manualFluids) do
        local fluidName = nil
        for _, dk in ipairs(wiz.danksList) do
            if dk.periph == periph then fluidName = dk.fluid; break end
        end
        if fluidName and mb > 0 then
            self.deps.fluids:extractFluid(fluidName, mb, wiz.machine)
        end
    end
    
    self:showToast("Inputs sent to machine!", "success")
    return true
end

function ui:renderLearnWizard(x, y, w, h, yBot)
    local st = self.state.recipes
    local wiz = st.wizard
    if not wiz then return end
    
    local recipes = self.deps.recipes
    local disp = self.deps.dispatcher
    
    local title = string.format("Learn: Step %d/9", wiz.step)
    widgets.text(x, y, title, colors.cyan, colors.black)
    
    local contentY = y + 2
    local contentH = yBot - contentY - 1
    
    if wiz.step == 1 then
        widgets.text(x, contentY, "Choose Recipe Type:", colors.white, colors.black)
        
        local isCraft = wiz.recipeType == "crafting"
        widgets.button(self, x, contentY + 2, w, "Crafting (Turtle)", { selected = isCraft }, function()
            wiz.recipeType = "crafting"
        end)
        widgets.button(self, x, contentY + 4, w, "Machine (In-World)", { selected = not isCraft }, function()
            wiz.recipeType = "machine"
        end)
        
    elseif wiz.step == 2 then
        widgets.text(x, contentY, "Select Source Chest:", colors.white, colors.black)
        
        local chests = {}
        for _, name in ipairs(peripheral.getNames()) do
            local ok, p = pcall(peripheral.wrap, name)
            if ok and p and type(p.list) == "function" and type(p.size) == "function" then
                table.insert(chests, name)
            end
        end
        table.sort(chests)
        
        if (not wiz.gridChest or wiz.gridChest == "") and self.configData.grid_chest then
            wiz.gridChest = self.configData.grid_chest
        end
        
        local rows = {}
        for idx, name in ipairs(chests) do
            local isSelected = (wiz.gridChest == name)
            if isSelected then wiz.selected = idx end
            table.insert(rows, (isSelected and "[*] " or "[ ] ") .. name)
        end
        
        local listState = { scroll = wiz.scroll, selected = wiz.selected }
        widgets.scrollList(self, x, contentY + 2, w, contentH - 2, rows, listState, function(idx)
            wiz.gridChest = chests[idx]
            wiz.selected = idx
        end)
        wiz.scroll = listState.scroll
        wiz.selected = listState.selected
        
    elseif wiz.step == 3 then
        if wiz.recipeType == "crafting" then
            widgets.text(x, contentY, "Select Worker Turtle:", colors.white, colors.black)
            
            local workers = disp and disp:workerList() or {}
            local rows = {}
            for idx, wInfo in ipairs(workers) do
                local isSelected = (wiz.worker == wInfo.id)
                if isSelected then wiz.selected = idx end
                table.insert(rows, (isSelected and "[*] " or "[ ] ") .. "Worker #" .. wInfo.id)
            end
            
            if #workers == 0 then
                widgets.text(x, contentY + 2, "No turtles connected.", colors.red, colors.black)
            else
                local listState = { scroll = wiz.scroll, selected = wiz.selected }
                widgets.scrollList(self, x, contentY + 2, w, contentH - 2, rows, listState, function(idx)
                    wiz.worker = workers[idx].id
                    wiz.selected = idx
                end)
                wiz.scroll = listState.scroll
                wiz.selected = listState.selected
            end
        else
            widgets.text(x, contentY, "Select Machine:", colors.white, colors.black)
            
            local machinesList = self.deps.machines and self.deps.machines.names or {}
            local rows = {}
            for idx, name in ipairs(machinesList) do
                local isSelected = (wiz.machine == name)
                if isSelected then wiz.selected = idx end
                table.insert(rows, (isSelected and "[*] " or "[ ] ") .. name)
            end
            
            if #machinesList == 0 then
                widgets.text(x, contentY + 2, "No machines registered.", colors.red, colors.black)
            else
                local listState = { scroll = wiz.scroll, selected = wiz.selected }
                widgets.scrollList(self, x, contentY + 2, w, contentH - 2, rows, listState, function(idx)
                    wiz.machine = machinesList[idx]
                    wiz.selected = idx
                end)
                wiz.scroll = listState.scroll
                wiz.selected = listState.selected
            end
        end
        
    elseif wiz.step == 4 then
        widgets.text(x, contentY, "Select Learn Mode:", colors.white, colors.black)
        
        local isStatic = wiz.learnType == "static"
        widgets.button(self, x, contentY + 2, w, "Static read (Chest)", { selected = isStatic }, function()
            wiz.learnType = "static"
        end)
        widgets.button(self, x, contentY + 4, w, "Active run (Process)", { selected = not isStatic }, function()
            wiz.learnType = "active"
        end)
        
    elseif wiz.step == 5 then
        widgets.text(x, contentY, "Select Active Run Option:", colors.white, colors.black)
        
        local isAuto = wiz.activeOption == "automated"
        widgets.button(self, x, contentY + 2, w, "Automated (Auto-Feed)", { selected = isAuto }, function()
            wiz.activeOption = "automated"
        end)
        widgets.button(self, x, contentY + 4, w, "Manual (Direct Run)", { selected = not isAuto }, function()
            wiz.activeOption = "manual"
        end)
        
    elseif wiz.step == 6 then
        widgets.text(x, contentY, "Select Input Fluids:", colors.white, colors.black)
        
        local isItemsOnly = wiz.manualFluidOption == "items_only"
        widgets.button(self, x, contentY + 2, w, "Items Only", { selected = isItemsOnly }, function()
            wiz.manualFluidOption = "items_only"
        end)
        widgets.button(self, x, contentY + 4, w, "Items & Fluids", { selected = not isItemsOnly }, function()
            wiz.manualFluidOption = "items_fluids"
        end)
        
    elseif wiz.step == 7 then
        widgets.text(x, contentY, "Select fluids and amounts:", colors.white, colors.black)
        
        if not wiz.danksList or #wiz.danksList == 0 then
            local danks = {}
            local assignedSet = {}
            for _, dk in ipairs(self.deps.fluids.danks or {}) do
                table.insert(danks, { periph = dk.periph, fluid = dk.fluid, target = dk.target })
                assignedSet[dk.periph] = true
            end
            for _, name in ipairs(peripheral.getNames()) do
                if not assignedSet[name] then
                    local p = peripheral.wrap(name)
                    if p and (peripheral.hasType(name, "fluid_storage") or type(p.tanks) == "function") then
                        local fluidName = "any"
                        local ok, tks = pcall(p.tanks)
                        if ok and tks and tks[1] then
                            fluidName = tks[1].name or tks[1].fluid or "any"
                        end
                        table.insert(danks, { periph = name, fluid = fluidName, target = 16000 })
                    end
                end
            end
            wiz.danksList = danks
        end
        
        local listY = contentY + 1
        local listH = contentH - 2
        local yCurr = listY
        for _, dk in ipairs(wiz.danksList) do
            if yCurr < listY + listH then
                local isSelected = (wiz.manualFluids[dk.periph] ~= nil)
                local val = wiz.manualFluids[dk.periph] or 1000
                
                widgets.button(self, x, yCurr, 3, isSelected and "*" or " ", { selected = isSelected }, function()
                    if isSelected then
                        wiz.manualFluids[dk.periph] = nil
                    else
                        wiz.manualFluids[dk.periph] = 1000
                    end
                end)
                
                widgets.text(x + 4, yCurr, widgets.clip(util.formatId(dk.fluid), w - 16), colors.white, colors.black)
                
                if isSelected then
                    widgets.stepper(self, x + w - 11, yCurr, 11, val, function(delta)
                        wiz.manualFluids[dk.periph] = math.max(1000, val + delta * 1000)
                    end)
                end
                yCurr = yCurr + 1
            end
        end
        
    elseif wiz.step == 8 then
        widgets.text(x, contentY, "Processing manual run...", colors.yellow, colors.black)
        widgets.text(x, contentY + 2, "Please let the machine complete", colors.white, colors.black)
        widgets.text(x, contentY + 3, "1 operation cycle.", colors.white, colors.black)
        widgets.text(x, contentY + 5, "Press Next to take snapshot.", colors.green, colors.black)
        
    elseif wiz.step == 9 then
        widgets.text(x, contentY, "Review changes:", colors.cyan, colors.black)
        
        local yLine = contentY + 1
        widgets.text(x, yLine, "Inputs consumed:", colors.yellow, colors.black)
        yLine = yLine + 1
        for _, it in ipairs(wiz.consumedItems or {}) do
            if yLine < yBot - 1 then
                widgets.text(x + 1, yLine, string.format("- %s x%d", widgets.clip(util.formatId(it.id), w - 8), it.count), colors.lightGray, colors.black)
                yLine = yLine + 1
            end
        end
        for _, fl in ipairs(wiz.consumedFluids or {}) do
            if yLine < yBot - 1 then
                widgets.text(x + 1, yLine, string.format("- %s %dmB", widgets.clip(util.formatId(fl.fluid), w - 8), fl.mb), colors.lightGray, colors.black)
                yLine = yLine + 1
            end
        end
        
        widgets.text(x, yLine, "Outputs produced:", colors.yellow, colors.black)
        yLine = yLine + 1
        for _, it in ipairs(wiz.producedItems or {}) do
            if yLine < yBot - 1 then
                widgets.text(x + 1, yLine, string.format("- %s x%d", widgets.clip(util.formatId(it.id), w - 8), it.count), colors.lightGray, colors.black)
                yLine = yLine + 1
            end
        end
        for _, fl in ipairs(wiz.producedFluids or {}) do
            if yLine < yBot - 1 then
                widgets.text(x + 1, yLine, string.format("- %s %dmB", widgets.clip(util.formatId(fl.fluid), w - 8), fl.mb), colors.lightGray, colors.black)
                yLine = yLine + 1
            end
        end
    end
    
    local showNext = true
    if wiz.step == 3 and wiz.recipeType == "crafting" and (not wiz.worker) then
        showNext = false
    end
    if wiz.step == 3 and wiz.recipeType == "machine" and (not wiz.machine) then
        showNext = false
    end
    
    local nextLabel = "Next"
    if wiz.step == 9 then
        nextLabel = "Save"
    end
    
    widgets.button(self, x, yBot, 8, "Back", { kind = "normal" }, function()
        if wiz.step == 1 then
            st.mode = "list"
            st.wizard = nil
        elseif wiz.step == 3 and wiz.recipeType == "machine" and wiz.machine then
            st.mode = "list"
            st.wizard = nil
        else
            wiz.step = wiz.step - 1
            if wiz.step == 3 and wiz.recipeType == "crafting" then
            elseif wiz.step == 5 and wiz.learnType == "static" then
                wiz.step = 4
            elseif wiz.step == 6 and wiz.activeOption == "automated" then
                wiz.step = 5
            elseif wiz.step == 7 and wiz.manualFluidOption == "items_only" then
                wiz.step = 6
            end
            wiz.selected = 1
            wiz.scroll = 0
        end
    end)
    
    widgets.button(self, x + 9, yBot, 8, "Cancel", { kind = "danger" }, function()
        if wiz.step == 8 then
            self.deps.machines:collect(wiz.machine, { itemInput = {}, fluidOutput = {} })
        end
        st.mode = "list"
        st.wizard = nil
    end)
    
    if showNext then
        widgets.button(self, x + w - 8, yBot, 8, nextLabel, { kind = "active" }, function()
            if wiz.step == 1 then
                wiz.step = 2
                wiz.selected = 1
                wiz.scroll = 0
                
            elseif wiz.step == 2 then
                wiz.step = 3
                wiz.selected = 1
                wiz.scroll = 0
                
            elseif wiz.step == 3 then
                if wiz.recipeType == "crafting" then
                    self:showToast("Auto-learning...", "info")
                    local ok, recipe = recipes:activeLearnCraft(wiz.gridChest, wiz.worker, disp)
                    if ok then
                        self:showToast("Saved: " .. self.deps.lang.display(recipe.id), "success")
                        self:addLog("Auto-learned recipe: " .. recipe.id)
                        st.mode = "list"
                        st.wizard = nil
                    else
                        self:showToast(tostring(recipe), "danger")
                    end
                else
                    wiz.step = 4
                    wiz.selected = 1
                    wiz.scroll = 0
                end
                
            elseif wiz.step == 4 then
                if wiz.learnType == "static" then
                    self:showToast("Reading chest...", "info")
                    local targetMachine = wiz.machine
                    local ptype = wiz.machine and peripheral.getType(wiz.machine)
                    local isChestType = false
                    local storageKeywords = { "chest", "barrel", "vault", "shulker", "crate", "storage", "drawer", "cabinet", "box", "bag", "dank", "safe", "pocket" }
                    if ptype then
                        local plower = ptype:lower()
                        for _, kw in ipairs(storageKeywords) do
                            if plower:find(kw) then isChestType = true; break end
                        end
                    end
                    if ptype and not isChestType then
                        targetMachine = ptype
                    end
                    local ok, recipe = recipes:learnFromStorage(wiz.gridChest, "machine", targetMachine)
                    if ok then
                        self:showToast("Saved: " .. self.deps.lang.display(recipe.id), "success")
                        self:addLog("Static machine recipe learned: " .. recipe.id)
                        st.mode = "list"
                        st.wizard = nil
                    else
                        self:showToast(tostring(recipe), "danger")
                    end
                else
                    wiz.step = 5
                    wiz.selected = 1
                    wiz.scroll = 0
                end
                
            elseif wiz.step == 5 then
                if wiz.activeOption == "automated" then
                    self:showToast("Machine processing...", "info")
                    local ok, recipe = recipes:activeLearnMachine(wiz.gridChest, wiz.machine)
                    if ok then
                        self:showToast("Smelt Saved: " .. self.deps.lang.display(recipe.id), "success")
                        self:addLog("Machine recipe learned: " .. recipe.id)
                        st.mode = "list"
                        st.wizard = nil
                    else
                        self:showToast(tostring(recipe), "danger")
                    end
                else
                    wiz.step = 6
                    wiz.selected = 1
                    wiz.scroll = 0
                end
                
            elseif wiz.step == 6 then
                if wiz.manualFluidOption == "items_only" then
                    local ok = self:wizardStartManualRun()
                    if ok then
                        wiz.step = 8
                    end
                else
                    wiz.step = 7
                    wiz.selected = 1
                    wiz.scroll = 0
                end
                
            elseif wiz.step == 7 then
                local ok = self:wizardStartManualRun()
                if ok then
                    wiz.step = 8
                end
                
            elseif wiz.step == 8 then
                local after = recipes.snapshotAll(wiz.machine, wiz.gridChest, self.deps.storage, self.deps.fluids)
                local stationAfter = recipes.snapshotStation(wiz.machine)
                local before = wiz.snapshotBefore
                local stationBefore = wiz.stationBefore
                
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
                
                wiz.consumedItems = consumedItems
                wiz.consumedFluids = consumedFluids
                wiz.producedItems = producedItems
                wiz.producedFluids = producedFluids
                wiz.step = 9
                
            elseif wiz.step == 9 then
                local recId = nil
                local recName = nil
                local outYield = 1
                if #wiz.producedItems > 0 then
                    recId = wiz.producedItems[1].id
                    recName = self.deps.lang.display(recId)
                    outYield = wiz.producedItems[1].count
                elseif #wiz.producedFluids > 0 then
                    recId = "fluid:" .. wiz.producedFluids[1].fluid
                    recName = util.formatId(wiz.producedFluids[1].fluid)
                    outYield = 1
                end
                
                if not recId then
                    self:showToast("No output found!", "danger")
                    return
                end
                
                local targetMachine = wiz.machine
                local ptype = wiz.machine and peripheral.getType(wiz.machine)
                local isChestType = false
                local storageKeywords = { "chest", "barrel", "vault", "shulker", "crate", "storage", "drawer", "cabinet", "box", "bag", "dank", "safe", "pocket" }
                if ptype then
                    local plower = ptype:lower()
                    for _, kw in ipairs(storageKeywords) do
                        if plower:find(kw) then isChestType = true; break end
                    end
                end
                if ptype and not isChestType then
                    targetMachine = ptype
                end

                local recipe = {
                    id = recId,
                    name = recName,
                    type = "station",
                    station = targetMachine or "any",
                    itemInput = wiz.consumedItems,
                    fluidInput = wiz.consumedFluids,
                    itemOutput = wiz.producedItems,
                    fluidOutput = wiz.producedFluids,
                    output = outYield
                }
                recipes:add(recipe)
                self:showToast("Saved: " .. recName, "success")
                st.mode = "list"
                st.wizard = nil
            end
        end)
    end
end

function ui:renderRecipes(yTop, yBot, w)
    local st = self.state.recipes
    local recipes = self.deps.recipes
    local list = recipes:all()
    local h = yBot - yTop + 1
    
    local modsSet = { all = true }
    for _, r in ipairs(list) do
        local mod = r.id:match("^([^:]+):") or "minecraft"
        modsSet[mod] = true
    end
    local mods = { "all" }
    for m in pairs(modsSet) do
        if m ~= "all" then
            table.insert(mods, m)
        end
    end
    table.sort(mods, function(a, b)
        if a == "all" then return true end
        if b == "all" then return false end
        return a < b
    end)
    
    st.selectedMod = st.selectedMod or "all"
    
    local filteredList = {}
    for _, r in ipairs(list) do
        local mod = r.id:match("^([^:]+):") or "minecraft"
        if st.selectedMod == "all" or mod == st.selectedMod then
            table.insert(filteredList, r)
        end
    end
    
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
    
    if st.mode == "confirm_delete" then
        local r = filteredList[st.selected]
        if not r then st.mode = "list"; return end
        
        local bodyFn = function(cx, cy, cw, ch)
            widgets.text(cx, cy + 1, "Delete this recipe?", colors.white, colors.black)
            widgets.text(cx, cy + 2, widgets.clip(r.id, cw - 4), colors.yellow, colors.black)
        end
        local buttons = {
            {
                label = "Delete",
                kind = "danger",
                action = function()
                    recipes:remove(r.id)
                    self:showToast("Deleted recipe", "success")
                    st.selected = math.max(1, st.selected - 1)
                    st.mode = "list"
                end
            },
            {
                label = "Cancel",
                kind = "normal",
                action = function()
                    st.mode = "list"
                end
            }
        }
        widgets.dialog(self, "Confirm Delete", bodyFn, buttons)
        return
    end
    
    local isSplit = (w >= 34)
    local startXLeft = 1
    local wLeft = w
    local startX = 1
    local wRight = 0
    local sepX = 0
    
    if isSplit then
        local maxLeft = 24
        local maxRight = 32
        local totalSplitW = maxLeft + 1 + maxRight
        if w > totalSplitW then
            startXLeft = math.floor((w - totalSplitW) / 2) + 1
            wLeft = maxLeft
        else
            wLeft = math.floor(w * 0.45)
        end
        sepX = startXLeft + wLeft
        startX = sepX + 1
        wRight = w - sepX
        if wRight > maxRight then
            wRight = maxRight
        end
    end
    
    if st.mode == "learn_wizard" then
        if isSplit then
            widgets.clearArea(startXLeft, yTop, wLeft, h)
            widgets.text(startXLeft, yTop, "Recipes", colors.cyan, colors.black)
            widgets.center(math.floor((yTop + yBot) / 2), "Wizard Active", colors.gray)
            
            term.setBackgroundColor(colors.black)
            for cy = yTop, yBot do
                term.setCursorPos(sepX, cy)
                term.setTextColor(colors.gray)
                term.write("|")
            end
            
            widgets.clearArea(startX, yTop, wRight, h)
            self:renderLearnWizard(startX, yTop, wRight, h, yBot)
        else
            widgets.clearArea(1, yTop, w, h)
            self:renderLearnWizard(1, yTop, w, h, yBot)
        end
        return
    end
    
    if isSplit then
        local modsSegments = {}
        for _, m in ipairs(mods) do
            table.insert(modsSegments, { id = m, title = prettyModName(m) })
        end
        
        local segY = widgets.segmented(self, yTop, modsSegments, st.selectedMod, function(id)
            st.selectedMod = id
            st.selected = 1
            st.scroll = 0
        end)
        
        local listY = segY + 1
        local listH = yBot - listY - 1
        
        local rows = {}
        for _, r in ipairs(filteredList) do
            local name = self.deps.lang.display(r.id, r.name)
            local typeStr = r.type == "machine" and "M" or (r.type == "shaped" and "S" or "L")
            table.insert(rows, string.format("[%s] %s", typeStr, name))
        end
        
        if #rows == 0 then
            widgets.clearArea(startXLeft, listY, wLeft, listH)
            widgets.center(math.floor((listY + listY + listH) / 2), "No recipes configured", colors.gray)
        else
            widgets.scrollList(self, startXLeft, listY, wLeft, listH, rows, st, function(idx)
                st.selected = idx
            end)
        end
        
        local btnY = yBot
        widgets.button(self, startXLeft, btnY, math.floor(wLeft / 2) - 1, "+ Learn", { kind = "active" }, function()
            self:startLearnWizard()
        end)
        widgets.button(self, startXLeft + math.floor(wLeft / 2), btnY, wLeft - math.floor(wLeft / 2), "Delete", { kind = "danger" }, function()
            local r = filteredList[st.selected]
            if r then
                st.mode = "confirm_delete"
            else
                self:showToast("No recipe selected", "danger")
            end
        end)
        
        term.setBackgroundColor(colors.black)
        for cy = yTop, yBot do
            term.setCursorPos(sepX, cy)
            term.setTextColor(colors.gray)
            term.write("|")
        end
        
        widgets.clearArea(startX, yTop, wRight, h)
        local r = filteredList[st.selected]
        if not r then
            st.selected = 1
            r = filteredList[1]
        end
        
        if r then
            local displayName = self.deps.lang.display(r.id, r.name)
            widgets.text(startX, yTop, "Recipe: " .. widgets.clip(displayName, wRight - 8), colors.white, colors.black)
            widgets.text(startX, yTop + 1, "Type: " .. r.type, colors.lightGray, colors.black)
            widgets.text(startX, yTop + 2, "Output: " .. (r.output or 1), colors.lightGray, colors.black)
            if r.avgTime then
                widgets.text(startX, yTop + 3, "Avg Time: " .. string.format("%.1fs", r.avgTime), colors.lightGray, colors.black)
            end
            local mName = r.id:match("^([^:]+):") or "minecraft"
            widgets.text(startX, yTop + 4, "Mod: " .. prettyModName(mName), colors.lightGray, colors.black)
            
            widgets.text(startX, yTop + 5, "Ingredients / Fluids:", colors.cyan, colors.black)
            local ings = recipes.ingredientsOf(r)
            local yLine = yTop + 6
            for _, ing in ipairs(ings) do
                if yLine <= yBot then
                    widgets.text(startX, yLine, string.format(" - %s x%d", widgets.clip(self.deps.lang.display(ing.id), wRight - 8), ing.count), colors.lightGray, colors.black)
                    yLine = yLine + 1
                end
            end
            local fls = recipes.fluidsOf(r)
            for _, fl in ipairs(fls) do
                if yLine <= yBot then
                    widgets.text(startX, yLine, string.format(" - %s %d mB", widgets.clip(util.formatId(fl.fluid), wRight - 12), fl.mb), colors.lightGray, colors.black)
                    yLine = yLine + 1
                end
            end
        else
            widgets.center(math.floor((yTop + yBot) / 2), "No recipe selected", colors.gray)
        end
    else
        local modsSegments = {}
        for _, m in ipairs(mods) do
            table.insert(modsSegments, { id = m, title = prettyModName(m) })
        end
        
        local segY = widgets.segmented(self, yTop, modsSegments, st.selectedMod, function(id)
            st.selectedMod = id
            st.selected = 1
            st.scroll = 0
        end)
        
        local listY = segY + 1
        local listH = yBot - listY - 1
        
        local rows = {}
        for _, r in ipairs(filteredList) do
            local name = self.deps.lang.display(r.id, r.name)
            table.insert(rows, name)
        end
        
        if #rows == 0 then
            widgets.clearArea(1, listY, w, listH)
            widgets.center(math.floor((listY + listY + listH) / 2), "No recipes configured", colors.gray)
        else
            widgets.scrollList(self, 1, listY, w, listH, rows, st, function(idx)
                st.selected = idx
            end)
        end
        
        local btnY = yBot
        widgets.button(self, 1, btnY, math.floor(w / 2) - 1, "+ Learn", { kind = "active" }, function()
            self:startLearnWizard()
        end)
        widgets.button(self, math.floor(w / 2) + 1, btnY, w - math.floor(w / 2), "Delete", { kind = "danger" }, function()
            local r = filteredList[st.selected]
            if r then
                st.mode = "confirm_delete"
            else
                self:showToast("No recipe selected", "danger")
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
function ui:openPeripheralPicker(title, filterFn, onSelect, currentVal, infoText)
    local st = self.state.settings
    st.pickerState = { scroll = 0, selected = 1 }
    st.mode = "picker"
    
    local list = {}
    for _, name in ipairs(peripheral.getNames()) do
        if filterFn(name) then
            table.insert(list, name)
        end
    end
    table.sort(list)
    table.insert(list, 1, "None")
    
    -- Highlight current selection by default
    local selectedIdx = 1
    if currentVal then
        for idx, name in ipairs(list) do
            if name == currentVal then
                selectedIdx = idx
                break
            end
        end
    end
    st.pickerState.selected = selectedIdx
    
    st.picker = {
        title = title,
        list = list,
        onSelect = onSelect,
        current = currentVal or "None",
        info = infoText
    }
end

function ui:renderSettings(yTop, yBot, w)
    local st = self.state.settings
    local h = yBot - yTop + 1
    
    st.mode = st.mode or "list"
    st.settingsState = st.settingsState or { scroll = 0, selected = 1 }
    
    if st.mode == "picker" and st.picker then
        local bodyFn = function(cx, cy, cw, ch)
            local yOffset = 0
            if st.picker.current then
                widgets.text(cx, cy, "Current: " .. tostring(st.picker.current), colors.yellow, colors.black)
                yOffset = yOffset + 1
            end
            if st.picker.info then
                widgets.text(cx, cy + yOffset, widgets.clip(st.picker.info, cw), colors.gray, colors.black)
                yOffset = yOffset + 1
            end
            
            local rows = {}
            for idx, name in ipairs(st.picker.list) do
                local isSel = (st.pickerState.selected == idx)
                table.insert(rows, (isSel and "[*] " or "[ ] ") .. name)
            end
            widgets.scrollList(self, cx, cy + yOffset, cw, ch - yOffset, rows, st.pickerState, function(idx)
                st.pickerState.selected = idx
            end)
        end
        
        local buttons = {
            {
                label = "Select",
                kind = "active",
                action = function()
                    local val = st.picker.list[st.pickerState.selected]
                    if val == "None" then val = nil end
                    st.picker.onSelect(val)
                    st.mode = "list"
                    st.picker = nil
                    st.pickerState = nil
                end
            },
            {
                label = "Cancel",
                kind = "danger",
                action = function()
                    st.mode = "list"
                    st.picker = nil
                    st.pickerState = nil
                end
            }
        }
        widgets.dialog(self, st.picker.title, bodyFn, buttons)
        return
    end
    
    local rows = {}
    table.insert(rows, "Grid Chest: " .. tostring(self.configData.grid_chest or "None"))
    table.insert(rows, "Recipe Input Chest: " .. tostring(self.configData.recipe_input_chest or "None"))
    table.insert(rows, "Grid Dank: " .. tostring(self.configData.grid_dank or "None"))
    table.insert(rows, "Default Import Chest: " .. tostring(self.configData.default_import or "None"))
    table.insert(rows, "--- Connected Peripherals ---")
    
    local names = peripheral.getNames()
    table.sort(names)
    for _, name in ipairs(names) do
        local ptype = peripheral.getType(name) or "unknown"
        local role = self.configData.manual_roles and self.configData.manual_roles[name] or "auto"
        table.insert(rows, string.format("%s: %s (%s)", name, role:upper(), ptype))
    end
    
    widgets.scrollList(self, 1, yTop, w, h, rows, st.settingsState, function(idx)
        st.settingsState.selected = idx
        if idx == 1 then
            self:openPeripheralPicker("Select Grid Chest", function(name)
                local ok, p = pcall(peripheral.wrap, name)
                return ok and p and type(p.list) == "function" and type(p.size) == "function"
            end, function(val)
                self.configData.grid_chest = val
                config.save(self.configData)
                self:addLog("Default grid chest: " .. tostring(val))
                self:showToast("Saved grid chest", "success")
                
                local resolved = config.resolve(self.configData)
                self.deps.storage.names = resolved.storage or {}
                self.deps.storage:scan()
                self.deps.fluids:resolvePool(resolved)
                self.deps.fluids:scan()
                self.deps.machines:refreshStations(resolved)
                self:buildTabs()
            end, self.configData.grid_chest)
        elseif idx == 2 then
            self:openPeripheralPicker("Select Input Chest", function(name)
                local ok, p = pcall(peripheral.wrap, name)
                return ok and p and type(p.list) == "function" and type(p.size) == "function"
            end, function(val)
                self.configData.recipe_input_chest = val
                config.save(self.configData)
                self:addLog("Recipe input chest: " .. tostring(val))
                self:showToast("Saved input chest", "success")
            end, self.configData.recipe_input_chest)
        elseif idx == 3 then
            self:openPeripheralPicker("Select Grid Dank", function(name)
                local ok, p = pcall(peripheral.wrap, name)
                return ok and p and (peripheral.hasType(name, "fluid_storage") or type(p.tanks) == "function")
            end, function(val)
                self.configData.grid_dank = val
                config.save(self.configData)
                self:addLog("Default dank: " .. tostring(val))
                self:showToast("Saved default dank", "success")
                
                local resolved = config.resolve(self.configData)
                self.deps.storage.names = resolved.storage or {}
                self.deps.storage:scan()
                self.deps.fluids:resolvePool(resolved)
                self.deps.fluids:scan()
                self.deps.machines:refreshStations(resolved)
                self:buildTabs()
            end, self.configData.grid_dank)
        elseif idx == 4 then
            self:openPeripheralPicker("Select Import Chest", function(name)
                local ok, p = pcall(peripheral.wrap, name)
                return ok and p and type(p.list) == "function" and type(p.size) == "function"
            end, function(val)
                self.configData.default_import = val
                config.save(self.configData)
                self:addLog("Default import chest: " .. tostring(val))
                self:showToast("Import chest set: " .. tostring(val or "None"), "success")
                
                local resolved = config.resolve(self.configData)
                self.deps.storage.names = resolved.storage or {}
                self.deps.storage:scan()
                self.deps.fluids:resolvePool(resolved)
                self.deps.fluids:scan()
                self.deps.machines:refreshStations(resolved)
                self:buildTabs()
            end, self.configData.default_import, "Drop items here, then press Import on Storage tab.")
        elseif idx >= 6 then
            local pName = names[idx - 5]
            if pName then
                local currentRole = self.configData.manual_roles and self.configData.manual_roles[pName] or "auto"
                local roles = { "auto", "storage", "machine", "ignored" }
                
                local pickerState = { scroll = 0, selected = 1 }
                for rIdx, r in ipairs(roles) do
                    if r == currentRole then
                        pickerState.selected = rIdx
                    end
                end
                
                st.pickerState = pickerState
                st.mode = "picker"
                st.picker = {
                    title = "Role for " .. pName,
                    list = roles,
                    current = currentRole,
                    info = "Choose role override for this peripheral.",
                    onSelect = function(val)
                        self.configData.manual_roles = self.configData.manual_roles or {}
                        self.configData.manual_roles[pName] = val
                        config.save(self.configData)
                        self:addLog("Set role of " .. pName .. " to " .. tostring(val))
                        self:showToast("Saved role override", "success")
                        
                        local resolved = config.resolve(self.configData)
                        self.deps.storage.names = resolved.storage or {}
                        self.deps.storage:scan()
                        self.deps.fluids:resolvePool(resolved)
                        self.deps.fluids:scan()
                        self.deps.machines:refreshStations(resolved)
                        self:buildTabs()
                    end
                }
            end
        end
    end)
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
