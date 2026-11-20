-- CorpseRun: SHA-256 and HMAC-SHA256 in pure Lua 5.1 (WoW has no crypto API).
-- Uses the client's `bit` library. Results are normalised mod 2^32, so this
-- works whether `bit` returns signed (LuaBitOp) or unsigned 32-bit numbers.
local _, ns = ...

local band, bor, bxor, bnot, rshift, lshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.rshift, bit.lshift
local MOD = 4294967296
local floor, char, byte, concat, rep, format = math.floor, string.char, string.byte, table.concat, string.rep, string.format

local function u(x) return x % MOD end
local function rrot(x, n) return u(bor(rshift(x, n), lshift(x, 32 - n))) end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function Pad(msg)
    local len = #msg
    local zeros = (64 - (len + 9) % 64) % 64
    local bits = len * 8
    local tail = {}
    for i = 7, 0, -1 do tail[#tail + 1] = char(floor(bits / 2 ^ (i * 8)) % 256) end
    return msg .. "\128" .. rep("\0", zeros) .. concat(tail)
end

local w = {}
local function Block(msg, i, H)
    for j = 1, 16 do
        local a, b, c, d = byte(msg, i, i + 3)
        w[j] = ((a * 256 + b) * 256 + c) * 256 + d
        i = i + 4
    end
    for j = 17, 64 do
        local v = w[j - 15]
        local s0 = u(bxor(bxor(rrot(v, 7), rrot(v, 18)), rshift(v, 3)))
        v = w[j - 2]
        local s1 = u(bxor(bxor(rrot(v, 17), rrot(v, 19)), rshift(v, 10)))
        w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % MOD
    end
    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for j = 1, 64 do
        local S1 = u(bxor(bxor(rrot(e, 6), rrot(e, 11)), rrot(e, 25)))
        local ch = u(bxor(band(e, f), band(bnot(e), g)))
        local t1 = (h + S1 + ch + K[j] + w[j]) % MOD
        local S0 = u(bxor(bxor(rrot(a, 2), rrot(a, 13)), rrot(a, 22)))
        local maj = u(bxor(bxor(band(a, b), band(a, c)), band(b, c)))
        local t2 = (S0 + maj) % MOD
        h, g, f, e, d, c, b, a = g, f, e, (d + t1) % MOD, c, b, a, (t1 + t2) % MOD
    end
    H[1], H[2], H[3], H[4] = (H[1] + a) % MOD, (H[2] + b) % MOD, (H[3] + c) % MOD, (H[4] + d) % MOD
    H[5], H[6], H[7], H[8] = (H[5] + e) % MOD, (H[6] + f) % MOD, (H[7] + g) % MOD, (H[8] + h) % MOD
end

--- SHA-256 of a string; returns the 32 raw bytes.
function ns.SHA256(msg)
    local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    msg = Pad(msg)
    for i = 1, #msg, 64 do Block(msg, i, H) end
    local out = {}
    for i = 1, 8 do
        local x = H[i]
        out[i] = char(floor(x / 16777216) % 256, floor(x / 65536) % 256, floor(x / 256) % 256, x % 256)
    end
    return concat(out)
end

--- HMAC-SHA256(key, msg); returns the 32 raw bytes.
function ns.HMAC_SHA256(key, msg)
    if #key > 64 then key = ns.SHA256(key) end
    key = key .. rep("\0", 64 - #key)
    local ipad, opad = {}, {}
    for i = 1, 64 do
        local k = byte(key, i)
        ipad[i] = char(u(bxor(k, 0x36)))
        opad[i] = char(u(bxor(k, 0x5c)))
    end
    return ns.SHA256(concat(opad) .. ns.SHA256(concat(ipad) .. msg))
end

function ns.ToHex(s)
    return (s:gsub(".", function(c) return format("%02x", byte(c)) end))
end

function ns.FromHex(h)
    return (h:gsub("%x%x", function(x) return char(tonumber(x, 16)) end))
end
