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

local MINI_W, MINI_H = WIDTH, 24  -- same width as the window; height = its title bar (measured)

-- The list is virtual: only enough rows to fill the visible area (plus one
-- for a partly scrolled row) exist, and they're refilled as it scrolls.
local LIST_TOP, LIST_BOTTOM = 84, 46
local VIEW_H = HEIGHT - LIST_TOP - LIST_BOTTOM
local NUM_ROWS = math.ceil(VIEW_H / ROW_H) + 1

local window, mini
local filter = "all"               -- all | kill | death
local rows = {}                    -- the NUM_ROWS row frames, reused
local shown = {}                   -- the filtered reports, newest first

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

-- Other players on each kill, from /cr backfill follow-ups: [kill client_id] = count.
local followUpAttackers = {}

--- Players who fought on our side of a kill, us included (1 = solo). The
--- attackers list never holds the reporter; a backfill follow-up can list
--- party members the kill itself went out without.
local function FightSize(r)
    local n = type(r.attackers) == "table" and #r.attackers or 0
    local extra = r.client_id and followUpAttackers[r.client_id] or 0
    return 1 + math.max(n, extra)
end
ns.FightSize = FightSize

local function Filtered()
    local list = {}
    local reports = WKillboardCharDB.reports
    local followUps = WKillboardCharDB.followUps or {}
    followUpAttackers = {}
    for i = #reports, 1, -1 do -- newest first
        local r = reports[i]
        local of = r.client_id and followUps[r.client_id]
        if of then
            -- Backfill follow-ups add damage to a kill already listed.
            local n = type(r.attackers) == "table" and #r.attackers or 0
            followUpAttackers[of] = math.max(followUpAttackers[of] or 0, n)
        elseif filter == "all" or r.kind == filter then
            list[#list + 1] = r
        end
    end
    return list
end

local SOLO_TAG, PARTY_TAG = "|cffE7E9EESolo|r", "|cff6FA3F2Party|r"

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
    if r.kind == "kill" then
        local size = FightSize(r)
        GameTooltip:AddDoubleLine("Fight", size > 1 and ("Party kill, " .. size .. " players") or "Solo kill",
            0.54, 0.56, 0.61, 1, 1, 1)
    end
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
    elseif ns.AwaitingDetails and ns.AwaitingDetails(r) and ns.Try(UnitAffectingCombat, "player") then
        GameTooltip:AddLine("Waiting for its details: exportable after combat", 0.95, 0.76, 0.31)
    else
        GameTooltip:AddLine("Waiting to export", 0.95, 0.76, 0.31)
    end
    GameTooltip:Show()
end

local function CreateRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(LIST_W, ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints()

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
    row.name:SetWordWrap(false)

    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.sub:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
    -- One line, cut off with "..." before the time column (wrapping would
    -- run it up into the name).
    row.sub:SetWidth(LIST_W - 42 - 64)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    if row.sub.SetMaxLines then row.sub:SetMaxLines(1) end

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
    row:Hide()
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
    local fight = ""
    if r.kind == "kill" then
        local size = FightSize(r)
        fight = (size > 1 and (PARTY_TAG .. DIM .. " " .. size .. "|r") or SOLO_TAG) .. " · "
    end
    row.sub:SetText(fight .. (desc and (desc .. " · ") or "") .. (r.subzone or r.zone or ""))

    row.honor:SetText(r.honor and (GOLD .. "+" .. r.honor .. "|r") or "")
    row.time:SetText(RelTime(r.occurred_at))

    if r.exported_at then
        row.status:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    else
        row.status:SetTexture("Interface\\COMMON\\Indicator-Yellow")
    end
    row:Show()
end

--- Put the row frames over the reports in view at the current scroll offset.
local function LayoutRows()
    if not window then return end
    local offset = window.scroll:GetVerticalScroll() or 0
    local first = math.max(0, math.floor(offset / ROW_H))
    for i, row in ipairs(rows) do
        local index = first + i
        local r = shown[index]
        if r then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_H)
            SetSolid(row.stripe, 1, 1, 1, index % 2 == 0 and 0.03 or 0)
            FillRow(row, r)
        else
            row:Hide()
            row.report = nil
        end
        -- The row under the mouse may now show another report.
        if GameTooltip:IsOwned(row) then
            if r then ShowTooltip(row) else GameTooltip:Hide() end
        end
    end
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
    mini.label:SetText(pending > 0
        and string.format("%s%d waiting to export|r", GOLD, pending)
        or DIM .. "nothing to export|r")
end

function ns.RefreshWindow()
    RefreshMini()
    if not window or not window:IsShown() then return end
    local kills, deaths, exported = 0, 0, 0
    for _, r in ipairs(WKillboardCharDB.reports) do
        if ns.IsFollowUp and ns.IsFollowUp(r) then
            -- counted under its kill
        elseif r.kind == "kill" then kills = kills + 1 else deaths = deaths + 1 end
        if r.exported_at then exported = exported + 1 end
    end
    local pending = ns.PendingCount()
    -- In combat, kills still waiting for their details aren't exportable yet.
    local ready, held = pending, 0
    if ns.ExportStatus then ready, held = ns.ExportStatus() end
    window.summary:SetText(string.format("%sKills|r %d   %sLosses|r %d   %s%d waiting to export|r%s",
        KILL_COLOR, kills, LOSS_COLOR, deaths, pending > 0 and GOLD or DIM, pending,
        held > 0 and string.format(" %s(%d after combat)|r", DIM, held) or ""))

    shown = Filtered()
    local height = #shown * ROW_H
    window.content:SetHeight(math.max(1, height))
    -- The list got shorter (cleared, filtered): don't stay scrolled past its end.
    local maxOffset = math.max(0, height - (window.scroll:GetHeight() or VIEW_H))
    if (window.scroll:GetVerticalScroll() or 0) > maxOffset then window.scroll:SetVerticalScroll(maxOffset) end
    LayoutRows()
    window.empty:SetShown(#shown == 0)

    window.exportNew:SetText(ready > 0 and string.format("Export new (%d)", ready) or "Export new")
    window.exportNew:SetEnabled(ready > 0)
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

--- The X (top left, closes) and the "-"/"+" button (top right) for the
--- window and the minimized bar. Both use the same frame template, so the
--- buttons land in exactly the same spots on each.
--- The box the title-bar buttons sit in, taken from one source so it's the
--- same on the window and the minimized bar: the top-right corner art of a
--- hidden copy of the window's template. Returns the art and where in it the
--- box is, or nil.
local boxArt
local function BoxArt()
    if boxArt ~= nil then return boxArt or nil end
    boxArt = false
    local ok, src = pcall(CreateFrame, "Frame", "CorpseRunBoxSource", UIParent, "BasicFrameTemplateWithInset")
    if not ok or type(src) ~= "table" then return nil end
    src:Hide()
    local tr = src.TopRightCorner or _G["CorpseRunBoxSourceTopRightCorner"]
    local close = src.CloseButton or _G["CorpseRunBoxSourceCloseButton"]
    if type(tr) ~= "table" or not tr.GetTexCoord or type(close) ~= "table" then return nil end
    local tw, th = tr:GetSize()
    local _, _, _, rx, ry = tr:GetPoint(1)
    local ulx, uly, llx, lly, urx = tr:GetTexCoord()
    local _, _, _, x, y = close:GetPoint(1)
    local cw, ch = close:GetSize()
    if not (tw and th and tw > 0 and th > 0 and urx and lly and cw and ch) then return nil end
    local boxC = 8 - ((x or 0) - math.floor((cw - 22) / 2)) -- box centre, in from the right edge
    local px0 = tw - (boxC + (rx or 0)) - cw / 2            -- box left, in texture pixels
    local py0 = (ry or 0) - (y or 0)                        -- box top, in texture pixels
    local function u(px) return ulx + (urx - ulx) * math.max(0, math.min(1, px / tw)) end
    local function v(py) return uly + (lly - uly) * math.max(0, math.min(1, py / th)) end
    boxArt = {
        atlas = tr.GetAtlas and tr:GetAtlas(), file = tr:GetTexture(),
        l = u(px0), r = u(px0 + cw), t = v(py0), b = v(py0 + ch), w = cw, h = ch,
    }
    return boxArt
end

--- Boxes behind the X (left, flipped) and the "-"/"+" (right). Both buttons
--- are centred 8 - mx in from their edge, so the boxes land centred on them.
local function Boxes(f, mx, y)
    local art = BoxArt()
    if not art or not y then return end
    local inset = (8 - mx) - art.w / 2
    for _, side in ipairs({ "LEFT", "RIGHT" }) do
        local t = f:CreateTexture(nil, "OVERLAY")
        if art.atlas and art.atlas ~= "" then t:SetAtlas(art.atlas) else t:SetTexture(art.file) end
        t:SetSize(art.w, art.h)
        if side == "LEFT" then
            t:SetTexCoord(art.r, art.l, art.t, art.b) -- flipped left/right
            t:SetPoint("TOPLEFT", f, "TOPLEFT", inset, y)
        else
            t:SetTexCoord(art.l, art.r, art.t, art.b)
            t:SetPoint("TOPRIGHT", f, "TOPRIGHT", -inset, y)
        end
    end
end

local function TitleButtons(f, name, text, state, tipTitle, tipText)
    local close = f.CloseButton or _G[name .. "CloseButton"]
    if type(close) ~= "table" then close = nil end
    if close then close:SetScript("OnClick", function() SetState("closed") end) end
    local MIN_W, MIN_H = 22, 18
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(MIN_W, MIN_H)
    local point, rel, relPoint, x, y, cw, ch
    if close then
        point, rel, relPoint, x, y = close:GetPoint(1)
        cw, ch = close:GetSize()
    end
    -- Centred where the template's X was.
    local mx, my = -4, -3
    if point == "TOPRIGHT" and relPoint == "TOPRIGHT" and cw and ch then
        mx = (x or 0) - math.floor((cw - MIN_W) / 2)
        my = (y or 0) - math.floor((ch - MIN_H) / 2)
    end
    -- Nudged to sit centred in the template's corner box (the X art it
    -- replaces isn't quite centred in its own button). Half pixels: the UI
    -- is usually scaled, so whole steps over- or undershoot.
    b:SetPoint("TOPRIGHT", f, "TOPRIGHT", mx + 3, my + 0.5)
    if close then
        close:SetSize(MIN_H, MIN_H) -- square, so the X art isn't stretched
        close:ClearAllPoints()
        -- same distance from the left edge as the "-"/"+" from the right
        close:SetPoint("TOPLEFT", f, "TOPLEFT", -mx + math.floor((MIN_W - MIN_H) / 2) - 3, my)
        Boxes(f, mx, y)
    end
    b:SetText(text)
    b:SetScript("OnClick", function() SetState(state) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(tipTitle)
        if tipText then GameTooltip:AddLine(tipText, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

function CreateMini()
    -- The window's own frame with everything below the title bar cut off: a
    -- holder that clips its children, with the same template inside at the
    -- window's width. Same template, width and top-left corner as the window,
    -- so it looks like its top and the buttons don't move when switching.
    local f = CreateFrame("Button", "CorpseRunMini", UIParent)
    f:SetSize(MINI_W, MINI_H)
    f:SetFrameStrata("MEDIUM")
    Draggable(f)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    if f.SetClipsChildren then f:SetClipsChildren(true) end

    local frame = CreateFrame("Frame", "CorpseRunMiniFrame", f, "BasicFrameTemplateWithInset")
    frame:SetSize(WIDTH, 120)
    frame:SetPoint("TOPLEFT")
    frame:EnableMouse(false) -- clicks and drags go to the holder
    f.frame = frame

    -- Cut just under the title bar's bottom edge line.
    local tb = frame.TitleBg or _G["CorpseRunMiniFrameTitleBg"]
    if type(tb) == "table" and tb.GetHeight then
        local th = tb:GetHeight()
        local _, _, _, _, ty = tb:GetPoint(1)
        if type(th) == "number" and th > 0 then f:SetHeight(math.floor(th - (ty or 0) + 3 + 0.5)) end
    end

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -5)
    frame.title:SetText("Corpse" .. GOLD .. "Run|r")

    f.expand = TitleButtons(frame, "CorpseRunMiniFrame", "+", "open", "Open")

    f.label = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.label:SetPoint("RIGHT", f.expand, "LEFT", -6, 0)
    f.label:SetJustifyH("RIGHT")

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

    f.minimize = TitleButtons(f, "CorpseRunWindow", "-", "min", "Minimize",
        "Shrinks to its title bar. It stays after a reload.")

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
            f.scroll:SetVerticalScroll(0)
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
    scroll:SetPoint("TOPLEFT", 12, -LIST_TOP)
    scroll:SetPoint("BOTTOMRIGHT", -32, LIST_BOTTOM)
    f.scroll = scroll
    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(LIST_W, 1)
    scroll:SetScrollChild(f.content)
    for i = 1, NUM_ROWS do rows[i] = CreateRow(f.content) end
    -- Refill the rows whenever the offset moves (drag, wheel, arrows).
    scroll:HookScript("OnVerticalScroll", LayoutRows)
    local bar = scroll.ScrollBar or _G["CorpseRunWindowScrollScrollBar"]
    if type(bar) == "table" and bar.HookScript then bar:HookScript("OnValueChanged", LayoutRows) end

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
