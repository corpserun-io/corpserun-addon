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

local function GroupSize()
    local n = ns.Try(GetNumGroupMembers) or 0
    return n > 0 and n or 1
end

local function Store(report)
    -- Position in this character's signed log, and who recorded it.
    WKillboardCharDB.nextSeq = (WKillboardCharDB.nextSeq or 0) + 1
    report.seq = WKillboardCharDB.nextSeq
    report.reporter = ns.PlayerReporter()
    local list = Reports()
    list[#list + 1] = report
    while #list > MAX_REPORTS do table.remove(list, 1) end
    -- Sign now (when a key is set) so exporting stays instant.
    if ns.SignReports then pcall(ns.SignReports) end
end

--- Drop reports older than KEEP_DAYS.
function ns.PruneReports()
    local cutoff = ns.Now() - KEEP_DAYS * 86400
    local kept = {}
    for _, r in ipairs(Reports()) do
        if (r.occurred_at or 0) >= cutoff then kept[#kept + 1] = r end
    end
    WKillboardCharDB.reports = kept
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
local died = {}                -- UNIT_DIED player deaths: { guid, at }
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
    died[#died + 1] = { guid = guid, at = Clock() }
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

    if ns.Debug then
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
            if ns.Debug then pcall(ns.Debug, "kill_unresolved", {}) end
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

-- Who is attacking us? Enemy players (target, focus, nameplates) targeting us.
local function ScanSuspects()
    local now = ns.Now()
    ScanUnitForSuspect("target", now)
    ScanUnitForSuspect("focus", now)
    for i = 1, 40 do ScanUnitForSuspect("nameplate" .. i, now) end
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
--- NPCs count toward damage taken but aren't attackers).
local function ParseRecap(events)
    if type(events) ~= "table" or #events == 0 then return nil end
    local byName, order, total, first, last = {}, {}, 0, nil, nil
    local killer
    local sources = {}                         -- every source GUID (incl. pets)
    local victimFull, victimGUID = ns.Str(events[1].destName), ns.Str(events[1].destGUID)
    for _, e in ipairs(events) do
        local srcGUID = ns.Str(e.sourceGUID)
        if srcGUID then sources[srcGUID] = true end
        local amount = ns.Num(e.amount)
        local ts = ns.Num(e.timestamp)
        if ts then first = math.min(first or ts, ts); last = math.max(last or ts, ts) end
        if amount and amount > 0 then total = total + amount end
        local src, guid = ns.Str(e.sourceName), ns.Str(e.sourceGUID)
        if src and guid and guid:find("^Player%-") then
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
    local recap = ParseRecap(events)
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
    if ns.Debug then pcall(ns.Debug, "death_recorded", { recap = recap ~= nil and recap.attackers ~= nil, attackers = report.attackers and #report.attackers or 0, killer = report.killer and report.killer.name }) end
    ns.Print("Recorded death%s. %d to export (/cr).",
        report.killer and (" to |cffffffff" .. report.killer.name .. "|r") or "", ns.PendingCount())
    if ns.OnReportsChanged then ns.OnReportsChanged() end
end

local function OnPlayerDead()
    local nowDead = ns.Now()
    if nowDead - lastDeathAt < DEATH_DEDUPE then return end
    lastDeathAt = nowDead
    -- Debug log first: the fight state is reset below.
    if ns.Debug then
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

local KILLMAIL_THROTTLE = 4
local lastKillmailScan = 0
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

local function RecordKillmail(km, src)
    local victim = CharFromFullName(km.victimFull, km.victimGUID)
    victim.class = victim.class or (ns.Str(src.classFilename))
    victim.faction = victim.faction or ns.Str(src.factionGroup)
    local at = km.newest and math.floor(km.newest) or ns.Now()

    -- A sparse kill the honorable-kill counter already recorded for this victim
    -- (not exported yet) is replaced by the full killmail.
    local honor
    local list = Reports()
    for i = #list, 1, -1 do
        local r = list[i]
        if r.kind == "kill" and r.victim and SameName(r.victim, victim) and not r.exported_at
            and math.abs((r.occurred_at or 0) - at) <= 120 then
            honor = honor or r.honor
            table.remove(list, i)
        end
    end

    local myGUID = ns.Try(UnitGUID, "player")
    local report = Location()
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
    if ns.Debug then pcall(ns.Debug, "killmail", { victim = victim.name, killer = km.killer and km.killer.name, attackers = km.attackers and #km.attackers or 0 }) end
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
local combatStart               -- when we last entered combat
local lastCombat                -- { start, stop } of the last finished fight

local function FillFromMeter()
    if not lastCombat then return end
    local from = (lastCombat.start or (lastCombat.stop - 120)) - 5
    local to = lastCombat.stop + 5
    local pending = {}
    for _, r in ipairs(Reports()) do
        if r.kind == "kill" and r.victim and not r.exported_at and not r.meter_damage and not r.damage_taken
            and (r.occurred_at or 0) >= from and (r.occurred_at or 0) <= to then
            pending[#pending + 1] = r
        end
    end
    if #pending == 0 then return end
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, 1, ENEMY_DAMAGE)   -- current fight
    if not ok or type(session) ~= "table" or ns.IsSecret(session) or type(session.combatSources) ~= "table" then return end
    local duration = ns.Num(session.durationSeconds)
    local filled = 0
    for _, src in ipairs(session.combatSources) do
        local amount = ns.Num(src.totalAmount)
        local guid = ns.Str(src.sourceGUID)
        local name, surname = ns.SplitName(ns.Str(src.name))
        for _, r in ipairs(pending) do
            local match = (guid and r.victim.guid and guid == r.victim.guid)
                or ((not guid or not r.victim.guid) and name and SameName(r.victim, { name = name, surname = surname }))
            if match and amount and amount > 0 and not r.meter_damage then
                r.meter_damage = math.floor(amount + 0.5)
                if r.group_size == 1 then r.reporter_damage = r.reporter_damage or r.meter_damage end
                if duration and duration > 0 and not r.duration_sec then r.duration_sec = math.floor(duration + 0.5) end
                filled = filled + 1
            end
        end
    end
    if filled > 0 then
        if ns.Debug then pcall(ns.Debug, "meter_fill", { filled = filled, duration = duration }) end
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
                        -- Only deaths we (or our pet) took part in: our kills and assists.
                        local involved = (myGUID and km.sources[myGUID]) or (petGUID and km.sources[petGUID])
                        local friendly = km.victimGUID and (km.victimGUID == myGUID or InMyGroup(km.victimGUID))
                        if involved and not friendly then
                            pcall(RecordKillmail, km, src)
                        end
                    end
                end
            end
        end
    end
    -- Then open-world kills the killmails didn't cover.
    pcall(FillFromMeter)
end

local function ScanSoon(delay)
    local scan = function() pcall(ns.ScanKillmails) end
    if C_Timer and C_Timer.After then C_Timer.After(delay, scan) else scan() end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
ns.recorderFrame = frame

function ns.StartRecording()
    frame:RegisterEvent("CHAT_MSG_COMBAT_HONOR_GAIN")
    frame:RegisterEvent("PLAYER_DEAD")
    frame:RegisterEvent("UNIT_COMBAT")
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
end

local function OnEvent(event, ...)
    if event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
        OnHonorMessage(...)
    elseif event == "PLAYER_DEAD" then
        OnPlayerDead()
        ScanSoon(3)
    elseif event == "UNIT_COMBAT" then
        local unit, action, _, amount = ...
        local okUnit, isPlayer = pcall(function() return not ns.IsSecret(unit) and unit == "player" end)
        if okUnit and isPlayer then
            if ns.Try(UnitAffectingCombat, "player") then fight.since = fight.since or ns.Now() end
            -- On modern clients the amount (maybe the action too) is a secret
            -- value: only plain numbers count toward damage taken.
            local ok, dmg = pcall(function()
                if ns.IsSecret(action) or ns.IsSecret(amount) or action ~= "WOUND" then return 0 end
                return math.max(0, tonumber(amount) or 0)
            end)
            if ok and type(dmg) == "number" then fight.damage = fight.damage + dmg end
            ScanSuspects()
        end
    elseif event == "PLAYER_PVP_KILLS_CHANGED" then
        OnKillsChanged()
    elseif event == "UNIT_DIED" then
        OnUnitDied((...))
    elseif event == "DAMAGE_METER_COMBAT_SESSION_UPDATED" then
        ScanSoon(0.5)
    elseif event == "PLAYER_ENTERING_WORLD" then
        OnEnterWorld()
    elseif event == "PLAYER_REGEN_DISABLED" then
        fight.since = fight.since or ns.Now()
        combatStart = ns.Now()
    elseif event == "PLAYER_REGEN_ENABLED" then
        lastCombat = { start = combatStart, stop = ns.Now() }
        combatStart = nil
        -- Left combat alive: forget this fight (keep it if we're dead).
        if not ns.Try(UnitIsDeadOrGhost, "player") then ResetFight() end
        ScanSoon(1)
    elseif event == "PLAYER_TARGET_CHANGED" then
        ns.Snapshot("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        ns.Snapshot("mouseover")
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        ns.Snapshot((...))
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        OnNameplateRemoved((...))
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
