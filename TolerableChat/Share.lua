-- Sharing lists (spec 15): guild words, guild exceptions, name keywords and custom terms, sent to one player,
-- your group or your guild as addon messages under 255 bytes, on TolerableChat's own prefix.
-- Players and default terms are never sent. A received list opens a preview: Add to mine, Replace
-- mine or Cancel; malformed entries are dropped. Lists from muted players are ignored.
--
-- The same text format is used for Settings -> Export my lists / Import lists.

local _, TC = ...
local UI = TC.UI
local find, sub, gsub, match, gmatch, format, lower = string.find, string.sub, string.gsub, string.match,
    string.gmatch, string.format, TC.Lower

local PREFIX = "TolerableChat"
local CHUNK = 200            -- payload bytes per message; with the header well under 255
local SEND_GAP = 0.3         -- seconds between messages
local share = { sending = nil, incoming = {}, status = "" }
TC.share = share

---------------------------------------------------------------------------------------------------
-- Text format: one entry per line, fields separated by tabs; % escapes tabs, newlines and itself.
--   g<TAB>word          muted guild word
--   x<TAB>Guild Name    guild exception (1.0.0; older versions drop these lines as malformed)
--   n<TAB>word          name keyword
--   t<TAB>kind<TAB>category<TAB>text   custom term

local function Esc(s)
    return (gsub(gsub(gsub(s, "%%", "%%%%"), "\t", "%%t"), "\n", "%%n"))
end

local function Unesc(s)
    return (gsub(s, "%%(.)", function(c) return c == "t" and "\t" or c == "n" and "\n" or c end))
end

function TC.SerializeLists()
    local lines = { "TolerableChat lists 1" }
    for _, w in ipairs(TC.db.guildWords) do lines[#lines + 1] = "g\t" .. Esc(w) end
    local exceptions = {}
    for _, name in pairs(TC.db.guildExceptions) do exceptions[#exceptions + 1] = name end
    table.sort(exceptions)
    for _, name in ipairs(exceptions) do lines[#lines + 1] = "x\t" .. Esc(name) end
    for _, w in ipairs(TC.db.nameWords) do lines[#lines + 1] = "n\t" .. Esc(w) end
    for _, t in ipairs(TC.db.terms.custom) do
        if type(t) == "table" and t.kind and t.text then
            lines[#lines + 1] = format("t\t%s\t%s\t%s", t.kind, Esc(t.cat or "Custom"), Esc(t.text))
        end
    end
    return table.concat(lines, "\n")
end

-- { guildWords = {}, exceptions = {}, nameWords = {}, terms = { { kind, cat, text } }, rejected = n, patterns = n }
-- fromPlayer: a list another player sent. Its Lua patterns are left out unread (counted in
-- patterns): a pattern runs on every chat line, and a badly made one can freeze the game, even while
-- it is checked. Patterns come in only through Import lists, which you paste yourself.
function TC.ParseLists(text, fromPlayer)
    local out = { guildWords = {}, exceptions = {}, nameWords = {}, terms = {}, rejected = 0, patterns = 0 }
    if type(text) ~= "string" then return out end
    for line in gmatch(text .. "\n", "([^\n]*)\n") do
        line = gsub(line, "\r$", "")
        if line ~= "" and not find(line, "^TolerableChat lists") then
            local fields = {}
            for f in gmatch(line .. "\t", "([^\t]*)\t") do fields[#fields + 1] = Unesc(f) end
            local what = fields[1]
            if what == "t" and fields[2] == "pattern" and fromPlayer then
                out.patterns = out.patterns + 1
            elseif what == "g" and fields[2] and fields[2] ~= "" and #fields[2] <= 40 then
                out.guildWords[#out.guildWords + 1] = lower(fields[2])
            elseif what == "x" and fields[2] and fields[2] ~= "" and #fields[2] <= 40 then
                out.exceptions[#out.exceptions + 1] = fields[2]
            elseif what == "n" and fields[2] and fields[2] ~= "" and #fields[2] <= 40 then
                out.nameWords[#out.nameWords + 1] = lower(fields[2])
            elseif what == "t" and TC.KIND_LABEL[fields[2] or ""] and fields[4] and #fields[4] <= 200
                and TC.ValidateTerm(fields[2], fields[4]) then
                local cat = TC.CategoryName(fields[3] or "")
                cat = TC.db.settings.categories[cat] ~= nil and cat or "Custom"
                out.terms[#out.terms + 1] = { kind = fields[2], cat = cat, text = fields[4] }
            else
                out.rejected = out.rejected + 1
            end
        end
    end
    return out
end

-- mode: "add" keeps yours and adds the new entries; "replace" swaps your lists for these.
function TC.ApplyLists(lists, mode)
    local db = TC.db
    if mode == "replace" then
        db.guildWords, db.nameWords, db.guildExceptions = {}, {}, {}
        local keep = {}
        db.terms.custom = keep
    end
    local n = 0
    for _, w in ipairs(lists.guildWords) do if TC.AddGuildWord(w) then n = n + 1 end end
    for _, name in ipairs(lists.exceptions or {}) do
        if not db.guildExceptions[lower(name)] then
            db.guildExceptions[lower(name)] = name
            n = n + 1
        end
    end
    for _, w in ipairs(lists.nameWords) do if TC.AddNameWord(w) then n = n + 1 end end
    for _, t in ipairs(lists.terms) do if TC.AddTerm(t.kind, t.text, t.cat) then n = n + 1 end end
    TC.CompileTerms()
    TC.Notify("GuildsChanged")
    TC.Notify("Changed")
    return n
end

---------------------------------------------------------------------------------------------------
-- Sending

local function Pump()
    local s = share.sending
    if not s then return end
    local i = s.next
    if i > #s.chunks then
        share.status = format("Shared with %s.", s.label)
        TC.Print(share.status)
        TC.Diag("share", "sent %d messages to %s", #s.chunks, s.label)
        share.sending = nil
        TC.Notify("Share")
        return
    end
    local msg = format("S:%s:%d:%d:%s", s.id, i, #s.chunks, s.chunks[i])
    C_ChatInfo.SendAddonMessage(PREFIX, msg, s.distribution, s.target)
    s.next = i + 1
    share.status = format("Sharing with %s: %d of %d", s.label, i, #s.chunks)
    TC.Notify("Share")
    C_Timer.After(SEND_GAP, Pump)
end

-- target: a player's name, "group" or "guild".
function TC.ShareLists(target)
    if share.sending then return nil, "Still sending the last share." end
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return nil, "Addon messages aren't available." end
    local distribution, whisperTo, label
    local t = lower(target or "")
    if t == "group" then
        if not IsInGroup() then return nil, "You aren't in a group." end
        distribution, label = IsInRaid() and "RAID" or "PARTY", "your group"
    elseif t == "guild" then
        if not IsInGuild() then return nil, "You aren't in a guild." end
        distribution, label = "GUILD", "your guild"
    elseif t ~= "" then
        local _, display = TC.NameKey(target)
        distribution, whisperTo, label = "WHISPER", display or target, display or target
    else
        return nil, "Share with whom? /tc share Name, group or guild."
    end
    local data = TC.SerializeLists()
    local chunks = {}
    for i = 1, #data, CHUNK do chunks[#chunks + 1] = sub(data, i, i + CHUNK - 1) end
    share.sending = { id = format("%04x", math.random(0, 0xFFFF)), chunks = chunks, next = 1, distribution = distribution,
                      target = whisperTo, label = label }
    Pump()
    return true
end

---------------------------------------------------------------------------------------------------
-- Receiving

local preview

local function ShowPreview(sender, lists)
    if not preview then
        local f = CreateFrame("Frame", "TolerableChatSharePreview", UIParent, "BasicFrameTemplateWithInset")
        f:Hide()
        f:SetSize(460, 340)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetClampedToScreen(true)
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        tinsert(UISpecialFrames, "TolerableChatSharePreview")
        if f.TitleText then f.TitleText:SetText("Shared lists") end
        f.cancel = UI.Button(f, "Cancel", function() f:Hide() end)
        f.cancel:SetPoint("BOTTOMRIGHT", -14, 12)
        f.replace = UI.Button(f, "Replace mine", nil)
        f.replace:SetPoint("RIGHT", f.cancel, "LEFT", -6, 0)
        f.add = UI.Button(f, "Add to mine", nil)
        f.add:SetPoint("RIGHT", f.replace, "LEFT", -6, 0)
        f.text = UI.Wrap(f, "")
        f.text:SetPoint("TOPLEFT", 16, -34)
        f.text:SetPoint("RIGHT", f, "RIGHT", -16, 0)
        preview = f
    end
    local function List(items, field)
        local out = {}
        for i, v in ipairs(items) do
            if i > 12 then out[#out + 1] = format("... and %d more", #items - 12) break end
            out[#out + 1] = field and v[field] or v
        end
        return out[1] and table.concat(out, ", ") or "none"
    end
    preview.text:SetText(format("%s shared these lists with you.\n\n|cffffd100Muted guild words|r (%d): %s\n\n"
        .. "|cffffd100Guild exceptions|r (%d): %s\n\n"
        .. "|cffffd100Name keywords|r (%d): %s\n\n|cffffd100Custom terms|r (%d): %s%s",
        sender, #lists.guildWords, List(lists.guildWords), #(lists.exceptions or {}), List(lists.exceptions or {}),
        #lists.nameWords, List(lists.nameWords),
        #lists.terms, List(lists.terms, "text"),
        (lists.rejected > 0 and format("\n\n|cffff6060%d malformed entries were dropped.|r", lists.rejected) or "")
        .. ((lists.patterns or 0) > 0 and format("\n\n|cffff9060%d pattern term%s left out: patterns from other "
            .. "players aren't accepted (a bad one can freeze the game). Ask for them as text and paste them into "
            .. "Settings, Import lists.|r", lists.patterns, lists.patterns == 1 and " was" or "s were") or "")))
    preview.add:SetScript("OnClick", function()
        local n = TC.ApplyLists(lists, "add")
        TC.Print(format("Added %d entries from %s.", n, sender))
        preview:Hide()
    end)
    preview.replace:SetScript("OnClick", function()
        TC.ApplyLists(lists, "replace")
        TC.Print(format("Your guild words, guild exceptions, name keywords and custom terms are now %s's.", sender))
        preview:Hide()
    end)
    preview:Show()
end
TC.ShowSharePreview = ShowPreview

TC.On("PLAYER_LOGIN", function()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end
end)

TC.On("CHAT_MSG_ADDON", function(prefix, text, distribution, sender)
    if prefix ~= PREFIX or TC.IsSecret(text) or TC.IsSecret(sender) or type(text) ~= "string" then return end
    local key, display = TC.NameKey(sender)
    if not key or key == TC.PlayerKey() then return end
    local id, i, n, data = match(text, "^S:(%x+):(%d+):(%d+):(.*)$")
    i, n = tonumber(i), tonumber(n)
    if not id or not i or not n or n < 1 or n > 100 or i < 1 or i > n then return TC.Count("shareUnreadable") end
    if not TC.db.settings.acceptShares or TC.IsMuted(key) then
        if i == 1 then
            TC.Diag("share", "ignored lists from %s (%s)", display, TC.IsMuted(key) and "muted" or "accepting lists is off")
        end
        return
    end
    local inbox = share.incoming[key]
    if not inbox or inbox.id ~= id then
        inbox = { id = id, n = n, parts = {}, got = 0 }
        share.incoming[key] = inbox
    end
    if not inbox.parts[i] then
        inbox.parts[i] = data
        inbox.got = inbox.got + 1
    end
    if inbox.got >= inbox.n then
        share.incoming[key] = nil
        local lists = TC.ParseLists(table.concat(inbox.parts, "", 1, inbox.n), true)
        TC.Diag("share", "lists from %s: %d guild words, %d exceptions, %d name keywords, %d terms, %d malformed, "
            .. "%d patterns left out", display, #lists.guildWords, #lists.exceptions, #lists.nameWords, #lists.terms,
            lists.rejected, lists.patterns)
        ShowPreview(display, lists)
    end
end)
