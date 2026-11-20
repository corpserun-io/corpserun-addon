-- CorpseRun: debug log for finding out what the Forever client exposes.
-- Saved in WKillboardCharDB.debug (never exported or sent anywhere); read it
-- from WTF/Account/<account>/<realm?>/<character>/SavedVariables/CorpseRun.lua
-- after a /reload or logout. `/cr debug` shows a summary, `/cr debug clear` empties it.
local _, ns = ...

local MAX_ENTRIES = 400

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

--- Copy a value into something SavedVariables can hold (no functions/userdata),
--- with depth, size and string-length limits.
local function Plain(v, depth, maxDepth)
    maxDepth = maxDepth or 4
    if ns.IsSecret(v) then return "<secret>" end
    local t = type(v)
    if t == "string" then return #v > 300 and (v:sub(1, 300) .. "…") or v end
    if t == "number" or t == "boolean" or t == "nil" then return v end
    if t ~= "table" then return "<" .. t .. ">" end
    if (depth or 0) >= maxDepth then return "<table>" end
    local out, n = {}, 0
    for k, val in pairs(v) do
        n = n + 1
        if n > 60 then out["…"] = "truncated"; break end
        if type(k) == "string" or type(k) == "number" then out[k] = Plain(val, (depth or 0) + 1, maxDepth) end
    end
    return out
end
ns.Plain = Plain

function ns.Debug(kind, data, maxDepth)
    local log = WKillboardCharDB and WKillboardCharDB.debug
    if not log then return end
    local entry = Plain(data or {}, 0, maxDepth) or {}
    entry.kind = kind
    entry.t = ns.Now()
    entry.zone = ns.Try(GetRealZoneText)
    local _, instanceType = ns.Try(IsInInstance)
    entry.instance = instanceType
    log[#log + 1] = entry
    while #log > MAX_ENTRIES do table.remove(log, 1) end
end

--- All return values of a call, as a list (nil -> "nil"), or the error.
local function Call(fn, ...)
    local res = { pcall(fn, ...) }
    if not res[1] then return { error = tostring(res[2]) } end
    local out = {}
    for i = 2, math.max(#res, 2) do out[i - 1] = res[i] == nil and "nil" or Plain(res[i], 1) end
    return out
end

-- ---------------------------------------------------------------------------
-- What exists on this client
-- ---------------------------------------------------------------------------

--- Global and C_* function names matching a Lua pattern (case-insensitive).
local function FindFunctions(pattern)
    local found = {}
    for key, value in pairs(_G) do
        if type(key) == "string" then
            if type(value) == "function" and key:lower():find(pattern) then
                found[#found + 1] = key
            elseif key:sub(1, 2) == "C_" and type(value) == "table" then
                for fkey, fval in pairs(value) do
                    if type(fkey) == "string" and type(fval) == "function" and (key .. "." .. fkey):lower():find(pattern) then
                        found[#found + 1] = key .. "." .. fkey
                    end
                end
            end
        end
    end
    table.sort(found)
    return found
end

local function Resolve(path)
    local a, b = path:match("^([^%.]+)%.(.+)$")
    if a then return _G[a] and _G[a][b] end
    return _G[path]
end

local deathRecapFns   -- discovered once at login (scanning _G is slow)
local meterFns        -- C_DamageMeter getters

-- Statistic IDs worth watching for a killing-blow signal (retail numbering:
-- the 1487-1510 block holds kill / killing-blow statistics; 588 honorable kills).
local STAT_IDS = { 588, 1197 }
for id = 1480, 1510 do STAT_IDS[#STAT_IDS + 1] = id end

local function Statistics()
    if not GetStatistic then return nil end
    local out = {}
    for _, id in ipairs(STAT_IDS) do
        local v = ns.Try(GetStatistic, id)
        if v ~= nil and v ~= "--" and v ~= "0" then out[tostring(id)] = v end
    end
    return out
end

-- Enum.DamageMeterType: 0 DamageDone, 7 DamageTaken, 9 Deaths, 10 EnemyDamageTaken.
-- Enum.DamageMeterSessionType: 0 Overall, 1 Current, 2 Expired.
local METER_TYPES = { 10, 9, 0 }

--- The built-in damage meter's sessions (secret during combat; read after).
--- For each source: its per-spell breakdown, and for deaths, the recap.
local function DamageMeter()
    if not C_DamageMeter then return nil end
    local out = {
        available = Call(C_DamageMeter.IsDamageMeterAvailable or function() end),
        sessions = Call(C_DamageMeter.GetAvailableCombatSessions or function() end),
    }
    for _, sessionType in ipairs({ 1, 0 }) do
        for _, meterType in ipairs(METER_TYPES) do
            local key = "s" .. sessionType .. "_t" .. meterType
            local ok, err = pcall(function()
                local session = C_DamageMeter.GetCombatSessionFromType(sessionType, meterType)
                out[key] = session
                if type(session) ~= "table" or ns.IsSecret(session) or type(session.combatSources) ~= "table" then return end
                local details = {}
                for i, src in ipairs(session.combatSources) do
                    -- Deaths: every recap. Other meters: the first 8 sources plus
                    -- always our own entry (its per-spell breakdown may name the
                    -- targets we damaged).
                    local wanted = (meterType == 9 and i <= 40) or i <= 8 or src.isLocalPlayer == true
                    if wanted then
                        local guid = ns.Str(src.sourceGUID)
                        local d = {}
                        if src.isLocalPlayer == true then guid = ns.Try(UnitGUID, "player") end
                        if guid and meterType ~= 9 and C_DamageMeter.GetCombatSessionSourceFromType then
                            d.source = Call(C_DamageMeter.GetCombatSessionSourceFromType, sessionType, meterType, guid)
                        end
                        if meterType == 9 and src.deathRecapID ~= nil and C_DeathRecap and C_DeathRecap.GetRecapEvents then
                            d.recap = Call(C_DeathRecap.GetRecapEvents, src.deathRecapID)
                        end
                        details[i] = d
                    end
                end
                out[key .. "_details"] = details
            end)
            if not ok then out[key .. "_error"] = tostring(err) end
        end
    end
    return out
end
ns.DebugStatistics, ns.DebugDamageMeter = Statistics, DamageMeter

local function ProbeApis()
    deathRecapFns = FindFunctions("deathrecap")
    meterFns = FindFunctions("^c_damagemeter%.")
    local exists = {}
    for _, name in ipairs({
        "bit", "C_EncodingUtil", "C_TooltipInfo", "GetDetailedItemLevelInfo", "C_Map", "GetCurrentRegion",
        "GetServerTime", "GetPVPSessionStats", "GetPVPLifetimeStats", "C_PvP", "GetBattlefieldScore",
        "GetNumBattlefieldScores", "RequestBattlefieldScoreData", "GetBattlefieldWinner", "UnitFullName",
        "GetNormalizedRealmName", "NotifyInspect", "C_DeathInfo", "issecretvalue", "canaccessvalue", "GetPlayerInfoByGUID",
    }) do
        exists[name] = _G[name] ~= nil
    end
    exists["C_PvP.GetScoreInfo"] = Resolve("C_PvP.GetScoreInfo") ~= nil
    exists["C_Map.GetPlayerMapPosition"] = Resolve("C_Map.GetPlayerMapPosition") ~= nil

    -- The exact honor / kill message templates this client uses.
    local strings = {}
    for key, value in pairs(_G) do
        if type(key) == "string" and type(value) == "string"
            and (key:find("^COMBATLOG_HONOR") or key:find("^COMBATLOG_DISHONOR")
                or key:find("HONORABLE_KILL") or key:find("KILLING_BLOW")) then
            strings[key] = value
        end
    end

    local _, _, _, toc = ns.Try(GetBuildInfo)
    ns.Debug("apis", {
        toc = toc,
        build = { ns.Try(GetBuildInfo) },
        region = ns.Try(GetCurrentRegion),
        realm = ns.Try(GetRealmName),
        normalizedRealm = ns.Try(GetNormalizedRealmName),
        fullName = { ns.Try(UnitFullName, "player") },
        serverTime = ns.Try(GetServerTime),
        localTime = time(),
        exists = exists,
        pvpSession = GetPVPSessionStats and Call(GetPVPSessionStats) or nil,
        pvpLifetime = GetPVPLifetimeStats and Call(GetPVPLifetimeStats) or nil,
        deathRecapFns = deathRecapFns,
        damageMeterFns = meterFns,
        statisticFns = FindFunctions("statistic"),
        statistics = Statistics(),
        deathFns = FindFunctions("^c_deathinfo"),
        surnameFns = FindFunctions("surname"),
        scoreFns = FindFunctions("battlefieldscore"),
        honorStrings = strings,
    })
end

-- ---------------------------------------------------------------------------
-- Snapshots
-- ---------------------------------------------------------------------------

--- Enemy players we can currently see (target, mouseover, nameplates).
local function VisibleEnemies()
    local out = {}
    local function add(unit)
        if not ns.Try(UnitExists, unit) or not ns.Try(UnitIsPlayer, unit) then return end
        if not ns.Try(UnitIsEnemy, "player", unit) then return end
        local _, class = ns.Try(UnitClass, unit)
        local name, second = ns.Try(UnitName, unit)
        out[#out + 1] = {
            unit = unit,
            name = name,
            nameSecond = second,               -- realm on other clients; surname on Forever?
            fullName = { ns.Try(UnitFullName, unit) },
            guid = ns.Try(UnitGUID, unit),
            level = ns.Try(UnitLevel, unit),
            class = class,
            dead = ns.Try(UnitIsDeadOrGhost, unit),
            targetingMe = ns.Try(UnitIsUnit, unit .. "target", "player"),
        }
    end
    add("target")
    add("mouseover")
    for i = 1, 40 do add("nameplate" .. i) end
    return out
end

ns.DebugVisibleEnemies = VisibleEnemies

--- Death-recap style getters, called after a short delay (data may arrive late).
local function ProbeDeathRecap()
    local results = {}
    -- The full latest recap (who hit us with what), deep enough to see its fields.
    if C_DeathRecap and C_DeathRecap.GetRecapEvents then
        local ok, events = pcall(C_DeathRecap.GetRecapEvents)
        results.events = ok and events or ("error: " .. tostring(events))
        results.link = ns.Try(C_DeathRecap.GetRecapLink)
        results.maxHealth = ns.Try(C_DeathRecap.GetRecapMaxHealth)
    end
    for _, name in ipairs(deathRecapFns or {}) do
        local short = name:match("[^%._]+$") or name
        -- Getters only: never call anything that might change state.
        if short:find("^Get") or short:find("^Has") or short:find("^Is") then
            local fn = Resolve(name)
            if type(fn) == "function" then
                results[name] = { noArgs = Call(fn), arg1 = Call(fn, 1) }
            end
        end
    end
    return results
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
local lastDeathProbe, lastKillsChanged = 0, 0

local function InBattleground()
    local _, instanceType = ns.Try(IsInInstance)
    return instanceType == "pvp"
end

local function OnEvent(event, ...)
    if event == "PLAYER_LOGIN" then
        ProbeApis()
    elseif event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
        local msg = ...
        local name, honor = ns.ParseHonor(msg or "")
        ns.Debug("honor_msg", { text = msg, parsedName = name, parsedHonor = honor, enemies = VisibleEnemies() })
    elseif event == "PLAYER_PVP_KILLS_CHANGED" then
        -- Fires several times per kill; log the first of each burst with context.
        if ns.Now() - lastKillsChanged < 3 then return end
        lastKillsChanged = ns.Now()
        ns.Debug("pvp_kills_changed", {
            canDisplayKillingBlows = C_PvP and C_PvP.CanDisplayKillingBlows and Call(C_PvP.CanDisplayKillingBlows) or nil,
            enemies = VisibleEnemies(),
            statistics = Statistics(),
            session = GetPVPSessionStats and Call(GetPVPSessionStats) or nil,
            lifetime = GetPVPLifetimeStats and Call(GetPVPLifetimeStats) or nil,
        })
    elseif event == "PLAYER_DEAD" then
        -- (The "death" entry itself is written by Recorder before it resets the fight.)
        if ns.Now() - lastDeathProbe < 10 then return end   -- Forever fires PLAYER_DEAD twice
        lastDeathProbe = ns.Now()
        if C_Timer and C_Timer.After then
            C_Timer.After(2, function()
                pcall(function() ns.Debug("death_recap", { results = ProbeDeathRecap() }, 7) end)
            end)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Combat data may only become readable after combat; look once per fight in PvP contexts.
        if ns.Now() - lastKillsChanged < 60 or InBattleground() then
            if C_Timer and C_Timer.After then
                C_Timer.After(1, function()
                    pcall(function() ns.Debug("after_combat", { statistics = Statistics(), meter = DamageMeter() }, 7) end)
                end)
            end
        end
    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        local lower = (msg or ""):lower()
        if lower:find("honor") or lower:find("kill") or lower:find("slain") then
            ns.Debug("system_msg", { text = msg })
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        local _, instanceType = ns.Try(IsInInstance)
        if instanceType == "pvp" then WKillboardCharDB.bgEntered = WKillboardCharDB.bgEntered or ns.Now() else WKillboardCharDB.bgEntered = nil end
        ns.Debug("zone", { event = event, mapId = C_Map and ns.Try(C_Map.GetBestMapForUnit, "player"), instanceInfo = { ns.Try(GetInstanceInfo) } })
    end
end

for _, e in ipairs({
    "PLAYER_LOGIN", "CHAT_MSG_COMBAT_HONOR_GAIN", "PLAYER_PVP_KILLS_CHANGED", "PLAYER_DEAD",
    "CHAT_MSG_SYSTEM", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
    "PLAYER_REGEN_ENABLED",
}) do
    pcall(frame.RegisterEvent, frame, e)
end
frame:SetScript("OnEvent", function(_, event, ...)
    -- The debug log must never break the addon.
    pcall(OnEvent, event, ...)
end)

-- ---------------------------------------------------------------------------
-- Event discovery: which kill / death / PvP events does this client fire?
-- Logs the first firing of each matching event name per 5 seconds, with args.
-- ---------------------------------------------------------------------------

local DISCOVER = { "KILL", "DIED", "DEATH", "HONOR", "PVP", "DAMAGE_METER", "COMBAT_TEXT", "SLAIN", "BLOW" }
local NOISY = { CHAT_MSG_COMBAT_HONOR_GAIN = true, PLAYER_PVP_KILLS_CHANGED = true, PLAYER_DEAD = true }
local lastSeen = {}
local discovery = CreateFrame("Frame")
if pcall(discovery.RegisterAllEvents, discovery) then
    discovery:SetScript("OnEvent", function(_, event, ...)
        if NOISY[event] or type(event) ~= "string" then return end
        local match = false
        for _, word in ipairs(DISCOVER) do if event:find(word, 1, true) then match = true; break end end
        if not match then return end
        local now = ns.Now()
        if lastSeen[event] and now - lastSeen[event] < 5 then return end
        lastSeen[event] = now
        pcall(ns.Debug, "event", { name = event, args = { ... } }, 5)
    end)
end

function ns.DebugSummary()
    local log = WKillboardCharDB.debug or {}
    local counts = {}
    for _, e in ipairs(log) do counts[e.kind] = (counts[e.kind] or 0) + 1 end
    local parts = {}
    for k, n in pairs(counts) do parts[#parts + 1] = k .. "=" .. n end
    table.sort(parts)
    ns.Print("Debug log: %d entries (%s). Saved on /reload or logout.", #log, #parts > 0 and table.concat(parts, ", ") or "empty")
end
