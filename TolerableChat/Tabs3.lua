-- Phase 3 tab: Advanced, the OlympusNet listener (spec 5.1, 12).

local _, TC = ...
local UI = TC.UI
local format = string.format

local function NameEdit(parent, key, width)
    local e = UI.Edit(parent, width or 110)
    local function Commit()
        local v = e:GetText():gsub("^%s+", ""):gsub("%s+$", "")
        if v ~= "" and v ~= TC.db.settings[key] then
            TC.NetLeave()
            TC.db.settings[key] = v
            if TC.ListenHere() then TC.NetJoin() end
        end
        e:SetText(TC.db.settings[key])
    end
    e:SetScript("OnEnterPressed", function(self) Commit() self:ClearFocus() end)
    e:SetScript("OnEditFocusLost", Commit)
    function e:Refresh() if not self:HasFocus() then self:SetText(TC.db.settings[key]) end end
    UI.Register(parent, e)
    return e
end

local WARNING = "- Joining their channel puts the character's name in its member list. Every Olympus addon user "
    .. "can see that list, and their addon knows the full member list of every Olympus guild, so anyone who isn't "
    .. "one of them is easy to spot. They may target that character for harassment.\n"
    .. "- If you want their guild lists, use a disposable alt on the same realm and faction (what it hears is shared "
    .. "with your other characters there) and pick |cffffffffThis character only|r, so your main never joins. It "
    .. "takes time: guilds report in every few minutes, so leave it on for 10 minutes or more, then turn it Off.\n"
    .. "- Olympus can break this whenever they like: there are many changes they could make to their addon (the "
    .. "channel name, the prefix, the message format). If the traffic stops or looks wrong, turn it Off.\n"
    .. "- You don't need it. Muting Olympus guilds runs on /who (the Check tab's sweep), nameplates and mouseovers, "
    .. "which are completely separate from this and work the same whether it's on or off."

-- The title and the text in a red-edged box as tall as they are. The box is drawn on textures
-- anchored to the two strings, so it needs no height of its own.
local function WarningBox(f, stack, title, text)
    local head = stack:Add(UI.Text(f, title, "GameFontNormalLarge"), 0, true)
    head:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -10)
    head:SetPoint("RIGHT", f, "RIGHT", -32, 0)
    head:SetTextColor(1, 0.3, 0.3)
    local body = stack:Add(UI.Wrap(f, text), 6, true)
    body:SetPoint("RIGHT", f, "RIGHT", -32, 0)
    local edge = f:CreateTexture(nil, "BACKGROUND")
    edge:SetColorTexture(0.85, 0.15, 0.15, 0.9)
    edge:SetPoint("TOPLEFT", head, "TOPLEFT", -8, 8)
    edge:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 8, -8)
    local fill = f:CreateTexture(nil, "BORDER")
    fill:SetColorTexture(0.18, 0.02, 0.02, 1)
    fill:SetPoint("TOPLEFT", edge, "TOPLEFT", 2, -2)
    fill:SetPoint("BOTTOMRIGHT", edge, "BOTTOMRIGHT", -2, 2)
    return body
end

-- Turning listening on for a character it isn't on for asks first, with the warning in short.
-- done runs however it ends, so the switch shows what is set.
local function AskListen(v, done)
    local s = TC.db.settings
    local widens = (v == "all" and s.listenMode ~= "all") or (v == "here" and not TC.ListenHere())
    if not widens then
        TC.SetListen(v)
        return done()
    end
    local who = v == "all" and "every character you log in on, your main included," or (UnitName("player") or "this character")
    UI.Ask({ text = format("|cffff5050Olympus will be able to see %s in their channel's member list|r, and may target "
            .. "it for harassment.\n\nUse a disposable alt with This character only. Muting Olympus guilds with /who "
            .. "works without this.\n\nListen to OlympusNet anyway?", who),
        yes = "Listen", no = "Cancel",
        onYes = function() TC.SetListen(v) done() end, onNo = done, onEscape = done })
end

local VIEWS = { { "guilds", "Guilds heard on OlympusNet" }, { "channel", "Channel and saved data" } }

-- A view's frame: everything below the view switch, down to the bottom of the tab.
local function Pane(f, below)
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, -8)
    p:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    return p
end

UI.RegisterTab("advanced", "Advanced", function(f)
    f.view = "guilds"
    local stack = UI.Stack(f)
    WarningBox(f, stack, "Read this before listening to OlympusNet", WARNING)
    local listenRow = UI.Row(f, 24)
    local listenLabel = UI.Text(listenRow, "Listen to OlympusNet:")
    listenLabel:SetPoint("LEFT", 4, 0)
    local listen
    listen = UI.Choice(listenRow, "", function()
        local s = TC.db.settings
        local here = (s.listenMode == "here" and not TC.ListenHere() and s.listenCharName)
            and ("Only on " .. s.listenCharName) or "This character only"
        return { { "all", "All characters" }, { "here", here }, { "off", "Off" } }
    end, function() return TC.db.settings.listenMode end, function(v)
        AskListen(v, function() listen:Refresh() end)
    end)
    listen:SetPoint("LEFT", listenLabel, "RIGHT", 10, 0)
    UI.Tooltip(listen, "This character only: no other character of yours joins the channel.")
    f.listenState = UI.Line(listenRow, "")
    f.listenState:SetPoint("LEFT", listen, "RIGHT", 10, 0)
    f.listenState:SetPoint("RIGHT", listenRow, "RIGHT", 0, 0)
    stack:Add(listenRow, 18, true)
    listenRow:SetPoint("RIGHT", f, "RIGHT", -24, 0)

    local viewRow = UI.Row(f, 24)
    f.viewChoice = UI.Choice(viewRow, "", function() return VIEWS end, function() return f.view end,
        function(v) f.view = v UI.Refresh() end)
    f.viewChoice:SetPoint("LEFT", 0, 0)
    f.viewCount = UI.Line(viewRow, "")
    f.viewCount:SetPoint("LEFT", f.viewChoice, "RIGHT", 12, 0)
    f.viewCount:SetPoint("RIGHT", viewRow, "RIGHT", 0, 0)
    stack:Add(viewRow, 10, true)
    viewRow:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    f.panes = { guilds = Pane(f, viewRow), channel = Pane(f, viewRow) }

    -- Guilds heard on OlympusNet
    local p = f.panes.guilds
    local hint = UI.Wrap(p, "|cff999999Guild names heard on OlympusNet (location pings, profession lists, census "
        .. "reports). Nothing heard there mutes anyone. Olympus guilds go into the guild index, and the sweep "
        .. "searches them once the game has shown a member. Guilds without a muted word are only listed: press "
        .. "Mute guild if one of them is theirs.|r")
    hint:SetPoint("TOPLEFT", 0, 0)
    hint:SetPoint("RIGHT", p, "RIGHT", -24, 0)
    local list = UI.List(p, 26, function(row)
        local buttons, leftmost = UI.RowButtons(row, {
            { "Mute guild", function(g) TC.Print(TC.AddGuildWordReport(g.guild)) UI.Refresh() end },
            { "Dismiss", function(g) TC.DismissNetGuild(g.guild) UI.Refresh() end },
        })
        row.mute, row.dismiss = buttons[1], buttons[2]
        row.text = UI.Line(row, "")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", leftmost, "LEFT", -6, 0)
    end, function(row, g)
        -- "OLYMPUS TYCOONS  425 / 978 muted": members muted (or, unmuted, known) against its own count.
        local count = format("%d / %s", g.known or 0, g.total and tostring(g.total) or "?")
        local parts = { g.seen and "seen in game" or "not seen in game yet" }
        if g.faction then parts[#parts + 1] = g.faction end
        if g.senders and g.senders > 0 then parts[#parts + 1] = format("%d sender%s", g.senders, g.senders == 1 and "" or "s") end
        parts[#parts + 1] = "last " .. date("%m-%d %H:%M", g.last or 0)
        row.text:SetText(format("%s  %s  |cff999999%s|r", g.guild,
            g.olympus and ("|cffff6060" .. count .. " muted|r") or ("|cffffd100" .. count .. " known, not muted|r"),
            table.concat(parts, "  ·  ")))
        row.mute:SetShown(not g.olympus)
        row.dismiss:SetShown(not g.olympus)
    end)
    list.box:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -6)
    list.box:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -24, 0)
    f.list = list

    -- Channel and saved data
    p = f.panes.channel
    local pstack = UI.Stack(p)
    pstack:Add(UI.Wrap(p, "|cff999999TolerableChat never sends anything on OlympusNet; it only listens, and only "
        .. "for guild names, member counts and factions. Who sends the traffic, who is in the channel and the "
        .. "player names in census reports aren't used. Forget clears what was heard on this realm.|r"), 0, true)
        :SetPoint("RIGHT", p, "RIGHT", -24, 0)
    f.status = pstack:Add(UI.Wrap(p, ""), 8, true)
    f.status:SetPoint("RIGHT", p, "RIGHT", -24, 0)
    local channels = UI.Row(p, 24)
    local channelsLabel = UI.Text(channels, "Channels:")
    channelsLabel:SetPoint("LEFT", 4, 0)
    local alliance = NameEdit(channels, "netChannelAlliance")
    alliance:SetPoint("LEFT", channelsLabel, "RIGHT", 12, 0)
    local horde = NameEdit(channels, "netChannelHorde")
    horde:SetPoint("LEFT", alliance, "RIGHT", 10, 0)
    local prefixLabel = UI.Text(channels, "Prefix:")
    prefixLabel:SetPoint("LEFT", horde, "RIGHT", 14, 0)
    local prefix = NameEdit(channels, "netPrefix", 90)
    prefix:SetPoint("LEFT", prefixLabel, "RIGHT", 10, 0)
    pstack:Add(channels, 8, true)
    local forgetRow = UI.Row(p, 24)
    f.notice = UI.SettingCheck(forgetRow, "Chat line for each new guild heard", "netNotice")
    f.notice:SetPoint("LEFT", 0, 0)
    local forget = UI.Button(forgetRow, "Forget OlympusNet data...", function()
        UI.Ask({ text = "Forget everything heard on OlympusNet on this realm: the OlympusNet guild list, Olympus "
                .. "guilds never seen in game, and census member counts? Players the game showed in a muted guild stay "
                .. "muted.",
            yes = "Forget", no = "Cancel",
            onYes = function()
                local n = TC.ForgetNetData()
                TC.Print(format("Forgot %d Olympus guilds not seen in game and %d other OlympusNet guilds.",
                    n.guilds, n.netGuilds))
            end })
    end)
    forget:SetPoint("RIGHT", 0, 0)
    pstack:Add(forgetRow, 4, true)
    forgetRow:SetPoint("RIGHT", p, "RIGHT", -24, 0)
end, function(f)
    for id, pane in pairs(f.panes) do pane:SetShown(id == f.view) end
    local s = TC.db.settings
    f.listenState:SetText(TC.ListenHere() and "|cffff6060On: Olympus can see this character in the channel.|r"
        or s.listenMode == "here" and "|cff999999Off on this character.|r" or "")
    if f.view == "guilds" then
        local items, olympus, muted, total = TC.NetHeardGuilds(), 0, 0, 0
        for _, g in ipairs(items) do
            if g.olympus then
                olympus, muted, total = olympus + 1, muted + (g.known or 0), total + (g.total or 0)
            end
        end
        f.viewCount:SetText(format("|cff999999%d Olympus guilds: %d muted of %d they report; %d other guilds|r",
            olympus, muted, total, #items - olympus))
        f.list:SetData(items)
    else
        local net = TC.net
        local counts = {}
        for kind, n in pairs(net.counts) do counts[#counts + 1] = format("%d %s", n, kind) end
        table.sort(counts)
        local d = TC.DiagData() or { netCapture = {} }
        f.viewCount:SetText(format("%s%s", TC.NetChannelName() or "?", net.joined and " (joined)" or " (not joined)"))
        f.status:SetText(format("Channel: %s%s%s.  Members: %d.  Traffic this session: %s; kinds TolerableChat doesn't "
            .. "know: %s.  Unknown speakers since login: %d.  Saving every message: %s, %d saved (/tc net capture).",
            TC.NetChannelName() or "?", net.joined and " (joined)" or " (not joined)",
            net.joinedOther and (", and the other faction's " .. net.joinedOther) or "", net.members or 0,
            counts[1] and table.concat(counts, ", ") or "none", TC.NetUnknownKinds() or "none", TC.UnknownSpeakers(),
            d.capturing and "on" or "off", #d.netCapture))
    end
end, 11, { "Watch", "Changed", "Settings", "NetGuilds" })

TC.Listen("Watch", function() UI.QueueRefresh("Watch") end)
TC.Listen("NetGuilds", function() UI.QueueRefresh("NetGuilds") end)
TC.Listen("Share", function() UI.QueueRefresh("Share") end)
