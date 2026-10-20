-- Settings -> AddOns -> TolerableChat (spec 5.2): the master switch and a button that opens the main
-- window, where everything else is.

local _, TC = ...
local UI = TC.UI

local panel = CreateFrame("Frame")
panel.name = "TolerableChat"
panel.controls = {}

local function Build(f)
    local inner = CreateFrame("Frame", nil, f)
    inner:SetPoint("TOPLEFT", 16, -16)
    inner:SetPoint("BOTTOMRIGHT", -16, 16)
    inner.controls = f.controls
    local stack = UI.Stack(inner)
    stack:Add(UI.Text(inner, "TolerableChat", "GameFontNormalLarge"), 0, true)
    stack:Add(UI.Wrap(inner, "Keeps chat quiet and game-focused. What it hides, the log and your lists are in "
        .. "the TolerableChat window: type /tc, or use the button below."), 8, true)
    stack:Add(UI.SettingCheck(inner, "TolerableChat is on", "enabled",
        "Off: every message is shown. Your lists and settings are kept."), 12)
    local row = UI.Row(inner, 22)
    -- The game's Settings window stays open and TolerableChat's comes up on top. Settings isn't a managed
    -- panel, so HideUIPanel would hide it from addon code: its OnHide would run tainted and could get
    -- the game's later actions blocked.
    local open = UI.Button(row, "Open TolerableChat", function() UI.Show() end)
    open:SetPoint("LEFT", 0, 0)
    stack:Add(row, 12, true)
    f.built = true
end

panel:SetScript("OnShow", function(self)
    if not self.built then Build(self) end
    for _, c in ipairs(self.controls) do c:Refresh() end
end)

local category
if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    category = Settings.RegisterCanvasLayoutCategory(panel, "TolerableChat")
    Settings.RegisterAddOnCategory(category)
end

function TC.OpenSettings()
    if category and Settings.OpenToCategory then Settings.OpenToCategory(category:GetID()) end
end
