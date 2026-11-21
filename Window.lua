-- CorpseRun: main window (/cr). A scrolling log of recent kills and losses
-- with filters, hover details and the export buttons. It can be minimized to
-- a small bar, and whether it was open, minimized or closed (plus where it
-- was) is saved, so it comes back the same way after a reload or login.
local _, ns = ...

local WIDTH, HEIGHT = 440, 420
local ROW_H = 38
local LIST_W = WIDTH - 52          -- inside inset, minus scrollbar
local KILL_COLOR = "|cff4ADE80"
local LOSS_COLOR = "|cffF06B61"
local GOLD = "|cffF2C14E"
local DIM = "|cff8A909C"
local CLASS_ICONS = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"

local MINI_W, MINI_H = WIDTH, 26  -- same width as the window, so minimizing keeps its footprint

local window, mini
local filter = "all"               -- all | kill | death
local rows = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function ClassColor(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile:upper()]
    if not c then return "|cffE7E9EE" end
    return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end

local ClassName = function(classFile) return ns.ClassName(classFile) end

local function RelTime(ts)
    local s = math.max(0, ns.Now() - (ts or 0))
    if s < 60 then return "now" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    if s < 86400 then return math.floor(s / 3600) .. "h" end
    return math.floor(s / 86400) .. "d"
end

local function SetSolid(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a) else tex:SetTexture(r, g, b, a) end
end

--- The "other" character of a report: the victim for kills, the killer for losses.
local function Opponent(r)
    if r.kind == "kill" then return r.victim end
    return r.killer or (r.attackers and r.attackers[1])
end

local function Describe(c)
    if not c then return nil end
    local parts = {}
    if c.level then parts[#parts + 1] = tostring(c.level) end
    if c.race then parts[#parts + 1] = c.race end
    if c.class then parts[#parts + 1] = ClassName(c.class) end
    return #parts > 0 and table.concat(parts, " ") or nil
end

local function Filtered()
    local list = {}
    local reports = WKillboardCharDB.reports
    for i = #reports, 1, -1 do -- newest first
        local r = reports[i]
        if filter == "all" or r.kind == filter then list[#list + 1] = r end
    end
    return list
end

-- ---------------------------------------------------------------------------
-- Row
-- ---------------------------------------------------------------------------

local function ShowTooltip(row)
    local r = row.report
    if not r then return end
    local o = Opponent(r)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if r.kind == "kill" then
        GameTooltip:AddLine(KILL_COLOR .. "Kill|r  " .. ClassColor(o and o.class) .. (o and o.name or "Unknown") .. "|r")
    else
        GameTooltip:AddLine(LOSS_COLOR .. "Death|r  killed by " .. ClassColor(o and o.class) .. (o and o.name or "unknown") .. "|r")
    end
    local desc = Describe(o)
    if desc then GameTooltip:AddLine(desc, 1, 1, 1) end
    if o and o.guild then GameTooltip:AddLine("<" .. o.guild .. ">", 0.66, 0.69, 0.73) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Zone", r.subzone and (r.zone .. ", " .. r.subzone) or r.zone, 0.54, 0.56, 0.61, 1, 1, 1)
    GameTooltip:AddDoubleLine("Time", date("%b %d %H:%M", r.occurred_at), 0.54, 0.56, 0.61, 1, 1, 1)
    if r.honor then GameTooltip:AddDoubleLine("Honor", "+" .. r.honor, 0.54, 0.56, 0.61, 0.95, 0.76, 0.31) end
    if r.damage_taken then
        local d = tostring(r.damage_taken) .. (r.duration_sec and r.duration_sec > 0 and (" in " .. r.duration_sec .. "s") or "")
        GameTooltip:AddDoubleLine("Damage taken", d, 0.54, 0.56, 0.61, 1, 1, 1)
    end
    if r.attackers and #r.attackers > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Attackers", 0.54, 0.56, 0.61)
        for _, a in ipairs(r.attackers) do
            GameTooltip:AddLine("  " .. ClassColor(a.class) .. a.name .. "|r " .. DIM .. (ClassName(a.class) or "") .. "|r")
        end
    end
    if r.gear and #r.gear > 0 then
        local sum, n = 0, 0
        for _, g in ipairs(r.gear) do
            if g.item_level and g.slot ~= "shirt" and g.slot ~= "tabard" then sum, n = sum + g.item_level, n + 1 end
        end
        GameTooltip:AddDoubleLine("Gear recorded", #r.gear .. " items" .. (n > 0 and string.format(", avg ilvl %d", sum / n) or ""),
            0.54, 0.56, 0.61, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    if r.exported_at then
        GameTooltip:AddLine("Exported " .. RelTime(r.exported_at) .. " ago", 0.54, 0.56, 0.61)
    else
        GameTooltip:AddLine("Waiting to export", 0.95, 0.76, 0.31)
    end
    GameTooltip:Show()
end

local function CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(LIST_W, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints()
    SetSolid(row.stripe, 1, 1, 1, index % 2 == 0 and 0.03 or 0)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(28, 28)
    row.icon:SetPoint("LEFT", 6, 0)

    row.tag = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.tag:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
    row.tag:SetWidth(34)
    row.tag:SetJustifyH("LEFT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.tag, "RIGHT", 2, 0)
    row.name:SetWidth(170)
    row.name:SetJustifyH("LEFT")

    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.sub:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
    row.sub:SetWidth(250)
    row.sub:SetJustifyH("LEFT")

    row.honor = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.honor:SetPoint("TOPRIGHT", -30, -5)
    row.honor:SetJustifyH("RIGHT")

    row.time = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.time:SetPoint("BOTTOMRIGHT", -30, 6)
    row.time:SetJustifyH("RIGHT")

    row.status = row:CreateTexture(nil, "OVERLAY")
    row.status:SetSize(12, 12)
    row.status:SetPoint("RIGHT", -8, 0)

    row:SetScript("OnEnter", ShowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function FillRow(row, r)
    row.report = r
    local o = Opponent(r)

    local coords = o and o.class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[o.class:upper()]
    if coords then
        row.icon:SetTexture(CLASS_ICONS)
        row.icon:SetTexCoord(unpack(coords))
    else
        row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end

    if r.kind == "kill" then
        row.tag:SetText(KILL_COLOR .. "KILL|r")
    else
        row.tag:SetText(LOSS_COLOR .. "LOSS|r")
    end

    local name = o and o.name or "Unknown"
    if r.kind == "death" and not r.killer and r.attackers and #r.attackers > 1 then
        name = name .. DIM .. " +" .. (#r.attackers - 1) .. "|r"
    end
    local faction = o and o.faction
    local factionTag = faction == "Alliance" and " |cff6FA3F2A|r" or faction == "Horde" and " |cffF06B61H|r" or ""
    row.name:SetText(ClassColor(o and o.class) .. name .. "|r" .. factionTag)

    local desc = Describe(o)
    row.sub:SetText((desc and (desc .. " · ") or "") .. (r.subzone or r.zone or ""))

    row.honor:SetText(r.honor and (GOLD .. "+" .. r.honor .. "|r") or "")
    row.time:SetText(RelTime(r.occurred_at))

    if r.exported_at then
        row.status:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    else
        row.status:SetTexture("Interface\\COMMON\\Indicator-Yellow")
    end
    row:Show()
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

local function UpdateFilterButtons()
    for key, button in pairs(window.filters) do
        if key == filter then button:LockHighlight() else button:UnlockHighlight() end
    end
end

local function RefreshMini()
    if not mini or not mini:IsShown() then return end
    local pending = ns.PendingCount()
    mini.label:SetText("Corpse" .. GOLD .. "Run|r  " .. (pending > 0
        and string.format("%s%d waiting to export|r", GOLD, pending)
        or DIM .. "nothing to export|r"))
end

function ns.RefreshWindow()
    RefreshMini()
    if not window or not window:IsShown() then return end
    local kills, deaths, exported = 0, 0, 0
    for _, r in ipairs(WKillboardCharDB.reports) do
        if r.kind == "kill" then kills = kills + 1 else deaths = deaths + 1 end
        if r.exported_at then exported = exported + 1 end
    end
    local pending = ns.PendingCount()
    window.summary:SetText(string.format("%sKills|r %d   %sLosses|r %d   %s%d waiting to export|r",
        KILL_COLOR, kills, LOSS_COLOR, deaths, pending > 0 and GOLD or DIM, pending))

    local list = Filtered()
    for i, r in ipairs(list) do
        rows[i] = rows[i] or CreateRow(window.content, i)
        FillRow(rows[i], r)
    end
    for i = #list + 1, #rows do rows[i]:Hide(); rows[i].report = nil end
    window.content:SetHeight(math.max(1, #list * ROW_H))
    window.empty:SetShown(#list == 0)

    window.exportNew:SetText(pending > 0 and string.format("Export new (%d)", pending) or "Export new")
    window.exportNew:SetEnabled(pending > 0)
    window.clear:SetEnabled(exported > 0)
    UpdateFilterButtons()
end

ns.OnReportsChanged = ns.RefreshWindow

-- ---------------------------------------------------------------------------
-- Saved state: "open", "min" or "closed", and the top-left corner shared by
-- the window and the mini bar (so minimizing keeps it in place).
-- ---------------------------------------------------------------------------

local function Saved()
    WKillboardDB.window = type(WKillboardDB.window) == "table" and WKillboardDB.window or {}
    return WKillboardDB.window
end

--- Remember where a frame's top-left corner is (after a drag).
local function SavePosition(f)
    local left, top = f:GetLeft(), f:GetTop()
    if left and top then
        local s = Saved()
        s.x, s.y = math.floor(left + 0.5), math.floor(top + 0.5)
    end
end

--- Put a frame at the saved top-left corner, or its default spot.
local function PlaceFrame(f, defaultPoint)
    local s = Saved()
    f:ClearAllPoints()
    if type(s.x) == "number" and type(s.y) == "number" then
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", s.x, s.y)
    else
        f:SetPoint(defaultPoint)
    end
end

local function Draggable(f)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- We save the spot ourselves; keep the client's layout cache out of it.
        if self.SetUserPlaced then self:SetUserPlaced(false) end
        SavePosition(self)
    end)
end

local CreateWindow, CreateMini

--- Show the window as "open", "min" or "closed" and remember it.
local function SetState(state)
    Saved().state = state
    if state == "open" then
        window = window or CreateWindow()
        if mini and mini:IsShown() then SavePosition(mini); mini:Hide() end
        PlaceFrame(window, "CENTER")
        window:Show()
    elseif state == "min" then
        mini = mini or CreateMini()
        if window and window:IsShown() then SavePosition(window); window:Hide() end
        PlaceFrame(mini, "CENTER")
        mini:Show()
        RefreshMini()
    else
        if window and window:IsShown() then SavePosition(window) end
        if mini and mini:IsShown() then SavePosition(mini) end
        if window then window:Hide() end
        if mini then mini:Hide() end
    end
end

function CreateMini()
    local f = CreateFrame("Button", "CorpseRunMini", UIParent)
    f:SetSize(MINI_W, MINI_H)
    f:SetFrameStrata("MEDIUM")
    Draggable(f)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    SetSolid(bg, 0.05, 0.06, 0.08, 0.92)
    -- 1px border
    for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
                            { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil } }) do
        local t = f:CreateTexture(nil, "BORDER")
        t:SetPoint(side[1]); t:SetPoint(side[2])
        if side[3] then t:SetWidth(side[3]) else t:SetHeight(side[4]) end
        SetSolid(t, 0.35, 0.37, 0.42, 0.9)
    end
    f:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.label:SetPoint("LEFT", 8, 0)
    f.label:SetPoint("RIGHT", -8, 0)
    f.label:SetJustifyH("LEFT")

    f:SetScript("OnClick", function(_, button)
        if button == "RightButton" then SetState("closed") else SetState("open") end
    end)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Corpse" .. GOLD .. "Run|r")
        GameTooltip:AddLine("Click to open. Drag to move. Right-click to close.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f:Hide()
    return f
end

function CreateWindow()
    local f = CreateFrame("Frame", "CorpseRunWindow", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER")
    Draggable(f)
    -- Not in UISpecialFrames: Escape (closing bags, the map...) leaves it open.

    -- The template's X closes it for good; the new button minimizes it.
    local closeButton = f.CloseButton or _G["CorpseRunWindowCloseButton"]
    if type(closeButton) ~= "table" then closeButton = nil end
    if closeButton then closeButton:SetScript("OnClick", function() SetState("closed") end) end
    -- Minimize in the top-right corner (centred where the template's X was),
    -- the X mirrored into the top-left corner at the same small size.
    local MIN_W, MIN_H = 22, 18
    f.minimize = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.minimize:SetSize(MIN_W, MIN_H)
    local point, rel, relPoint, x, y, cw, ch
    if closeButton then
        point, rel, relPoint, x, y = closeButton:GetPoint(1)
        cw, ch = closeButton:GetSize()
    end
    local mx, my = -4, -3
    if point == "TOPRIGHT" and relPoint == "TOPRIGHT" and cw and ch then
        mx = (x or 0) - math.floor((cw - MIN_W) / 2)
        my = (y or 0) - math.floor((ch - MIN_H) / 2)
    end
    f.minimize:SetPoint("TOPRIGHT", f, "TOPRIGHT", mx, my)
    if closeButton then
        closeButton:SetSize(MIN_H, MIN_H) -- square, so the X art isn't stretched
        closeButton:ClearAllPoints()
        -- same distance from the left edge (centre to edge) as the minimize from the right
        closeButton:SetPoint("TOPLEFT", f, "TOPLEFT", -mx + math.floor((MIN_W - MIN_H) / 2), my)
    end
    f.minimize:SetText("_")
    f.minimize:SetScript("OnClick", function() SetState("min") end)
    f.minimize:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Minimize")
        GameTooltip:AddLine("Shrinks to a small bar. It stays after a reload.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.minimize:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOP", 0, -5)
    f.title:SetText("Corpse" .. GOLD .. "Run|r")

    f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.summary:SetPoint("TOPLEFT", 16, -34)

    -- Filters
    f.filters = {}
    local prev
    for _, def in ipairs({ { "all", "All" }, { "kill", "Kills" }, { "death", "Losses" } }) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(70, 22)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 14, -56) end
        b:SetText(def[2])
        b:SetScript("OnClick", function()
            filter = def[1]
            ns.RefreshWindow()
        end)
        f.filters[def[1]] = b
        prev = b
    end

    -- Clear: only removes reports already exported, so nothing unsent is lost.
    f.clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.clear:SetSize(70, 22)
    f.clear:SetPoint("TOPRIGHT", -14, -56)
    f.clear:SetText("Clear")
    f.clear:SetScript("OnClick", function() ns.ClearReports(false) end)
    if f.clear.SetMotionScriptsWhileDisabled then f.clear:SetMotionScriptsWhileDisabled(true) end
    f.clear:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Clear exported")
        GameTooltip:AddLine("Removes reports you've already exported. Reports waiting to export are kept.", 1, 1, 1, true)
        GameTooltip:AddLine("/cr clear all deletes everything.", 0.54, 0.56, 0.61, true)
        GameTooltip:Show()
    end)
    f.clear:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- List
    local scroll = CreateFrame("ScrollFrame", "CorpseRunWindowScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -84)
    scroll:SetPoint("BOTTOMRIGHT", -32, 46)
    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(LIST_W, 1)
    scroll:SetScrollChild(f.content)

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("CENTER", scroll, "CENTER", 0, 10)
    f.empty:SetWidth(LIST_W - 40)
    f.empty:SetText("No kills or losses recorded yet.\nThey appear here automatically after PvP fights.")

    -- Export buttons
    f.exportNew = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.exportNew:SetSize(150, 24)
    f.exportNew:SetPoint("BOTTOMLEFT", 14, 14)
    f.exportNew:SetScript("OnClick", function() ns.ShowExport("new") end)

    f.exportAll = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.exportAll:SetSize(130, 24)
    f.exportAll:SetPoint("BOTTOMRIGHT", -14, 14)
    f.exportAll:SetText("Export all (14d)")
    f.exportAll:SetScript("OnClick", function() ns.ShowExport("all") end)

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.hint:SetPoint("BOTTOM", 0, 20)
    f.hint:SetText("paste at Submit kills")

    -- Keep relative times fresh while open.
    f:SetScript("OnShow", function(self)
        ns.RefreshWindow()
        if C_Timer and C_Timer.NewTicker then
            self.ticker = C_Timer.NewTicker(30, ns.RefreshWindow)
        end
    end)
    f:SetScript("OnHide", function(self)
        if self.ticker then self.ticker:Cancel(); self.ticker = nil end
    end)

    f:Hide()
    return f
end

--- /cr: open it (from closed or minimized), or close it when it's open.
function ns.ToggleWindow()
    SetState(Saved().state == "open" and window and window:IsShown() and "closed" or "open")
end

--- After login or a reload: bring the window back the way it was left.
function ns.RestoreWindow()
    local state = Saved().state
    if state == "open" or state == "min" then SetState(state) end
end
