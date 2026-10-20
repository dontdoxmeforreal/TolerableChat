-- Players and guilds (spec 9, 10): muting by hand, name keywords, muted guild words and exceptions,
-- and the player-to-guild table learned from /who, mouseover, target, focus, the group roster,
-- inspect, guild invites and nameplates. Nameplates are only read (the guild of the player whose
-- nameplate appeared), never changed, so nameplate addons are unaffected.
--
-- A guild mute is worked out from the guild's name each time, so a guild exception or a removed
-- guild word shows every member again at once. It sticks to the player (p.stuck, 1.0.0, the user's
-- call): once the game has shown them in a muted guild they stay muted after leaving it, until you
-- re-check them by hand (TC.RecheckGuild) or that guild stops being muted.
--
-- Only the game itself says which guild a player is in. OlympusNet traffic (Net.lua) is written by
-- other players' addons, so anything it says about a player is a lead for /who, never a mute (1.0.0).

local _, TC = ...
local find, sub, gsub, lower, format = string.find, string.sub, string.gsub, TC.Lower, string.format
local IsSecret = TC.IsSecret

---------------------------------------------------------------------------------------------------
-- Guild names: lowercased, accents, look-alike letters and invisible characters undone
-- (Text.lua TC.UnicodeFold), digits and @ folded as in 6.3, then everything but letters removed, so
-- "O.L.Y.M.P.U.S", "0lympus", "Olymp1a" and "Ólymp" with an accent all contain their word.

local FOLD = { ["1"] = "i", ["3"] = "e", ["4"] = "a", ["0"] = "o", ["5"] = "s", ["7"] = "t", ["8"] = "b", ["9"] = "g",
               ["@"] = "a" }

function TC.GuildKey(name)
    return (gsub(gsub(TC.UnicodeFold(lower(name or "")), "[013457-9@]", FOLD), "[^%a\128-\255]", ""))
end

-- A guild word must have at least this many letters once folded: a shorter one ("ash") would mute
-- half the realm's guilds.
TC.GUILD_WORD_MIN = 4

local guildCache, nameKeys = {}, {}

local function ClearGuildCache()
    for k in pairs(guildCache) do guildCache[k] = nil end
end
TC.Listen("GuildsChanged", ClearGuildCache)

-- The muted guild word in this guild's name, or nil. Exceptions are exact names.
local wordCache = {}
TC.Listen("GuildsChanged", function() for k in pairs(wordCache) do wordCache[k] = nil end end)

function TC.GuildWordOf(guild)
    if type(guild) ~= "string" or guild == "" then return nil end
    local cached = wordCache[guild]
    if cached ~= nil then return cached or nil end
    local word = false
    if not TC.db.guildExceptions[lower(guild)] then
        local key = TC.GuildKey(guild)
        for _, w in ipairs(TC.db.guildWords) do
            local wk = TC.GuildKey(w)
            if wk ~= "" and find(key, wk, 1, true) then
                word = w
                break
            end
        end
    end
    wordCache[guild] = word
    return word or nil
end

-- Why this guild is muted: its guild word, or (setting offensiveGuildNames) a Mute Forever term its
-- name matches after all the folding ('offensive name "tranny"' for "Tr4nny Squad"). nil otherwise.
-- Exceptions win either way.
function TC.GuildMuteWord(guild)
    if type(guild) ~= "string" or guild == "" then return nil end
    local cached = guildCache[guild]
    if cached ~= nil then return cached or nil end
    local word = TC.GuildWordOf(guild) or false
    if not word and TC.db.settings.offensiveGuildNames and TC.MatchGuildName and not TC.db.guildExceptions[lower(guild)] then
        local term = TC.MatchGuildName(guild)
        if term and term.offensive then word = format('offensive name "%s"', term.text) end
    end
    guildCache[guild] = word
    return word or nil
end
-- Terms or their categories changed: which guild names are offensive may have too.
TC.Listen("Terms", function()
    ClearGuildCache()
    if TC.DropMutedList then TC.DropMutedList() end
end)

function TC.GuildMuted(guild)
    return TC.GuildMuteWord(guild) ~= nil
end

-- The muted guild that mutes this player record: their current guild, or the one they were seen in
-- before (p.stuck), while that guild is still muted. nil otherwise.
function TC.GuildMutedBy(p)
    if not p then return nil end
    if p.guild and TC.GuildMuted(p.guild) then return p.guild end
    if p.stuck and TC.GuildMuted(p.stuck) then return p.stuck, true end
end

-- Decision step 5: a muted guild or a name keyword. Returns a reason or nil.
function TC.GuildMuteReason(key)
    local p = TC.rdb.players[key]
    local guild, left = TC.GuildMutedBy(p)
    if guild then
        local why = TC.GuildMuteWord(guild)
        return (left and format('was in guild "%s"', guild) or format('guild "%s"', guild))
            .. ((why and find(why, "^offensive")) and (" (" .. why .. ")") or "")
    end
    local words = TC.db.nameWords
    if words[1] then
        -- Spaces and punctuation don't count: "Dust Monkey" contains "dustmonkey".
        local name = nameKeys[key]
        if not name then
            name = TC.GuildKey(key)
            nameKeys[key] = name
        end
        for _, w in ipairs(words) do
            local wk = TC.GuildKey(w)
            if wk ~= "" and find(name, wk, 1, true) then return format('name contains "%s"', w) end
        end
    end
    return nil
end

---------------------------------------------------------------------------------------------------
-- Learning guilds

-- Clean-up when a learned guild makes a player muted: their earlier lines go.
local function NewlyMuted(key, reason)
    if TC.ExemptReason(key) or not TC.RemoveSenderLines then return end
    TC.RemoveSenderLines(key, TC.Now(), nil, function() return false end,
        function(e) e.step, e.cleanup, e.muteReason = "guild", true, reason end, 0, nil)
    local today = TC.Today()
    today.muted = (today.muted or 0) + 1
    TC.Notify("Muted")
end

-- Sources that are only other players' addons talking (OlympusNet). Everything else (/who,
-- nameplates, mouseover, target, focus, group, inspect, guild invites) is the game showing the guild.
-- ("import" records came from the old Mute / Olympus Mute import, removed in 1.0.0; they were game data.)
local NET_SOURCES = { OlympusNet = true, census = true }
TC.NET_SOURCES = NET_SOURCES
TC.HEARD_MAX = 200   -- Olympus guilds known only from OlympusNet, and OlympusNet guilds not muted: at most this many

local function Find(index, guild)
    local record = index[guild]
    if record then return record, guild end
    local low = lower(guild)
    for name, r in pairs(index) do
        if lower(name) == low then return r, name end
    end
end

local function CountHeard(index)
    local n = 0
    for _, r in pairs(index) do
        if not r.confirmed then n = n + 1 end
    end
    return n
end

-- A census guild's faction field ("H" or "A") or a faction name: "Horde", "Alliance" or nil.
local function Faction(f)
    if f == "H" or f == "Horde" then return "Horde" end
    if f == "A" or f == "Alliance" then return "Alliance" end
end
TC.FactionName = Faction

-- The index of Olympus guilds (rdb.olympusGuilds): every muted guild name seen anywhere, with the size
-- its census gave. A guild the game has shown a member of is confirmed; one only heard on OlympusNet
-- isn't, gets no exact-name searches of its own (a discovery sweep's word searches reach it), and there
-- are at most TC.HEARD_MAX of those, so made-up names can't flood the sweep. Confirmed guilds are kept
-- for good.
function TC.NoteOlympusGuild(guild, source, total, faction)
    -- Only guilds a guild word mutes: an offensively named guild is muted, but it isn't an Olympus guild.
    if not TC.Str(guild) or not TC.GuildWordOf(guild) then return nil end
    local index = TC.rdb.olympusGuilds
    local record = Find(index, guild)
    local heard = NET_SOURCES[source] or false
    local now = time()
    if not record then
        if heard and CountHeard(index) >= TC.HEARD_MAX then
            TC.Count("netGuildsDropped")
            return nil
        end
        record = { first = now }
        index[guild] = record
        TC.Count("guildsIndexed")
        TC.Diag("guilds", 'new muted guild "%s" in the index (from %s%s)', guild, tostring(source), heard and ", not seen in game yet" or "")
    end
    record.first = record.first or now
    record.last, record.source = now, source or record.source
    if heard then
        if not record.net and TC.db.settings.netNotice then TC.Print(format('OlympusNet: "%s", a muted guild.', guild)) end
        record.net = now   -- named on OlympusNet: the Advanced tab lists it
    end
    if not heard and not record.confirmed then
        record.confirmed = now
        if record.first < now then TC.Diag("guilds", 'muted guild "%s" confirmed in game (%s)', guild, tostring(source)) end
    end
    faction = Faction(faction)
    if faction then record.faction = faction end
    if total then
        -- Logged the first time and on a change of 10 or more: reports from different members go 939, 940, 939.
        if not record.logged or math.abs(total - record.logged) >= 10 then
            TC.Diag("net", "census: %s has %d members", guild, total)
            record.logged = total
        end
        record.total, record.reported = total, now
    end
    return record
end

-- OlympusNet guilds that aren't muted (rdb.netGuilds): a guild whose members' Olympus addon sends
-- traffic, or that sends a census of its own, without a muted guild word in its name, like MUDHUTTERS
-- before mudhutter was added. Never muted automatically: the Guilds tab lists them, and Mute guild
-- adds the exact name. seen: the game has shown someone in it (a /who, a nameplate, a mouseover).
function TC.NoteNetGuild(guild, senderKey, total, faction, seen)
    guild = TC.Str(guild)
    if not guild or #guild > 40 or TC.GuildMuted(guild) or TC.db.guildExceptions[lower(guild)] then return nil end
    local index = TC.rdb.netGuilds
    local record = Find(index, guild)
    local now = time()
    if not record then
        local n = 0
        for _ in pairs(index) do n = n + 1 end
        if n >= TC.HEARD_MAX then
            TC.Count("netGuildsDropped")
            return nil
        end
        record = { first = now, senders = 0, census = 0 }
        index[guild] = record
        TC.Diag("guilds", 'OlympusNet guild without a muted word: "%s"', guild)
        if TC.db.settings.netNotice then TC.Print(format('OlympusNet: "%s", a guild without a muted word.', guild)) end
    end
    record.last = now
    record.members = record.members or {}
    if senderKey and not record.members[senderKey] then
        record.members[senderKey] = true
        record.senders = (record.senders or 0) + 1
    end
    if total then record.total, record.census = total, (record.census or 0) + 1 end
    faction = Faction(faction)
    if faction then record.faction = faction end
    if seen then record.seen = now end
    TC.Notify("NetGuilds")
    return record
end

-- The not-muted OlympusNet guilds for the Guilds tab, most evidence first; dismissed ones left out.
function TC.NetGuilds()
    local out = {}
    for guild, r in pairs(TC.rdb.netGuilds) do
        if not r.dismissed and not TC.GuildMuted(guild) and not TC.db.guildExceptions[lower(guild)] then
            out[#out + 1] = { guild = guild, record = r, score = (r.seen and 1000 or 0) + (r.senders or 0) * 10 + (r.census or 0) }
        end
    end
    table.sort(out, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.guild < b.guild
    end)
    return out
end

-- Every guild named on OlympusNet on this realm, for the Advanced tab: the Olympus guilds (in the index)
-- and the ones without a muted word (dismissed ones left out). Olympus guilds first, then newest.
-- known: players the game has shown in the guild (for an Olympus guild, the members muted by it, those
-- who have left since included); total: the guild's own member count from its census.
function TC.NetHeardGuilds()
    local known = {}
    for _, p in pairs(TC.rdb.players) do
        local low = type(p.stuck) == "string" and lower(p.stuck) or (type(p.guild) == "string" and lower(p.guild))
        if low then known[low] = (known[low] or 0) + 1 end
    end
    local out = {}
    for guild, r in pairs(TC.rdb.olympusGuilds) do
        if r.net or r.reported or NET_SOURCES[r.source] then
            out[#out + 1] = { guild = guild, olympus = true, seen = r.confirmed, total = r.total, faction = r.faction,
                              known = known[lower(guild)] or 0, last = r.net or r.reported or r.last or 0 }
        end
    end
    for _, g in ipairs(TC.NetGuilds()) do
        local r = g.record
        out[#out + 1] = { guild = g.guild, olympus = false, seen = r.seen, total = r.total, faction = r.faction,
                          known = known[lower(g.guild)] or 0, senders = r.senders, last = r.last or 0 }
    end
    table.sort(out, function(a, b)
        if a.olympus ~= b.olympus then return a.olympus end
        if a.last ~= b.last then return a.last > b.last end
        return a.guild < b.guild
    end)
    return out
end

function TC.DismissNetGuild(guild)
    local r = Find(TC.rdb.netGuilds, guild)
    if r then
        r.dismissed = true
        TC.Notify("NetGuilds")
        TC.Notify("Changed")
    end
end

-- Seeding and the one-time changes to a realm's data, whenever a realm's table is bound (Core.lua).
TC.Listen("RealmBound", function(r)
    -- Olympus guilds in the saved players or the lead list that the index doesn't have yet.
    local have = {}
    for guild in pairs(r.olympusGuilds) do have[lower(guild)] = true end
    local function Seed(guild, source)
        if type(guild) == "string" and guild ~= "" and not have[lower(guild)] and TC.GuildMuted(guild) then
            have[lower(guild)] = true
            TC.NoteOlympusGuild(guild, source)
        end
    end
    for _, p in pairs(r.players) do Seed(p.guild, NET_SOURCES[p.source] and "census" or "saved players") end
    if (r.rev or 0) < 2 then
        -- 1.0.0: guild mutes stick. Everyone in a muted guild now stays muted if they leave it, and the
        -- sweep's re-checks of muted players it missed are gone (nothing to find out any more).
        for _, p in pairs(r.players) do
            if p.guild and TC.GuildMuted(p.guild) then p.stuck = p.guild end
        end
        r.check.recheck = {}
    end
    if (r.rev or 0) < 1 then
        -- 1.0.0: census names were muted as members of the guild that sent the census (0.8.1). Census
        -- text is written by the sender's addon, so it can name anyone: those players aren't muted any
        -- more (the sweep mutes them if they really are in a muted guild).
        local n = 0
        for key, p in pairs(r.players) do
            if NET_SOURCES[p.source] then r.players[key], n = nil, n + 1 end
        end
        -- Olympus guilds known only from OlympusNet aren't confirmed; everything else in the index was seen.
        for _, record in pairs(r.olympusGuilds) do
            if not record.confirmed and not NET_SOURCES[record.source] then record.confirmed = record.first or time() end
        end
        if n > 0 then TC.Diag("guilds", "%d players muted from census reports alone aren't muted now", n) end
    end
    if (r.rev or 0) < 3 then
        -- 1.0.0: OlympusNet is read for guild names only, so the leads named in census reports go.
        local n = 0
        for key, w in pairs(r.watch or {}) do
            if w.evidence == "census" then r.watch[key], n = nil, n + 1 end
        end
        if n > 0 then TC.Diag("guilds", "dropped %d leads named only in census reports", n) end
    end
    if (r.rev or 0) < 4 then
        -- 1.0.1: OlympusNet is read for guild names only; the player leads go.
        local n = 0
        for _ in pairs(r.watch or {}) do n = n + 1 end
        r.watch = nil
        if n > 0 then TC.Diag("guilds", "dropped %d OlympusNet leads (only guild names are used now)", n) end
    end
    r.rev = 4
    TC.DropMutedList()
end)

-- The player's faction, when the game shows it (nameplates, mouseover, target, group, /who). Both
-- factions are recorded and muted: the other faction's Olympus members still talk in shared chat.
function TC.NoteFaction(key, faction)
    local p = key and TC.rdb.players[key]
    -- Secret first: comparing a secret value is itself an error.
    if p and not IsSecret(faction) and (faction == "Horde" or faction == "Alliance") then p.faction = faction end
end

-- Records a player's guild as the game shows it (false: no guild). source: "who", "mouseover",
-- "target", "group", ... An OlympusNet lead for this player is settled by it: a lead in a guild that
-- isn't muted puts that guild on the OlympusNet guild list (their addon talks on OlympusNet).
function TC.LearnGuild(name, realm, guild, source, guid)
    if IsSecret(guild) or IsSecret(name) or NET_SOURCES[source] then return end
    local key, display = TC.NameKey(name, realm)
    if not key or key == TC.PlayerKey() then return end
    guild = (type(guild) == "string" and guild ~= "") and guild or false
    local r, now = TC.rdb, time()
    local p = r.players[key]
    local wasMuted = TC.GuildMutedBy(p) ~= nil
    if not p then
        p = { name = display, first = now }
        r.players[key] = p
    end
    p.last, p.source = now, source
    if TC.IsPlayerGUID(guid) then p.guid = guid end
    if p.guild ~= guild then
        -- Joining, leaving or moving between muted guilds changes the muted list.
        if wasMuted or (guild and TC.GuildMuted(guild)) then TC.DropMutedList() end
        p.guild, p.since = guild, now
    end
    -- You asked to mute this player's guild before it was known (right-click Mute their guild).
    local want = r.check.muteGuildOf[key]
    if want then
        r.check.muteGuildOf[key] = nil
        if now - want > 3 * 86400 then
            -- asked too long ago: forgotten
        elseif guild and TC.GuildMuted(guild) then
            TC.Print(format("%s is in %s, which is muted already.", p.name or display, guild))
        elseif guild then
            TC.Print(format("%s is in %s. ", p.name or display, guild) .. TC.AddGuildWordReport(guild))
        elseif source == "who" then
            TC.Print(format("%s isn't in a guild, so there's no guild to mute.", p.name or display))
        else
            r.check.muteGuildOf[key] = want
        end
    end
    local muted = guild and TC.GuildMuted(guild)
    if muted then
        p.stuck = guild   -- muted for good, even after leaving it (TC.RecheckGuild undoes it)
        TC.NoteOlympusGuild(guild, source)
        if not wasMuted then NewlyMuted(key, format('guild "%s"', guild)) end
    end
    -- A guild on the OlympusNet guild list that the game shows someone in is real: "seen in game".
    local net = guild and not muted and Find(r.netGuilds, guild)
    if net and not net.seen then
        net.seen = now
        TC.Notify("NetGuilds")
    end
    return key
end

local function LearnUnit(unit, source)
    if not UnitExists(unit) or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return end
    local name, realm = UnitName(unit)
    local guild = GetGuildInfo(unit)
    if IsSecret(name) or IsSecret(guild) then return end
    -- Seen online, with class and race from the GUID: the guild sweep can clear them (Check.lua).
    if TC.SeenOnline then
        local guid = UnitGUID(unit)
        TC.SeenOnline((TC.NameKey(name, realm)), (not IsSecret(guid)) and guid or nil)
    end
    -- GetGuildInfo is nil both for "no guild" and "not loaded yet", so only a guild name is learned
    -- from a unit; "no guild" comes from /who alone. Otherwise a slow load could unmute someone.
    if type(guild) ~= "string" or guild == "" then return end
    local key = TC.LearnGuild(name, realm, guild, source, UnitGUID(unit))
    TC.NoteFaction(key, UnitFactionGroup(unit))
end
TC.LearnUnit = LearnUnit

TC.On("UPDATE_MOUSEOVER_UNIT", function() LearnUnit("mouseover", "mouseover") end)
-- In a city, dozens of players a minute; each is a cheap lookup. Only players whose nameplates the
-- game shows (Interface > Names: friendly and enemy player nameplates).
TC.On("NAME_PLATE_UNIT_ADDED", function(unit)
    if TC.db.settings.learnNameplates and type(unit) == "string" then
        TC.Count("nameplatesRead")
        LearnUnit(unit, "nameplate")
    end
end)
TC.On("PLAYER_TARGET_CHANGED", function() LearnUnit("target", "target") end)
TC.On("PLAYER_FOCUS_CHANGED", function() LearnUnit("focus", "focus") end)
TC.On("INSPECT_READY", function() LearnUnit("target", "inspect") end)
TC.On("GROUP_ROSTER_UPDATE", function()
    local prefix, count = "party", GetNumSubgroupMembers and GetNumSubgroupMembers() or 0
    if IsInRaid and IsInRaid() then prefix, count = "raid", GetNumGroupMembers() or 0 end
    for i = 1, count do LearnUnit(prefix .. i, "group") end
end)
TC.On("GUILD_INVITE_REQUEST", function(inviter, guild)
    TC.LearnGuild(inviter, nil, guild, "guild invite")
end)

---------------------------------------------------------------------------------------------------
-- Muting by hand (9)

function TC.MuteByHand(name, realm, reason)
    local key, display = TC.NameKey(name, realm)
    if not key or key == TC.PlayerKey() then return nil end
    TC.SetMute(key, display, "hand", reason or "muted by you")
    TC.CleanUpMute(key, reason or "muted by you")
    return key, display
end

-- Name keywords and guild words: lowercased, trimmed, no duplicates.
local function Clean(word)
    return lower((gsub(gsub(tostring(word or ""), "^[ \t\n\r\f\v]+", ""), "[ \t\n\r\f\v]+$", "")))
end

local function AddWord(list, word)
    word = Clean(word)
    if word == "" then return nil end
    for _, w in ipairs(list) do
        if w == word then return nil end
    end
    list[#list + 1] = word
    return word
end

local function RemoveWord(list, word)
    word = Clean(word)
    for i, w in ipairs(list) do
        if w == word then
            table.remove(list, i)
            return word
        end
    end
end

-- Why this can't be a guild word, or nil. /who searches put the word in quotes.
function TC.GuildWordProblem(word)
    word = Clean(word)
    if word == "" then return "type a word or a guild's name" end
    if find(word, '"', 1, true) then return "no quote marks" end
    if #TC.GuildKey(word) < TC.GUILD_WORD_MIN then
        return format("at least %d letters (a short word mutes every guild that happens to contain it)", TC.GUILD_WORD_MIN)
    end
end

-- Every guild TolerableChat knows of on this realm (seen in game, in the Olympus index or on the
-- OlympusNet guild list) whose name contains this word as a guild word would match it.
function TC.GuildWordMatches(word)
    local wk = TC.GuildKey(Clean(word))
    local out, seen = {}, {}
    if wk == "" then return out end
    local function Try(guild)
        if type(guild) == "string" and not seen[lower(guild)] then
            seen[lower(guild)] = true
            if find(TC.GuildKey(guild), wk, 1, true) and not TC.db.guildExceptions[lower(guild)] then out[#out + 1] = guild end
        end
    end
    for _, p in pairs(TC.rdb.players) do Try(p.guild) end
    for guild in pairs(TC.rdb.olympusGuilds) do Try(guild) end
    for guild in pairs(TC.rdb.netGuilds) do Try(guild) end
    table.sort(out)
    return out
end

-- Adds a guild word. Returns the word, or nil and why not.
function TC.AddGuildWord(word)
    local problem = TC.GuildWordProblem(word)
    if problem then return nil, problem end
    local w = AddWord(TC.db.guildWords, word)
    if not w then return nil, "already on the list" end
    TC.Notify("GuildsChanged")
    TC.Notify("Changed")
    return w
end

function TC.RemoveGuildWord(word)
    local w = RemoveWord(TC.db.guildWords, word)
    if w then TC.Notify("GuildsChanged") TC.Notify("Changed") end
    return w
end

-- Puts back any default guild words that were removed; your own words stay. Returns how many.
function TC.RestoreGuildWords()
    local n = 0
    for _, w in ipairs(TC.DEFAULT_GUILD_WORDS) do
        if AddWord(TC.db.guildWords, w) then n = n + 1 end
    end
    if n > 0 then TC.Notify("GuildsChanged") TC.Notify("Changed") end
    return n
end

local function Some(list, n)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return table.concat(out, ", ") .. (#list > n and ", ..." or "")
end

-- Adds a guild word (or a guild's exact name) and says in a chat line what that does.
function TC.AddGuildWordReport(text)
    local w, why = TC.AddGuildWord(text)
    if not w then return format("Not added: %s.", why) end
    local matches = TC.GuildWordMatches(w)
    return format('Guilds containing "%s" are muted%s. The guild sweep searches for it from the next /who.', w,
        #matches > 0 and format(": %d known on this realm (%s)", #matches, Some(matches, 5)) or " (none known yet)")
end

-- Toggles a guild exception and says in a chat line what that does.
function TC.ExceptionReport(text)
    local on, guild, n = TC.ToggleGuildException(text)
    if not guild then return "Type the guild's exact name." end
    if on then
        return format("%s is a guild exception now: never muted by a guild word. %d known member%s shown again; "
            .. "lines already hidden stay hidden.", guild, n, n == 1 and " is" or "s are")
    end
    return format("%s is no longer a guild exception%s.", guild,
        TC.GuildMuted(guild) and format(": its %d known member%s muted again", n, n == 1 and " is" or "s are") or "")
end

-- Mute their guild for a player whose guild TolerableChat doesn't know yet: they go first for the next
-- /who, and whichever guild the game shows for them (that /who, a nameplate, a mouseover) is muted.
-- Waits up to 3 days. Returns the display name.
function TC.QueueGuildMute(name, realm)
    local key, display = TC.NameKey(name, realm)
    if not key then return nil end
    TC.rdb.check.muteGuildOf[key] = time()
    TC.QueueCheck(name, realm)
    return display
end

-- Re-check by hand: the player's guild mute is let go, so whether they are muted follows the guild the
-- game shows now, and they are put first for the next /who to look again. Returns their name and the
-- guild that had muted them, or nil.
function TC.RecheckGuild(name, realm)
    local key, display = TC.NameKey(name, realm)
    local p = key and TC.rdb.players[key]
    if not p then return nil end
    local was = p.stuck
    p.stuck = nil
    TC.DropMutedList()
    if TC.QueueCheck then TC.QueueCheck(p.name or display) end
    TC.Notify("Changed")
    TC.Notify("Muted")
    return p.name or display, was
end

-- Lets go of every guild mute whose player the game has since shown in an unmuted guild (or no guild).
-- Returns how many.
function TC.ReleaseLeftGuild()
    local n = 0
    for _, p in pairs(TC.rdb.players) do
        if p.stuck and p.guild ~= p.stuck and not (p.guild and TC.GuildMuted(p.guild)) then
            p.stuck = nil
            n = n + 1
        end
    end
    if n > 0 then
        TC.DropMutedList()
        TC.Notify("Changed")
        TC.Notify("Muted")
    end
    return n
end

-- How many players have left the muted guild they were muted for (TC.ReleaseLeftGuild would let go).
function TC.CountLeftGuild()
    local n = 0
    for _, p in pairs(TC.rdb.players) do
        if p.stuck and p.guild ~= p.stuck and not (p.guild and TC.GuildMuted(p.guild)) and TC.GuildMuted(p.stuck) then
            n = n + 1
        end
    end
    return n
end

-- How many players this realm's saved list has in exactly this guild (any letter case).
function TC.GuildMemberCount(guild)
    local low, n = lower(guild or ""), 0
    for _, p in pairs(TC.rdb.players) do
        if (p.guild and lower(p.guild) == low) or (p.stuck and p.stuck ~= p.guild and lower(p.stuck) == low) then
            n = n + 1
        end
    end
    return n
end

-- Toggles an exact guild name on the exception list. Returns true if it is now an exception, the
-- name, and how many known members that shows again (or mutes again).
function TC.ToggleGuildException(guild)
    guild = (gsub(gsub(tostring(guild or ""), "^[ \t\n\r\f\v]+", ""), "[ \t\n\r\f\v]+$", ""))
    if guild == "" then return nil end
    local list = TC.db.guildExceptions
    local key = lower(guild)
    if list[key] then list[key] = nil else list[key] = guild end
    TC.Notify("GuildsChanged")
    TC.Notify("Changed")
    return list[key] ~= nil, guild, TC.GuildMemberCount(guild)
end

function TC.AddNameWord(word)
    local w = AddWord(TC.db.nameWords, word)
    if w then TC.DropMutedList() TC.Notify("Changed") end
    return w
end

function TC.RemoveNameWord(word)
    local w = RemoveWord(TC.db.nameWords, word)
    if w then TC.DropMutedList() TC.Notify("Changed") end
    return w
end

---------------------------------------------------------------------------------------------------
-- Look-alike guilds: names one letter away from a muted word ("Olynpus", "Olympvss" is caught anyway,
-- "Olymups"), which neither folding nor a /who for the word finds. Listed for you to decide, never
-- muted automatically. Reference words: the muted guild words of 6 letters or more, plus the full
-- forms of the default stems ("olymp" is too short to compare), each only while its stem is muted.

local FULL_FORMS = { "olympus", "mudhutter", "dustmonkey" }

-- Whether a and b are at most one edit apart: one letter changed, added, dropped, or two neighbours swapped.
local function Within1(a, b)
    if a == b then return true end
    local la, lb = #a, #b
    if la > lb then a, b, la, lb = b, a, lb, la end
    if lb - la > 1 then return false end
    local i = 1
    while i <= la and sub(a, i, i) == sub(b, i, i) do i = i + 1 end
    if la == lb then
        if sub(a, i + 1) == sub(b, i + 1) then return true end   -- one letter changed
        return sub(a, i, i) == sub(b, i + 1, i + 1) and sub(a, i + 1, i + 1) == sub(b, i, i) and sub(a, i + 2) == sub(b, i + 2)
    end
    return sub(a, i) == sub(b, i + 1)   -- one letter added
end

local function References()
    local out, seen = {}, {}
    local function Add(w)
        local k = TC.GuildKey(w)
        if #k >= 6 and not seen[k] then
            seen[k] = true
            local grams = {}
            for i = 1, #k - 2 do grams[#grams + 1] = sub(k, i, i + 2) end
            out[#out + 1] = { word = w, key = k, grams = grams }
        end
    end
    for _, w in ipairs(FULL_FORMS) do
        local k = TC.GuildKey(w)
        for _, g in ipairs(TC.db.guildWords) do
            local gk = TC.GuildKey(g)
            if gk ~= "" and find(k, gk, 1, true) then Add(w) break end
        end
    end
    for _, w in ipairs(TC.db.guildWords) do Add(w) end
    return out
end

-- The reference word this guild name nearly contains, or nil.
local function LookAlike(guild, refs)
    local key = TC.GuildKey(guild)
    for _, ref in ipairs(refs) do
        -- One edit changes at most three letter triples; a word of 6+ letters keeps at least one.
        local any = false
        for _, g in ipairs(ref.grams) do
            if find(key, g, 1, true) then any = true break end
        end
        if any then
            local L = #ref.key
            for start = 1, #key do
                for len = L - 1, L + 1 do
                    if start + len - 1 <= #key and Within1(sub(key, start, start + len - 1), ref.key) then return ref.word end
                end
            end
        end
    end
end

local lookCache = {}
TC.Listen("GuildsChanged", function() lookCache = {} end)
TC.Listen("RealmBound", function() lookCache = {} end)

-- Known guilds on this realm (seen in game, or on the OlympusNet guild list) that look like a muted
-- word but aren't muted: { guild, word, count }.
function TC.LookAlikeGuilds()
    local refs, counts = References(), {}
    for _, p in pairs(TC.rdb.players) do
        if p.guild then counts[p.guild] = (counts[p.guild] or 0) + 1 end
    end
    for guild in pairs(TC.rdb.netGuilds) do counts[guild] = counts[guild] or 0 end
    local out = {}
    for guild, n in pairs(counts) do
        if not TC.GuildMuted(guild) and not TC.db.guildExceptions[lower(guild)] then
            local word = lookCache[guild]
            if word == nil then
                word = LookAlike(guild, refs) or false
                lookCache[guild] = word
            end
            if word then out[#out + 1] = { guild = guild, word = word, count = n } end
        end
    end
    table.sort(out, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.guild < b.guild
    end)
    return out
end

---------------------------------------------------------------------------------------------------
-- Guilds named with a filtered word: known guilds whose names match a term of a Timeout or Hide Only
-- category ("MAGA Raiders", "Thunderfury"), listed for you to decide. Never muted automatically: a
-- guild mute is for good and covers game talk, so a topic word in a guild's name is no reason to mute
-- every member (only Mute Forever words are, GuildMuteWord). Place names don't count at all
-- (TC.GUILD_NAME_SKIP).

local filteredCache = {}
local function ClearFiltered() filteredCache = {} end
TC.Listen("GuildsChanged", ClearFiltered)
TC.Listen("Terms", ClearFiltered)
TC.Listen("RealmBound", ClearFiltered)

-- { guild, word, cat, count }, most members seen first; muted guilds and exceptions left out.
function TC.FilteredNameGuilds()
    local counts = {}
    for _, p in pairs(TC.rdb.players) do
        if type(p.guild) == "string" then counts[p.guild] = (counts[p.guild] or 0) + 1 end
    end
    local out = {}
    for guild, n in pairs(counts) do
        if not TC.GuildMuted(guild) and not TC.db.guildExceptions[lower(guild)] then
            local hit = filteredCache[guild]
            if hit == nil then
                local term = TC.MatchGuildName and TC.MatchGuildName(guild)
                hit = (term and not term.offensive) and { word = term.form or term.text, term = term.text, cat = term.cat } or false
                filteredCache[guild] = hit
            end
            if hit then out[#out + 1] = { guild = guild, word = hit.term, cat = hit.cat, count = n } end
        end
    end
    table.sort(out, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.guild < b.guild
    end)
    return out
end

---------------------------------------------------------------------------------------------------
-- Lists for the People and Guilds tabs

-- Why a player is muted ("muted by you", 'guild "Olympus Templars"'), or nil.
function TC.WhyMuted(key)
    local m = TC.MuteEntry(key)
    if m then return m.reason or "muted", m end
    return TC.GuildMuteReason(key)
end

-- Every muted player: explicit mutes, players in muted guilds, name keywords. The People and
-- Auto-mutes tabs ask on every refresh and it walks every known player, so it is built once and kept
-- until who is muted changes (TC.DropMutedList) or a 2-hour mute ends. Rows don't carry exemptions,
-- which follow your friends, guild and group: TC.MutedExempt(row) looks them up for the rows on screen.
-- Callers must not change the list.
local mutedList, mutedUntil = nil, 0

function TC.DropMutedList()
    mutedList = nil
end
TC.Listen("Muted", TC.DropMutedList)
TC.Listen("GuildsChanged", TC.DropMutedList)
TC.Listen("RealmBound", TC.DropMutedList)

function TC.MutedPlayers()
    if mutedList and time() < mutedUntil then return mutedList end
    local out, seen, soonest = {}, {}, math.huge
    local r = TC.rdb
    local function Push(key, name)
        if seen[key] then return end
        local reason, m = TC.WhyMuted(key)
        if not reason then return end
        seen[key] = true
        local p = r.players[key]
        name = name or (p and p.name) or key
        out[#out + 1] = { key = key, name = name, sortName = lower(name), guild = p and p.guild or nil,
                          reason = reason, kind = m and m.kind or "guild", first = (m and m.added) or (p and p.first),
                          last = p and p.last, guid = p and p.guid }
        if m and m.expires and m.expires < soonest then soonest = m.expires end
    end
    for key, m in pairs(r.mutes) do Push(key, m.name) end
    for key, p in pairs(r.players) do
        if TC.GuildMutedBy(p) then Push(key, p.name) end
    end
    mutedList, mutedUntil = out, soonest
    return out
end

-- Why a row of TC.MutedPlayers is shown anyway ("friend"), or nil.
function TC.MutedExempt(row)
    return TC.ExemptReason(row.key, row.guid)
end

-- Known guilds with how many players were seen in each, and whether they are muted.
function TC.KnownGuilds()
    local counts = {}
    for _, p in pairs(TC.rdb.players) do
        if p.guild then counts[p.guild] = (counts[p.guild] or 0) + 1 end
    end
    local out = {}
    for guild, n in pairs(counts) do
        out[#out + 1] = { guild = guild, count = n, word = TC.GuildMuteWord(guild),
                          exception = TC.db.guildExceptions[lower(guild)] ~= nil }
    end
    table.sort(out, function(a, b)
        if (a.word ~= nil) ~= (b.word ~= nil) then return a.word ~= nil end
        if a.count ~= b.count then return a.count > b.count end
        return a.guild < b.guild
    end)
    return out
end

---------------------------------------------------------------------------------------------------
-- The game's ignore list carries over (setting mirrorIgnore, the user's call): anyone on it who isn't
-- muted here is muted, quietly, on every character of this realm. That is all: TolerableChat never adds
-- to or removes from the game's list, and unignoring someone changes nothing here. Read whenever the
-- list changes (IGNORELIST_UPDATE) and at login; nothing of the game's is hooked. Someone you unmute here
-- while they're still on the game's list stays unmuted (rdb.ignoreReleased).

local IGNORE_REASON = "on your game ignore list"

function TC.SyncIgnoreList()
    if not TC.db.settings.mirrorIgnore then return 0 end
    if not (C_FriendList and C_FriendList.GetNumIgnores and C_FriendList.GetIgnoreName) then return 0 end
    local r, added = TC.rdb, 0
    for i = 1, C_FriendList.GetNumIgnores() or 0 do
        local name = TC.Str(C_FriendList.GetIgnoreName(i))
        local key = name and TC.NameKey(name)
        if key and key ~= TC.PlayerKey() and not r.ignoreReleased[key] then
            local m = TC.MuteEntry(key)
            if not m or m.kind == "timed" then
                TC.MuteByHand(name, nil, IGNORE_REASON)
                if r.mutes[key] then
                    r.mutes[key].fromIgnore = true
                    added = added + 1
                end
            end
        end
    end
    if added > 0 then TC.Diag("ignore", "%d players from the game's ignore list muted here", added) end
    return added
end

TC.On("IGNORELIST_UPDATE", function() TC.SyncIgnoreList() end)
TC.On("PLAYER_LOGIN", function() C_Timer.After(5, TC.SyncIgnoreList) end)

-- Players last seen more than 90 days ago, in no muted guild, are forgotten at login.
TC.On("PLAYER_LOGIN", function()
    local limit = time() - 90 * 86400
    for key, p in pairs(TC.rdb.players) do
        if (p.last or 0) < limit and not TC.GuildMutedBy(p) then TC.rdb.players[key] = nil end
    end
end)
