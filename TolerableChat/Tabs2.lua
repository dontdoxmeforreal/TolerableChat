-- Phase 2 tabs: People, Guilds, Check and Settings (spec 5.1), and the small Check window (11).

local _, TC = ...
local UI = TC.UI
local format, lower = string.format, TC.Lower

local function When(t)
    return t and date("%Y-%m-%d", t) or "?"
end

-- A row with an edit box stretched up to a button on its right.
local function AddRow(parent, buttonText, onAdd)
    local row = UI.Row(parent, 24)
    local button = UI.Button(row, buttonText, nil)
    button:SetPoint("RIGHT", 0, 0)
    local edit = UI.Edit(row, 100, function(text, box)
        if text ~= "" then onAdd(text, box) end
    end)
    edit:SetPoint("LEFT", 6, 0)
    edit:SetPoint("RIGHT", button, "LEFT", -10, 0)
    button:SetScript("OnClick", function()
        local text = edit:GetText()
        if text ~= "" then onAdd(text, edit) end
    end)
    row.edit, row.button = edit, button
    return row
end

-- Shift-clicking a player's name in chat while one of our name boxes has focus puts the name there.
local nameBoxes = {}
hooksecurefunc("SetItemRef", function(link)
    if type(link) ~= "string" or TC.IsSecret(link) or not IsModifiedClick("CHATLINK") then return end
    local name = link:match("^player:([^:]+)")
    if not name then return end
    for box in pairs(nameBoxes) do
        if box:HasFocus() then box:SetText(name) end
    end
end)

---------------------------------------------------------------------------------------------------
-- People (9, 8)

local PEOPLE_VIEWS = { { "muted", "Muted players" }, { "never", "Never-mute list" }, { "names", "Name keywords" } }
local SORTS = { { "name", "Sort by name" }, { "guild", "Sort by guild" } }

UI.RegisterTab("people", "People", function(f)
    f.view, f.sort, f.search = "muted", "name", ""
    local stack = UI.Stack(f)
    local top = UI.Row(f, 24)
    f.viewChoice = UI.Choice(top, "", function() return PEOPLE_VIEWS end, function() return f.view end,
        function(v) f.view = v UI.Refresh() end)
    f.viewChoice:SetPoint("LEFT", 0, 0)
    f.sortChoice = UI.Choice(top, "", function() return SORTS end, function() return f.sort end,
        function(v) f.sort = v UI.Refresh() end)
    f.sortChoice:SetPoint("LEFT", f.viewChoice, "RIGHT", 4, 0)
    local searchLabel = UI.Text(top, "Search")
    searchLabel:SetPoint("LEFT", f.sortChoice, "RIGHT", 12, 0)
    local search = UI.Edit(top, 140)
    search:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    search:SetScript("OnTextChanged", function(self)
        f.search = lower(self:GetText())
        UI.QueueRefresh()
    end)
    stack:Add(top, 0, true)
    top:SetPoint("RIGHT", f, "RIGHT", -24, 0)

    f.add = AddRow(f, "Mute", function(text, box)
        if f.view == "muted" then
            local names = {}
            for part in text:gmatch("[^,]+") do names[#names + 1] = part end
            for _, name in ipairs(names) do TC.MuteByHand(name) end
        elseif f.view == "never" then
            for part in text:gmatch("[^,]+") do
                local key = TC.NameKey(part)
                if key and not TC.rdb.neverMute[key] then TC.ToggleNeverMute(part) end
            end
        else
            TC.AddNameWord(text)
        end
        box:SetText("")
        UI.Refresh()
    end)
    nameBoxes[f.add.edit] = true
    stack:Add(f.add, 6, true)
    f.add:SetPoint("RIGHT", f, "RIGHT", -24, 0)

    local options = UI.Grid(f, 26, 18)
    options:Add(UI.SettingCheck(options, "Never mute friends", "neverMuteFriends",
        "WoW friends and Battle.net friends' current characters are never hidden."))
    options:Add(UI.SettingCheck(options, "Never mute guild members", "neverMuteGuild",
        "Your guild's members are never hidden when they talk outside guild chat."))
    f.options = options
    stack:Add(options, 6, true)
    options:SetPoint("RIGHT", f, "RIGHT", -24, 0)

    f.hint = stack:Add(UI.Wrap(f, ""), 2, true)
    f.hint:SetPoint("RIGHT", f, "RIGHT", -24, 0)

    local list = UI.List(f, 44, function(row)
        local buttons, leftmost = UI.RowButtons(row, {
            { "Unmute", function(r) if TC.Unmute(r.key) then UI.Refresh() end end },
            { "Re-check", function(r)
                local who, was = TC.RecheckGuild(r.name)
                if who then TC.Print(format("%s: the guild mute%s is lifted until the game shows their guild again.", who,
                    was and (" for " .. was) or "")) end
                UI.Refresh()
            end },
            { "Never mute", function(r) if not TC.rdb.neverMute[r.key] then TC.ToggleNeverMute(r.name) end end },
            { "Remove", function(r)
                if r.word then TC.RemoveNameWord(r.word) elseif TC.rdb.neverMute[r.key] then TC.ToggleNeverMute(r.name) end
            end },
        })
        row.unmute, row.recheck, row.never, row.remove = buttons[1], buttons[2], buttons[3], buttons[4]
        row.head = UI.Line(row, "", "GameFontNormalSmall")
        row.head:SetPoint("TOPLEFT", 4, -6)
        row.head:SetPoint("RIGHT", leftmost, "LEFT", -6, 0)
        row.text = UI.Line(row, "")
        row.text:SetPoint("TOPLEFT", 4, -24)
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.text:SetTextColor(0.7, 0.7, 0.7)
    end, function(row, r)
        local isMuted, isNever, isWord = r.reason ~= nil, r.never, r.word ~= nil
        row.unmute:SetShown(isMuted)
        row.unmute:SetEnabled(isMuted and TC.rdb.mutes[r.key] ~= nil)
        row.recheck:SetShown(isMuted and TC.GuildMutedBy(TC.rdb.players[r.key]) ~= nil)
        row.never:SetShown(isMuted)
        row.remove:SetShown(isNever or isWord)
        if isWord then
            row.head:SetText(format('Names containing "%s"', r.word))
            row.text:SetText("Any player whose name contains this is muted.")
        elseif isNever then
            row.head:SetText(r.name)
            row.text:SetText("On your never-mute list since " .. When(r.added))
        else
            local exempt = TC.MutedExempt(r)   -- only for the rows on screen
            row.head:SetText(format("%s%s  |cffff9060%s|r", r.name, r.guild and ("  <" .. r.guild .. ">") or "", r.reason)
                .. (exempt and format("  |cff60ff60muted, but exempt (%s)|r", exempt) or ""))
            row.text:SetText(format("First seen %s, last seen %s.%s", When(r.first), When(r.last),
                TC.rdb.mutes[r.key] and "" or " Muted by guild for good, even if they leave: Re-check looks again."))
        end
    end)
    list.box:SetPoint("TOPLEFT", f.hint, "BOTTOMLEFT", 0, -6)
    list.box:SetPoint("BOTTOMRIGHT", -24, 0)
    f.list = list
end, function(f)
    local items = {}
    local search = f.search
    local function Matches(...)
        if search == "" then return true end
        for i = 1, select("#", ...) do
            local s = select(i, ...)
            if type(s) == "string" and lower(s):find(search, 1, true) then return true end
        end
        return false
    end
    if f.view == "muted" then
        for _, r in ipairs(TC.MutedPlayers()) do
            if Matches(r.name, r.guild, r.reason) then items[#items + 1] = r end
        end
        f.add.button:SetText("Mute")
        f.hint:SetText(format("|cff999999%d muted players. Type a name (or several, with commas) and Mute; or shift-click "
            .. "a name in chat into the box.|r", #items))
    elseif f.view == "never" then
        for key, v in pairs(TC.rdb.neverMute) do
            if Matches(v.name) then
                items[#items + 1] = { key = key, name = v.name, sortName = lower(v.name or ""), added = v.added, never = true }
            end
        end
        f.add.button:SetText("Never mute")
        f.hint:SetText("|cff999999Never-mute names are never hidden, whatever they say. Friends and guild members "
            .. "(boxes above) and your group are never hidden either.|r")
    else
        for _, w in ipairs(TC.db.nameWords) do
            if Matches(w) then items[#items + 1] = { word = w, name = w, sortName = w } end
        end
        f.add.button:SetText("Add keyword")
        f.hint:SetText("|cff999999Any player whose name contains a keyword is muted.|r")
    end
    UI.FitButton(f.add.button)
    -- sortName: lowercased once per row, not in every comparison
    if f.sort == "guild" then
        table.sort(items, function(a, b)
            local ga, gb = a.guild or "~", b.guild or "~"
            if ga ~= gb then return ga < gb end
            return a.sortName < b.sortName
        end)
    else
        table.sort(items, function(a, b) return a.sortName < b.sortName end)
    end
    f.options:Layout()
    f.list:SetData(items)
end, 3, { "Changed", "Muted", "Settings" })

---------------------------------------------------------------------------------------------------
-- Guilds (10)

-- For each guild in the index, the shortest other indexed name inside its own: /who matches any part
-- of a guild name, so the sweep's search for that one lists this guild's members too.
local function SearchedWith(list)
    local via = {}
    for _, a in ipairs(list) do
        local la = lower(a.guild)
        for _, b in ipairs(list) do
            local lb = lower(b.guild)
            if #lb < #la and string.find(la, lb, 1, true) and (not via[a.guild] or #lb < #lower(via[a.guild])) then
                via[a.guild] = b.guild
            end
        end
    end
    return via
end

local GUILD_VIEWS = { { "known", "Known guilds" }, { "index", "Muted guild index" }, { "words", "Muted guild words" },
                      { "exceptions", "Guild exceptions" },
                      { "net", "OlympusNet guilds, not muted" }, { "lookalike", "Look-alike guilds" },
                      { "filtered", "Named with a filtered word" } }

local GUILD_HINTS = {
    index = "Every guild with a muted guild word in its name seen on this realm, from the sweeps, nameplates and "
        .. "mouseover. Each is kept for good and gets a /who search in the sweeps. Members known (shown in it by the "
        .. "game) / the guild's own member count, when known. /who matches any part of a guild name, so a guild "
        .. "whose name contains another's is found by that guild's search (\"in RAIDERS's search\"). If you listen to "
        .. "OlympusNet (Advanced tab), guilds only heard there wait until the game shows a member.",
    known = "Guilds of players the game has shown on this realm (/who, nameplates, mouseover, target, your group, "
        .. "inspect, guild invites). Muted guilds first. Type a guild's name and Mute guild to add it: the guild sweep "
        .. "searches for it and mutes its members as they're found.",
    words = "Any guild whose name contains one of these is muted, whatever else it contains. Spaces, dots and digit "
        .. "spellings don't matter: R.A.I.D and r41d match raid. The guild sweep searches for each word.",
    exceptions = "Exact guild names that are never muted by a guild word. Making a guild an exception shows all its "
        .. "members again at once.",
    net = "Guilds heard on OlympusNet (only while you listen, Advanced tab) whose names contain no muted word. "
        .. "Nothing here is muted: Mute guild if you want it muted. \"seen in game\": the game has shown someone in it.",
    lookalike = "Guilds whose names are one letter away from a muted word (a letter changed, added, dropped or swapped), "
        .. "which no word and no /who search catches. Nothing here is muted: Mute guild if it's one you meant, or leave it.",
    filtered = "Guilds whose names contain a Timeout or Hide Only word (a politician, Thunderfury). Nothing here is "
        .. "muted: a guild mute is for good and hides everything its members say, so you decide each one. Guilds named "
        .. "with a Mute Forever word (slurs, bigotry) are muted without asking. Place names don't count.",
}

UI.RegisterTab("guilds", "Guilds", function(f)
    f.view = "known"
    local stack = UI.Stack(f)
    local top = UI.Row(f, 24)
    f.viewChoice = UI.Choice(top, "", function() return GUILD_VIEWS end, function() return f.view end,
        function(v) f.view = v UI.Refresh() end)
    f.viewChoice:SetPoint("LEFT", 0, 0)
    f.restore = UI.Button(top, "Restore default words", function()
        local n = TC.RestoreGuildWords()
        TC.Print(n > 0 and format("Put back %d default guild word%s.", n, n == 1 and "" or "s")
            or "Every default guild word is on the list already.")
        UI.Refresh()
    end)
    f.restore:SetPoint("RIGHT", 0, 0)
    f.count = UI.Line(top, "")
    f.count:SetPoint("LEFT", f.viewChoice, "RIGHT", 12, 0)
    f.count:SetPoint("RIGHT", f.restore, "LEFT", -8, 0)
    stack:Add(top, 0, true)
    top:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    f.add = AddRow(f, "Mute guild", function(text, box)
        if f.view == "exceptions" then
            TC.Print(TC.ExceptionReport(text))
        else
            TC.Print(TC.AddGuildWordReport(text))
        end
        box:SetText("")
        UI.Refresh()
    end)
    stack:Add(f.add, 6, true)
    f.add:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    f.hint = stack:Add(UI.Wrap(f, ""), 2, true)
    f.hint:SetPoint("RIGHT", f, "RIGHT", -24, 0)

    local list = UI.List(f, 26, function(row)
        local buttons, leftmost = UI.RowButtons(row, {
            { "Mute guild", function(r)
                if r.guild then TC.Print(TC.AddGuildWordReport(r.guild)) UI.Refresh() end
            end },
            { "Exception", function(r)
                if r.guild then TC.Print(TC.ExceptionReport(r.guild)) UI.Refresh() end
            end },
            { "Dismiss", function(r) if r.net then TC.DismissNetGuild(r.guild) UI.Refresh() end end },
            { "Remove", function(r)
                if r.word then TC.RemoveGuildWord(r.word)
                elseif r.exceptionName then TC.Print(TC.ExceptionReport(r.exceptionName)) end
                UI.Refresh()
            end },
        })
        row.mute, row.exception, row.dismiss, row.remove = buttons[1], buttons[2], buttons[3], buttons[4]
        row.text = UI.Line(row, "")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", leftmost, "LEFT", -6, 0)
    end, function(row, r)
        local guildRow = r.guild ~= nil
        row.mute:SetShown(guildRow and not r.word and not r.exception and not r.index)
        row.exception:SetShown(guildRow and (r.word ~= nil or r.exception) and not r.net and not r.lookalike
            and not r.filtered)
        row.dismiss:SetShown(r.net == true)
        row.remove:SetShown(not guildRow and (r.word ~= nil or r.exceptionName ~= nil))
        if guildRow then
            row.exception:SetText(r.exception and "Not exception" or "Exception")
            UI.FitButton(row.exception)
        end
        if r.index then
            local g = r.index
            row.text:SetText(format("%s  |cff999999%d known / %s members%s%s%s|r", g.guild, g.known,
                g.total and tostring(g.total) or "?", g.faction and ("  " .. g.faction) or "",
                g.confirmed and "" or "  (not seen in game yet)", r.via and ("  in " .. r.via .. "'s search") or ""))
        elseif r.net then
            local rec = r.record
            row.text:SetText(format("%s  |cff999999%d sender%s%s%s%s|r%s", r.guild, rec.senders or 0,
                (rec.senders or 0) == 1 and "" or "s", rec.total and format(", census: %d members", rec.total) or "",
                rec.faction and (", " .. rec.faction) or "", ", last " .. date("%m-%d %H:%M", rec.last or 0),
                rec.seen and "  |cffffd100seen in game|r" or ""))
        elseif r.lookalike then
            row.text:SetText(format('%s  |cff999999%d seen, looks like "%s"|r', r.guild, r.count, r.lookalike))
        elseif r.filtered then
            row.text:SetText(format('%s  |cff999999%d seen,|r |cffffd100"%s"|r |cff999999(%s)|r', r.guild, r.count,
                r.filtered, r.cat))
        elseif guildRow then
            row.text:SetText(format("%s  |cff999999%d seen|r  %s", r.guild, r.count,
                r.exception and "|cff60ff60exception|r" or (r.word and format('|cffff6060muted ("%s")|r', r.word) or "")))
        elseif r.word then
            row.text:SetText(r.word)
        else
            row.text:SetText(r.exceptionName)
        end
    end)
    list.box:SetPoint("TOPLEFT", f.hint, "BOTTOMLEFT", 0, -6)
    list.box:SetPoint("BOTTOMRIGHT", -24, 0)
    f.list = list
end, function(f)
    local items = {}
    f.restore:SetShown(f.view == "words")
    f.add:SetShown(f.view == "known" or f.view == "words" or f.view == "exceptions")
    if f.view == "known" then
        items = TC.KnownGuilds()
        local muted = 0
        for _, g in ipairs(items) do if g.word then muted = muted + 1 end end
        f.count:SetText(format("|cff999999%d guilds seen, %d muted|r", #items, muted))
        f.add.button:SetText("Mute guild")
    elseif f.view == "index" then
        local list = TC.OlympusCoverage()
        local via, known, total, horde, alliance = SearchedWith(list), 0, 0, 0, 0
        for _, g in ipairs(list) do
            known, total = known + g.known, total + (g.total or 0)
            items[#items + 1] = { guild = g.guild, index = g, via = via[g.guild] }
        end
        for _, pl in pairs(TC.rdb.players) do
            if pl.guild and TC.GuildMuted(pl.guild) then
                if pl.faction == "Horde" then horde = horde + 1 elseif pl.faction == "Alliance" then alliance = alliance + 1 end
            end
        end
        f.count:SetText(format("|cff999999%d guilds, %d members known%s%s|r", #list, known,
            (horde + alliance) > 0 and format(" (%d Horde, %d Alliance)", horde, alliance) or "",
            total > 0 and format("; their own counts add up to %d", total) or ""))
    elseif f.view == "words" then
        for _, w in ipairs(TC.db.guildWords) do items[#items + 1] = { word = w } end
        f.count:SetText(format("|cff999999%d words|r", #items))
        f.add.button:SetText("Add word")
    elseif f.view == "exceptions" then
        for _, name in pairs(TC.db.guildExceptions) do items[#items + 1] = { exceptionName = name } end
        table.sort(items, function(a, b) return a.exceptionName < b.exceptionName end)
        f.count:SetText(format("|cff999999%d exceptions|r", #items))
        f.add.button:SetText("Add exception")
    elseif f.view == "net" then
        for _, g in ipairs(TC.NetGuilds()) do items[#items + 1] = { guild = g.guild, record = g.record, net = true } end
        f.count:SetText(format("|cff999999%d guilds|r", #items))
    elseif f.view == "filtered" then
        for _, g in ipairs(TC.FilteredNameGuilds()) do
            items[#items + 1] = { guild = g.guild, count = g.count, filtered = g.word, cat = g.cat }
        end
        f.count:SetText(format("|cff999999%d guilds|r", #items))
    else
        for _, g in ipairs(TC.LookAlikeGuilds()) do
            items[#items + 1] = { guild = g.guild, count = g.count, lookalike = g.word }
        end
        f.count:SetText(format("|cff999999%d guilds|r", #items))
    end
    f.hint:SetText("|cff999999" .. GUILD_HINTS[f.view] .. "|r")
    UI.FitButton(f.add.button)
    f.list:SetData(items)
end, 4, { "Changed", "Settings", "NetGuilds" })

---------------------------------------------------------------------------------------------------
-- Check (11): the tab and the small detachable window share one status.

local checkWindow

local function StatusText()
    return table.concat(TC.CheckStatus(), "\n")
end

-- "Next /who" when a press will search, the seconds left otherwise; the width fits the longest label.
local function UpdateButton(button)
    local wait, pending = TC.CheckCooldown(), TC.CheckPending()
    local ready = not pending and wait <= 0
    button:SetText(ready and "Next /who" or pending and "Next /who (...)" or format("Next /who (%d)", math.ceil(wait)))
    button:SetEnabled(ready)
end

local function SizeButton(button)
    button:SetText("Next /who (30)")
    UI.FitButton(button)
    UpdateButton(button)
end

local function CreateCheckWindow()
    local w = CreateFrame("Frame", "TolerableChatCheckFrame", UIParent, "BasicFrameTemplateWithInset")
    w:Hide()
    w:SetSize(380, 170)
    local pos = TC.db.settings.checkWindow
    if type(pos) == "table" and pos.point then w:SetPoint(pos.point, UIParent, pos.point, pos.x, pos.y)
    else w:SetPoint("RIGHT", -80, 0) end
    w:SetFrameStrata("MEDIUM")
    w:SetClampedToScreen(true)
    w:EnableMouse(true)
    w:SetMovable(true)
    w:RegisterForDrag("LeftButton")
    w:SetScript("OnDragStart", w.StartMoving)
    w:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        TC.db.settings.checkWindow = { point = point, x = x, y = y }
    end)
    if w.TitleText then w.TitleText:SetText("TolerableChat check") end
    w.button = UI.Button(w, "Next /who", function() TC.CheckNext() end, nil, 28)
    w.button:SetNormalFontObject("GameFontNormal")
    w.button:SetPoint("TOPLEFT", 12, -30)
    SizeButton(w.button)
    w.status = UI.Wrap(w, "")
    w.status:SetPoint("TOPLEFT", w.button, "BOTTOMLEFT", 2, -8)
    w.status:SetPoint("RIGHT", w, "RIGHT", -12, 0)
    local tick, slow = 0, 1
    w:SetScript("OnUpdate", function(self, elapsed)   -- only while the window is open
        tick, slow = tick + elapsed, slow + elapsed
        if tick < 0.25 then return end
        tick = 0
        UpdateButton(self.button)
        if slow < 1 then return end
        slow = 0
        self.status:SetText(StatusText())
        -- tall enough for the status lines at any font size
        local height = 30 + self.button:GetHeight() + 8 + (self.status:GetStringHeight() or 60) + 14
        if math.abs(self:GetHeight() - height) > 1 then self:SetHeight(height) end
    end)
    checkWindow = w
end

function TC.ToggleCheckWindow()
    if not checkWindow then CreateCheckWindow() end
    checkWindow:SetShown(not checkWindow:IsShown())
end

TC.Listen("Check", function()
    if checkWindow and checkWindow:IsShown() then checkWindow.status:SetText(StatusText()) end
    UI.QueueRefresh("Check")
end)

UI.RegisterTab("check", "Check", function(f)
    local stack = UI.Stack(f)
    local top = UI.Row(f, 30)
    f.button = UI.Button(top, "Next /who", function() TC.CheckNext() end, nil, 30)
    f.button:SetNormalFontObject("GameFontNormal")
    SizeButton(f.button)
    f.button:SetPoint("LEFT", 0, 0)
    local small = UI.Button(top, "Small window", function() TC.ToggleCheckWindow() end)
    small:SetPoint("LEFT", f.button, "RIGHT", 10, 0)
    stack:Add(top, 0, true)
    f.status = stack:Add(UI.Wrap(f, ""), 8, true)
    f.status:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    stack:Add(UI.Wrap(f, "|cff999999One /who every 5 seconds: any key press does it once it's due (see below), or the "
        .. "button or its key binding \"Next /who\". Each search reads the answer quietly. Nearly every press is a search of the "
        .. "guild sweep: each muted guild word, then each muted guild in the index (a guild whose name contains "
        .. "another's is in that one's search), at all levels. A search showing 50 players is split by level range, "
        .. "then class, race and zone, and a guild search then by letters in the name. Everyone found in a muted guild "
        .. "is muted. When a discovery sweep ends (every "
        .. "third sweep, when the guild word searches are split too), everyone else seen online during it (talking, "
        .. "on a nameplate or moused over) is cleared at once, without a search of their own. Only the players below get one: "
        .. "those you add with Check or Re-check guild. /who only shows your own faction.|r"), 6, true):SetPoint("RIGHT", f, "RIGHT", -24, 0)
    stack:Add(UI.Check(f, "Any key press runs the next /who when it's due (not in combat)",
        function() return TC.db.settings.keyWho end, function(v) TC.SetKeyWho(v) end), 6)
    stack:Add(UI.SettingCheck(f, "Learn guilds from nameplates as they appear (read only; nameplates aren't changed)",
        "learnNameplates"), 2)
    local header = stack:Add(UI.Header(f, "Own searches (added with Check or Re-check guild)"), 10, true)
    local list = UI.List(f, 22, function(row)
        row.text = UI.Line(row, "")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", -4, 0)
    end, function(row, item)
        row.text:SetText(format("%s  |cff999999%s|r", item.name, TC.CHECK_REASONS[item.reason]))
    end)
    list.box:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
    list.box:SetPoint("BOTTOMRIGHT", -24, 0)
    f.list = list
    local tick, slow = 0, 0
    f:SetScript("OnUpdate", function(self, elapsed)   -- only while the tab is open: the countdown
        tick, slow = tick + elapsed, slow + elapsed
        if tick < 0.25 then return end
        tick = 0
        UpdateButton(self.button)
        if slow >= 1 then
            slow = 0
            self.status:SetText(StatusText())
        end
    end)
end, function(f)
    f.status:SetText(StatusText())
    UpdateButton(f.button)
    f.list:SetData(TC.OwnSearchQueue())
end, 6, { "Check", "Changed", "Settings" })

---------------------------------------------------------------------------------------------------
-- Settings (5.1): what happens to muted players, and the rest. Few switches, each doing one thing.

local TRADE_OPTIONS = { { "ask", "Ask me" }, { "decline", "Decline" } }

UI.RegisterTab("settings", "Settings", function(f)
    local stack = UI.Stack(f)
    stack:Add(UI.Header(f, "Muted players"), 0, true)
    stack:Add(UI.SettingCheck(f, "Decline their group invites, guild invites and duels", "declineRequests",
        "After a random 2-8 second pause, with the pop-up out of sight meanwhile."), 6)
    stack:Add(UI.SettingCheck(f, "Decline at once (no 2-8 second pause)", "declineInstant"), 2)
    local tradeRow = UI.Row(f, 24)
    local tradeLabel = UI.Text(tradeRow, "Their trades:")
    tradeLabel:SetPoint("LEFT", 4, 0)
    local trade = UI.Choice(tradeRow, "", function() return TRADE_OPTIONS end,
        function() return TC.db.settings.trades end, function(v) TC.db.settings.trades = v end)
    trade:SetPoint("LEFT", tradeLabel, "RIGHT", 10, 0)
    UI.Tooltip(trade, "Ask me: \"Trade with Name?\" with Allow and Decline; Allow covers them for 10 minutes.")
    stack:Add(tradeRow, 4, true)
    stack:Add(UI.SettingCheck(f, "Warn me when I invite or whisper a muted player", "warnings"), 4)
    stack:Add(UI.SettingCheck(f, "Hide their chat bubbles (open world)", "bubbles"), 2)
    stack:Add(UI.SettingCheck(f, "Show \"muted\" in their tooltip", "tooltip"), 2)
    stack:Add(UI.SettingCheck(f, "Players on your game ignore list are muted here too (all your characters on this realm)",
        "mirrorIgnore", "One way only: TolerableChat never adds to or removes from the game's ignore list, and "
            .. "unignoring someone changes nothing here.", function() TC.SyncIgnoreList() end), 2)
    stack:Add(UI.SettingCheck(f, "Mute guilds whose names contain a Mute Forever word (a slur or other bigotry)",
        "offensiveGuildNames", "TolerableChat tries to deobfuscate guild names first (digits, symbols and accents "
            .. "read as letters). A guild exception still wins.", function() TC.Notify("GuildsChanged") TC.Notify("Changed") end), 2)

    stack:Add(UI.Header(f, "Sharing"), 16, true)
    stack:Add(UI.Wrap(f, "|cff999999Sends your muted guild words, guild exceptions, name keywords and custom terms; "
        .. "never players or the default terms. The other player sees a preview before anything changes.|r"), 2, true)
        :SetPoint("RIGHT", f, "RIGHT", -24, 0)
    local shareRow = UI.Row(f, 24)
    local shareLabel = UI.Text(shareRow, "Share my lists with:")
    shareLabel:SetPoint("LEFT", 4, 0)
    local function Share(target)
        local ok, why = TC.ShareLists(target)
        if not ok then TC.Print(why) end
    end
    local group = UI.Button(shareRow, "My group", function() Share("group") end)
    group:SetPoint("LEFT", shareLabel, "RIGHT", 10, 0)
    local guild = UI.Button(shareRow, "My guild", function() Share("guild") end)
    guild:SetPoint("LEFT", group, "RIGHT", 4, 0)
    local player = UI.Edit(shareRow, 140, function(text) if text ~= "" then Share(text) end end)
    player:SetPoint("LEFT", guild, "RIGHT", 14, 0)
    nameBoxes[player] = true
    local send = UI.Button(shareRow, "Send to player", function() if player:GetText() ~= "" then Share(player:GetText()) end end)
    send:SetPoint("LEFT", player, "RIGHT", 6, 0)
    stack:Add(shareRow, 4, true)
    f.shareStatus = stack:Add(UI.Line(f, ""), 2, true)
    stack:Add(UI.SettingCheck(f, "Accept lists other players share with me", "acceptShares"), 4)
    local listsRow = UI.Row(f, 24)
    local export = UI.Button(listsRow, "Export my lists...", function()
        UI.ShowTextBox("TolerableChat lists", TC.SerializeLists())
    end)
    export:SetPoint("LEFT", 0, 0)
    local import = UI.Button(listsRow, "Import lists...", function()
        UI.ShowTextBox("Import lists: paste them, then Preview", "", "Preview", function(text)
            UI.HideTextBox()
            TC.ShowSharePreview("The pasted text", TC.ParseLists(text))
        end)
    end)
    import:SetPoint("LEFT", export, "RIGHT", 4, 0)
    stack:Add(listsRow, 6, true)

    stack:Add(UI.Header(f, "Other"), 16, true)
    local diagRow = UI.Row(f, 24)
    local diag = UI.Button(diagRow, "Diagnostics report...", function()
        if not TC.DiagReport then return TC.Print("Diagnostics aren't loaded: exit the game fully and start it again.") end
        UI.ShowTextBox("TolerableChat diagnostics (Ctrl+A, Ctrl+C to copy)", TC.DiagReport())
    end)
    diag:SetPoint("LEFT", 0, 0)
    local diagNote = UI.Line(diagRow, "|cff999999What has worked and what hasn't since login; /tc diag in chat.|r")
    diagNote:SetPoint("LEFT", diag, "RIGHT", 10, 0)
    diagNote:SetPoint("RIGHT", 0, 0)
    stack:Add(diagRow, 6, true)
    f.health = stack:Add(UI.Wrap(f, ""), 4, true)
    f.health:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    stack:Add(UI.SettingCheck(f, "Debug output in chat (each hidden message and its reason, and the diagnostics log)",
        "debug"), 6)
end, function(f)
    f.shareStatus:SetText("|cff999999" .. (TC.share and TC.share.status or "") .. "|r")
    local errors = TC.counters.errors or 0
    f.health:SetText(errors > 0 and format("|cffff6060%d error%s caught since login: see the diagnostics report.|r",
        errors, errors == 1 and "" or "s") or "|cff60ff60No errors since login.|r")
end, 10, { "Settings", "Share", "Changed" })
