-- Phase 1 tabs: Overview, Filter, Log, Flagged and Auto-mutes (spec 5.1).
--
-- Every tab is laid out top to bottom with UI.Stack, stretched to the window's width, so it holds
-- together with any font and UI scale. The Filter tab scrolls if the window is too short for it.

local _, TC = ...
local UI = TC.UI
local format = string.format

---------------------------------------------------------------------------------------------------
-- Categories: one choice each (Matcher.lua TC.CATEGORY_ACTIONS): Mute Forever, Timeout, Hide Only, Off.

local ACTION_HELP = "Mute Forever: mutes that player: everything from them is hidden from then on (see Auto-mutes).\n"
    .. "Timeout: hides the message, and that player's other messages for the Timeout Duration, unless they're "
    .. "about the game.\nHide Only: hides just that message.\nOff: this category isn't checked."

local function CategoryState(cat) return TC.CategoryAction(cat) end
local function SetCategoryState(cat, value) TC.SetCategoryAction(cat, value) end

local function CategoryItem(parent, cat)
    local item = CreateFrame("Frame", nil, parent)
    item:SetSize(10, 24)
    item.alignLabel = true
    item.label = UI.Line(item, cat)
    item.label:SetPoint("LEFT", 0, 0)
    item.choice = UI.Choice(item, "", function() return TC.CATEGORY_ACTIONS end,
        function() return CategoryState(cat) end, function(v) SetCategoryState(cat, v) end)
    item.choice:SetPoint("LEFT", item.label, "RIGHT", 8, 0)
    UI.Tooltip(item.choice, ACTION_HELP)
    function item:Measure() return self.label:GetWidth() + 8 + self.choice:GetWidth() end
    return item
end

-- A one-line summary of what is on, for the Overview tab.
local function Summary()
    local s = TC.db.settings
    local lists = { mute = {}, timeout = {}, hide = {}, off = {} }
    for _, cat in ipairs(TC.CATEGORIES) do
        local list = lists[CategoryState(cat)]
        list[#list + 1] = cat
    end
    local parts = {}
    for _, a in ipairs(TC.CATEGORY_ACTIONS) do
        local list = lists[a[1]]
        if list[1] then parts[#parts + 1] = a[2] .. ": " .. table.concat(list, ", ") .. "." end
    end
    parts[#parts + 1] = format("Timeout Duration: %d minutes.", s.senderMinutes)
    if s.symbolSpam then parts[#parts + 1] = "Symbol and script spam: hidden." end
    parts[#parts + 1] = format("Guild words: %d.", #TC.db.guildWords)
    if s.listenMode ~= "off" then parts[#parts + 1] = format("OlympusNet: %s.", TC.ListenText()) end
    return table.concat(parts, " ")
end

---------------------------------------------------------------------------------------------------
-- Overview

UI.RegisterTab("overview", "Overview", function(f)
    local stack = UI.Stack(f)
    local master = UI.SettingCheck(f, "TolerableChat is on", "enabled",
        "Off: every message is shown. Your lists and settings are kept.")
    master.label:SetFontObject("GameFontNormal")
    master:SetLabel("TolerableChat is on")
    stack:Add(master, 0)
    f.counts = stack:Add(UI.Wrap(f, "", "GameFontHighlight"), 8, true)
    f.summary = stack:Add(UI.Wrap(f, ""), 6, true)
    local change = UI.Row(f, 22)
    change.button = UI.Button(change, "Change on the Filter tab", function() UI.SelectTab("filter") end)
    change.button:SetPoint("LEFT", 0, 0)
    stack:Add(change, 6, true)

    stack:Add(UI.Header(f, "Meme word mute"), 18, true)
    stack:Add(UI.Wrap(f, format("|cff999999Words that many of the last %d messages share. Mute one for a while "
        .. "when a joke goes round; it comes back by itself, so you can still talk about it later.|r",
        TC.MEME_WINDOW)), 4, true)
    f.memeRows = {}
    for i = 1, 3 do
        local row = UI.Row(f, 24)
        row.short = UI.Button(row, format("Mute %d min", TC.MEME_SHORT), function()
            if row.word then TC.Print(TC.MemeMuteReport(row.word, TC.MEME_SHORT, select(2, TC.MuteMemeWord(row.word, TC.MEME_SHORT)))) end
        end)
        row.short:SetPoint("LEFT", 0, 0)
        row.long = UI.Button(row, format("Mute %d hours", TC.MEME_LONG / 60), function()
            if row.word then TC.Print(TC.MemeMuteReport(row.word, TC.MEME_LONG, select(2, TC.MuteMemeWord(row.word, TC.MEME_LONG)))) end
        end)
        row.long:SetPoint("LEFT", row.short, "RIGHT", 4, 0)
        row.text = UI.Line(row, "")
        row.text:SetPoint("LEFT", row.long, "RIGHT", 10, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        f.memeRows[i] = stack:Add(row, i == 1 and 6 or 2, true)
    end
    f.memeMuted = stack:Add(UI.Wrap(f, ""), 6, true)
    local unmuteRow = UI.Row(f, 22)
    f.unmuteMeme = UI.Button(unmuteRow, "Unmute meme words", function()
        for _, m in ipairs(TC.MutedMemeWords()) do TC.UnmuteMemeWord(m.word) end
    end)
    f.unmuteMeme:SetPoint("LEFT", 0, 0)
    stack:Add(unmuteRow, 4, true)

    stack:Add(UI.Header(f, "Last 5 hidden messages"), 18, true)
    f.last = {}
    for i = 1, 5 do f.last[i] = stack:Add(UI.Line(f, ""), i == 1 and 6 or 4, true) end
    local open = UI.Row(f, 22)
    open.button = UI.Button(open, "Open the log", function() UI.SelectTab("log") end)
    open.button:SetPoint("LEFT", 0, 0)
    stack:Add(open, 10, true)
end, function(f)
    local today = TC.Today()
    f.counts:SetText(format("Today: %d hidden  ·  %d muted players  ·  %d flagged",
        today.hidden or 0, today.muted or 0, today.flagged or 0))
    f.summary:SetText("|cffbbbbbb" .. Summary() .. "|r")
    local memes = TC.MemeWords(3)
    for i, row in ipairs(f.memeRows) do
        local m = memes[i]
        row.word = m and m.word
        row.short:SetShown(m ~= nil)
        row.long:SetShown(m ~= nil)
        row.text:SetText(m and format("|cffffd100%s|r  in %d of the last %d messages, %d player%s", m.word, m.messages,
            TC.MEME_WINDOW, m.players, m.players == 1 and "" or "s")
            or (i == 1 and "|cff999999No word stands out right now.|r" or ""))
    end
    local muted, parts = TC.MutedMemeWords(), {}
    for _, m in ipairs(muted) do
        parts[#parts + 1] = format("%s (%d min left)", m.word, math.ceil(m.left / 60))
    end
    f.memeMuted:SetText(parts[1] and ("Muted for now: " .. table.concat(parts, ", ")) or "|cff999999No meme words muted.|r")
    f.unmuteMeme:SetShown(muted[1] ~= nil)
    local hidden = TC.LogEntries(5)
    for i = 1, 5 do
        local e = hidden[i]
        f.last[i]:SetText(e and format("|cff999999%s|r  %s: %s  |cffff9060(%s)|r", date("%H:%M", e.t),
            e.sender or "?", TC.EntryText(e), UI.EntryReason(e)) or (i == 1 and "|cff999999Nothing hidden yet.|r" or ""))
    end
end, 1)

---------------------------------------------------------------------------------------------------
-- Filter

local function ChannelMenu(owner)
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Filter these custom channels")
        local list, any = { GetChannelList() }, false
        for i = 1, #list, 3 do
            local name = list[i + 1]
            if type(name) == "string" and TC.IsCustomChannel(name) then
                any = true
                local key = TC.Lower(name)
                root:CreateCheckbox(name, function() return not TC.db.settings.customOff[key] end, function()
                    TC.db.settings.customOff[key] = (not TC.db.settings.customOff[key]) or nil
                    TC.Notify("Settings")
                end)
            end
        end
        if not any then root:CreateTitle("You aren't in any custom channels.") end
    end)
end

-- A scrolling area for a tab whose content may be taller than the window.
local function ScrollArea(f)
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -26, 0)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(500, 600)
    child.controls = f.controls
    scroll:SetScrollChild(child)
    scroll:SetScript("OnSizeChanged", function(_, width) child:SetWidth(width) end)
    -- Sets the scroll height to the content once it has been laid out.
    function scroll:Fit(last)
        C_Timer.After(0, function()
            local top, bottom = child:GetTop(), last:GetBottom()
            if top and bottom then child:SetHeight(math.max(10, top - bottom + 10)) end
        end)
    end
    return scroll, child
end

UI.RegisterTab("filter", "Filter", function(f)
    local scroll, c = ScrollArea(f)
    f.scroll = scroll
    local stack = UI.Stack(c)

    local whatRow = UI.Row(c, 22)
    UI.Header(whatRow, "What to hide"):SetPoint("LEFT", 0, 0)
    f.editTerms = UI.Button(whatRow, "Edit terms...", function() UI.OpenTermEditor() end)
    f.editTerms:SetPoint("RIGHT", 0, 0)
    f.termCount = UI.Line(whatRow, "")
    f.termCount:SetPoint("RIGHT", f.editTerms, "LEFT", -8, 0)
    stack:Add(whatRow, 0, true)
    f.cats = UI.Grid(c, 26, 18)
    f.catItems = {}
    for _, cat in ipairs(TC.CATEGORIES) do f.catItems[cat] = f.cats:Add(CategoryItem(f.cats, cat)) end
    stack:Add(f.cats, 6, true)
    stack:Add(UI.Wrap(c, "|cff999999Mute Forever: mutes the player (see Auto-mutes). Timeout: hides the message, and "
        .. "that player's other messages for the Timeout Duration unless they're about the game. Hide Only: hides "
        .. "just the message.|r"), 4, true)
    stack:Add(UI.SettingCheck(c, "Also hide symbol and script spam (ASCII art, text in other alphabets)", "symbolSpam",
        format("A message of %d or more characters (not counting spaces) where more than %d%% aren't letters, "
            .. "digits or emoji. Short replies like \"...\" stay.", TC.SYMBOL_MIN, TC.SYMBOL_PERCENT)), 6)

    stack:Add(UI.Header(c, "Timeout Duration"), 16, true)
    local ruleRow = UI.Row(c, 24)
    local ruleLabel = UI.Text(ruleRow, "A Timeout hides that player's other messages for")
    ruleLabel:SetPoint("LEFT", 4, 0)
    local minutes = UI.NumberEdit(ruleRow, "senderMinutes", 5, 120)
    minutes:SetPoint("LEFT", ruleLabel, "RIGHT", 12, 0)
    UI.Text(ruleRow, "minutes"):SetPoint("LEFT", minutes, "RIGHT", 6, 0)
    stack:Add(ruleRow, 4, true)
    stack:Add(UI.Wrap(c, format("|cff999999Before and after the hidden message, from 5 to 120 minutes. Their game talk "
        .. "still shows: class, role, dungeon and zone words, item, spell and profession links, and WTS/WTB unless "
        .. "they're spamming (%d hidden messages, or %d messages in %d minutes).|r", TC.SPAM_HITS, TC.SPAM_MESSAGES,
        TC.SPAM_SECONDS / 60)), 2, true)

    stack:Add(UI.Header(c, "Where"), 16, true)
    f.scopes = UI.Grid(c, 26, 18)
    local function Scope(label, key)
        f.scopes:Add(UI.SettingCheck(f.scopes, label, { "scope", key }))
    end
    Scope("General, Trade, LFG, defense", "world")
    Scope("Custom channels", "custom")
    Scope("Say, yell and emote", "say")
    Scope("Whispers (muted players' are hidden anyway)", "whisper")
    Scope("Communities", "community")
    stack:Add(f.scopes, 4, true)
    local channelRow = UI.Row(c, 22)
    local pick = UI.Button(channelRow, "Pick custom channels...", function(self) ChannelMenu(self) end)
    pick:SetPoint("LEFT", 0, 0)
    local never = UI.Line(channelRow, "|cff999999Guild, officer, party, raid and instance chat are never filtered.|r")
    never:SetPoint("LEFT", pick, "RIGHT", 12, 0)
    never:SetPoint("RIGHT", 0, 0)
    stack:Add(channelRow, 4, true)

    stack:Add(UI.Header(c, "Test a message"), 16, true)
    local testRow = UI.Row(c, 24)
    local test = UI.Button(testRow, "Test", function() f.RunTest(f.testBox:GetText()) end)
    test:SetPoint("RIGHT", 0, 0)
    f.testBox = UI.Edit(testRow, 100, function(text) f.RunTest(text) end)
    f.testBox:SetPoint("LEFT", 6, 0)
    f.testBox:SetPoint("RIGHT", test, "LEFT", -10, 0)
    stack:Add(testRow, 4, true)
    f.testResult = stack:Add(UI.Wrap(c, ""), 6, true)
    f.last = f.testResult
    function f.RunTest(text)
        if text and text ~= "" then
            f.testResult:SetText(table.concat(TC.SelfTest(text), "\n"))
            f.scroll:Fit(f.last)
        end
    end
end, function(f)
    local active, total = TC.TermCounts()
    f.termCount:SetText(format("|cff999999%d of %d terms on|r", active, total))
    local counts = TC.CategoryCounts()
    for cat, item in pairs(f.catItems) do item.label:SetText(format("%s (%d)", cat, counts[cat] or 0)) end
    f.cats:Layout()
    f.scopes:Layout()
    f.scroll:Fit(f.last)
end, 2, { "Terms", "Settings" })

---------------------------------------------------------------------------------------------------
-- Log (14.1)

UI.RegisterTab("log", "Log", function(f)
    f.title = UI.Wrap(f, "")
    f.title:SetPoint("TOPLEFT", 0, 0)
    f.title:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    local list = UI.List(f, 46, function(row)
        local buttons, leftmost = UI.RowButtons(row, {
            { "Show", function(e) TC.ShowHidden(e) end },
            { "Report", function(e) TC.ReportEntry(e) end },
            { "Never mute", function(e) if e.sender and not TC.rdb.neverMute[e.key] then TC.ToggleNeverMute(e.sender) end end },
            { "Disable term", function(e) if e.term then TC.SetTermEnabled(e.term.key, false) end end },
            { "Wrongly hidden", function(e) if not e.flaggedWrong then TC.FlagWrong(e) end end },
        })
        row.report, row.never, row.disable, row.wrong = buttons[2], buttons[3], buttons[4], buttons[5]
        row.head = UI.Line(row, "", "GameFontNormalSmall")
        row.head:SetPoint("TOPLEFT", 4, -6)
        row.head:SetPoint("RIGHT", leftmost, "LEFT", -6, 0)
        row.text = UI.Line(row, "")
        row.text:SetPoint("TOPLEFT", 4, -26)
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        UI.Tooltip(row, function()
            local e = row.item
            return e and (TC.EntryText(e) .. "\n\n|cff999999" .. TC.Trace(e) .. "|r") or ""
        end)
    end, function(row, e)
        row.head:SetText(UI.EntryHead(e) .. "  |cffff9060" .. UI.EntryReason(e) .. "|r")
        row.text:SetText(TC.EntryText(e))
        row.report:SetEnabled(e.lineID ~= nil and e.guid ~= nil)
        row.never:SetEnabled(e.key ~= nil and not TC.rdb.neverMute[e.key])
        row.disable:SetEnabled(e.term ~= nil and not TC.db.terms.disabled[e.term.key])
        row.wrong:SetEnabled(not e.flaggedWrong)
    end)
    list.box:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -8)
    list.box:SetPoint("BOTTOMRIGHT", -24, 0)
    f.list = list
end, function(f)
    local hidden = TC.LogEntries()
    f.title:SetText(format("Hidden in the last 30 minutes: %d. Lines removed afterwards are counted on the line "
        .. "that caused it. Hover a line for the full text and why.", #hidden))
    f.list:SetData(hidden)
end, 7)

---------------------------------------------------------------------------------------------------
-- Flagged (14.2)

UI.RegisterTab("flagged", "Flagged", function(f)
    f.show = "both"
    local function Pick(which)
        return function()
            f.show = which
            UI.Refresh()
        end
    end
    local top = UI.Row(f, 22)
    top:SetPoint("TOPLEFT", 0, 0)
    top:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    f.missedButton = UI.Button(top, "Missed (000)", Pick("missed"))
    f.missedButton:SetPoint("LEFT", 0, 0)
    f.wrongButton = UI.Button(top, "Wrongly hidden (000)", Pick("wrong"))
    f.wrongButton:SetPoint("LEFT", f.missedButton, "RIGHT", 4, 0)
    f.bothButton = UI.Button(top, "Both", Pick("both"))
    f.bothButton:SetPoint("LEFT", f.wrongButton, "RIGHT", 4, 0)
    local export = UI.Button(top, "Export all", function() UI.ShowTextBox("Flagged messages", TC.ExportFlagged()) end)
    export:SetPoint("RIGHT", 0, 0)
    local hint = UI.Wrap(f, "|cff999999Messages you flagged as missed (right-click a name, Flag message) or as "
        .. "wrongly hidden (the Log tab). Export all copies them as text, to send to whoever looks after the lists.|r")
    hint:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", f, "RIGHT", -24, 0)

    local list = UI.List(f, 62, function(row)
        local _, leftmost = UI.RowButtons(row, {
            { "Unflag", function(r)
                local listed = TC.db.flagged[r.list]
                for i, x in ipairs(listed) do
                    if x == r then table.remove(listed, i) break end
                end
                TC.Notify("Flagged")
            end },
            { "Copy", function(r)
                UI.ShowTextBox("Flagged message", format("{%s; %s} %s", r.list == "missed" and "missed" or "wrongly hidden",
                    r.trace or "", TC.FormatLogLine(r)))
            end },
        })
        row.head = UI.Line(row, "", "GameFontNormalSmall")
        row.head:SetPoint("TOPLEFT", 4, -6)
        row.head:SetPoint("RIGHT", leftmost, "LEFT", -6, 0)
        row.text = UI.Line(row, "")
        row.text:SetPoint("TOPLEFT", 4, -26)
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.trace = UI.Line(row, "")
        row.trace:SetPoint("TOPLEFT", 4, -44)
        row.trace:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.trace:SetTextColor(0.6, 0.6, 0.6)
        UI.Tooltip(row, function()
            local r = row.item
            return r and ((r.text or "") .. "\n\n|cff999999" .. (r.trace or "") .. "|r") or ""
        end)
    end, function(row, r)
        row.head:SetText(format("%s  [%s]  %s  |cffff9060%s|r", date("%Y-%m-%d %H:%M", r.t or 0), r.channel or "?",
            r.sender or "?", r.list == "missed" and "missed" or "wrongly hidden"))
        row.text:SetText(r.text or "")
        row.trace:SetText(r.trace or "")
    end)
    list.box:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
    list.box:SetPoint("BOTTOMRIGHT", -24, 0)
    f.list = list
end, function(f)
    local flagged = TC.db.flagged
    f.missedButton:SetText(format("Missed (%d)", #flagged.missed))
    f.wrongButton:SetText(format("Wrongly hidden (%d)", #flagged.wrong))
    for which, b in pairs({ missed = f.missedButton, wrong = f.wrongButton, both = f.bothButton }) do
        UI.FitButton(b)
        if which == f.show then b:LockHighlight() else b:UnlockHighlight() end
    end
    local items = {}
    for _, name in ipairs({ "missed", "wrong" }) do
        if f.show == "both" or f.show == name then
            for _, r in ipairs(flagged[name]) do items[#items + 1] = r end
        end
    end
    table.sort(items, function(a, b) return (a.t or 0) > (b.t or 0) end)
    f.list:SetData(items)
end, 8, { "Flagged" })

---------------------------------------------------------------------------------------------------
-- Auto-mutes (14.4): every automatic mute, for reviewing bad mutes.

UI.RegisterTab("automutes", "Auto-mutes", function(f)
    f.confirmUntil = false
    local top = UI.Row(f, 22)
    top:SetPoint("TOPLEFT", 0, 0)
    top:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    f.clear = UI.Button(top, "Click again to clear", function(self)
        if f.confirmUntil and GetTime() < f.confirmUntil then
            f.confirmUntil = false
            TC.ClearMuteReport()
        else
            f.confirmUntil = GetTime() + 4
            self:SetText("Click again to clear")
            C_Timer.After(4, function() UI.Refresh() end)
        end
    end)
    f.clear:SetPoint("RIGHT", 0, 0)
    local recheck = UI.Button(top, "Re-check against the lists", function()
        local lifted, kept = TC.RecheckAutoMutes()
        TC.Print(format("Auto-mutes re-checked: %d lifted (no Mute Forever word in their messages now), %d kept.",
            lifted, kept))
        UI.Refresh()
    end)
    recheck:SetPoint("RIGHT", f.clear, "LEFT", -6, 0)
    UI.Tooltip(recheck, "Judges each auto-muted player's logged messages with the current lists and Filter tab "
        .. "choices, and lifts the mutes they wouldn't make now. Runs by itself when the built-in lists or their "
        .. "defaults change.")
    f.title = UI.Line(top, "", "GameFontNormal")
    f.title:SetPoint("LEFT", 0, 0)
    f.title:SetPoint("RIGHT", recheck, "LEFT", -10, 0)
    local hint = UI.Wrap(f, "|cff999999Players muted for a term in a Mute Forever category (Bigotry, unless you "
        .. "changed it on the Filter tab). Clearing the report doesn't unmute anyone.|r")
    hint:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", f, "RIGHT", -24, 0)

    local list = UI.List(f, 62, function(row)
        local buttons, leftmost = UI.RowButtons(row, {
            { "Unmute", function(r) TC.Unmute(r.key) end },
            { "Never mute", function(r) if not TC.rdb.neverMute[r.key] then TC.ToggleNeverMute(r.name) end end },
            { "Wrongly hidden", function(r)
                if not r.flaggedWrong then
                    r.flaggedWrong = true
                    TC.FlagWrongRecord({ t = r.t, channel = r.channel, sender = r.name, text = r.text,
                        trace = format('hidden: term match; term "%s" (%s); Mute Forever: sender muted', r.term or "?", r.cat or "?") })
                end
            end },
        })
        row.unmute, row.never, row.wrong = buttons[1], buttons[2], buttons[3]
        row.head = UI.Line(row, "", "GameFontNormalSmall")
        row.head:SetPoint("TOPLEFT", 4, -6)
        row.head:SetPoint("RIGHT", leftmost, "LEFT", -6, 0)
        row.text = UI.Line(row, "")
        row.text:SetPoint("TOPLEFT", 4, -26)
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.status = UI.Line(row, "")
        row.status:SetPoint("TOPLEFT", 4, -44)
        row.status:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.status:SetTextColor(0.6, 0.6, 0.6)
        UI.Tooltip(row, function() return row.item and row.item.text or "" end)
    end, function(row, r)
        row.head:SetText(format("%s  [%s]  %s  |cffff9060%s \"%s\"|r", date("%Y-%m-%d %H:%M", r.t or 0),
            r.channel or "?", r.name or "?", r.cat or "?", r.term or "?"))
        row.text:SetText(r.text or "")
        local muted = TC.MuteEntry(r.key) ~= nil
        row.status:SetText(muted and "still muted" or (TC.rdb.neverMute[r.key] and "on your never-mute list")
            or (r.lifted and "lifted: the current lists wouldn't mute for this") or "unmuted")
        row.unmute:SetEnabled(muted)
        row.never:SetEnabled(not TC.rdb.neverMute[r.key])
        row.wrong:SetEnabled(not r.flaggedWrong)
    end)
    list.box:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
    list.box:SetPoint("BOTTOMRIGHT", -24, 0)
    f.list = list
end, function(f)
    if not TC.CountMuted then return end   -- Mutes.lua not loaded yet (see Core.lua)
    local report = TC.rdb.muteReport
    f.title:SetText(format("Auto-mutes logged: %d. Players muted now: %d.", #report, (TC.CountMuted())))
    if not (f.confirmUntil and GetTime() < f.confirmUntil) then f.clear:SetText("Clear report") end
    local items = {}
    for i = #report, 1, -1 do items[#items + 1] = report[i] end
    f.list:SetData(items)
end, 9, { "Muted", "Changed", "Flagged" })

-- The Overview's meme words follow the chat: refreshed at most every 2 s while that tab is open.
local lastMemeRefresh = 0
TC.Listen("Shown", function()
    if UI.CurrentTab() == "overview" and GetTime() - lastMemeRefresh >= 2 then
        lastMemeRefresh = GetTime()
        UI.QueueRefresh("Shown")
    end
end)

