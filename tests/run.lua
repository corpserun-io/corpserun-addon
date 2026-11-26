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
    C_Map.GetPlayerMapPosition = function() return { x = 0.9, y = 0.1 } end   -- we've moved on since
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
    assert(k.x == 0.4213 and k.y == 0.5501, "location of the bare kill kept")
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
    assert(T.said("held until you leave combat") and not T.last().exported_at, "in-combat kill held back")
end)

test("in combat, export holds kills still waiting for details (and what follows); out of combat sends them", function()
    local ns = T.boot()
    SlashCmdList.CORPSERUN("key wkb_" .. string.rep("ab", 32))
    T.units.target = T.enemy("Victim1", nil, { dead = true })
    T.clock = 10; T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    T.units.target = nil
    T.inCombat = false
    T.clock = 20; T.fire("PLAYER_REGEN_ENABLED")             -- the scan after that fight: Victim1 is ready
    T.inCombat = true
    T.clock = 30; T.fire("PLAYER_REGEN_DISABLED")
    T.units.target = T.enemy("Victim2", nil, { dead = true })
    T.clock = 40; T.hk = 2; T.fire("PLAYER_PVP_KILLS_CHANGED")
    assert(#T.reports() == 2, "two kills, got " .. #T.reports())
    local ready, held = ns.ExportStatus()
    assert(ready == 1 and held == 1, ("status %d ready / %d held"):format(ready, held))
    local blob, count, _, h = ns.Export("new")
    assert(blob and count == 1 and h == 1, "exported the earlier kill only")
    assert(T.reports()[1].exported_at and not T.reports()[2].exported_at, "current-fight kill held")
    T.inCombat = false
    T.clock = 50
    blob, count = ns.Export("new")
    assert(blob and count == 1 and T.reports()[2].exported_at, "sent once out of combat")
end)

--- A party of three: Thrall and Jaina fighting with us, Bob far away.
local function Party()
    T.units.party1 = { name = "Thrall", second = "Doe", class = { "Shaman", "SHAMAN" }, race = "Orc", level = 40,
                       faction = "Horde", guid = "Player-1-0002", inCombat = true }
    T.units.party2 = { name = "Jaina", class = { "Mage", "MAGE" }, race = "Undead", level = 38,
                       faction = "Horde", guid = "Player-1-0003", inCombat = true }
    T.units.party3 = { name = "Bob", class = { "Rogue", "ROGUE" }, race = "Orc", level = 30,
                       faction = "Horde", guid = "Player-1-0004", inCombat = true, inRange = false }
    T.group = { "Player-1-0001", "Player-1-0002", "Player-1-0003", "Player-1-0004" }
end

test("open-world party kill: group members in the fight are its attackers (no solo credit)", function()
    T.boot()
    Party()
    T.units.party2.inCombat = false                                  -- Jaina wasn't fighting
    T.units.target = T.enemy("Valeria", nil, { dead = true })
    T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    local r = T.last()
    assert(r and r.group_size == 4, "kill with group size")
    assert(r.attackers and #r.attackers == 1 and r.attackers[1].name == "Thrall" and r.attackers[1].surname == "Doe",
        "attackers: " .. (r.attackers and #r.attackers or 0))
    assert(r.attackers[1].damage == nil and not r.killer, "no damage or killer guessed")
    -- Solo (a 1v1): no attackers, as before.
    T.boot()
    T.units.target = T.enemy("Valeria", nil, { dead = true })
    T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    assert(T.last() and T.last().attackers == nil, "solo kill has no attackers")
end)

test("open-world party kill: the meter's breakdown gives each member's damage after combat", function()
    local ns = T.boot()
    SlashCmdList.CORPSERUN("key wkb_" .. string.rep("ab", 32))
    Party()
    T.guids["Player-6926-004BFD85"] = { "Paladin", "PALADIN", "Human", 2, "Swinton Lightsblade", "CAMWOWUS1Realm8PvP" }
    T.clock = 100; T.fire("PLAYER_REGEN_DISABLED")
    T.clock = 121; T.fire("UNIT_DIED", "Player-6926-004BFD85")
    T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    assert(#T.last().attackers == 2, "fallback: Thrall and Jaina (Bob out of range)")
    T.meterEnemy = { durationSeconds = 20, combatSources = {
        { name = "Swinton Lightsblade", sourceGUID = "Player-6926-004BFD85", totalAmount = 1500 },
    } }
    -- The shape Forever returns (from a debug log): one entry per unit, its
    -- damage in totalAmount, a single details table naming it (amount 0).
    T.meterVictim["Player-6926-004BFD85"] = { maxAmount = 950, totalAmount = 1500, combatSpells = {
        { spellID = 0, totalAmount = 950, overkillAmount = 0, amountPerSecond = 0, isAvoidable = false, isDeadly = false,
          combatSpellDetails = { unitName = "Thrall Doe", amount = 0, isPet = false, isMob = false, unitClassFilename = "" } },
        { spellID = 0, totalAmount = 500, combatSpellDetails = { unitName = "Gorvash", amount = 0 } },
        { spellID = 0, totalAmount = 50, combatSpellDetails = { unitName = "Stranger", amount = 0 } },
    } }
    T.inCombat = false
    T.clock = 126; T.fire("PLAYER_REGEN_ENABLED")
    local r = T.last()
    assert(r.meter_damage == 1500 and r.reporter_damage == 500, "damage: " .. tostring(r.reporter_damage))
    assert(r.attackers and #r.attackers == 1 and r.attackers[1].name == "Thrall" and r.attackers[1].damage == 950,
        "breakdown attackers (Jaina did nothing, the stranger isn't in the group)")
    assert(ns.SignedJSON(r):find('"damage":950', 1, true), "signed again with the attackers")
end)

test("open-world kill: players outside our group fighting the victim are listed (no damage), kept after the meter", function()
    T.boot()
    Party()
    local victim = T.enemy("Swinton", "Lightsblade", { guid = "Player-6926-004BFD85" })
    T.units.target = victim
    -- Terra (not in our group) is fighting it; Idle is around but not in combat; a
    -- friendly player on someone else isn't counted either.
    T.units.nameplate2 = { name = "Terra", second = "Hux", class = { "Druid", "DRUID" }, race = "Tauren", level = 35,
                           faction = "Horde", guid = "Player-1-0010", inCombat = true, targeting = "target" }
    T.units.nameplate3 = { name = "Idle", class = { "Mage", "MAGE" }, race = "Troll", faction = "Horde",
                           guid = "Player-1-0011", targeting = "target" }
    T.units.nameplate4 = { name = "Busy", class = { "Rogue", "ROGUE" }, race = "Orc", faction = "Horde",
                           guid = "Player-1-0012", inCombat = true, targeting = "nameplate2" }
    for i = 2, 4 do T.fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. i) end
    T.clock = 100; T.fire("PLAYER_REGEN_DISABLED")
    victim.dead = true
    T.clock = 121; T.fire("UNIT_DIED", victim.guid)
    T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    local names = {}
    for _, a in ipairs(T.last().attackers or {}) do names[a.name] = a end
    assert(names.Thrall and names.Jaina, "group members")
    assert(names.Terra and names.Terra.damage == nil and names.Terra.surname == "Hux", "helper outside the group")
    assert(not names.Idle and not names.Busy, "not fighting it")
    -- The meter's breakdown (our group only) replaces the group guess but keeps Terra.
    T.meterEnemy = { durationSeconds = 20, combatSources = {
        { name = "Swinton Lightsblade", sourceGUID = victim.guid, totalAmount = 1500 },
    } }
    T.meterVictim[victim.guid] = { maxAmount = 950, totalAmount = 1500, combatSpells = {
        { spellID = 0, totalAmount = 950, combatSpellDetails = { unitName = "Thrall Doe", amount = 0 } },
        { spellID = 0, totalAmount = 550, combatSpellDetails = { unitName = "Gorvash", amount = 0 } },
    } }
    T.inCombat = false
    T.clock = 126; T.fire("PLAYER_REGEN_ENABLED")
    names = {}
    for _, a in ipairs(T.last().attackers or {}) do names[a.name] = a end
    assert(names.Thrall and names.Thrall.damage == 950, "meter damage")
    assert(not names.Jaina, "Jaina did nothing")
    assert(names.Terra and names.Terra.damage == nil, "helper kept after the meter fill")
end)

test("/cr backfill: exported group kill without damage gets a follow-up from the debug log's breakdown", function()
    local ns = T.boot()
    SlashCmdList.CORPSERUN("key wkb_" .. string.rep("ab", 32))
    Party()
    T.units.target = T.enemy("Valeria", nil, { dead = true })
    T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    T.inCombat = false
    assert(ns.Export("new"), "exported")
    local r = T.reports()[1]
    assert(#r.attackers == 2 and r.attackers[1].damage == nil, "went out with names only")
    -- What debug mode logged when the meter was read after that fight.
    table.insert(WKillboardCharDB.debug, { kind = "meter_victim", t = r.occurred_at + 10, guid = r.victim.guid, ok = true,
        source = { totalAmount = 1500, maxAmount = 950, combatSpells = {
            { spellID = 0, totalAmount = 950, combatSpellDetails = { unitName = "Thrall Doe", amount = 0 } },
            { spellID = 0, totalAmount = 500, combatSpellDetails = { unitName = "Gorvash", amount = 0 } },
            { spellID = 0, totalAmount = 50, combatSpellDetails = { unitName = "Stranger", amount = 0 } },
        } } })
    SlashCmdList.CORPSERUN("backfill")
    assert(#T.reports() == 2 and T.said("Added 1 follow-up"), "one follow-up")
    local f = T.last()
    assert(f.client_id ~= r.client_id and f.occurred_at == r.occurred_at and f.victim.guid == r.victim.guid, "same kill, new report")
    assert(#f.attackers == 1 and f.attackers[1].name == "Thrall" and f.attackers[1].damage == 950, "member damage")
    assert(f.reporter_damage == 500 and f.meter_damage == 1500, "our damage and the total")
    assert(f._sig and not f.exported_at and ns.IsFollowUp(f) and not ns.IsFollowUp(r), "signed, waiting to export")
    assert(r.exported_at and r.attackers[1].damage == nil, "the exported report is untouched")
    SlashCmdList.CORPSERUN("backfill")
    assert(#T.reports() == 2, "only once per kill")
    local blob, count = ns.Export("new")
    assert(blob and count == 1, "the follow-up exports")
end)

--- A kept meter fight in which `guid` took `total`, `lines` = { { "Name", damage }, ... }.
local function Fight(id, name, guid, total, lines)
    local spells = {}
    for _, l in ipairs(lines) do
        spells[#spells + 1] = { spellID = 0, totalAmount = l[2], combatSpellDetails = { unitName = l[1], amount = 0 } }
    end
    return { id = id, enemy = { durationSeconds = 25, combatSources = { { name = name, sourceGUID = guid, totalAmount = total } } },
             victims = { [guid] = { totalAmount = total, combatSpells = spells } } }
end

test("back-to-back fights: each kill gets its own fight's details from the meter's kept fights", function()
    T.boot()
    Party()
    T.units.target = T.enemy("Valeria", nil, { dead = true })
    T.clock = 10; T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    T.fire("PLAYER_REGEN_ENABLED")                 -- straight into the next fight: still in combat, nothing read
    T.units.target = T.enemy("Mira", nil, { dead = true })
    T.clock = 40; T.hk = 2; T.fire("PLAYER_PVP_KILLS_CHANGED")
    T.meterSessions = {
        Fight(7, "Valeria", "Player-9-Valeria", 800, { { "Thrall Doe", 600 }, { "Gorvash", 200 } }),
        Fight(8, "Mira", "Player-9-Mira", 900, { { "Jaina", 900 } }),
    }
    T.inCombat = false
    T.clock = 60; T.fire("PLAYER_REGEN_ENABLED")
    local v, m = T.reports()[1], T.reports()[2]
    assert(v.meter_damage == 800 and v.reporter_damage == 200 and #v.attackers == 1 and v.attackers[1].damage == 600,
        "first fight's kill: " .. tostring(v.meter_damage))
    assert(m.meter_damage == 900 and #m.attackers == 1 and m.attackers[1].name == "Jaina", "second fight's kill")
end)

test("healing: the group's Healing Done and Absorbs for the kill's fight become its healers (us included)", function()
    local ns = T.boot()
    SlashCmdList.CORPSERUN("key wkb_" .. string.rep("ab", 32))
    Party()
    T.units.target = T.enemy("Valeria", nil, { dead = true })
    T.clock = 10; T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    local f = Fight(7, "Valeria", "Player-9-Valeria", 800, { { "Thrall Doe", 600 }, { "Gorvash", 200 } })
    f.heals = { durationSeconds = 25, combatSources = {
        { name = "Thrall Doe", sourceGUID = "Player-1-0002", totalAmount = 2400 },
        { name = "Gorvash", sourceGUID = "Player-1-0001", totalAmount = 120, isLocalPlayer = true },
        { name = "Stranger", sourceGUID = "Player-5-0001", totalAmount = 9000 },     -- not in our group
    } }
    f.absorbs = { combatSources = { { name = "Jaina", sourceGUID = "Player-1-0003", totalAmount = 300 } } }
    f.healSpells = { ["Player-1-0002"] = { combatSpells = {
        { spellID = 331, totalAmount = 400 }, { spellID = 8004, totalAmount = 2000 },
    } } }
    T.meterSessions = { f }
    T.inCombat = false
    T.clock = 40; T.fire("PLAYER_REGEN_ENABLED")
    local r = T.last()
    assert(r.healers and #r.healers == 3, "healers: " .. (r.healers and #r.healers or 0))
    local h = r.healers
    assert(h[1].name == "Thrall" and h[1].surname == "Doe" and h[1].healing == 2400 and h[1].top_ability == "Lesser Healing Wave", "Thrall heals most: " .. tostring(h[1].top_ability))
    assert(h[2].name == "Jaina" and h[2].absorbs == 300 and h[2].healing == nil, "Jaina's shields")
    assert(h[3].name == "Gorvash" and h[3].healing == 120, "our own healing")
    assert(ns.SignedJSON(r):find('"healing":2400', 1, true), "signed again with the healers")
    -- A fight without healing lists leaves the kill alone.
    T.boot()
    T.units.target = T.enemy("Mira", nil, { dead = true })
    T.clock = 10; T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    T.meterSessions = { Fight(8, "Mira", "Player-9-Mira", 900, {}) }
    T.inCombat = false
    T.clock = 40; T.fire("PLAYER_REGEN_ENABLED")
    assert(T.last().healers == nil, "no healers")
end)

test("/cr backfill: the meter's kept fights fill exported kills, only when kills and fights pair up", function()
    local ns = T.boot()
    SlashCmdList.CORPSERUN("key wkb_" .. string.rep("ab", 32))
    Party()
    T.units.target = T.enemy("Valeria", nil, { dead = true })
    T.clock = 10; T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    T.units.target = T.enemy("Mira", nil, { dead = true })
    T.clock = 40; T.hk = 2; T.fire("PLAYER_PVP_KILLS_CHANGED")
    T.inCombat = false
    assert(ns.Export("new"), "exported with names only")
    T.meterSessions = {
        Fight(5, "Mira", "Player-9-Mira", 300, { { "Jaina", 300 } }),           -- an earlier fight Mira survived
        Fight(7, "Valeria", "Player-9-Valeria", 800, { { "Thrall Doe", 600 }, { "Gorvash", 200 } }),
        Fight(8, "Mira", "Player-9-Mira", 900, { { "Jaina", 900 } }),
    }
    SlashCmdList.CORPSERUN("backfill")
    assert(#T.reports() == 3, "one follow-up, got " .. (#T.reports() - 2))
    local f = T.last()
    assert(f.victim.name == "Valeria" and f.attackers[1].name == "Thrall" and f.attackers[1].damage == 600 and f.reporter_damage == 200,
        "Valeria filled")
    -- Mira took damage in two fights but died once: can't tell which, so skipped.
    -- Our own death to Mira before the kill explains the other fight: now it pairs up.
    table.insert(WKillboardCharDB.reports, 1, { kind = "death", client_id = "d-mira", occurred_at = 1800000005, exported_at = 1,
        killer = { name = "Mira", guid = "Player-9-Mira" }, attackers = { { name = "Mira", guid = "Player-9-Mira", damage = 700 } } })
    SlashCmdList.CORPSERUN("backfill")
    local m = T.last()
    assert(#T.reports() == 5 and m.victim.name == "Mira" and m.attackers[1].name == "Jaina" and m.attackers[1].damage == 900,
        "Mira filled from the newer fight")
end)

test("killmail location: where we were when the victim died, not where the scan ran", function()
    T.boot()
    T.fire("UNIT_DIED", "Player-9-M")                        -- at the starting position
    C_Map.GetPlayerMapPosition = function() return { x = 0.9, y = 0.1 } end
    T.zone = "Stormwind City"
    T.recaps[3001] = { ev("Gorvash", "Player-1-0001", "Mira Dawn", "Player-9-M", "Execute", 400, 50, 1800000000) }
    T.meterDeaths = { { deathRecapID = 3001, isLocalPlayer = false, classFilename = "PRIEST", name = T.SECRET } }
    T.inCombat = false
    T.clock = 30; T.fire("PLAYER_REGEN_ENABLED")
    local k = T.last()
    assert(k and k.victim.name == "Mira", "killmail recorded")
    assert(k.x == 0.4213 and k.zone == "Elwynn Forest", ("location %s %s"):format(tostring(k.x), tostring(k.zone)))
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

test("death to our own damage: never our own attacker; mid-fight the last enemy hit gets the kill", function()
    T.boot()
    local me = T.units.player.guid
    local t = 1800000000 + 100
    T.clock = 100
    -- Alone in the open world: only our own Hellfire and a mob. Not a PvP death.
    T.recap = {
        { amount = 300, overkill = 12, sourceName = "Gorvash", sourceGUID = me, spellName = "Hellfire Effect", event = "SPELL_DAMAGE", timestamp = t - 0.5 },
        { amount = 610, overkill = -1, sourceName = "Gorvash", sourceGUID = me, spellName = "Life Tap", event = "SPELL_DAMAGE", timestamp = t - 20 },
        { amount = 80, overkill = -1, sourceName = "Boulderfist Ogre", sourceGUID = "Creature-0-1-2-3-4-5", spellName = "Melee", event = "SWING_DAMAGE", timestamp = t - 30 },
    }
    T.fire("PLAYER_DEAD")
    assert(#T.reports() == 0, "self death recorded as PvP")

    -- In a fight: two enemies hit us, then our own Life Tap finishes us.
    T.clock = 300
    t = 1800000000 + 300
    T.recap = {
        { amount = 200, overkill = 5, sourceName = "Gorvash", sourceGUID = me, spellName = "Life Tap", event = "SPELL_DAMAGE", timestamp = t - 0.2 },
        { amount = 150, overkill = -1, sourceName = "Jute Gyte", sourceGUID = "Player-6798-00370993", spellName = "Frostbolt", event = "SPELL_DAMAGE", timestamp = t - 1 },
        { amount = 500, overkill = -1, sourceName = "Kennexath Ash", sourceGUID = "Player-6801-002DE511", spellName = "Seal of Command", event = "SPELL_DAMAGE", timestamp = t - 4 },
    }
    T.fire("PLAYER_DEAD")
    local d = T.last()
    assert(d and d.kind == "death", "fight death not recorded")
    assert(#d.attackers == 2, "attackers: " .. #d.attackers)
    for _, a in ipairs(d.attackers) do assert(a.name ~= "Gorvash", "we're our own attacker") end
    assert(d.killer and d.killer.name == "Jute", "killing blow: " .. tostring(d.killer and d.killer.name))
    assert(d.damage_taken == 850, "self damage still counts: " .. tostring(d.damage_taken))
end)

test("death without a recap falls back to enemies targeting us; PvE deaths ignored", function()
    local ns = T.boot()
    assert(ns.recorderFrame.unitEvents and ns.recorderFrame.unitEvents.UNIT_COMBAT == "player", "UNIT_COMBAT for the player only")
    T.units.nameplate3 = T.enemy("Thessaly", "Moon", { targeting = "player" })
    T.fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
    T.fire("PLAYER_REGEN_DISABLED")
    T.fire("UNIT_COMBAT", "player", "WOUND", "", 1800, 16)
    T.fire("UNIT_COMBAT", "player", "WOUND", "", 200, 16)       -- same moment: no second scan
    assert(ns.FightSnapshot().suspects[1].hits == 1, "suspect scan not throttled")
    assert(ns.FightSnapshot().damage == 2000, "damage still counts every hit")
    T.clock = 1
    T.fire("UNIT_COMBAT", "player", "WOUND", "", 100, 16)
    assert(ns.FightSnapshot().suspects[1].hits == 2, "scans again after the interval")
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
    assert(ns.ToHex(ns.HMAC_SHA256(key, ns.SignedJSON(r))) == r._sig.s, "signature")
    assert(r._sig.r == nil, "signed JSON isn't saved a second time")
    T.inCombat = false                                  -- (in combat the kill would be held for its details)
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
    T.inCombat = false
    assert(ns.Export("new"), "exported")
    SlashCmdList.CORPSERUN("clear")
    assert(#T.reports() == 0 and T.said("Removed 2 exported reports"), "exported reports removed")
    -- The next report still points back at the last signature the site saw.
    T.units.target = T.enemy("Victim3", nil, { dead = true })
    T.hk = 3; T.fire("PLAYER_PVP_KILLS_CHANGED")
    local r = T.last()
    assert(r.seq == 3, "seq continues")
    assert(ns.SignedJSON(r):find('"prev":"' .. lastSig .. '"', 1, true), "prev is the last dropped signature")
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

test("settings: what's off is named once per game session, never again after a /reload or a change", function()
    local function count(text)
        local n = 0
        for _, l in ipairs(T.printed) do if l:find(text, 1, true) then n = n + 1 end end
        return n
    end
    T.boot({ cvars = { damageMeterEnabled = "1", nameplateShowEnemies = "1", nameplateShowFriends = "0" } })
    assert(T.said("Friendly nameplates are off. Please turn them on in the game's Options to collect all data."),
        "friendly nameplates off at login")
    assert(count(" off. Please turn") == 1, "one message")
    T.cvars.nameplateShowEnemies = "0"
    T.fire("CVAR_UPDATE", "nameplateShowEnemies", "0")
    T.fire("PLAYER_ENTERING_WORLD", false, false)           -- loading screen
    assert(count(" off. Please turn") == 1, "not repeated in the same session")
    -- A /reload restarts the addon: still no repeat.
    T.boot({ reload = true, cvars = { damageMeterEnabled = "1", nameplateShowEnemies = "1", nameplateShowFriends = "0" } })
    assert(not T.said("off. Please turn"), "not repeated after a /reload")
    T.boot({ cvars = { damageMeterEnabled = "0", nameplateShowEnemies = "0", nameplateShowFriends = "0" } })
    assert(T.said("The damage meter, enemy nameplates and friendly nameplates are off. Please turn them on"), "all three in one line")
    T.boot({ cvars = { damageMeterEnabled = "0", nameplateShowEnemies = "1", nameplateShowFriends = "1" } })
    assert(T.said("The damage meter is off. Please turn it on"), "one setting, singular")
    SlashCmdList.CORPSERUN("check")
    assert(T.said("on|r friendly nameplates") and T.said("(key V)"), "/cr check lists them")
    T.boot({ cvars = { damageMeterEnabled = "1", nameplateShowEnemies = "1", nameplateShowFriends = "1" } })
    assert(not T.said(" off."), "no warning when all are on")
    T.boot()
    assert(not T.said("nameplates"), "unknown settings count as on")
    -- Forever: friendly players' nameplates have their own setting.
    T.boot({ cvars = { damageMeterEnabled = "1", nameplateShowEnemies = "1", nameplateShowFriends = "0", nameplateShowFriendlyPlayers = "1" } })
    assert(not T.said(" off."), "friendly player nameplates on counts")
    T.boot({ cvars = { damageMeterEnabled = "1", nameplateShowEnemies = "1", nameplateShowFriendlyPlayers = "0" } })
    assert(T.said("Friendly nameplates are off"), "only the Forever setting, off")
end)

local function ListeningToAll()
    for _, f in ipairs(T.frames()) do if f.all then return true end end
    return false
end

test("debug mode: off by default; /cr debug on logs and discovers events, off stops", function()
    T.boot()
    T.fire("UNIT_DIED", "Player-1-x")
    assert(#WKillboardCharDB.debug == 0, "logged while off")
    assert(not ListeningToAll(), "listening to every event while off")
    SlashCmdList.CORPSERUN("debug on")
    assert(WKillboardDB.debugMode == true and ListeningToAll(), "on")
    T.fire("UNIT_DIED", "Player-1-x")
    local kinds = {}
    for _, e in ipairs(WKillboardCharDB.debug) do kinds[e.kind] = true end
    assert(kinds.apis and kinds.event, "debug entries missing")
    SlashCmdList.CORPSERUN("debug off")
    assert(not WKillboardDB.debugMode and not ListeningToAll(), "off")
    local n = #WKillboardCharDB.debug
    T.clock = 100
    T.fire("UNIT_DIED", "Player-1-y")
    T.fire("PLAYER_DEAD")
    assert(#WKillboardCharDB.debug == n, "logged after turning it off")
    SlashCmdList.CORPSERUN("debug clear")
    assert(#WKillboardCharDB.debug == 0)
    SlashCmdList.CORPSERUN("debug on")
    T.boot({ saved = { db = WKillboardDB, char = WKillboardCharDB } })
    assert(ListeningToAll(), "debug mode survives a reload")
end)

test("meter details added after a kill was signed are signed again and exported", function()
    local ns = T.boot()
    SlashCmdList.CORPSERUN("key wkb_" .. string.rep("ef", 32))
    T.units.player.guid = "Player-6930-00D7BA05"
    T.guids["Player-6926-004BFD85"] = { "Paladin", "PALADIN", "Human", 2, "Swinton Lightsblade", "CAMWOWUS1Realm8PvP" }
    T.units.target = T.enemy("Valeria", nil, { dead = true })        -- an earlier kill (before the fight)
    T.clock = 50; T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    T.units.target = nil
    T.clock = 100; T.fire("PLAYER_REGEN_DISABLED")
    T.clock = 121; T.fire("UNIT_DIED", "Player-6926-004BFD85")
    T.hk = 2; T.fire("PLAYER_PVP_KILLS_CHANGED")
    assert(#T.reports() == 2, "two kills, got " .. #T.reports())
    local before = T.last()._sig.s
    T.meterEnemy = { durationSeconds = 26, combatSources = {
        { name = "Swinton Lightsblade", sourceGUID = "Player-6926-004BFD85", totalAmount = 774 },
    } }
    T.inCombat = false
    T.clock = 126; T.fire("PLAYER_REGEN_ENABLED")
    local r = T.last()
    assert(r.meter_damage == 774, "meter fill")
    assert(r._sig.s ~= before, "not signed again")
    local json = ns.SignedJSON(r)
    assert(json:find('"meter_damage":774', 1, true), "signed copy lacks the meter damage")
    assert(ns.ToHex(ns.HMAC_SHA256(ns.FromHex(WKillboardDB.signKey), json)) == r._sig.s, "signature")
    assert(json:find('"prev":"' .. T.reports()[1]._sig.s .. '"', 1, true), "chained to the kill before")
    assert(ns.Export("new"), "exported")
end)

test("a killmail replacing a signed kill re-signs the reports after it", function()
    local ns = T.boot()
    SlashCmdList.CORPSERUN("key wkb_" .. string.rep("ab", 32))
    T.units.player.guid = "Player-6930-00D7BA05"
    T.units.target = T.enemy("Swinton Lightsblade", "CAMWOWUS1Realm8PvP", { guid = "Player-6926-004BFD85" })
    T.clock = 100
    T.fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Swinton Lightsblade-CAMWOWUS1Realm8PvP dies (Honorable Kill). You gain 5 Honor.")
    T.units.target = T.enemy("Valeria", nil, { dead = true })
    T.clock = 120; T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    assert(#T.reports() == 2, "two kills, got " .. #T.reports())
    local t = 1800000000 + 100
    T.recaps[2001] = { ev("Sathorian Hurden", "Player-6930-00D7BA05", "Swinton Lightsblade-CAMWOWUS1Realm8PvP", "Player-6926-004BFD85", "Wrath", 120, 30, t) }
    T.meterDeaths = { { deathRecapID = 2001, isLocalPlayer = false, classFilename = "PALADIN", name = T.SECRET } }
    T.inCombat = false
    T.clock = 130; T.fire("PLAYER_REGEN_ENABLED")
    local list = T.reports()
    assert(#list == 2 and list[1].victim.name == "Valeria" and list[2].killer, "killmail replaced the bare kill")
    assert(ns.SignedJSON(list[1]):find('"prev":""', 1, true), "Valeria re-signed: first in the log now")
    assert(ns.SignedJSON(list[2]):find('"prev":"' .. list[1]._sig.s .. '"', 1, true), "killmail chained to Valeria")
end)

test("old saves: stored signed JSON is dropped only when it rebuilds exactly", function()
    local ns = T.boot()
    SlashCmdList.CORPSERUN("key wkb_" .. string.rep("ab", 32))
    for i = 1, 2 do
        T.units.target = T.enemy("Victim" .. i, nil, { dead = true })
        T.clock = i * 100; T.hk = i; T.fire("PLAYER_PVP_KILLS_CHANGED")
    end
    local a, b = T.reports()[1], T.reports()[2]
    local jsonA = ns.SignedJSON(a)
    a._sig = { kid = a._sig.kid, r = jsonA, s = a._sig.s }                    -- the old format
    b._sig = { kid = b._sig.kid, r = ns.SignedJSON(b) .. " ", s = b._sig.s }  -- doesn't rebuild the same
    ns = T.boot({ saved = { db = WKillboardDB, char = WKillboardCharDB } })
    a, b = T.reports()[1], T.reports()[2]
    assert(a._sig.r == nil and a._sig.p == "" and ns.SignedJSON(a) == jsonA, "compacted")
    assert(b._sig.r ~= nil, "a copy that doesn't match is kept")
end)

test("window list is virtual: a long log fills only the visible rows", function()
    T.boot()
    for i = 1, 30 do
        T.units.target = T.enemy("Victim" .. i, nil, { dead = true })
        T.clock = i * 100; T.hk = i; T.fire("PLAYER_PVP_KILLS_CHANGED")
    end
    assert(#T.reports() == 30, "30 kills, got " .. #T.reports())
    SlashCmdList.CORPSERUN("")
    local filled = 0
    for _, f in ipairs(T.frames()) do if rawget(f, "report") then filled = filled + 1 end end
    assert(filled > 0 and filled <= 10, "rows filled: " .. filled)
end)

test("window: kills are tagged solo or party (a backfill follow-up counts)", function()
    local ns = T.boot()
    T.units.target = T.enemy("Lonely", nil, { dead = true })
    T.clock = 100; T.hk = 1; T.fire("PLAYER_PVP_KILLS_CHANGED")
    Party()
    T.units.target = T.enemy("Crowded", nil, { dead = true })
    T.clock = 200; T.hk = 2; T.fire("PLAYER_PVP_KILLS_CHANGED")
    local solo, party = T.reports()[1], T.reports()[2]
    assert(ns.FightSize(solo) == 1 and ns.FightSize(party) == 3, "sizes " .. ns.FightSize(solo) .. " " .. ns.FightSize(party))
    SlashCmdList.CORPSERUN("")
    local subs = {}
    for _, f in ipairs(T.frames()) do
        local r = rawget(f, "report")
        if r then subs[r.victim.name] = rawget(f.sub, "text_") end
    end
    assert(subs.Lonely and subs.Lonely:find("Solo"), "solo row: " .. tostring(subs.Lonely))
    assert(subs.Crowded and subs.Crowded:find("Party") and subs.Crowded:find(" 3"), "party row: " .. tostring(subs.Crowded))
    -- A follow-up listing two members turns the solo-looking kill into a party kill.
    WKillboardCharDB.followUps = { fu1 = solo.client_id }
    table.insert(WKillboardCharDB.reports, { kind = "kill", client_id = "fu1", victim = solo.victim,
        attackers = { { name = "Thrall" }, { name = "Jaina" } } })
    ns.RefreshWindow()
    assert(ns.FightSize(solo) == 3, "follow-up counted: " .. ns.FightSize(solo))
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
