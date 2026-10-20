-- OlympusNet watcher (spec 12). Listens on the Olympus addon's hidden channels for guild names;
-- TolerableChat never sends anything there.
--
-- Only guild names are read (1.0.1, the user's call). The traffic is written by other players' addons,
-- so nothing heard there mutes anyone, and no player named or heard there gets a /who of their own:
-- the guild sweep finds the real members. Olympus guild names go into the Olympus guild index as "not
-- seen in game yet" (at most TC.HEARD_MAX), with a census's member count and faction; guilds without a
-- muted word go on the OlympusNet guild list for you to decide about. Wall-of-shame lists are ignored.
--
-- The guild is read from its own field of each message kind (L1 4th, W1, R1 and R2 1st, M1 2nd, D1
-- 5th), never from free text such as chat or a map pin's note. /tc net raw prints what arrives, and
-- /tc net capture saves it to TolerableChatDB.diag.netCapture; the latest few of each kind are always
-- kept in TolerableChatDB.diag.netSamples.

local _, TC = ...
local find, sub, match, gmatch, gsub, format, lower = string.find, string.sub, string.match, string.gmatch,
    string.gsub, string.format, TC.Lower
local IsSecret = TC.IsSecret

-- Message kinds. Known: what they carry is understood. Seen: in real traffic on 2026-10-16, meaning
-- not worked out ("H3~Horde~0~0", "HQ~0~0", "T7~1", "W4~1", "Q1~", "IL~L1~3ka.01841e01~k~tn0xzu"). Any
-- other kind is new to TolerableChat: counted by name (net.unknownKinds) for the diagnostics.
local KNOWN_KINDS = { L1 = "location", M1 = "chat", D1 = "map pin", R1 = "census", R2 = "census", W1 = "professions" }
local SEEN_KINDS = { H3 = true, HQ = true, T7 = true, W4 = true, Q1 = true, IL = true }
local CHUNK_PER_SENDER, CHUNK_TOTAL, CHUNK_PARTS, CHUNK_AGE = 4, 400, 30, 60
local SAMPLES_PER_KIND, CAPTURE_MAX, SAMPLE_LENGTH = 10, 1000, 255
local QUIET_CHECK = 300   -- joined this long with no traffic: say so in the diagnostics log

local net = { joined = nil, counts = {}, unknown = 0, unknownKinds = {}, raw = false, chunks = {}, openChunks = 0,
              rosterSeen = {},
              members = 0, unknownSpeakers = {}, total = 0 }
TC.net = net

local function S() return TC.db.settings end

-- This character, realm included: "here" listens on one character only.
function TC.CharacterId()
    local realm = GetNormalizedRealmName and GetNormalizedRealmName() or ""
    return (TC.PlayerKey() or "?") .. "@" .. lower(realm or "")
end

function TC.ListenHere()
    local s = S()
    return s.listenMode == "all" or (s.listenMode == "here" and s.listenChar == TC.CharacterId())
end

function TC.ListenText()
    local s = S()
    if s.listenMode == "all" then return "on, all characters" end
    if s.listenMode == "here" then
        return TC.ListenHere() and "on, this character only" or ("off here (on for " .. tostring(s.listenCharName or s.listenChar) .. " only)")
    end
    return "off"
end

local function ChannelName()
    local faction = UnitFactionGroup("player")
    return faction == "Alliance" and S().netChannelAlliance or S().netChannelHorde
end
TC.NetChannelName = ChannelName

-- The other faction's channel. Olympus gives each faction a channel of its own name, which suggests
-- custom channels aren't split by faction, so TolerableChat listens on both: the other faction's
-- members get muted too. If the game keeps factions apart, that channel just stays quiet.
local function OtherChannelName()
    local faction = UnitFactionGroup("player")
    return faction == "Alliance" and S().netChannelHorde or S().netChannelAlliance
end

local function OurChannel(name)
    if type(name) ~= "string" or IsSecret(name) then return false end
    local low = lower(name)
    return (net.joined and low == lower(net.joined)) or (net.joinedOther and low == lower(net.joinedOther)) or false
end
TC.IsNetChannel = OurChannel

---------------------------------------------------------------------------------------------------
-- Forgetting

-- Forgets everything learned from OlympusNet on this realm: the OlympusNet guild list, the Olympus
-- guilds never seen in game, and the census member counts. Players the game itself showed in a muted
-- guild stay muted. Returns the numbers forgotten.
function TC.ForgetNetData()
    local r, n = TC.rdb, { guilds = 0, netGuilds = 0 }
    for _ in pairs(r.netGuilds) do n.netGuilds = n.netGuilds + 1 end
    r.netGuilds = {}
    for guild, record in pairs(r.olympusGuilds) do
        if not record.confirmed then
            r.olympusGuilds[guild] = nil
            n.guilds = n.guilds + 1
        else
            record.total, record.reported, record.logged, record.net = nil, nil, nil, nil
            if TC.NET_SOURCES[record.source] then record.source = "seen in game" end
        end
    end
    TC.Diag("net", "forgot OlympusNet data: %d Olympus guilds not seen in game, %d other OlympusNet guilds",
        n.guilds, n.netGuilds)
    TC.Notify("Watch")
    TC.Notify("Check")
    TC.Notify("NetGuilds")
    TC.Notify("Changed")
    return n
end

---------------------------------------------------------------------------------------------------
-- Parsing

local function Escape(c)
    return (gsub(c, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- kind and fields of a message: "L1" plus its fields, or "C" plus { id, i, n, data } for a chunk.
local function Parse(text)
    local id, i, n, data = match(text, "^C(%w+):(%d+):(%d+):?(.*)$")
    if id then return "C", { id = id, i = tonumber(i), n = tonumber(n), data = data } end
    local kind, rest = match(text, "^(%u[%u%d])(.*)$")
    if not kind then return nil end
    local fields = {}
    local sep = sub(rest, 1, 1)
    if sep ~= "" and not find(sep, "%w") then
        for field in gmatch(sub(rest, 2) .. sep, "(.-)" .. Escape(sep)) do fields[#fields + 1] = field end
    elseif rest ~= "" then
        fields[1] = rest
    end
    return kind, fields
end
TC.NetParse = Parse

-- Where each kind carries the sender's guild (L1 "L1~1420~13~4~OLYMPUS DUSTMONKEYS", W1 and the census
-- reports first, M1 and D1 as the old Mute's watcher had them). Other fields are never read as a guild:
-- chat text or a map pin's note saying "olympus" isn't anyone's guild.
local GUILD_FIELD = { L1 = 4, W1 = 1, R1 = 1, R2 = 1, M1 = 2, D1 = 5 }

local function GuildField(kind, fields)
    local i = GUILD_FIELD[kind or ""]
    local guild = i and fields[i]
    if type(guild) ~= "string" then return nil end
    guild = gsub(gsub(guild, "^[ \t\n\r\f\v]+", ""), "[ \t\n\r\f\v]+$", "")
    if guild == "" or #guild > 40 or find(guild, "[=:,|]") then return nil end
    return guild
end
TC.NetGuildField = GuildField

-- The guild a sender's own traffic names: a muted one goes in the index (not seen in game yet), another
-- on the OlympusNet guild list. The sender is only counted there, never checked or muted.
local function FromSender(kind, fields, sender, faction)
    local guild = GuildField(kind, fields)
    if not guild then return end
    if TC.GuildMuted(guild) then
        TC.NoteOlympusGuild(guild, "OlympusNet", nil, faction)
    else
        TC.NoteNetGuild(guild, TC.NameKey(sender), nil, faction)
    end
    TC.Notify("Watch")
end

-- A census report: the guild, its member count and faction ("H" or "A"). The leader, officers and top
-- players it names aren't used (1.0.0, the user's call): the sender's addon writes them, so they could
-- be anyone, and the guild sweep finds the real members. A guild without a muted word goes on the
-- OlympusNet guild list instead.
local function Census(fields, sender, faction)
    local guild = GuildField("R2", fields)
    if not guild then return end
    local total
    local n = fields[2] and match(fields[2], "^%d+$") and tonumber(fields[2])   -- not tonumber alone: "1e5", "0x1f"
    if n and n > 0 then total = n end
    for i = #fields, 3, -1 do
        if fields[i] == "H" or fields[i] == "A" then faction = TC.FactionName(fields[i]) break end
    end
    if not TC.GuildMuted(guild) then
        TC.NoteNetGuild(guild, nil, total, faction)
        return
    end
    TC.NoteOlympusGuild(guild, "census", total, faction)
end

-- Counts a message by kind; a kind TolerableChat doesn't know is counted by name.
local function CountKind(kind)
    if kind and (KNOWN_KINDS[kind] or SEEN_KINDS[kind]) then
        net.counts[kind] = (net.counts[kind] or 0) + 1
    else
        net.unknown = net.unknown + 1
        net.unknownKinds[kind or "?"] = (net.unknownKinds[kind or "?"] or 0) + 1
    end
end

-- A reassembled chunked payload: census reports are used, everything else (wall-of-shame lists
-- among them) only counted.
local Sample

local function Payload(text, sender, faction)
    local kind, fields = Parse(text)
    Sample("C>" .. (kind or "?"), sender, text)
    -- The sender's own client sent this payload too.
    if kind and kind ~= "C" then FromSender(kind, fields, sender, faction) end
    if kind == "R1" or kind == "R2" then
        net.counts.census = (net.counts.census or 0) + 1
        Census(fields, sender, faction)
    else
        CountKind(kind)
    end
end

local function SweepChunks(now)
    for sender, byId in pairs(net.chunks) do
        for id, c in pairs(byId) do
            if now - c.t > CHUNK_AGE then
                byId[id] = nil
                net.openChunks = net.openChunks - 1
            end
        end
        if not next(byId) then net.chunks[sender] = nil end
    end
end

local function Chunk(sender, c, faction)
    if not c.i or not c.n or c.n < 1 or c.n > CHUNK_PARTS or c.i < 1 or c.i > c.n then
        return TC.Count("netChunkDropped")
    end
    local now = GetTime()
    SweepChunks(now)
    local byId = net.chunks[sender] or {}
    net.chunks[sender] = byId
    local open = byId[c.id]
    if not open then
        local count = 0
        for _ in pairs(byId) do count = count + 1 end
        if count >= CHUNK_PER_SENDER or net.openChunks >= CHUNK_TOTAL then return TC.Count("netChunkDropped") end
        open = { n = c.n, parts = {}, got = 0, t = now }
        byId[c.id] = open
        net.openChunks = net.openChunks + 1
    end
    if not open.parts[c.i] then
        open.parts[c.i] = c.data or ""
        open.got = open.got + 1
    end
    if open.got >= open.n then
        byId[c.id] = nil
        net.openChunks = net.openChunks - 1
        Payload(table.concat(open.parts, "", 1, open.n), sender, faction)
    end
end

-- The latest few messages of each kind, kept in the saved file (diagnostics, 22.3).
function Sample(kind, sender, text)
    local d = TC.DiagData()
    if not d then return end
    local list = d.netSamples[kind]
    if not list then
        list = {}
        d.netSamples[kind] = list
        TC.Diag("net", "first %s message, from %s: %s", kind, sender, gsub(sub(text, 1, 120), "|", "||"))
    end
    list[#list + 1] = format("%s %s: %s", date("%m-%d %H:%M:%S"), sender, sub(text, 1, SAMPLE_LENGTH))
    while #list > SAMPLES_PER_KIND do table.remove(list, 1) end
end

-- Everything, when /tc net capture or /tc net raw is on.
local function Capture(sender, text)
    local d = TC.DiagData()
    if not d or not d.capturing then return end
    local list = d.netCapture
    list[#list + 1] = { t = time(), sender = sender, text = text }
    while #list > CAPTURE_MAX do table.remove(list, 1) end
end

function TC.SetCapture(on)
    local d = TC.DiagData()
    if d then d.capturing = on and true or nil end
end

-- One OlympusNet message from sender. faction: whose channel it came on, when known.
function TC.NetMessage(text, sender, faction)
    if type(text) ~= "string" or type(sender) ~= "string" or IsSecret(text) or IsSecret(sender) then
        return TC.Count("netUnreadable")
    end
    net.total = net.total + 1
    if net.raw then TC.Print("|cff999999OlympusNet|r " .. sender .. ": " .. gsub(sub(text, 1, 200), "|", "||")) end
    Capture(sender, text)
    local kind, fields = Parse(text)
    Sample(kind == "C" and "C" or kind or "?", sender, text)
    if kind == "C" then
        net.counts.chunk = (net.counts.chunk or 0) + 1
        return Chunk(sender, fields, faction)
    end
    if not kind then
        TC.Count("netUnreadable")
        return
    end
    CountKind(kind)
    FromSender(kind, fields, sender, faction)
    if kind == "R1" or kind == "R2" then Census(fields, sender, faction) end
end

---------------------------------------------------------------------------------------------------
-- The channel: joined 10 s after login, kept out of every chat window, member list read on join and
-- on each roster update. Joining shows you in its member list (the Advanced tab warns about it).

-- Through the game's own chat window settings (GetChatWindowChannels, RemoveChatWindowChannel), never
-- a chat frame's RemoveChannel: that edits the frame's Lua channel list, which the game reads for every
-- channel message, so a value written there from addon code would taint all channel chat. Anything
-- said in the channels is hidden by the chat filter anyway (TC.IsNetChannel, Filter.lua).
local function RemoveFromWindows()
    if not (GetChatWindowChannels and RemoveChatWindowChannel) then return end
    local ids = {}
    for i = 1, NUM_CHAT_WINDOWS or 10 do ids[i] = true end
    for _, frameName in pairs(CHAT_FRAMES or {}) do
        local f = _G[frameName]
        local id = f and f.GetID and f:GetID()
        if type(id) == "number" and id > 0 then ids[id] = true end
    end
    for id in pairs(ids) do
        local list = { GetChatWindowChannels(id) }   -- name, zone channel ID, name, ...
        for i = 1, #list, 2 do
            if OurChannel(list[i]) then pcall(RemoveChatWindowChannel, id, list[i]) end
        end
    end
end

local function DisplayIndex(name)
    if not GetNumDisplayChannels or not GetChannelDisplayInfo then return nil end
    local lname = lower(name)
    for i = 1, GetNumDisplayChannels() or 0 do
        local cname = GetChannelDisplayInfo(i)
        if type(cname) == "string" and not IsSecret(cname) and lower(cname) == lname then return i end
    end
end

-- The member list is only counted (the Advanced tab shows the number); who is in it isn't used.
local rosterAsked, rosterReadAt, rosterQueued = false, -60, false

local function ReadRoster()
    rosterQueued = false
    local name = ChannelName()
    local index = name and DisplayIndex(name)
    if not index or not (C_ChatInfo and C_ChatInfo.GetChannelRosterInfo) then return end
    rosterReadAt = GetTime()
    local count = select(5, GetChannelDisplayInfo(index)) or 0
    if count ~= net.members and (net.members == 0 or math.abs(count - net.members) >= 10) then
        TC.Diag("net", "%s has %d members", name, count)
    end
    net.members = count   -- only counted: who is in the channel isn't used (1.0.1)
    TC.Notify("Watch")
end

-- The server sends a channel's member list only for the channel selected in the Channels window (the
-- game's own window selects one when you click it), so TolerableChat selects it, unless that window is
-- open and you are looking at another channel.
local function AskRoster()
    local name = ChannelName()
    local index = name and DisplayIndex(name)
    if not index or not SetSelectedDisplayChannel then return end
    if ChannelFrame and ChannelFrame.IsShown and ChannelFrame:IsShown() then return end
    local ok, err = pcall(SetSelectedDisplayChannel, index)
    if not rosterAsked then
        TC.Diag("net", "asked for the %s member list (channel %d)%s", name, index, ok and "" or (": " .. tostring(err)))
    end
    rosterAsked = true
end

-- Channel numbers. The game gives a channel the lowest free number and keeps each character's
-- numbers between sessions, so where earlier channels left gaps (General saved at 3), the Olympus
-- channels would take 1 and 2. After joining, each of them is moved past the channel after it, one
-- swap at a time, until both are last: every other channel keeps its order and moves up into the
-- freed numbers. C_ChatInfo.SwapChatChannelsByChannelIndex is what the Channels window's
-- drag-and-drop uses. Chat windows follow channels by name, so no window changes what it shows.
local function ChannelSlots()
    local list, out = { GetChannelList() }, {}
    for i = 1, #list, 3 do
        local num, name = list[i], list[i + 1]
        if type(num) == "number" and type(name) == "string" and not IsSecret(name) then
            out[#out + 1] = { num = num, name = name }
        end
    end
    table.sort(out, function(a, b) return a.num < b.num end)
    return out
end

-- An Olympus channel with someone else's channel right after it: the pair to swap, or nil.
local function NextSwap(slots)
    for i = 1, #slots - 1 do
        if OurChannel(slots[i].name) and not OurChannel(slots[i + 1].name) then return slots[i], slots[i + 1] end
    end
end

local function Order(slots)
    local parts = {}
    for _, slot in ipairs(slots) do parts[#parts + 1] = slot.num .. "=" .. slot.name end
    return table.concat(parts, ",")
end

local moving, swaps, lastOrder = false, 0, nil
local function MoveChannelsToEnd()
    moving = false
    if not net.joined or not GetChannelList or not (C_ChatInfo and C_ChatInfo.SwapChatChannelsByChannelIndex) then return end
    if InCombatLockdown and InCombatLockdown() then
        moving = true
        return C_Timer.After(5, MoveChannelsToEnd)
    end
    local slots = ChannelSlots()
    local a, b = NextSwap(slots)
    if not a then
        if swaps > 0 then TC.Diag("net", "moved the OlympusNet channels to the end of the channel list (%d swaps)", swaps) end
        swaps, lastOrder = 0, nil
        return
    end
    local order = Order(slots)
    if order == lastOrder or swaps >= 40 then
        -- The last swap changed nothing (or something keeps moving them back): leave it.
        TC.Diag("net", "couldn't move the OlympusNet channels to the end: %s", order)
        swaps, lastOrder = 0, nil
        return
    end
    lastOrder = order
    if not pcall(C_ChatInfo.SwapChatChannelsByChannelIndex, a.num, b.num) then
        TC.Diag("net", "swapping channels %d and %d failed", a.num, b.num)
        swaps, lastOrder = 0, nil
        return
    end
    swaps = swaps + 1
    moving = true
    C_Timer.After(0.3, MoveChannelsToEnd)
end

function TC.NetMoveChannelsToEnd()
    if moving then return end
    moving = true
    C_Timer.After(0.5, MoveChannelsToEnd)
end

-- Reads at most every 15 s: the member list changes with every login and logout.
local function QueueRoster()
    if rosterQueued then return end
    rosterQueued = true
    C_Timer.After(math.max(0, rosterReadAt + 15 - GetTime()), ReadRoster)
end

function TC.NetRefreshRoster()
    if not net.joined then return end
    AskRoster()
    QueueRoster()
end

function TC.NetJoin()
    if not TC.ListenHere() then
        TC.Diag("net", "not listening on this character (%s)", S().listenMode)
        return
    end
    local name = ChannelName()
    if not name or name == "" then return end
    local registered = true
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, S().netPrefix)
        registered = ok and result ~= false and result ~= 2 and result ~= 3   -- 2: invalid, 3: too many prefixes
    end
    local function Join(channel)
        if JoinTemporaryChannel then JoinTemporaryChannel(channel) elseif JoinChannelByName then JoinChannelByName(channel) end
    end
    Join(name)
    net.joined, net.joinedAt = name, GetTime()
    local other = OtherChannelName()
    if other and other ~= "" and lower(other) ~= lower(name) then
        Join(other)
        net.joinedOther = other
    end
    TC.Diag("net", "joined %s%s, prefix %s%s", name, net.joinedOther and (" and the other faction's " .. net.joinedOther) or "",
        S().netPrefix, registered and "" or " (registering the prefix failed)")
    C_Timer.After(1, RemoveFromWindows)
    C_Timer.After(3, function() AskRoster() ReadRoster() end)
    C_Timer.After(4, TC.NetMoveChannelsToEnd)
    local total = net.total
    C_Timer.After(QUIET_CHECK, function()
        if net.joined == name and net.total == total then
            TC.Diag("net", "no OlympusNet messages in %d min since joining %s (members: %d). Is the channel name "
                .. "or prefix right?", QUIET_CHECK / 60, name, net.members or 0)
        end
    end)
    TC.Notify("Watch")
end

function TC.NetLeave()
    for _, name in ipairs({ net.joined or false, net.joinedOther or false }) do
        if name and LeaveChannelByName then LeaveChannelByName(name) end
    end
    if net.joined then TC.Diag("net", "left %s%s", net.joined, net.joinedOther and (" and " .. net.joinedOther) or "") end
    net.joined, net.joinedOther = nil, nil
    TC.Notify("Watch")
end

-- mode: "all", "here" (this character only) or "off"; true and false mean "all" and "off".
function TC.SetListen(mode)
    if mode == true then mode = "all" elseif mode == false or mode == nil then mode = "off" end
    local s = S()
    s.listenMode = mode
    if mode == "here" then
        s.listenChar = TC.CharacterId()
        s.listenCharName = format("%s-%s", UnitName("player") or "?", GetRealmName and GetRealmName() or "?")
    end
    if TC.ListenHere() then
        if not net.joined then TC.NetJoin() end
    else
        TC.NetLeave()
    end
end

TC.On("PLAYER_LOGIN", function()
    C_Timer.After(10, TC.NetJoin)
end)

-- The faction whose channel a message came on: the channel's name is the 5th or the 8th argument.
local function MessageFaction(...)
    local mine = UnitFactionGroup("player")
    local other = mine == "Horde" and "Alliance" or mine == "Alliance" and "Horde" or nil
    for _, i in ipairs({ 5, 8 }) do
        local name = select(i, ...)
        if type(name) == "string" and not IsSecret(name) then
            local low = lower((gsub(name, "^%d+%. ", "")))
            if net.joined and low == lower(net.joined) then return mine end
            if net.joinedOther and low == lower(net.joinedOther) then return other end
        end
    end
end

TC.On("CHAT_MSG_ADDON", function(prefix, text, distribution, sender, ...)
    if IsSecret(prefix) or prefix ~= S().netPrefix or not net.joined then return end
    TC.NetMessage(text, sender, MessageFaction(prefix, text, distribution, sender, ...))
end)

TC.On("CHANNEL_ROSTER_UPDATE", function() if net.joined then QueueRoster() end end)
TC.On("CHANNEL_UI_UPDATE", function()
    if not net.joined then return end
    RemoveFromWindows()
    -- A channel joined later (a new custom channel) may land after ours: move ours back to the end.
    if GetChannelList and NextSwap(ChannelSlots()) then TC.NetMoveChannelsToEnd() end
end)

-- Keep the channel's join and leave notices out of chat.
local function QuietNotice(_, _, _, _, _, _, _, _, _, _, chanBase)
    return OurChannel(chanBase)
end
TC.On("ADDON_LOADED", function(name)
    if name ~= TC.name then return end
    local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    add("CHAT_MSG_CHANNEL_NOTICE", QuietNotice)
    add("CHAT_MSG_CHANNEL_NOTICE_USER", QuietNotice)
end)

-- The kinds TolerableChat doesn't know, with how many of each arrived: "Z9 3, X1 1", or nil.
function TC.NetUnknownKinds()
    local list = {}
    for kind, n in pairs(net.unknownKinds) do list[#list + 1] = format("%s %d", kind, n) end
    table.sort(list)
    return list[1] and table.concat(list, ", ") or nil
end

-- Unknown speakers since login: players who talked in a filtered chat type with no known guild.
local function NoteSpeaker(e)
    if e and e.filterable and e.key and not TC.rdb.players[e.key] then net.unknownSpeakers[e.key] = true end
end
TC.Listen("Shown", NoteSpeaker)
TC.Listen("Hidden", NoteSpeaker)

function TC.UnknownSpeakers()
    local n = 0
    for key in pairs(net.unknownSpeakers) do
        if not TC.rdb.players[key] then n = n + 1 end
    end
    return n
end

-- Known members per Olympus guild against the guild's own member count ("MUDHUTTERS 412 / 946"). Known
-- means the game showed them in it; guilds that are exceptions now are left out. faction: most of its
-- known members' faction, or its census's.
function TC.OlympusCoverage()
    local known, factions = {}, {}
    for _, p in pairs(TC.rdb.players) do
        if p.guild and TC.GuildMuted(p.guild) then
            known[p.guild] = (known[p.guild] or 0) + 1
            if p.faction then
                factions[p.guild] = factions[p.guild] or {}
                factions[p.guild][p.faction] = (factions[p.guild][p.faction] or 0) + 1
            end
        end
    end
    local out = {}
    for guild, n in pairs(known) do out[guild] = { guild = guild, known = n, confirmed = true } end
    for guild, r in pairs(TC.rdb.olympusGuilds) do
        if TC.GuildMuted(guild) then
            out[guild] = out[guild] or { guild = guild, known = 0 }
            out[guild].total = r.total
            out[guild].confirmed = out[guild].confirmed or r.confirmed ~= nil
            out[guild].faction = r.faction
        end
    end
    local list = {}
    for guild, v in pairs(out) do
        local f = factions[guild]
        if f then v.faction = (f.Horde or 0) >= (f.Alliance or 0) and "Horde" or "Alliance" end
        list[#list + 1] = v
    end
    table.sort(list, function(a, b)
        if a.known ~= b.known then return a.known > b.known end
        return a.guild < b.guild
    end)
    return list
end
