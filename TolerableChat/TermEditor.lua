-- Term editor (spec 6.2): add, edit, disable and delete terms; a hit counter per term; import and
-- export of the whole list as plain text.

local _, TC = ...
local UI = TC.UI
local format = string.format

local editor
local state = { cat = "all", show = "all", search = "", kind = "word", newCat = "Custom", editing = nil }

local function CategoryOptions(withAll)
    local out = withAll and { { "all", "All categories" } } or {}
    for _, cat in ipairs(TC.CATEGORIES) do out[#out + 1] = { cat, cat } end
    return out
end

local function KindOptions()
    local out = {}
    for _, kind in ipairs(TC.KINDS) do out[#out + 1] = { kind, TC.KIND_LABEL[kind] } end
    return out
end

local SHOW_OPTIONS = { { "all", "All terms" }, { "on", "Enabled" }, { "off", "Disabled" }, { "custom", "Yours" },
                       { "hits", "With hits" } }

local function Visible()
    local out, search = {}, TC.Lower(state.search)
    for _, t in ipairs(TC.AllTerms()) do
        local ok = (state.cat == "all" or t.cat == state.cat)
            and (state.show == "all" or (state.show == "on" and t.enabled) or (state.show == "off" and not t.enabled)
                 or (state.show == "custom" and t.custom) or (state.show == "hits" and t.hits > 0))
            and (search == "" or t.text:find(search, 1, true))
        if ok then out[#out + 1] = t end
    end
    if state.show == "hits" then table.sort(out, function(a, b) return a.hits > b.hits end) end
    return out
end

local function SetError(text)
    editor.err:SetText(text and ("|cffff6060" .. text .. "|r") or "")
end

local function ResetForm()
    state.editing = nil
    editor.input:SetText("")
    editor.add:SetText("Add")
    editor.cancel:Hide()
    SetError(nil)
end

local function Submit()
    local text = editor.input:GetText()
    local key, reason
    if state.editing then
        key, reason = TC.EditTerm(state.editing, state.kind, text, state.newCat)
    else
        key, reason = TC.AddTerm(state.kind, text, state.newCat)
    end
    if not key then
        SetError(reason)
        return
    end
    ResetForm()
    UI.RefreshTermEditor()
end

-- The line above the add row says what the chosen match type does.
local function ShowKindHint()
    if editor and editor.kindHint then editor.kindHint:SetText("|cffaaaaaa" .. (TC.KIND_SUMMARY[state.kind] or "") .. "|r") end
end

local function StartEdit(t)
    state.editing, state.kind, state.newCat = t.key, t.kind, t.cat
    ShowKindHint()
    editor.input:SetText(t.text)
    editor.kindButton:Refresh()
    editor.catButton:Refresh()
    editor.add:SetText("Save")
    editor.cancel:Show()
    SetError(not t.custom and "Saving an edited default term disables the original and adds your version." or nil)
    editor.input:SetFocus()
end

local function Build()
    local f = CreateFrame("Frame", "TolerableChatTermEditor", UIParent, "BasicFrameTemplateWithInset")
    f:Hide()
    f:SetSize(720, 520)
    f:SetPoint("CENTER", 40, -20)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.TitleText then f.TitleText:SetText("TolerableChat terms") end
    tinsert(UISpecialFrames, "TolerableChatTermEditor")
    f.controls = {}
    editor = f

    -- Everything is anchored relative to its neighbours or the frame's edges, never at fixed x offsets,
    -- so it holds together with any font and UI scale.
    local searchLabel = UI.Text(f, "Search")
    searchLabel:SetPoint("TOPLEFT", 18, -38)
    local search = UI.Edit(f, 150)
    search:SetPoint("LEFT", searchLabel, "RIGHT", 10, 0)
    search:SetScript("OnTextChanged", function(self)
        state.search = self:GetText()
        UI.RefreshTermEditor()
    end)
    local cat = UI.Choice(f, "", function() return CategoryOptions(true) end, function() return state.cat end,
        function(v) state.cat = v UI.RefreshTermEditor() end)
    cat:SetPoint("LEFT", search, "RIGHT", 10, 0)
    local show = UI.Choice(f, "", function() return SHOW_OPTIONS end, function() return state.show end,
        function(v) state.show = v UI.RefreshTermEditor() end)
    show:SetPoint("LEFT", cat, "RIGHT", 4, 0)
    f.count = UI.Line(f, "")
    f.count:SetPoint("LEFT", show, "RIGHT", 10, 0)
    f.count:SetPoint("RIGHT", f, "RIGHT", -16, 0)

    local list = UI.List(f, 24, function(row)
        row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.check:SetSize(20, 20)
        row.check:SetPoint("LEFT", 2, 0)
        row.check:SetScript("OnClick", function(self)
            TC.SetTermEnabled(row.item.key, self:GetChecked() and true or false)
        end)
        local buttons, leftmost = UI.RowButtons(row, {
            { "Edit", function(t) StartEdit(t) end },
            { "Delete", function(t) TC.DeleteTerm(t.key) end },
        })
        row.delete = buttons[2]
        row.hits = UI.Line(row, "")
        row.hits:SetJustifyH("RIGHT")
        row.hits:SetWidth(64)
        row.hits:SetPoint("RIGHT", leftmost, "LEFT", -8, 0)
        row.cat = UI.Line(row, "")
        row.cat:SetWidth(104)
        row.cat:SetPoint("RIGHT", row.hits, "LEFT", -8, 0)
        row.kind = UI.Line(row, "")
        local widest = 0   -- as wide as the longest type label in this font
        for _, label in pairs(TC.KIND_LABEL) do
            row.kind:SetText(label)
            widest = math.max(widest, row.kind:GetStringWidth() or 0)
        end
        row.kind:SetWidth(math.max(64, widest + 4))
        row.kind:SetPoint("RIGHT", row.cat, "LEFT", -8, 0)
        UI.Tooltip(row, function() return row.item and TC.KindHelp(row.item) or "" end)
        row.term = UI.Line(row, "")
        row.term:SetPoint("LEFT", 26, 0)
        row.term:SetPoint("RIGHT", row.kind, "LEFT", -8, 0)
    end, function(row, t)
        row.check:SetChecked(t.enabled)
        row.term:SetText((t.enabled and "" or "|cff808080") .. t.text .. (t.custom and "  |cff66ccff(yours)|r" or ""))
        row.kind:SetText(TC.KIND_LABEL[t.kind] or t.kind)
        row.cat:SetText(t.cat)
        row.hits:SetText(t.hits > 0 and format("%d hit%s", t.hits, t.hits == 1 and "" or "s") or "")
        row.delete:SetShown(t.custom)
    end)
    list.box:SetPoint("TOPLEFT", 14, -64)
    list.box:SetPoint("BOTTOMRIGHT", -32, 144)
    f.list = list

    local export = UI.Button(f, "Export...", function()
        UI.ShowTextBox("TolerableChat terms", TC.ExportTerms())
    end)
    export:SetPoint("BOTTOMRIGHT", -14, 12)
    local import = UI.Button(f, "Import...", function()
        UI.ShowTextBox("Import terms: paste a list, then Import", "", "Import", function(text)
            local counts, rejected = TC.ImportTerms(text)
            TC.Print(format("Imported: %d added, %d enabled, %d disabled, %d lines rejected.",
                counts.added, counts.enabled, counts.disabled, counts.rejected))
            for i = 1, math.min(5, #rejected) do TC.Print("  rejected: " .. rejected[i]) end
            UI.HideTextBox()
        end)
    end)
    import:SetPoint("RIGHT", export, "LEFT", -4, 0)
    -- All built-in terms off at once (asks first), or back on: for filling in a list of your own.
    f.builtIn = UI.Button(f, "Turn off built-in terms", function()
        local on, total = TC.DefaultTermsOn()
        if on == 0 then
            local n = TC.SetDefaultTermsEnabled(true)
            TC.Print(format("%d built-in terms switched back on.", n))
            return
        end
        UI.Ask({
            text = format("Switch off all %d built-in terms? Only your own terms will filter chat.\n"
                .. "|cff999999Turn built-in terms on brings them all back, including any you had switched "
                .. "off one by one.|r", total),
            yes = "Turn off", no = CANCEL or "Cancel",
            onYes = function()
                local n = TC.SetDefaultTermsEnabled(false)
                TC.Print(format("%d built-in terms switched off. Your own terms still filter chat; add more with "
                    .. "Edit terms.", n))
            end,
        })
    end)
    f.builtIn:SetPoint("RIGHT", import, "LEFT", -4, 0)
    UI.Tooltip(f.builtIn, function()
        return "Switches every built-in term off, so only the terms you add filter chat. Your own terms, guild words "
            .. "and settings aren't touched. Press it again to turn them all back on."
    end)
    f.err = UI.Wrap(f, "")
    f.err:SetPoint("BOTTOMLEFT", 18, 16)
    f.err:SetPoint("RIGHT", f.builtIn, "LEFT", -12, 0)

    f.kindButton = UI.Choice(f, "Match: ", KindOptions, function() return state.kind end,
        function(v) state.kind = v ShowKindHint() end)
    f.kindButton:SetPoint("BOTTOMLEFT", 14, 52)
    f.catButton = UI.Choice(f, "", function() return CategoryOptions(false) end, function() return state.newCat end,
        function(v) state.newCat = v end)
    f.catButton:SetPoint("LEFT", f.kindButton, "RIGHT", 4, 0)
    f.add = UI.Button(f, "Add", Submit)
    f.add:SetPoint("BOTTOMRIGHT", -14, 52)
    f.cancel = UI.Button(f, "Cancel", ResetForm)
    f.cancel:SetPoint("RIGHT", f.add, "LEFT", -4, 0)
    f.cancel:Hide()
    f.input = UI.Edit(f, 100, function() Submit() end)
    f.input:SetPoint("LEFT", f.catButton, "RIGHT", 12, 0)
    f.input:SetPoint("RIGHT", f.cancel, "LEFT", -10, 0)
    f.kindHint = UI.Wrap(f, "")
    f.kindHint:SetPoint("BOTTOMLEFT", f.kindButton, "TOPLEFT", 4, 6)
    f.kindHint:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    local addLabel = UI.Header(f, "Add a term: choose how it matches (Match:) and its category, then type it")
    addLabel:SetPoint("BOTTOMLEFT", f.kindHint, "TOPLEFT", 0, 4)
    UI.Tooltip(f.kindButton, function()
        local lines = { "How a term can match (every type sees through spelling tricks):", "" }
        for _, kind in ipairs(TC.KINDS) do lines[#lines + 1] = TC.KIND_SUMMARY[kind] end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Capital classes such as %W aren't allowed (text is lowercased): write [^%w]. "
            .. "Patterns aren't accepted from guild shares; pass them on with Export and Import."
        return table.concat(lines, "\n")
    end)
end

function UI.OpenTermEditor()
    if not editor then Build() end
    editor:Show()
    UI.RefreshTermEditor()
end

function UI.RefreshTermEditor()
    if not editor or not editor:IsShown() then return end
    ShowKindHint()
    for _, c in ipairs(editor.controls) do c:Refresh() end
    local items = Visible()
    local active, total = TC.TermCounts()
    editor.count:SetText(format("%d shown · %d of %d active", #items, active, total))
    editor.builtIn:SetText(TC.DefaultTermsOn() == 0 and "Turn built-in terms on" or "Turn off built-in terms")
    UI.FitButton(editor.builtIn)
    editor.list:SetData(items)
end
