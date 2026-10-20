-- The decision for every incoming chat message (spec section 4), the sender rule (6.5), the
-- recent-message buffer and hidden-message log (14.1), removing past lines from chat windows,
-- flagging (14.2), the self-test (14.3) and stats.

local _, TC = ...

local find, gsub, lower, sub, match, format = string.find, string.gsub, TC.Lower, string.sub,
    string.match, string.format
local IsSecret = TC.IsSecret

-- Chat events filtered, by chat type (6.4). Guild, officer, party, raid and instance chat are never
-- registered, so they are never filtered. Battle.net whispers come only from Battle.net friends.
local EVENTS = {
    CHAT_MSG_CHANNEL = "channel",
    CHAT_MSG_SAY = "say",
    CHAT_MSG_YELL = "yell",
    CHAT_MSG_EMOTE = "emote",
    CHAT_MSG_TEXT_EMOTE = "emote",
    CHAT_MSG_WHISPER = "whisper",
    CHAT_MSG_AFK = "whisper",
    CHAT_MSG_DND = "whisper",
    CHAT_MSG_COMMUNITIES_CHANNEL = "community",
}
TC.FILTER_EVENTS = EVENTS

local CHANNEL_LABEL = { say = "Say", yell = "Yell", emote = "Emote", whisper = "Whisper", community = "Community" }
local WORLD_CHANNELS = { "general", "trade", "lookingforgroup", "localdefense", "worlddefense" }

local function Now()
    return GetTime()
end
TC.Now = Now

---------------------------------------------------------------------------------------------------
-- Chat types (6.4)

-- Channel display name and scope ("world" or "custom") for a CHAT_MSG_CHANNEL message.
local function ChannelInfo(zoneID, base, name)
    local display = type(base) == "string" and base ~= "" and base or gsub(tostring(name or ""), "^%d+%.%s*", "")
    local low = lower(display)
    if type(zoneID) == "number" and zoneID > 0 then return display, "world", low end
    for _, world in ipairs(WORLD_CHANNELS) do
        if low == world or sub(low, 1, #world + 1) == world .. " " then return display, "world", low end
    end
    return display, "custom", low
end

-- For the Filter tab's list of joined channels.
function TC.IsCustomChannel(name)
    local _, scope = ChannelInfo(0, name)
    return scope == "custom"
end

-- True when this chat type is filtered under the current settings.
local function InScope(kind, scope, channelKey)
    local s = TC.db.settings
    if kind == "channel" then
        if scope == "custom" then return s.scope.custom and not s.customOff[channelKey] end
        return s.scope.world
    end
    if kind == "yell" or kind == "emote" then kind = "say" end   -- one switch for say, yell and emote
    return s.scope[kind] and true or false
end

---------------------------------------------------------------------------------------------------
-- Recent-message buffer: the last 30 minutes of judged messages, up to 500, in memory only.

local buffer, head, tail = {}, 1, 0   -- entries buffer[head..tail], oldest first
local byLine = {}                -- lineID -> entry; also the per-lineID decision cache
local noLine, noLineAt = {}, nil -- messages without a lineID, cached for the current frame only
local checkpoints = {}           -- { time, first lineID seen } every 10 s, for look-back by lineID

local function Prune(now)
    local limit = now - TC.BUFFER_SECONDS
    while head <= tail and (buffer[head].now < limit or tail - head + 1 > TC.BUFFER_MAX) do
        local e = buffer[head]
        buffer[head] = nil
        head = head + 1
        if e.lineID and byLine[e.lineID] == e then byLine[e.lineID] = nil end
    end
    if head > 2 * TC.BUFFER_MAX then
        local moved, n = {}, 0
        for i = head, tail do
            n = n + 1
            moved[n] = buffer[i]
        end
        buffer, head, tail = moved, 1, n
    end
    -- Checkpoints outlive the buffer: a Timeout Duration of up to 120 minutes looks back that far.
    local keep = now - TC.LIMITS.senderMinutes[2] * 60 - 60
    while checkpoints[1] and checkpoints[1][1] < keep do table.remove(checkpoints, 1) end
end

local function Store(e)
    tail = tail + 1
    buffer[tail] = e
    if e.lineID then
        byLine[e.lineID] = e
        local last = checkpoints[#checkpoints]
        if not last or e.now - last[1] >= 10 then checkpoints[#checkpoints + 1] = { e.now, e.lineID } end
    end
    Prune(e.now)
end

-- A lineID from no earlier than the given time (up to 10 s later), or nil.
local function LineIDSince(t)
    for i = 1, #checkpoints do
        if checkpoints[i][1] >= t then return checkpoints[i][2] end
    end
end

-- Newest first. filter(e) picks entries; nil means all.
function TC.RecentEntries(filter, limit)
    local out = {}
    for i = tail, head, -1 do
        local e = buffer[i]
        if not filter or filter(e) then
            out[#out + 1] = e
            if limit and #out >= limit then break end
        end
    end
    return out
end

function TC.HiddenEntries(limit)
    return TC.RecentEntries(function(e) return e.hidden end, limit)
end

-- The Log tab's list: hidden messages that caused an action or arrived while one was in force. Lines
-- removed afterwards by look-back or clean-up on mute are left out; their cause says how many.
function TC.LogEntries(limit)
    return TC.RecentEntries(function(e) return e.hidden and not e.lookBack and not e.cleanup end, limit)
end

function TC.EntryByLine(lineID)
    return byLine[lineID]
end

-- The visible text of an entry ("[Linen Cloth] x20"), worked out when first needed.
function TC.EntryText(e)
    if not e.visible and e.raw then e.visible = TC.StripFormatting(e.raw) end
    return e.visible or ""
end

---------------------------------------------------------------------------------------------------
-- Removing past lines from chat windows, one chat window per frame.

local jobs = {}
local driver = CreateFrame("Frame")
driver:Hide()

local function ChatFrames()
    local frames, seen = {}, {}
    local function Add(f)
        if f and not seen[f] and f.RemoveMessagesByPredicate then
            seen[f] = true
            frames[#frames + 1] = f
        end
    end
    if CHAT_FRAMES then
        for _, name in pairs(CHAT_FRAMES) do Add(_G[name]) end
    end
    for i = 1, NUM_CHAT_WINDOWS or 10 do Add(_G["ChatFrame" .. i]) end
    return frames
end

driver:SetScript("OnUpdate", function(self)
    local job = jobs[1]
    if job then
        local frame = table.remove(job.frames, 1)
        if frame then frame:RemoveMessagesByPredicate(job.predicate) end
        if not job.frames[1] then table.remove(jobs, 1) end
    end
    if not jobs[1] then self:Hide() end
end)

-- Removes past chat lines for which test(event, eventArgs) is true. Only incoming messages of the
-- filtered types are looked at, so your own whispers to someone always stay.
function TC.RemoveLines(test)
    local function Predicate(message, r, g, b, infoID, accessID, typeID, event, eventArgs)
        if type(event) ~= "string" or not EVENTS[event] or type(eventArgs) ~= "table" then return false end
        return test(event, eventArgs) and true or false
    end
    local frames = ChatFrames()
    if not frames[1] then return end
    jobs[#jobs + 1] = { frames = frames, predicate = Predicate }
    driver:Show()
end

function TC.RemoveLineIDs(ids)
    if not next(ids) then return end
    TC.RemoveLines(function(_, args)
        local id = args[11]
        return not IsSecret(id) and ids[id]
    end)
end

---------------------------------------------------------------------------------------------------
-- Removing a sender's earlier lines: look-back (6.5) and clean-up on mute (9)

local function CountHidden(e)
    local stats = TC.db.stats
    stats.hiddenTotal = stats.hiddenTotal + 1
    local today = TC.Today()
    today.hidden = (today.hidden or 0) + 1
    TC.session.hidden = TC.session.hidden + 1
end

-- True when a chat-window line from this event is a filtered chat type under the current settings.
local function LineInScope(event, args)
    local kind = EVENTS[event]
    if kind == "channel" then
        if IsSecret(args[7]) or IsSecret(args[9]) or IsSecret(args[4]) then return false end
        local _, scope, channelKey = ChannelInfo(args[7], args[9], args[4])
        return InScope(kind, scope, channelKey)
    end
    return InScope(kind)
end

-- Removes this sender's earlier lines from every chat window. Buffer entries within `window` seconds
-- (nil: any age) are removed unless keep(e), and get mark(e). Lines older than the buffer go when their
-- lineID is at least `since` (0: all; nil: none) and keepText(text) doesn't keep them. Returns how many
-- buffer entries were removed.
local function RemoveSenderLines(key, now, window, keep, mark, since, keepText)
    local ids, count = {}, 0
    for i = head, tail do
        local e = buffer[i]
        if e.key == key and e.filterable and not e.hidden and (not window or now - e.now <= window) and not keep(e) then
            e.hidden = true
            mark(e)
            if e.lineID then ids[e.lineID] = true end
            CountHidden(e)
            count = count + 1
        end
    end
    TC.RemoveLines(function(event, args)
        local id = args[11]
        if IsSecret(id) then return false end
        if ids[id] then return true end
        if not since or type(id) ~= "number" or id < since or byLine[id] then return false end
        local sender, text = args[2], args[1]
        if IsSecret(sender) or IsSecret(text) or type(text) ~= "string" then return false end
        if TC.NameKey(sender) ~= key or not LineInScope(event, args) then return false end
        return not (keepText and keepText(text))
    end)
    if count > 0 then TC.Notify("Hidden") end
    return count
end
TC.RemoveSenderLines = RemoveSenderLines

---------------------------------------------------------------------------------------------------
-- Sender rule (6.5). Hit times per sender, in memory only: they end at /reload or logout. causes[key]
-- is what started the rule this time ({ what = 'term "trump"', t = time }), for the log.

local hits, causes, said = {}, {}, {}
local MAX_WINDOW = 120 * 60

local function CountHits(key, now)
    local list = hits[key]
    if not list then return 0 end
    local window = TC.db.settings.senderMinutes * 60
    local n, last = 0, nil
    for i = #list, 1, -1 do
        if now - list[i] > window then break end
        n = n + 1
        last = last or list[i]
    end
    return n, last
end

-- Hits and seconds left while the sender rule is on for this sender, or nil.
local function SenderRule(key, now)
    local s = TC.db.settings
    if not key then return nil end
    local n, last = CountHits(key, now)
    if n >= 1 then return n, last + s.senderMinutes * 60 - now end
    return nil
end
TC.SenderRule = SenderRule

function TC.RuleCause(key)
    return causes[key]
end

-- Counts this message and returns how many the sender sent in the last TC.SPAM_SECONDS.
local function CountSaid(key, now)
    local list = said[key]
    if not list then
        list = {}
        said[key] = list
    end
    list[#list + 1] = now
    while list[1] and now - list[1] > TC.SPAM_SECONDS do table.remove(list, 1) end
    return #list
end

-- Drops senders nobody needs to remember any more.
local function Sweep(now)
    for key, list in pairs(said) do
        if not list[1] or now - list[#list] > TC.SPAM_SECONDS then said[key] = nil end
    end
    for key, list in pairs(hits) do
        if not list[1] or now - list[#list] > MAX_WINDOW then
            hits[key], causes[key] = nil, nil
        end
    end
end

-- The shield for a stored entry, worked out when first needed. A trade post sent while posting
-- fast isn't shielded.
local function EntryShield(e)
    if e.shield == nil then
        local prep = e.raw and TC.Prepare(e.raw, false)
        local shield = prep and TC.GameTalk(prep) or false
        if shield and e.fast and TC.IsTradePost(prep) then shield = false end
        e.shield = shield
    end
    return e.shield
end
TC.EntryShield = EntryShield

-- On the hit that starts the sender rule, removes the sender's lines from the previous window that
-- are still in chat windows, except clear game talk. Returns how many it removed.
local function LookBack(key, now, except)
    local window = TC.db.settings.senderMinutes * 60
    return RemoveSenderLines(key, now, window,
        function(e) return e == except or EntryShield(e) end,
        function(e)
            e.step, e.lookBack, e.cause = "sender", true, causes[key]
            e.ruleHits = CountHits(key, now)
        end,
        LineIDSince(now - window),
        function(text) return TC.GameTalk(TC.Prepare(text, false)) ~= nil end)
end

-- Records a sender-rule hit. cause says what it was, for the log. Returns how many earlier lines
-- look-back removed (only on the hit that starts the rule).
local function RecordHit(key, now, except, cause)
    local s = TC.db.settings
    local wasOn = CountHits(key, now) > 0
    local list = hits[key] or {}
    hits[key] = list
    list[#list + 1] = now
    while list[1] and now - list[1] > MAX_WINDOW do table.remove(list, 1) end
    if not wasOn then
        causes[key] = cause
        return LookBack(key, now, except)
    end
    return 0
end
TC.RecordHit = RecordHit

---------------------------------------------------------------------------------------------------
-- The decision (section 4)

local STEP_TEXT = {
    off = "TolerableChat is off", scope = "chat type not filtered", unreadable = "unreadable (secret)",
    own = "your own message", gm = "GM or DEV message", exempt = "exempt sender", muted = "muted player",
    guild = "guild or name mute", term = "term match", sender = "timeout", flagged = "flagged by you",
    game = "clear game talk", shown = "no term", spam = "symbol or script spam", meme = "meme word mute",
}
TC.STEP_TEXT = STEP_TEXT

local function Finish(e, hidden, step)
    e.hidden, e.step = hidden, step
    if hidden then
        CountHidden(e)
        if TC.db.settings.debug then
            TC.Debug(format("hid [%s] %s: %s (%s)", e.channel or "?", e.sender or "?", TC.EntryText(e), TC.Trace(e)))
        end
        TC.Notify("Hidden", e)
    else
        TC.Notify("Shown", e)
    end
    return e
end

-- Steps 1 and 2 are checked secret-first, because nothing can be compared until the arguments are
-- known to be readable; both end in "show", so the result is the same.
local function Decide(e, event, text, sender, chanName, flags, zoneID, chanBase, guid)
    local s = TC.db.settings
    local kind = EVENTS[event]
    if IsSecret(text) or IsSecret(sender) or IsSecret(flags) or IsSecret(guid)
        or IsSecret(zoneID) or IsSecret(chanBase) or IsSecret(chanName) then
        return Finish(e, false, "unreadable")
    end
    local channel, scope, channelKey
    if kind == "channel" then
        channel, scope, channelKey = ChannelInfo(zoneID, chanBase, chanName)
    else
        channel = CHANNEL_LABEL[kind]
    end
    e.channel = channel
    if type(text) ~= "string" then return Finish(e, false, "unreadable") end
    e.raw = text
    e.key, e.sender = TC.NameKey(sender)
    e.guid = TC.IsPlayerGUID(guid) and guid or nil
    if not e.key then return Finish(e, false, "unreadable") end

    if not s.enabled then return Finish(e, false, "off") end
    -- The "Where" switches choose where terms and timeouts apply; muted players stay hidden in every
    -- chat type TolerableChat looks at, whispers included.
    local inScope = InScope(kind, scope, channelKey)
    if e.key == TC.PlayerKey() or (e.guid and e.guid == UnitGUID("player")) then return Finish(e, false, "own") end
    if flags == "GM" or flags == "DEV" then return Finish(e, false, "gm") end

    local exempt = TC.ExemptReason(e.key, e.guid)
    if exempt then
        e.exempt = exempt
        return Finish(e, false, "exempt")
    end
    if TC.MuteReason then   -- phase 2 and 3: explicit, guild and name-keyword mutes
        local step, reason = TC.MuteReason(e.key, e.guid)
        if step then
            e.muteReason = reason
            return Finish(e, true, step)
        end
    end
    if not inScope then return Finish(e, false, "scope") end

    e.filterable = true
    e.fast = CountSaid(e.key, e.now) >= TC.SPAM_MESSAGES
    local prep = TC.Prepare(text, true)
    e.visible = prep.visible
    local term = TC.MatchPrepared(prep)
    if term then
        e.term = term
        e.blanked = prep.blanked
        TC.CountTermHit(term)
        if term.offensive and TC.AutoMute then
            -- Offensive (rule 6): mute the sender. Clean-up removes their earlier lines.
            e.autoMuted = true
            e.removedEarlier = TC.AutoMute(e, term)
            return Finish(e, true, "term")
        end
        -- Hide Only (Dead Horses by default): hidden, and that's all (no timeout).
        if term.noRule then return Finish(e, true, "term") end
        e.removedEarlier = RecordHit(e.key, e.now, e, { what = format('term "%s"', term.text), t = e.t })
        e.ruleHits = CountHits(e.key, e.now)
        return Finish(e, true, "term")
    end
    local meme = TC.MemeWordIn(prep.lower)
    if meme then
        e.memeWord = meme   -- muted for a while from the Overview tab; never a sender-rule hit
        return Finish(e, true, "meme")
    end
    if s.symbolSpam and TC.IsSymbolSpam(prep.visible) then return Finish(e, true, "spam") end
    local ruleHits, left = SenderRule(e.key, e.now)
    e.ruleHits = CountHits(e.key, e.now)
    if ruleHits then
        e.ruleLeft, e.cause = left, causes[e.key]
        local shield = TC.GameTalk(prep)
        -- A spamming sender's trade posts aren't shielded, even with links or game words.
        if shield and (ruleHits >= TC.SPAM_HITS or e.fast) and TC.IsTradePost(prep) then
            e.spamming, shield = true, nil
        end
        e.shield = shield or false
        if e.shield then return Finish(e, false, "game") end
        return Finish(e, true, "sender")
    end
    return Finish(e, false, "shown")
end

-- Judges one message once, however many chat windows show it. Returns its buffer entry.
local function Judge(event, text, sender, chanName, flags, zoneID, chanBase, lineID, guid)
    local cacheKey
    if not IsSecret(lineID) and type(lineID) == "number" and lineID > 0 then   -- secret first: comparing one errors
        local e = byLine[lineID]
        if e then return e end
    else
        lineID = nil
        local now = Now()
        if noLineAt ~= now then noLine, noLineAt = {}, now end
        if not IsSecret(text) and not IsSecret(sender) then
            cacheKey = event .. "\0" .. tostring(sender) .. "\0" .. tostring(text)
            if noLine[cacheKey] then return noLine[cacheKey] end
        end
    end
    local started = debugprofilestop and debugprofilestop()
    local e = { now = Now(), t = time(), event = event, lineID = lineID }
    Decide(e, event, text, sender, chanName, flags, zoneID, chanBase, guid)
    if cacheKey then noLine[cacheKey] = e end
    if e.raw then Store(e) end   -- secret values are never kept
    if started then
        local ms = debugprofilestop() - started
        TC.session.judgeTime = TC.session.judgeTime + ms
        if TC.Max then TC.Max("judge", ms) end
    end
    TC.session.judged = TC.session.judged + 1
    if TC.session.judged % 256 == 0 then Sweep(e.now) end
    return e
end
TC.Judge = Judge

-- An error while judging shows the message rather than losing it, and is logged (Diag.lua).
local function ChatFilter(chatFrame, event, text, sender, language, chanName, target, flags, zoneID, chanIndex,
                          chanBase, languageID, lineID, guid)
    -- The OlympusNet channels (Net.lua) never show, whatever a chat window's channel list says.
    if event == "CHAT_MSG_CHANNEL" and TC.IsNetChannel and TC.IsNetChannel(chanBase) then return true end
    local ok, e = TC.XCall(Judge, TC.OnError, event, text, sender, chanName, flags, zoneID, chanBase, lineID, guid)
    if not ok then
        TC.Count("filterErrors")
        TC.DiagError("chat filter (" .. tostring(event) .. ")", e)
        return false
    end
    return e.hidden and true or false
end
TC.ChatFilter = ChatFilter

TC.On("ADDON_LOADED", function(name)
    if name ~= TC.name then return end
    local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    for event in pairs(EVENTS) do add(event, ChatFilter) end
end)

---------------------------------------------------------------------------------------------------
-- Decision trace

local function Minutes(seconds)
    return math.max(0, math.ceil((seconds or 0) / 60))
end

function TC.Trace(e)
    local parts = { (e.hidden and "hidden" or "shown") .. ": " .. (STEP_TEXT[e.step] or tostring(e.step)) }
    if e.lookBack then parts[1] = parts[1] .. " (look-back)" end
    if e.cleanup then parts[1] = parts[1] .. " (cleared on mute)" end
    if e.exempt then parts[#parts + 1] = "exempt (" .. e.exempt .. ")" end
    if e.muteReason then parts[#parts + 1] = e.muteReason end
    if e.memeWord then parts[#parts + 1] = format('meme word "%s"', e.memeWord) end
    if e.term then
        parts[#parts + 1] = format('term "%s" (%s, %s)%s', e.term.text, e.term.cat, TC.KIND_LABEL[e.term.kind] or e.term.kind,
            e.term.via and format(', spelled "%s"', e.term.form) or "")
    end
    if e.autoMuted then parts[#parts + 1] = "Mute Forever: sender muted" end
    if (e.removedEarlier or 0) > 0 then
        parts[#parts + 1] = format("removed %d earlier line%s", e.removedEarlier, e.removedEarlier == 1 and "" or "s")
    end
    if e.filterable and not e.autoMuted and not e.cleanup then
        local n = e.ruleHits or 0
        if n > 0 then
            parts[#parts + 1] = format("timeout: %d hit%s", n, n == 1 and "" or "s")
                .. (e.ruleLeft and format(", %d min left", Minutes(e.ruleLeft)) or "")
                .. (e.cause and format(", started by %s at %s", e.cause.what, date("%H:%M", e.cause.t)) or "")
        else
            parts[#parts + 1] = "timeout: no hits"
        end
        if e.spamming then parts[#parts + 1] = "spamming: WTS/WTB not shielded" end
        if e.shield then parts[#parts + 1] = "game talk: " .. e.shield end
    end
    return table.concat(parts, "; ")
end

---------------------------------------------------------------------------------------------------
-- Log actions (14.1)

-- Prints a hidden message once, marked.
function TC.ShowHidden(e)
    local frame = DEFAULT_CHAT_FRAME or ChatFrame1
    if not frame or not e.raw then return end
    frame:AddMessage(format("|cff999999[hidden by TolerableChat]|r [%s] [%s]: %s", e.channel or "?", e.sender or "?", e.raw))
end

-- Opens Blizzard's report window for that message.
function TC.ReportEntry(e)
    if not (e.lineID and e.guid and ReportInfo and ReportFrame and PlayerLocation and Enum and Enum.ReportType) then
        TC.Print("This message can't be reported from here. Right-click the name in chat and choose Report.")
        return
    end
    local info = ReportInfo:CreateReportInfoFromType(Enum.ReportType.Chat)
    info:SetReportTarget(e.guid)
    ReportFrame:InitiateReport(info, e.sender, PlayerLocation:CreateFromChatLineID(e.lineID))
end

---------------------------------------------------------------------------------------------------
-- Flagging (14.2)

local function FlagRecord(e, list)
    return { t = e.t, channel = e.channel, sender = e.sender, text = TC.EntryText(e),
             trace = TC.Trace(e), list = list }
end

local function CapFlagged()
    local f = TC.db.flagged
    while #f.missed + #f.wrong > TC.FLAG_MAX do
        local m, w = f.missed[1], f.wrong[1]
        if m and (not w or (m.t or 0) <= (w.t or 0)) then table.remove(f.missed, 1) else table.remove(f.wrong, 1) end
    end
end

local function CountFlag()
    local stats = TC.db.stats
    stats.flaggedTotal = stats.flaggedTotal + 1
    local today = TC.Today()
    today.flagged = (today.flagged or 0) + 1
end

-- A message that should have been hidden: saved to the missed list, hidden, and (setting on)
-- counted as a sender-rule hit.
function TC.FlagMissed(e)
    table.insert(TC.db.flagged.missed, FlagRecord(e, "missed"))
    CapFlagged()
    CountFlag()
    if not e.hidden then
        e.hidden, e.step = true, "flagged"
        CountHidden(e)
        if e.lineID then TC.RemoveLineIDs({ [e.lineID] = true }) end
    end
    if e.key then
        e.removedEarlier = RecordHit(e.key, Now(), e, { what = "your flag", t = time() })
    end
    TC.Notify("Flagged")
    TC.Notify("Hidden")
end

-- A hidden message that should have been shown, from the Log tab.
function TC.FlagWrong(e)
    e.flaggedWrong = true
    TC.FlagWrongRecord(FlagRecord(e, "wrong"))
end

-- Saves a ready-made record ({ t, channel, sender, text, trace }) to the wrongly hidden list.
function TC.FlagWrongRecord(r)
    r.list = "wrong"
    table.insert(TC.db.flagged.wrong, r)
    CapFlagged()
    CountFlag()
    TC.Notify("Flagged")
end

-- The messages a right-click on this player could mean: the line itself when the menu gives its
-- lineID, otherwise their shown messages from the last 2 minutes, newest first.
function TC.FlagCandidates(key, lineID)
    if lineID and byLine[lineID] then return { byLine[lineID] } end
    local now = Now()
    local list = TC.RecentEntries(function(e) return e.key == key and e.raw and not e.hidden and now - e.now <= 120 end)
    if not list[1] then
        list = TC.RecentEntries(function(e) return e.key == key and e.raw and not e.hidden end, 1)
    end
    return list
end

local function FormatLogLine(r)
    return format("%s [%s] %s: %s", date("%Y-%m-%d %H:%M:%S", r.t or 0), r.channel or "?", r.sender or "?", r.text or "")
end
TC.FormatLogLine = FormatLogLine

-- Every flagged entry in the ChatArchive log format, with its list and trace.
function TC.ExportFlagged()
    local out = { "# TolerableChat flagged messages. {list; decision trace} then the line in ChatArchive log format.",
                  "# missed = should have been hidden; wrongly hidden = should have been shown." }
    for _, name in ipairs({ "missed", "wrong" }) do
        for _, r in ipairs(TC.db.flagged[name]) do
            out[#out + 1] = format("{%s; %s} %s", name == "missed" and "missed" or "wrongly hidden", r.trace or "", FormatLogLine(r))
        end
    end
    return table.concat(out, "\n")
end

---------------------------------------------------------------------------------------------------
-- Self-test (14.3)

function TC.SelfTest(text)
    local s = TC.db.settings
    local prep = TC.Prepare(text, true)
    local lines = {}
    if not s.enabled then lines[#lines + 1] = "TolerableChat is switched off, so nothing is hidden right now." end
    lines[#lines + 1] = format('Matched as: "%s"', prep.base)
    if prep.folded then lines[#lines + 1] = format('Folded: "%s"', prep.folded) end
    if prep.blanked then lines[#lines + 1] = "Game names blanked out: " .. table.concat(prep.blanked, ", ") end
    local term = TC.MatchPrepared(prep)
    if term and term.via then
        lines[#lines + 1] = format('Spelled "%s": a %s form of "%s".', term.form, term.via, term.text)
    end
    if term and term.offensive then
        lines[#lines + 1] = format('|cffff6060Hidden|r: term "%s" (%s, %s). Mute Forever: the sender would be muted, '
            .. "so all their chat is hidden, game talk included.", term.text, term.cat, TC.KIND_LABEL[term.kind])
    elseif term and term.noRule then
        lines[#lines + 1] = format('|cffff6060Hidden|r: term "%s" (%s, %s). Hide Only: just this message.',
            term.text, term.cat, TC.KIND_LABEL[term.kind])
    elseif term then
        lines[#lines + 1] = format('|cffff6060Hidden|r: term "%s" (%s, %s). Timeout: the sender\'s other messages '
            .. "from %d minutes before to %d minutes after are hidden too, unless they're game talk.",
            term.text, term.cat, TC.KIND_LABEL[term.kind], s.senderMinutes, s.senderMinutes)
    elseif s.symbolSpam and TC.IsSymbolSpam(prep.visible) then
        lines[#lines + 1] = TC.MixedScriptWord(prep.visible)
            and "|cffff6060Hidden|r: symbol or script spam (a word mixes Latin with Cyrillic or Greek look-alike letters)."
            or format("|cffff6060Hidden|r: symbol or script spam (more than %d%% of it isn't letters, "
                .. "digits or emoji).", TC.SYMBOL_PERCENT)
    else
        lines[#lines + 1] = "|cff60ff60Shown|r: no term matches."
        local shield = TC.GameTalk(prep)
        if shield and TC.IsTradePost(prep) then
            lines[#lines + 1] = format("Trade post (%s): shown even if this player was hidden for a term in the last %d "
                .. "minutes, unless they're spamming (%d+ hits, or %d+ messages in %d minutes).", shield,
                s.senderMinutes, TC.SPAM_HITS, TC.SPAM_MESSAGES, TC.SPAM_SECONDS / 60)
        elseif shield then
            lines[#lines + 1] = format("Game talk (%s): shown even if this player was hidden for a term in the last %d "
                .. "minutes.", shield, s.senderMinutes)
        else
            lines[#lines + 1] = format("Not game talk: hidden if this player was hidden for a term in the last %d "
                .. "minutes.", s.senderMinutes)
        end
    end
    return lines
end

-- Why a player's messages are shown or hidden right now (/tc status).
function TC.Status(name)
    local key, display = TC.NameKey(name)
    if not key then return { "No name given." } end
    local lines = {}
    local exempt = TC.ExemptReason(key)
    if exempt then
        lines[#lines + 1] = format("%s is exempt (%s): never hidden.", display, exempt)
    end
    if TC.MuteStatus then
        for _, line in ipairs(TC.MuteStatus(key)) do lines[#lines + 1] = line end
    end
    local n, left = SenderRule(key, Now())
    if n then
        lines[#lines + 1] = format("Timeout on: %d hit%s, %d min left. Their messages are hidden unless clear game talk.",
            n, n == 1 and "" or "s", Minutes(left))
    else
        local count = CountHits(key, Now())
        lines[#lines + 1] = format("No timeout for %s (%d hit%s in the window).", display, count, count == 1 and "" or "s")
    end
    if not exempt and not n then lines[#lines + 1] = "Their messages are shown unless they contain a term." end
    return lines
end

---------------------------------------------------------------------------------------------------
-- Stats (/tc tally)

function TC.Tally()
    local stats, today = TC.db.stats, TC.Today()
    local active, total = TC.TermCounts()
    local lines = {
        format("Hidden this session: %d. Hidden in total: %d. Today: %d hidden, %d flagged.",
            TC.session.hidden, stats.hiddenTotal, today.hidden or 0, today.flagged or 0),
        format("Terms: %d active of %d (%d custom). Flagged: %d missed, %d wrongly hidden.",
            active, total, #TC.db.terms.custom, #TC.db.flagged.missed, #TC.db.flagged.wrong),
    }
    local never = 0
    for _ in pairs(TC.rdb.neverMute) do never = never + 1 end
    lines[#lines + 1] = format("Never-mute list: %d.", never)
    if TC.ExtraTally then
        for _, line in ipairs(TC.ExtraTally()) do lines[#lines + 1] = line end
    end
    if TC.session.judged > 0 then
        lines[#lines + 1] = format("Judged %d messages this session, %.3f ms each on average.",
            TC.session.judged, TC.session.judgeTime / TC.session.judged)
    end
    return lines
end

---------------------------------------------------------------------------------------------------
-- Meme word mute: the words the most recent messages share, and words muted for a while from the
-- Overview tab (30 minutes or 4 hours), so a wave of murloc jokes can be skipped without hiding
-- murlocs for good. Counted over the last TC.MEME_WINDOW messages shown, each word once per
-- message; the common words in TC.CommonWords (ChatArchive\common-words.txt) never count. A muted
-- meme word hides the message only: no sender rule.

local gmatch = string.gmatch
local MEME_MIN = 3   -- shown as a meme word once this many recent messages share it
local recentWords, recentHead = {}, 0
local common

local function Common()
    if not common then
        common = {}
        for _, w in ipairs(TC.CommonWords or {}) do common[w] = true end
    end
    return common
end

-- "murlocs" counts as "murloc"; "boss" stays "boss". Apostrophes are dropped first ("don't" is "dont").
local function Stem(w)
    if #w > 3 and sub(w, -1) == "s" and sub(w, -2, -2) ~= "s" then return sub(w, 1, -2) end
    return w
end

local function EachWord(text, fn)
    text = gsub(lower(text), "'", "")
    for w in gmatch(text, "[a-z\128-\255]+") do
        if #w >= 3 then
            local r = fn(w, Stem(w))
            if r then return r end
        end
    end
end

local function MemeTable()
    local db = TC.db
    if type(db.memeWords) ~= "table" then db.memeWords = {} end
    return db.memeWords   -- [word] = { untilTime, minutes, added }
end

function TC.MemeMuted(word)
    local list = MemeTable()
    local m = list[word]
    if m and (m.untilTime or 0) > time() then return m end
    if m then list[word] = nil end
end

-- The muted meme word in this (lowercased) text, or nil.
function TC.MemeWordIn(text)
    if not next(MemeTable()) or type(text) ~= "string" then return nil end
    return EachWord(text, function(w, stem)
        if TC.MemeMuted(stem) then return stem end
        if stem ~= w and TC.MemeMuted(w) then return w end
    end)
end

TC.Listen("Shown", function(e)
    if not (e and e.filterable and type(e.visible) == "string") then return end
    local set, c = {}, Common()
    EachWord(e.visible, function(w, stem)
        if not c[w] and not c[stem] then set[stem] = true end
    end)
    recentHead = recentHead % TC.MEME_WINDOW + 1
    recentWords[recentHead] = { words = set, key = e.key }
end)

-- The top n meme words: { word, messages, players }, most messages first.
function TC.MemeWords(n)
    local msgs, who = {}, {}
    for _, r in pairs(recentWords) do
        for w in pairs(r.words) do
            msgs[w] = (msgs[w] or 0) + 1
            who[w] = who[w] or {}
            who[w][r.key or "?"] = true
        end
    end
    local list = {}
    for w, m in pairs(msgs) do
        if m >= MEME_MIN and not TC.MemeMuted(w) then
            local players = 0
            for _ in pairs(who[w]) do players = players + 1 end
            list[#list + 1] = { word = w, messages = m, players = players }
        end
    end
    table.sort(list, function(a, b)
        if a.messages ~= b.messages then return a.messages > b.messages end
        if a.players ~= b.players then return a.players > b.players end
        return a.word < b.word
    end)
    for i = #list, (n or 3) + 1, -1 do list[i] = nil end
    return list
end

-- Removes the lines already shown that contain this meme word (the buffer: the last 30 minutes), the
-- way they'd have been hidden had the word been muted when they arrived. Returns how many.
local function RemoveMemeLines(word)
    local ids, count = {}, 0
    local function Has(w, stem) return w == word or stem == word end
    for i = head, tail do
        local e = buffer[i]
        if e.filterable and not e.hidden and type(e.visible) == "string" and EachWord(e.visible, Has) then
            e.hidden, e.step, e.memeWord, e.cleanup = true, "meme", word, true
            if e.lineID then ids[e.lineID] = true end
            CountHidden(e)
            count = count + 1
        end
    end
    TC.RemoveLineIDs(ids)
    if count > 0 then TC.Notify("Hidden") end
    return count
end

-- Mutes a meme word for a while and removes the lines already shown with it. Returns the word as
-- stored (stemmed) and how many lines went, or nil when it's too short.
function TC.MuteMemeWord(word, minutes)
    word = Stem(gsub(lower(tostring(word or "")), "[^a-z\128-\255]", ""))
    if #word < 3 then return nil end
    minutes = math.max(1, math.floor(tonumber(minutes) or 30))
    MemeTable()[word] = { untilTime = time() + minutes * 60, minutes = minutes, added = time() }
    local removed = RemoveMemeLines(word)
    TC.Diag("meme", 'muted "%s" for %d min; %d earlier lines removed', word, minutes, removed)
    TC.Notify("Changed")
    return word, removed
end

-- The chat line confirming a meme word mute.
function TC.MemeMuteReport(word, minutes, removed)
    return format('Meme word "%s" muted for %d minutes%s.', word, minutes,
        removed and removed > 0 and format("; %d earlier line%s removed", removed, removed == 1 and "" or "s") or "")
end

function TC.UnmuteMemeWord(word)
    MemeTable()[word] = nil
    TC.Notify("Changed")
end

-- Muted meme words: { word, left (seconds), minutes }, soonest to end first.
function TC.MutedMemeWords()
    local list, now = {}, time()
    for w in pairs(MemeTable()) do
        local m = TC.MemeMuted(w)
        if m then list[#list + 1] = { word = w, left = m.untilTime - now, minutes = m.minutes } end
    end
    table.sort(list, function(a, b) return a.left < b.left end)
    return list
end

