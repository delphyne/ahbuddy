-- Wire protocol of the FFXI search server (TCP port 54002), as far as the
-- Auction House needs it: build the encrypted requests the client sends for an
-- item's sale history and for a category's stock listing, and decrypt and
-- parse the replies.
--
-- Framing (all little-endian):
--   0x00  u16  packet length
--   0x04  u32  'IXFF' magic
--   0x08  u16  end of payload (offset of the first byte past the records)
--   0x0A  u8   0x80 flag (last page)
--   0x0B  u8   request/reply type
--   ...        type-specific body
--   len-0x18   4 bytes  key2 (zero; folded into the reply cipher key)
--   len-0x14   16 bytes MD5 of bytes [0x08, len-0x14)
--   len-0x04   4 bytes  key tail (random per request; folded into both keys)
--
-- Everything from 0x08 up to the last whole pair of words is Blowfish'd with a
-- client-specific F-function. The request key is md5(SEED .. tail); the reply
-- key is md5(SEED .. tail .. key2), where tail is read back from the reply.
--
-- Layouts were taken from LandSandBoat's search server (which mirrors retail)
-- and from OmniWatch's live captures of the retail client.

local bit = require('bit')
local band, bor, bxor = bit.band, bit.bor, bit.bxor
local lshift, rshift = bit.lshift, bit.rshift

local md5 = require('md5')
local table_hex = require('cipher_table')

local M = {}

M.PORT = 54002

local MAGIC = 0x46465849 -- 'IXFF'
local SEED = string.char(0x30, 0x73, 0x3D, 0x6D, 0x3C, 0x31, 0x49, 0x5A,
                         0x32, 0x7A, 0x42, 0x43, 0x63, 0x38, 0x7B, 0x7E)

M.TYPE_HISTORY_SINGLE = 0x05
M.TYPE_HISTORY_STACK = 0x06
M.TYPE_LIST_MORE = 0x10
M.TYPE_LIST = 0x15
M.REPLY_LIST = 0x95

-- A listing count of this value means "not sold in that form".
M.NONE = 0xFFFFFFFF

--------------------------------------------------------------------------------
-- Byte buffers: 0-based offsets over a 1-based table of byte values.
--------------------------------------------------------------------------------

local function u32(x)
    return x % 4294967296
end

local function new_buffer(length)
    local buf = {}
    for i = 1, length do
        buf[i] = 0
    end
    return buf
end

local function put8(buf, o, v)
    buf[o + 1] = v % 256
end

local function put16(buf, o, v)
    buf[o + 1] = v % 256
    buf[o + 2] = math.floor(v / 256) % 256
end

local function put32(buf, o, v)
    v = u32(v)
    buf[o + 1] = v % 256
    buf[o + 2] = math.floor(v / 256) % 256
    buf[o + 3] = math.floor(v / 65536) % 256
    buf[o + 4] = math.floor(v / 16777216) % 256
end

local function put_bytes(buf, o, s)
    for i = 1, #s do
        buf[o + i] = s:byte(i)
    end
end

local function get8(buf, o)
    return buf[o + 1]
end

local function get16(buf, o)
    return buf[o + 1] + buf[o + 2] * 256
end

local function get32(buf, o)
    return buf[o + 1] + buf[o + 2] * 256 + buf[o + 3] * 65536 + buf[o + 4] * 16777216
end

local function get_bytes(buf, o, n)
    local parts = {}
    for i = 1, n do
        parts[i] = string.char(buf[o + i])
    end
    return table.concat(parts)
end

local function to_string(buf)
    local parts = {}
    for i = 1, #buf, 4096 do
        parts[#parts + 1] = string.char(unpack(buf, i, math.min(i + 4095, #buf)))
    end
    return table.concat(parts)
end

local function from_string(s)
    local buf = {}
    for i = 1, #s do
        buf[i] = s:byte(i)
    end
    return buf
end

--------------------------------------------------------------------------------
-- Blowfish with the client's F-function
--------------------------------------------------------------------------------

-- Initial P-array (18 words) and S-boxes (1024 words), decoded once.
local P0, S0 = {}, {}
do
    local words = {}
    for i = 0, 4167, 4 do
        local hex = table_hex:sub(i * 2 + 1, i * 2 + 8)
        local b1, b2, b3, b4 = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16),
                               tonumber(hex:sub(5, 6), 16), tonumber(hex:sub(7, 8), 16)
        words[#words + 1] = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end
    for i = 0, 17 do
        P0[i] = words[i + 1]
    end
    for i = 0, 1023 do
        S0[i] = words[i + 19]
    end
end

local function F(x, S)
    return u32(bxor(band(S[256 + band(rshift(x, 8), 0xFF)], 1), 32)
             + bxor(band(S[768 + band(rshift(x, 24), 0xFF)], 1), 32)
             + S[512 + band(rshift(x, 16), 0xFF)]
             + S[band(x, 0xFF)])
end

local function encipher(xl, xr, P, S)
    for i = 0, 15 do
        xl = u32(bxor(xl, P[i]))
        xr = u32(bxor(F(xl, S), xr))
        xl, xr = xr, xl
    end
    xl, xr = xr, xl
    xr = u32(bxor(xr, P[16]))
    xl = u32(bxor(xl, P[17]))
    return xl, xr
end

local function decipher(xl, xr, P, S)
    for i = 17, 2, -1 do
        xl = u32(bxor(xl, P[i]))
        xr = u32(bxor(F(xl, S), xr))
        xl, xr = xr, xl
    end
    xl, xr = xr, xl
    xr = u32(bxor(xr, P[1]))
    xl = u32(bxor(xl, P[0]))
    return xl, xr
end

-- Expand a key (the 16-byte MD5 digest) into a fresh P-array and S-boxes.
-- The server folds the key as signed bytes, so values >= 0x80 sign-extend.
local function init(key)
    local P, S = {}, {}
    for i = 0, 17 do
        P[i] = P0[i]
    end
    for i = 0, 1023 do
        S[i] = S0[i]
    end
    local n = #key
    local j = 1
    for i = 0, 17 do
        local data = 0
        for _ = 1, 4 do
            local b = key:byte(j)
            if b >= 128 then
                b = 0xFFFFFF00 + b
            end
            data = u32(bor(lshift(data, 8), b))
            j = j + 1
            if j > n then
                j = 1
            end
        end
        P[i] = u32(bxor(P[i], data))
    end
    local dl, dr = 0, 0
    for i = 0, 16, 2 do
        dl, dr = encipher(dl, dr, P, S)
        P[i], P[i + 1] = dl, dr
    end
    for box = 0, 3 do
        for k = 0, 254, 2 do
            dl, dr = encipher(dl, dr, P, S)
            S[box * 256 + k], S[box * 256 + k + 1] = dl, dr
        end
    end
    return P, S
end

-- Run the cipher over the packet body in place: whole pairs of words from
-- offset 8, leaving the 12-byte header untouched.
local function cipher_blocks(buf, length, P, S, decrypt)
    local words = math.floor((length - 12) / 4)
    words = words - words % 2
    local fn = decrypt and decipher or encipher
    for i = 0, words - 1, 2 do
        local o = 8 + i * 4
        local xl, xr = fn(get32(buf, o), get32(buf, o + 4), P, S)
        put32(buf, o, xl)
        put32(buf, o + 4, xr)
    end
end

--------------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------------

local KEY2 = string.char(0, 0, 0, 0)

local function random_tail()
    return string.char(math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255))
end

-- Seal a request buffer: key2, MD5 trailer, random tail, then encrypt.
local function seal(buf)
    local length = #buf
    local tail = random_tail()
    put_bytes(buf, length - 0x18, KEY2)
    put_bytes(buf, length - 0x14, md5.digest(get_bytes(buf, 0x08, length - 0x14 - 0x08)))
    put_bytes(buf, length - 0x04, tail)
    local P, S = init(md5.digest(SEED .. tail))
    cipher_blocks(buf, length, P, S, false)
    return to_string(buf)
end

local function header(buf, payload_end, kind)
    put16(buf, 0x00, #buf)
    put32(buf, 0x04, MAGIC)
    put16(buf, 0x08, payload_end)
    put8(buf, 0x0A, 0x80)
    put8(buf, 0x0B, kind)
end

-- Sale history of one item, singles or stacks. 268 bytes.
function M.history_request(item_id, stack)
    local buf = new_buffer(268)
    header(buf, 184, stack and M.TYPE_HISTORY_STACK or M.TYPE_HISTORY_SINGLE)
    put16(buf, 0x12, item_id)
    put8(buf, 0x14, 0x04)
    put8(buf, 0x15, stack and 1 or 0)
    return seal(buf)
end

-- Stock listing of one AH category: every item in it with its single and
-- stack counts, 20 items per reply. 268 bytes. Sorted by level, ascending.
function M.list_request(category)
    local buf = new_buffer(268)
    header(buf, 184, M.TYPE_LIST)
    put16(buf, 0x0E, 1)
    put8(buf, 0x12, 1)     -- parameter count
    put16(buf, 0x14, 4)
    put8(buf, 0x16, category)
    put32(buf, 0x18, 2)    -- parameter: sort by level
    put32(buf, 0x1C, 2)    -- parameter bits: descending flag only
    return seal(buf)
end

-- Next page of the listing opened on this connection. 76 bytes.
function M.more_request()
    local buf = new_buffer(76)
    header(buf, 16, M.TYPE_LIST_MORE)
    put16(buf, 0x10, 3)
    put16(buf, 0x12, 1)
    return seal(buf)
end

--------------------------------------------------------------------------------
-- Replies
--------------------------------------------------------------------------------

-- Length the server declared for a reply, from its first two bytes, or nil
-- while fewer than two bytes are in.
function M.declared_length(data)
    if #data < 2 then
        return nil
    end
    return data:byte(1) + data:byte(2) * 256
end

-- Decrypt a reply and check its MD5 trailer. Returns the byte buffer and its
-- length, or nil and a reason.
local function open(data)
    if #data < 28 then
        return nil, ('reply too short (%d bytes)'):format(#data)
    end
    local buf = from_string(data)
    local length = get16(buf, 0x00)
    if length < 28 or length > #buf then
        return nil, ('bad reply length %d (have %d bytes)'):format(length, #buf)
    end
    local tail = get_bytes(buf, length - 0x04, 4)
    local P, S = init(md5.digest(SEED .. tail .. KEY2))
    cipher_blocks(buf, length, P, S, true)
    local expected = get_bytes(buf, length - 0x14, 16)
    if md5.digest(get_bytes(buf, 0x08, length - 0x14 - 0x08)) ~= expected then
        return nil, 'reply failed its hash check'
    end
    return buf, length
end

local function name_at(buf, o, n)
    local s = get_bytes(buf, o, n)
    local z = s:find('\0', 1, true)
    if z then
        s = s:sub(1, z - 1)
    end
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Parse a history reply. Returns a table:
--   listed (bool: the AH sells this item at all; the rest is only meaningful
--   when true), item_id, stack (bool), stock (how many are for sale in that
--   form), category, sales = { {price, date (unix), seller, buyer}, ... }
--   oldest first
-- or nil and a reason.
function M.parse_history(data)
    local buf, length = open(data)
    if not buf then
        return nil, length
    end
    local kind = band(get8(buf, 0x0B), 0x1F)
    if kind ~= M.TYPE_HISTORY_SINGLE and kind ~= M.TYPE_HISTORY_STACK then
        return nil, ('unexpected reply type 0x%02X'):format(get8(buf, 0x0B))
    end
    local result = {
        stack = kind == M.TYPE_HISTORY_STACK,
        sales = {},
    }
    -- An item the AH does not sell gets a reply with no item header at all:
    -- the payload ends where the header would begin.
    local payload_end = get16(buf, 0x08)
    if payload_end < 0x20 then
        result.listed = false
        return result
    end
    result.listed = true
    result.item_id = get16(buf, 0x18)
    result.stock = get32(buf, 0x1A)
    result.category = get16(buf, 0x1E)
    local count = math.floor((payload_end - 0x20) / 40)
    for i = 0, count - 1 do
        local o = 0x20 + 40 * i
        if o + 40 > length - 0x14 then
            break
        end
        result.sales[#result.sales + 1] = {
            price = get32(buf, o),
            date = get32(buf, o + 0x04),
            seller = name_at(buf, o + 0x08, 16),
            buyer = name_at(buf, o + 0x18, 16),
        }
    end
    return result
end

-- Parse one page of a listing reply. Returns a table:
--   total (items in the category), last (bool, no more pages),
--   items = { [item_id] = {single = n, stack = n} } with M.NONE for a form
--   the item is never sold in
-- or nil and a reason.
function M.parse_list(data)
    local buf, length = open(data)
    if not buf then
        return nil, length
    end
    if get8(buf, 0x0B) ~= M.REPLY_LIST then
        return nil, ('unexpected reply type 0x%02X'):format(get8(buf, 0x0B))
    end
    local result = {
        total = get16(buf, 0x0E),
        last = get8(buf, 0x0A) == 0x80,
        items = {},
    }
    local payload_end = get16(buf, 0x08)
    local count = math.max(0, math.floor((payload_end - 0x18) / 10))
    for i = 0, count - 1 do
        local o = 0x18 + 10 * i
        if o + 10 > length then
            break
        end
        result.items[get16(buf, o)] = {
            single = get32(buf, o + 2),
            stack = get32(buf, o + 6),
        }
    end
    return result
end

-- Decrypted bytes of a reply, for debugging. Returns the string, or nil and
-- a reason.
function M.decrypt(data)
    local buf, length = open(data)
    if not buf then
        return nil, length
    end
    return to_string(buf)
end

return M
