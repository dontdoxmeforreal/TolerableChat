-- TolerableChat: keeps chat quiet and game-focused.
--
-- Core: saved data and defaults, events, the name normaliser and exemptions (friends, guild,
-- group, never-mute list). The filter itself is in Text.lua, Matcher.lua and Filter.lua.

local ADDON, TC = ...
_G.TolerableChat = TC

-- Lowercase A-Z only. string.lower follows the system locale, and on a Western Windows locale it
-- also changes bytes C0-DE: the first byte of every accented, Cyrillic or Greek character in UTF-8
-- ("à" is C3 A0 and became E3 A0, which is no character at all). Names and chat are UTF-8, so every
-- file uses this instead.
local ASCII_LOWER = {}
for c = 65, 90 do ASCII_LOWER[string.char(c)] = string.char(c + 32) end
function TC.Lower(s)
    return (string.gsub(s, "[A-Z]", ASCII_LOWER))
end

local find, gsub, lower, match, format = string.find, string.gsub, TC.Lower, string.match, string.format

TC.name = ADDON
local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
TC.version = GetMetadata and GetMetadata(ADDON, "Version") or "?"

TC.CATEGORIES = { "Streamers", "Politics", "Nationality", "Religion", "Sexual", "Bigotry", "Harassment",
                  "Dead Horses", "Custom" }
-- Categories merged into another (1.0.1, the user's call): saved choices, custom terms, imported and
-- shared lists that still name them land in Bigotry.
TC.CATEGORY_ALIAS = { ["Coded bigotry"] = "Bigotry", Slurs = "Bigotry" }
function TC.CategoryName(cat)
    return TC.CATEGORY_ALIAS[cat] or cat
end
-- Dead Horses (Thunderfury, Mankrik's wife, Chuck Norris) are matched with game names left in, since
-- the jokes are about game names and item links.
TC.UNMASKED = { ["Dead Horses"] = true }
TC.BUFFER_SECONDS = 30 * 60   -- recent-message buffer and hidden-message log
TC.BUFFER_MAX = 500
TC.FLAG_MAX = 1000            -- flagged entries kept, both lists together
TC.REPORT_MAX = 1000          -- auto-mute report entries kept
TC.TIMED_MUTE = 2 * 60 * 60   -- "Mute for 2 hours"
TC.SPAM_HITS = 3              -- spamming (6.5): this many hits in the window,
TC.SPAM_MESSAGES = 5          -- or this many messages
TC.SPAM_SECONDS = 120         -- in this many seconds
TC.SYMBOL_MIN = 8             -- symbol and script spam (6.5a): at least this many characters,
TC.SYMBOL_PERCENT = 80        -- more than this share not letters, digits or emoji
TC.MEME_WINDOW = 50           -- meme word mute: words counted over the last this many messages shown
TC.MEME_SHORT, TC.MEME_LONG = 30, 240   -- the two mute lengths offered, in minutes
TC.SCRIPT_MIN = 2             -- or this many letters of another script (Chinese, Cyrillic ...) at any length
TC.ALLOW_TRADE = 10 * 60      -- "Allow" on a muted player's trade covers them this long
TC.TALKING_NOW = 10 * 60      -- check queue: "talking now" means a message in this window
-- Stems (1.0.0): "olymp" covers olympus, olympvs, olympuz, olympos, olympia and olympic, and "olimp"
-- covers olimpus and olimpo, in one /who search each, along with spellings nobody has listed yet.
TC.DEFAULT_GUILD_WORDS = { "olymp", "olimp", "olmps", "mudhutter", "dustmonkey" }
TC.OLD_GUILD_WORDS = { olympus = "olymp", olympvs = "olymp", olympuz = "olymp", olympos = "olymp", olympia = "olymp",
                       olympic = "olymp", olimpus = "olimp", olimpo = "olimp" }
TC.DEFAULT_NAME_WORDS = { "mudhutter", "dustmonkey" }

local DEFAULTS = {
    enabled = true,
    categories = { Streamers = true, Politics = true, Nationality = true, Religion = true, Sexual = true, Bigotry = true,
                   Harassment = true, ["Dead Horses"] = true, Custom = true },
    -- What a match does, per category (Filter tab): Mute Forever (offensive), Timeout (the default:
    -- the message and, for TC.senderMinutes, the sender's other non-game messages), Hide Only
    -- (hideOnly: just the message), or Off (categories[cat] false). Dead Horses start as Hide Only.
    -- Harassment is a Timeout (1.0.1, the user's call): "kys" is everyday banter for many players.
    offensive = { Bigotry = true, Harassment = false },
    hideOnly = { ["Dead Horses"] = true },
    symbolSpam = true,
    -- Timeout (the sender rule): one hit starts it; look-back and flags-count-as-hits always on (6.5, 14.2).
    senderMinutes = 30,
    neverMuteFriends = true, neverMuteGuild = true,
    -- Muted players (section 13). One switch for group invites, guild invites and duels.
    declineRequests = true, declineInstant = false,
    trades = "ask",              -- "ask" or "decline"
    warnings = true,             -- inviting or whispering a muted player
    tooltip = true, bubbles = true,
    mirrorIgnore = true,         -- ignoring someone in the game mutes them here too (Players.lua)
    offensiveGuildNames = true,  -- guilds whose names match a Mute Forever term are muted
    -- OlympusNet watcher (section 12: guild names only, never mutes) and sharing (15)
    listenMode = "off",          -- "all" characters, "here" (only listenChar) or "off": off until you choose,
                                 -- since listening puts your name in Olympus's channel member list
    netNotice = false,           -- a chat line for each new guild heard on OlympusNet
    netChannelAlliance = "OlympusNet", netChannelHorde = "OlympusNetH", netPrefix = "OLYMPUS",
    acceptShares = true,
    -- Check queue (section 11)
    checkSettledDays = 7, checkRetryMinutes = 60, checkMisses = 3,
    keyWho = true,               -- any key press runs the next /who when it's ready
    learnNameplates = true,      -- read the guild of players whose nameplates appear (read only)
    -- 6.4: world = General, Trade, Trade (Services), LookingForGroup, LocalDefense, WorldDefense
    -- Where terms and timeouts apply (muted players are hidden everywhere TolerableChat looks).
    -- Whispers are off: private conversations aren't word-filtered.
    scope = { world = true, custom = true, say = true, whisper = false, community = true },   -- say covers yell and emote
    customOff = {},   -- [lowercased custom channel name] = true when that channel isn't filtered
    debug = false,
    window = {},
}
TC.LIMITS = { senderMinutes = { 5, 120 }, checkSettledDays = { 1, 60 }, checkRetryMinutes = { 5, 240 },
              checkMisses = { 1, 10 } }

local session = { hidden = 0, judged = 0, judgeTime = 0 }
TC.session = session

-- Stand-ins until Diag.lua replaces them. After an update that added Diag.lua, a /reload doesn't load
-- it (the game reads the file list at start-up); everything else still has to work then.
TC.counters = {}
function TC.Diag() end
function TC.Count() end
function TC.Max() end
function TC.NoteTouch() end
function TC.DiagData() return nil end
function TC.DiagError(_, err)
    local handler = geterrorhandler and geterrorhandler()
    if handler then handler(err) end
end

---------------------------------------------------------------------------------------------------
-- Output

function TC.Print(msg)
    local frame = DEFAULT_CHAT_FRAME or (ChatFrame1)
    if frame then frame:AddMessage("|cff66ccffTolerableChat|r: " .. tostring(msg)) end
end

function TC.Debug(msg)
    if TC.db and TC.db.settings.debug then TC.Print("|cff999999" .. tostring(msg) .. "|r") end
end

-- Whitespace in patterns: never %s on chat text or names. Lua's %s is the C library's isspace,
-- which on Windows also matches byte 0xA0, the last byte of many UTF-8 characters (à is C3 A0,
-- 你 is E4 BD A0), so trimming or squeezing with it cuts characters in half.
TC.WS = "[ \t\n\r\f\v]"

function TC.IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) and true or false
end

-- A game value as a usable string: not secret and not empty, else nil. A secret value can't even be
-- compared ("x == ''" errors), so this checks for secrets first.
function TC.Str(value)
    if type(value) ~= "string" or TC.IsSecret(value) or value == "" then return nil end
    return value
end

---------------------------------------------------------------------------------------------------
-- Saved data

local function Fill(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            Fill(dst[k], v)
        elseif dst[k] == nil or type(dst[k]) ~= type(v) then
            dst[k] = v
        end
    end
end

local function Table(t, key)
    if type(t[key]) ~= "table" then t[key] = {} end
    return t[key]
end

function TC.ClampSettings()
    local s = TC.db.settings
    for key, range in pairs(TC.LIMITS) do
        local v = math.floor(tonumber(s[key]) or DEFAULTS[key])
        s[key] = math.max(range[1], math.min(range[2], v))
    end
end

function TC.InitDB()
    if type(TolerableChatDB) ~= "table" then TolerableChatDB = {} end
    local db = TolerableChatDB
    TC.db = db
    db.version = 1
    Fill(Table(db, "settings"), DEFAULTS)
    -- Settings that 0.2 and earlier had and 0.3 made always-on.
    local s = db.settings
    s.fold, s.lookBack, s.flagIsHit, s.senderHits = nil, nil, nil, nil
    s.scope.yell, s.scope.emote = nil, nil   -- the "say" switch covers yell and emote
    -- 0.4: Bigotry and Coded bigotry became offensive (mute the sender) by default, once.
    if (db.settingsRev or 0) < 2 then
        s.offensive.Bigotry, s.offensive["Coded bigotry"] = true, true
        db.settingsRev = 2
    end
    -- 0.6: the listen switch became a choice that can be one character only.
    if s.listenNet == false then s.listenMode = "off" end
    s.listenNet = nil
    if s.listenMode ~= "all" and s.listenMode ~= "here" and s.listenMode ~= "off" then s.listenMode = "off" end
    s.recheckMuted = nil   -- 0.6.1: the sweep finds muted players who left their guild
    -- 0.9.1: the sender rule's on/off switch became a choice per category. Off meant no timeouts
    -- anywhere, so those categories become Hide Only.
    if s.senderRule == false then
        for _, cat in ipairs(TC.CATEGORIES) do
            if s.categories[cat] and not s.offensive[cat] then s.hideOnly[cat] = true end
        end
    end
    s.senderRule = nil
    TC.ClampSettings()

    local terms = Table(db, "terms")
    Table(terms, "custom")      -- { kind, text, cat, added } the user added
    Table(terms, "disabled")    -- [kind:text] = true, defaults or custom
    Table(terms, "hits")        -- [kind:text] = times it hid a message
    terms.defaultVersion = TC.DefaultTerms and TC.DefaultTerms.version

    if type(db.guildWords) ~= "table" then   -- a list, so kept outside the defaults
        db.guildWords = {}
        for i, w in ipairs(TC.DEFAULT_GUILD_WORDS) do db.guildWords[i] = w end
    end
    Table(db, "guildExceptions")   -- [lowercased exact guild name] = "Guild Name"
    if type(db.nameWords) ~= "table" then   -- a list, so kept outside the defaults
        db.nameWords = {}
        for i, w in ipairs(TC.DEFAULT_NAME_WORDS) do db.nameWords[i] = w end
    end
    -- 0.6.1: Dust Monkeys and Mudhutters by name too (the user's call), once.
    if (db.settingsRev or 0) < 3 then
        local function Ensure(list, word)
            for _, w in ipairs(list) do
                if w == word then return end
            end
            list[#list + 1] = word
        end
        Ensure(db.guildWords, "dustmonkey")
        Ensure(db.guildWords, "mudhutter")
        Ensure(db.nameWords, "dustmonkey")
        Ensure(db.nameWords, "mudhutter")
        db.settingsRev = 3
    end
    -- 0.9.2: whispers aren't word-filtered by default any more (the user's call), once.
    if (db.settingsRev or 0) < 5 then s.scope.whisper = false end
    -- 1.0.0: the old default spellings become the two stems that cover them; your own words stay.
    if (db.settingsRev or 0) < 7 then
        local out, have = {}, {}
        for _, w in ipairs(db.guildWords) do
            local word = TC.OLD_GUILD_WORDS[w] or w
            if not have[word] then
                have[word] = true
                out[#out + 1] = word
            end
        end
        db.guildWords = out
        db.imported = nil   -- the old addons' import was removed in 1.0.0
        db.settingsRev = 7
    end
    if (db.settingsRev or 0) < 8 then
        -- 1.0.1: Harassment's default became Timeout. Saved choices can't tell the old default from a
        -- choice, so every install moves once; the auto-mutes it made are judged again at login.
        s.offensive.Harassment = false
    end
    if (db.settingsRev or 0) < 9 then
        -- 1.0.1: Coded bigotry and Slurs merged into Bigotry. The merged category keeps the strictest
        -- choice any of the three had, and custom terms filed under them move with it.
        local rank = { off = 0, hide = 1, timeout = 2, mute = 3 }
        local function Action(cat)
            if s.categories[cat] == false then return "off" end
            if s.offensive[cat] then return "mute" end
            if s.hideOnly[cat] then return "hide" end
            return "timeout"
        end
        local best = Action("Bigotry")
        for old in pairs(TC.CATEGORY_ALIAS) do
            if s.categories[old] ~= nil and rank[Action(old)] > rank[best] then best = Action(old) end
        end
        s.categories.Bigotry, s.offensive.Bigotry, s.hideOnly.Bigotry = best ~= "off", best == "mute", best == "hide"
        for old in pairs(TC.CATEGORY_ALIAS) do
            s.categories[old], s.offensive[old], s.hideOnly[old] = nil, nil, nil
        end
        for _, t in ipairs(db.terms and db.terms.custom or {}) do t.cat = TC.CategoryName(t.cat) end
    end
    db.settingsRev = math.max(db.settingsRev or 0, 9)
    Table(db, "realms")            -- [realm] = the realm's players, mutes and guilds (TC.BindRealm)
    local flagged = Table(db, "flagged")
    Table(flagged, "missed")
    Table(flagged, "wrong")
    local stats = Table(db, "stats")
    stats.hiddenTotal = tonumber(stats.hiddenTotal) or 0
    stats.flaggedTotal = tonumber(stats.flaggedTotal) or 0
    Table(stats, "today")
    TC.BindRealm()
end

---------------------------------------------------------------------------------------------------
-- Per-realm data. Character and guild names are only unique within a realm, so everything keyed by
-- one lives under TolerableChatDB.realms[<realm>] and TC.rdb points at this realm's table: a mute on one
-- realm never hides a same-named character on another. Words, terms and settings stay account-wide.

TC.REALM_FIELDS = { "players", "mutes", "neverMute", "check", "olympusGuilds", "netGuilds", "muteReport",
                    "sweeps" }

local function RealmName()
    local name = GetNormalizedRealmName and GetNormalizedRealmName()
    if type(name) ~= "string" or name == "" or TC.IsSecret(name) then
        name = GetRealmName and GetRealmName()
        if type(name) ~= "string" or TC.IsSecret(name) then return nil end
        name = gsub(name, "[ \t\n\r\f\v%-]", "")   -- the normalized form: "Classic Beta PvE" -> "ClassicBetaPvE"
    end
    return name ~= "" and name or nil
end
TC.RealmName = RealmName

local function InitRealm(r)
    Table(r, "players")         -- [name key] = { name, guild (false: none), first, last, since, source, guid, faction }
    Table(r, "mutes")           -- [name key] = { name, kind = "hand" | "auto" | "timed", reason, added, expires }
    Table(r, "neverMute")       -- [name key] = { name = "First Last", added = time }
    Table(r, "muteReport")      -- auto-mutes, oldest first, for reviewing bad mutes
    local check = Table(r, "check")
    Table(check, "settled")     -- [key] = time the player's guild was confirmed by /who or a sweep
    Table(check, "offline")     -- [key] = { misses, retry }
    Table(check, "front")       -- list of keys queued with Check, first first
    Table(check, "recheck")     -- [key] = time a sweep missed this muted player while they were online (up to 0.9.6)
    Table(check, "muteGuildOf") -- [key] = time you asked to mute this player's guild once it's known
    Table(r, "ignoreReleased")  -- [key] = true: unmuted here while still on a game ignore list
    Table(r, "olympusGuilds")   -- [guild] = { first, last, source, total, reported, confirmed, faction }: the index
    Table(r, "netGuilds")       -- [guild] = { first, last, total, faction, senders, seen }: OlympusNet guilds not muted
    Table(r, "sweeps")          -- [faction] = { number, quiet = {} }: /who only shows your own faction
    return r
end

-- Moves values from one realm table into another without overwriting what is there.
local function Merge(from, to)
    for k, v in pairs(from) do
        if type(v) == "table" and type(to[k]) == "table" then Merge(v, to[k]) elseif to[k] == nil then to[k] = v end
    end
end

-- Points TC.rdb at this realm's table. The realm isn't always known when the saved data loads; then a
-- scratch table (not saved) stands in until login, when it is merged into the realm's own.
function TC.BindRealm()
    local db, name = TC.db, RealmName()
    if not name then
        if not TC.rdb then TC.rdb, TC.realmPending = InitRealm({}), true end
        return
    end
    if TC.realm == name and TC.rdb and db.realms[name] == TC.rdb then return end
    local r = InitRealm(Table(db.realms, name))
    -- 1.0.0: these lived at the top of the saved data, shared by every realm. They go to the realm
    -- that loads first: before 1.0.0 TolerableChat had only ever run on one realm.
    for _, field in ipairs(TC.REALM_FIELDS) do
        if type(db[field]) == "table" then
            Merge(db[field], r[field])
            db[field] = nil
        end
    end
    if type(db.whoSeen) == "table" then db.whoSeen.quiet, db.whoSeen.sweeps = nil, nil end
    if TC.realmPending and TC.rdb then Merge(TC.rdb, r) end
    TC.rdb, TC.realm, TC.realmPending = r, name, nil
    TC.Notify("RealmBound", r)
end

-- Today's counts for the Overview tab, reset when the date changes.
function TC.Today()
    local today = TC.db.stats.today
    local day = date("%Y-%m-%d")
    if today.day ~= day then
        today.day, today.hidden, today.flagged, today.muted = day, 0, 0, 0
    end
    return today
end

---------------------------------------------------------------------------------------------------
-- Events and internal notifications

local eventFrame = CreateFrame("Frame")
local handlers = {}

function TC.On(event, fn)
    local list = handlers[event]
    if not list then
        list = {}
        handlers[event] = list
        -- Unknown events (one client has an event, another doesn't) are skipped, not an error.
        if not pcall(eventFrame.RegisterEvent, eventFrame, event) then return end
    end
    list[#list + 1] = fn
end

-- xpcall with arguments. The game's xpcall passes them on; plain Lua 5.1's doesn't, so there a closure
-- carries them.
local XPCALL_ARGS = select(2, xpcall(function(a) return a end, function() end, true)) == true
function TC.XCall(fn, handler, ...)
    if XPCALL_ARGS then return xpcall(fn, handler, ...) end
    local n, args = select("#", ...), { ... }
    return xpcall(function() return fn(unpack(args, 1, n)) end, handler)
end

-- Each handler runs on its own: an error in one is logged (Diag.lua) and the others still run.
local function OnError(err)
    return tostring(err) .. "\n" .. (debugstack and debugstack(2, 6, 0) or "")
end
TC.OnError = OnError

-- fn wrapped for a hook the game calls (menus, tooltips): an error is logged and passed to the error
-- handler once (Diag.lua), and the game's own code carries on.
function TC.Guarded(where, fn)
    return function(...)
        local ok, err = TC.XCall(fn, OnError, ...)
        if not ok then TC.DiagError(where, err) end
    end
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if list then
        for i = 1, #list do
            local ok, err = TC.XCall(list[i], OnError, ...)
            if not ok and TC.DiagError then TC.DiagError(event, err) end
        end
    end
end)

local listeners = {}

function TC.Listen(name, fn)
    local list = listeners[name] or {}
    listeners[name] = list
    list[#list + 1] = fn
end

function TC.Notify(name, ...)
    local list = listeners[name]
    if list then
        for i = 1, #list do list[i](...) end
    end
end

---------------------------------------------------------------------------------------------------
-- Names. Forever characters are "First Last"; the game also writes "First Last-Realm" and, in
-- some places, "First-Last". Every name goes through NameKey, which returns a lowercase key
-- and a display name. The own realm is dropped; other realms stay.

local ownRealms

local function OwnRealms()
    if ownRealms then return ownRealms end
    local found = {}
    local normalized = GetNormalizedRealmName and GetNormalizedRealmName()
    local realm = GetRealmName and GetRealmName()
    if type(normalized) == "string" and normalized ~= "" then found[lower(normalized)] = true end
    if type(realm) == "string" and realm ~= "" then found[lower((gsub(realm, "[ \t\n\r\f\v%-]", "")))] = true end
    if next(found) then ownRealms = found end   -- not known before login; try again later
    return found
end

function TC.NameKey(name, realm)
    if type(name) ~= "string" or TC.IsSecret(name) then return nil end
    if TC.Str(realm) and not find(name, "-", 1, true) then
        name = name .. "-" .. realm
    end
    name = gsub(gsub(gsub(name, "^[ \t\n\r\f\v]+", ""), "[ \t\n\r\f\v]+$", ""), "[ \t\n\r\f\v]+", " ")
    if name == "" then return nil end
    local base, server = match(name, "^(.-)%-([^%-]+)$")
    if base and base ~= "" then
        if OwnRealms()[lower((gsub(server, "[ \t\n\r\f\v]", "")))] then
            name = base
        elseif not find(base, " ", 1, true) then
            -- "First-Last": a single hyphenated word is a first name and surname, not a realm.
            name = base .. " " .. server
        end
    end
    return lower(name), name
end

function TC.PlayerKey()
    if not TC.playerKey then
        local name, realm = UnitName("player")
        TC.playerKey = TC.NameKey(name, realm)
    end
    return TC.playerKey
end

---------------------------------------------------------------------------------------------------
-- Exemptions (section 8). Rebuilt lazily after the game says a list changed.

local friends, guildies, group = {}, {}, {}
local dirty = { friends = true, guild = true, group = true }

local function Wipe(t)
    for k in pairs(t) do t[k] = nil end
end

local function AddName(set, name, realm)
    local key = TC.NameKey(name, realm)
    if key then set[key] = true end
end

local function RebuildFriends()
    Wipe(friends)
    if C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetFriendInfoByIndex then
        for i = 1, C_FriendList.GetNumFriends() or 0 do
            local info = C_FriendList.GetFriendInfoByIndex(i)
            if info then AddName(friends, info.name) end
        end
    end
    -- Battle.net friends' current WoW characters, where the client exposes them.
    if BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendGameAccountInfo then
        for i = 1, (BNGetNumFriends()) or 0 do
            for j = 1, C_BattleNet.GetFriendNumGameAccounts(i) or 0 do
                local game = C_BattleNet.GetFriendGameAccountInfo(i, j)
                if game and game.clientProgram == (BNET_CLIENT_WOW or "WoW") and type(game.characterName) == "string" then
                    AddName(friends, game.characterName, game.realmName)
                end
            end
        end
    end
    dirty.friends = false
end

local function RebuildGuild()
    Wipe(guildies)
    if IsInGuild and IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo then
        for i = 1, (GetNumGuildMembers()) or 0 do
            AddName(guildies, (GetGuildRosterInfo(i)))
        end
    end
    dirty.guild = false
end

local function RebuildGroup()
    Wipe(group)
    local prefix, count = "party", GetNumSubgroupMembers and GetNumSubgroupMembers() or 0
    if IsInRaid and IsInRaid() then prefix, count = "raid", GetNumGroupMembers() or 0 end
    for i = 1, count do
        AddName(group, UnitName(prefix .. i))
    end
    dirty.group = false
end

local function IsPlayerGUID(guid)
    return type(guid) == "string" and not TC.IsSecret(guid) and find(guid, "^Player%-") ~= nil
end
TC.IsPlayerGUID = IsPlayerGUID

-- Why this player is never hidden, or nil.
function TC.ExemptReason(key, guid)
    if not key then return nil end
    local s = TC.db.settings
    if TC.rdb.neverMute[key] then return "never mute" end
    if dirty.group then RebuildGroup() end
    if group[key] then return "group" end
    local hasGUID = IsPlayerGUID(guid)
    if hasGUID and IsGUIDInGroup and IsGUIDInGroup(guid) then return "group" end
    if s.neverMuteFriends then
        if dirty.friends then RebuildFriends() end
        if friends[key] then return "friend" end
        if hasGUID and C_FriendList and C_FriendList.IsFriend and C_FriendList.IsFriend(guid) then return "friend" end
        if hasGUID and C_BattleNet and C_BattleNet.GetGameAccountInfoByGUID and C_BattleNet.GetGameAccountInfoByGUID(guid) then
            return "friend"
        end
    end
    if s.neverMuteGuild then
        if dirty.guild then RebuildGuild() end
        if guildies[key] then return "guild" end
        if hasGUID and IsGuildMember and IsGuildMember(guid) then return "guild" end
    end
    return nil
end

-- Toggles a name on the never-mute list. Returns true if it is now on the list.
function TC.ToggleNeverMute(name, realm)
    local key, display = TC.NameKey(name, realm)
    if not key then return nil end
    local list = TC.rdb.neverMute
    if list[key] then
        list[key] = nil
    else
        list[key] = { name = display, added = time() }
        if TC.OnNeverMute then TC.OnNeverMute(key) end   -- phase 2: removes them from the mute list
    end
    TC.Notify("Changed")
    return list[key] ~= nil, display
end

for _, event in ipairs({ "FRIENDLIST_UPDATE", "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_ACCOUNT_ONLINE",
                         "BN_FRIEND_ACCOUNT_OFFLINE", "BN_FRIEND_LIST_SIZE_CHANGED" }) do
    TC.On(event, function() dirty.friends = true end)
end
TC.On("GUILD_ROSTER_UPDATE", function() dirty.guild = true end)
TC.On("PLAYER_GUILD_UPDATE", function() dirty.guild = true end)
TC.On("GROUP_ROSTER_UPDATE", function() dirty.group = true end)

TC.On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    TC.InitDB()
    TC.CompileTerms()
    TC.Today()
    TC.Notify("Loaded")
end)

TC.On("PLAYER_LOGIN", function()
    if not TC.AutoMute or not TC.HealthLines then
        -- The game reads an addon's file list at start-up, so a /reload after an update that added a
        -- file doesn't load it.
        TC.Print("Updated with a new file: exit the game fully and start it again so everything works "
            .. "(auto-mutes, 2-hour mutes, diagnostics).")
    end
    TC.playerKey = nil
    TC.PlayerKey()
    if TC.realmPending then TC.BindRealm() end   -- the realm wasn't known when the saved data loaded
    if C_GuildInfo and C_GuildInfo.GuildRoster and IsInGuild and IsInGuild() then C_GuildInfo.GuildRoster() end
    dirty.friends, dirty.guild, dirty.group = true, true, true
    TC.Notify("Login")
end)
