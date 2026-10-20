-- Right-click menu items (spec 5.3) on player menus: chat names, target, party, raid, friends,
-- guild roster and communities.

local _, TC = ...

local MENUS = { "PLAYER", "PARTY", "RAID_PLAYER", "RAID", "FRIEND", "FRIEND_OFFLINE", "ENEMY_PLAYER", "TARGET",
                "FOCUS", "GUILD", "GUILD_OFFLINE", "COMMUNITIES_WOW_MEMBER", "COMMUNITIES_GUILD_MEMBER", "CHAT_ROSTER" }

-- The player's name and realm, or nil. In combat, and on some secure menus, the game gives the name as
-- a secret value; then TolerableChat's items aren't added to that menu.
local function MenuName(contextData)
    local name, realm = TC.Str(contextData.name), TC.Str(contextData.server)
    if not name and contextData.unit and not TC.IsSecret(contextData.unit) then
        local n, r = UnitName(contextData.unit)
        name, realm = TC.Str(n), TC.Str(r)
    end
    return name, realm
end

-- The line's lineID, when the menu gives a readable one (a secret can't even be compared).
local function LineID(contextData)
    local id = contextData.lineID
    if TC.IsSecret(id) then return nil end
    return tonumber(id)
end

-- Menus opened from a name in a chat line carry the chat frame, and usually the line's lineID.
local function FromChatLine(contextData)
    return LineID(contextData) ~= nil or (contextData.chatFrame ~= nil and not contextData.friendsList)
end

local function Short(text, n)
    if #text > n then return text:sub(1, n - 3) .. "..." end
    return text
end

local function Flagged(e)
    TC.FlagMissed(e)
    TC.Print(string.format('Flagged %s\'s message as missed: "%s"', e.sender or "?", Short(TC.EntryText(e), 60)))
end

local function FlagMessage(contextData, key)
    local lineID = LineID(contextData)
    TC.Debug(lineID and ("menu gave lineID " .. lineID) or "menu gave no lineID; using their recent messages")
    local list = TC.FlagCandidates(key, lineID)
    if #list == 0 then
        TC.Print("No recent shown message from them to flag.")
    elseif #list == 1 then
        Flagged(list[1])
    else
        MenuUtil.CreateContextMenu(UIParent, function(_, root)
            root:CreateTitle("Flag which message?")
            for _, e in ipairs(list) do
                root:CreateButton(date("%H:%M  ", e.t) .. Short(TC.EntryText(e), 60), function() Flagged(e) end)
            end
        end)
    end
end

local function Modify(owner, root, contextData)
    if type(contextData) ~= "table" then return end
    local name, realm = MenuName(contextData)
    if not name then return end
    local key, display = TC.NameKey(name, realm)
    if not key or key == TC.PlayerKey() then return end
    root:CreateDivider()
    root:CreateTitle("TolerableChat")
    local muted = TC.MuteEntry and TC.MuteEntry(key)
    if muted then
        local left = TC.MuteMinutesLeft(key)
        root:CreateButton("Unmute" .. (left and string.format(" (%d min left)", left) or ""), function()
            TC.Unmute(key)
            TC.Print(display .. " is unmuted.")
        end)
    elseif TC.MuteByHand then
        root:CreateButton("Mute", function()
            TC.MuteByHand(name, realm)
            local exempt = TC.ExemptReason(key)
            TC.Print(display .. " is muted." .. (exempt and (" They're exempt (" .. exempt .. ") for now.") or ""))
        end)
    end
    root:CreateCheckbox("Never mute",
        function() return TC.rdb.neverMute[key] ~= nil end,
        function()
            local on = TC.ToggleNeverMute(name, realm)
            TC.Print(display .. (on and " is on your never-mute list." or " is off your never-mute list."))
        end)
    -- Their guild, when the game has shown it: mute it, or make it an exception if that's why they're muted.
    local p = TC.rdb and TC.rdb.players[key]
    local guild = p and type(p.guild) == "string" and p.guild or nil
    if guild and TC.AddGuildWordReport then
        if TC.GuildMuted(guild) then
            root:CreateButton("Guild exception: " .. guild, function() TC.Print(TC.ExceptionReport(guild)) end)
        elseif not TC.db.guildExceptions[TC.Lower(guild)] then
            root:CreateButton("Mute guild: " .. guild, function() TC.Print(TC.AddGuildWordReport(guild)) end)
        end
    end
    -- Their guild isn't known yet: look it up with the next /who and mute whatever it is.
    if (not p or p.guild == nil) and TC.QueueGuildMute then
        root:CreateButton("Mute their guild (look it up with /who)", function()
            local who = TC.QueueGuildMute(name, realm)
            if who then
                TC.Print(string.format("%s is first for the next /who; their guild is muted as soon as the game shows "
                    .. "it.", who))
            end
        end)
    end
    -- Muted by a guild (now or one they left): look them up again, by hand.
    local mutedBy = TC.GuildMutedBy and TC.GuildMutedBy(p)
    if mutedBy then
        root:CreateButton("Re-check guild (muted for " .. mutedBy .. ")", function()
            local who, was = TC.RecheckGuild(name, realm)
            if who then
                TC.Print(string.format("%s: the mute for %s is lifted until the game shows their guild again; they're first "
                    .. "for the next /who.", who, was or mutedBy))
            end
        end)
    end
    if TC.QueueCheck and not muted then
        root:CreateButton("Check", function()
            TC.QueueCheck(name, realm)
            TC.Print(display .. " is first for the next /who: any key press runs it when it's due, or Next /who on "
                .. "the Check tab.")
        end)
    end
    if FromChatLine(contextData) then
        root:CreateButton("Flag message", function() FlagMessage(contextData, key) end)
        if not muted and TC.MuteFor then
            root:CreateButton("Mute for 2 hours", function() TC.MuteFor(name, realm) end)
        end
    end
end

if Menu and Menu.ModifyMenu then
    local guarded = TC.Guarded("right-click menu", Modify)
    for _, which in ipairs(MENUS) do Menu.ModifyMenu("MENU_UNIT_" .. which, guarded) end
end
