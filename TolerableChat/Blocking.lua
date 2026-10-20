-- Interaction blocking for muted players (spec 13): group and guild invites and duels declined after
-- a pause, trades asked about, a heads-up when you invite or whisper one, chat bubbles blanked; plus
-- the tooltip line (9). Exempt players are never blocked.
--
-- Blizzard's invite pop-ups decline when hidden, and hiding the trade window cancels the trade, so
-- "hidden during the pause" means made invisible (alpha 0, no mouse). TolerableChat never shows or
-- hides the game's pop-ups itself (that leaves "tainted" values that later block the game's own
-- protected actions): it declines with the game's decline call and keeps the pop-up invisible until
-- the game hides it, or until another player's request reuses it.

local _, TC = ...
local format, lower = string.format, TC.Lower
local IsSecret = TC.IsSecret

local function Muted(name, realm)
    if type(name) ~= "string" or IsSecret(name) then return nil end
    local key, display = TC.NameKey(name, realm)
    if key and TC.IsMuted(key) then return key, display end
    return nil
end

local function FindPopup(which)
    if StaticPopup_FindVisible then return StaticPopup_FindVisible(which) end
    for i = 1, STATICPOPUP_NUMDIALOGS or 4 do
        local f = _G["StaticPopup" .. i]
        if f and f:IsShown() and f.which == which then return f end
    end
end

local concealed, hooked = {}, {}

local function Reveal(frame)
    if frame and concealed[frame] then
        concealed[frame] = nil
        frame:SetAlpha(1)
        frame:EnableMouse(true)
    end
end

local function Conceal(frame)
    if not frame then return end
    TC.NoteTouch("pop-ups kept out of sight")
    concealed[frame] = true
    frame:SetAlpha(0)
    frame:EnableMouse(false)
    if not hooked[frame] and frame.HookScript then
        hooked[frame] = true
        frame:HookScript("OnHide", Reveal)   -- pop-up frames are reused: never left invisible
    end
end

---------------------------------------------------------------------------------------------------
-- Requests (13.1)

local held = {}
local COUNTER = { ["group invite"] = "declineGroup", ["guild invite"] = "declineGuild", duel = "declineDuel" }

-- Declines a muted player's request after 2-8 s (at once with "Decline instantly"), its pop-up
-- invisible meanwhile. If blocking is switched off or the player unmuted during the pause, the
-- pop-up comes back to you.
local function Hold(kind, key, display, findFrame, decline)
    local token = {}
    held[kind] = token
    local delay = TC.db.settings.declineInstant and 0 or (2 + math.random() * 6)
    C_Timer.After(0, function()   -- the game shows its pop-up after this event
        if held[kind] ~= token then return end
        local frame = findFrame()
        if frame then
            Conceal(frame)
        else
            TC.Count("popupMissing")
            TC.Diag("block", "no %s pop-up found to keep out of sight (from %s)", kind, display)
        end
    end)
    C_Timer.After(delay, function()
        if held[kind] ~= token then return end
        held[kind] = nil
        local frame = findFrame()
        if TC.db.settings.declineRequests and TC.IsMuted(key) then
            decline()
            TC.Count(COUNTER[kind] or "declineOther")
            TC.Diag("block", "declined %s from %s after %.1f s%s", kind, display, delay,
                (frame and frame:IsShown()) and " (its pop-up stays invisible until the game closes it)" or "")
            -- Shown again when the game closes it; at the latest after its 60 s timeout.
            if frame then C_Timer.After(65, function() Reveal(frame) end) end
        else
            TC.Diag("block", "%s from %s let through: blocking switched off or player unmuted", kind, display)
            Reveal(frame)
        end
    end)
end

-- A request from someone else replaces a muted player's (one of each kind at a time): its pending
-- decline is called off, and the pop-up it may reuse is shown.
local function Unhold(kind, findFrame)
    held[kind] = nil
    C_Timer.After(0, function() Reveal(findFrame()) end)
end

local function GroupPopup()
    return FindPopup("PARTY_INVITE") or (LFGInvitePopup and LFGInvitePopup:IsShown() and LFGInvitePopup) or nil
end

TC.On("PARTY_INVITE_REQUEST", function(name)
    local key, display = Muted(name)
    if not key or not TC.db.settings.declineRequests then return Unhold("group invite", GroupPopup) end
    Hold("group invite", key, display, GroupPopup, function() DeclineGroup() end)
end)

local function GuildPopup()
    return GuildInviteFrame and GuildInviteFrame:IsShown() and GuildInviteFrame or nil
end

TC.On("GUILD_INVITE_REQUEST", function(inviter)
    local key, display = Muted(inviter)   -- Players.lua has already learned the inviter's guild
    if not key or not TC.db.settings.declineRequests then return Unhold("guild invite", GuildPopup) end
    Hold("guild invite", key, display, GuildPopup, function() DeclineGuild() end)
end)

for event, which in pairs({ DUEL_REQUESTED = "DUEL_REQUESTED", DUEL_TO_THE_DEATH_REQUESTED = "DUEL_TO_THE_DEATH_REQUESTED" }) do
    local function DuelPopup() return FindPopup(which) end
    TC.On(event, function(name)
        local key, display = Muted(name)
        if not key or not TC.db.settings.declineRequests then return Unhold("duel", DuelPopup) end
        Hold("duel", key, display, DuelPopup, function() CancelDuel() end)
    end)
end

---------------------------------------------------------------------------------------------------
-- Trades (13.1): "Ask" shows "Trade with Name?"; Allow covers that player for 10 minutes.

local allowedUntil, asking, question = {}, nil, nil

local function EndAsk()
    asking, question = nil, nil
    Reveal(TradeFrame)
end

local function DeclineTrade()
    if asking then
        CloseTrade()
        TC.Count("tradeDeclined")
        TC.Diag("block", "trade declined (you chose Decline)")
    end
    EndAsk()
end

TC.On("TRADE_SHOW", function()
    local name, realm = UnitName("NPC")
    local key, display = Muted(name, realm)
    if not key or (allowedUntil[key] and time() < allowedUntil[key]) then return end
    if TC.db.settings.trades == "decline" then
        CloseTrade()
        TC.Count("tradeDeclined")
        TC.Diag("block", "declined a trade from %s", display)
        return
    end
    TC.Count("tradeAsked")
    TC.Diag("block", "asked about a trade from %s", display)
    asking = key
    Conceal(TradeFrame)
    question = {
        text = format("Trade with %s?\n|cff999999They're on your mute list.|r", display),
        yes = "Allow", no = DECLINE or "Decline",
        onYes = function()
            if asking then allowedUntil[asking] = time() + TC.ALLOW_TRADE end
            EndAsk()
        end,
        onNo = DeclineTrade,
        onEscape = DeclineTrade,
    }
    TC.UI.Ask(question)
end)

TC.On("TRADE_CLOSED", function()
    if asking then
        TC.UI.CloseAsk(question)
        EndAsk()
    end
end)

---------------------------------------------------------------------------------------------------
-- Heads-up when you invite a muted player (13.2); nothing is blocked.

local function InviteHeadsUp(name)
    if not TC.db.settings.warnings or type(name) ~= "string" or IsSecret(name) then return end
    local key, display = TC.NameKey(name)
    local reason = key and TC.WhyMuted(key)
    if reason then TC.Print(format("%s is on your mute list (%s).", display, reason)) end
end

if C_PartyInfo and C_PartyInfo.InviteUnit then hooksecurefunc(C_PartyInfo, "InviteUnit", InviteHeadsUp) end
if InviteUnit then hooksecurefunc("InviteUnit", InviteHeadsUp) end

---------------------------------------------------------------------------------------------------
-- Whispers (13.3): a red chat box header when you whisper a muted player, with one line saying their
-- replies will be hidden.

local hooked, warned = {}, {}

local function OnHeader(editBox)
    if not TC.db or not TC.db.settings.warnings then return end
    if editBox:GetAttribute("chatType") ~= "WHISPER" then return end
    local target = editBox:GetAttribute("tellTarget")
    if type(target) ~= "string" or IsSecret(target) then return end
    local key, display = TC.NameKey(target)
    local reason = key and TC.IsMuted(key) and TC.WhyMuted(key)
    if not reason then return end
    local header = editBox.header or (editBox:GetName() and _G[editBox:GetName() .. "Header"])
    if header then header:SetTextColor(1, 0.25, 0.25) end
    if not warned[key] then
        warned[key] = true
        TC.Print(format("%s is muted (%s): their replies will be hidden.", display, reason))
    end
end

local function HookEditBoxes()
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local eb = _G["ChatFrame" .. i .. "EditBox"]
        if eb and not hooked[eb] and eb.UpdateHeader then
            hooked[eb] = true
            hooksecurefunc(eb, "UpdateHeader", OnHeader)
        end
    end
end

TC.On("PLAYER_LOGIN", HookEditBoxes)

-- With whispers in their own tabs (Interface > Social > New Whispers: "New Tab"), a muted player's
-- whisper still opens an empty tab: the game opens it before any chat filter runs
-- (FloatingChatFrameManager_OnEvent). TolerableChat leaves it alone. Closing it (FCF_Close) would
-- write the game's whisper-tab records from addon code, and the game reads them for every later
-- whisper, so replies and slash commands typed there could be blocked. Close it by hand.

---------------------------------------------------------------------------------------------------
-- Chat bubbles (13.4), open world only: muted players' bubbles and bubbles of hidden messages are
-- blanked; a bubble whose text a shown player said at the same moment stays. Say, yell and emote
-- are tracked for 10 seconds; there is no per-frame work when nothing is tracked or blanked.

local BUBBLE_EVENTS = { CHAT_MSG_SAY = true, CHAT_MSG_YELL = true, CHAT_MSG_EMOTE = true }
local TRACK = 10
local hiddenSaid, shownSaid, blanked = {}, {}, {}
local driver = CreateFrame("Frame")
driver:Hide()

local function BubbleKey(text)
    return lower(TC.StripFormatting(text))
end

local function BubbleText(bubble)
    local holder = bubble.GetChildren and bubble:GetChildren()
    if not holder then return end
    local fs = holder.String
    if not fs and holder.GetRegions then
        for _, region in ipairs({ holder:GetRegions() }) do
            if region.GetObjectType and region:GetObjectType() == "FontString" then fs = region break end
        end
    end
    return holder, fs and fs:GetText()
end

local function RestoreAll()
    for holder in pairs(blanked) do
        holder:SetAlpha(1)
        blanked[holder] = nil
    end
end

local elapsedSince = 0
driver:SetScript("OnUpdate", function(self, elapsed)
    elapsedSince = elapsedSince + elapsed
    if elapsedSince < 0.1 then return end
    elapsedSince = 0
    local now = TC.Now()
    for k, t in pairs(hiddenSaid) do if t < now then hiddenSaid[k] = nil end end
    for k, t in pairs(shownSaid) do if t < now then shownSaid[k] = nil end end
    if not TC.db.settings.bubbles or (IsInInstance and IsInInstance()) or not C_ChatBubbles then
        RestoreAll()
        if not next(hiddenSaid) then self:Hide() end
        return
    end
    for _, bubble in ipairs(C_ChatBubbles.GetAllChatBubbles(false) or {}) do
        local holder, text = BubbleText(bubble)
        if holder and type(text) == "string" and not IsSecret(text) then
            local key = BubbleKey(text)
            if hiddenSaid[key] and not shownSaid[key] then
                if not blanked[holder] then
                    holder:SetAlpha(0)
                    blanked[holder] = true
                end
            elseif blanked[holder] then
                holder:SetAlpha(1)   -- bubble frames are reused for other messages
                blanked[holder] = nil
            end
        end
    end
    if not next(hiddenSaid) and not next(blanked) then self:Hide() end
end)

TC.Listen("Hidden", function(e)
    if e and BUBBLE_EVENTS[e.event] and e.raw and TC.db.settings.bubbles then
        hiddenSaid[BubbleKey(e.raw)] = TC.Now() + TRACK
        driver:Show()
    end
end)

TC.Listen("Shown", function(e)
    if e and BUBBLE_EVENTS[e.event] and e.raw and next(hiddenSaid) then
        shownSaid[BubbleKey(e.raw)] = TC.Now() + TRACK
    end
end)

TC.Listen("Settings", function()
    if TC.db and not TC.db.settings.bubbles then RestoreAll() end
end)

---------------------------------------------------------------------------------------------------
-- Tooltip line (9): "TolerableChat: muted (reason)".

local function AddTooltipLine(tooltip)
    if not TC.db or not TC.db.settings.tooltip or not tooltip.GetUnit then return end
    local _, unit = tooltip:GetUnit()
    if not unit or IsSecret(unit) or not UnitIsPlayer(unit) then return end
    local name, realm = UnitName(unit)
    if not TC.Str(name) then return end
    local key = TC.NameKey(name, realm)
    local reason = key and TC.WhyMuted(key)
    if not reason then return end
    local guid = UnitGUID(unit)
    local exempt = TC.ExemptReason(key, (not IsSecret(guid)) and guid or nil)
    tooltip:AddLine("TolerableChat: muted (" .. reason .. ")" .. (exempt and (", but exempt (" .. exempt .. ")") or ""),
        1, 0.4, 0.4, true)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, TC.Guarded("tooltip", function(tooltip)
        if tooltip == GameTooltip then AddTooltipLine(tooltip) end
    end))
elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetUnit", TC.Guarded("tooltip", AddTooltipLine))
end
