-- Term list (spec 6.1, 6.2): the default list from Terms.lua plus the user's own terms.
--
-- Match types: word (standing alone), phrase (exact text, spaces included), contains (anywhere,
-- even inside words), allof (every comma-separated part present, any order) and pattern (a Lua
-- pattern matched against the lowercase text). A term's key is "kind:text"; disabled terms and hit
-- counts are kept by key, so a newer default list never overwrites the user's changes.

local _, TC = ...

local find, gsub, lower, sub, byte, match, gmatch, format = string.find, string.gsub, TC.Lower,
    string.sub, string.byte, string.match, string.gmatch, string.format
local IsWordByte, EndsWord, Unglue = TC.IsWordByte, TC.EndsWord, TC.Unglue

TC.KINDS = { "word", "phrase", "contains", "allof", "pattern" }
-- Labels say where a term can match (the editor, /tc test, the log); the keys stay the same.
TC.KIND_LABEL = { word = "Whole word", phrase = "Exact text", contains = "Anywhere", allof = "All of", pattern = "Pattern" }

-- What each match type does, in one line each, for the term editor (the hint under the list and the
-- Match: button's tooltip). The pattern line is the syntax and what Lua patterns can't do.
TC.KIND_SUMMARY = {
    word = "Whole word: the word or phrase standing alone, like \\bword\\b. t.r.u.m.p and trump2028 count; "
        .. "trumpet doesn't.",
    phrase = "Exact text: the text anywhere, spaces included, even inside a longer word. Put spaces in to mark "
        .. "the edges: \" eu \".",
    contains = "Anywhere: the text anywhere, even inside a longer word: cat also matches category.",
    allof = "All of: every comma-separated part appears somewhere, in any order: free, gold, cheap.",
    pattern = "Pattern (Lua, like a simple regular expression): %f[%w] word start (\\b), %a letter, %d digit, "
        .. "%w letter or digit, [a@] a or @, [^%w] not a letter or digit, . any character, + one or more, * zero "
        .. "or more, - as few as possible, ? optional, ^ and $ start and end. No a||b, {2,3}, repeated groups "
        .. "or lookarounds: add one term per alternative. At most 2 open-ended parts (%a+, .-) and 10 optional "
        .. "ones (x?).",
}

-- What a term matches, in words, for the term editor's tooltip. Every type is also checked against a
-- copy with spelling tricks undone (dots, digits, accents, look-alike letters).
function TC.KindHelp(t)
    local text, help = t.text or "", nil
    if t.kind == "word" then
        help = format('Whole word: "%s" on its own, like \\b%s\\b in a regular expression. Not when it\'s part '
            .. 'of a longer word%s.', text, text,
            find(text, " ") and "" or format(', though a number stuck on counts ("%s2028")', text))
        if #text >= TC.WORDFORM_MIN and find(text, "^[a-z]+$") then
            help = help .. " At 5 or more letters it also matches starred and stretched spellings."
        end
    elseif t.kind == "phrase" then
        help = format('Exact text: "%s" anywhere in the message, spaces included, even as part of a longer word '
            .. '(no \\b at either end).', text)
    elseif t.kind == "contains" then
        help = format('Anywhere: "%s" anywhere in the message, even as part of a longer word (no \\b at either '
            .. 'end).', text)
    elseif t.kind == "allof" then
        help = format('All of: every comma-separated part of "%s" appears somewhere in the message, in any order.',
            text)
    else
        help = format('Pattern: the Lua pattern "%s", a simpler cousin of a regular expression, on the lowercase '
            .. 'text. %%f[%%w] means the start of a word (like \\b), %%w a letter or digit, [a@] "a or @", + "one '
            .. 'or more", . any character. Lua patterns have no a||b, {2,3} or lookarounds.', text)
    end
    return help .. "\n\nSpelling tricks (dots, digits, accents, look-alike letters) are undone first."
end

function TC.TermKey(kind, text)
    return kind .. ":" .. text
end

local function Trim(s)
    return (gsub(gsub(s, "^[ \t\n\r\f\v]+", ""), "[ \t\n\r\f\v]+$", ""))
end

-- The stored form of a term's text: lowercase; trimmed except for phrases.
function TC.NormalizeTermText(kind, text)
    text = lower(tostring(text or ""))
    if kind ~= "phrase" then text = Trim(text) end
    return text
end

-- The index of the "]" closing the set that starts at i.
local function SetEnd(p, i)
    local j = i + 1
    if sub(p, j, j) == "^" then j = j + 1 end
    if sub(p, j, j) == "]" then j = j + 1 end   -- a "]" right after "[" or "[^" is a member
    while j <= #p do
        local c = sub(p, j, j)
        if c == "%" then
            j = j + 2
        elseif c == "]" then
            return j
        else
            j = j + 1
        end
    end
    return #p
end

-- How much work a pattern can make on a long line: its open-ended parts (".-", "%a+", "[^,]*": a
-- class or set repeated) and its optional parts ("s?"). Each one multiplies the tries Lua makes when a
-- line almost matches, and a pattern runs on every chat line, so a few are allowed and no more.
-- The default patterns have at most one open-ended part.
TC.PATTERN_OPEN_MAX, TC.PATTERN_OPTIONAL_MAX = 2, 10

function TC.PatternCost(p)
    local open, optional, i, n = 0, 0, 1, #p
    while i <= n do
        local c = sub(p, i, i)
        local last, class, quantifiable = i, false, true
        if c == "%" then
            local nc = sub(p, i + 1, i + 1)
            if nc == "b" then
                last, quantifiable = i + 3, false
            elseif nc == "f" then
                last, quantifiable = SetEnd(p, i + 2), false
            else
                last, class = i + 1, find(nc, "^[a-zA-Z]$") ~= nil   -- %a, %w ...; not %% or %1
            end
        elseif c == "[" then
            last, class = SetEnd(p, i), true
        elseif c == "." then
            class = true
        elseif (c == "^" and i == 1) or (c == "$" and i == n) or c == "(" or c == ")" then
            quantifiable = false
        end
        local q = quantifiable and sub(p, last + 1, last + 1) or ""
        if q == "*" or q == "+" or q == "-" then
            if class then open = open + 1 end
            last = last + 1
        elseif q == "?" then
            optional = optional + 1
            last = last + 1
        end
        i = last + 1
    end
    return open, optional
end

-- Checks a pattern before it is saved. Returns true, or nil and a readable reason.
function TC.ValidatePattern(p)
    if p == "" then return nil, "The pattern is empty." end
    if find(p, "%%[ACDGLPSUWXZ]") then
        return nil, "Capital classes such as %W aren't allowed: patterns are matched against lowercase text. "
            .. "For \"not a letter or digit\" write [^%w]."
    end
    -- Regular-expression habits Lua patterns don't have: refused, so they don't silently match nothing.
    if find(p, "|", 1, true) then
        return nil, "Lua patterns have no a||b (either/or): add one term for each alternative."
    end
    if find(p, "{%d") then
        return nil, "Lua patterns have no counts like {2,3}: repeat the part, or use + (one or more)."
    end
    if find(p, "(?", 1, true) or find(p, "\\", 1, true) then
        return nil, "That looks like a regular expression (lookarounds, \\b, \\d...). Lua patterns use %f[%w] for "
            .. "a word start, %d for a digit, %a for a letter and %w for either."
    end
    local open, optional = TC.PatternCost(p)
    if open > TC.PATTERN_OPEN_MAX then
        return nil, format("This pattern has %d open-ended parts such as .- or %%a+; at most %d are allowed, because "
            .. "each one multiplies the work on every chat line.", open, TC.PATTERN_OPEN_MAX)
    end
    if optional > TC.PATTERN_OPTIONAL_MAX then
        return nil, format("This pattern has %d optional parts (x?); at most %d are allowed, because each one "
            .. "doubles the work on every chat line.", optional, TC.PATTERN_OPTIONAL_MAX)
    end
    local ok, result = pcall(find, "", p)
    if not ok then
        local reason = match(tostring(result), "%((.*)%)") or tostring(result)
        return nil, "Not a valid Lua pattern: " .. reason .. "."
    end
    if result then return nil, "This pattern matches an empty message, so it would hide everything." end
    ok, result = pcall(find, "lf healer for rfc, wts [linen cloth]", p)
    if not ok then return nil, "Not a valid Lua pattern: " .. tostring(result) .. "." end
    return true
end

-- Checks any term before it is saved.
function TC.ValidateTerm(kind, text)
    if not TC.KIND_LABEL[kind] then return nil, "Unknown match type." end
    if Trim(text) == "" then return nil, "The term is empty." end
    if kind == "pattern" then return TC.ValidatePattern(text) end
    if kind == "allof" then
        local parts = 0
        for part in gmatch(text, "[^,]+") do
            if Trim(part) ~= "" then parts = parts + 1 end
        end
        if parts == 0 then return nil, "List at least one part, separated by commas." end
    end
    return true
end

---------------------------------------------------------------------------------------------------
-- Compiling

local compiled, compiledNames

-- Categories a guild's name is never judged by. Place names are hidden in chat as a stand-in for
-- politics talk, but a guild called "Texas Raiders" is no reason to mute or list it.
TC.GUILD_NAME_SKIP = { Nationality = true }

local function NewSet()
    return { index = {}, loose = {}, patterns = {}, allof = {}, plain = {}, stretch = {}, byLen = {} }
end

-- Word forms (1.0.0): a single-word term of at least this many letters also matches when starred
-- ("wh*res": at most half the letters starred) or stretched ("niigger": letters repeated more than in
-- the term). Shorter terms don't: "woops" would be the slur "wops".
TC.WORDFORM_MIN = 5
-- Real words that are stretched forms of a term: "puttin" isn't Putin, "rapped" isn't raped.
TC.STRETCH_SKIP = { puttin = true, bidden = true, rapped = true, rapping = true }

-- A word's letters with repeats squeezed out, and how many times each repeats: "nigger" -> "niger",
-- { 1, 1, 2, 1, 1 }.
local function Runs(w)
    local letters, counts, last, n = {}, {}, nil, 0
    for i = 1, #w do
        local c = sub(w, i, i)
        if c == last then
            counts[n] = counts[n] + 1
        else
            n = n + 1
            letters[n], counts[n], last = c, 1, c
        end
    end
    return table.concat(letters), counts
end
TC.WordRuns = Runs

local function Add(C, kind, text, cat, custom)
    local key = TC.TermKey(kind, text)
    if C.seen[key] then return end
    C.seen[key] = true
    C.total = C.total + 1
    C.byCat[cat] = (C.byCat[cat] or 0) + 1
    local term = { kind = kind, text = text, cat = cat, key = key, custom = custom,
                   offensive = TC.db.settings.offensive[cat] and true or false,
                   noRule = (TC.db.settings.hideOnly[cat] and not TC.db.settings.offensive[cat]) and true or nil }
    if TC.db.terms.disabled[key] or not TC.db.settings.categories[cat] then return end
    C.active = C.active + 1
    -- Unmasked categories are matched against the text with game names left in (MatchPrepared).
    if TC.UNMASKED[cat] then C = C.unmasked end
    if kind == "word" and #text >= TC.WORDFORM_MIN and find(text, "^[a-z]+$") then
        local key, counts = Runs(text)
        term.runs = counts
        C.stretch[key] = C.stretch[key] or {}
        table.insert(C.stretch[key], term)
        C.byLen[#text] = C.byLen[#text] or {}
        table.insert(C.byLen[#text], term)
    end
    if kind == "word" then
        local first = match(text, "^[%w\128-\255]+")
        if first then
            local list = C.index[first] or {}
            C.index[first] = list
            list[#list + 1] = term
        else
            C.loose[#C.loose + 1] = term
        end
    elseif kind == "pattern" then
        if TC.ValidatePattern(text) then C.patterns[#C.patterns + 1] = term end
    elseif kind == "allof" then
        term.parts = {}
        for part in gmatch(text, "[^,]+") do
            part = Trim(part)
            if part ~= "" then term.parts[#term.parts + 1] = part end
        end
        C.allof[#C.allof + 1] = term
    else
        C.plain[#C.plain + 1] = term   -- phrase and contains: plain substring
    end
end

-- The active term set, leaving out the categories in skip (nil: none).
local function Compile(skip)
    local C = NewSet()
    C.seen, C.byCat, C.total, C.active, C.unmasked = {}, {}, 0, 0, NewSet()
    for _, group in ipairs(TC.DefaultTerms) do
        local cat, kind = group[1], group[2]
        if not (skip and skip[cat]) then
            for _, text in ipairs(group[3]) do Add(C, kind, text, cat, false) end
        end
    end
    for _, t in ipairs(TC.db.terms.custom) do
        if type(t) == "table" and TC.KIND_LABEL[t.kind] and type(t.text) == "string" then
            local cat = TC.CategoryName(t.cat)
            cat = TC.db.settings.categories[cat] ~= nil and cat or "Custom"
            if not (skip and skip[cat]) then Add(C, t.kind, t.text, cat, true) end
        end
    end
    -- Longest first, so the trace names "elon musk" rather than "elon".
    for _, set in ipairs({ C, C.unmasked }) do
        for _, list in pairs(set.index) do
            table.sort(list, function(a, b) return #a.text > #b.text end)
        end
    end
    C.seen = nil
    return C
end

-- Rebuilds the active term set after any change to terms, categories or the default list.
function TC.CompileTerms()
    compiled = Compile()
    compiledNames = nil   -- the guild-name set is rebuilt when next needed
    TC.BuildNameIndex(TC.GameNames)
    TC.Notify("Terms")
end

function TC.TermCounts()
    return compiled and compiled.active or 0, compiled and compiled.total or 0
end

-- Terms per category, on or off.
function TC.CategoryCounts()
    return compiled and compiled.byCat or {}
end

---------------------------------------------------------------------------------------------------
-- Matching

local function Loose(s, text)
    local init = 1
    while true do
        local a, b = find(s, text, init, true)
        if not a then return false end
        if not IsWordByte(byte(s, a - 1)) and not IsWordByte(byte(s, b + 1)) then return true end
        init = a + 1
    end
end

local function AllOf(s, parts)
    for _, part in ipairs(parts) do
        if not find(s, part, 1, true) then return false end
    end
    return true
end

-- The term, marked with how it was spelled: { via = "starred", form = "wh*res" }; every field of the
-- term reads through.
local function Via(term, how, form)
    return setmetatable({ via = how, form = form }, { __index = term })
end

local common
local function IsCommonWord(w)
    if not common then
        common = {}
        for _, c in ipairs(TC.CommonWords or {}) do common[c] = true end
    end
    return common[w]
end

-- Starred and stretched forms of single-word terms (TC.WORDFORM_MIN), with the same offensive-first
-- rule as MatchText: found is what has matched so far.
local function WordForms(C, s, found)
    if next(C.stretch) and find(s, "(%a)%1") then
        for word in gmatch(s, "[a-z]+") do
            if #word >= TC.WORDFORM_MIN and find(word, "(%a)%1") then
                -- Squeezed with gsub first (fast); letter counts only when some term has that shape.
                local key = word
                while find(key, "(%a)%1") do key = gsub(key, "(%a)%1", "%1") end
                local list = C.stretch[key]
                local counts = list and not TC.STRETCH_SKIP[word] and not IsCommonWord(word) and select(2, Runs(word))
                for _, term in ipairs(counts and list or {}) do
                    if (not found or term.offensive) and term.text ~= word then
                        local ok = true
                        for i = 1, #counts do
                            if counts[i] < term.runs[i] then ok = false break end
                        end
                        if ok then
                            if term.offensive then return Via(term, "stretched", word) end
                            found = Via(term, "stretched", word)
                        end
                    end
                end
            end
        end
    end
    if find(s, "%*") then
        for token in gmatch(s, "[a-z%*]+") do
            local w = gsub(gsub(token, "^%*+", ""), "%*+$", "")
            local _, stars = gsub(w, "%*", "")
            if stars > 0 and #w >= TC.WORDFORM_MIN and stars * 2 <= #w then
                local shape = "^" .. gsub(w, "%*", "%%a") .. "$"
                for _, term in ipairs(C.byLen[#w] or {}) do
                    if (not found or term.offensive) and find(term.text, shape) then
                        if term.offensive then return Via(term, "starred", w) end
                        found = Via(term, "starred", w)
                    end
                end
            end
        end
    end
    return found
end

-- The matching term, an offensive one if any term matching is offensive (so "trump is a [slur]"
-- mutes rather than only starting the sender rule). Once an annoying term is found, only offensive
-- terms are still tried.
-- A word term whose first or last letter has a number glued to it still matches: "trump2028",
-- "2028trump" (Text.lua EndsWord, Unglue). glued is TC.HasGlued(s), or true when unsure.
local function MatchText(C, s, glued)
    local found
    if glued == nil then glued = TC.HasGlued(s) end
    for pos, word in gmatch(s, "()([%w\128-\255]+)") do
        local list, whole = C.index[word], true
        if not list and glued then
            local lead, stem = Unglue(word)
            if stem then pos, list, whole = pos + lead, C.index[stem], false end
        end
        if list then
            for i = 1, #list do
                local term = list[i]
                if not found or term.offensive then
                    local text = term.text
                    local e = pos + #text - 1
                    if ((whole and #text == #word) or sub(s, pos, e) == text) and EndsWord(s, e) then
                        if term.offensive then return term end
                        found = term
                    end
                end
            end
        end
    end
    for _, term in ipairs(C.loose) do
        if (not found or term.offensive) and Loose(s, term.text) then
            if term.offensive then return term end
            found = term
        end
    end
    for _, term in ipairs(C.patterns) do
        if (not found or term.offensive) and find(s, term.text) then
            if term.offensive then return term end
            found = term
        end
    end
    for _, term in ipairs(C.plain) do
        if (not found or term.offensive) and find(s, term.text, 1, true) then
            if term.offensive then return term end
            found = term
        end
    end
    for _, term in ipairs(C.allof) do
        if (not found or term.offensive) and AllOf(s, term.parts) then
            if term.offensive then return term end
            found = term
        end
    end
    return found
end

-- The term of set C matching a prepared message (Text.lua Prepare), offensive ones first, then the
-- other masked ones, then the unmasked ones (Dead Horses), or nil.
local function MatchSet(C, prep)
    local term = MatchText(C, prep.base, prep.glued)
    if term and term.offensive then return term end
    local folded = prep.folded and MatchText(C, prep.folded, prep.foldedGlued)
    if folded and folded.offensive then return folded end
    -- Starred and stretched forms, once per message, on the most folded copy (it keeps the stars).
    local found = WordForms(C, prep.folded or prep.base, term or folded)
    if found then return found end
    return MatchText(C.unmasked, prep.lower, prep.glued)
end

function TC.MatchPrepared(prep)
    if not compiled then return nil end
    return MatchSet(compiled, prep)
end

-- The term a guild's name matches, judged without the TC.GUILD_NAME_SKIP categories, or nil.
function TC.MatchGuildName(guild)
    if not compiled then return nil end
    compiledNames = compiledNames or Compile(TC.GUILD_NAME_SKIP)
    return MatchSet(compiledNames, TC.Prepare(guild, true))
end

function TC.IsOffensive(cat)
    return TC.db.settings.offensive[cat] and true or false
end

-- What a match in this category does: "mute" (Mute Forever), "timeout", "hide" (Hide Only) or "off".
TC.CATEGORY_ACTIONS = { { "mute", "Mute Forever" }, { "timeout", "Timeout" }, { "hide", "Hide Only" }, { "off", "Off" } }

function TC.CategoryAction(cat)
    local s = TC.db.settings
    if not s.categories[cat] then return "off" end
    if s.offensive[cat] then return "mute" end
    if s.hideOnly[cat] then return "hide" end
    return "timeout"
end

-- Stored as true/false, never nil, so the defaults don't come back at the next login.
function TC.SetCategoryAction(cat, action)
    local s = TC.db.settings
    s.categories[cat] = action ~= "off"
    s.offensive[cat] = action == "mute"
    s.hideOnly[cat] = action == "hide"
    TC.CompileTerms()
    TC.Notify("Settings")
end

-- For tests and the self-test: the term that would hide this text.
function TC.MatchRaw(raw)
    return TC.MatchPrepared(TC.Prepare(raw, true))
end

function TC.CountTermHit(term)
    local hits = TC.db.terms.hits
    hits[term.key] = (hits[term.key] or 0) + 1
end

---------------------------------------------------------------------------------------------------
-- Editing (term editor and /tc term)

-- Every term, default and custom, for the editor: { kind, text, cat, key, custom, enabled, hits }.
function TC.AllTerms()
    local out, seen = {}, {}
    local disabled, hits = TC.db.terms.disabled, TC.db.terms.hits
    local function Push(kind, text, cat, custom)
        local key = TC.TermKey(kind, text)
        if seen[key] then return end
        seen[key] = true
        out[#out + 1] = { kind = kind, text = text, cat = cat, key = key, custom = custom,
                          enabled = not disabled[key], hits = hits[key] or 0 }
    end
    for _, group in ipairs(TC.DefaultTerms) do
        for _, text in ipairs(group[3]) do Push(group[2], text, group[1], false) end
    end
    for _, t in ipairs(TC.db.terms.custom) do
        if type(t) == "table" and t.kind and t.text then Push(t.kind, t.text, t.cat or "Custom", true) end
    end
    return out
end

local defaultKeys
local function IsDefault(key)
    if not defaultKeys then
        defaultKeys = {}
        for _, group in ipairs(TC.DefaultTerms) do
            for _, text in ipairs(group[3]) do defaultKeys[TC.TermKey(group[2], text)] = group[1] end
        end
    end
    return defaultKeys[key]
end
TC.IsDefaultTerm = IsDefault

local function FindCustom(key)
    for i, t in ipairs(TC.db.terms.custom) do
        if type(t) == "table" and t.kind and t.text and TC.TermKey(t.kind, t.text) == key then return i, t end
    end
end

-- Validates as typed (so "%W" is refused, not quietly lowercased), then stores the normal form.
local function Prepared(kind, text)
    text = tostring(text or "")
    local ok, reason = TC.ValidateTerm(kind, text)
    if not ok then return nil, reason end
    text = TC.NormalizeTermText(kind, text)
    ok, reason = TC.ValidateTerm(kind, text)
    if not ok then return nil, reason end
    return text
end

-- Adds a custom term. Returns the term key, or nil and a reason.
function TC.AddTerm(kind, text, cat)
    local reason
    text, reason = Prepared(kind, text)
    if not text then return nil, reason end
    cat = TC.CategoryName(cat)
    cat = TC.db.settings.categories[cat] ~= nil and cat or "Custom"
    local key = TC.TermKey(kind, text)
    if IsDefault(key) or FindCustom(key) then
        if TC.db.terms.disabled[key] then
            TC.db.terms.disabled[key] = nil
            TC.CompileTerms()
            return key, "re-enabled"
        end
        return nil, "That term is already on the list."
    end
    table.insert(TC.db.terms.custom, { kind = kind, text = text, cat = cat, added = time() })
    TC.CompileTerms()
    return key
end

function TC.SetTermEnabled(key, enabled)
    TC.db.terms.disabled[key] = (not enabled) or nil
    TC.CompileTerms()
end

-- Built-in terms switched on: on, total.
function TC.DefaultTermsOn()
    local disabled, on, total = TC.db.terms.disabled, 0, 0
    for _, group in ipairs(TC.DefaultTerms) do
        for _, text in ipairs(group[3]) do
            total = total + 1
            if not disabled[TC.TermKey(group[2], text)] then on = on + 1 end
        end
    end
    return on, total
end

-- Switches every built-in term off or on at once, for anyone who'd rather fill in their own list.
-- Your own terms stay as they are. Returns how many changed.
function TC.SetDefaultTermsEnabled(enabled)
    local disabled, n = TC.db.terms.disabled, 0
    for _, group in ipairs(TC.DefaultTerms) do
        for _, text in ipairs(group[3]) do
            local key = TC.TermKey(group[2], text)
            if enabled and disabled[key] then
                disabled[key], n = nil, n + 1
            elseif not enabled and not disabled[key] then
                disabled[key], n = true, n + 1
            end
        end
    end
    TC.CompileTerms()
    return n
end

-- Deletes a custom term; a default term can only be disabled.
function TC.DeleteTerm(key)
    local i = FindCustom(key)
    if i then
        table.remove(TC.db.terms.custom, i)
        if not IsDefault(key) then TC.db.terms.disabled[key] = nil end
        TC.CompileTerms()
        return true
    end
    if IsDefault(key) then
        TC.SetTermEnabled(key, false)
        return true, "disabled"
    end
    return nil
end

-- Replaces a term with an edited one. Editing a default term disables it and adds the edit as a
-- custom term in the same category.
function TC.EditTerm(key, kind, text, cat)
    local reason
    text, reason = Prepared(kind, text)
    if not text then return nil, reason end
    local newKey = TC.TermKey(kind, text)
    if newKey == key then
        local _, t = FindCustom(key)
        if t then t.cat = cat end
        TC.CompileTerms()
        return newKey
    end
    if IsDefault(newKey) or FindCustom(newKey) then return nil, "That term is already on the list." end
    local i = FindCustom(key)
    if i then
        local t = TC.db.terms.custom[i]
        t.kind, t.text, t.cat = kind, text, cat
    else
        TC.db.terms.disabled[key] = true
        table.insert(TC.db.terms.custom, { kind = kind, text = text, cat = cat, added = time() })
    end
    TC.CompileTerms()
    return newKey
end

---------------------------------------------------------------------------------------------------
-- Import and export of the whole list as plain text

local EXPORT_HEADER = "# TolerableChat terms. One per line: category | type | text. A leading \"- \" marks a disabled term.\n"
    .. "# Types: word (Whole word), phrase (Exact text), contains (Anywhere), allof (All of), pattern (Pattern).\n"
    .. "# Lines starting with # are ignored.\n"

function TC.ExportTerms()
    local lines = { EXPORT_HEADER }
    for _, t in ipairs(TC.AllTerms()) do
        lines[#lines + 1] = format("%s%s | %s | %s", t.enabled and "" or "- ", t.cat, t.kind, t.text)
    end
    return table.concat(lines, "\n")
end

-- Merges a pasted list: default terms take the line's on/off state; other lines become custom terms.
-- Returns counts { added, enabled, disabled, rejected } and a list of rejected lines.
function TC.ImportTerms(text)
    local counts, rejected = { added = 0, enabled = 0, disabled = 0, rejected = 0 }, {}
    local disabled = TC.db.terms.disabled
    for line in gmatch(text .. "\n", "([^\r\n]*)\r?\n") do
        local trimmed = Trim(line)
        if trimmed ~= "" and sub(trimmed, 1, 1) ~= "#" then
            local off = false
            if sub(trimmed, 1, 2) == "- " then off, trimmed = true, sub(trimmed, 3) end
            local cat, kind, body = match(trimmed, "^([^|]-)%s*|%s*(%a+)%s*|%s?(.*)$")
            kind = kind and lower(kind)
            body = kind and TC.KIND_LABEL[kind] and Prepared(kind, body)
            if not (cat and body) then
                counts.rejected = counts.rejected + 1
                rejected[#rejected + 1] = line
            else
                cat = TC.CategoryName(Trim(cat))
                local key = TC.TermKey(kind, body)
                if not IsDefault(key) and not FindCustom(key) then
                    table.insert(TC.db.terms.custom, { kind = kind, text = body,
                        cat = TC.db.settings.categories[cat] ~= nil and cat or "Custom", added = time() })
                    counts.added = counts.added + 1
                end
                if off and not disabled[key] then
                    disabled[key] = true
                    counts.disabled = counts.disabled + 1
                elseif not off and disabled[key] then
                    disabled[key] = nil
                    counts.enabled = counts.enabled + 1
                end
            end
        end
    end
    TC.CompileTerms()
    return counts, rejected
end
