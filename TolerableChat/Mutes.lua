-- The mute list (spec 9): mutes by hand, auto-mutes from offensive terms, "Mute for 2 hours" and
-- Unmute. A muted player's chat is hidden in every filtered chat type, game talk included;
-- exemptions still win. Guild mutes and name keywords are in Players.lua.
--
-- Auto-mutes are silent in chat and logged in the auto-mute report (14.4) for review.

local _, TC = ...
local format = string.format

-- The explicit mute for this player while it lasts, or nil. 2-hour mutes end by themselves.
function TC.MuteEntry(key)
    local m = key and TC.rdb.mutes[key]
    if m and m.expires and time() >= m.expires then
        TC.rdb.mutes[key] = nil
        if TC.DropMutedList then TC.DropMutedList() end
        TC.Notify("Changed")
        return nil
    end
    return m
end

-- Decision steps 4 and 5 (Filter.lua): "muted" (explicit) or "guild" (guild word, name keyword) and
-- the reason, or nil.
function TC.MuteReason(key)
    local m = TC.MuteEntry(key)
    if m then return "muted", m.reason or "muted" end
    local reason = TC.GuildMuteReason and TC.GuildMuteReason(key)
    if reason then return "guild", reason end
    return nil
end

-- True while this player's interactions (invites, duels, trades, bubbles) are blocked.
function TC.IsMuted(key)
    return key ~= nil and TC.MuteReason(key) ~= nil and not TC.ExemptReason(key)
end

-- Clean-up on mute: removes the player's earlier lines from every chat window (your whispers to
-- them stay). Returns how many lines from the recent-message buffer it removed.
local function CleanUp(key, reason, except)
    return TC.RemoveSenderLines(key, TC.Now(), nil,
        function(e) return e == except end,
        function(e) e.step, e.cleanup, e.muteReason = "muted", true, reason end,
        0, nil)
end
TC.CleanUpMute = CleanUp

-- kind: "hand", "auto" or "timed". Mute and never-mute are exclusive.
function TC.SetMute(key, name, kind, reason, expires)
    local had = TC.rdb.mutes[key] ~= nil
    TC.rdb.mutes[key] = { name = name, kind = kind, reason = reason, added = time(), expires = expires }
    TC.rdb.neverMute[key] = nil
    if not had then
        local today = TC.Today()
        today.muted = (today.muted or 0) + 1
    end
    TC.Notify("Changed")
    TC.Notify("Muted")
end

-- An offensive term (rule 6). e is the message that set it off; it is already hidden.
function TC.AutoMute(e, term)
    local reason = format('auto-muted: %s "%s"', TC.Lower(term.cat), term.text)
    if not (TC.rdb.mutes[e.key] and TC.rdb.mutes[e.key].kind == "hand") then
        TC.SetMute(e.key, e.sender, "auto", reason, nil)
    end
    local report = TC.rdb.muteReport
    report[#report + 1] = { t = e.t, key = e.key, name = e.sender, channel = e.channel, text = TC.EntryText(e),
                            term = term.text, cat = term.cat }
    while #report > TC.REPORT_MAX do table.remove(report, 1) end
    return CleanUp(e.key, reason, e)
end

-- "Mute for 2 hours" from the right-click menu.
function TC.MuteFor(name, realm, seconds)
    local key, display = TC.NameKey(name, realm)
    if not key then return end
    seconds = seconds or TC.TIMED_MUTE
    TC.SetMute(key, display, "timed", format("muted for %d hours", math.floor(seconds / 3600 + 0.5)), time() + seconds)
    CleanUp(key, "muted for 2 hours")
    local exempt = TC.ExemptReason(key)
    TC.Print(format("Muted %s for 2 hours.", display)
        .. (exempt and format(" They're exempt (%s), so this only applies once that ends.", exempt) or ""))
end

-- Ends an explicit mute. A guild mute can't be ended here: use Never mute or a guild exception.
function TC.Unmute(key)
    local m = TC.rdb.mutes[key]
    if m then
        -- Carried over from the game's ignore list and unmuted by you: not carried over again (Players.lua).
        if m.fromIgnore then TC.rdb.ignoreReleased[key] = true end
        TC.rdb.mutes[key] = nil
        TC.Notify("Changed")
        TC.Notify("Muted")
        return true
    end
end

-- Adding someone to the never-mute list removes their mute (Core.lua ToggleNeverMute).
TC.OnNeverMute = TC.Unmute

-- Minutes left on a 2-hour mute, or nil.
function TC.MuteMinutesLeft(key)
    local m = TC.MuteEntry(key)
    if m and m.expires then return math.max(1, math.ceil((m.expires - time()) / 60)) end
end

-- All muted players, then how many are auto-muted and how many for 2 hours.
function TC.CountMuted()
    local auto, timed = 0, 0
    for key in pairs(TC.rdb.mutes) do
        local m = TC.MuteEntry(key)
        if m and m.kind == "timed" then timed = timed + 1 elseif m and m.kind == "auto" then auto = auto + 1 end
    end
    return #TC.MutedPlayers(), auto, timed
end

-- Auto-mutes judged again with the current lists and category choices: a mute stays when one of the
-- player's logged messages still hits a Mute Forever term (its reason then names that term), and is
-- lifted when none does, as for "gay" and "nazi" after they became Timeout words. Without a
-- logged message the term in the reason is judged. Hand mutes are never touched. Runs by itself
-- once per realm for each new built-in term list, and from the Auto-mutes tab. Returns lifted, kept.
function TC.RecheckAutoMutes()
    local r, lifted, kept = TC.rdb, 0, 0
    local texts = {}
    for _, e in ipairs(r.muteReport) do
        if e.key and e.text then
            texts[e.key] = texts[e.key] or {}
            table.insert(texts[e.key], e)
        end
    end
    for key, m in pairs(r.mutes) do
        if m.kind == "auto" then
            local still
            for _, e in ipairs(texts[key] or {}) do
                local term = TC.MatchRaw(e.text)
                if term and term.offensive then still = term break end
            end
            if not still and not texts[key] then
                local text = m.reason and string.match(m.reason, '"(.+)"$')
                local term = text and TC.MatchRaw(text)
                still = (term and term.offensive) and term or nil
                if not text then still = true end   -- nothing to judge by: left alone
            end
            if still then
                kept = kept + 1
                if type(still) == "table" then m.reason = format('auto-muted: %s "%s"', TC.Lower(still.cat), still.text) end
            else
                lifted = lifted + 1
                TC.rdb.mutes[key] = nil
                for _, e in ipairs(texts[key] or {}) do e.lifted = time() end
            end
        end
    end
    r.autoChecked = TC.AutoCheckKey()
    if lifted > 0 then
        TC.Diag("mutes", "re-checked auto-mutes: %d lifted (no Mute Forever word now), %d kept", lifted, kept)
        TC.Notify("Muted")
        TC.Notify("Changed")
    end
    return lifted, kept
end

-- What the auto-mutes were last judged against: the built-in term list and the settings migrations
-- (a migration can change a category's default action, as 1.0.1 did for Harassment).
function TC.AutoCheckKey()
    return format("%s/%s", TC.DefaultTerms and TC.DefaultTerms.version or "?", tostring(TC.db.settingsRev))
end

-- New built-in lists or defaults: auto-mutes made under the old ones are judged again (once per realm).
TC.On("PLAYER_LOGIN", function()
    C_Timer.After(3, function()
        local r = TC.rdb
        if not r or not TC.DefaultTerms or r.autoChecked == TC.AutoCheckKey() then return end
        local lifted, kept = TC.RecheckAutoMutes()
        if lifted > 0 then
            TC.Print(format("The lists changed: %d auto-mute%s lifted, because the current lists wouldn't make "
                .. "them (some words are Timeout words now); %d stay%s. The Auto-mutes tab shows which.",
                lifted, lifted == 1 and " was" or "s were", kept, kept == 1 and "s" or ""))
        end
    end)
end)

function TC.ClearMuteReport()
    TC.rdb.muteReport = {}
    TC.Notify("Muted")
end

-- For /tc status.
function TC.MuteStatus(key)
    local lines = {}
    local m = TC.MuteEntry(key)
    if m and m.expires then
        lines[#lines + 1] = format("Muted for 2 hours: %d min left.", TC.MuteMinutesLeft(key))
    elseif m then
        lines[#lines + 1] = format("Muted since %s (%s).", date("%Y-%m-%d %H:%M", m.added or 0), m.reason or "muted")
    end
    local guild = TC.GuildMuteReason and TC.GuildMuteReason(key)
    if guild then lines[#lines + 1] = "Muted: " .. guild .. "." end
    local p = TC.rdb.players[key]
    if p then
        lines[#lines + 1] = format("Guild: %s (seen %s, from %s).", p.guild or "none",
            date("%Y-%m-%d %H:%M", p.last or 0), p.source or "?")
    else
        lines[#lines + 1] = "Guild: not known yet."
    end
    return lines
end

-- For /tc tally.
function TC.ExtraTally()
    local total, auto, timed = TC.CountMuted()
    local players, guilds = 0, 0
    for _ in pairs(TC.rdb.players) do players = players + 1 end
    guilds = #TC.KnownGuilds()
    return { format("Muted players: %d (%d auto-muted, %d for 2 hours). Auto-mute report: %d entries.",
        total, auto, timed, #TC.rdb.muteReport),
        format("Known players: %d in %d guilds. Muted guild words: %d. Name keywords: %d.",
            players, guilds, #TC.db.guildWords, #TC.db.nameWords) }
end

TC.On("PLAYER_LOGIN", function()
    for key in pairs(TC.rdb.mutes) do TC.MuteEntry(key) end   -- drop 2-hour mutes that ended
end)
