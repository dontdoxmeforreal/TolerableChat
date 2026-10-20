-- The main window (spec 5.1): movable, resizable, tabbed; remembers its size, position and last tab;
-- Esc closes it. Also the widget and layout helpers the tabs use, and the shared text box pop-up.
--
-- Layout: fonts differ between UI skins (EllesmereUI swaps them) and so do UI scales, so nothing is
-- placed at a fixed x offset. Rows stack under each other and stretch to the window's width, text
-- wraps, grids work out their columns from their widest item, and the tab bar wraps when narrow.

local _, TC = ...

local UI = {}
TC.UI = UI

local tabs, order, current = {}, {}, nil
local main

---------------------------------------------------------------------------------------------------
-- Widgets

-- Adds a control to the nearest frame (itself or up to three parents) that keeps a controls list,
-- so the tab re-reads it on show.
local function Register(parent, control)
    local p = parent
    for _ = 1, 4 do
        if not p then return end
        local list = rawget(p, "controls")
        if list then
            list[#list + 1] = control
            return
        end
        p = p.GetParent and p:GetParent()
    end
end
UI.Register = Register

function UI.Text(parent, text, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    return fs
end

-- Text that wraps to whatever width its anchors give it.
function UI.Wrap(parent, text, font)
    local fs = UI.Text(parent, text, font)
    fs:SetWordWrap(true)
    fs:SetJustifyV("TOP")
    return fs
end

-- A single line that is cut short ("...") rather than running past its anchors.
function UI.Line(parent, text, font)
    local fs = UI.Text(parent, text, font)
    fs:SetWordWrap(false)
    return fs
end

function UI.Header(parent, text)
    return UI.Text(parent, text, "GameFontNormal")
end

function UI.Tooltip(frame, text)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(type(text) == "function" and text() or text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- A checkbox bound to get/set. Its Refresh method re-reads the value; tabs call it on show.
function UI.Check(parent, label, get, set, tooltip)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    local text = cb.Text or cb.text
    if not text then
        text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    end
    text:SetFontObject("GameFontHighlightSmall")
    cb.label = text
    function cb:SetLabel(s)
        self.label:SetText(s)
        self:SetHitRectInsets(0, -self.label:GetStringWidth() - 4, 0, 0)   -- the label clicks too
    end
    -- The width the box and its label take, for grids.
    function cb:Measure() return 28 + self.label:GetStringWidth() end
    cb:SetLabel(label)
    cb:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        TC.Notify("Settings")
    end)
    function cb:Refresh() self:SetChecked(get() and true or false) end
    if tooltip then UI.Tooltip(cb, tooltip) end
    Register(parent, cb)
    return cb
end

-- A setting checkbox: TC.db.settings[key], or a nested table path such as { "scope", "say" }.
function UI.SettingCheck(parent, label, path, tooltip, after)
    path = type(path) == "table" and path or { path }
    local function Holder()
        local t = TC.db.settings
        for i = 1, #path - 1 do t = t[path[i]] end
        return t
    end
    return UI.Check(parent, label,
        function() return Holder()[path[#path]] end,
        function(v)
            Holder()[path[#path]] = v
            if after then after(v) end
        end, tooltip)
end

-- A button sized to its text unless width is given.
function UI.Button(parent, text, onClick, width, height)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    if height and height < 22 then
        b:SetNormalFontObject("GameFontNormalSmall")
        b:SetHighlightFontObject("GameFontHighlightSmall")
        b:SetDisabledFontObject("GameFontDisableSmall")
    end
    b:SetText(text)
    local fs = b:GetFontString()
    b:SetSize(width or math.max(56, (fs and fs:GetStringWidth() or #text * 7) + 22), height or 22)
    b:SetScript("OnClick", onClick)
    return b
end

-- Re-sizes a button to its current text.
function UI.FitButton(b)
    local fs = b:GetFontString()
    if fs then b:SetWidth(math.max(56, fs:GetStringWidth() + 22)) end
end

function UI.Edit(parent, width, onEnter)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetAutoFocus(false)
    e:SetSize(width, 20)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    e:SetScript("OnEnterPressed", function(self)
        if onEnter then onEnter(self:GetText(), self) end
        self:ClearFocus()
    end)
    return e
end

-- A numeric edit box for a whole-number setting with limits.
function UI.NumberEdit(parent, key, min, max)
    local e = UI.Edit(parent, 36)
    e:SetNumeric(true)
    e:SetMaxLetters(3)
    local function Commit()
        local v = tonumber(e:GetText())
        if v then TC.db.settings[key] = math.max(min, math.min(max, math.floor(v))) end
        e:SetText(tostring(TC.db.settings[key]))
        TC.Notify("Settings")
    end
    e:SetScript("OnEnterPressed", function(self) Commit() self:ClearFocus() end)
    e:SetScript("OnEditFocusLost", Commit)
    function e:Refresh() if not self:HasFocus() then self:SetText(tostring(TC.db.settings[key])) end end
    Register(parent, e)
    return e
end

-- A button that opens a menu of choices, as wide as its longest choice. options() returns
-- { { value, label } }; get/set the chosen value.
function UI.Choice(parent, prefix, options, get, set)
    local b = UI.Button(parent, prefix, nil, 60)
    local function Label()
        for _, o in ipairs(options()) do
            if o[1] == get() then return o[2] end
        end
        return tostring(get())
    end
    function b:Refresh()
        local fs, widest = self:GetFontString(), 0
        for _, o in ipairs(options()) do
            self:SetText(prefix .. o[2])
            widest = math.max(widest, fs and fs:GetStringWidth() or 0)
        end
        self:SetWidth(math.max(60, widest + 28))
        self:SetText(prefix .. Label())
    end
    b:SetScript("OnClick", function(self)
        MenuUtil.CreateContextMenu(self, function(_, root)
            for _, o in ipairs(options()) do
                root:CreateRadio(o[2], function() return get() == o[1] end, function()
                    set(o[1])
                    self:Refresh()
                end)
            end
        end)
    end)
    Register(parent, b)
    b:Refresh()
    return b
end

-- A plain frame one control high, for laying a few widgets side by side.
function UI.Row(parent, height)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(height or 24)
    return row
end

-- Stacks widgets top to bottom. stretch also pins a widget's right edge to the parent (text, rows,
-- grids); checkboxes and buttons keep their own width.
function UI.Stack(parent)
    local stack = {}
    function stack:Add(widget, gap, stretch)
        widget:ClearAllPoints()
        if self.last then
            widget:SetPoint("TOPLEFT", self.last, "BOTTOMLEFT", 0, -(gap or 8))
        else
            widget:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
        end
        if stretch then widget:SetPoint("RIGHT", parent, "RIGHT", 0, 0) end
        self.last = widget
        return widget
    end
    return stack
end

-- Lays items out in as many equal columns as fit, each as wide as the widest item. Items have a
-- Measure() method. Items with alignLabel get their labels padded to one width, so the controls
-- after the labels line up.
function UI.Grid(parent, rowHeight, gap)
    local grid = CreateFrame("Frame", nil, parent)
    grid.items, grid.rowHeight, grid.gap = {}, rowHeight or 26, gap or 18
    grid:SetHeight(grid.rowHeight)
    function grid:Add(item)
        self.items[#self.items + 1] = item
        return item
    end
    function grid:Layout(width)
        width = width or self:GetWidth()
        if not width or width <= 0 then return end
        local labelWidth = 0
        for _, it in ipairs(self.items) do
            if it.alignLabel then labelWidth = math.max(labelWidth, it.label:GetStringWidth()) end
        end
        local colWidth = 0
        for _, it in ipairs(self.items) do
            if it.alignLabel then it.label:SetWidth(labelWidth + 2) end
            if it:IsShown() then colWidth = math.max(colWidth, it:Measure()) end
        end
        colWidth = colWidth + self.gap
        local cols = math.max(1, math.floor((width + self.gap) / colWidth))
        local n = 0
        for _, it in ipairs(self.items) do
            if it:IsShown() then
                it:ClearAllPoints()
                it:SetPoint("TOPLEFT", self, "TOPLEFT", (n % cols) * colWidth, -math.floor(n / cols) * self.rowHeight)
                n = n + 1
            end
        end
        self:SetHeight(math.max(1, math.ceil(n / cols)) * self.rowHeight)
    end
    grid:SetScript("OnSizeChanged", function(self, width) self:Layout(width) end)
    return grid
end

-- A scrolling list. build(row) runs once per row frame; fill(row, item) on every show.
function UI.List(parent, rowHeight, build, fill)
    local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
    local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 6, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 6, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(rowHeight)
    view:SetElementInitializer("Button", function(row, item)
        if not row.built then
            row.built = true
            row:SetHeight(rowHeight)
            local hl = row:CreateTexture(nil, "BACKGROUND")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.04)
            row.stripe = hl
            build(row)
        end
        row.item = item
        fill(row, item)
        if row.LayoutButtons then row:LayoutButtons() end
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    local list = { box = box, bar = bar }
    function list:SetData(items)
        box:SetDataProvider(CreateDataProvider(items), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
    end
    return list
end

-- Small buttons along the right edge of a list row, right to left; returns an edge just left of the
-- leftmost shown button, for the row's text to stop at. specs: { { text, onClick(item, button) } } in
-- left-to-right order. Buttons a row hides leave no gap: they are packed again after every fill.
function UI.RowButtons(row, specs)
    local buttons = {}
    for i, spec in ipairs(specs) do
        buttons[i] = UI.Button(row, spec[1], function(self) spec[2](self:GetParent().item, self) end, nil, 18)
    end
    local edge = CreateFrame("Frame", nil, row)
    edge:SetSize(1, 1)
    function row:LayoutButtons()
        local right
        for i = #buttons, 1, -1 do
            local b = buttons[i]
            if b:IsShown() then
                b:ClearAllPoints()
                if right then b:SetPoint("RIGHT", right, "LEFT", -2, 0) else b:SetPoint("TOPRIGHT", -2, -3) end
                right = b
            end
        end
        edge:ClearAllPoints()
        if right then edge:SetPoint("RIGHT", right, "LEFT", 0, 0) else edge:SetPoint("TOPRIGHT", -2, -3) end
    end
    row:LayoutButtons()
    return buttons, edge
end

-- "20:31 [Trade - English] Name" and the short reason for a buffer entry.
function UI.EntryHead(e)
    return string.format("%s  [%s]  %s", date("%H:%M:%S", e.t), e.channel or "?", e.sender or "?")
end

-- "term "trump" (Politics), cleared 3 earlier lines", "timeout: started by term "trump" at 06:04".
function UI.EntryReason(e)
    local format = string.format
    local cleared = (e.removedEarlier or 0) > 0
        and format(", cleared %d earlier line%s", e.removedEarlier, e.removedEarlier == 1 and "" or "s") or ""
    if e.step == "term" and e.term then
        return format('term "%s"%s (%s)%s%s', e.term.text, e.term.via and format(' as "%s"', e.term.form) or "", e.term.cat,
            e.autoMuted and ", sender auto-muted" or "", cleared)
    end
    if e.step == "sender" then
        local cause = e.cause and format("started by %s at %s", e.cause.what, date("%H:%M", e.cause.t)) or "started earlier"
        return format("timeout%s: %s", e.spamming and " (spamming)" or "", cause)
    end
    if e.step == "muted" then return e.muteReason or "muted" end
    if e.step == "flagged" then return "flagged by you" .. cleared end
    if e.step == "meme" and e.memeWord then return format('meme word mute: "%s"', e.memeWord) end
    return TC.STEP_TEXT[e.step] or tostring(e.step)
end

---------------------------------------------------------------------------------------------------
-- Tabs

-- build(frame) runs once when the tab is first shown; refresh(frame) every time it is shown or
-- something it shows changes.
-- position sets the tab's place in the bar (spec 5.1 order). events lists the notifications that
-- refresh the tab while it's open ("Muted", "Watch" ...); without it, every one does. A tab that
-- doesn't show messages leaves out "Hidden", so it isn't rebuilt for every chat line.
function UI.RegisterTab(id, label, build, refresh, position, events)
    local wanted
    if events then
        wanted = {}
        for _, name in ipairs(events) do wanted[name] = true end
    end
    tabs[id] = { id = id, label = label, build = build, refresh = refresh, position = position or 100 + #order,
                 events = wanted }
    order[#order + 1] = id
    table.sort(order, function(a, b) return tabs[a].position < tabs[b].position end)
end

function UI.TabOrder()
    return order
end

-- A tab's frame once it has been shown (nil before).
function UI.TabFrame(id)
    return tabs[id] and tabs[id].frame
end

local function SaveWindow()
    if not main then return end
    local w = TC.db.settings.window
    local point, _, relPoint, x, y = main:GetPoint()
    w.point, w.relPoint, w.x, w.y = point, relPoint, x, y
    w.width, w.height = main:GetWidth(), main:GetHeight()
end

-- Tab buttons in a row, wrapping onto a second row when the window is narrow; the content starts
-- below the last row.
local function LayoutTabs()
    local width = main:GetWidth() - 24
    local x, y = 0, 0
    for _, id in ipairs(order) do
        local b = main.tabButtons[id]
        if x > 0 and x + b:GetWidth() > width then x, y = 0, y + 24 end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", main, "TOPLEFT", 10 + x, -28 - y)
        x = x + b:GetWidth() + 2
    end
    main.content:ClearAllPoints()
    main.content:SetPoint("TOPLEFT", main, "TOPLEFT", 16, -60 - y)
    main.content:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -16, 16)
end

local function CreateMain()
    local f = CreateFrame("Frame", "TolerableChatFrame", UIParent, "BasicFrameTemplateWithInset")
    f:Hide()
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetResizable(true)
    if f.SetResizeBounds then f:SetResizeBounds(600, 460) end
    local w = TC.db.settings.window
    f:SetSize(w.width or 780, w.height or 560)
    if w.point then
        f:SetPoint(w.point, UIParent, w.relPoint or w.point, w.x or 0, w.y or 0)
    else
        f:SetPoint("CENTER")
    end
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveWindow()
    end)
    if f.TitleText then f.TitleText:SetText("TolerableChat") end
    tinsert(UISpecialFrames, "TolerableChatFrame")

    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        SaveWindow()
        UI.Refresh()
    end)

    f.tabButtons = {}
    for _, id in ipairs(order) do
        f.tabButtons[id] = UI.Button(f, tabs[id].label, function() UI.SelectTab(id) end)
    end
    f.content = CreateFrame("Frame", nil, f)
    main = f
    UI.main = f
    LayoutTabs()
    f:SetScript("OnSizeChanged", LayoutTabs)
    f:SetScript("OnHide", SaveWindow)
end

function UI.SelectTab(id)
    if not main then CreateMain() end
    if not tabs[id] then id = order[1] end
    for tid, tab in pairs(tabs) do
        if tab.frame and tid ~= id then tab.frame:Hide() end
        local b = main.tabButtons[tid]
        if tid == id then b:LockHighlight() else b:UnlockHighlight() end
    end
    local tab = tabs[id]
    if not tab.frame then
        local frame = CreateFrame("Frame", nil, main.content)
        frame:SetAllPoints()
        frame.controls = {}
        tab.frame = frame
        tab.build(frame)
    end
    current = id
    TC.db.settings.window.tab = id
    main:Show()
    tab.frame:Show()
    UI.Refresh()
end

function UI.Show(id)
    UI.SelectTab(id or TC.db.settings.window.tab or order[1])
    main:Raise()   -- above the game's Settings window (same strata) when opened from there
end

function UI.Toggle()
    if main and main:IsShown() then
        main:Hide()
    else
        UI.Show()
    end
end

function UI.CurrentTab()
    return main and main:IsShown() and current or nil
end

local TERM_EDITOR_EVENTS = { Terms = true, Settings = true }

-- Whether a tab wants refreshing for these notifications (nil or "all": yes).
local function Wants(wanted, due)
    if not due or due.all or not wanted then return true end
    for name in pairs(due) do
        if wanted[name] then return true end
    end
    return false
end

-- due: the notifications that asked for it (UI.QueueRefresh); nil refreshes everything shown.
function UI.Refresh(due)
    if main and main:IsShown() and current then
        local tab = tabs[current]
        if tab.frame and Wants(tab.events, due) then
            for _, c in ipairs(tab.frame.controls) do c:Refresh() end
            if tab.refresh then tab.refresh(tab.frame) end
        end
    end
    -- The term editor lists every term: only term and category changes redraw it.
    if UI.RefreshTermEditor and Wants(TERM_EDITOR_EVENTS, due) then UI.RefreshTermEditor() end
end

-- Many messages can arrive in one second; refresh at most a few times a second, for whatever asked
-- in between. reason: the notification's name; none means "all".
local pending, due = false, {}
function UI.QueueRefresh(reason)
    due[reason or "all"] = true
    if pending then return end
    pending = true
    C_Timer.After(0.3, function()
        pending = false
        local now = due
        due = {}
        UI.Refresh(now)
    end)
end

for _, name in ipairs({ "Hidden", "Changed", "Flagged", "Terms", "Settings", "Muted" }) do
    TC.Listen(name, function() UI.QueueRefresh(name) end)
end

---------------------------------------------------------------------------------------------------
-- Text box pop-up for export, import and copying. Ctrl+A, Ctrl+C copies.

local box

local function CreateTextBox()
    local f = CreateFrame("Frame", "TolerableChatTextBox", UIParent, "BasicFrameTemplateWithInset")
    f:Hide()
    f:SetSize(640, 440)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "TolerableChatTextBox")

    f.close = UI.Button(f, "Close", function() f:Hide() end)
    f.close:SetPoint("BOTTOMRIGHT", -14, 12)
    f.action = UI.Button(f, "Import", nil)
    f.action:SetPoint("RIGHT", f.close, "LEFT", -6, 0)
    f.hint = UI.Line(f, "Ctrl+A selects all, Ctrl+C copies, Ctrl+V pastes.")
    f.hint:SetPoint("LEFT", f, "BOTTOMLEFT", 16, 23)
    f.hint:SetPoint("RIGHT", f.action, "LEFT", -10, 0)

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -32)
    scroll:SetPoint("BOTTOMRIGHT", -34, 46)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(0)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(580)
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(edit)
    scroll:SetScript("OnSizeChanged", function(self, width) edit:SetWidth(width) end)
    f.edit = edit
    box = f
end

-- Shows text in the pop-up. With actionLabel/onAction, a button passes the edited text back.
function UI.ShowTextBox(title, text, actionLabel, onAction)
    if not box then CreateTextBox() end
    if box.TitleText then box.TitleText:SetText(title) end
    box.edit:SetText(text or "")
    if onAction then
        box.action:SetText(actionLabel or "OK")
        UI.FitButton(box.action)
        box.action:SetScript("OnClick", function() onAction(box.edit:GetText()) end)
        box.action:Show()
    else
        box.action:Hide()
    end
    box:Show()
    box.edit:SetFocus()
    if not onAction then box.edit:HighlightText() end
end

function UI.HideTextBox()
    if box then box:Hide() end
end

---------------------------------------------------------------------------------------------------
-- A small yes/no question of TolerableChat's own. The game's StaticPopup system isn't used: pop-ups an
-- addon shows or hides there leave "tainted" values behind, and the game's own pop-ups and Esc
-- handling then get blocked from protected actions (Esc stopping a cast, for one).
--   UI.Ask{ text = "...", yes = "Allow", no = "Decline", onYes = fn, onNo = fn, onEscape = fn }
-- onEscape runs when the question is closed any other way (Esc, or a newer question); default none.

local ask

local function CreateAsk()
    local f = CreateFrame("Frame", "TolerableChatAsk", UIParent, "BasicFrameTemplateWithInset")
    f:Hide()
    f:SetSize(380, 120)
    f:SetPoint("TOP", UIParent, "TOP", 0, -135)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    if f.TitleText then f.TitleText:SetText("TolerableChat") end
    f.text = UI.Wrap(f, "")
    f.text:SetPoint("TOPLEFT", 16, -34)
    f.text:SetPoint("TOPRIGHT", -16, -34)
    f.text:SetJustifyH("CENTER")
    f.yes = UI.Button(f, "Yes", nil, nil, 24)
    f.no = UI.Button(f, "No", nil, nil, 24)
    f:SetScript("OnHide", function(self)
        local q = self.question
        self.question = nil
        if q and q.onEscape then q.onEscape() end
    end)
    tinsert(UISpecialFrames, "TolerableChatAsk")
    ask = f
end

local function Answer(which)
    local q = ask.question
    ask.question = nil   -- answered: hiding it isn't an escape
    ask:Hide()
    if q and q[which] then q[which]() end
end

function UI.Ask(q)
    if not ask then CreateAsk() end
    if ask:IsShown() then ask:Hide() end   -- a newer question replaces an open one
    ask.text:SetText(q.text or "")
    ask.yes:SetText(q.yes or "Yes")
    ask.no:SetText(q.no or "No")
    UI.FitButton(ask.yes)
    UI.FitButton(ask.no)
    ask.yes:SetScript("OnClick", function() Answer("onYes") end)
    ask.no:SetScript("OnClick", function() Answer("onNo") end)
    ask.yes:ClearAllPoints()
    ask.no:ClearAllPoints()
    ask.yes:SetPoint("TOPRIGHT", ask.text, "BOTTOM", -4, -12)
    ask.no:SetPoint("TOPLEFT", ask.text, "BOTTOM", 4, -12)
    ask.question = q
    ask:Show()
    ask:Raise()   -- above the term editor and other windows of the same strata
    -- tall enough for the text at any font size
    ask:SetHeight(34 + (ask.text:GetStringHeight() or 30) + 12 + ask.yes:GetHeight() + 14)
end

-- Closes the open question if it is this one, without running any of its answers.
function UI.CloseAsk(q)
    if ask and ask:IsShown() and (not q or ask.question == q) then
        ask.question = nil
        ask:Hide()
    end
end

function UI.AskShown()
    return ask and ask:IsShown() and ask.question or nil
end

