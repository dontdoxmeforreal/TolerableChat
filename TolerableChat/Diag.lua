-- Diagnostics: proof that things work, and early warning when they don't.
--
--   TC.Diag(area, fmt, ...)   one line in the diagnostics log (saved, last 600 lines)
--   TC.Count(name, n)         a counter for this session
--   TC.DiagError(where, err)  an error caught in TolerableChat's own code: logged, counted, and still
--                             passed to the game's error handler so BugSack shows it
--   /tc diag                  the health summary in chat; Settings -> Diagnostics report shows it all
--
-- The log and the OlympusNet samples are in TolerableChatDB.diag, so they can be read from the saved
-- file after logout.

local _, TC = ...
local format, date = string.format, date

local LOG_MAX = 600
local counters, maxima = {}, {}
TC.counters = counters

local function Diag()
    local db = TC.db
    if not db then return nil end
    if type(db.diag) ~= "table" then db.diag = {} end
    local d = db.diag
    if type(d.log) ~= "table" then d.log = {} end
    if type(d.netSamples) ~= "table" then d.netSamples = {} end
    if type(d.netCapture) ~= "table" then d.netCapture = {} end
    if type(d.errors) ~= "table" then d.errors = {} end
    return d
end
TC.DiagData = Diag

function TC.Diag(area, fmt, ...)
    local d = Diag()
    if not d then return end
    local ok, msg = pcall(format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    local log = d.log
    log[#log + 1] = format("%s %-6s %s", date("%m-%d %H:%M:%S"), area, msg)
    while #log > LOG_MAX do table.remove(log, 1) end
    if TC.db.settings.debug then TC.Print("|cff999999[" .. area .. "] " .. msg .. "|r") end
end

function TC.Count(name, n)
    counters[name] = (counters[name] or 0) + (n or 1)
end

function TC.Max(name, value)
    if not maxima[name] or value > maxima[name] then maxima[name] = value end
end

local reported = {}
function TC.DiagError(where, err)
    err = tostring(err)
    TC.Count("errors")
    local d = Diag()
    if d then
        local line = format("%s %s: %s", date("%m-%d %H:%M:%S"), where, err)
        d.errors[#d.errors + 1] = line
        while #d.errors > 50 do table.remove(d.errors, 1) end
        TC.Diag("error", "%s: %s", where, err)
    end
    if not reported[err] then
        reported[err] = true
        local handler = geterrorhandler and geterrorhandler()
        if handler then handler(err) end
    end
end

---------------------------------------------------------------------------------------------------
-- What TolerableChat does to the game's own frames this session: pop-ups kept out of sight
-- (Blocking.lua) and the Who list taken off WHO_LIST_UPDATE during a search (Check.lua). Only widget
-- calls (SetAlpha, EnableMouse, UnregisterEvent), which leave no tainted values behind, but they're the
-- first places to look if the game ever blames TolerableChat, so a block report lists them.

local touches = {}   -- [what] = { n, last }

function TC.NoteTouch(what)
    local t = touches[what] or { n = 0 }
    touches[what] = t
    t.n, t.last = t.n + 1, time()
end

local function Touches()
    local list = {}
    for what, t in pairs(touches) do
        list[#list + 1] = format("%s %d time%s (last %s)", what, t.n, t.n == 1 and "" or "s", date("%H:%M", t.last))
    end
    table.sort(list)
    return list[1] and table.concat(list, "; ") or "nothing"
end

---------------------------------------------------------------------------------------------------
-- The game blocked or refused a protected action and named TolerableChat ("tainted"): logged and
-- counted. The any-key /who frame sees every key press, so it is switched off, just in case.

local lastBlocked
local function Blocked(kind, addon, func)
    if addon ~= TC.name then return end
    TC.Count("gameBlocked")
    lastBlocked = tostring(func)
    local keyOn = TC.db and TC.db.settings.keyWho
    TC.Diag("taint", "the game %s %s because of TolerableChat%s; game frames touched this session: %s", kind,
        lastBlocked, keyOn and " (any-key /who was on: switched off)" or "", Touches())
    if keyOn and TC.SetKeyWho then
        TC.SetKeyWho(false)
        TC.Print("The game blocked an action (" .. lastBlocked .. ") and named TolerableChat, so \"any key runs "
            .. "the next /who\" is off now; the Next /who button still works. /tc diag report has the details.")
    end
end
TC.On("ADDON_ACTION_BLOCKED", function(addon, func) Blocked("blocked", addon, func) end)
TC.On("ADDON_ACTION_FORBIDDEN", function(addon, func) Blocked("refused", addon, func) end)

---------------------------------------------------------------------------------------------------
-- Environment check: the client functions TolerableChat relies on, logged at login.

local NEEDED = {
    { "chat filter", function() return (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter end },
    { "line removal", function() return ChatFrame1 and ChatFrame1.RemoveMessagesByPredicate end },
    { "secret values", function() return issecretvalue end },
    { "right-click menus", function() return Menu and Menu.ModifyMenu end },
    { "/who", function() return C_FriendList and C_FriendList.SendWho end },
    { "quiet /who", function() return C_FriendList and C_FriendList.SetWhoToUi end },
    { "channel join", function() return JoinTemporaryChannel or JoinChannelByName end },
    { "channel members", function() return C_ChatInfo and C_ChatInfo.GetChannelRosterInfo and GetChannelDisplayInfo end },
    { "addon messages", function() return C_ChatInfo and C_ChatInfo.SendAddonMessage and C_ChatInfo.RegisterAddonMessagePrefix end },
    { "chat bubbles", function() return C_ChatBubbles and C_ChatBubbles.GetAllChatBubbles end },
    { "tooltips", function() return TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall end },
    { "report window", function() return ReportFrame and ReportInfo end },
    { "AddOn Compartment", function() return AddonCompartmentFrame end },
}

function TC.EnvironmentCheck()
    local missing = {}
    for _, need in ipairs(NEEDED) do
        local ok, present = pcall(need[2])
        if not ok or not present then missing[#missing + 1] = need[1] end
    end
    TC.missing = missing
    local toc = GetBuildInfo and select(4, GetBuildInfo())
    TC.Diag("start", "TolerableChat %s, client %s (%s), %s %s, realm %s. Missing: %s.", TC.version,
        tostring(toc or "?"), tostring(WOW_PROJECT_ID or "?"),
        tostring(UnitFactionGroup("player") or "?"), tostring(TC.PlayerKey() or "?"),
        tostring(GetNormalizedRealmName and GetNormalizedRealmName() or "?"),
        missing[1] and table.concat(missing, ", ") or "nothing")
    return missing
end

TC.On("PLAYER_LOGIN", function()
    C_Timer.After(2, TC.EnvironmentCheck)
end)

---------------------------------------------------------------------------------------------------
-- Health summary and full report

local function Ago(t)
    if not t then return "never" end
    local s = math.floor(GetTime() - t)
    return s < 120 and (s .. " s ago") or (math.floor(s / 60) .. " min ago")
end

function TC.HealthLines()
    local c, s = counters, TC.session
    local lines = {}
    local judged = s.judged
    lines[#lines + 1] = format("Chat filter: %d messages judged, %.3f ms average, %.3f ms slowest; %d hidden; %d errors.",
        judged, judged > 0 and s.judgeTime / judged or 0, maxima.judge or 0, s.hidden, c.filterErrors or 0)
    local who = TC.WhoStats and TC.WhoStats() or {}
    lines[#lines + 1] = format("/who: %d sent (%d by any key), %d answered, %d without an answer, %d \"wait\" notices; "
        .. "cooldown now %d s; last answer %s.", c.whoSent or 0, c.whoByKey or 0, c.whoAnswered or 0, c.whoNoReply or 0,
        c.whoThrottled or 0, who.cooldown or 0, Ago(who.lastAnswer))
    lines[#lines + 1] = format("  learned %d players (%d new to TolerableChat, %d in muted guilds); %d chat lines of "
        .. "/who output hidden; Who window opened by a search %d times; %d presses too early or while waiting; "
        .. "%d answers not ours.", c.whoLearned or 0, c.whoNew or 0, c.whoMutedFound or 0, c.whoChatHidden or 0,
        c.whoWindowOpened or 0, (c.whoPressEarly or 0) + (c.whoPressWaiting or 0), c.whoUnclaimed or 0)
    if who.sweep then lines[#lines + 1] = "  sweep: " .. who.sweep end
    local indexed, heard, netGuilds = 0, 0, 0
    local r = TC.rdb or {}
    for _, record in pairs(r.olympusGuilds or {}) do
        indexed = indexed + 1
        if not record.confirmed then heard = heard + 1 end
    end
    for _ in pairs(r.netGuilds or {}) do netGuilds = netGuilds + 1 end
    lines[#lines + 1] = format("Realm %s. Muted guild index: %d guilds, %d of them only heard on OlympusNet (%d new this "
        .. "session, %d dropped over the cap); %d OlympusNet guilds without a muted word.",
        tostring(TC.realm or "not known yet"), indexed, heard, c.guildsIndexed or 0, c.netGuildsDropped or 0, netGuilds)
    lines[#lines + 1] = format("Nameplates read: %d; players seen online since login: %d.", c.nameplatesRead or 0,
        TC.online and (function() local n = 0 for _ in pairs(TC.online) do n = n + 1 end return n end)() or 0)
    local net = TC.net or {}
    local kinds = {}
    for kind, n in pairs(net.counts or {}) do kinds[#kinds + 1] = format("%s %d", kind, n) end
    table.sort(kinds)
    lines[#lines + 1] = format("OlympusNet: %s; %d members; messages: %s; %d unreadable; kinds TolerableChat doesn't "
        .. "know: %s; %d chunks dropped. Only guild names are used; nothing heard there mutes anyone.",
        net.joined and ("joined " .. net.joined) or "not joined", net.members or 0,
        kinds[1] and table.concat(kinds, ", ") or "none", c.netUnreadable or 0,
        TC.NetUnknownKinds and TC.NetUnknownKinds() or "none", c.netChunkDropped or 0)
    lines[#lines + 1] = format("Blocking: %d invites, %d guild invites, %d duels declined; %d trades asked, %d declined; "
        .. "%d pop-ups not found.", c.declineGroup or 0, c.declineGuild or 0, c.declineDuel or 0, c.tradeAsked or 0,
        c.tradeDeclined or 0, c.popupMissing or 0)
    lines[#lines + 1] = format("Actions the game blocked because of TolerableChat: %d%s. Game frames touched: %s.",
        c.gameBlocked or 0, lastBlocked and (" (last: " .. lastBlocked .. ")") or "", Touches())
    lines[#lines + 1] = format("Errors this session: %d.%s", c.errors or 0,
        (TC.missing and TC.missing[1]) and ("  Missing client functions: " .. table.concat(TC.missing, ", ") .. ".") or "")
    return lines
end

function TC.DiagReport()
    local d = Diag() or {}
    local out = { "TolerableChat diagnostics report, " .. date("%Y-%m-%d %H:%M:%S"), "" }
    for _, line in ipairs(TC.HealthLines()) do out[#out + 1] = line end
    out[#out + 1] = ""
    out[#out + 1] = "Recent errors:"
    for i = math.max(1, #d.errors - 9), #d.errors do out[#out + 1] = "  " .. d.errors[i] end
    out[#out + 1] = ""
    out[#out + 1] = "OlympusNet samples (latest per kind):"
    for kind, list in pairs(d.netSamples or {}) do
        for _, sample in ipairs(list) do out[#out + 1] = format("  [%s] %s", kind, sample) end
    end
    out[#out + 1] = ""
    out[#out + 1] = format("Raw capture saved: %d messages (/tc net raw to switch it on or off).", #(d.netCapture or {}))
    out[#out + 1] = ""
    out[#out + 1] = "Log (newest last):"
    for i = math.max(1, #d.log - 199), #d.log do out[#out + 1] = d.log[i] end
    return table.concat(out, "\n")
end
