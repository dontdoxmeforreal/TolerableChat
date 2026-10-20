-- Slash commands (spec 16), the key binding and the AddOn Compartment button. Slash commands never
-- send /who.

local _, TC = ...
local UI = TC.UI
local format, lower, match, gmatch, gsub = string.format, TC.Lower, string.match, string.gmatch, string.gsub

BINDING_NAME_TOLERABLECHAT_TOGGLE = "Toggle TolerableChat"

function TolerableChat_Toggle()
    UI.Toggle()
end

function TolerableChat_OnAddonCompartmentClick()
    UI.Toggle()
end

function TolerableChat_OnAddonCompartmentEnter(_, button)
    GameTooltip:SetOwner(button or UIParent, "ANCHOR_LEFT")
    GameTooltip:SetText("TolerableChat")
    GameTooltip:AddLine("Click to open or close the main window.", 1, 1, 1)
    GameTooltip:Show()
end

function TolerableChat_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

-- Whitespace is spelled out: %s follows the Windows locale and also matches byte A0, the last byte of
-- many UTF-8 letters (see TC.WS), so "%s*$" would cut an "à" at the end of a name in half.
local function Trim(s)
    return (gsub(gsub(s or "", "^[ \t\n\r\f\v]+", ""), "[ \t\n\r\f\v]+$", ""))
end

-- The first word and the rest, trimmed.
local function FirstWord(s)
    local word, rest = match(Trim(s), "^([^ \t\n\r\f\v]*)[ \t\n\r\f\v]*(.*)$")
    return word or "", rest or ""
end

local function Names(text)
    local out = {}
    for part in gmatch(text or "", "[^,]+") do
        part = Trim(part)
        if part ~= "" then out[#out + 1] = part end
    end
    return out
end

local function PrintLines(lines)
    for _, line in ipairs(lines) do TC.Print(line) end
end

local HELP = {
    "/tc  open or close the window",
    "/tc mute Name[, Name],  /tc unmute Name[, Name],  /tc allow Name[, Name] (never mute, toggle)",
    "/tc guild add||remove word,  /tc guild except Guild Name  (muted guild words and exceptions)",
    "/tc guild preview word  which known guilds a word would mute;  /tc guild defaults  put back the default words",
    "/tc guild of Name  mute that player's guild, looked up with the next /who if it isn't known",
    "/tc name add||remove word  (mute players whose name contains it)",
    "/tc check [Name]  open the Check tab, or put a player first in the queue (the Next /who button does the search)",
    "/tc share Name||group||guild  send your guild words, guild exceptions, name keywords and custom terms",
    "/tc net on||all||off  listen on this character only, on every character, or not at all;  /tc advanced  the Advanced tab",
    "/tc net raw  print and save each OlympusNet message;  /tc net capture  save them without printing",
    "/tc net forget  forget everything heard on OlympusNet on this realm (guilds not seen in game, census counts)",
    "/tc diag  health summary;  /tc diag report  the full diagnostics report to copy",
    "/tc meme  meme words now;  /tc meme mute word [minutes],  /tc meme unmute word",
    "/tc key on||off  any key press runs the next /who when it's due",
    "/tc guilds  the muted guild index: members known / the guild's own member count, faction",
    "/tc status Name  why a player is shown or hidden",
    "/tc recheck Name  lift a guild mute and look them up again;  /tc recheck left  let go of everyone who left",
    "/tc term add [word||phrase||contains||allof||pattern] text,  /tc term remove text,  /tc term list",
    "    (word = Whole word, phrase = Exact text, contains = Anywhere, allof = All of, pattern = a Lua pattern)",
    "/tc test text  would this be hidden, and why",
    "/tc log,  /tc flagged  open those tabs",
    "/tc tally  stats",
    "/tc on,  /tc off,  /tc debug",
}

local function TermCommand(rest)
    local action, body = FirstWord(rest)
    action = lower(action)
    if action == "add" then
        local kind, text = FirstWord(body)
        if text == "" or not TC.KIND_LABEL[lower(kind)] then kind, text = "word", body end
        local key, reason = TC.AddTerm(lower(kind), text, "Custom")
        if key then
            TC.Print(format('Added %s term "%s" (Custom).', TC.KIND_LABEL[lower(kind)], TC.NormalizeTermText(lower(kind), text)))
        else
            TC.Print("Not added: " .. tostring(reason))
        end
    elseif action == "remove" then
        for _, kind in ipairs(TC.KINDS) do
            local key = TC.TermKey(kind, TC.NormalizeTermText(kind, body))
            local ok, how = TC.DeleteTerm(key)
            if ok then
                return TC.Print(format('%s "%s".', how == "disabled" and "Disabled default term" or "Removed", body))
            end
        end
        TC.Print(format('No term "%s".', body))
    elseif action == "list" then
        local custom = TC.db.terms.custom
        TC.Print(format("%d custom term%s:", #custom, #custom == 1 and "" or "s"))
        for _, t in ipairs(custom) do
            TC.Print(format("  %s  (%s, %s)%s", t.text, TC.KIND_LABEL[t.kind] or t.kind, t.cat or "Custom",
                TC.db.terms.disabled[TC.TermKey(t.kind, t.text)] and " off" or ""))
        end
        local off = 0
        for key in pairs(TC.db.terms.disabled) do
            if TC.IsDefaultTerm(key) then off = off + 1 end
        end
        TC.Print(format("%d default term%s disabled. The term editor lists them all: /tc, Filter, Edit terms.", off,
            off == 1 and "" or "s"))
    else
        TC.Print("/tc term add [type] text  ||  /tc term remove text  ||  /tc term list")
    end
end

SLASH_TOLERABLECHAT1 = "/tc"
SLASH_TOLERABLECHAT2 = "/tolerablechat"
SlashCmdList.TOLERABLECHAT = function(msg)
    if not TC.db then return end
    local cmd, rest = FirstWord(msg)
    cmd = lower(cmd)
    if cmd == "" then
        UI.Toggle()
    elseif cmd == "allow" then
        local names = Names(rest)
        if not names[1] then return TC.Print("/tc allow Name[, Name]") end
        for _, name in ipairs(names) do
            local on, display = TC.ToggleNeverMute(name)
            if display then
                TC.Print(display .. (on and " is on your never-mute list." or " is off your never-mute list."))
            end
        end
    elseif cmd == "mute" or cmd == "unmute" then
        local names = Names(rest)
        if not names[1] then return TC.Print("/tc " .. cmd .. " Name[, Name]") end
        for _, name in ipairs(names) do
            if cmd == "mute" then
                local _, display = TC.MuteByHand(name)
                if display then TC.Print(display .. " is muted.") end
            else
                local key, display = TC.NameKey(name)
                if key and TC.Unmute(key) then
                    TC.Print(display .. " is unmuted.")
                elseif key then
                    local reason = TC.WhyMuted(key)
                    TC.Print(display .. (reason and (" isn't muted by hand (" .. reason .. "); /tc allow " .. display
                        .. " never mutes them.") or " isn't muted."))
                end
            end
        end
    elseif cmd == "guild" then
        local action, text = FirstWord(rest)
        action = lower(action)
        if action == "add" and text ~= "" then
            TC.Print(TC.AddGuildWordReport(text))
        elseif action == "remove" and text ~= "" then
            TC.Print(TC.RemoveGuildWord(text) and ('Removed "' .. lower(text) .. '": guilds it alone muted are shown again.')
                or "Not on the list.")
        elseif action == "except" and text ~= "" then
            TC.Print(TC.ExceptionReport(text))
        elseif action == "preview" and text ~= "" then
            local problem = TC.GuildWordProblem(text)
            local matches = TC.GuildWordMatches(text)
            TC.Print(format('"%s" would mute %d known guild%s on this realm%s%s', lower(text), #matches,
                #matches == 1 and "" or "s", matches[1] and (": " .. table.concat(matches, ", ", 1, math.min(10, #matches))
                .. (#matches > 10 and ", ..." or "")) or "", problem and (". It can't be added: " .. problem .. ".") or "."))
        elseif action == "of" and text ~= "" then
            local who = TC.QueueGuildMute(text)
            TC.Print(who and (who .. " is first for the next /who; their guild is muted as soon as the game shows it.")
                or "/tc guild of Name")
        elseif action == "defaults" then
            local n = TC.RestoreGuildWords()
            TC.Print(n > 0 and format("Put back %d default guild word%s.", n, n == 1 and "" or "s")
                or "Every default guild word is on the list already.")
        else
            TC.Print("Muted guild words: " .. table.concat(TC.db.guildWords, ", ")
                .. ". /tc guild add||remove||preview word, /tc guild except Guild Name, /tc guild defaults")
        end
    elseif cmd == "name" then
        local action, text = FirstWord(rest)
        action = lower(action)
        if action == "add" and text ~= "" then
            TC.Print(TC.AddNameWord(text) and ('Players whose name contains "' .. lower(text) .. '" are muted.') or "Already on the list.")
        elseif action == "remove" and text ~= "" then
            TC.Print(TC.RemoveNameWord(text) and ('Removed "' .. lower(text) .. '".') or "Not on the list.")
        else
            TC.Print("Name keywords: " .. (TC.db.nameWords[1] and table.concat(TC.db.nameWords, ", ") or "none") .. ". /tc name add||remove word")
        end
    elseif cmd == "check" then
        if rest == "" then return UI.Show("check") end
        local display = TC.QueueCheck(rest)
        if display then TC.Print(display .. " is first in the check queue. Press Next /who (or its key binding) to look them up.") end
    elseif cmd == "share" then
        local ok, why = TC.ShareLists(rest)
        if not ok then TC.Print(why) end
    elseif cmd == "net" then
        local action = lower(rest)
        local d = TC.DiagData() or { netCapture = {} }
        if action == "on" or action == "all" or action == "here" or action == "off" then
            TC.SetListen(action == "on" and "here" or action)
            TC.Print("OlympusNet listening: " .. TC.ListenText() .. ".")
            if action ~= "off" then
                TC.Print("|cffff5050Olympus can see you in their channel's member list and may target you for "
                    .. "harassment.|r Use a disposable alt; the Advanced tab explains. /tc net off stops it.")
            end
        elseif action == "raw" then
            TC.net.raw = not TC.net.raw
            TC.SetCapture(TC.net.raw)
            TC.Print("OlympusNet raw capture " .. (TC.net.raw and "on: every message is printed and saved." or "off."))
        elseif action == "capture" then
            TC.SetCapture(not d.capturing)
            TC.Print(format("OlympusNet capture %s (%d messages saved, the last %d are kept).",
                d.capturing and "on: every message is saved" or "off", #d.netCapture, 1000))
        elseif action == "clear" then
            d.netCapture, d.netSamples = {}, {}
            TC.Print("Saved OlympusNet capture and samples cleared.")
        elseif action == "forget" then
            local n = TC.ForgetNetData()
            TC.Print(format("Forgot %d Olympus guilds not seen in game and %d other OlympusNet guilds on this realm. "
                .. "Players the game showed in a muted guild stay muted.", n.guilds, n.netGuilds))
        else
            TC.Print(format("OlympusNet: %s, channel %s; %d messages saved. /tc net on||all||off||raw||capture||clear||forget",
                TC.ListenText(), TC.net.joined or "not joined", #d.netCapture))
        end
    elseif cmd == "meme" then
        local action, more = FirstWord(rest)
        local word, after = FirstWord(more)
        local minutes = match(after, "^%d*")
        action = lower(action)
        if action == "mute" and word ~= "" then
            local w, removed = TC.MuteMemeWord(word, tonumber(minutes) or TC.MEME_SHORT)
            TC.Print(w and TC.MemeMuteReport(w, tonumber(minutes) or TC.MEME_SHORT, removed)
                or "Meme words need at least 3 letters.")
        elseif action == "unmute" and word ~= "" then
            TC.UnmuteMemeWord(lower(word))
            TC.Print(format('Meme word "%s" unmuted.', lower(word)))
        else
            local memes = TC.MemeWords(3)
            if not memes[1] then TC.Print("No word stands out in the last " .. TC.MEME_WINDOW .. " messages.") end
            for _, m in ipairs(memes) do
                TC.Print(format("%s: %d of the last %d messages, %d players", m.word, m.messages, TC.MEME_WINDOW, m.players))
            end
            for _, m in ipairs(TC.MutedMemeWords()) do
                TC.Print(format("muted: %s (%d min left)", m.word, math.ceil(m.left / 60)))
            end
        end
    elseif cmd == "guilds" then
        local list = TC.OlympusCoverage()
        TC.Print(format("Muted guild index: %d guilds.", #list))
        for _, g in ipairs(list) do
            TC.Print(format("  %s  %d known / %s members%s%s", g.guild, g.known, g.total and tostring(g.total) or "?",
                g.faction and ("  " .. g.faction) or "", g.confirmed and "" or "  (not seen in game yet)"))
        end
    elseif cmd == "key" then
        local action = lower(rest)
        if action == "on" or action == "off" then TC.SetKeyWho(action == "on") end
        TC.Print("Any key press runs the next /who: " .. (TC.db.settings.keyWho and "on." or "off.") .. " /tc key on||off")
    elseif cmd == "diag" then
        if not TC.HealthLines then
            TC.Print("Diagnostics aren't loaded: exit the game fully and start it again.")
        elseif lower(rest) == "report" then
            UI.ShowTextBox("TolerableChat diagnostics (Ctrl+A, Ctrl+C to copy)", TC.DiagReport())
        else
            PrintLines(TC.HealthLines())
            TC.Print("/tc diag report  shows everything, ready to copy.")
        end
    elseif cmd == "advanced" or cmd == "watcher" or cmd == "olympus" then
        UI.Show("advanced")
    elseif cmd == "recheck" then
        if lower(rest) == "left" then
            local n = TC.ReleaseLeftGuild()
            TC.Print(format("Let go of %d guild mute%s: players the game has since shown in an unmuted guild.", n,
                n == 1 and "" or "s"))
        elseif rest ~= "" then
            local who, was = TC.RecheckGuild(rest)
            TC.Print(who and format("%s: the guild mute%s is lifted until the game shows their guild again; first "
                .. "for the next /who.", who, was and (" for " .. was) or "") or "Not a known player: /tc recheck Name")
        else
            TC.Print(format("/tc recheck Name  or  /tc recheck left (%d have left the muted guild they were muted for).",
                TC.CountLeftGuild()))
        end
    elseif cmd == "status" then
        if rest == "" then return TC.Print("/tc status Name") end
        PrintLines(TC.Status(rest))
    elseif cmd == "term" then
        TermCommand(rest)
    elseif cmd == "test" then
        if rest == "" then return TC.Print("/tc test text") end
        PrintLines(TC.SelfTest(rest))
    elseif cmd == "log" or cmd == "flagged" then
        UI.Show(cmd)
    elseif cmd == "tally" then
        PrintLines(TC.Tally())
    elseif cmd == "on" or cmd == "off" then
        TC.db.settings.enabled = cmd == "on"
        TC.Notify("Settings")
        TC.Print(cmd == "on" and "On." or "Off: every message is shown until you turn it back on.")
    elseif cmd == "debug" then
        TC.db.settings.debug = not TC.db.settings.debug
        TC.Print("Debug output " .. (TC.db.settings.debug and "on: each hidden message is printed with its reason." or "off."))
    elseif TC.ExtraCommand and TC.ExtraCommand(cmd, rest) then
        -- phase 2 and 3 commands
    else
        PrintLines(HELP)
    end
end
