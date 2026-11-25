-- CorpseRun: shared helpers (safe calls, printing, JSON, base64).
local _, ns = ...

ns.VERSION = "@project-version@"

function ns.Print(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    print("|cffF2C14E[CorpseRun]|r " .. msg)
end

-- Modern clients (Forever runs on one) hand addons some combat values as
-- "secret": they can be passed along but not compared, used in arithmetic or
-- stored. Comparing one raises "attempt to compare a secret number value".
-- We treat them as unknown.
local issecret = issecretvalue
-- Defined once (not as closures per call): these run for nearly every value read.
local function SelfCompare(v) return v <= v end
local function Truthy(v) if v then return 1 end return 0 end

function ns.IsSecret(v)
    if v == nil then return false end
    if issecret then
        -- The client's own answer is authoritative when it has one.
        local ok, secret = pcall(issecret, v)
        if ok then return secret == true end
    end
    -- Without issecretvalue: a number or string that can't be compared is secret.
    local t = type(v)
    if t == "number" or t == "string" then
        return not pcall(SelfCompare, v)
    end
    if t == "boolean" then
        return not pcall(Truthy, v)
    end
    return false
end

--- Debug mode (off by default): `/cr debug on`. Saved account-wide.
function ns.DebugEnabled()
    return WKillboardDB ~= nil and WKillboardDB.debugMode == true
end

--- A plain number (nil if missing or secret).
function ns.Num(v)
    if ns.IsSecret(v) then return nil end
    return tonumber(v)
end

--- A plain string (nil if missing or secret).
function ns.Str(v)
    if type(v) ~= "string" or ns.IsSecret(v) then return nil end
    return v
end
local function Clean(v)
    if ns.IsSecret(v) then return nil end
    return v
end

--- pcall a function that may not exist on this client (Forever blocks/omits many APIs).
--- Secret return values come back as nil.
local function CleanResults(ok, ...)
    if not ok then return nil end
    local n = select("#", ...)
    -- Most calls return one or two values: no table needed for those.
    if n == 1 then return Clean((...)) end
    if n == 2 then local a, b = ...; return Clean(a), Clean(b) end
    if n == 0 then return end
    -- All return values (GetPlayerInfoByGUID has 7), secrets blanked.
    local r = { ... }
    for i = 1, n do r[i] = Clean(r[i]) end
    return unpack(r, 1, n)
end

function ns.Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    return CleanResults(pcall(fn, ...))
end

function ns.Now()
    return time() or 0
end

--- Game version: "forever" | "classic" | "progression" | "retail".
--- Same recording everywhere; this only decides identity (realms vs surnames).
function ns.Game()
    if ns.game then return ns.game end
    local _, _, _, toc = ns.Try(GetBuildInfo)
    toc = tonumber(toc) or 0
    local game
    if toc >= 16000 and toc < 20000 then
        game = "forever"                       -- WoW: Forever (1.60.x)
    elseif toc < 30000 then
        game = "classic"                       -- Classic Era / SoD / Hardcore / Anniversary
    elseif toc < 100000 then
        game = "progression"                   -- Progression Classic (Cata / MoP ...)
    else
        game = "retail"
    end
    ns.game = game
    return game
end

--- Realm of the current character (nil on realmless Forever).
function ns.PlayerRealm()
    if ns.Game() == "forever" then return nil end
    local realm = ns.Try(GetRealmName)
    return (realm and realm ~= "") and realm or nil
end

--- Display name for a class file token ("DEATHKNIGHT" -> "Death Knight").
local CLASS_NAMES = { DEATHKNIGHT = "Death Knight", DEMONHUNTER = "Demon Hunter" }
function ns.ClassName(classFile)
    if not classFile then return nil end
    local upper = classFile:upper()
    local localized = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[upper]
    if localized then return localized end
    if CLASS_NAMES[upper] then return CLASS_NAMES[upper] end
    local lower = upper:lower()
    return lower:sub(1, 1):upper() .. lower:sub(2)
end

--- First name only: strips "-Realm" suffixes and, on Forever, the surname
--- some clients include after a space ("Swinton Lightsblade" -> "Swinton").
--- Names elsewhere never contain spaces.
function ns.ShortName(name)
    if type(name) ~= "string" then return nil end
    name = (name:match("^([^%-]+)")) or name
    return (name:match("^%s*(%S+)")) or name
end

--- "Swinton Lightsblade-CAMWOWUS1Realm8PvP" -> "Swinton", "Lightsblade".
--- Returns the first name and the surname after the space (or nil).
function ns.SplitName(full)
    if type(full) ~= "string" then return nil end
    local base = (full:match("^([^%-]+)")) or full
    local name, surname = base:match("^%s*(%S+)%s+(.-)%s*$")
    if not name then return ns.ShortName(full), nil end
    return name, surname ~= "" and surname or nil
end

--- A surname from the client's "realm" slot. Forever puts the surname there
--- for some players but Blizzard's internal server name (e.g.
--- "CAMWOWUS1Realm8PvP") for players from another server; surnames never
--- contain digits, server names always do.
function ns.SurnameFromRealmSlot(s)
    if type(s) ~= "string" or s == "" or s:find("%d") then return nil end
    return s
end

-- ---------------------------------------------------------------------------
-- JSON encoder. Tables with [1] are arrays; everything else is an object.
-- Empty tables encode as {} - callers omit empty arrays instead of sending them.
-- ---------------------------------------------------------------------------

local function jsonString(s)
    s = s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

local function jsonValue(v, depth)
    if depth > 16 then return "null" end
    local t = type(v)
    if v == nil then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
        return string.format("%.6g", v)
    end
    if t == "string" then return jsonString(v) end
    if t ~= "table" then return "null" end

    local parts = {}
    if v[1] ~= nil then
        for i = 1, #v do parts[i] = jsonValue(v[i], depth + 1) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do
        if type(k) == "string" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = jsonString(k) .. ":" .. jsonValue(v[k], depth + 1)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

function ns.ToJSON(v)
    return jsonValue(v, 0)
end

-- ---------------------------------------------------------------------------
-- Base64 (standard alphabet, padded). Pure Lua 5.1, no bit ops needed.
-- ---------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function ns.Base64(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=")
            .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end
