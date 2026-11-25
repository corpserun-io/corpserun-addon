-- Minimal WoW client stubs so the addon runs in plain Lua 5.1.
-- T.boot{...} loads a fresh copy of the addon (in TOC order) and returns ns.
local T = {}
local ADDON = (ADDON_DIR or "/addon/CorpseRun/")

local frames
local function newFrame()
    local f = { scripts = {}, events = {}, shown = false, all = false }
    setmetatable(f, { __index = function(_, k)
        if k == "SetScript" then return function(self, n, fn) self.scripts[n] = fn end end
        if k == "RegisterEvent" then return function(self, e) self.events[e] = true end end
        if k == "RegisterAllEvents" then return function(self) self.all = true end end
        if k == "UnregisterAllEvents" then return function(self) self.all = false end end
        if k == "RegisterUnitEvent" then return function(self, e, unit)
            self.events[e] = true
            rawset(self, "unitEvents", rawget(self, "unitEvents") or {})
            self.unitEvents[e] = unit
        end end
        if k == "UnregisterEvent" then return function(self, e) self.events[e] = nil end end
        if k == "IsShown" then return function(self) return self.shown end end
        if k == "Show" then return function(self) self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end end
        if k == "Hide" then return function(self) self.shown = false end end
        if k == "SetShown" then return function(self, v) if v then self:Show() else self:Hide() end end end
        if k == "CreateFontString" or k == "CreateTexture" then return function() return newFrame() end end
        if k == "SetText" then return function(self, t) rawset(self, "text_", t) end end
        return function() end
    end })
    frames[#frames + 1] = f
    return f
end

--- Fire a game event to every frame registered for it.
function T.fire(event, ...)
    for _, f in ipairs(frames) do
        if (f.events[event] or f.all) and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end

function T.frames() return frames end

--- A "secret" value: comparing it raises like the real client.
T.SECRET = setmetatable({}, {
    __lt = function() error("attempt to compare a secret number value") end,
    __le = function() error("attempt to compare a secret number value") end,
})

--- Fresh client + addon. opts: toc (default 16001), saved = { db, char }.
function T.boot(opts)
    opts = opts or {}
    frames = {}
    T.clock = 0
    T.printed = {}
    T.units = {
        player = { name = "Gorvash", second = nil, class = { "Warrior", "WARRIOR" }, race = "Orc", level = 60, sex = 2,
                   faction = "Horde", guild = "Bloodfang", guid = "Player-1-0001" },
    }
    T.guids = {}             -- GetPlayerInfoByGUID data: [guid] = { class, CLASS, race, sex, name, second }
    T.instance = "none"
    T.zone = "Elwynn Forest"
    T.hk = 0
    T.group = {}             -- GUIDs in our group
    T.recap = nil            -- C_DeathRecap.GetRecapEvents() result (latest = own death)
    T.recaps = {}            -- [recapID] = events (enemy deaths)
    T.meterDeaths = nil      -- C_DamageMeter Deaths session combatSources
    T.meterEnemy = nil       -- C_DamageMeter current-fight Enemy Damage Taken session
    T.meterVictim = {}       -- [enemy GUID] = its Enemy Damage Taken breakdown (GetCombatSessionSourceFromType)
    T.inCombat = true

    local units = T.units
    print = function(...) local t = {}; for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end; T.printed[#T.printed + 1] = table.concat(t, " ") end
    for _, name in ipairs(T.named or {}) do _G[name] = nil end
    T.named = {}
    CreateFrame = function(_, name)
        local f = newFrame()
        if name then _G[name] = f; T.named[#T.named + 1] = name end
        return f
    end
    UIParent, UISpecialFrames, ChatFontNormal, tinsert = {}, {}, {}, table.insert
    time = function() return 1800000000 + math.floor(T.clock) end
    GetTime = function() return T.clock end
    GetServerTime = time
    date = os.date
    UNKNOWNOBJECT = "Unknown"
    -- Forever's honor templates (from the client's GlobalStrings).
    COMBATLOG_HONORGAIN = "%s dies (Honorable Kill: %s). You gain %d Honor."
    COMBATLOG_HONORGAIN_NO_RANK = "%s dies (Honorable Kill). You gain %d Honor."
    COMBATLOG_HONORGAIN_EXHAUSTION1 = nil
    SlashCmdList = {}
    GameTooltip = newFrame()
    Minimap = newFrame()
    C_Timer = { After = function(_, fn) fn() end, NewTicker = function() return { Cancel = function() end } end }
    RAID_CLASS_COLORS = setmetatable({}, { __index = function() return { r = 1, g = 1, b = 1 } end })
    CLASS_ICON_TCOORDS = setmetatable({}, { __index = function() return { 0, 1, 0, 1 } end })
    local function base(u) return (u:gsub("target$", "")) end
    UnitExists = function(u) if u:match(".target$") then local b = units[base(u)]; return b and b.targeting ~= nil end return units[u] ~= nil end
    -- "<unit>target" is the unit named by that unit's `targeting` (a unit token).
    local function R(u)
        if u:match(".target$") then local b = units[base(u)]; return b and b.targeting and units[b.targeting] end
        return units[u]
    end
    UnitIsPlayer = function(u) return R(u) ~= nil end
    UnitName = function(u) local x = units[u]; if x then return x.name, x.second end end
    UnitFullName = function(u) local x = units[u]; if x then return x.name, x.second end end
    UnitClass = function(u) local x = units[u]; if x and x.class then return x.class[1], x.class[2] end end
    UnitRace = function(u) local x = units[u]; return x and x.race, x and x.race end
    UnitLevel = function(u) return units[u] and units[u].level end
    UnitSex = function(u) return units[u] and units[u].sex end
    UnitFactionGroup = function(u) return units[u] and units[u].faction end
    GetGuildInfo = function(u) return units[u] and units[u].guild end
    UnitGUID = function(u) local x = R(u); return x and x.guid end
    UnitIsEnemy = function(_, b) local x = R(b); return x and x.enemy end
    UnitIsFriend = function(_, b) local x = R(b); return x ~= nil and not x.enemy end
    UnitIsUnit = function(a, b)
        if a:match(".target$") then local s = units[base(a)]; return s and s.targeting == b end
        return a == b
    end
    UnitIsDeadOrGhost = function(u) return units[u] ~= nil and units[u].dead == true end
    UnitAffectingCombat = function(u)
        if u == "player" then return T.inCombat end
        return units[u] ~= nil and units[u].inCombat == true
    end
    UnitInRange = function(u) local x = units[u]; if x then return x.inRange ~= false, true end return false, false end
    IsInRaid = function() return false end
    IsGUIDInGroup = function(g) for _, x in ipairs(T.group) do if x == g then return true end end return false end
    GetPlayerInfoByGUID = function(g)
        local p = T.guids[g]
        if p then return p[1], p[2], p[3], p[3], p[4], p[5], p[6] end
    end
    GetPVPSessionStats = function() return T.hk, 0 end
    GetRealZoneText = function() return T.zone end
    GetSubZoneText = function() return "" end
    C_Map = { GetBestMapForUnit = function() return 1459 end, GetPlayerMapPosition = function() return { x = 0.42131, y = 0.55012 } end }
    IsInInstance = function() return T.instance ~= "none", T.instance end
    GetNumGroupMembers = function() return #T.group end
    GetCurrentRegion = function() return 1 end
    local toc = opts.toc or 16001
    GetBuildInfo = function() return "1.60.1", "70959", "Nov 2026", toc end
    GetRealmName = function() return "Realm" end
    C_DeathRecap = { GetRecapEvents = function(id) if id then return T.recaps[id] end return T.recap end }
    T.meterSessions = nil    -- the meter's kept fights: { { id, enemy = session, victims = { [guid] = breakdown } } }
    local function fightById(id)
        for _, f in ipairs(T.meterSessions or {}) do if f.id == id then return f end end
    end
    C_DamageMeter = { GetAvailableCombatSessions = function()
        local out = {}
        for _, f in ipairs(T.meterSessions or {}) do out[#out + 1] = { sessionID = f.id, durationSeconds = 20, name = "" } end
        return out
    end, GetCombatSessionFromID = function(id, meterType)
        if T.inCombat then return T.SECRET end
        local f = fightById(id)
        if f and meterType == 10 then return f.enemy end
    end, GetCombatSessionSourceFromID = function(id, meterType, guid)
        if T.inCombat then return T.SECRET end
        local f = fightById(id)
        if f and meterType == 10 then return f.victims and f.victims[guid] end
    end, GetCombatSessionSourceFromType = function(sessionType, meterType, guid)
        if T.inCombat then return T.SECRET end
        if sessionType == 1 and meterType == 10 then return T.meterVictim[guid] end
    end, GetCombatSessionFromType = function(sessionType, meterType)
        if meterType == 9 and T.meterDeaths then
            if T.inCombat then return T.SECRET end
            return { combatSources = T.meterDeaths }
        end
        if meterType == 10 and sessionType == 1 and T.meterEnemy then
            if T.inCombat then return T.SECRET end
            return T.meterEnemy
        end
    end }
    GetInventoryItemLink = function(_, slot)
        if slot == 1 then return "|cffa335ee|Hitem:16955:2585:::::1018:::60:::::|h[Judgement Crown of the Eagle]|h|r" end
        if slot == 16 then return "|cffa335ee|Hitem:19364::::|h[Ashkandi, Greatsword of the Brotherhood]|h|r" end
    end
    GetItemInfo = function(link)
        if link:find("16955") then return "Judgement Crown", link, 4, 76 end
        return "Ashkandi", link, 4, 81
    end
    issecretvalue = function(v) return v == T.SECRET end
    T.cvars = opts.cvars or { damageMeterEnabled = "1" }
    C_CVar = { GetCVar = function(name) return T.cvars[name] end }

    WKillboardDB = opts.saved and opts.saved.db or nil
    WKillboardCharDB = opts.saved and opts.saved.char or nil
    local ns = {}
    for line in io.lines(ADDON .. "CorpseRun.toc") do
        if line:match("%.lua$") then assert(loadfile(ADDON .. line))("CorpseRun", ns) end
    end
    T.fire("ADDON_LOADED", "CorpseRun")
    T.fire("PLAYER_LOGIN")
    T.fire("PLAYER_ENTERING_WORLD")
    return ns
end

--- Did any chat line contain `text`?
function T.said(text)
    for _, l in ipairs(T.printed) do if l:find(text, 1, true) then return true end end
    return false
end

function T.reports() return WKillboardCharDB.reports end
function T.last() local r = WKillboardCharDB.reports; return r[#r] end

--- An enemy player unit.
function T.enemy(name, surname, extra)
    local u = { name = name, second = surname, class = { "Mage", "MAGE" }, race = "Human", level = 29, sex = 2,
                faction = "Alliance", guid = "Player-9-" .. name, enemy = true }
    for k, v in pairs(extra or {}) do u[k] = v end
    return u
end

return T
