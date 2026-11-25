-- CorpseRun: setup and slash commands. (The window lives in Window.lua.)
local ADDON_NAME, ns = ...

local function PrintIdentity(id)
    ns.Print("name=%s realm=%s guid=%s region=%s", tostring(id.name), tostring(id.realm), tostring(id.guid), tostring(id.region))
    ns.Print("%s %s %s L%s <%s> bnet=%s toc=%s compression=%s", tostring(id.faction), tostring(id.raceName),
        tostring(id.className), tostring(id.level), tostring(id.guild), tostring(id.battleTag),
        tostring(id.build and id.build.toc), tostring(id.encodingUtil))
    if #id.surnameApis == 0 then
        ns.Print("no API with 'surname' in its name was found")
    end
    for _, api in ipairs(id.surnameApis) do
        ns.Print("surname api: %s -> %s", api.name, api.player)
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        WKillboardDB = WKillboardDB or {}
        WKillboardCharDB = WKillboardCharDB or {}
        WKillboardCharDB.reports = WKillboardCharDB.reports or {}
        WKillboardCharDB.debug = WKillboardCharDB.debug or {}
        WKillboardCharDB.seenRecaps = WKillboardCharDB.seenRecaps or {}
        -- Random id for this character's signed log (a reinstall starts a new chain).
        WKillboardCharDB.chainId = WKillboardCharDB.chainId
            or string.format("%08x%08x", math.random(0, 0x7fffffff), (time() or 0) % 0x7fffffff)
        -- Reports recorded before signing existed get log positions in order.
        WKillboardCharDB.nextSeq = WKillboardCharDB.nextSeq or 0
        for _, r in ipairs(WKillboardCharDB.reports) do
            if not r.seq then
                WKillboardCharDB.nextSeq = WKillboardCharDB.nextSeq + 1
                r.seq = WKillboardCharDB.nextSeq
            end
        end
        -- Forever fires PLAYER_DEAD twice per death: drop duplicate death reports
        -- (a death within 10 s of the previous one) that haven't been exported.
        local kept, lastDeath = {}, nil
        for _, r in ipairs(WKillboardCharDB.reports) do
            local dup = r.kind == "death" and lastDeath and not r.exported_at
                and math.abs((r.occurred_at or 0) - lastDeath) < 10
            if r.kind == "death" then lastDeath = r.occurred_at end
            if not dup then kept[#kept + 1] = r end
        end
        WKillboardCharDB.reports = kept
        ns.PruneReports()
        pcall(ns.CompactSignatures)
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        WKillboardDB.identity = ns.CollectIdentity()
        ns.ApplyDebugMode()
        ns.StartRecording()
        local pending = ns.PendingCount()
        if not ns.HasKey() then
            ns.Print("Loaded. Set up exports once: create a token on the site, then |cffffffff/cr key <token>|r.")
        elseif pending > 0 then
            ns.Print("%d kill/death report%s waiting to export. Type |cffffffff/cr|r.", pending, pending == 1 and "" or "s")
        else
            ns.Print("Loaded. Kills and deaths are recorded automatically. |cffffffff/cr|r for options.")
        end
        ns.CheckSettings(true)
        ns.RestoreWindow()
        ns.SetupMinimapButton()
    elseif event == "CVAR_UPDATE" then
        local name = type(arg1) == "string" and arg1:lower() or ""
        if name == "damagemeterenabled" or name == "nameplateshowenemies" or name == "nameplateshowfriends"
            or name == "nameplateshowfriendlyplayers" then
            ns.CheckSettings(false)
        end
    end
end)
loader:RegisterEvent("CVAR_UPDATE")

-- Game settings CorpseRun reads from. If a player turned one off, say so: all
-- of them in one message at login, then again only when one is switched off.
-- Never switch them on for the player (the meter would pop its window up).
local SETTINGS = {
    { cvar = "damageMeterEnabled", name = "the damage meter", why = "final blows, attackers and damage" },
    { cvar = "nameplateShowEnemies", name = "enemy nameplates", why = "who attacked you and which enemy died", key = "V" },
    -- Forever (modern engine) has nameplateShowFriendlyPlayers; older clients nameplateShowFriends.
    { cvar = "nameplateShowFriends", also = "nameplateShowFriendlyPlayers", name = "friendly nameplates",
      why = "players outside your group who helped on a kill" },
}

local function CVar(name)
    local get = (C_CVar and C_CVar.GetCVar) or GetCVar
    if not get then return nil end
    local ok, v = pcall(get, name)
    return ok and v or nil
end

local function CVarOff(name)
    return CVar(name) == "0"                  -- unknown setting / no value: assume on
end

function ns.DamageMeterOff()
    if not C_DamageMeter then return false end
    return CVarOff("damageMeterEnabled")
end

local function SettingOff(s)
    if s.cvar == "damageMeterEnabled" then return ns.DamageMeterOff() end
    -- Off only when no version of it is on (a client may have just one of them).
    if s.also and CVar(s.also) == "1" then return false end
    if s.also and CVar(s.cvar) == nil then return CVarOff(s.also) end
    return CVarOff(s.cvar)
end

local function Describe(s)
    return string.format("|cffffffff%s|r (%s%s)", s.name, s.why, s.key and (", key " .. s.key) or "")
end

local lastOff = {}                            -- [cvar] = was off at the last check
local warnedAny = false

--- Prints which settings are off. login: everything that's off (once per
--- session); otherwise only settings switched off since the last check, and
--- a thank-you once everything warned about is back on.
function ns.CheckSettings(login)
    local off, newlyOff = {}, {}
    for _, s in ipairs(SETTINGS) do
        local isOff = SettingOff(s)
        if isOff then off[#off + 1] = s end
        if isOff and not lastOff[s.cvar] then newlyOff[#newlyOff + 1] = s end
        lastOff[s.cvar] = isOff
    end
    local list = login and off or newlyOff
    if #list > 0 then
        local parts = {}
        for i, s in ipairs(list) do parts[i] = Describe(s) end
        ns.Print("Turned off: %s. CorpseRun reads %s to record kills fully. Turn %s on in the game's Options.",
            table.concat(parts, "; "), #list == 1 and "it" or "them", #list == 1 and "it" or "them")
        warnedAny = true
    elseif warnedAny and #off == 0 and not login then
        warnedAny = false
        ns.Print("Thanks: the damage meter and nameplates are all on.")
    end
    return off
end
ns.CheckDamageMeter = function() ns.CheckSettings(true) end

--- /cr check: every setting and whether it's on.
function ns.SettingsStatus()
    for _, s in ipairs(SETTINGS) do
        ns.Print("%s %s: %s", SettingOff(s) and "|cffff5555off|r" or "|cff4ade80on|r", s.name, s.why)
    end
end

-- /cr clear all asks twice: the second time within 30 seconds deletes.
local clearAllAt

--- Removes reports already exported (all=true: every report, asking for
--- confirmation first when some haven't been exported yet).
--- Used by /cr clear and the window's Clear button.
function ns.ClearReports(all)
    local list = WKillboardCharDB.reports
    if all then
        local pending = ns.PendingCount()
        local now = GetTime()
        if #list > 0 and pending > 0 and not (clearAllAt and now - clearAllAt <= 30) then
            clearAllAt = now
            ns.Print("This deletes all %d saved reports, including |cffff5555%d not exported yet|r (they can't be submitted afterwards). Type |cffffffff/cr clear all|r again within 30 seconds to confirm.", #list, pending)
            return
        end
        clearAllAt = nil
        local n = ns.DropReports(function() return false end)
        ns.Print("Deleted %d report%s.", n, n == 1 and "" or "s")
    else
        local n = ns.DropReports(function(r) return not r.exported_at end)
        local left = #WKillboardCharDB.reports
        if n == 0 then
            ns.Print("Nothing to clear: no exported reports saved.%s", left > 0 and (" %d not exported yet."):format(left) or "")
        else
            ns.Print("Removed %d exported report%s.%s", n, n == 1 and "" or "s",
                left > 0 and (" Kept %d not exported yet."):format(left) or "")
        end
    end
    if ns.OnReportsChanged then pcall(ns.OnReportsChanged) end
end

-- /cr is short but another addon may claim it; /corpserun always works.
-- /wkb and /wkillboard are the old names, kept so existing habits still work.
SLASH_CORPSERUN1 = "/cr"
SLASH_CORPSERUN2 = "/corpserun"
SLASH_CORPSERUN3 = "/wkb"
SLASH_CORPSERUN4 = "/wkillboard"
SlashCmdList["CORPSERUN"] = function(msg)
    local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(%S*)")
    if cmd == "key" then
        if arg == "" then
            if ns.HasKey() then
                ns.Print("Exports are signed with token |cffffffffwkb_%s…|r. |cffffffff/cr key <token>|r to change it.", WKillboardDB.signKid)
            else
                ns.NoKeyHelp()
            end
        else
            local kid = ns.SetKey(arg)
            if kid then
                ns.SignReports()
                ns.Print("Key saved for token |cffffffffwkb_%s…|r (the token itself isn't stored). Try |cffffffff/cr test|r.", kid)
            else
                ns.Print("That isn't an API token. Copy the whole token (wkb_ + 64 characters) from the site.")
            end
        end
    elseif cmd == "debug" then
        if arg == "clear" then
            WKillboardCharDB.debug = {}
            WKillboardCharDB.debugScore = nil
            ns.Print("Debug log cleared.")
        elseif arg == "on" then
            ns.SetDebugMode(true)
            ns.Print("Debug mode on: logging to the saved debug log. |cffffffff/cr debug off|r stops it.")
        elseif arg == "off" then
            ns.SetDebugMode(false)
            ns.Print("Debug mode off. The log is kept until |cffffffff/cr debug clear|r.")
        else
            ns.DebugSummary()
        end
    elseif cmd == "export" then
        ns.ShowExport(arg == "all" and "all" or "new")
    elseif cmd == "clear" then
        ns.ClearReports(arg == "all")
    elseif cmd == "test" then
        ns.ShowTestExport()
    elseif cmd == "backfill" then
        local n = ns.Backfill()
        if n > 0 then
            ns.Print("Added %d follow-up report%s with your group's damage on kills already exported. Export to send them.", n, n == 1 and "" or "s")
        else
            ns.Print("Nothing to backfill: no exported group kill is missing damage that the debug log has.")
        end
    elseif cmd == "check" then
        ns.SettingsStatus()
    elseif cmd == "minimap" then
        ns.ToggleMinimapButton()
    elseif cmd == "id" then
        WKillboardDB.identity = ns.CollectIdentity()
        PrintIdentity(WKillboardDB.identity)
    elseif cmd == "help" then
        ns.Print("/cr - recent kills and losses")
        ns.Print("/cr export [all] - export new (or all) reports to paste on the site")
        ns.Print("/cr clear - remove reports you've already exported (/cr clear all: everything)")
        ns.Print("/cr key <token> - sign exports with your API token from the site")
        ns.Print("/cr test - export a test kill to check your key (not saved)")
        ns.Print("/cr backfill - send your group's damage for exported kills that went out without it (from the debug log)")
        ns.Print("/cr check - game settings CorpseRun needs (damage meter, nameplates)")
        ns.Print("/cr minimap - hide or show the minimap button")
        ns.Print("/cr id - print identity info")
        ns.Print("/cr debug [on/off/clear] - debug mode (off by default) and its log summary")
        ns.Print("/corpserun works the same if another addon took /cr.")
    else
        ns.ToggleWindow()
    end
end
