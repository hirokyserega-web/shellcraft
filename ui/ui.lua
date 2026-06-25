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
        { id = "craft",   title = "Крафт" },
        { id = "storage", title = "Хранилище" },
    }
    if self.deps.machines and self.deps.machines:count() > 0 then
        table.insert(self.tabs, { id = "machines", title = "Механизмы" })
    end
    table.insert(self.tabs, { id = "recipes", title = "Рецепты" })
    table.insert(self.tabs, { id = "log",     title = "Лог" })
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
    local x = 1
    for _, t in ipairs(self.tabs) do
        local label = " " .. t.title .. " "
        local active = (t.id == self.activeTab)
        local bg = active and colors.blue or colors.gray
        local fg = active and colors.white or colors.lightGray
        term.setBackgroundColor(bg)
        term.setTextColor(fg)
        term.setCursorPos(x, y)
        term.write(label)
        self.tabBounds[#self.tabBounds + 1] = { x = x, y = y, w = #label, id = t.id }
        x = x + #label
    end
    -- добить строку
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    if x <= w then
        term.setCursorPos(x, y)
        term.write(string.rep(" ", w - x + 1))
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

    -- Заголовок
    widgets.center(1, " ShellCraft ", colors.yellow, colors.black)

    -- Статус справа в заголовке
    local status = ""
    if self.deps.dispatcher then
        local free = self.deps.dispatcher:freeCount()
        local total = 0
        for _ in pairs(self.deps.dispatcher.workers) do total = total + 1 end
        local active = #self.deps.dispatcher:activeTasks()
        status = string.format("В:%d/%d З:%d", free, total, active)
    end
    term.setTextColor(colors.lightGray)
    term.setCursorPos(math.max(1, w - #status), 1)
    term.write(status)

    -- Вкладки
    self:buildTabs()
    self:drawTabs(2)

    -- Контент
    local tab = self.activeTab
    if tab == "craft" then self:renderCraft(3, h - 1, w)
    elseif tab == "storage" then self:renderStorage(3, h - 1, w)
    elseif tab == "machines" then self:renderMachines(3, h - 1, w)
    elseif tab == "recipes" then self:renderRecipes(3, h - 1, w)
    elseif tab == "log" then self:renderLog(3, h - 1, w)
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
        if m == "list" then return "Тап — выбрать рецепт. Q — выход." end
        return "Тап по цифрам/ОК. Отмена — назад."
    elseif tab == "storage" then return "Прокрутка тапом по краям. Q — выход."
    elseif tab == "machines" then return "Тап — обновить статус."
    elseif tab == "recipes" then return "Тап — выбрать. [+Обучить] — новый рецепт."
    elseif tab == "log" then return "Прокрутка тапом по краям."
    end
    return ""
end

----------------------------------------------------------------
-- Вкладка КРАФТ
----------------------------------------------------------------
function ui:renderCraft(yTop, yBot, w)
    local st = self.state.craft
    local recipes = self.deps.recipes
    local list = recipes:list()
    if #list == 0 then
        widgets.center(math.floor((yTop + yBot) / 2), "Нет рецептов. Перейдите во вкладку «Рецепты».", colors.red)
        return
    end
    if st.mode == "list" then
        -- Список рецептов
        local items = {}
        for _, r in ipairs(list) do
            local name = self.deps.lang.display(r.id, r.name)
            local have = self.deps.storage:count(r.id)
            local type = r.type == "machine" and " [М]" or ""
            local tStr = ""
            if r.avgTime then
                tStr = string.format(" ~%.0fs", r.avgTime * (r.crafts or 1))
            end
            table.insert(items, string.format("%-22s x%-3d%s есть:%d%s", name:sub(1, 22), r.output or 1, type, have, tStr))
        end
        local h = yBot - yTop + 1
        widgets.list(1, yTop, w, h, items, st.scroll, st.selected)
        -- Кнопки прокрутки
        self:button(w - 4, yTop, 4, " Вверх ", false, function() st.scroll = math.max(0, st.scroll - (h - 2)) end)
        self:button(w - 4, yBot, 4, " Вниз ", false, function()
            if st.scroll + h < #items then st.scroll = st.scroll + (h - 2) end
        end)
    elseif st.mode == "quantity" then
        local r = list[st.selected]
        if not r then st.mode = "list"; return end
        widgets.box(2, yTop, w - 4, yBot - yTop + 1, "Заказ крафта", "double")
        local name = self.deps.lang.display(r.id, r.name)
        widgets.text(4, yTop + 2, "Предмет: " .. name, colors.white)
        widgets.text(4, yTop + 3, string.format("Выход за крафт: %d", r.output or 1), colors.lightGray)
        local inStore = self.deps.storage:count(r.id)
        widgets.text(4, yTop + 4, "В хранилище: " .. inStore, colors.lightGray)
        -- Количество
        widgets.center(yTop + 6, "Количество: " .. st.qty, colors.yellow, colors.black)
        -- Калькулятор потребности + оценка времени
        local qty = tonumber(st.qty) or 0
        if qty > 0 then
            local tree = planner.buildTree(r.id, qty, recipes, self.deps.storage)
            local bom = planner.calculateBOM(tree)
            local estTime, approx = planner.estimateTime(tree, self:workersCount(), self.deps.recipes)
            widgets.text(4, yTop + 5, "Оценка: " .. planner.formatDuration(estTime, approx), approx and colors.yellow or colors.green)
            local y = yTop + 8
            widgets.text(4, y, "Потребуется:", colors.cyan); y = y + 1
            local any = false
            for _, info in ipairs(bom) do
                if y < yBot - 2 then
                    local have = self.deps.storage:count(info.id)
                    local col = have >= info.count and colors.green or colors.red
                    widgets.text(5, y, string.format("  %-20s надо:%d есть:%d",
                        self.deps.lang.display(info.id):sub(1, 20), info.count, have), col)
                    y = y + 1
                    any = true
                end
            end
            if not any then
                widgets.text(5, y, "  (базовых ресурсов не требует)", colors.lightGray)
            end
        end
        -- Кнопки количества
        local bx = 4
        self:button(bx, yBot - 1, 5, " +1 ", false, function() st.qty = tostring((tonumber(st.qty) or 0) + 1) end)
        self:button(bx + 6, yBot - 1, 6, " +10 ", false, function() st.qty = tostring((tonumber(st.qty) or 0) + 10) end)
        self:button(bx + 13, yBot - 1, 6, " +64 ", false, function() st.qty = tostring((tonumber(st.qty) or 0) + 64) end)
        self:button(bx + 20, yBot - 1, 5, " -1 ", false, function() st.qty = tostring(math.max(0, (tonumber(st.qty) or 0) - 1)) end)
        self:button(bx + 26, yBot - 1, 7, " Сброс ", false, function() st.qty = "1" end)
        -- ОК / Отмена
        self:button(w - 18, yBot - 1, 7, " ОК ", true, function()
            local n = tonumber(st.qty) or 0
            if n > 0 then
                local tree = planner.buildTree(r.id, n, recipes, self.deps.storage)
                local estTime, approx = planner.estimateTime(tree, self:workersCount(), self.deps.recipes)
                local ids, err = self.deps.dispatcher:requestCraft(r.id, n, recipes)
                if ids then
                    self:addLog("Заказ: " .. name .. " x" .. n .. " (" .. #ids .. " шагов, " .. planner.formatDuration(estTime, approx) .. ")")
                    self.state.craft.active = {
                        total = #ids, done = 0, failed = 0,
                        etaTotal = estTime, started = os.epoch("utc"),
                    }
                else
                    self:addLog("Ошибка заказа: " .. tostring(err))
                end
            end
            st.mode = "list"; st.qty = "1"
        end, { bgActive = colors.green })
        self:button(w - 9, yBot - 1, 7, " Отмена ", false, function()
            st.mode = "list"; st.qty = "1"
        end, { bg = colors.red })
    end
end

----------------------------------------------------------------
-- Вкладка ХРАНИЛИЩЕ
----------------------------------------------------------------
function ui:renderStorage(yTop, yBot, w)
    local st = self.state.storage
    local items = self.deps.storage:items()
    -- Поле поиска (верхняя строка контента)
    widgets.text(1, yTop, "Поиск: " .. st.search .. "_", colors.yellow)
    local search = st.search:lower()
    -- Фильтрация
    local filtered = {}
    for _, it in ipairs(items) do
        local name = self.deps.lang.display(it.id):lower()
        if search == "" or name:find(search, 1, true) or it.id:lower():find(search, 1, true) then
            table.insert(filtered, it)
        end
    end
    local h = yBot - yTop + 1 - 1  -- минус строка поиска
    local rows = {}
    for _, it in ipairs(filtered) do
        local name = self.deps.lang.display(it.id)
        table.insert(rows, string.format("%-26s x%d", name:sub(1, 26), it.count))
    end
    if #rows == 0 then
        widgets.center(math.floor((yTop + yBot) / 2), "Ничего не найдено", colors.gray)
        return
    end
    widgets.list(1, yTop + 1, w, h, rows, st.scroll, st.selected)
    self:button(w - 4, yTop + 1, 4, " Вверх ", false, function() st.scroll = math.max(0, st.scroll - (h - 2)) end)
    self:button(w - 4, yBot, 4, " Вниз ", false, function()
        if st.scroll + h < #rows then st.scroll = st.scroll + (h - 2) end
    end)
    self:button(w - 12, yTop, 8, " Очистить ", false, function() st.search = ""; st.scroll = 0; st.selected = 1 end,
        { bg = colors.red })
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
        local busy = info.busy and "ЗАНЯТ" or "СВОБ"
        local what = info.cooking and (" (" .. self.deps.lang.display(info.cooking) .. ")") or ""
        table.insert(rows, string.format("%-20s %-6s%s", name:sub(1, 20), busy, what))
    end
    widgets.list(1, yTop, w, h, rows, st.scroll, st.selected)
    self:button(2, yBot, 14, " Обновить ", false, function()
        -- пересканируем машины (статус обновится при следующем render)
    end)
end

----------------------------------------------------------------
-- Вкладка РЕЦЕПТЫ
----------------------------------------------------------------
function ui:renderRecipes(yTop, yBot, w)
    local st = self.state.recipes
    local recipes = self.deps.recipes
    local list = recipes:list()
    local h = yBot - yTop + 1
    local rows = {}
    for _, r in ipairs(list) do
        local name = self.deps.lang.display(r.id, r.name)
        local type = r.type == "machine" and "M" or (r.type == "shaped" and "S" or "L")
        table.insert(rows, string.format("[%s] %-24s x%d", type, name:sub(1, 24), r.output or 1))
    end
    if #rows == 0 then
        widgets.center(yTop + 1, "Нет рецептов", colors.gray)
    else
        widgets.list(1, yTop, w, h - 2, rows, st.scroll, st.selected)
    end
    -- Кнопки внизу
    self:button(2, yBot - 1, 16, " + Обучить ", false, function()
        self:addLog("Обучение: положите предметы в верстак черепахи-обучателя и нажмите Готово")
        st.mode = "learn"
    end, { bgActive = colors.green })
    self:button(20, yBot - 1, 14, " - Удалить ", false, function()
        if list[st.selected] then
            recipes:remove(list[st.selected].id)
            self:addLog("Удалён рецепт: " .. self.deps.lang.display(list[st.selected].id))
        end
    end, { bg = colors.red })
    if st.mode == "learn" then
        widgets.center(yTop, ">>> РЕЖИМ ОБУЧЕНИЯ <<<", colors.yellow, colors.black)
        self:button(w - 16, yTop, 7, " Готово ", true, function()
            local ok, recipe = recipes:learnFromTurtle()
            if ok then
                self:addLog("Сохранён рецепт: " .. self.deps.lang.display(recipe.id))
            else
                self:addLog("Ошибка обучения: " .. tostring(recipe))
            end
            st.mode = "list"
        end, { bgActive = colors.green })
    end
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
        widgets.center(math.floor((yTop + yBot) / 2), "Лог пуст", colors.gray)
        return
    end
    widgets.list(1, yTop, w, h, rows, st.scroll, nil)
    self:button(w - 4, yTop, 4, " Вверх ", false, function() st.scroll = math.max(0, st.scroll - (h - 2)) end)
    self:button(w - 4, yBot, 4, " Вниз ", false, function()
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
    if not st or not st.selected then return end
    local yTop = 3
    local idx = y - yTop + 1 + (st.scroll or 0)
    local list
    if tab == "craft" and self.state.craft.mode == "list" then
        list = self.deps.recipes:list()
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
        list = self.deps.recipes:list()
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
    if not st or not st.selected then return end
    local list
    if self.activeTab == "craft" then list = self.deps.recipes:list()
    elseif self.activeTab == "storage" then list = self.deps.storage:items()
    elseif self.activeTab == "recipes" then list = self.deps.recipes:list()
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
