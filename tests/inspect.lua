-- Summarize a CorpseRun per-character SavedVariables file:
--   docker run ... lua /addon/tests/inspect.lua /sv/CorpseRun.lua [since_unix]
local path, since = arg[1], tonumber(arg[2] or "0")
dofile(path)
local db = WKillboardCharDB
local function show(v, ind, depth, maxDepth)
    if type(v) ~= "table" then print(ind .. tostring(v)); return end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local x = v[k]
        if type(x) == "table" and depth < maxDepth then print(ind .. tostring(k) .. ":"); show(x, ind .. "  ", depth + 1, maxDepth)
        else print(ind .. tostring(k) .. " = " .. tostring(x)) end
    end
end
print("== reports since " .. os.date("!%H:%M:%S", since))
for i, r in ipairs(db.reports) do
    if (r.occurred_at or 0) >= since then
        local v = r.victim
        print(string.format("#%d %s %s %s victim=%s killer=%s dmg=%s dur=%s exported=%s", i, r.kind, os.date("!%H:%M:%S", r.occurred_at),
            tostring(r.zone), v and (v.name .. " " .. (v.surname or "") .. " " .. tostring(v.race) .. " " .. tostring(v.class)) or "-",
            r.killer and (r.killer.name .. " " .. (r.killer.surname or "")) or "-", tostring(r.damage_taken), tostring(r.duration_sec), tostring(r.exported_at ~= nil)))
        for _, a in ipairs(r.attackers or {}) do
            print(string.format("     %s %s %s dmg=%s %s%s", a.name, a.surname or "", tostring(a.class), tostring(a.damage), tostring(a.top_ability), a.final_blow and " FB" or ""))
        end
    end
end
print("== debug since")
for _, e in ipairs(db.debug or {}) do
    if e.t >= since and e.kind ~= "zone" then
        print("-- " .. os.date("!%H:%M:%S", e.t) .. " " .. e.kind)
        if e.kind ~= "apis" then show(e, "   ", 0, tonumber(arg[3] or "6")) end
    end
end
