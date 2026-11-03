-- MD5 (RFC 1321) in pure Lua 5.1 on top of the bit library Windower ships.
-- Only the raw 16-byte digest is needed by the search-server cipher framing.

local bit = require('bit')
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift = bit.lshift, bit.rshift

local function u32(x)
    return x % 4294967296
end

local function rol(x, n)
    return u32(bor(lshift(x, n), rshift(x, 32 - n)))
end

local function le32(x)
    x = u32(x)
    return string.char(x % 256, math.floor(x / 256) % 256, math.floor(x / 65536) % 256, math.floor(x / 16777216) % 256)
end

local K = {}
for i = 0, 63 do
    K[i] = math.floor(math.abs(math.sin(i + 1)) * 4294967296)
end

local S = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

local function digest(msg)
    local len = #msg
    local bits = len * 8
    local tail = {}
    for _ = 1, 8 do
        tail[#tail + 1] = string.char(bits % 256)
        bits = math.floor(bits / 256)
    end
    msg = msg .. '\128' .. string.rep('\0', (55 - len) % 64) .. table.concat(tail)

    local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
    local M = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local p = chunk + i * 4
            local b1, b2, b3, b4 = msg:byte(p, p + 3)
            M[i] = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        end
        local A, B, C, D = a0, b0, c0, d0
        for i = 0, 63 do
            local F, g
            if i < 16 then
                F = bor(band(B, C), band(bnot(B), D))
                g = i
            elseif i < 32 then
                F = bor(band(D, B), band(bnot(D), C))
                g = (5 * i + 1) % 16
            elseif i < 48 then
                F = bxor(B, C, D)
                g = (3 * i + 5) % 16
            else
                F = bxor(C, bor(B, bnot(D)))
                g = (7 * i) % 16
            end
            F = u32(u32(F) + A + K[i] + M[g])
            A, D, C = D, C, B
            B = u32(B + rol(F, S[i + 1]))
        end
        a0, b0, c0, d0 = u32(a0 + A), u32(b0 + B), u32(c0 + C), u32(d0 + D)
    end
    return le32(a0) .. le32(b0) .. le32(c0) .. le32(d0)
end

local function hex(s)
    return (s:gsub('.', function(c)
        return ('%02x'):format(c:byte())
    end))
end

return {
    digest = digest,
    hex = function(msg)
        return hex(digest(msg))
    end,
}
