-- CorpseRun addon tests: `make addon-test` (plain Lua 5.1 in Docker).
-- Each test boots a fresh copy of the addon against stubbed client APIs.
package.path = "/addon/tests/?.lua;" .. package.path
dofile("/addon/tests/bitshim.lua")
local T = require("wow")

local tests, failed = {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function out(s) io.write(s, "\n") end

-- ---------------------------------------------------------------------------
-- Crypto
-- ---------------------------------------------------------------------------

test("SHA-256 / HMAC match Python (unsigned and signed bit libraries)", function()
    for _, signed in ipairs({ false, true }) do
        SIGNED_BIT = signed
        local ns = {}
        assert(loadfile("/addon/CorpseRun/Sha256.lua"))("CorpseRun", ns)
        for line in io.lines("/addon/tests/sha_vectors.txt") do
            local kind, a, b, want = line:match("^(%S+) (%S+) (%S+) (%S+)$")
            local msg = function(h) return h == "-" and "" or ns.FromHex(h) end
            local got = kind == "sha" and ns.ToHex(ns.SHA256(msg(a))) or ns.ToHex(ns.HMAC_SHA256(msg(a), msg(b)))
            assert(got == want, ("%s mismatch (signed=%s): %s"):format(kind, tostring(signed), line))
        end
    end
    SIGNED_BIT = false
end)

-- ---------------------------------------------------------------------------
-- Kills
-- ---------------------------------------------------------------------------

test("honor message kill (clients that send one), duplicate line ignored", function()
    local ns = T.boot()
    T.units.target = T.enemy("Valeria", nil, { class = { "Paladin", "PALADIN" } })
    T.fire("PLAYER_TARGET_CHANGED")
    T.fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Valeria dies (Honorable Kill: Knight). You gain 241 Honor.")
    T.fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Valeria dies (Honorable Kill: Knight). You gain 241 Honor.")
    assert(#T.reports() == 1, "expected 1 report, got " .. #T.reports())
    local r = T.last()
    assert(r.kind == "kill" and r.victim.name == "Valeria" and r.victim.class == "PALADIN" and r.honor == 241)
    assert(ns.ParseHonor("You have been awarded 2 Honor.") == nil, "objective honor is not a kill")
end)

test("counter kill: victim from UNIT_DIED + GetPlayerInfoByGUID (surname, class)", function()
    T.boot()
    T.guids["Player-6798-1"] = { "Hunter", "HUNTER", "Night Elf", 3, "Tiny", "Eyes" }
    T.clock = 10
    T.fire("UNIT_DIED", "Player-6798-1")
    T.clock = 10.3
    T.hk = 1
    T.fire("PLAYER_PVP_KILLS_CHANGED"); T.fire("PLAYER_PVP_KILLS_CHANGED")   -- Forever fires a burst
    assert(#T.reports() == 1, "expected 1 kill, got " .. #T.reports())
    local v = T.last().victim
    assert(v.name == "Tiny" and v.surname == "Eyes" and v.class == "HUNTER" and v.race == "Night Elf" and v.gender == 3, "victim fields")
    assert(v.faction == "Alliance", "faction from race")
end)

test("counter kill ignores our own group's deaths", function()
    T.boot()
    T.guids["Player-1-ally"] = { "Priest", "PRIEST", "Undead", 2, "Mirra", "Vale" }
    T.guids["Player-6798-2"] = { "Rogue", "ROGUE", "Human", 2, "Fenwick", "Hale" }
    T.group = { "Player-1-ally" }
    T.clock = 5
    T.fire("UNIT_DIED", "Player-1-ally")
    T.fire("UNIT_DIED", "Player-6798-2")
    T.hk = 1
    T.fire("PLAYER_PVP_KILLS_CHANGED")
    assert(T.last().victim.name == "Fenwick", "teammate counted as victim")
end)

test("counter kill: victim from a nameplate that vanished while dead", function()
    T.boot()
    T.units.nameplate7 = T.enemy("Badfortune", "Cookie", { dead = true })
    T.clock = 20
    T.fire("NAME_PLATE_UNIT_REMOVED", "nameplate7")
    T.units.nameplate7 = nil
    T.hk = 1
    T.fire("PLAYER_PVP_KILLS_CHANGED")
    local v = T.last().victim
    assert(v.name == "Badfortune" and v.surname == "Cookie", "nameplate victim")
end)

test("back-to-back kills both count; a kept-targeted corpse isn't reused", function()
    T.boot()
    T.units.target = T.enemy("Gimbrick", "Slimebeard", { dead = true })
    T.clock = 30; T.hk = 1
    T.fire("PLAYER_PVP_KILLS_CHANGED")
    T.guids["Player-6798-3"] = { "Mage", "MAGE", "Gnome", 3, "Whumpster", "Bog" }
    T.clock = 34
    T.fire("UNIT_DIED", "Player-6798-3")
    T.hk = 2
    T.fire("PLAYER_PVP_KILLS_CHANGED")          -- the dead target is still targeted
    local names = {}
    for _, r in ipairs(T.reports()) do names[#names + 1] = r.victim.name end
    assert(#names == 2 and names[1] == "Gimbrick" and names[2] == "Whumpster", "got: " .. table.concat(names, ","))
end)

test("unidentifiable kill records nothing, quietly", function()
    T.boot()
    T.clock = 40; T.hk = 1
    T.fire("PLAYER_PVP_KILLS_CHANGED")
    T.clock = 60
    T.fire("PLAYER_PVP_KILLS_CHANGED")           -- later retries expire it (C_Timer runs inline in tests)
    assert(#T.reports() == 0, "recorded a kill without a victim")
    assert(not T.said("couldn't be identified"), "unresolved kills shouldn't print to chat")
end)

local function ev(src, srcGUID, dest, destGUID, spell, amount, overkill, ts)
    return { sourceName = src, sourceGUID = srcGUID, destName = dest, destGUID = destGUID, spellName = spell,
             amount = amount, overkill = overkill, event = "SPELL_DAMAGE", timestamp = ts }
end

test("killmail: enemy death from the damage meter + its recap (killing blow, everyone involved)", function()
    T.boot()
    T.units.player.guid = "Player-6798-0184E712"
    T.instance, T.zone = "pvp", "Warsong Gulch"
    local t = 1800000000 + 50
    -- The counter already recorded a sparse kill of Arya (victim from a nameplate).
    T.units.nameplate4 = T.enemy("Arya", "Svetskona", { dead = true })
    T.clock = 50
    T.fire("NAME_PLATE_UNIT_REMOVED", "nameplate4"); T.units.nameplate4 = nil
    T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    assert(#T.reports() == 1 and T.last().killer == nil, "sparse counter kill first")
    T.recaps[1608] = {
        ev("Shn Gig", "Player-6798-0184E712", "Arya Svetskona", "Player-6935-02ECFFCC", "Shadowburn", 176, 64, t),
        ev("Klathzazt", "Player-1-K", "Arya Svetskona", "Player-6935-02ECFFCC", "Mortal Strike", 300, -1, t - 2),
        ev("Shn Gig", "Player-6798-0184E712", "Arya Svetskona", "Player-6935-02ECFFCC", "Corruption", 90, -1, t - 6),
        ev("Cat", "Pet-0-1-2", "Arya Svetskona", "Player-6935-02ECFFCC", "Claw", 36, -1, t - 3),
    }
    T.recaps[1609] = { ev("Althea Lights", "Player-1-A", "Shamlock Graves", "Player-1-S", "Smite", 296, 239, t - 5) }
    T.meterDeaths = {
        { deathRecapID = 1610, isLocalPlayer = true, classFilename = "WARLOCK", name = "Shn Gig" },          -- our death
        { deathRecapID = 1609, isLocalPlayer = false, factionGroup = "Alliance", classFilename = "WARLOCK", name = T.SECRET },
        { deathRecapID = 1608, isLocalPlayer = false, classFilename = "DRUID", name = T.SECRET },          -- no factionGroup (usual)
        { deathRecapID = 1607, isLocalPlayer = false, classFilename = "PRIEST", name = "Mirra Vale" },     -- a teammate
    }
    T.fire("PLAYER_REGEN_ENABLED")                        -- in combat: secret, nothing read
    assert(#T.reports() == 1, "read the meter in combat")
    T.inCombat = false
    T.clock = 60
    T.fire("PLAYER_REGEN_ENABLED")
    assert(#T.reports() == 1, "expected the killmail to replace the sparse kill, got " .. #T.reports())
    local k = T.last()
    assert(k.kind == "kill" and k.victim.name == "Arya" and k.victim.surname == "Svetskona" and k.victim.class == "DRUID", "victim")
    assert(k.killer and k.killer.name == "Shn" and k.killer.surname == "Gig", "our killing blow")
    assert(k.reporter_damage == 266, "our damage " .. tostring(k.reporter_damage))
    assert(#k.attackers == 1 and k.attackers[1].name == "Klathzazt" and k.attackers[1].damage == 300, "other players involved")
    assert(k.damage_taken == 602 and k.duration_sec == 6, "damage/duration")
    -- Not involved in Shamlock's death: not recorded. Scanning again doesn't duplicate.
    T.clock = 80
    T.fire("PLAYER_REGEN_ENABLED")
    assert(#T.reports() == 1, "duplicate or uninvolved killmail")
end)

test("Forever names: 'First Surname' and other-server names split right", function()
    local ns = T.boot()
    local n, s = ns.SplitName("Swinton Lightsblade-CAMWOWUS1Realm8PvP")
    assert(n == "Swinton" and s == "Lightsblade", "split with server: " .. tostring(n) .. "/" .. tostring(s))
    n, s = ns.SplitName("Valeria")
    assert(n == "Valeria" and s == nil, "single name")
    assert(ns.ShortName("Aiohd Up") == "Aiohd" and ns.ShortName("Tiny-Realm") == "Tiny", "ShortName")
    -- What different clients return from UnitName for the same kind of player.
    local cases = {
        { "Aiohd Up", nil, "Aiohd", "Up" },                                   -- full name, same server
        { "Swinton Lightsblade", "CAMWOWUS1Realm8PvP", "Swinton", "Lightsblade" }, -- full name, other server
        { "Sheew", "Rooke", "Sheew", "Rooke" },                               -- surname in the realm slot
        { "Tiny", "CAMWOWUS1Realm8PvP", "Tiny", nil },                        -- server name is no surname
    }
    for _, c in ipairs(cases) do
        T.units.target = T.enemy(c[1], c[2])
        local info = ns.CharInfo("target")
        assert(info.name == c[3] and info.surname == c[4],
            ("%s / %s -> %s / %s"):format(c[1], tostring(c[2]), tostring(info.name), tostring(info.surname)))
    end
    local name, honor, surname = ns.ParseHonor("Swinton Lightsblade-CAMWOWUS1Realm8PvP dies (Honorable Kill). You gain 5 Honor.")
    assert(name == "Swinton" and surname == "Lightsblade" and honor == 5, "honor message with a full name")
end)

test("counter kill: GetPlayerInfoByGUID with 'First Surname' + server name (Sathorian's client)", function()
    T.boot()
    T.guids["Player-6926-004BFD85"] = { "Paladin", "PALADIN", "Human", 2, "Swinton Lightsblade", "CAMWOWUS1Realm8PvP" }
    T.clock = 10
    T.fire("UNIT_DIED", "Player-6926-004BFD85")
    T.clock = 10.3
    T.hk = 1
    T.fire("PLAYER_PVP_KILLS_CHANGED")
    assert(#T.reports() == 1, "expected 1 kill, got " .. #T.reports())
    local v = T.last().victim
    assert(v.name == "Swinton" and v.surname == "Lightsblade", "victim " .. tostring(v.name) .. " / " .. tostring(v.surname))
end)

test("open-world kill: damage and fight length from the meter's Enemy Damage Taken (current fight only)", function()
    T.boot()
    T.units.player.guid = "Player-6930-00D7BA05"
    T.guids["Player-6926-004BFD85"] = { "Paladin", "PALADIN", "Human", 2, "Swinton Lightsblade", "CAMWOWUS1Realm8PvP" }
    T.clock = 100
    T.fire("PLAYER_REGEN_DISABLED")
    T.clock = 121
    T.fire("UNIT_DIED", "Player-6926-004BFD85")
    T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    assert(#T.reports() == 1 and T.last().meter_damage == nil, "bare kill first")
    T.meterEnemy = { durationSeconds = 26, combatSources = {
        { name = "Swinton Lightsblade", sourceGUID = "Player-6926-004BFD85", totalAmount = 774, deathRecapID = 0, isLocalPlayer = false },
        { name = "Some Bystander", sourceGUID = "Player-6926-1", totalAmount = 50 },
    } }
    T.fire("PLAYER_REGEN_ENABLED")                 -- still secret: nothing read
    assert(T.last().meter_damage == nil, "read the meter in combat")
    T.inCombat = false
    T.clock = 126
    T.fire("PLAYER_REGEN_ENABLED")
    local r = T.last()
    assert(r.meter_damage == 774 and r.reporter_damage == 774 and r.duration_sec == 26,
        ("meter fill: %s / %s / %s"):format(tostring(r.meter_damage), tostring(r.reporter_damage), tostring(r.duration_sec)))
    -- A later fight's list never fills an earlier fight's kill.
    T.reports()[1].meter_damage, T.reports()[1].duration_sec, T.reports()[1].reporter_damage = nil, nil, nil
    T.inCombat = true
    T.clock = 400; T.fire("PLAYER_REGEN_DISABLED")
    T.inCombat = false
    T.clock = 420; T.fire("PLAYER_REGEN_ENABLED")
    assert(T.reports()[1].meter_damage == nil, "earlier kill filled from a later fight")
end)

test("a bare honor kill of a full-named victim is replaced by its killmail", function()
    T.boot()
    T.units.player.guid = "Player-6930-00D7BA05"
    T.units.target = T.enemy("Swinton Lightsblade", "CAMWOWUS1Realm8PvP", { guid = "Player-6926-004BFD85" })
    T.clock = 100
    T.fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Swinton Lightsblade-CAMWOWUS1Realm8PvP dies (Honorable Kill). You gain 5 Honor.")
    assert(#T.reports() == 1 and T.last().victim.name == "Swinton" and T.last().victim.surname == "Lightsblade", "bare kill")
    local t = 1800000000 + 100
    T.recaps[2001] = {
        ev("Sathorian Hurden", "Player-6930-00D7BA05", "Swinton Lightsblade-CAMWOWUS1Realm8PvP", "Player-6926-004BFD85", "Wrath", 120, 30, t),
        ev("Sathorian Hurden", "Player-6930-00D7BA05", "Swinton Lightsblade-CAMWOWUS1Realm8PvP", "Player-6926-004BFD85", "Moonfire", 80, -1, t - 9),
    }
    T.meterDeaths = { { deathRecapID = 2001, isLocalPlayer = false, classFilename = "PALADIN", name = T.SECRET } }
    T.inCombat = false
    T.clock = 110
    T.fire("PLAYER_REGEN_ENABLED")
    assert(#T.reports() == 1, "killmail should replace the bare kill, got " .. #T.reports())
    local k = T.last()
    assert(k.victim.name == "Swinton" and k.victim.surname == "Lightsblade", "victim " .. k.victim.name .. "/" .. tostring(k.victim.surname))
    assert(k.honor == 5 and k.killer and k.killer.name == "Sathorian" and k.duration_sec == 9 and k.damage_taken == 200, "details + honor kept")
end)

test("export reads ready killmails first (no throttle) and warns in combat", function()
    local ns = T.boot()
    SlashCmdList.CORPSERUN("key wkb_" .. string.rep("ab", 32))
    T.units.player.guid = "Player-1-0001"
    T.inCombat = false
    T.clock = 200
    T.fire("PLAYER_REGEN_ENABLED")                      -- a scan just ran (throttled for a few seconds)
    local t = 1800000000 + 200
    T.recaps[3001] = { ev("Gorvash", "Player-1-0001", "Mira Dawn", "Player-9-M", "Execute", 400, 50, t) }
    T.meterDeaths = { { deathRecapID = 3001, isLocalPlayer = false, classFilename = "PRIEST", name = T.SECRET } }
    T.clock = 201
    ns.ShowExport("new")
    assert(#T.reports() == 1 and T.last().killer and T.last().exported_at, "killmail picked up by the export")
    assert(not T.said("Still in combat"), "no warning out of combat")
    T.inCombat = true
    T.units.target = T.enemy("Valeria", nil, { dead = true })
    T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    ns.ShowExport("new")
    assert(T.said("Still in combat"), "in-combat export warns")
end)

-- ---------------------------------------------------------------------------
-- Deaths
-- ---------------------------------------------------------------------------

test("death from the recap: killer, attackers, damage, duration; NPCs ignored", function()
    T.boot()
    T.instance, T.zone = "pvp", "Warsong Gulch"
    local t = 1800000000 + 100
    T.clock = 100
    T.recap = {
        { amount = 155, overkill = 34, sourceName = "Jute Gyte", sourceGUID = "Player-6798-00370993", spellName = "Frostbolt", event = "SPELL_DAMAGE", timestamp = t - 0.4 },
        { amount = 101, overkill = -1, sourceName = "Kennexath Ash", sourceGUID = "Player-6801-002DE511", spellName = "Holy Strike", event = "SPELL_DAMAGE", timestamp = t - 1.4 },
        { amount = 444, overkill = -1, sourceName = "Kennexath Ash", sourceGUID = "Player-6801-002DE511", spellName = "Seal of Command", event = "SPELL_DAMAGE", timestamp = t - 9 },
        { amount = 40, overkill = -1, sourceName = "Silverwing Sentinel", sourceGUID = "Creature-0-1-2-3-4-5", spellName = "Shoot", event = "SPELL_DAMAGE", timestamp = t - 3 },
    }
    T.fire("PLAYER_DEAD"); T.fire("PLAYER_DEAD")    -- Forever fires it twice
    assert(#T.reports() == 1, "double death")
    local d = T.last()
    assert(d.kind == "death" and d.killer.name == "Jute" and d.killer.surname == "Gyte", "killer")
    assert(#d.attackers == 2, "players only")
    assert(d.attackers[1].name == "Kennexath" and d.attackers[1].damage == 545 and d.attackers[1].top_ability == "Seal of Command")
    assert(d.attackers[2].final_blow == true and d.attackers[2].top_ability == "Frostbolt")
    assert(d.damage_taken == 740 and d.duration_sec == 9, "damage/duration")
end)

test("death without a recap falls back to enemies targeting us; PvE deaths ignored", function()
    T.boot()
    T.units.nameplate3 = T.enemy("Thessaly", "Moon", { targeting = "player" })
    T.fire("PLAYER_REGEN_DISABLED")
    T.fire("UNIT_COMBAT", "player", "WOUND", "", 1800, 16)
    T.fire("PLAYER_DEAD")
    assert(#T.reports() == 1 and T.last().killer.name == "Thessaly", "suspect death")
    T.units.nameplate3 = nil
    T.clock = 200
    T.fire("PLAYER_DEAD")
    assert(#T.reports() == 1, "PvE death recorded")
end)

-- ---------------------------------------------------------------------------
-- Robustness
-- ---------------------------------------------------------------------------

test("secret values never raise (UNIT_COMBAT amount, ns.Try)", function()
    local ns = T.boot()
    T.fire("UNIT_COMBAT", "player", "WOUND", "", T.SECRET, 1)
    T.fire("UNIT_COMBAT", "player", T.SECRET, "", T.SECRET, 1)
    assert(not T.said("couldn't process"), "secret raised")
    local a, b = ns.Try(function() return T.SECRET, 5 end)
    assert(a == nil and b == 5, "ns.Try must blank secrets")
end)

test("duplicate unexported death reports are cleaned up on load", function()
    T.boot()
    local saved = { db = WKillboardDB, char = { reports = {
        { kind = "death", occurred_at = 1800000000, client_id = "d1", seq = 1, exported_at = 1 },
        { kind = "death", occurred_at = 1800000000, client_id = "d2", seq = 2, exported_at = 1 },
        { kind = "death", occurred_at = 1800000100, client_id = "d3", seq = 3 },
        { kind = "death", occurred_at = 1800000100, client_id = "d4", seq = 4 },
    } } }
    T.boot({ saved = saved })
    local ids = {}
    for _, r in ipairs(T.reports()) do ids[#ids + 1] = r.client_id end
    assert(table.concat(ids, ",") == "d1,d2,d3", "got " .. table.concat(ids, ","))
end)

-- ---------------------------------------------------------------------------
-- Signing / export
-- ---------------------------------------------------------------------------

test("export needs a key; the token isn't stored; reports are signed and chained", function()
    local ns = T.boot()
    T.units.target = T.enemy("Valeria", nil, { dead = true })
    T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    local blob, _, reason = ns.Export("new")
    assert(blob == nil and reason == "nokey", "export without key")
    local token = "wkb_" .. string.rep("ab", 32)
    SlashCmdList.CORPSERUN("key " .. token)
    assert(ns.HasKey(), "key not saved")
    for _, v in pairs(WKillboardDB) do assert(type(v) ~= "string" or not v:find(string.rep("ab", 32), 1, true), "token stored") end
    local r = T.last()
    assert(r._sig and r.seq == 1, "signed with seq")
    local key = ns.FromHex(WKillboardDB.signKey)
    assert(ns.ToHex(ns.HMAC_SHA256(key, r._sig.r)) == r._sig.s, "signature")
    blob = ns.Export("new")
    assert(blob and blob:sub(1, 5) == "WKB2:", "WKB2 blob")
    assert(ns.Export("new") == nil, "second export empty")
end)

test("/cr clear removes exported reports; the signed chain continues from the last one", function()
    local ns = T.boot()
    SlashCmdList.CORPSERUN("key wkb_" .. string.rep("cd", 32))
    for i = 1, 2 do
        T.units.target = T.enemy("Victim" .. i, nil, { dead = true })
        T.hk = i; T.fire("PLAYER_PVP_KILLS_CHANGED")
    end
    assert(#T.reports() == 2, "two kills")
    local lastSig = T.last()._sig.s
    assert(ns.Export("new"), "exported")
    SlashCmdList.CORPSERUN("clear")
    assert(#T.reports() == 0 and T.said("Removed 2 exported reports"), "exported reports removed")
    -- The next report still points back at the last signature the site saw.
    T.units.target = T.enemy("Victim3", nil, { dead = true })
    T.hk = 3; T.fire("PLAYER_PVP_KILLS_CHANGED")
    local r = T.last()
    assert(r.seq == 3, "seq continues")
    assert(r._sig.r:find('"prev":"' .. lastSig .. '"', 1, true), "prev is the last dropped signature")
    -- An unexported report survives a plain clear.
    SlashCmdList.CORPSERUN("clear")
    assert(#T.reports() == 1 and T.said("Nothing to clear"), "unexported kept")
end)

test("/cr clear all asks first when unexported reports would be lost", function()
    local ns = T.boot()
    T.units.target = T.enemy("Valeria", nil, { dead = true })
    T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    SlashCmdList.CORPSERUN("clear all")
    assert(#T.reports() == 1 and T.said("again within 30 seconds"), "asks first")
    T.clock = T.clock + 5
    SlashCmdList.CORPSERUN("clear all")
    assert(#T.reports() == 0 and T.said("Deleted 1 report."), "second time deletes")
end)

test("damage meter turned off: one warning per session", function()
    T.boot({ cvars = { damageMeterEnabled = "0" } })
    local n = 0
    for _, l in ipairs(T.printed) do if l:find("damage meter is turned off", 1, true) then n = n + 1 end end
    assert(n == 1, "warned once at login")
    T.fire("CVAR_UPDATE", "damageMeterEnabled", "0")
    n = 0
    for _, l in ipairs(T.printed) do if l:find("damage meter is turned off", 1, true) then n = n + 1 end end
    assert(n == 1, "not repeated")
    T.boot()
    assert(not T.said("damage meter is turned off"), "no warning when it's on")
end)

test("debug log: summary, event discovery sees UNIT_DIED", function()
    local ns = T.boot()
    T.fire("UNIT_DIED", "Player-1-x")
    local kinds = {}
    for _, e in ipairs(WKillboardCharDB.debug) do kinds[e.kind] = true end
    assert(kinds.apis and kinds.event, "debug entries missing")
    SlashCmdList.CORPSERUN("debug clear")
    assert(#WKillboardCharDB.debug == 0)
end)

test("slash commands: /cr, /corpserun and the old /wkb all work", function()
    T.boot()
    local names = {}
    for i = 1, 9 do local v = _G["SLASH_CORPSERUN" .. i]; if v then names[v] = true end end
    for _, c in ipairs({ "/cr", "/corpserun", "/wkb", "/wkillboard" }) do assert(names[c], c .. " not registered") end
    SlashCmdList.CORPSERUN("help")
    assert(T.said("/cr export"), "help shows /cr")
end)

test("window: minimize and open state survive a reload, Escape doesn't close it", function()
    T.boot()
    assert(not CorpseRunWindow, "window is not created until it's opened")
    SlashCmdList.CORPSERUN("")
    assert(CorpseRunWindow:IsShown(), "/cr opens it")
    for _, name in ipairs(UISpecialFrames) do assert(name ~= "CorpseRunWindow", "Escape would close it") end
    CorpseRunWindow.minimize.scripts.OnClick()
    assert(not CorpseRunWindow:IsShown() and CorpseRunMini:IsShown(), "minimize swaps to the bar")
    assert(WKillboardDB.window.state == "min")

    -- Reload: minimized again, without opening the full window.
    local db, char = WKillboardDB, WKillboardCharDB
    T.boot({ saved = { db = db, char = char } })
    assert(CorpseRunMini and CorpseRunMini:IsShown(), "bar comes back after reload")
    assert(not CorpseRunWindow, "full window stays closed")
    CorpseRunMini.scripts.OnClick(CorpseRunMini, "LeftButton")
    assert(CorpseRunWindow:IsShown() and not CorpseRunMini:IsShown(), "clicking the bar opens it")

    T.boot({ saved = { db = WKillboardDB, char = WKillboardCharDB } })
    assert(CorpseRunWindow and CorpseRunWindow:IsShown(), "open window comes back after reload")
    SlashCmdList.CORPSERUN("")
    assert(not CorpseRunWindow:IsShown() and WKillboardDB.window.state == "closed", "/cr closes it")
    T.boot({ saved = { db = WKillboardDB, char = WKillboardCharDB } })
    assert(not CorpseRunWindow and not CorpseRunMini, "closed stays closed")
end)

test("minimap button: opens/closes the window, /cr minimap hides it across reloads", function()
    T.boot()
    local b = CorpseRunMinimapButton
    assert(b and b:IsShown(), "button shown by default")
    b.scripts.OnClick(b, "LeftButton")
    assert(CorpseRunWindow and CorpseRunWindow:IsShown(), "click opens the window")
    b.scripts.OnClick(b, "LeftButton")
    assert(not CorpseRunWindow:IsShown(), "click again closes it")
    SlashCmdList.CORPSERUN("minimap")
    assert(not b:IsShown() and WKillboardDB.minimap.hide, "/cr minimap hides it")
    T.boot({ saved = { db = WKillboardDB, char = WKillboardCharDB } })
    assert(CorpseRunMinimapButton and not CorpseRunMinimapButton:IsShown(), "stays hidden after reload")
    SlashCmdList.CORPSERUN("minimap")
    assert(CorpseRunMinimapButton:IsShown(), "/cr minimap shows it again")
end)

-- ---------------------------------------------------------------------------

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        out("PASS  " .. t.name)
    else
        failed = failed + 1
        out("FAIL  " .. t.name .. "\n      " .. tostring(err))
    end
end
out(("%d/%d passed"):format(#tests - failed, #tests))
os.exit(failed == 0 and 0 or 1)
