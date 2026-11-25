-- Pure-Lua `bit` for tests (plain Lua 5.1 has none). SIGNED_BIT = true mimics
-- LuaBitOp's signed results; WoW's own library returns unsigned numbers.
local MOD = 4294967296
local function norm(x) return x % MOD end
local function out(x) if SIGNED_BIT and x >= 2147483648 then return x - MOD end return x end
local function op(a, b, f)
    a, b = norm(a), norm(b)
    local r, p = 0, 1
    for _ = 1, 32 do
        local x, y = a % 2, b % 2
        if f(x, y) then r = r + p end
        a, b, p = (a - x) / 2, (b - y) / 2, p * 2
    end
    return out(r)
end
bit = {
    band = function(a, b) return op(a, b, function(x, y) return x == 1 and y == 1 end) end,
    bor = function(a, b) return op(a, b, function(x, y) return x == 1 or y == 1 end) end,
    bxor = function(a, b) return op(a, b, function(x, y) return x ~= y end) end,
    bnot = function(a) return out(MOD - 1 - norm(a)) end,
    rshift = function(a, n) return out(math.floor(norm(a) / 2 ^ n)) end,
    lshift = function(a, n) return out((norm(a) * 2 ^ n) % MOD) end,
}
