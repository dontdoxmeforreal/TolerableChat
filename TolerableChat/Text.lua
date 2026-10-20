-- Text preparation (spec 6.3) and the clear-game-talk shield (6.6).
--
-- Prepare(raw) strips formatting, lowercases, blanks out game names that a term would match
-- (GameNames.lua) and, with folding on, also builds a folded copy: "t.r.u.m.p" -> "trump",
-- "g4y" -> "gay", "gayyy" -> "gayy", "7rump2028" -> "trump2028". Terms are matched against both
-- copies, so a term that itself contains a digit ("tyler1", "1488") or a triple letter ("kkk") still
-- matches. A number glued to a word ("trump2028", "2028trump") is looked past (EndsWord, Unglue).

local _, TC = ...

local find, gsub, lower, sub, byte, match, gmatch = string.find, string.gsub, TC.Lower, string.sub,
    string.byte, string.match, string.gmatch
local concat = table.concat

-- A letter, digit or non-ASCII byte: what "standing alone" means for Word terms.
local function IsWordByte(b)
    return b ~= nil and (b >= 128 or (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end
TC.IsWordByte = IsWordByte

-- A letter or non-ASCII byte.
local function IsLetterByte(b)
    return b ~= nil and (b >= 128 or (b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end

-- True when the word ends after position e: no letter or digit follows, or only a number glued to a
-- letter ("trump2028"; "tyler12" isn't "tyler1").
local function EndsWord(s, e)
    local b = byte(s, e + 1)
    if not IsWordByte(b) then return true end
    if b > 57 or not IsLetterByte(byte(s, e)) then return false end
    local _, de = find(s, "^%d+", e + 1)
    return not IsWordByte(byte(s, de + 1))
end
TC.EndsWord = EndsWord

-- A word with a number glued to either end ("trump2028", "2028trump"): how many digits lead it, and
-- the word without the numbers. Nil for any other word.
local function Unglue(word)
    local first, last = byte(word, 1), byte(word, -1)
    if (first < 48 or first > 57) and (last < 48 or last > 57) then return end
    local lead, stem = match(word, "^(%d*)(.-)%d*$")
    if stem ~= "" and stem ~= word then return #lead, stem end
end
TC.Unglue = Unglue

-- True when s has a digit next to a letter somewhere, so Unglue might find something. Prepare works
-- it out once per text (one scan; this runs on every chat line).
function TC.HasGlued(s)
    local a, b = find(s, "%d+")
    while a do
        if IsLetterByte(byte(s, a - 1)) or IsLetterByte(byte(s, b + 1)) then return true end
        a, b = find(s, "%d+", b + 1)
    end
    return false
end

---------------------------------------------------------------------------------------------------
-- 1. Strip formatting

-- Link kinds that count as real game links: items, spells, recipes ("enchant" is a Classic profession
-- recipe), professions ("trade:Player-...:spellID:skillLine") and quests ("questie" is Questie's).
local GAME_LINKS = { item = true, spell = true, enchant = true, trade = true, quest = true, questie = true }

-- Returns the visible text ("[Linen Cloth] x20") and whether it held a real game link.
function TC.StripFormatting(raw)
    local gameLink = false
    local s = gsub(raw, "||", "\1")
    if find(s, "|", 1, true) then
        s = gsub(s, "|H([^|]*)|h(.-)|h", function(data, text)
            local kind = match(data, "^(%a+):")
            -- a real link carries a non-zero number: the item or spell ID
            if kind and GAME_LINKS[kind] and find(data, ":0*[1-9]") then gameLink = true end
            return text
        end)
        s = gsub(s, "|c%x%x%x%x%x%x%x%x", "")
        s = gsub(s, "|cn[^:|]*:", "")
        s = gsub(s, "|r", "")
        s = gsub(s, "|T.-|t", "")
        s = gsub(s, "|A.-|a", "")
        s = gsub(s, "|K.-|k", "?")
    end
    s = gsub(s, "\1", "|")
    s = gsub(s, "[ \t\n\r\f\v]+", " ")   -- not %s: see TC.WS
    s = gsub(gsub(s, "^ ", ""), " $", "")
    return s, gameLink
end

---------------------------------------------------------------------------------------------------
-- 3. Fold obfuscation

-- Unicode tricks, undone for matching only (the visible text and the spam rules keep the original):
-- invisible characters (zero-width spaces and joiners, word joiner, BOM, soft hyphen) are dropped,
-- fullwidth letters become ASCII, Cyrillic and Greek look-alikes become the Latin letter they imitate
-- ("trаnny" with a Cyrillic а), and accented Latin letters lose their accents ("trànny").
local UNI = {}
local function MapChars(target, chars)
    for ch in gmatch(chars, "[\192-\247][\128-\191]*") do UNI[ch] = target end
end
for _, ch in ipairs({ "\226\128\139", "\226\128\140", "\226\128\141", "\226\128\142", "\226\128\143", "\226\129\160",
                      "\239\187\191", "\194\173" }) do
    UNI[ch] = ""
end
for cp = 0xFF01, 0xFF5E do   -- fullwidth ! to ~
    UNI[string.char(0xEF, 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)] = string.char(cp - 0xFEE0)
end
local LOOKALIKES = {
    a = "аАαΑ", b = "вВΒ", c = "сС", d = "ԁ", e = "еЕёЁεΕ", g = "ɡ", h = "нНΗ", i = "іІїЇιΙ", j = "јЈ",
    k = "кКκΚ", m = "мМΜ", n = "Νпη", o = "оОοΟ", p = "рРρΡ", s = "ѕЅ", t = "тТτΤ", u = "υ", v = "ν",
    x = "хХχΧ", y = "уУΥ", z = "Ζ",
}
local ACCENTS = {
    a = "àáâãäåāăąÀÁÂÃÄÅĀĂĄ", c = "çćĉċčÇĆĈĊČ", d = "ďđĎĐ", e = "èéêëēĕėęěÈÉÊËĒĔĖĘĚ", g = "ĝğġģĜĞĠĢ",
    h = "ĥħĤĦ", i = "ìíîïĩīĭįıÌÍÎÏĨĪĬĮİ", j = "ĵĴ", k = "ķĶ", l = "ĺļľŀłĹĻĽĿŁ", n = "ñńņňÑŃŅŇ",
    o = "òóôõöøōŏőÒÓÔÕÖØŌŎŐ", r = "ŕŗřŔŖŘ", s = "śŝşšŚŜŞŠ", t = "ţťŧŢŤŦ", u = "ùúûüũūŭůűųÙÚÛÜŨŪŬŮŰŲ",
    w = "ŵŴ", y = "ýÿŷÝŸŶ", z = "źżžŹŻŽ",
}
for letter, chars in pairs(LOOKALIKES) do MapChars(letter, chars) end
for letter, chars in pairs(ACCENTS) do MapChars(letter, chars) end

-- The text with the Unicode tricks above undone, lowercased (A-Z only, as everywhere).
function TC.UnicodeFold(s)
    if not find(s, "[\128-\255]") then return s end
    return lower((gsub(s, "[\192-\247][\128-\191]*", UNI)))
end

local function IsSingleLetter(w)
    return #w == 1 and find(w, "^%a$") ~= nil
end

-- What may sit between single letters that are joined: dots, spaces, - _ * / , ~ ' + | : ;
local SEPARATORS = "[%. %-_%*/,~'%+|:;]"

local function IsJoinSeparator(sep)
    return sep ~= "" and find(sep, "^" .. SEPARATORS .. "+$") ~= nil
end

-- "t.r.u.m.p", "t r u m p" and "t-r-a-n-n-y" -> "trump", "tranny".
local function JoinSingleLetters(s)
    if not find(s, "%f[%w\128-\255]%a" .. SEPARATORS .. "+%a%f[^%w\128-\255]") then return s end
    local words, seps, n = {}, {}, 0
    for w, sep in gmatch(s, "([%w\128-\255]*)([^%w\128-\255]*)") do
        if w ~= "" or sep ~= "" then
            n = n + 1
            words[n], seps[n] = w, sep
        end
    end
    local out, i = {}, 1
    while i <= n do
        local w = words[i]
        if IsSingleLetter(w) and i < n and IsSingleLetter(words[i + 1]) and IsJoinSeparator(seps[i]) then
            local run = { w }
            while i < n and IsSingleLetter(words[i + 1]) and IsJoinSeparator(seps[i]) do
                i = i + 1
                run[#run + 1] = words[i]
            end
            out[#out + 1] = concat(run) .. seps[i]
        else
            out[#out + 1] = w .. seps[i]
        end
        i = i + 1
    end
    return concat(out)
end

local DIGIT_LETTERS = { ["1"] = "i", ["3"] = "e", ["4"] = "a", ["0"] = "o", ["5"] = "s", ["7"] = "t", ["8"] = "b",
                        ["9"] = "g", ["@"] = "a" }

local function FoldWord(word)
    if find(word, "[013457-9@]") and find(word, "[%a\128-\255]") then
        -- A number at either end with a 2 or 6 in it (digits that stand for no letter) stays a number,
        -- so "7rump2028" folds to "trump2028" and the matcher looks past the year.
        local lead, body, tail = "", word, ""
        if find(word, "[26]") then
            lead, body, tail = match(word, "^(%d*)(.-)(%d*)$")
            if not find(lead, "[26]") then lead, body = "", lead .. body end
            if not find(tail, "[26]") then body, tail = body .. tail, "" end
        end
        return lead .. gsub(body, "[013457-9@]", DIGIT_LETTERS) .. tail
    end
end

-- s must already be lowercase.
function TC.Fold(s)
    s = TC.UnicodeFold(s)
    s = JoinSingleLetters(s)
    if find(s, "!", 1, true) then s = gsub(s, "([a-z])!([a-z])", "%1i%2") end   -- "k!ll"
    if find(s, "$", 1, true) then s = gsub(s, "%$([a-z])", "s%1") end           -- "$hekels"
    if find(s, "[013457-9@]") then s = gsub(s, "[%w@\128-\255]+", FoldWord) end
    -- Three or more of a letter become two. Lua can't repeat a back-reference, so squeeze until done.
    while find(s, "(%a)%1%1") do s = gsub(s, "(%a)%1%1", "%1%1") end
    -- A z for a plural s: "libtardz", "gayz".
    if find(s, "z", 1, true) then s = gsub(s, "([a-z][a-z][a-z])z%f[^%w\128-\255]", "%1s") end
    return s
end

---------------------------------------------------------------------------------------------------
-- 4. Blank out game names (GameNames.lua: "brutal politics", "vance undergloom")

local nameIndex, looseNames = {}, {}

function TC.BuildNameIndex(names)
    nameIndex, looseNames = {}, {}
    for _, name in ipairs(names or {}) do
        local first = match(name, "^[%w\128-\255]+")
        if first then
            local list = nameIndex[first] or {}
            nameIndex[first] = list
            list[#list + 1] = name
        else
            looseNames[#looseNames + 1] = name
        end
    end
    for _, list in pairs(nameIndex) do
        table.sort(list, function(a, b) return #a > #b end)
    end
end

-- Returns the text with every listed game name replaced by a space, and the names found. A number
-- glued to a name doesn't hide it, as it doesn't hide a term (Matcher.lua MatchText). glued is
-- TC.HasGlued(s), or true when unsure.
function TC.BlankGameNames(s, glued)
    local spans, lastEnd
    if glued == nil then glued = TC.HasGlued(s) end
    for pos, word in gmatch(s, "()([%w\128-\255]+)") do
        local list = nameIndex[word]
        if not list and glued then
            local lead, stem = Unglue(word)
            if stem then pos, list = pos + lead, nameIndex[stem] end
        end
        if list and (not lastEnd or pos > lastEnd) then
            for i = 1, #list do
                local name = list[i]
                local e = pos + #name - 1
                if sub(s, pos, e) == name and EndsWord(s, e) then
                    spans = spans or {}
                    spans[#spans + 1] = pos
                    spans[#spans + 1] = e
                    lastEnd = e
                    break
                end
            end
        end
    end
    for _, name in ipairs(looseNames) do
        local init = 1
        while true do
            local a, b = find(s, name, init, true)
            if not a then break end
            if not IsWordByte(byte(s, a - 1)) and not IsWordByte(byte(s, b + 1)) then
                spans = spans or {}
                spans[#spans + 1] = a
                spans[#spans + 1] = b
            end
            init = a + 1
        end
    end
    if not spans then return s end
    local found, out, at = {}, {}, 1
    -- Loose names can come after indexed ones; blank in text order and skip overlaps.
    local order = {}
    for i = 1, #spans, 2 do order[#order + 1] = { spans[i], spans[i + 1] } end
    table.sort(order, function(a, b) return a[1] < b[1] end)
    for _, span in ipairs(order) do
        if span[1] >= at then
            out[#out + 1] = sub(s, at, span[1] - 1)
            out[#out + 1] = " "
            found[#found + 1] = sub(s, span[1], span[2])
            at = span[2] + 1
        end
    end
    out[#out + 1] = sub(s, at)
    return concat(out), found
end

---------------------------------------------------------------------------------------------------
-- Prepare: everything the matcher and the shield need from one message.

-- Returns { visible, lower, base, folded, gameLink, blanked, glued, foldedGlued }. base is the
-- lowercased text with game names blanked; folded (when fold is set and it changes something) is its
-- folded copy. glued says whether lower (so also base) has a number glued to a word, foldedGlued the
-- same for folded (folding can glue one on by dropping a zero-width space before "2028").
function TC.Prepare(raw, fold)
    local visible, gameLink = TC.StripFormatting(raw)
    local low = lower(visible)
    local glued = TC.HasGlued(low)
    local base, blanked = TC.BlankGameNames(low, glued)
    local prep = { visible = visible, lower = low, base = base, gameLink = gameLink, blanked = blanked,
                   glued = glued }
    if fold then
        local folded = TC.Fold(base)
        if folded ~= base then
            prep.foldedGlued = TC.HasGlued(folded)
            local blankedAgain, more = TC.BlankGameNames(folded, prep.foldedGlued)
            prep.folded = blankedAgain
            if more then
                prep.blanked = prep.blanked or {}
                for _, n in ipairs(more) do prep.blanked[#prep.blanked + 1] = n end
            end
        end
    end
    return prep
end

---------------------------------------------------------------------------------------------------
-- Clear game talk (6.6), ported from the [game] section of ChatArchive\filter-rules.txt.
-- It shields a message from the sender rule only, never from a term. Word edges here follow the
-- Python \b of filter_chat.py: letters, digits, underscore and non-ASCII bytes are word bytes.

local function Set(list)
    local t = {}
    for _, v in ipairs(list) do t[v] = true end
    return t
end

local function WithPlural(list)
    local out = {}
    for _, v in ipairs(list) do
        out[#out + 1] = v
        out[#out + 1] = v .. "s"
    end
    return out
end

local GAME_WORDS = Set(WithPlural({ "paladin", "pally", "hunter", "rogue", "priest", "shaman", "shammy", "mage",
    "warlock", "druid" }))
for word in pairs(Set({
    -- roles, mechanics
    "ele", "enh", "resto", "tank", "healer", "healers", "heals", "dps", "talent", "talents",
    "nerf", "nerfs", "nerfed", "nerfing", "buff", "buffs", "buffed", "buffing", "cooldown", "cooldowns", "cd",
    "proc", "procs", "crit", "spells", "spellpower", "spellhit", "spellcrit",
    "glow", "totem", "totems", "mount", "mounts", "zep", "zeppelin", "zepelin", "addon", "addons",
    "actionbar", "actionbars", "stealth", "aggrend", "dungeon", "dungeons", "raid", "raids", "raiding", "raider",
    "raiders", "twink", "twinks", "transmute", "salv", "enslave",
    -- dungeons and raids
    "rfc", "rfk", "rfd", "sfk", "bfd", "wc", "deadmines", "shadowfang", "blackfathom", "stockade", "stockades",
    "razorfen", "ulda", "uldaman", "zf", "zulfarrak", "mara", "maraudon", "brd", "lbrs", "ubrs", "blackrock",
    "strat", "stratholme", "scholo", "scholomance", "mc", "ony", "onyxia", "bwl", "zg", "zulgurub", "aq20", "aq40",
    -- cities and zones
    "org", "orgrimmar", "ironforge", "stormwind", "undercity", "gadgetzan", "ratchet", "everlook", "crossroads",
    "xroads", "barrens", "tanaris", "felwood", "winterspring", "silithus", "feralas", "desolace", "ashenvale",
    "stv", "stranglethorn", "hinterlands", "arathi", "alterac", "hillsbrad", "silverpine", "tirisfal", "durotar",
    "mulgore", "elwynn", "westfall", "duskwood", "redridge", "badlands", "dustwallow", "stonetalon", "azshara",
    "moonglade", "ungoro", "plaguelands",
})) do GAME_WORDS[word] = true end

-- Trade shorthand (6.6): game talk, except from a spamming sender (6.5).
local TRADE_WORDS = { wts = true, wtb = true }
for word in pairs(TRADE_WORDS) do GAME_WORDS[word] = true end

local GAME_PREFIXES = { "gnomer", "naxx" }   -- gnomeregan, naxxramas
local GAME_PHRASES = { "ghost wolf", "spell power", "spell damage", "spell hit", "spell crit", "action bar",
    "action bars", "wailing caverns", "scarlet monastery", "zul'farrak", "sunken temple", "dire maul",
    "molten core", "zul'gurub", "aq 20", "aq 40", "thunder bluff", "booty bay", "searing gorge",
    "burning steppes", "blasted lands", "thousand needles", "un'goro", "loch modan", "dun morogh" }
local HOLY_NEXT = Set(WithPlural({ "priest", "pally", "paladin", "spec", "light", "nova", "fire", "shock",
    "strike", "wrath", "power" }))
-- "warrior" except in "keyboard warrior", "social justice warrior" and "culture warrior".
local NOT_WARRIOR = { "justice ", "keyboard ", "culture " }

local function IsShieldByte(b)
    return b == 95 or IsWordByte(b)   -- 95 is "_"
end

-- The game-talk word in s (lowercase visible text), or nil.
function TC.GameTalkWord(s)
    for pos, word in gmatch(s, "()([%w_\128-\255]+)") do
        if GAME_WORDS[word] then return word end
        if word == "warrior" or word == "warriors" then
            local excluded = false
            for _, before in ipairs(NOT_WARRIOR) do
                if pos > #before and sub(s, pos - #before, pos - 1) == before then excluded = true end
            end
            if not excluded then return word end
        elseif word == "holy" then
            local nextWord = match(s, "^ ([%w_\128-\255]+)", pos + 4)
            if nextWord and HOLY_NEXT[nextWord] then return "holy " .. nextWord end
        elseif word == "rank" then
            if find(s, "^ %d", pos + 4) and not IsShieldByte(byte(s, pos + 6)) then return sub(s, pos, pos + 5) end
        else
            for _, prefix in ipairs(GAME_PREFIXES) do
                if sub(word, 1, #prefix) == prefix then return word end
            end
        end
    end
    for _, phrase in ipairs(GAME_PHRASES) do
        local init = 1
        while true do
            local a, b = find(s, phrase, init, true)
            if not a then break end
            if not IsShieldByte(byte(s, a - 1)) and not IsShieldByte(byte(s, b + 1)) then return phrase end
            init = a + 1
        end
    end
    return nil
end

-- Questie's quest tag as typed text: "[[29] WANTED: Arnak Grimtotem (5147)]". Players with
-- Questie see it as a quest link; its filter may run before or after this one.
local QUESTIE_TAG = "%[%[%d+%] [^%[%]]- %(%d+%)%]"

-- Why the prepared message is clear game talk ("link", "healer"), or nil.
function TC.GameTalk(prep)
    if prep.gameLink or find(prep.visible, QUESTIE_TAG) then return "game link" end
    return TC.GameTalkWord(prep.lower)
end

-- True for a trade post: one with WTS or WTB in it.
function TC.IsTradePost(prep)
    for word in gmatch(prep.lower, "[%w_\128-\255]+") do
        if TRADE_WORDS[word] then return true end
    end
    return false
end

---------------------------------------------------------------------------------------------------
-- Symbol and script spam (6.5a): more than TC.SYMBOL_PERCENT % of the characters other than spaces
-- not letters, digits or emoji, in a message of at least TC.SYMBOL_MIN such characters, or of any
-- length with at least TC.SCRIPT_MIN letters of another script (a few Chinese characters say a lot).
-- Latin letters count, accented ones too; other scripts, box drawing, braille art and punctuation
-- don't. Short replies like "..." are never spam.

local function CodePoint(ch)
    local b1, b2, b3, b4 = byte(ch, 1, 4)
    if not b2 then return b1 end
    if b1 < 0xE0 then return (b1 - 0xC0) * 64 + (b2 - 0x80) end
    if not b3 then return 0xFFFD end
    if b1 < 0xF0 then return ((b1 - 0xE0) * 64 + (b2 - 0x80)) * 64 + (b3 - 0x80) end
    if not b4 then return 0xFFFD end
    return (((b1 - 0xF0) * 64 + (b2 - 0x80)) * 64 + (b3 - 0x80)) * 64 + (b4 - 0x80)
end

local function IsSpace(cp)
    return cp == 0xA0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200A) or cp == 0x2028 or cp == 0x2029
        or cp == 0x202F or cp == 0x205F or cp == 0x3000 or cp == 0x200D or cp == 0xFE0F
end

-- Letters of scripts other than Latin: Greek to the Indic scripts, Hangul, kana, CJK, fullwidth forms.
local function IsOtherScript(cp)
    return (cp >= 0x370 and cp <= 0x1FFF) or (cp >= 0x3040 and cp <= 0x9FFF) or (cp >= 0xAC00 and cp <= 0xD7AF)
        or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFF21 and cp <= 0xFF5A) or (cp >= 0xFF66 and cp <= 0xFFDC)
        or (cp >= 0x20000 and cp <= 0x3FFFF)
end

local function IsLetterOrEmoji(cp)
    return (cp >= 0xC0 and cp <= 0x24F and cp ~= 0xD7 and cp ~= 0xF7)   -- Latin letters with accents
        or (cp >= 0x1F000 and cp <= 0x1FAFF) or (cp >= 0x2600 and cp <= 0x27BF) or (cp >= 0x2B00 and cp <= 0x2BFF)
end

-- A word mixing Latin letters with Cyrillic or Greek ones ("FАSТ LЕVЕLІNG" with Cyrillic А, Т, Е, І):
-- look-alike letters used to slip past filters, as gold sellers' ads do. Real Russian or Greek words
-- are all one script. UTF-8 lead bytes CE-D3 (and CD B0-BF) are Greek and Cyrillic.
local function MixedScriptWord(s)
    if not find(s, "[\205-\211]") then return false end
    for word in gmatch(s, "[%w\128-\255]+") do
        if find(word, "[A-Za-z]") and (find(word, "[\206-\211][\128-\191]") or find(word, "\205[\176-\191]")) then
            return true
        end
    end
    return false
end
TC.MixedScriptWord = MixedScriptWord

function TC.IsSymbolSpam(s)
    if #s < 2 then return false end
    if MixedScriptWord(s) then return true, "mixed" end
    local good, bad, script = 0, 0, 0
    if not find(s, "[\128-\255]") then
        local _, alnum = gsub(s, "%w", "")
        local _, spaces = gsub(s, "%s", "")
        good, bad = alnum, #s - alnum - spaces
    else
        for ch in gmatch(s, "[%z\1-\127\194-\244][\128-\191]*") do
            local b = byte(ch)
            if b < 128 then
                if find(ch, "^%w$") then good = good + 1 elseif not find(ch, "^%s$") then bad = bad + 1 end
            else
                local cp = CodePoint(ch)
                if IsLetterOrEmoji(cp) then
                    good = good + 1
                elseif not IsSpace(cp) then
                    bad = bad + 1
                    if IsOtherScript(cp) then script = script + 1 end
                end
            end
        end
    end
    local total = good + bad
    return (total >= TC.SYMBOL_MIN or script >= TC.SCRIPT_MIN) and bad * 100 > TC.SYMBOL_PERCENT * total
end
