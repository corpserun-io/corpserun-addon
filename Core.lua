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
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        WKillboardDB.identity = ns.CollectIdentity()
        ns.StartRecording()
        local pending = ns.PendingCount()
        if not ns.HasKey() then
            ns.Print("Loaded. Set up exports once: create a token on the site, then |cffffffff/cr key <token>|r.")
        elseif pending > 0 then
            ns.Print("%d kill/death report%s waiting to export. Type |cffffffff/cr|r.", pending, pending == 1 and "" or "s")
        else
            ns.Print("Loaded. Kills and deaths are recorded automatically. |cffffffff/cr|r for options.")
        end
    end
end)

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
        else
            ns.DebugSummary()
        end
    elseif cmd == "export" then
        ns.ShowExport(arg == "all" and "all" or "new")
    elseif cmd == "test" then
        ns.ShowTestExport()
    elseif cmd == "id" then
        WKillboardDB.identity = ns.CollectIdentity()
        PrintIdentity(WKillboardDB.identity)
    elseif cmd == "help" then
        ns.Print("/cr - recent kills and losses")
        ns.Print("/cr export [all] - export new (or all) reports to paste on the site")
        ns.Print("/cr key <token> - sign exports with your API token from the site")
        ns.Print("/cr test - export a test kill to check your key (not saved)")
        ns.Print("/cr id - print identity info")
        ns.Print("/cr debug [clear] - debug log summary (saved on /reload)")
        ns.Print("/corpserun works the same if another addon took /cr.")
    else
        ns.ToggleWindow()
    end
end
