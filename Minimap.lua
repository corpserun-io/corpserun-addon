-- CorpseRun: round minimap button. Left-click opens/closes the window, drag
-- moves it around the minimap edge, /cr minimap hides or shows it. Its spot
-- and visibility are saved account-wide (WKillboardDB.minimap).
local _, ns = ...

local GOLD = "|cffF2C14E"
local ICON = "Interface\\AddOns\\CorpseRun\\icon"
local button

local function Saved()
    WKillboardDB.minimap = type(WKillboardDB.minimap) == "table" and WKillboardDB.minimap or {}
    local s = WKillboardDB.minimap
    if type(s.angle) ~= "number" then s.angle = 220 end -- lower left of the minimap
    return s
end

--- Put the button on the minimap's edge at the saved angle.
local function Place()
    if not button or not Minimap then return end
    local w = Minimap:GetWidth()
    local radius = (type(w) == "number" and w > 0 and w / 2 or 70) + 10
    local a = math.rad(Saved().angle)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * radius, math.sin(a) * radius)
end

--- While dragging: follow the cursor's angle around the minimap centre.
local function OnDragUpdate()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    if not (mx and px and scale and scale > 0) then return end
    Saved().angle = math.deg(math.atan2(py / scale - my, px / scale - mx))
    Place()
end

local function ShowTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Corpse" .. GOLD .. "Run|r")
    local pending = ns.PendingCount and ns.PendingCount() or 0
    if pending > 0 then
        GameTooltip:AddLine(string.format("%d waiting to export", pending), 0.95, 0.76, 0.31)
    end
    GameTooltip:AddLine("Click to open or close. Drag to move.", 1, 1, 1, true)
    GameTooltip:AddLine("/cr minimap hides this button.", 0.54, 0.56, 0.61, true)
    GameTooltip:Show()
end

local function Create()
    local b = CreateFrame("Button", "CorpseRunMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- The usual round minimap-button look: dark disc, icon, gold ring.
    -- Icon centred in the ring (the ring art sits in the top-left of its
    -- texture, so its centre is about 16.5, -16 from the button's corner).
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetTexture(ICON)
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("TOPLEFT", 8.5, -7)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- trim the icon's rounded corners

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(22, 22)
    bg:SetPoint("CENTER", b.icon, "CENTER")

    local ring = b:CreateTexture(nil, "OVERLAY")
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetSize(53, 53)
    ring:SetPoint("TOPLEFT")

    b:SetScript("OnClick", function() ns.ToggleWindow() end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", OnDragUpdate)
        GameTooltip:Hide()
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnEnter", ShowTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

--- After login: create the button unless the player hid it.
function ns.SetupMinimapButton()
    if not Minimap then return end
    button = button or Create()
    Place()
    button:SetShown(not Saved().hide)
end

--- /cr minimap: hide or show the button.
function ns.ToggleMinimapButton()
    local s = Saved()
    s.hide = not s.hide
    ns.SetupMinimapButton()
    if s.hide then
        ns.Print("Minimap button hidden. |cffffffff/cr minimap|r brings it back.")
    else
        ns.Print("Minimap button shown.")
    end
end
