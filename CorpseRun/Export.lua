-- CorpseRun: signed copy/paste export for the "Submit kills" page.
--   "WKB2:<enc>:<base64 of the signed envelope JSON>"
--   enc = z  zlib-compressed (when the client has C_EncodingUtil)
--   enc = j  plain JSON (fallback)
--
-- Every report is signed with HMAC-SHA256 using a key derived from the user's
-- API token (SHA256("wkb-sign-v1|" .. token)); the site derives the same key
-- when it creates the token. Only the derived key is saved, never the token.
-- Reports are chained (seq + the previous report's signature) so edited or
-- inserted old reports stand out.
local _, ns = ...

local REGIONS = { [1] = "us", [2] = "kr", [3] = "eu", [4] = "tw" }
local SIGN_PREFIX = "wkb-sign-v1|"

function ns.PendingCount()
    local n = 0
    for _, r in ipairs(WKillboardCharDB.reports) do
        if not r.exported_at then n = n + 1 end
    end
    return n
end

function ns.HasKey()
    return type(WKillboardDB.signKey) == "string" and type(WKillboardDB.signKid) == "string"
end

--- Save the signing key derived from an API token. Returns the key id or nil.
function ns.SetKey(token)
    token = (token or ""):match("^%s*(.-)%s*$"):lower()
    if not token:match("^wkb_" .. string.rep("%x", 64) .. "$") then return nil end
    WKillboardDB.signKey = ns.ToHex(ns.SHA256(SIGN_PREFIX .. token))
    WKillboardDB.signKid = token:sub(5, 12)
    return WKillboardDB.signKid
end

--- The player as a submission Character.
function ns.PlayerReporter()
    local reporter = ns.CharInfo("player") or { name = ns.ShortName(ns.Try(UnitName, "player")) or "Unknown" }
    reporter.realm = ns.PlayerRealm()
    return reporter
end

--- Copy of a report without addon-only bookkeeping fields.
local function Clean(report)
    local out = {}
    for k, v in pairs(report) do
        if k ~= "exported_at" and k ~= "_sig" then out[k] = v end
    end
    return out
end

local function Sign(key, json)
    return ns.ToHex(ns.HMAC_SHA256(key, json))
end

--- Sign every report not yet signed with the current key, in log order. A
--- signature (and the `prev` it commits to) never changes while the key stays
--- the same; a new key re-signs the whole log.
function ns.SignReports()
    if not ns.HasKey() then return false end
    local kid, key = WKillboardDB.signKid, nil
    local prev = ""
    for _, r in ipairs(WKillboardCharDB.reports) do
        if not (r._sig and r._sig.kid == kid) then
            key = key or ns.FromHex(WKillboardDB.signKey)
            r.reporter = r.reporter or ns.PlayerReporter()
            local copy = Clean(r)
            copy.prev = prev
            copy.chain = WKillboardCharDB.chainId
            local json = ns.ToJSON(copy)
            r._sig = { kid = kid, r = json, s = Sign(key, json) }
        end
        prev = r._sig.s
    end
    return true
end

--- Signed envelope around already-signed report entries ({ r = json, s = sig }).
local function Envelope(entries)
    local key = ns.FromHex(WKillboardDB.signKey)
    local h = ns.ToJSON({
        addon_version = ns.VERSION,
        game = ns.Game(),
        region = REGIONS[ns.Try(GetCurrentRegion) or 0],
        client_time = ns.Now(),
        reporter = ns.PlayerReporter(),
    })
    return { v = 2, kid = WKillboardDB.signKid, h = h, hs = Sign(key, h), reports = entries }
end

local function Compress(json)
    if not (C_EncodingUtil and C_EncodingUtil.CompressString and C_EncodingUtil.EncodeBase64) then return nil end
    local method = Enum and Enum.CompressionMethod and Enum.CompressionMethod.Zlib
    if not method then return nil end
    local compressed = ns.Try(C_EncodingUtil.CompressString, json, method)
    local encoded = compressed and ns.Try(C_EncodingUtil.EncodeBase64, compressed)
    return encoded
end

function ns.Encode(envelope)
    local json = ns.ToJSON(envelope)
    local z = Compress(json)
    if z then return "WKB2:z:" .. z end
    return "WKB2:j:" .. ns.Base64(json)
end

--- Returns the blob and report count (or nil, 0, reason), and marks exported reports.
--- mode: "new" (not yet exported) or "all".
function ns.Export(mode)
    if not ns.HasKey() then return nil, 0, "nokey" end
    -- Pick up killmails the damage meter has ready (out of combat), so a kill
    -- from just now goes out with its attackers and damage, not bare.
    if ns.ScanKillmails then pcall(ns.ScanKillmails, true) end
    ns.SignReports()
    local entries = {}
    for _, r in ipairs(WKillboardCharDB.reports) do
        if mode == "all" or not r.exported_at then
            entries[#entries + 1] = { r = r._sig.r, s = r._sig.s }
        end
    end
    if #entries == 0 then return nil, 0, "empty" end
    local blob = ns.Encode(Envelope(entries))
    local now = ns.Now()
    for _, r in ipairs(WKillboardCharDB.reports) do
        if mode == "all" or not r.exported_at then r.exported_at = now end
    end
    return blob, #entries
end

local function NoKeyHelp()
    ns.Print("Exports are signed with your API token. On CorpseRun.io open |cffffffffAPI tokens|r, "
        .. "create a token, then type |cffffffff/cr key <token>|r here (only a key derived from it is saved).")
end
ns.NoKeyHelp = NoKeyHelp

-- ---------------------------------------------------------------------------
-- Export window
-- ---------------------------------------------------------------------------

local exportFrame

local function CreateExportFrame()
    local f = CreateFrame("Frame", "CorpseRunExportFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(540, 320)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "CorpseRunExportFrame") -- Escape closes it

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOP", 0, -5)
    f.title:SetText("CorpseRun export")

    f.help = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.help:SetPoint("TOPLEFT", 14, -32)
    f.help:SetPoint("TOPRIGHT", -14, -32)
    f.help:SetJustifyH("LEFT")

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -72)
    scroll:SetPoint("BOTTOMRIGHT", -34, 46)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(480)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(0)
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    -- Read-only: undo any typing so the blob can't be corrupted by accident.
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput and f.blob then
            self:SetText(f.blob)
            self:HighlightText()
        end
    end)
    edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    scroll:SetScrollChild(edit)
    f.edit = edit

    local select = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    select:SetSize(120, 24)
    select:SetPoint("BOTTOMLEFT", 14, 14)
    select:SetText("Select all")
    select:SetScript("OnClick", function()
        edit:SetFocus()
        edit:HighlightText()
    end)

    local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    close:SetSize(100, 24)
    close:SetPoint("BOTTOMRIGHT", -14, 14)
    close:SetText("Close")
    close:SetScript("OnClick", function() f:Hide() end)

    f:Hide()
    return f
end

--- Show a blob in the export window. note: extra help text.
function ns.ShowBlob(blob, count, note)
    exportFrame = exportFrame or CreateExportFrame()
    exportFrame.blob = blob
    exportFrame.help:SetText(string.format(
        "%s%d report%s. Press |cffffffffCtrl+C|r to copy, then paste it on CorpseRun.io under |cffffffffSubmit kills|r.",
        note or "", count, count == 1 and "" or "s"))
    exportFrame.edit:SetText(blob)
    exportFrame:Show()
    exportFrame.edit:SetFocus()
    exportFrame.edit:HighlightText()
end

function ns.ShowExport(mode)
    local blob, count, reason = ns.Export(mode or "new")
    if reason == "nokey" then return NoKeyHelp() end
    if not blob then
        ns.Print("Nothing new to export. Use |cffffffff/cr export all|r to export the last 14 days again.")
        return
    end
    ns.ShowBlob(blob, count)
    if ns.Try(UnitAffectingCombat, "player") then
        ns.Print("Still in combat: kill details (attackers, damage, fight length) are added once you leave combat. Export again after.")
    end
    if ns.OnReportsChanged then ns.OnReportsChanged() end
end

--- A fake kill flagged "test": the site validates it but never stores it.
function ns.ShowTestExport()
    if not ns.HasKey() then return NoKeyHelp() end
    local victim = ns.CharInfo("target")
    if not victim or ns.Try(UnitIsUnit, "target", "player") then
        victim = { name = "Testdummy", level = 60, race = "Human", class = "PALADIN", faction = "Alliance", gender = 3 }
    end
    local report = {
        client_id = string.format("test-%d", ns.Now()),
        kind = "kill",
        occurred_at = ns.Now(),
        zone = ns.Try(GetRealZoneText) or "Unknown",
        victim = victim,
        honor = 1,
        group_size = 1,
        test = true,
        seq = 0,
        prev = "",
        chain = WKillboardCharDB.chainId,
        reporter = ns.PlayerReporter(),
    }
    local json = ns.ToJSON(report)
    local entry = { r = json, s = Sign(ns.FromHex(WKillboardDB.signKey), json) }
    ns.ShowBlob(ns.Encode(Envelope({ entry })), 1, "|cff3DDC84TEST|r (not saved by the site; checks your key): ")
end
