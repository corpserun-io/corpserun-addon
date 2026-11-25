-- CorpseRun: turns game events into kill / death reports.
--
-- Forever forbids COMBAT_LOG_EVENT_UNFILTERED, so:
--   * kills  come from honor messages (CHAT_MSG_COMBAT_HONOR_GAIN) where the
--            client sends them, else from the honorable-kill counter
--            (PLAYER_PVP_KILLS_CHANGED) with the victim found among dead enemy
--            units or, in battlegrounds, from scoreboard death counts
--   * deaths come from PLAYER_DEAD, with attackers guessed from enemy players
--     who were targeting us while we took damage (UNIT_COMBAT on "player")
-- Reports use the server's submission format (docs/KILL_SUBMISSION.md).
local _, ns = ...

local KEEP_DAYS = 14
local MAX_REPORTS = 500
local SUSPECT_WINDOW = 20      -- seconds an enemy targeting us counts as an attacker
local DUPLICATE_WINDOW = 5     -- same victim twice within this = one kill
local DEATH_DEDUPE = 10        -- Forever fires PLAYER_DEAD twice per death

local GEAR_SLOTS = {
    [1] = "head", [2] = "neck", [3] = "shoulder", [4] = "shirt", [5] = "chest",
    [6] = "waist", [7] = "legs", [8] = "feet", [9] = "wrist", [10] = "hands",
    [11] = "finger1", [12] = "finger2", [13] = "trinket1", [14] = "trinket2",
    [15] = "back", [16] = "mainhand", [17] = "offhand", [18] = "ranged", [19] = "tabard",
}
local QUALITY = { [0] = "poor", "common", "uncommon", "rare", "epic", "legendary", "artifact", "heirloom" }

-- Combat state for the current fight (reset on leaving combat / death).
local fight = { since = nil, damage = 0, suspects = {} }

--- Current fight state, for the debug log.
function ns.FightSnapshot()
    local suspects = {}
    for name, s in pairs(fight.suspects) do
        suspects[#suspects + 1] = { name = name, hits = s.hits, last = s.last, class = s.info and s.info.class, level = s.info and s.info.level }
    end
    return { since = fight.since, damage = fight.damage, suspects = suspects }
end
local lastKill = { name = nil, at = 0, source = nil }
local counter = 0

-- Kills recorded without their details: the killmail / meter details only
-- become readable out of combat. Cleared by the first full meter scan after
-- them. (Session only: weak keys, so replaced reports just drop out.)
local awaiting = setmetatable({}, { __mode = "k" })

--- Can the game's damage meter add details to kills on this client?
local function MeterUsable()
    return C_DamageMeter and C_DamageMeter.GetCombatSessionFromType and C_DeathRecap and C_DeathRecap.GetRecapEvents
        and not (ns.DamageMeterOff and ns.DamageMeterOff()) and true or false
end

--- Is this kill still waiting for details the meter will add after combat?
function ns.AwaitingDetails(r)
    return awaiting[r] == true
end

local function Reports()
    return WKillboardCharDB.reports
end

local function NewClientId(kind)
    counter = counter + 1
    return string.format("%s-%d-%d-%d", kind, ns.Now(), math.floor((GetTime() % 1000) * 1000), counter)
end

local function Location()
    local loc = {
        zone = ns.Try(GetRealZoneText) or ns.Try(GetZoneText) or "Unknown",
    }
    local sub = ns.Try(GetSubZoneText)
    if sub and sub ~= "" and sub ~= loc.zone then loc.subzone = sub end
    if C_Map then
        local mapId = ns.Try(C_Map.GetBestMapForUnit, "player")
        if mapId then
            loc.map_id = mapId
            local pos = ns.Try(C_Map.GetPlayerMapPosition, mapId, "player")
            if pos and pos.x then
                loc.x = math.floor(pos.x * 10000 + 0.5) / 10000
                loc.y = math.floor(pos.y * 10000 + 0.5) / 10000
            end
        end
    end
    local _, instanceType = ns.Try(IsInInstance)
    loc.instance_type = instanceType
    return loc
end

--- A copy of just the location fields of a report or Location() result.
local LOCATION_KEYS = { "zone", "subzone", "map_id", "x", "y", "instance_type" }
local function CopyLocation(from)
    local loc = {}
    for _, k in ipairs(LOCATION_KEYS) do loc[k] = from[k] end
    return loc
end

local function GroupSize()
    local n = ns.Try(GetNumGroupMembers) or 0
    return n > 0 and n or 1
end

-- ---------------------------------------------------------------------------
-- Our group on a kill. Open-world kills have no killmail (the meter lists
-- enemy deaths only in battlegrounds), so who else fought comes from the
-- group. With no attackers on a report the site credits the reporter alone,
-- which is right for a 1v1 but not for a party kill.
-- ---------------------------------------------------------------------------

--- The other members of our group, as unit tokens.
local function GroupUnits()
    local out = {}
    if (ns.Try(GetNumGroupMembers) or 0) == 0 then return out end
    local prefix, count = "party", 4
    if ns.Try(IsInRaid) then prefix, count = "raid", 40 end
    for i = 1, count do
        local unit = prefix .. i
        if ns.Try(UnitExists, unit) and not ns.Try(UnitIsUnit, unit, "player") then out[#out + 1] = unit end
    end
    return out
end

--- Group members in the fight right now: in combat (or dead) and in range
--- (when the client can tell). Characters, without damage.
local function GroupInFight()
    local out = {}
    for _, unit in ipairs(GroupUnits()) do
        local fighting = ns.Try(UnitAffectingCombat, unit) == true
            or ns.Try(UnitIsDead or UnitIsDeadOrGhost, unit) == true
        local inRange, checked = ns.Try(UnitInRange, unit)
        if fighting and not (checked == true and inRange ~= true) then
            local info = ns.CharInfo(unit)
            if info then out[#out + 1] = info end
        end
    end
    return out
end

local function Store(report)
    -- Position in this character's signed log, and who recorded it.
    WKillboardCharDB.nextSeq = (WKillboardCharDB.nextSeq or 0) + 1
    report.seq = WKillboardCharDB.nextSeq
    report.reporter = ns.PlayerReporter()
    local list = Reports()
    list[#list + 1] = report
    local excess = #list - MAX_REPORTS
    if excess > 0 then
        local i = 0
        ns.DropReports(function() i = i + 1; return i > excess end)
    end
    -- Sign now (when a key is set) so exporting stays instant.
    if ns.SignReports then pcall(ns.SignReports) end
end

--- Remove the reports `keep` says no to; returns how many went. The newest
--- dropped signature is remembered (chainTail), so a report signed after the
--- list empties still points back at it: the site checks the chain.
function ns.DropReports(keep)
    local kept, removed, tail = {}, 0, nil
    for _, r in ipairs(Reports()) do
        if keep(r) then
            kept[#kept + 1] = r
        else
            removed = removed + 1
            if r._sig and (not tail or (r.seq or 0) > tail.seq) then
                tail = { kid = r._sig.kid, s = r._sig.s, seq = r.seq or 0 }
            end
        end
    end
    local cur = WKillboardCharDB.chainTail
    if tail and not (cur and (cur.seq or 0) > tail.seq) then WKillboardCharDB.chainTail = tail end
    WKillboardCharDB.reports = kept
    return removed
end

--- Clear the signatures of the reports from position `from` to the end, so
--- the next SignReports signs them again with their current contents and the
--- right `prev`. Only for reports not exported yet (the site has seen none of
--- those signatures); changes nothing and returns false if one was exported.
local function Unsign(from)
    local list = Reports()
    for i = from, #list do if list[i].exported_at then return false end end
    for i = from, #list do list[i]._sig = nil end
    return true
end

--- Drop reports older than KEEP_DAYS.
function ns.PruneReports()
    local cutoff = ns.Now() - KEEP_DAYS * 86400
    ns.DropReports(function(r) return (r.occurred_at or 0) >= cutoff end)
end

-- ---------------------------------------------------------------------------
-- Honor messages -> kill reports
-- ---------------------------------------------------------------------------

-- Turn a GlobalStrings format ("%s dies, honorable kill Rank: %s (Estimated Honor Points: %d)")
-- into a Lua pattern plus the order of its %s / %d captures.
local function FormatToPattern(fmt)
    local kinds = {}
    for spec in fmt:gmatch("%%%d*%$?([sd])") do kinds[#kinds + 1] = spec end
    -- Swap tokens for placeholders, escape pattern magic, then insert captures.
    local pattern = fmt:gsub("%%%d*%$?s", "\001"):gsub("%%%d*%$?d", "\002")
    pattern = pattern:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1")
    pattern = pattern:gsub("\001", "(.+)"):gsub("\002", "(%%d+)")
    return "^" .. pattern .. "$", kinds
end

local honorPatterns
local function HonorPatterns()
    if honorPatterns then return honorPatterns end
    honorPatterns = {}
    for _, key in ipairs({ "COMBATLOG_HONORGAIN", "COMBATLOG_HONORGAIN_NO_RANK", "COMBATLOG_HONORGAIN_EXHAUSTION1" }) do
        local fmt = _G[key]
        if type(fmt) == "string" and fmt:find("%%") then
            local pattern, kinds = FormatToPattern(fmt)
            honorPatterns[#honorPatterns + 1] = { pattern = pattern, kinds = kinds }
        end
    end
    -- English fallbacks (incl. the wording the old ForeverKillmails addon saw).
    honorPatterns[#honorPatterns + 1] = { pattern = "^(.+) dies, honorable kill", kinds = { "s" } }
    honorPatterns[#honorPatterns + 1] = { pattern = "awarded (%d+) honor points? for killing ([^%.!]+)", kinds = { "d", "s" } }
    return honorPatterns
end

--- Returns victim name, honor (number or nil) and surname (Forever, when the
--- message has "First Surname") from an honor message, or nil.
function ns.ParseHonor(msg)
    for _, p in ipairs(HonorPatterns()) do
        local caps = { msg:match(p.pattern) }
        if caps[1] then
            local name, honor
            for i, kind in ipairs(p.kinds) do
                if kind == "s" and not name then name = caps[i] end
                if kind == "d" and not honor then honor = tonumber(caps[i]) end
            end
            if not honor then honor = tonumber(msg:match("(%d+)%)?%.?%s*$")) end
            if name then
                local first, surname = ns.SplitName(name)
                return first, honor, surname
            end
        end
    end
    return nil
end

--- Store a kill report. victim: Character table (at least a name).
--- killerIsMe: we landed the killing blow (when known).
local function RecordKill(victim, honor, killerIsMe, source)
    local now = ns.Now()
    lastKill.name, lastKill.at, lastKill.source = victim.name, now, source
    victim = ns.FillFromGUID(victim)
    local report = Location()
    report.client_id = NewClientId("k")
    report.kind = "kill"
    report.occurred_at = now
    report.victim = victim
    report.honor = honor
    report.group_size = GroupSize()
    if killerIsMe then report.killer = ns.PlayerReporter() end
    -- Group members fighting alongside us (open world; battlegrounds have
    -- killmails). The meter's breakdown replaces this after combat if it can.
    if report.instance_type ~= "pvp" then
        local mates = GroupInFight()
        if #mates > 0 then report.attackers = mates end
    end
    if MeterUsable() then awaiting[report] = true end
    Store(report)
    ns.Print("Recorded kill: |cffffffff%s|r%s. %d to export (/cr).",
        victim.name, honor and string.format(" (+%d honor)", honor) or "", ns.PendingCount())
    if ns.OnReportsChanged then ns.OnReportsChanged() end
end

local function OnHonorMessage(msg)
    local name, honor, surname = ns.ParseHonor(msg or "")
    if not name then
        -- "You have been awarded N Honor." (no victim): remember it for a counter kill.
        local award = tonumber((msg or ""):match("(%d+)"))
        if award then ns.lastHonorAward = { amount = award, at = ns.Now() } end
        return
    end
    local now = ns.Now()
    if lastKill.name == name and now - lastKill.at <= DUPLICATE_WINDOW then return end
    -- Prefer a live read of the target if it's the victim.
    local victim
    if ns.ShortName(ns.Try(UnitName, "target")) == name then victim = ns.CharInfo("target") end
    victim = victim or ns.Lookup(name) or { name = name }
    victim.surname = victim.surname or surname
    RecordKill(victim, honor, nil, "honor_message")
end

-- ---------------------------------------------------------------------------
-- Kills from the honorable-kill counter (Forever sends no "X dies" message)
--
-- The counter says *that* we got an honorable kill; the victim is, in order:
--   1. an enemy player reported by UNIT_DIED (12.x engines) around the kill
--   2. an enemy whose nameplate vanished while dead around the kill
--   3. a dead enemy still visible (target / nameplates), not already counted
--   4. an enemy whose nameplate vanished around the kill (no death flag)
-- The same everywhere (world PvP and battlegrounds): no scoreboard.
-- ---------------------------------------------------------------------------

local RESOLVE_DELAY = 1.5      -- let deaths, nameplates and honor messages settle
local RESOLVE_TIMEOUT = 12     -- give up identifying a victim after this
local hkCount                  -- last seen session honorable kills
local pending = {}             -- kills waiting for a victim: { at = time, clock = GetTime }
local recentVictims = {}       -- [name] = time recorded (avoid double counting)
local removed = {}             -- vanished enemy nameplates: { info, at, dead }
local died = {}                -- UNIT_DIED player deaths: { guid, at, loc }
local ResolvePending           -- (defined below)

local function Clock() return (GetTime and ns.Num(GetTime())) or ns.Now() end

local function SessionHK()
    return tonumber((ns.Try(GetPVPSessionStats)))
end

-- Faction by race, for players we've never seen as a unit.
local RACE_FACTION = {
    ["Human"] = "Alliance", ["Dwarf"] = "Alliance", ["Night Elf"] = "Alliance", ["Gnome"] = "Alliance",
    ["Draenei"] = "Alliance", ["Worgen"] = "Alliance",
    ["Orc"] = "Horde", ["Undead"] = "Horde", ["Tauren"] = "Horde", ["Troll"] = "Horde",
    ["Blood Elf"] = "Horde", ["Goblin"] = "Horde",
}

--- Character from a player GUID: name / surname / class / race / gender from
--- GetPlayerInfoByGUID, plus what snapshots know (level, guild, faction).
local function CharFromGUID(guid)
    local _, englishClass, localizedRace, _, sex, name, second = ns.Try(GetPlayerInfoByGUID, guid)
    name = ns.Str(name)
    if not name or name == "" then return nil end
    local first, nameSurname = ns.SplitName(name)
    name = first
    local info = ns.Lookup(name) or { name = name }
    second = ns.Str(second)
    if ns.Game() == "forever" then
        -- Forever: the surname is in the name or where other clients return the realm.
        info.surname = info.surname or nameSurname or ns.SurnameFromRealmSlot(second)
    elseif second and second ~= "" then
        info.realm = info.realm or second
    end
    info.guid = guid
    info.class = info.class or ns.Str(englishClass)
    info.race = info.race or ns.Str(localizedRace)
    info.gender = info.gender or ns.Num(sex)
    info.faction = info.faction or (info.race and RACE_FACTION[info.race]) or nil
    return info
end
ns.CharFromGUID = CharFromGUID

local function InMyGroup(guid)
    if IsGUIDInGroup then return ns.Try(IsGUIDInGroup, guid) == true end
    for i = 1, 40 do if ns.Try(UnitGUID, "raid" .. i) == guid then return true end end
    for i = 1, 4 do if ns.Try(UnitGUID, "party" .. i) == guid then return true end end
    return false
end

--- An enemy player's death (not ours, not our group's, not our faction's).
local function IsEnemyDeath(guid, info)
    if guid == ns.Try(UnitGUID, "player") or InMyGroup(guid) then return false end
    local mine = ns.Try(UnitFactionGroup, "player")
    if info.faction and mine then return info.faction ~= mine end
    return true
end

local function OnUnitDied(guid)
    guid = ns.Str(guid)                       -- secret / missing -> nil
    if not guid or not guid:find("^Player%-") then return end
    -- Where we were when they died: the location a later killmail uses.
    died[#died + 1] = { guid = guid, at = Clock(), loc = Location() }
    while #died > 40 do table.remove(died, 1) end
    if #pending > 0 then pcall(ResolvePending) end
end

--- Enemy players that are dead on target / mouseover / focus / nameplates.
local function DeadEnemies()
    local out, seen = {}, {}
    local function check(unit)
        if ns.Try(UnitExists, unit) and ns.Try(UnitIsPlayer, unit) and ns.Try(UnitIsEnemy, "player", unit)
            and ns.Try(UnitIsDeadOrGhost, unit) then
            local info = ns.CharInfo(unit)
            if info and not seen[info.name] then
                seen[info.name] = true
                out[#out + 1] = info
            end
        end
    end
    check("target"); check("mouseover"); check("focus")
    for i = 1, 40 do check("nameplate" .. i) end
    return out
end

local function OnNameplateRemoved(unit)
    if not unit or not ns.Try(UnitIsPlayer, unit) or not ns.Try(UnitIsEnemy, "player", unit) then return end
    local info = ns.CharInfo(unit)
    if not info then return end
    removed[#removed + 1] = { info = info, at = Clock(), dead = ns.Try(UnitIsDeadOrGhost, unit) == true }
    while #removed > 40 do table.remove(removed, 1) end
end

--- Give each pending kill a victim; record the ones that resolve.
ResolvePending = function()
    if #pending == 0 then return end
    local now = ns.Now()
    -- A kill an honor message already recorded (clients that send them) is done.
    if lastKill.source == "honor_message" and now - lastKill.at <= 5 then
        table.remove(pending, 1)
        lastKill.source = nil
        if #pending == 0 then return end
    end
    local killClock = pending[1].clock

    local candidates, seenNames = {}, {}
    local function add(info, via, window)
        if not (info and info.name) or seenNames[info.name] then return end
        local last = recentVictims[info.name]
        if last and now - last <= (window or 20) then return end
        seenNames[info.name] = true
        candidates[#candidates + 1] = { info = info, via = via }
    end

    -- 1. UNIT_DIED: an enemy player that died around the kill, closest first.
    local nearDied = {}
    for _, d in ipairs(died) do
        local dt = d.at - killClock
        if dt >= -4 and dt <= 3 then nearDied[#nearDied + 1] = d end
    end
    table.sort(nearDied, function(a, b) return math.abs(a.at - killClock) < math.abs(b.at - killClock) end)
    for _, d in ipairs(nearDied) do
        local info = CharFromGUID(d.guid)
        if info and IsEnemyDeath(d.guid, info) then add(info, "unit_died") end
    end
    -- 2-4. Nameplates and visible corpses.
    local near = {}
    for _, r in ipairs(removed) do
        local dt = r.at - killClock
        if dt >= -4 and dt <= 2.5 then near[#near + 1] = r end
    end
    table.sort(near, function(a, b) return a.at > b.at end)
    for _, r in ipairs(near) do if r.dead then add(r.info, "nameplate_dead") end end
    for _, info in ipairs(DeadEnemies()) do add(info, "visible_dead", 90) end
    for _, r in ipairs(near) do if not r.dead then add(r.info, "nameplate_gone") end end

    if ns.DebugEnabled() then
        local dbgDied, dbgRemoved = {}, {}
        for _, d in ipairs(died) do
            if math.abs(d.at - killClock) <= 10 then
                local info = CharFromGUID(d.guid)
                dbgDied[#dbgDied + 1] = { guid = d.guid, name = info and info.name, faction = info and info.faction,
                    dt = math.floor((d.at - killClock) * 10 + 0.5) / 10 }
            end
        end
        for _, r in ipairs(removed) do
            if math.abs(r.at - killClock) <= 10 then
                dbgRemoved[#dbgRemoved + 1] = { name = r.info.name, dead = r.dead, dt = math.floor((r.at - killClock) * 10 + 0.5) / 10 }
            end
        end
        pcall(ns.Debug, "kill_resolve", { pending = #pending, candidates = #candidates,
            first = candidates[1] and candidates[1].info.name, via = candidates[1] and candidates[1].via,
            died = dbgDied, removals = dbgRemoved })
    end

    local honor = ns.lastHonorAward and now - ns.lastHonorAward.at <= 5 and ns.lastHonorAward.amount or nil
    while #pending > 0 and #candidates > 0 do
        table.remove(pending, 1)
        local c = table.remove(candidates, 1)
        recentVictims[c.info.name] = now
        RecordKill(c.info, honor, false, c.via)
        honor = nil
    end
    -- Unidentified kills expire.
    for i = #pending, 1, -1 do
        if now - pending[i].at > RESOLVE_TIMEOUT then
            table.remove(pending, i)
            -- Usually a group kill we weren't part of: debug log only, no chat noise.
            if ns.DebugEnabled() then pcall(ns.Debug, "kill_unresolved", {}) end
        end
    end
end

local function OnKillsChanged()
    local count = SessionHK()
    if not count then return end
    if hkCount and count > hkCount then
        for _ = 1, math.min(count - hkCount, 10) do pending[#pending + 1] = { at = ns.Now(), clock = Clock() } end
        -- The victim's death / nameplate can come a moment after the counter
        -- moves: retry a few times (the last attempt expires anything unresolved).
        local resolve = function() pcall(ResolvePending) end
        if C_Timer and C_Timer.After then
            for _, delay in ipairs({ RESOLVE_DELAY, 3, 5, 8, RESOLVE_TIMEOUT + 1 }) do C_Timer.After(delay, resolve) end
        else
            resolve()
        end
    end
    hkCount = count
end

local function OnEnterWorld()
    hkCount = SessionHK()
    pending = {}
end

-- ---------------------------------------------------------------------------
-- Deaths -> death reports
-- ---------------------------------------------------------------------------

local function ScanUnitForSuspect(unit, now)
    if not ns.Try(UnitExists, unit) or not ns.Try(UnitIsPlayer, unit) then return end
    if not ns.Try(UnitIsEnemy, "player", unit) then return end
    if not ns.Try(UnitIsUnit, unit .. "target", "player") then return end
    local info = ns.Snapshot(unit)
    if not info then return end
    local s = fight.suspects[info.name] or { hits = 0 }
    s.info, s.last, s.hits = info, now, s.hits + 1
    fight.suspects[info.name] = s
end

local SUSPECT_SCAN_INTERVAL = 0.5  -- seconds between scans while we take damage
local plates = {}                  -- [unit] = true for nameplates currently shown
local lastSuspectScan

--- The nameplates shown right now (after login / a loading screen; the
--- NAME_PLATE_UNIT_* events keep it current after that).
local function SeedPlates()
    plates = {}
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if ns.Try(UnitExists, unit) then plates[unit] = true end
    end
end

-- Who is attacking us? Enemy players (target, focus, nameplates) targeting us.
-- Runs on our damage taken, which can be many times a second: at most every
-- SUSPECT_SCAN_INTERVAL, and only over nameplates that exist.
local function ScanSuspects()
    local clock = Clock()
    if lastSuspectScan and clock - lastSuspectScan >= 0 and clock - lastSuspectScan < SUSPECT_SCAN_INTERVAL then return end
    lastSuspectScan = clock
    local now = ns.Now()
    ScanUnitForSuspect("target", now)
    ScanUnitForSuspect("focus", now)
    for unit in pairs(plates) do ScanUnitForSuspect(unit, now) end
end

local function ResetFight()
    fight.since, fight.damage, fight.suspects = nil, 0, {}
end

-- Enchant text from the in-game tooltip (modern clients expose C_TooltipInfo).
local function EnchantText(slot)
    if not (C_TooltipInfo and C_TooltipInfo.GetInventoryItem) then return nil end
    local data = ns.Try(C_TooltipInfo.GetInventoryItem, "player", slot)
    local enchantType = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.ItemEnchantmentPermanent
    if type(data) ~= "table" or type(data.lines) ~= "table" or not enchantType then return nil end
    for _, line in ipairs(data.lines) do
        if line.type == enchantType and type(line.leftText) == "string" then
            return (line.leftText:gsub("^Enchanted: ", ""))
        end
    end
    return nil
end

local function GearSnapshot()
    local gear = {}
    for slot, slotName in pairs(GEAR_SLOTS) do
        local link = ns.Try(GetInventoryItemLink, "player", slot)
        -- item:itemID:enchantID:gem1:gem2:gem3:gem4:suffixID:...
        local itemString = link and link:match("item:([%-%d:]+)")
        local fields, i = {}, 0
        if itemString then
            -- Index explicitly: empty fields ("::") are nil and must keep their position.
            for v in (itemString .. ":"):gmatch("(%-?%d*):") do
                i = i + 1
                fields[i] = tonumber(v)
            end
        end
        local itemId = fields[1]
        if itemId then
            local item = {
                slot = slotName,
                item_id = itemId,
                name = link:match("|h%[(.-)%]|h"),      -- includes random suffixes ("of the Eagle")
                link = "item:" .. itemString,
                enchant_id = (fields[2] or 0) > 0 and fields[2] or nil,
                suffix_id = (fields[7] or 0) ~= 0 and fields[7] or nil,
                enchant = EnchantText(slot),
            }
            local _, _, quality, itemLevel = ns.Try(GetItemInfo, link)
            local detailed = ns.Try(GetDetailedItemLevelInfo, link)
            item.item_level = detailed or itemLevel
            item.quality = quality and QUALITY[quality]
            gear[#gear + 1] = item
        end
    end
    table.sort(gear, function(a, b) return a.slot < b.slot end)
    return gear
end

local lastDeathAt = 0

--- "Jute Gyte" -> { name = "Jute", surname = "Gyte" } (Forever full names),
--- filled in from snapshots and the player GUID.
local function CharFromFullName(full, guid)
    local name, surname = ns.SplitName(full)
    local info = ns.Lookup(name) or { name = name }
    info.surname = info.surname or surname
    info.guid = info.guid or guid
    return ns.FillFromGUID(info)
end

--- Read the death recap (killer, abilities, damage per attacker). Returns
--- { attackers = {...}, killer = Character, damage = n, duration = n } or nil.
--- Parse a death recap (events newest first) into who died, who hit them with
--- what and how hard, and who landed the killing blow. Players only (pets and
--- NPCs count toward damage taken but aren't attackers). The victim's own hits
--- (a warlock's Life Tap or Hellfire) count as damage taken but never make them
--- an attacker: when they finished themselves, the newest enemy hit before
--- that gets the killing blow. selfGUID: the victim when the events don't say.
local function ParseRecap(events, selfGUID)
    if type(events) ~= "table" or #events == 0 then return nil end
    local byName, order, total, first, last = {}, {}, 0, nil, nil
    local killer
    local sources = {}                         -- every source GUID (incl. pets)
    local victimFull, victimGUID = ns.Str(events[1].destName), ns.Str(events[1].destGUID)
    local victimSelf = victimGUID or selfGUID
    for _, e in ipairs(events) do
        local srcGUID = ns.Str(e.sourceGUID)
        if srcGUID then sources[srcGUID] = true end
        local amount = ns.Num(e.amount)
        local ts = ns.Num(e.timestamp)
        if ts then first = math.min(first or ts, ts); last = math.max(last or ts, ts) end
        if amount and amount > 0 then total = total + amount end
        local src, guid = ns.Str(e.sourceName), ns.Str(e.sourceGUID)
        if src and guid and guid:find("^Player%-") and guid ~= victimSelf then
            local a = byName[src]
            if not a then
                a = { full = src, guid = guid, damage = 0, abilities = {} }
                byName[src] = a
                order[#order + 1] = a
            end
            a.damage = a.damage + (amount or 0)
            local spell = ns.Str(e.spellName) or (ns.Str(e.event) == "SWING_DAMAGE" and "Melee") or nil
            if spell then a.abilities[spell] = (a.abilities[spell] or 0) + (amount or 0) end
            local overkill = ns.Num(e.overkill)
            if not killer and overkill and overkill >= 0 then killer = a; a.finalSpell = spell end
        end
    end
    local base = {
        victimFull = victimFull, victimGUID = victimGUID, sources = sources,
        newest = ns.Num(events[1].timestamp),
        damage = total > 0 and total or nil,
        duration = first and last and math.floor(last - first + 0.5) or nil,
    }
    if #order == 0 then return base end
    -- No overkill marker: the newest player hit is the killing blow.
    if not killer then
        for _, e in ipairs(events) do
            local src = ns.Str(e.sourceName)
            if src and byName[src] then killer = byName[src]; killer.finalSpell = ns.Str(e.spellName); break end
        end
    end
    table.sort(order, function(a, b) return a.damage > b.damage end)
    local attackers = {}
    for _, a in ipairs(order) do
        local top, topDmg = nil, -1
        for spell, dmg in pairs(a.abilities) do if dmg > topDmg then top, topDmg = spell, dmg end end
        local char = CharFromFullName(a.full, a.guid)
        char.damage = a.damage > 0 and a.damage or nil
        char.top_ability = (a == killer and a.finalSpell) or top
        char.final_blow = a == killer or nil
        attackers[#attackers + 1] = char
    end
    for _, c in ipairs(attackers) do if c.final_blow then base.killer = c end end
    base.attackers = attackers
    return base
end

--- Our own latest death's recap (checked to be this death's).
local function ReadRecap(diedAt)
    if not (C_DeathRecap and C_DeathRecap.GetRecapEvents) then return nil end
    local ok, events = pcall(C_DeathRecap.GetRecapEvents)
    if not ok then return nil end
    local recap = ParseRecap(events, ns.Str(ns.Try(UnitGUID, "player")))
    if not recap or not recap.newest or math.abs(recap.newest - diedAt) > 30 then return nil end
    return recap
end

local function FinishDeath(report, fightCopy, diedAt, suspects)
    local recap = ReadRecap(diedAt)
    if recap and recap.attackers then
        -- The recap is authoritative: who hit us, with what, how hard, who finished us.
        local list = {}
        for i, c in ipairs(recap.attackers) do
            local entry = {}
            for k, v in pairs(c) do if k ~= "damage" and k ~= "top_ability" and k ~= "final_blow" then entry[k] = v end end
            list[i] = entry
            entry.damage, entry.top_ability, entry.final_blow = c.damage, c.top_ability, c.final_blow
        end
        report.attackers = list
        if recap.killer then
            local k = {}
            for key, v in pairs(recap.killer) do
                if key ~= "damage" and key ~= "top_ability" and key ~= "final_blow" then k[key] = v end
            end
            report.killer = k
        end
        report.damage_taken = recap.damage or report.damage_taken
        if recap.duration and recap.duration > 0 then report.duration_sec = math.max(report.duration_sec or 0, recap.duration) end
    elseif #suspects > 0 then
        report.attackers = {}
        for i, sus in ipairs(suspects) do report.attackers[i] = sus.info end
        if #suspects == 1 then report.killer = suspects[1].info end
    end
    if recap and recap.damage and not report.damage_taken then report.damage_taken = recap.damage end

    -- Only PvP deaths: enemy players involved, or inside a battleground.
    if not report.attackers and report.instance_type ~= "pvp" then return end
    Store(report)
    if ns.DebugEnabled() then pcall(ns.Debug, "death_recorded", { recap = recap ~= nil and recap.attackers ~= nil, attackers = report.attackers and #report.attackers or 0, killer = report.killer and report.killer.name }) end
    ns.Print("Recorded death%s. %d to export (/cr).",
        report.killer and (" to |cffffffff" .. report.killer.name .. "|r") or "", ns.PendingCount())
    if ns.OnReportsChanged then ns.OnReportsChanged() end
end

local function OnPlayerDead()
    local nowDead = ns.Now()
    if nowDead - lastDeathAt < DEATH_DEDUPE then return end
    lastDeathAt = nowDead
    -- Debug log first: the fight state is reset below.
    if ns.DebugEnabled() then
        pcall(ns.Debug, "death", { fight = ns.FightSnapshot(), enemies = ns.DebugVisibleEnemies and ns.DebugVisibleEnemies() })
    end
    local now = ns.Now()
    local report = Location()
    report.client_id = NewClientId("d")
    report.kind = "death"
    report.occurred_at = now
    report.damage_taken = fight.damage > 0 and fight.damage or nil
    report.duration_sec = fight.since and math.max(0, now - fight.since) or nil
    local gear = GearSnapshot()               -- gear as it was at death
    if #gear > 0 then report.gear = gear end

    local suspects = {}
    for _, sus in pairs(fight.suspects) do
        if now - sus.last <= SUSPECT_WINDOW then suspects[#suspects + 1] = sus end
    end
    table.sort(suspects, function(a, b) return a.hits > b.hits end)
    ResetFight()

    -- The death recap fills in shortly after death.
    local diedAt = (ns.Try(GetServerTime) or now)
    local finish = function() pcall(FinishDeath, report, nil, diedAt, suspects) end
    if C_Timer and C_Timer.After then C_Timer.After(1.5, finish) else finish() end
end

-- ---------------------------------------------------------------------------
-- Killmails: enemy deaths from the built-in damage meter's Deaths list, each
-- opened with its own death recap (victim, killing blow, everyone's damage).
-- The meter is secret during combat, so this runs whenever we're out of it.
-- ---------------------------------------------------------------------------

local combatStart               -- when we last entered combat
local lastCombat                -- { start, stop, loc } of the last finished fight

local KILLMAIL_THROTTLE = 4
local RECAP_TRIES = 3           -- scans an unreadable recap is retried
local lastKillmailScan = 0
local recapTries = {}           -- [recapID] = failed reads this session
local DEATHS = 9                -- Enum.DamageMeterType.Deaths

--- A Character without the attacker-only fields.
local function Plain(c)
    local out = {}
    for k, v in pairs(c) do if k ~= "damage" and k ~= "top_ability" and k ~= "final_blow" then out[k] = v end end
    return out
end

--- Same character by name (first names equal, surnames equal when both known).
local function SameName(a, b)
    local an, bn = ns.ShortName(a.name), ns.ShortName(b.name)
    if not an or not bn or an:lower() ~= bn:lower() then return false end
    return not (a.surname and b.surname) or a.surname:lower() == b.surname:lower()
end

--- Where a killmail's kill happened (as best we know: our own position). The
--- scan runs after the fight, maybe much later, so in order: the bare kill it
--- replaces -> where we were when UNIT_DIED reported the victim -> where the
--- fight it belongs to ended -> where we are now.
local function KillmailLocation(km, at, replacedLoc)
    if replacedLoc then return replacedLoc end
    if km.victimGUID then
        for i = #died, 1, -1 do
            if died[i].guid == km.victimGUID and died[i].loc then return CopyLocation(died[i].loc) end
        end
    end
    if lastCombat and lastCombat.loc and at >= (lastCombat.start or lastCombat.stop - 120) - 5 and at <= lastCombat.stop + 5 then
        return CopyLocation(lastCombat.loc)
    end
    return Location()
end

local function RecordKillmail(km, src)
    local victim = CharFromFullName(km.victimFull, km.victimGUID)
    victim.class = victim.class or (ns.Str(src.classFilename))
    victim.faction = victim.faction or ns.Str(src.factionGroup)
    local at = km.newest and math.floor(km.newest) or ns.Now()

    -- A sparse kill the honorable-kill counter already recorded for this victim
    -- (not exported yet) is replaced by the full killmail.
    local honor, removedAt, replacedLoc
    local list = Reports()
    for i = #list, 1, -1 do
        local r = list[i]
        if r.kind == "kill" and r.victim and SameName(r.victim, victim) and not r.exported_at
            and math.abs((r.occurred_at or 0) - at) <= 120 then
            honor = honor or r.honor
            replacedLoc = replacedLoc or CopyLocation(r)
            table.remove(list, i)
            removedAt = i
        end
    end
    -- Reports signed after the removed one pointed back at it: sign them again
    -- (Store below does) so the chain links real reports.
    if removedAt then Unsign(removedAt) end

    local myGUID = ns.Try(UnitGUID, "player")
    local report = KillmailLocation(km, at, replacedLoc)
    report.client_id = NewClientId("k")
    report.kind = "kill"
    report.occurred_at = at
    report.victim = victim
    report.honor = honor
    report.group_size = GroupSize()
    report.damage_taken = km.damage
    report.duration_sec = km.duration
    if km.killer then report.killer = Plain(km.killer) end
    if km.attackers then
        report.attackers = {}
        for _, a in ipairs(km.attackers) do
            if a.guid == myGUID then
                report.reporter_damage = a.damage            -- we're the reporter, not an "attacker"
            else
                local entry = Plain(a)
                entry.damage, entry.top_ability, entry.final_blow = a.damage, a.top_ability, a.final_blow
                report.attackers[#report.attackers + 1] = entry
            end
        end
        if #report.attackers == 0 then report.attackers = nil end
    end
    recentVictims[victim.name] = ns.Now()
    lastKill.name, lastKill.at, lastKill.source = victim.name, ns.Now(), "killmail"
    Store(report)
    if ns.DebugEnabled() then pcall(ns.Debug, "killmail", { victim = victim.name, killer = km.killer and km.killer.name, attackers = km.attackers and #km.attackers or 0 }) end
    local kb = km.killer and (km.killer.guid == myGUID and "your killing blow" or ("killing blow: " .. km.killer.name)) or nil
    ns.Print("Recorded kill: |cffffffff%s|r%s. %d to export (/cr).", victim.name, kb and (" (" .. kb .. ")") or "", ns.PendingCount())
    if ns.OnReportsChanged then ns.OnReportsChanged() end
end

-- ---------------------------------------------------------------------------
-- Open-world kills: the meter only lists enemy deaths in battlegrounds, so
-- there's no killmail. Its Enemy Damage Taken list still has the victim: the
-- damage our side did (ours when solo, maybe the group's when grouped) and how
-- long the fight lasted. Only the current fight's list is used (the overall
-- one adds up every fight), for kills made during that fight.
-- ---------------------------------------------------------------------------

local ENEMY_DAMAGE = 10         -- Enum.DamageMeterType.EnemyDamageTaken

local function SpellName(id)
    if not id then return nil end
    local name = C_Spell and C_Spell.GetSpellName and ns.Try(C_Spell.GetSpellName, id)
    return ns.Str(name) or ns.Str((ns.Try(GetSpellInfo, id)))
end

--- The meter's breakdown of the damage an enemy took this fight: per unit
--- that hit it, its damage and spells. Returns [lower first name] =
--- { name, surname, damage, spells = { [spellID] = damage } }, or nil when the
--- breakdown names nobody (the client doesn't give one).
local function ParseBreakdown(source)
    if type(source) ~= "table" or ns.IsSecret(source) then return nil end
    local spells = source.combatSpells or source.spells
    if type(spells) ~= "table" then return nil end
    local byName, named = {}, false
    -- Forever: one entry per unit that hit the enemy (spellID 0), its damage
    -- in the entry's totalAmount and a single combatSpellDetails table naming
    -- the unit (its own amount is 0). Per-spell entries listing several units,
    -- each with an amount, are read too.
    for _, spell in ipairs(spells) do
        local details = type(spell) == "table" and (spell.combatSpellDetails or spell.details) or nil
        if type(details) == "table" and details[1] == nil then details = { details } end
        if type(details) ~= "table" then details = {} end
        for _, d in ipairs(details) do
            local full = type(d) == "table" and (ns.Str(d.unitName) or ns.Str(d.name) or ns.Str(d.sourceName))
            local name, surname = ns.SplitName(full)
            local amount = type(d) == "table" and (ns.Num(d.amount) or ns.Num(d.totalAmount))
            if (not amount or amount <= 0) and #details == 1 then amount = ns.Num(spell.totalAmount) end
            if name and amount and amount > 0 then
                named = true
                local key = name:lower()
                local a = byName[key] or { name = name, surname = surname, damage = 0, spells = {} }
                byName[key] = a
                a.damage = a.damage + amount
                local id = ns.Num(spell.spellID)
                if id and id > 0 then a.spells[id] = (a.spells[id] or 0) + amount end
            end
        end
    end
    return named and byName or nil
end

--- An attacker entry: `info` (a Character) with a breakdown line's damage
--- and top ability.
local function WithDamage(info, line)
    local out = {}
    for k, v in pairs(info) do out[k] = v end
    out.damage = math.floor(line.damage + 0.5)
    local top, topDmg = nil, -1
    for id, dmg in pairs(line.spells) do if dmg > topDmg then top, topDmg = id, dmg end end
    out.top_ability = SpellName(top)
    return out
end

local function MyKey()
    return (ns.ShortName(ns.Try(UnitName, "player")) or ""):lower()
end

--- Who in our group damaged an enemy this fight (see ParseBreakdown).
--- Returns attackers (group members: Characters with damage and top ability,
--- most damage first), our own damage, and whether the breakdown named anyone
--- (if it didn't, nothing should change).
local function GroupDamageOn(fight, guid)
    if not (guid and fight.breakdown) then return nil end
    local ok, source = pcall(fight.breakdown, guid)
    -- Kept in the debug log (and used by /cr backfill).
    if ns.DebugEnabled() then pcall(ns.Debug, "meter_victim", { guid = guid, ok = ok, source = source }, 7) end
    if not ok then return nil end
    local byName = ParseBreakdown(source)
    if not byName then return nil end
    local attackers = {}
    for _, unit in ipairs(GroupUnits()) do
        local line = byName[(ns.ShortName(ns.Try(UnitName, unit)) or ""):lower()]
        local info = line and ns.CharInfo(unit)
        if info then attackers[#attackers + 1] = WithDamage(info, line) end
    end
    table.sort(attackers, function(x, y) return x.damage > y.damage end)
    local mine = byName[MyKey()]
    return attackers, mine and math.floor(mine.damage + 0.5) or nil, true
end

local SESSION_LOOKBACK = 12     -- recent fights searched for a kill's victim after combat
local FILL_WINDOW = 15 * 60     -- kills this recent can still get their meter details

--- The fights to look in for kills' victims, newest first, each
--- { key, session() -> Enemy Damage Taken session, breakdown(guid) }. The
--- meter keeps every fight (by session ID); back-to-back fights each have
--- their own. Without that API, only the current fight (and `false`).
local function Fights(lookback)
    local fights = {}
    local ok, list = false, nil
    if C_DamageMeter.GetAvailableCombatSessions and C_DamageMeter.GetCombatSessionFromID then
        ok, list = pcall(C_DamageMeter.GetAvailableCombatSessions)
    end
    if ok and type(list) == "table" and not ns.IsSecret(list) and #list > 0 then
        local ids = {}
        for _, entry in ipairs(list) do
            local id = type(entry) == "table" and ns.Num(entry.sessionID)
            if id then ids[#ids + 1] = id end
        end
        table.sort(ids, function(a, b) return a > b end)
        local bySource = C_DamageMeter.GetCombatSessionSourceFromID
        for n = 1, math.min(#ids, lookback or SESSION_LOOKBACK) do
            local id = ids[n]
            fights[#fights + 1] = {
                key = id,
                session = function() return C_DamageMeter.GetCombatSessionFromID(id, ENEMY_DAMAGE) end,
                breakdown = bySource and function(guid) return bySource(id, ENEMY_DAMAGE, guid) end,
            }
        end
        if #fights > 0 then return fights, true end
    end
    local byType = C_DamageMeter.GetCombatSessionSourceFromType
    fights[1] = {
        key = "current",
        session = function() return C_DamageMeter.GetCombatSessionFromType(1, ENEMY_DAMAGE) end,
        breakdown = byType and function(guid) return byType(1, ENEMY_DAMAGE, guid) end,
    }
    return fights, false
end

--- A fight's Enemy Damage Taken session (cached per lookup in `cache`).
local function FightSession(fight, cache)
    local session = cache[fight]
    if session == nil then
        local ok, s = pcall(fight.session)
        session = ok and type(s) == "table" and not ns.IsSecret(s) and type(s.combatSources) == "table" and s or false
        cache[fight] = session
    end
    return session or nil
end

--- The victim's line in a fight's Enemy Damage Taken (by GUID, or by name when
--- either GUID is missing), if they took damage there.
local function VictimSource(session, victim)
    for _, src in ipairs(session.combatSources) do
        local guid = ns.Str(src.sourceGUID)
        local name, surname = ns.SplitName(ns.Str(src.name))
        local amount = ns.Num(src.totalAmount)
        if amount and amount > 0 and ((guid and victim.guid and guid == victim.guid)
            or ((not guid or not victim.guid) and name and SameName(victim, { name = name, surname = surname }))) then
            return src
        end
    end
end

--- For each kill (newest first: a victim killed twice gets the newest fight
--- for the newest kill), the newest fight it took damage in that no other
--- kill of it has taken. Calls found(r, fight, session, src) per match.
local function MatchFights(kills, fights, found)
    local cache, used = {}, {}
    for _, r in ipairs(kills) do
        for _, fight in ipairs(fights) do
            local session = FightSession(fight, cache)
            local src = session and VictimSource(session, r.victim)
            local key = src and (tostring(fight.key) .. "|" .. (ns.Str(src.sourceGUID) or r.victim.name or ""))
            if src and not used[key] then
                used[key] = true
                found(r, fight, session, src)
                break
            end
        end
    end
end

local function FillFromMeter()
    local fights, bySession = Fights()
    local from, to
    if bySession then
        from, to = ns.Now() - FILL_WINDOW, math.huge
    else
        -- Only the current fight is readable: only kills made during it.
        if not lastCombat then return end
        from = (lastCombat.start or (lastCombat.stop - 120)) - 5
        to = lastCombat.stop + 5
    end
    local pending, index = {}, {}
    for i, r in ipairs(Reports()) do
        if r.kind == "kill" and r.victim and not r.exported_at and not r.meter_damage and not r.damage_taken
            and (r.occurred_at or 0) >= from and (r.occurred_at or 0) <= to then
            pending[#pending + 1] = r
            index[r] = i
        end
    end
    if #pending == 0 then return end
    table.sort(pending, function(a, b) return index[a] > index[b] end)
    local filled, firstChanged = 0, nil
    MatchFights(pending, fights, function(r, fight, session, src)
        r.meter_damage = math.floor(ns.Num(src.totalAmount) + 0.5)
        if r.group_size == 1 then r.reporter_damage = r.reporter_damage or r.meter_damage end
        -- Who in the group hit it, and how hard (replaces the guess made when
        -- the kill was recorded).
        local attackers, mine, named = GroupDamageOn(fight, ns.Str(src.sourceGUID) or r.victim.guid)
        if named then
            r.attackers = #attackers > 0 and attackers or nil
            if mine then r.reporter_damage = mine end
        end
        local duration = ns.Num(session.durationSeconds)
        if duration and duration > 0 and not r.duration_sec then r.duration_sec = math.floor(duration + 0.5) end
        filled = filled + 1
        if not firstChanged or index[r] < firstChanged then firstChanged = index[r] end
    end)
    if filled > 0 then
        -- These kills were signed when recorded: sign them (and the ones after
        -- them, whose `prev` changes) again, or the export sends the old copy.
        if Unsign(firstChanged) and ns.SignReports then pcall(ns.SignReports) end
        if ns.DebugEnabled() then pcall(ns.Debug, "meter_fill", { filled = filled, bySession = bySession }) end
        if ns.OnReportsChanged then ns.OnReportsChanged() end
    end
end

--- Look for enemy deaths we took part in that we haven't recorded yet.
--- force: skip the throttle (an export wants everything that's ready).
function ns.ScanKillmails(force)
    if not (C_DamageMeter and C_DamageMeter.GetCombatSessionFromType and C_DeathRecap and C_DeathRecap.GetRecapEvents) then return end
    if ns.Try(UnitAffectingCombat, "player") then return end           -- secret in combat
    local now = ns.Now()
    if not force and now - lastKillmailScan < KILLMAIL_THROTTLE then return end
    lastKillmailScan = now
    local seen = WKillboardCharDB.seenRecaps
    for id, at in pairs(seen) do if now - at > 86400 then seen[id] = nil end end
    local myGUID, petGUID = ns.Try(UnitGUID, "player"), ns.Try(UnitGUID, "pet")
    for _, sessionType in ipairs({ 1, 0 }) do                           -- current, overall
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, sessionType, DEATHS)
        if ok and type(session) == "table" and not ns.IsSecret(session) and type(session.combatSources) == "table" then
            for _, src in ipairs(session.combatSources) do
                -- (factionGroup is missing for most players, so it can't tell
                -- enemies apart; having damaged the victim can: we can't hurt
                -- our own faction, and duels don't kill.)
                local recapID = ns.Num(src.deathRecapID)
                if recapID and recapID > 0 and not seen[recapID] and src.isLocalPlayer ~= true then
                    local okRecap, events = pcall(C_DeathRecap.GetRecapEvents, recapID)
                    local km = okRecap and ParseRecap(events) or nil
                    if km and km.victimFull then
                        seen[recapID] = now
                        recapTries[recapID] = nil
                        -- Only deaths we (or our pet) took part in: our kills and assists.
                        local involved = (myGUID and km.sources[myGUID]) or (petGUID and km.sources[petGUID])
                        local friendly = km.victimGUID and (km.victimGUID == myGUID or InMyGroup(km.victimGUID))
                        if involved and not friendly then
                            pcall(RecordKillmail, km, src)
                        end
                    else
                        -- Not readable (maybe not filled in yet): try a few more
                        -- scans, then stop fetching it every time.
                        recapTries[recapID] = (recapTries[recapID] or 0) + 1
                        if recapTries[recapID] >= RECAP_TRIES then
                            seen[recapID] = now
                            recapTries[recapID] = nil
                        end
                    end
                end
            end
        end
    end
    -- Then open-world kills the killmails didn't cover.
    pcall(FillFromMeter)
    -- Every kill recorded before this scan has had its chance at details:
    -- they're ready to export.
    if next(awaiting) then
        for r in pairs(awaiting) do awaiting[r] = nil end
        if ns.OnReportsChanged then pcall(ns.OnReportsChanged) end
    end
end

-- ---------------------------------------------------------------------------
-- /cr backfill: exported kills whose group members went out without damage
-- (recorded before the meter breakdown was read) get a follow-up report with
-- each member's damage, from the breakdowns kept in the debug log. The follow-
-- up is a new signed report for the same victim at the same time: the site
-- merges it into the kill. Nothing already signed or exported changes.
-- ---------------------------------------------------------------------------

local BACKFILL_WINDOW = 180     -- seconds after a kill its breakdown may have been read

local function HasDamage(attackers)
    for _, a in ipairs(attackers) do if a.damage then return true end end
    return false
end

--- Is this report a backfill follow-up (not a kill of its own)?
function ns.IsFollowUp(r)
    local f = WKillboardCharDB.followUps
    return f ~= nil and r.client_id ~= nil and f[r.client_id] ~= nil
end

local BACKFILL_LOOKBACK = math.huge   -- /cr backfill searches every fight the meter still holds

--- Returns how many follow-up reports were added.
function ns.Backfill()
    local log = WKillboardCharDB.debug or {}
    WKillboardCharDB.backfilled = WKillboardCharDB.backfilled or {}   -- [kill client_id] = follow-up client_id
    WKillboardCharDB.followUps = WKillboardCharDB.followUps or {}     -- [follow-up client_id] = kill client_id
    local done, me = WKillboardCharDB.backfilled, MyKey()
    local list = Reports()
    local index, kills = {}, {}
    for i, r in ipairs(list) do
        index[r] = i
        -- Exported group kills whose members went out without damage.
        if r.kind == "kill" and r.exported_at and r.victim and r.victim.guid and r.client_id and not done[r.client_id]
            and not ns.IsFollowUp(r) and ((r.group_size or 1) > 1 or (type(r.attackers) == "table" and #r.attackers > 0))
            and not HasDamage(r.attackers or {}) then
            kills[#kills + 1] = r
        end
    end
    table.sort(kills, function(a, b) return index[a] > index[b] end)

    local made = 0
    --- A follow-up for kill r from a breakdown: the group members the kill
    --- names. A grouped kill sent with no members at all (older addon) takes
    --- everyone the breakdown names: the meter counts only our group's damage.
    local function FollowUp(r, byName, total, duration)
        local known, anyone = {}, (r.group_size or 1) > 1 and not (r.attackers and #r.attackers > 0)
        for _, a in ipairs(r.attackers or {}) do if a.name then known[a.name:lower()] = a end end
        local attackers = {}
        for key, line in pairs(byName) do
            if key ~= me and (known[key] or anyone) then
                attackers[#attackers + 1] = WithDamage(known[key] or { name = line.name, surname = line.surname }, line)
            end
        end
        table.sort(attackers, function(x, y) return x.damage > y.damage end)
        local mine = byName[me] and math.floor(byName[me].damage + 0.5) or nil
        if #attackers == 0 and not mine then return false end
        local f = CopyLocation(r)
        f.client_id = NewClientId("k")
        f.kind = "kill"
        f.occurred_at = r.occurred_at
        f.victim = {}
        for k, v in pairs(r.victim) do f.victim[k] = v end
        f.group_size = r.group_size
        f.attackers = #attackers > 0 and attackers or nil
        f.reporter_damage = mine
        f.meter_damage = total and total > 0 and math.floor(total + 0.5) or r.meter_damage
        f.duration_sec = r.duration_sec or (duration and duration > 0 and math.floor(duration + 0.5)) or nil
        done[r.client_id] = f.client_id
        WKillboardCharDB.followUps[f.client_id] = r.client_id
        Store(f)
        made = made + 1
        return true
    end

    -- 1. The breakdown the debug log kept from right after the kill.
    local rest = {}
    for _, r in ipairs(kills) do
        local at, best = r.occurred_at or 0, nil
        for _, e in ipairs(log) do
            if e.kind == "meter_victim" and e.guid == r.victim.guid and type(e.t) == "number"
                and e.t >= at - 5 and e.t <= at + BACKFILL_WINDOW and (not best or e.t < best.t) then
                best = e
            end
        end
        local byName = best and ParseBreakdown(best.source)
        if not (byName and FollowUp(r, byName, ns.Num(best.source.totalAmount), nil)) then rest[#rest + 1] = r end
    end

    -- 2. The fights the meter still holds. They carry no times but come in
    -- order, and so do our reports: a victim's fights pair up one to one with
    -- our kills of them plus our deaths they fought in (when there are exactly
    -- that many), or with our kills alone (exactly that many). Otherwise the
    -- fight a kill belongs to can't be told, and it's skipped.
    local fights, bySession = Fights(BACKFILL_LOOKBACK)
    if bySession and #rest > 0 then
        local wanted, candidate = {}, {}
        for _, r in ipairs(rest) do wanted[r.victim.guid] = true; candidate[r] = true end
        local events, kills = {}, {}       -- [guid] = reports, oldest first
        local function add(t, guid, r)
            t[guid] = t[guid] or {}
            local l = t[guid]
            if l[#l] ~= r then l[#l + 1] = r end
        end
        for _, r in ipairs(list) do
            if not ns.IsFollowUp(r) then
                if r.kind == "kill" and r.victim and wanted[r.victim.guid] then
                    add(events, r.victim.guid, r)
                    add(kills, r.victim.guid, r)
                elseif r.kind == "death" then
                    for _, c in ipairs(r.attackers or {}) do
                        if c.guid and wanted[c.guid] then add(events, c.guid, r) end
                    end
                    if r.killer and r.killer.guid and wanted[r.killer.guid] then add(events, r.killer.guid, r) end
                end
            end
        end
        local cache, fightsOf = {}, {}     -- [guid] = { { fight, session, src } }, oldest first
        for n = #fights, 1, -1 do
            local session = FightSession(fights[n], cache)
            if session then
                for guid in pairs(wanted) do
                    local src = VictimSource(session, { guid = guid })
                    if src then
                        fightsOf[guid] = fightsOf[guid] or {}
                        table.insert(fightsOf[guid], { fight = fights[n], session = session, src = src })
                    end
                end
            end
        end
        for guid in pairs(wanted) do
            local fs, evs, ks = fightsOf[guid] or {}, events[guid] or {}, kills[guid] or {}
            local order = (#fs == #evs and evs) or (#fs == #ks and ks) or nil
            for n, r in ipairs(order or {}) do
                local f = fs[n]
                if candidate[r] and f.fight.breakdown then
                    local ok, source = pcall(f.fight.breakdown, guid)
                    local byName = ok and ParseBreakdown(source)
                    if byName then FollowUp(r, byName, ns.Num(f.src.totalAmount), ns.Num(f.session.durationSeconds)) end
                end
            end
        end
    end
    if made > 0 and ns.OnReportsChanged then pcall(ns.OnReportsChanged) end
    return made
end

-- One queued scan at a time: the meter's update event can fire many times a
-- second, and each scan reads every recap the meter lists.
local scanQueued = false
local function RunQueuedScan()
    scanQueued = false
    pcall(ns.ScanKillmails)
end

local function ScanSoon(delay)
    if scanQueued then return end
    scanQueued = true
    if C_Timer and C_Timer.After then C_Timer.After(delay, RunQueuedScan) else RunQueuedScan() end
end

-- On modern clients the amount (maybe the action too) is a secret value:
-- only plain numbers count toward damage taken.
local function WoundAmount(action, amount)
    if ns.IsSecret(action) or ns.IsSecret(amount) or action ~= "WOUND" then return 0 end
    return math.max(0, tonumber(amount) or 0)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
ns.recorderFrame = frame

function ns.StartRecording()
    frame:RegisterEvent("CHAT_MSG_COMBAT_HONOR_GAIN")
    frame:RegisterEvent("PLAYER_DEAD")
    -- Our own damage taken only (registered for every unit, it fires for each
    -- hit on any nameplate, party member or target).
    if not pcall(frame.RegisterUnitEvent, frame, "UNIT_COMBAT", "player") then
        frame:RegisterEvent("UNIT_COMBAT")
    end
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    frame:RegisterEvent("PLAYER_PVP_KILLS_CHANGED")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    pcall(frame.RegisterEvent, frame, "UNIT_DIED")   -- 12.x engines only
    pcall(frame.RegisterEvent, frame, "DAMAGE_METER_COMBAT_SESSION_UPDATED")
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(20, function() pcall(ns.ScanKillmails) end)
    end
    hkCount = SessionHK()
    SeedPlates()
end

local function OnEvent(event, ...)
    if event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
        OnHonorMessage(...)
    elseif event == "PLAYER_DEAD" then
        OnPlayerDead()
        ScanSoon(3)
    elseif event == "UNIT_COMBAT" then
        local unit, action, _, amount = ...
        if ns.Str(unit) == "player" then          -- (other units only if RegisterUnitEvent is missing)
            if ns.Try(UnitAffectingCombat, "player") then fight.since = fight.since or ns.Now() end
            local ok, dmg = pcall(WoundAmount, action, amount)
            if ok and type(dmg) == "number" then fight.damage = fight.damage + dmg end
            ScanSuspects()
        end
    elseif event == "PLAYER_PVP_KILLS_CHANGED" then
        OnKillsChanged()
    elseif event == "UNIT_DIED" then
        OnUnitDied((...))
    elseif event == "DAMAGE_METER_COMBAT_SESSION_UPDATED" then
        -- The meter is secret in combat; leaving combat scans anyway.
        if not ns.Try(UnitAffectingCombat, "player") then ScanSoon(0.5) end
    elseif event == "PLAYER_ENTERING_WORLD" then
        OnEnterWorld()
        SeedPlates()
    elseif event == "PLAYER_REGEN_DISABLED" then
        fight.since = fight.since or ns.Now()
        combatStart = ns.Now()
    elseif event == "PLAYER_REGEN_ENABLED" then
        lastCombat = { start = combatStart, stop = ns.Now(), loc = Location() }
        combatStart = nil
        -- Left combat alive: forget this fight (keep it if we're dead).
        if not ns.Try(UnitIsDeadOrGhost, "player") then ResetFight() end
        ScanSoon(1)
    elseif event == "PLAYER_TARGET_CHANGED" then
        ns.Snapshot("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        ns.Snapshot("mouseover")
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local unit = ...
        if type(unit) == "string" then plates[unit] = true end
        ns.Snapshot(unit)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local unit = ...
        OnNameplateRemoved(unit)
        if type(unit) == "string" then plates[unit] = nil end
    end
end

-- Some clients (e.g. retail's combat restrictions) may hand back values addons
-- can't use; never let that surface as a Lua error. Report the first one only.
local reportedError = false
frame:SetScript("OnEvent", function(_, event, ...)
    local ok, err = pcall(OnEvent, event, ...)
    if not ok and not reportedError then
        reportedError = true
        ns.Print("couldn't process %s (%s). Recording continues; please report this.", event, tostring(err))
    end
end)
