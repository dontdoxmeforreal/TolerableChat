-- Check queue and guild sweep (spec 11): one /who per press of the Next /who button or its key
-- binding, never from anything else. The game only lets /who run from a key press or click, shows
-- only your faction, and returns at most 50 players per search.
--
-- The guild sweep does nearly all the work. It starts with one search per muted guild word
-- (g-"olympus" 1-60), to discover which Olympus guilds are online, then gives every known Olympus
-- guild (the index: Players.lua TC.NoteOlympusGuild) a search of its own, g-"OLYMPUS XIIl" 1-60,
-- the guilds with the most members still unknown first. A guild search that comes back full (more
-- players than /who shows) is split: level range in halves, then by class, then by race. A finished
-- discovery sweep (every third: the word searches split too) has listed every online member of a muted
-- guild, so everyone else seen online during it (talking, sending OlympusNet traffic, in the channel's
-- member list) is cleared at once: no search of their own. The sweeps in between leave guilds not yet
-- in the index unsearched, so they clear nobody. Only a few players get a search of their own:
--   - players you asked to check (right-click Check, /tc check Name);
--   - muted players you asked to re-check (Re-check guild).
-- Nobody heard on OlympusNet gets one (1.0.1): only guild names are read there. Sweep state is kept
-- per realm and faction.

local _, TC = ...
local format, lower, match, find, gsub, floor = string.format, TC.Lower, string.match, string.find, string.gsub, math.floor
local gmatch, sub = string.gmatch, string.sub

local COOLDOWN_START, COOLDOWN_FLOOR, COOLDOWN_MAX = 5, 5, 15   -- seconds between searches
-- Never closer than 5 s: the server's limit, never pushed (the user's rule). Each "wait" from the
-- server adds 1 s and raises the floor above the wait that was too short; after 20 answers in a
-- row the wait shrinks by 1 s, but never below the floor.
local REPLY_WAIT = 6                        -- no answer in this long: treated like "wait"
local WHO_CAP = 50
local SEEN_SLACK = 600      -- online: seen within 10 minutes of the searches that would have found them
local SEEN_KEEP = 7200      -- sightings older than 2 hours are forgotten
local QUIET_EVERY = 3       -- a guild word whose last search found nobody new is searched every 3rd sweep
-- Class and race combinations each faction allows. Horde follows Forever's own table (client data,
-- build 70374: Orc Mages, Troll Warlocks, Undead-only Paladins and the Windshaper Skyborne); Alliance
-- is still the classic table. /who answers add any other combination, learned per faction. Your
-- faction decides: /who only shows players of your own faction.
local SKYBORNE = "Windshaper Skyborne"
local COMBOS = {
    Horde = { WARRIOR = { "Orc", "Undead", "Tauren", "Troll", SKYBORNE }, HUNTER = { "Orc", "Tauren", "Troll", SKYBORNE },
              ROGUE = { "Orc", "Undead", "Troll", SKYBORNE }, PRIEST = { "Undead", "Troll" },
              SHAMAN = { "Orc", "Tauren", "Troll", SKYBORNE }, MAGE = { "Orc", "Undead", "Troll", SKYBORNE },
              WARLOCK = { "Orc", "Undead", "Troll" }, DRUID = { "Tauren", SKYBORNE }, PALADIN = { "Undead" } },
    Alliance = { WARRIOR = { "Human", "Dwarf", "Night Elf", "Gnome" }, PALADIN = { "Human", "Dwarf" },
                 HUNTER = { "Dwarf", "Night Elf" }, ROGUE = { "Human", "Dwarf", "Night Elf", "Gnome" },
                 PRIEST = { "Human", "Dwarf", "Night Elf" }, MAGE = { "Human", "Gnome" }, WARLOCK = { "Human", "Gnome" },
                 DRUID = { "Night Elf" } },
}
local ZONES_MAX = 10   -- a search still full at one level, class and race splits into its answer's zones
-- Still full after that (a crowd in one zone), a guild's own search goes by letters in the name. /who
-- matches any part of a name (n-" b" finds a b anywhere: the space is dropped), so n-"b", then n-"ba",
-- n-"bal" overlap rather than split, but every name is reached through its own first letters.
local NAME_DEPTH = 3   -- "b", "ba", "bal": up to 26^3 searches for one crowd, only where still full
local LETTERS = "abcdefghijklmnopqrstuvwxyz"

-- 1, 3, 4, 7 and 8 were OlympusNet leads (gone in 1.0.1); kept so the numbers stay put.
TC.CHECK_REASONS = { "OlympusNet lead, talking now", "talking now, guild unknown", "OlympusNet lead",
                     "OlympusNet channel member", "added with Check", "Re-check guild (by you)",
                     "sent OlympusNet traffic", "OlympusNet lead of the other faction" }
-- Reasons that get a /who of their own; the others wait for the sweep to settle them.
local OWN_SEARCH = { [5] = true, [6] = true }
local PROBES = 3             -- per sweep: Olympus guilds only heard on OlympusNet, each searched once by name
TC.CHECK_OWN_SEARCH = OWN_SEARCH

local pending, readyAt, cooldown, okStreak, lastAnswer, quietUntil = nil, 0, COOLDOWN_START, 0, nil, 0
local minWait = COOLDOWN_FLOOR
local sweep, lastSweep = nil, nil
local tonight = { checked = 0, muted = 0, cleared = 0, offline = 0, searches = 0, sweeps = 0 }
TC.checkTonight = tonight

local function Settings() return TC.db.settings end

-- Classes and races /who has shown (races per faction), added to the split lists. Game data, so
-- account-wide.
local function Seen()
    local db = TC.db
    if type(db.whoSeen) ~= "table" then db.whoSeen = {} end
    local seen = db.whoSeen
    if type(seen.classes) ~= "table" then seen.classes = {} end
    if type(seen.races) ~= "table" then seen.races = {} end
    if type(seen.combos) ~= "table" then seen.combos = {} end
    local faction = UnitFactionGroup("player") or "?"
    if type(seen.races[faction]) ~= "table" then seen.races[faction] = {} end
    if type(seen.combos[faction]) ~= "table" then seen.combos[faction] = {} end
    return seen, seen.races[faction], seen.combos[faction]   -- combos: [class] = { [race] = true }
end

-- This realm's and faction's sweep count, and how many sweeps in a row each guild word's search (and
-- each guild's, "g:name") found nobody new.
local function SweepData()
    local faction = UnitFactionGroup("player") or "?"
    local all = TC.rdb.sweeps
    local d = all[faction]
    if type(d) ~= "table" then
        d = {}
        all[faction] = d
    end
    if type(d.quiet) ~= "table" then d.quiet = {} end
    d.number = tonumber(d.number) or 0
    return d
end
TC.SweepData = SweepData

local function Recheck()
    local check = TC.rdb.check
    if type(check.recheck) ~= "table" then check.recheck = {} end
    return check.recheck
end

---------------------------------------------------------------------------------------------------
-- Who is online: players seen since login (talking, OlympusNet traffic, channel member list), with
-- their class and race when the game knows them. Memory only.

local online = {}
TC.online = online

function TC.SeenOnline(key, guid)
    if not key then return end
    local now = time()
    local o = online[key]
    if not o then
        o = { first = now }
        online[key] = o
    end
    o.last = now
    if guid and not o.class and GetPlayerInfoByGUID and TC.IsPlayerGUID(guid) then
        local ok, class, _, race = pcall(GetPlayerInfoByGUID, guid)
        if ok then o.class, o.race = TC.Str(class), TC.Str(race) end
    end
end

-- Lines in the filtered chat types, muted players' among them (a muted player the sweep misses may
-- have left the guild).
local function NoteMessage(e)
    if e and e.key and (e.filterable or e.muteReason) then TC.SeenOnline(e.key, e.guid) end
end
TC.Listen("Shown", NoteMessage)
TC.Listen("Hidden", NoteMessage)

---------------------------------------------------------------------------------------------------
-- Players to check

-- Not queued: muted, exempt, settled recently, or an offline retry not due yet. force (reason 6)
-- ignores muted and settled.
local function Skip(key, force)
    local db = TC.rdb
    if TC.ExemptReason(key) then return true end
    if not force then
        if TC.MuteReason(key) then return true end
        local settled = db.check.settled[key]
        if settled and time() - settled < Settings().checkSettledDays * 86400 then return true end
    end
    local off = db.check.offline[key]
    if off and (off.dropped or time() < (off.retry or 0)) then return true end
    return false
end

-- Players to check in priority order: { key, name, reason (index into TC.CHECK_REASONS) }. Reasons in
-- OWN_SEARCH come first; the rest are listed so the Check tab can count what the sweep will clear.
function TC.CheckQueue()
    local db, q, seen = TC.rdb, {}, {}
    local function Add(key, name, reason, force)
        if not key or seen[key] or key == TC.PlayerKey() then return end
        seen[key] = true
        if not Skip(key, force) then q[#q + 1] = { key = key, name = name or key, reason = reason } end
    end
    for _, item in ipairs(db.check.front) do Add(item.key, item.name, 5) end
    local talking, now = {}, TC.Now()
    for _, e in ipairs(TC.RecentEntries(function(e) return e.filterable and now - e.now <= TC.TALKING_NOW end)) do
        talking[e.key] = talking[e.key] or e.sender
    end
    for key in pairs(Recheck()) do
        local p = db.players[key]
        if p and p.guild and TC.GuildMuted(p.guild) then Add(key, p.name, 6, true) else Recheck()[key] = nil end
    end
    for key, name in pairs(talking) do
        if not db.players[key] then Add(key, name, 2) end
    end
    return q
end

-- Puts a player at the front of the queue (right-click Check, /tc check Name).
function TC.QueueCheck(name, realm)
    local key, display = TC.NameKey(name, realm)
    if not key then return nil end
    local front = TC.rdb.check.front
    for i = #front, 1, -1 do
        if front[i].key == key then table.remove(front, i) end
    end
    table.insert(front, 1, { key = key, name = display })
    TC.rdb.check.settled[key] = nil
    local off = TC.rdb.check.offline[key]
    if off then off.retry, off.dropped = 0, nil end   -- due now; earlier misses still count
    TC.Notify("Check")
    return display
end

---------------------------------------------------------------------------------------------------
-- The guild sweep

local function MaxLevel()
    local level = GetMaxPlayerLevel and GetMaxPlayerLevel()
    return (type(level) == "number" and level > 0) and level or 60
end

local function SortedKeys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return out
end

local fileByName, nameByFile
local function ClassNames()
    if not fileByName then
        fileByName, nameByFile = {}, {}
        for id = 1, 12 do
            local name, file = nil, nil
            if GetClassInfo then name, file = GetClassInfo(id) end
            if type(name) == "string" and name ~= "" and type(file) == "string" then
                fileByName[name], nameByFile[file] = file, name
            end
        end
    end
    return fileByName, nameByFile
end

local function Faction()
    return COMBOS[UnitFactionGroup("player") or ""] and UnitFactionGroup("player") or "Horde"
end

-- Classes of your faction to split by: the allowed ones by their game names, plus any /who showed.
local function Classes()
    local _, nameByFile = ClassNames()
    local set = {}
    for file in pairs(COMBOS[Faction()]) do
        local name = nameByFile[file]
        if name then set[name] = true end
    end
    local _, _, combos = Seen()
    for class in pairs(combos) do set[class] = true end
    return SortedKeys(set)
end

-- Races this class can be in your faction: the allowed ones, plus any /who showed with it.
local function RacesFor(class)
    local fileByName = ClassNames()
    local set = {}
    for _, race in ipairs(COMBOS[Faction()][fileByName[class] or ""] or {}) do set[race] = true end
    local _, _, combos = Seen()
    for race in pairs(combos[class] or {}) do set[race] = true end
    return SortedKeys(set)
end

local function SweepFilter(spec)
    local parts = { format('g-"%s"', spec.word) }
    if spec.class then parts[#parts + 1] = format('c-"%s"', spec.class) end
    if spec.race then parts[#parts + 1] = format('r-"%s"', spec.race) end
    if spec.zone then parts[#parts + 1] = format('z-"%s"', spec.zone) end
    if spec.name then parts[#parts + 1] = format('n-"%s"', spec.name) end
    parts[#parts + 1] = format("%d-%d", spec.lo, spec.hi)
    return table.concat(parts, " ")
end
TC.SweepFilter = SweepFilter

-- Letters in a name search's prefix (UTF-8 letters count once).
local function NameDepth(prefix)
    return prefix and #gsub(prefix, "[\128-\191]", "") or 0
end

-- The letters to add to a name search's letters: a to z, and any other letter (accented, another
-- script) that follows them anywhere in the answer's names (any letter of a name, for the first step).
local CHAR = "[\1-\127\194-\244][\128-\191]*"
local function NextLetters(prefix, names)
    local set = {}
    for c in gmatch(LETTERS, ".") do set[c] = true end
    for _, name in ipairs(names or {}) do
        local low = lower(name)
        if prefix == "" then
            for c in gmatch(low, CHAR) do set[c] = true end
        else
            local at = find(low, prefix, 1, true)
            while at do
                local c = match(sub(low, at + #prefix), "^" .. CHAR)
                if c then set[c] = true end
                at = find(low, prefix, at + 1, true)
            end
        end
    end
    set[" "], set['"'], set["-"] = nil, nil, nil
    return SortedKeys(set)
end

-- Finer searches for one that came back full, or nil when it can't be split further: the level range
-- in halves down to one level, then class, then race (skipped for a class with only one race in your
-- faction), then the zones its answer showed (zones = { [zone] = players }), most players first, then,
-- for a guild's own search, letters in the name (n-"b", n-"ba", n-"bal"). Neither zones nor names are
-- a sure split (a zone nobody in the answer was in isn't searched; a name with only letters no answer
-- showed isn't either), so a search split by them still counts as "not sure" for clearing. A guild's
-- search isn't one guild's 999 members at most: it reaches every guild whose name contains its name
-- (OLYMPUS PVE reaches Olympus PVE II). It splits by letters because guild searches are what find
-- every member between discovery sweeps. Word searches stop at zones: they are there to find guilds,
-- one member shown is enough to add a guild, and the guild searches of the next sweeps find the rest.
local function Split(spec, zones, names)
    local children = {}
    local function Child(changes)
        local c = { word = spec.word, lo = spec.lo, hi = spec.hi, class = spec.class, race = spec.race, zone = spec.zone,
                    name = spec.name, perGuild = spec.perGuild }
        for k, v in pairs(changes) do c[k] = v end
        children[#children + 1] = c
    end
    if spec.hi > spec.lo then
        local mid = floor((spec.lo + spec.hi) / 2)
        Child({ hi = mid })
        Child({ lo = mid + 1 })
    elseif not spec.class then
        for _, class in ipairs(Classes()) do Child({ class = class }) end
    elseif not spec.race and #RacesFor(spec.class) > 1 then
        for _, race in ipairs(RacesFor(spec.class)) do Child({ race = race }) end
    elseif not spec.zone and not spec.name and zones and next(zones) then
        local list = {}
        for zone, n in pairs(zones) do list[#list + 1] = { zone = zone, n = n } end
        table.sort(list, function(a, b)
            if a.n ~= b.n then return a.n > b.n end
            return a.zone < b.zone
        end)
        for i = 1, math.min(#list, ZONES_MAX) do Child({ zone = list[i].zone }) end
        if children[1] then children.byZone = true end
    elseif spec.perGuild and NameDepth(spec.name) < NAME_DEPTH then
        local prefix = spec.name or ""
        for _, c in ipairs(NextLetters(prefix, names)) do Child({ name = prefix .. c }) end
        children.byName = true
    end
    return children[1] and children or nil
end
TC.SweepSplit = Split
TC.SweepClasses = function() return Classes() end

-- kind "word": discovery, one per guild word; when full it isn't split (the guild searches cover
-- it), but every Olympus guild in its answer gets a search of its own. kind "guild": one known guild.
local function Root(word, kind)
    return { word = word, lo = 1, hi = MaxLevel(), root = kind or "word", perGuild = kind == "guild" or nil }
end

-- A guild name /who can search for (the filter is quoted).
local function Searchable(name)
    return type(name) == "string" and name ~= "" and not find(name, '"', 1, true)
end

-- A guild a word search reaches: its name contains the word as written.
local function Covered(low, words)
    for word in pairs(words) do
        if find(low, word, 1, true) then return true end
    end
    return false
end

-- Each indexed guild's faction: most of its known members', else its census's. nil: not known yet.
local function GuildFactions()
    local counts = {}
    for _, p in pairs(TC.rdb.players) do
        if p.guild and p.faction then
            local low = lower(p.guild)
            counts[low] = counts[low] or {}
            counts[low][p.faction] = (counts[low][p.faction] or 0) + 1
        end
    end
    local out = {}
    for low, c in pairs(counts) do out[low] = (c.Horde or 0) >= (c.Alliance or 0) and "Horde" or "Alliance" end
    for name, r in pairs(TC.rdb.olympusGuilds) do
        local low = lower(name)
        if not out[low] and r.faction then out[low] = r.faction end
    end
    return out
end
TC.GuildFactions = GuildFactions

local function StartSweep()
    local data = SweepData()
    local number = data.number + 1
    data.number = number
    local specs, words, skipped, quietGuilds = {}, {}, {}, 0
    local mine = UnitFactionGroup("player")
    local factions = GuildFactions()
    local function OurSide(low) return not factions[low] or not mine or factions[low] == mine end
    -- Indexed guilds /who can find from here: confirmed in game, and of this faction (or not known yet).
    local indexed, otherSide = 0, 0
    for name, r in pairs(TC.rdb.olympusGuilds) do
        if r.confirmed and TC.GuildMuted(name) then
            if OurSide(lower(name)) then indexed = indexed + 1 else otherSide = otherSide + 1 end
        end
    end
    -- Every third sweep is a discovery sweep (and so is every sweep while this faction's index is small):
    -- the word searches split like guild searches, so members of guilds not in the index yet are found
    -- and their guilds indexed. In between, every indexed guild gets a search of its own.
    local discovery = number % QUIET_EVERY == 1 or indexed < 5
    local due = discovery
    -- 1. One search per guild word (all of them in a discovery sweep; otherwise a word whose search
    --    found nobody the others hadn't is left out).
    local allWords = {}
    for _, word in ipairs(TC.db.guildWords) do
        allWords[lower(word)] = true
        if (data.quiet[word] or 0) == 0 or due then
            specs[#specs + 1] = Root(word, "word")
            words[lower(word)] = true
        else
            skipped[#skipped + 1] = word
        end
    end
    -- 2. One search per Olympus guild the game has shown members of, the most members still unknown
    --    first. A guild nobody of which was online last time is left out until a sweep finds one of its
    --    members again (a discovery sweep's word searches reach it). The other faction's are left out.
    local known = {}
    for _, p in pairs(TC.rdb.players) do
        if p.guild then known[lower(p.guild)] = (known[lower(p.guild)] or 0) + 1 end
    end
    local candidates, probes = {}, {}
    for name, r in pairs(TC.rdb.olympusGuilds) do
        local low = lower(name)
        if Searchable(name) and TC.GuildMuted(name) and not words[low] and OurSide(low) then
            if r.confirmed then
                -- In a discovery sweep the word searches already reach guilds whose names contain the word.
                if not (discovery and Covered(low, words)) then
                    if (data.quiet["g:" .. low] or 0) == 0 or due then
                        candidates[#candidates + 1] = { name = name, low = low, gap = (r.total or 100) - (known[low] or 0) }
                    else
                        quietGuilds = quietGuilds + 1
                    end
                end
            elseif not r.probed and not Covered(low, allWords) then
                -- 3. Heard only on OlympusNet, with a name no word search finds ("0LYMPUS ..."): a few are
                --    searched once each, so made-up names can't take over the sweep.
                probes[#probes + 1] = { name = name, low = low, first = r.first or 0 }
            end
        end
    end
    -- /who matches any part of a guild name, so a guild whose name contains another's (Olympus PVE II
    -- and OLYMPUS PVE, OLYMPUS MUDHUTTERS and MUDHUTTERS) is in that guild's search already: shortest
    -- names first, and a longer one adds its unknown members to the search that reaches it instead of
    -- getting one of its own.
    table.sort(candidates, function(a, b)
        if #a.low ~= #b.low then return #a.low < #b.low end
        return a.low < b.low
    end)
    local guilds, guildNames, reached = {}, {}, 0
    for _, c in ipairs(candidates) do
        local into
        for _, g in ipairs(guilds) do
            if find(c.low, g.low, 1, true) then into = g break end
        end
        if into then
            into.gap = into.gap + c.gap
            reached = reached + 1
        else
            guilds[#guilds + 1] = c
            guildNames[c.low] = true
            words[c.low] = true
        end
    end
    table.sort(guilds, function(a, b)
        if a.gap ~= b.gap then return a.gap > b.gap end
        return a.name < b.name
    end)
    for i = #probes, 1, -1 do
        if Covered(probes[i].low, guildNames) then table.remove(probes, i) end
    end
    table.sort(probes, function(a, b)
        if a.first ~= b.first then return a.first > b.first end
        return a.name < b.name
    end)
    for _, g in ipairs(guilds) do specs[#specs + 1] = Root(g.name, "guild") end
    for i = 1, math.min(#probes, PROBES) do
        local spec = Root(probes[i].name, "guild")
        spec.probe = true
        specs[#specs + 1] = spec
        words[probes[i].low] = true
        guildNames[probes[i].low] = true
    end
    sweep = { pending = specs, done = 0, found = 0, new = 0, muted = 0, capped = 0, started = time(), number = number,
              words = words, guildNames = guildNames, foundKeys = {}, added = {}, leaves = {}, rootNum = {},
              guildsSeen = {}, completeWords = {}, guilds = #guilds, reached = reached, discovery = discovery }
    tonight.sweeps = tonight.sweeps + 1
    TC.Diag("sweep", "sweep %d started%s: %d guild words, %d known muted guilds%s%s%s%s%s", number,
        discovery and " (discovery: word searches split too)" or "", #specs - #guilds - math.min(#probes, PROBES), #guilds,
        reached > 0 and format(" (and %d more their searches reach: their names contain one of these)", reached) or "",
        skipped[1] and (", without " .. table.concat(skipped, ", ") .. " (nobody new last time)") or "",
        quietGuilds > 0 and format(", %d guilds left out (nobody online last time)", quietGuilds) or "",
        otherSide > 0 and format(", %d of the other faction left out", otherSide) or "",
        #probes > 0 and format(", %d of %d heard only on OlympusNet searched once", math.min(#probes, PROBES), #probes) or "")
end

-- A guild found during the sweep that has no search in it yet gets one, at the end.
local function AddGuildRoot(s, guild)
    local low = lower(guild)
    if s.words[low] or not Searchable(guild) then return false end
    if s.discovery and Covered(low, s.words) then return false end   -- a word search is splitting for it
    if Covered(low, s.guildNames) then return false end   -- a guild search with a shorter name reaches it
    s.words[low] = true
    s.guildNames[low] = true
    s.guilds = (s.guilds or 0) + 1
    s.pending[#s.pending + 1] = Root(guild, "guild")
    return true
end

-- Whether the finished sweep listed every online member of this muted guild: its own guild search ran
-- (guild searches split until they're complete), or a word search reaching it was complete (not full,
-- or split, as in every discovery sweep). Between discovery sweeps the word searches come back full
-- and aren't split, so a guild not in the index isn't covered.
local function Complete(s, guild)
    local name = lower(guild)
    for searched in pairs(s.rootNum) do
        if find(name, searched, 1, true) then return true end   -- its own search, or one its name contains
    end
    for word in pairs(s.completeWords) do
        if find(name, word, 1, true) then return true end
    end
    return false
end

-- The finished sweep's searches that would have listed this player, by class and race when known:
-- earliest and latest time, and whether any of them was still full (so it may have missed them).
local function Covering(s, o)
    local first, last, full
    for _, leaf in ipairs(s.leaves) do
        if (not leaf.class or not o.class or leaf.class == o.class) and (not leaf.race or not o.race or leaf.race == o.race) then
            if leaf.full then full = true end
            first = math.min(first or leaf.t, leaf.t)
            last = math.max(last or leaf.t, leaf.t)
        end
    end
    return first, last, full
end

-- Players seen online during the sweep and not found by it. After a discovery sweep they aren't in a
-- muted guild: cleared (settled) without a search of their own. A sweep in between clears nobody (see
-- Complete). A muted player that a complete search of their guild should have found is queued for a
-- check of their own instead (left the guild?).
local function ClearUnfound(s)
    local db, now = TC.rdb, time()
    local cleared, uncertain, recheck, waiting = 0, 0, 0, 0
    local me = TC.PlayerKey()
    for key, o in pairs(online) do
        if now - o.last > SEEN_KEEP then
            online[key] = nil
        elseif not s.foundKeys[key] and key ~= me then
            local first, last, full = Covering(s, o)
            if first and o.last >= first - SEEN_SLACK and o.first <= last + SEEN_SLACK then
                local p = db.players[key]
                if full then
                    uncertain = uncertain + 1
                elseif TC.GuildMutedBy(p) then
                    -- Muted for good (guild mutes stick): a complete search of their guild missing them only
                    -- means they may have left it; counted, not checked (Re-check is by hand).
                    if p.guild and TC.GuildMuted(p.guild) and Complete(s, p.guild) then recheck = recheck + 1 end
                elseif s.discovery then
                    local settled = db.check.settled[key]
                    if not (settled and now - settled < Settings().checkSettledDays * 86400) then cleared = cleared + 1 end
                    db.check.settled[key] = now
                else
                    waiting = waiting + 1
                end
            end
        end
    end
    s.cleared, s.uncertain, s.recheck, s.waiting = cleared, uncertain, recheck, waiting
    tonight.cleared = tonight.cleared + cleared
end

local function FinishSweep()
    local s = sweep
    sweep = nil
    s.finished = time()
    lastSweep = s
    local quiet = SweepData().quiet
    for _, word in ipairs(TC.db.guildWords) do
        if s.words[lower(word)] then
            if (s.added[word] or 0) > 0 then quiet[word] = nil else quiet[word] = (quiet[word] or 0) + 1 end
        end
    end
    for low, num in pairs(s.rootNum) do
        if num > 0 then quiet["g:" .. low] = nil else quiet["g:" .. low] = (quiet["g:" .. low] or 0) + 1 end
    end
    -- A quiet guild whose members any search found (a discovery sweep's word searches) is searched again.
    for low in pairs(s.guildsSeen) do quiet["g:" .. low] = nil end
    ClearUnfound(s)
    local clearing = s.discovery and format("cleared %d others seen online, %d not sure (in a full search)", s.cleared,
        s.uncertain) or format("cleared nobody (only discovery sweeps clear; %d seen online wait for the next one)", s.waiting)
    TC.Diag("sweep", "sweep %d finished in %d min: %d searches, %d players found (%d new, %d in muted guilds), %d "
        .. "still full at the finest split; %s; %d muted players not found (they may have left; muted anyway)", s.number,
        math.ceil((s.finished - s.started) / 60), s.done, s.found, s.new, s.muted, s.capped, clearing, s.recheck)
    TC.Notify("Check")
end

function TC.SweepState()
    return sweep, lastSweep
end

-- A guild word added during a sweep is searched in it too.
TC.Listen("GuildsChanged", function()
    if not sweep then return end
    for _, word in ipairs(TC.db.guildWords) do
        if not sweep.words[lower(word)] then
            sweep.words[lower(word)] = true
            sweep.pending[#sweep.pending + 1] = Root(word, "word")
        end
    end
end)

---------------------------------------------------------------------------------------------------
-- One press

local function BaseName(name)
    return (match(name, "^(.-)%-[^%-]+$") or name)
end

-- Forever's Who list lives in the group finder (LFGWhoListFrame, loaded once you open it). It opens its
-- window for every /who answer, ours included, so during our search it doesn't get the answer: it is
-- taken off WHO_LIST_UPDATE and put back as soon as the answer (or the timeout) comes. Not while you
-- have it open yourself, and not in combat.
local function WhoListFrame()
    return LFGWhoListFrame or WhoFrame
end

local function WhoWindowShown()
    return (LFGParentFrame and LFGParentFrame:IsShown()) or (FriendsFrame and FriendsFrame:IsShown())
        or (WhoFrame and WhoFrame:IsShown()) or false
end

local detached
local function DetachWhoList()
    local f = WhoListFrame()
    if not f or WhoWindowShown() or (InCombatLockdown and InCombatLockdown()) then return end
    if f.IsEventRegistered and not f:IsEventRegistered("WHO_LIST_UPDATE") then return end
    if pcall(f.UnregisterEvent, f, "WHO_LIST_UPDATE") then
        detached = f
        TC.NoteTouch("Who list taken off WHO_LIST_UPDATE")
    end
end

local function ReattachWhoList()
    local f = detached
    detached = nil
    if f then pcall(f.RegisterEvent, f, "WHO_LIST_UPDATE") end
end

-- Results go to WHO_LIST_UPDATE, not chat; afterwards the setting is whatever the Who window wants.
local function SetWhoToUi(on)
    if not (C_FriendList and C_FriendList.SetWhoToUi) then return end
    local f = WhoListFrame()
    C_FriendList.SetWhoToUi(on or (f and f.IsShown and f:IsShown()) or false)
end

-- The server said "wait" (or didn't answer): the same search runs again on the next press, and the
-- time between searches grows by a second.
local function Throttled(p, why)
    if pending ~= p then return end
    pending = nil
    okStreak = 0
    minWait = math.min(COOLDOWN_MAX, math.max(minWait, cooldown + 1))
    cooldown = math.min(COOLDOWN_MAX, math.max(minWait, cooldown + 1))
    readyAt = GetTime() + cooldown
    ReattachWhoList()
    SetWhoToUi(false)
    TC.Count(why == "wait" and "whoThrottled" or "whoNoReply")
    TC.Diag("who", "%s for %s: the same search runs on the next press; %d s between searches now",
        why == "wait" and "the server said wait" or ("no answer in " .. REPLY_WAIT .. " s"), p.filter, cooldown)
    TC.Notify("Check")
end

-- What the next press will do: { kind = "player", item }, { kind = "sweep", spec }, { kind = "new sweep" }
-- or { kind = "idle" }.
local function NextAction(q)
    q = q or TC.CheckQueue()
    for _, item in ipairs(q) do
        if OWN_SEARCH[item.reason] then return { kind = "player", item = item } end
    end
    if not TC.db.guildWords[1] then
        -- No guild words to sweep for: players are checked one by one.
        if q[1] then return { kind = "player", item = q[1] } end
        return { kind = "idle" }
    end
    if sweep and sweep.pending[1] then return { kind = "sweep", spec = sweep.pending[1] } end
    return { kind = "new sweep" }
end

function TC.CheckCooldown()
    return math.max(0, readyAt - GetTime())
end

function TC.CheckPending()
    return pending
end

function TC.CheckNext()
    local now = GetTime()
    if pending then return TC.Count("whoPressWaiting") end
    if now < readyAt then return TC.Count("whoPressEarly") end
    if not (C_FriendList and C_FriendList.SendWho) then
        TC.Print("/who isn't available on this client.")
        return
    end
    local action = NextAction()
    if action.kind == "idle" then return TC.Print("Nobody to check, and no muted guild words to sweep for.") end
    if action.kind == "new sweep" then
        if TC.NetRefreshRoster then TC.NetRefreshRoster() end   -- fresh sightings of the channel's members
        StartSweep()
        if not sweep.pending[1] then
            sweep = nil
            return TC.Print("No muted guild words to search for.")
        end
        action = { kind = "sweep", spec = sweep.pending[1] }
    end
    local p = { kind = action.kind, sent = now, windowWasShown = WhoWindowShown() }
    if action.kind == "player" then
        p.key, p.name, p.reason = action.item.key, action.item.name, action.item.reason
        p.filter = format('n-"%s"', BaseName(action.item.name))
    else
        p.spec = action.spec
        p.filter = SweepFilter(action.spec)
    end
    pending = p
    quietUntil = now + REPLY_WAIT + 3
    DetachWhoList()
    SetWhoToUi(true)   -- read quietly from WHO_LIST_UPDATE, not as chat lines
    C_FriendList.SendWho(p.filter)
    TC.Count("whoSent")
    readyAt = now + cooldown
    C_Timer.After(REPLY_WAIT, function() Throttled(p, "timeout") end)
    TC.Notify("Check")
end

local function Answer()
    local p = pending
    pending = nil
    local db = TC.rdb
    local num, total = C_FriendList.GetNumWhoResults()
    num, total = num or 0, total or num or 0
    lastAnswer = GetTime()
    quietUntil = lastAnswer + 2   -- any chat copy of the results arrives with the answer
    ReattachWhoList()
    okStreak = okStreak + 1
    if okStreak >= 20 and cooldown > minWait then
        cooldown, okStreak = cooldown - 1, 0
        TC.Diag("who", "20 answers in a row: %d s between searches now", cooldown)
    end
    TC.Count("whoAnswered")
    tonight.searches = tonight.searches + 1
    local found, new, muted = nil, 0, 0
    local resultGuilds = {}
    local seen, seenRaces, combos = Seen()
    local zones, names = {}, {}
    local s = p.kind == "sweep" and sweep or nil
    for i = 1, num do
        local info = C_FriendList.GetWhoInfo(i)
        local name = info and info.fullName
        if type(name) == "string" and not TC.IsSecret(name) and not TC.IsSecret(info.fullGuildName) then
            local before = TC.NameKey(name)
            local wasKnown = before and db.players[before] ~= nil
            local key = TC.LearnGuild(name, nil, info.fullGuildName or "", "who")
            if key then
                TC.NoteFaction(key, UnitFactionGroup("player"))   -- /who only shows your own faction
                db.check.settled[key] = time()
                Recheck()[key] = nil
                if not wasKnown then new = new + 1 end
                if TC.GuildMuted(info.fullGuildName or "") then
                    muted = muted + 1
                    resultGuilds[info.fullGuildName] = true
                end
                if p.kind == "player" and key == p.key then found = info end
                if s and not s.foundKeys[key] then
                    s.foundKeys[key] = true
                    s.added[p.spec.word] = (s.added[p.spec.word] or 0) + 1
                end
            end
            local race, class, area = TC.Str(info.raceStr), TC.Str(info.classStr), TC.Str(info.area)
            if race then seenRaces[race] = true end
            if class then
                seen.classes[class] = true
                if race then
                    combos[class] = combos[class] or {}
                    combos[class][race] = true
                end
            end
            if area and not find(area, '"', 1, true) then zones[area] = (zones[area] or 0) + 1 end
            names[#names + 1] = BaseName(name)
        end
    end
    TC.Count("whoLearned", num)
    TC.Count("whoNew", new)
    TC.Count("whoMutedFound", muted)
    local note = ""
    if p.kind == "player" then
        tonight.checked = tonight.checked + 1
        local front = db.check.front
        for i = #front, 1, -1 do
            if front[i].key == p.key then table.remove(front, i) end
        end
        Recheck()[p.key] = nil
        if found then
            db.check.offline[p.key] = nil
            if TC.GuildMuted(found.fullGuildName or "") then tonight.muted = tonight.muted + 1 note = " (muted)"
            else tonight.cleared = tonight.cleared + 1 note = " (cleared)" end
        else
            local off = db.check.offline[p.key] or { misses = 0 }
            off.misses = (off.misses or 0) + 1
            off.retry = time() + Settings().checkRetryMinutes * 60
            off.dropped = off.misses >= Settings().checkMisses or nil
            db.check.offline[p.key] = off
            db.check.settled[p.key] = nil
            tonight.offline = tonight.offline + 1
            note = off.dropped and " (not found; dropped)" or " (not found; retry later)"
            if db.check.muteGuildOf[p.key] then
                TC.Print(format("%s isn't online; their guild is muted when the game shows it (asked within 3 days).",
                    p.name))
            end
        end
    elseif s then
        tonight.muted = tonight.muted + muted
        for i, spec in ipairs(s.pending) do
            if spec == p.spec then table.remove(s.pending, i) break end
        end
        s.done, s.found, s.new, s.muted = s.done + 1, s.found + num, s.new + new, s.muted + muted
        local full = total > num or num >= WHO_CAP
        if p.spec.root == "guild" then s.rootNum[lower(p.spec.word)] = num end
        if p.spec.probe then
            local record = TC.rdb.olympusGuilds[p.spec.word]
            if record then record.probed = time() end
        end
        local added = 0
        for guild in pairs(resultGuilds) do
            s.guildsSeen[lower(guild)] = true
            if AddGuildRoot(s, guild) then added = added + 1 end
        end
        if added > 0 then note = format(" (%d new guild%s to search)", added, added == 1 and "" or "s") end
        local splits = p.spec.root ~= "word" or s.discovery
        -- A word search listed everyone it reaches unless it came back full and isn't split.
        if p.spec.root == "word" and (not full or splits) then s.completeWords[lower(p.spec.word)] = true end
        local children = full and splits and Split(p.spec, zones, names) or nil
        if full and not splits then
            note = note .. " (full: the guild searches cover it)"
        elseif children then
            for i = #children, 1, -1 do table.insert(s.pending, 1, children[i]) end
            note = format(" (full: split into %d%s)", #children,
                children.byZone and " zones" or children.byName and " by letters in the name" or "")
            if children.byZone or children.byName then
                -- Zones and names aren't a sure split: anyone of this class and race may still be missing.
                s.leaves[#s.leaves + 1] = { t = time(), class = p.spec.class, race = p.spec.race, full = true }
            end
        else
            -- A search that wasn't split: it covered its players at this moment.
            s.leaves[#s.leaves + 1] = { t = time(), class = p.spec.class, race = p.spec.race, full = full or nil }
            if full then
                s.capped = s.capped + 1
                note = " (still full at the finest split)"
            end
        end
        if not s.pending[1] then FinishSweep() end
    end
    if not p.windowWasShown and WhoWindowShown() then
        TC.Count("whoWindowOpened")
        note = note .. " [the Who window opened]"
    end
    -- Every player check, and sweep searches that split or say something unusual (the log keeps 600 lines).
    if p.kind == "player" or note ~= "" or (s and s.done % 20 == 1) then
        TC.Diag("who", "%s -> %d of %d, %d new, %d in muted guilds, %.1f s%s", p.filter, num, total, new, muted,
            lastAnswer - p.sent, note)
    end
    TC.lastCheck = p
    SetWhoToUi(false)
    TC.Notify("Check")
    TC.Notify("Changed")
end

TC.On("WHO_LIST_UPDATE", function()
    if not C_FriendList.GetNumWhoResults then return end
    if not pending then
        -- Your own /who, or an answer that came too late: its guilds are still worth learning.
        TC.Count("whoUnclaimed")
        local num = C_FriendList.GetNumWhoResults() or 0
        for i = 1, num do
            local info = C_FriendList.GetWhoInfo(i)
            if info and type(info.fullName) == "string" then TC.LearnGuild(info.fullName, nil, info.fullGuildName or "", "who") end
        end
        return
    end
    Answer()
end)

-- The server's "you must wait before using /who again" notice. It may come as a system message or
-- be written straight into the chat windows, so both are watched, only in the seconds after a search.
local function IsWaitNotice(msg)
    -- Player and channel lines never are, and nor are TolerableChat's own lines.
    if find(msg, "|H", 1, true) or find(msg, "TolerableChat", 1, true) then return false end
    local m = lower(msg)
    return find(m, "/who", 1, true) and (find(m, "wait", 1, true) or find(m, "again", 1, true)) and true or false
end

-- System lines that are never the server's /who notice, so they aren't logged during a search: anything
-- with a link (logins and logouts, loot, achievements) and the game's own group, guild and AFK lines,
-- matched through its own strings, so in any language.
local ROUTINE = { "ERR_FRIEND_ONLINE_SS", "ERR_FRIEND_OFFLINE_S", "ERR_JOINED_GROUP_S", "ERR_LEFT_GROUP_S",
    "ERR_LEFT_GROUP_YOU", "ERR_RAID_MEMBER_ADDED_S", "ERR_RAID_MEMBER_REMOVED_S", "ERR_GROUP_DISBANDED",
    "ERR_NEW_LEADER_S", "ERR_NEW_LEADER_YOU", "ERR_INVITE_PLAYER_S", "ERR_DECLINE_GROUP_S", "ERR_GUILD_JOIN_S",
    "ERR_GUILD_LEAVE_S", "MARKED_AFK", "MARKED_AFK_MESSAGE", "CLEARED_AFK", "MARKED_DND", "CLEARED_DND" }
local routine

local function Routine(msg)
    if find(msg, "|H", 1, true) then return true end
    if not routine then
        routine = {}
        for _, name in ipairs(ROUTINE) do
            local text = _G[name]
            if type(text) == "string" and text ~= "" then
                text = gsub(text, "%%%d*%$?[sd]", "\1")                        -- %s, %d, %1$s: any text
                text = gsub(text, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
                routine[#routine + 1] = "^" .. (gsub(text, "\1", ".+")) .. "$"
            end
        end
    end
    for _, pattern in ipairs(routine) do
        if find(msg, pattern) then return true end
    end
    return false
end

-- /who output that still reaches chat during one of our searches is hidden; anything else the server
-- says then, apart from routine lines, is logged.
local lastSystem
local function QuietWho(_, _, msg)
    if GetTime() > quietUntil or type(msg) ~= "string" or TC.IsSecret(msg) then return false end
    if pending and IsWaitNotice(msg) then
        Throttled(pending, "wait")
        return true
    end
    if (find(msg, "|Hplayer:", 1, true) and find(msg, LEVEL or "Level", 1, true)) or match(msg, "^%d+ players? total") then
        TC.Count("whoChatHidden")
        return true
    end
    if msg ~= lastSystem and not Routine(msg) then
        lastSystem = msg
        TC.Diag("who", "system message during a search: %s", msg)
    end
    return false
end

local function OnChatLine(_, msg)
    if not pending or GetTime() > quietUntil or type(msg) ~= "string" or TC.IsSecret(msg) then return end
    if IsWaitNotice(msg) then Throttled(pending, "wait") end
end

TC.On("ADDON_LOADED", function(name)
    if name ~= TC.name then return end
    local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    add("CHAT_MSG_SYSTEM", QuietWho)
end)

TC.On("PLAYER_LOGIN", function()
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local f = _G["ChatFrame" .. i]
        if f and f.AddMessage then hooksecurefunc(f, "AddMessage", OnChatLine) end
    end
end)

---------------------------------------------------------------------------------------------------
-- Status shared by the Check tab and the small window

function TC.CheckCounts()
    local counts, q = {}, TC.CheckQueue()
    for _, item in ipairs(q) do counts[item.reason] = (counts[item.reason] or 0) + 1 end
    return counts, q
end

-- The players who get a search of their own, in order.
function TC.OwnSearchQueue(q)
    local out = {}
    for _, item in ipairs(q or TC.CheckQueue()) do
        if OWN_SEARCH[item.reason] or not TC.db.guildWords[1] then out[#out + 1] = item end
    end
    return out
end

local function SweepText()
    if sweep then
        return format("Sweep %d%s: %d searches done, %d waiting; %d players found, %d new, %d in muted guilds.",
            sweep.number, sweep.discovery and " (discovery)" or "", sweep.done, #sweep.pending, sweep.found, sweep.new,
            sweep.muted)
    elseif lastSweep then
        local clearing = lastSweep.discovery and format("cleared %d others seen online%s", lastSweep.cleared or 0,
            (lastSweep.uncertain or 0) > 0 and format(", %d not sure", lastSweep.uncertain) or "")
            or "cleared nobody (not a discovery sweep)"
        return format("Last sweep (%s): %d searches, %d found in muted guilds (%d new); %s.",
            date("%H:%M", lastSweep.finished), lastSweep.done, lastSweep.muted, lastSweep.new, clearing)
    end
end

function TC.WhoStats()
    return { cooldown = cooldown, lastAnswer = lastAnswer, sweep = SweepText() }
end

function TC.CheckStatus()
    local counts, q = TC.CheckCounts()
    local lines = {}
    local wait = TC.CheckCooldown()
    if pending then
        lines[1] = "Waiting for the answer to " .. pending.filter
    elseif wait > 0 then
        lines[1] = format("Ready in %d s", math.ceil(wait))
    else
        lines[1] = "|cff60ff60Ready|r"
    end
    local action = NextAction(q)
    if action.kind == "player" then
        lines[2] = format("Next: check %s (%s)", action.item.name, TC.CHECK_REASONS[action.item.reason])
    elseif action.kind == "sweep" then
        lines[2] = "Next: sweep search " .. SweepFilter(action.spec)
    elseif action.kind == "idle" then
        lines[2] = "Next: nothing to do"
    else
        lines[2] = "Next: start a guild sweep (" .. #TC.db.guildWords .. " guild words)"
    end
    lines[3] = SweepText() or "No sweep yet."
    local own, bySweep = {}, {}
    for i, reason in ipairs(TC.CHECK_REASONS) do
        if counts[i] then
            local list = (OWN_SEARCH[i] or not TC.db.guildWords[1]) and own or bySweep
            list[#list + 1] = format("%d %s", counts[i], reason)
        end
    end
    lines[4] = "Own searches waiting: " .. (own[1] and table.concat(own, ", ") or "none")
    lines[5] = "Waiting for the sweep to settle them: " .. (bySweep[1] and table.concat(bySweep, ", ") or "nobody")
    lines[6] = format("Since login: %d searches, %d sweeps, %d checked one by one, %d muted, %d cleared, %d not found; "
        .. "%d s between searches", tonight.searches, tonight.sweeps, tonight.checked, tonight.muted, tonight.cleared,
        tonight.offline, cooldown)
    return lines
end

---------------------------------------------------------------------------------------------------
-- Any key (setting keyWho): /who needs a key press or a click, and any key press counts. A small
-- invisible frame sees each key press first and passes it on to the game unchanged; when the next
-- search is due (and you aren't in combat) that key press runs it, so playing normally keeps the
-- sweep going. The Next /who button and key binding still work. If the game ever blocks an action
-- because of TolerableChat, this switches itself off (Diag.lua).

local keyFrame

local function InCombat()
    return InCombatLockdown and InCombatLockdown() or false
end

local function KeyWhoDue()
    if pending or GetTime() < readyAt or InCombat() then return false end
    return NextAction().kind ~= "idle"
end

function TC.SetupKeyWho()
    if keyFrame or not TC.db.settings.keyWho or InCombat() then return end
    local f = CreateFrame("Frame", "TolerableChatKeyWho", UIParent)
    f:SetSize(1, 1)
    f:SetPoint("TOPLEFT")
    f:SetPropagateKeyboardInput(true)   -- every key still reaches the game
    f:EnableKeyboard(true)
    f:SetScript("OnKeyDown", function(_, key)
        if not TC.db.settings.keyWho or key == "ESCAPE" then return end
        if KeyWhoDue() then
            TC.Count("whoByKey")
            TC.CheckNext()
        end
    end)
    keyFrame = f
end

function TC.SetKeyWho(on)
    TC.db.settings.keyWho = on and true or false
    if keyFrame then
        if not InCombat() then keyFrame:EnableKeyboard(TC.db.settings.keyWho) end
    elseif on then
        TC.SetupKeyWho()
    end
    TC.Notify("Settings")
end

TC.On("PLAYER_LOGIN", function() C_Timer.After(1, TC.SetupKeyWho) end)
TC.On("PLAYER_REGEN_ENABLED", function()
    if not keyFrame then TC.SetupKeyWho() elseif not InCombat() then keyFrame:EnableKeyboard(TC.db.settings.keyWho) end
end)

BINDING_NAME_TOLERABLECHAT_CHECK = "Next /who (check or sweep)"

function TolerableChat_CheckNext()
    TC.CheckNext()
end
