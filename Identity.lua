-- CorpseRun: who is who. Snapshots of players seen via target, mouseover and
-- nameplates, so kill/death reports can carry class, race, guild, etc.
-- (Forever forbids the combat log, so this is all we get.)
local _, ns = ...

local SNAPSHOT_TTL = 15 * 60
local MAX_SNAPSHOTS = 400

local snapshots = {}   -- [lower(name)] = { info = CharInfo, seen = time }
local snapshotCount = 0
local surnameFns       -- discovered surname getters

-- WoW: Forever characters have surnames; the client API for them is unknown,
-- so look for a *getter* whose name mentions the surname. Only names that start
-- with Get/Unit are considered: never call anything that could change state
-- (SetSurname, RequestSurnameChange, ...) or is protected.
local function IsSurnameGetter(fname)
    if not fname:find("Surname", 1, true) then return false end
    if not (fname:find("^Get") or fname:find("^Unit")) then return false end
    local lower = fname:lower()
    for _, verb in ipairs({ "set", "request", "change", "clear", "reset", "send", "confirm", "accept" }) do
        if lower:find(verb, 1, true) then return false end
    end
    return true
end

local function DiscoverSurnameFns()
    surnameFns = {}
    for key, value in pairs(_G) do
        if type(key) == "string" then
            if type(value) == "function" and IsSurnameGetter(key) then
                surnameFns[#surnameFns + 1] = { name = key, fn = value }
            elseif key:sub(1, 2) == "C_" and type(value) == "table" then
                for fkey, fval in pairs(value) do
                    if type(fkey) == "string" and type(fval) == "function" and IsSurnameGetter(fkey) then
                        surnameFns[#surnameFns + 1] = { name = key .. "." .. fkey, fn = fval }
                    end
                end
            end
        end
    end
end

function ns.SurnameFns()
    if not surnameFns then DiscoverSurnameFns() end
    return surnameFns
end

local surnameWinner   -- the getter that has returned a surname; used exclusively after
local surnameFailures = {}  -- [name] = count of errors; a getter that keeps erroring is dropped

function ns.GetSurname(unit)
    if surnameWinner then
        local ok, value = pcall(surnameWinner.fn, unit)
        if ok and type(value) == "string" and value ~= "" then return value end
        return nil
    end
    local fns = ns.SurnameFns()
    for i = #fns, 1, -1 do
        local entry = fns[i]
        local ok, value = pcall(entry.fn, unit)
        if ok and type(value) == "string" and value ~= "" then
            surnameWinner = entry
            return value
        elseif not ok then
            surnameFailures[entry.name] = (surnameFailures[entry.name] or 0) + 1
            if surnameFailures[entry.name] >= 3 then table.remove(fns, i) end
        end
    end
    return nil
end

--- Fill race / class / gender from a player GUID (enemy units can hide them;
--- GetPlayerInfoByGUID may still answer). Returns info.
function ns.FillFromGUID(info)
    if not info or not info.guid or (info.race and info.class and info.gender) then return info end
    local _, englishClass, localizedRace, _, sex = ns.Try(GetPlayerInfoByGUID, info.guid)
    info.class = info.class or ns.Str(englishClass)
    info.race = info.race or ns.Str(localizedRace)
    info.gender = info.gender or ns.Num(sex)
    return info
end

--- Everything we can read about a player unit, in the submission's Character shape.
function ns.CharInfo(unit)
    if not ns.Try(UnitExists, unit) or not ns.Try(UnitIsPlayer, unit) then return nil end
    local rawName, rawRealm = ns.Try(UnitName, unit)
    local name, nameSurname = ns.SplitName(rawName)
    if not name or name == "" or name == UNKNOWNOBJECT then return nil end
    local _, classFile = ns.Try(UnitClass, unit)
    local race = ns.Try(UnitRace, unit)
    local level = ns.Try(UnitLevel, unit)
    -- UnitName gives a realm only for players from other realms; the server
    -- assumes the reporter's realm otherwise. Forever is realmless.
    local realm = ns.Game() ~= "forever" and type(rawRealm) == "string" and rawRealm ~= "" and rawRealm or nil
    -- Forever is realmless. Some clients return "First Surname" as the name;
    -- others the first name, with the surname where the realm used to be
    -- (or the internal server name, for players from another server).
    local surname
    if ns.Game() == "forever" then
        surname = nameSurname or ns.SurnameFromRealmSlot(rawRealm)
        if not surname and unit == "player" then
            local _, s = ns.Try(UnitFullName, "player")
            surname = type(s) == "string" and s ~= "" and s or nil
        end
    end
    return ns.FillFromGUID({
        name = name,
        realm = realm,
        surname = surname or ns.GetSurname(unit),
        guid = ns.Try(UnitGUID, unit),
        level = (type(level) == "number" and level > 0) and level or nil,
        race = race,
        class = classFile,
        gender = ns.Try(UnitSex, unit),          -- 2 male, 3 female
        faction = ns.Try(UnitFactionGroup, unit), -- "Alliance" / "Horde"
        guild = ns.Try(GetGuildInfo, unit),
    })
end

function ns.Snapshot(unit)
    local info = ns.CharInfo(unit)
    if not info then return nil end
    local key = info.name:lower()
    if not snapshots[key] then snapshotCount = snapshotCount + 1 end
    snapshots[key] = { info = info, seen = ns.Now() }

    if snapshotCount > MAX_SNAPSHOTS then
        local cutoff = ns.Now() - SNAPSHOT_TTL
        snapshotCount = 0
        for k, v in pairs(snapshots) do
            if v.seen < cutoff then snapshots[k] = nil else snapshotCount = snapshotCount + 1 end
        end
        -- Still full of fresh ones (a very busy area): drop the oldest down to
        -- 3/4, so the next snapshots don't each sweep the whole table again.
        if snapshotCount > MAX_SNAPSHOTS then
            local keys = {}
            for k in pairs(snapshots) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return snapshots[a].seen < snapshots[b].seen end)
            local target = math.floor(MAX_SNAPSHOTS * 3 / 4)
            for i = 1, #keys - target do snapshots[keys[i]] = nil end
            snapshotCount = math.min(#keys, target)
        end
    end
    return info
end

--- Best known info for a name (fresh snapshot), or just the name.
function ns.Lookup(name)
    name = ns.ShortName(name)
    if not name then return nil end
    local snap = snapshots[name:lower()]
    local info = { name = name }
    if snap and ns.Now() - snap.seen <= SNAPSHOT_TTL then
        for k, v in pairs(snap.info) do info[k] = v end
    end
    return info
end

--- Identity probe: recorded on login into WKillboardDB.identity (/cr id).
function ns.CollectIdentity()
    local id = { collectedAt = ns.Now() }
    id.name, id.realm = ns.Try(UnitName, "player")
    id.fullName, id.fullRealm = ns.Try(UnitFullName, "player")
    id.guid = ns.Try(UnitGUID, "player")
    id.realmName = ns.Try(GetRealmName)
    id.region = ns.Try(GetCurrentRegion)
    id.game = ns.Game()
    id.faction = ns.Try(UnitFactionGroup, "player")
    id.className, id.classFile = ns.Try(UnitClass, "player")
    id.raceName, id.raceFile = ns.Try(UnitRace, "player")
    id.level = ns.Try(UnitLevel, "player")
    id.guild = ns.Try(GetGuildInfo, "player")
    local version, build, _, toc = ns.Try(GetBuildInfo)
    id.build = { version = version, build = build, toc = toc }
    local _, battleTag = ns.Try(BNGetInfo)
    id.battleTag = battleTag
    id.encodingUtil = (C_EncodingUtil and C_EncodingUtil.CompressString) and true or false
    id.surnameApis = {}
    for _, entry in ipairs(ns.SurnameFns()) do
        id.surnameApis[#id.surnameApis + 1] = { name = entry.name, player = tostring(ns.Try(entry.fn, "player")) }
    end
    return id
end
