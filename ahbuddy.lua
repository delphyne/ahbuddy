_addon.name = 'ahbuddy'
_addon.author = 'Mithrael@Quezacoatl'
_addon.version = '0.1.0'
_addon.command = 'ahbuddy'

require('logger')
local config = require('config')
local res = require('resources')
local socket = require('socket')
local ss = require('searchserver')

local defaults = {
    -- Search server to ask. Empty means pick it from the world you are logged
    -- into; otherwise an IP, or IP:port, to use instead.
    server = '',
    -- First address of the block of world search servers. Each world's server
    -- is this plus its position in `worlds`. Only this needs updating if
    -- Square Enix ever moves the block.
    base_ip = '124.150.154.61',
    -- Seconds to wait on each step of a query (connect, send, reply).
    timeout = 8,
    -- How many of the most recent sales to show for each form. The server
    -- sends at most ten.
    results = 3,
    -- Also print the fields of each reply that are not shown normally.
    debug = false,
}
local settings = config.load(defaults)

-- Worlds in the order their search servers sit in the address block.
local worlds = {
    'Bahamut', 'Shiva', 'Phoenix', 'Carbuncle', 'Fenrir', 'Sylph',
    'Valefor', 'Leviathan', 'Odin', 'Quetzalcoatl', 'Siren', 'Ragnarok',
    'Cerberus', 'Bismarck', 'Lakshmi', 'Asura',
}

-- AH category ids as the search server numbers them.
local categories = {
    [1] = 'Hand-to-Hand', [2] = 'Daggers', [3] = 'Swords', [4] = 'Great Swords', [5] = 'Axes',
    [6] = 'Great Axes', [7] = 'Scythes', [8] = 'Polearms', [9] = 'Katana', [10] = 'Great Katana',
    [11] = 'Clubs', [12] = 'Staves', [13] = 'Ranged', [14] = 'Instruments', [15] = 'Ammunition',
    [16] = 'Shields', [17] = 'Head', [18] = 'Body', [19] = 'Hands', [20] = 'Legs', [21] = 'Feet',
    [22] = 'Neck', [23] = 'Waist', [24] = 'Earrings', [25] = 'Rings', [26] = 'Back',
    [28] = 'White Magic', [29] = 'Black Magic', [30] = 'Summoning', [31] = 'Ninjutsu', [32] = 'Songs',
    [33] = 'Medicines', [34] = 'Furnishings', [35] = 'Crystals', [36] = 'Cards', [37] = 'Cursed Items',
    [38] = 'Smithing', [39] = 'Goldsmithing', [40] = 'Clothcraft', [41] = 'Leathercraft',
    [42] = 'Bonecraft', [43] = 'Woodworking', [44] = 'Alchemy', [45] = 'Geomancy', [46] = 'Misc.',
    [47] = 'Fishing Gear', [48] = 'Pet Items', [49] = 'Ninja Tools', [50] = 'Beast-made', [51] = 'Fish',
    [52] = 'Meat & Eggs', [53] = 'Seafood', [54] = 'Vegetables', [55] = 'Soups', [56] = 'Breads & Rice',
    [57] = 'Sweets', [58] = 'Drinks', [59] = 'Ingredients', [60] = 'Dice', [61] = 'Automaton',
    [62] = 'Grips', [63] = 'Alchemy 2', [64] = 'Misc. 2', [65] = 'Misc. 3',
}

math.randomseed(os.time())

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

local function say(line)
    windower.add_to_chat(207, '[ahbuddy] ' .. line)
end

local function gil(n)
    local s = tostring(n)
    repeat
        local count
        s, count = s:gsub('^(-?%d+)(%d%d%d)', '%1,%2')
    until count == 0
    return s
end

local function date(unix)
    return os.date('%Y-%m-%d', unix)
end

--------------------------------------------------------------------------------
-- Server selection
--------------------------------------------------------------------------------

local function world_name()
    local info = windower.ffxi.get_info()
    local server = info and info.server
    local entry = server and res.servers and res.servers[server]
    return entry and entry.en
end

local function bump_ip(ip, n)
    local a, b, c, d = ip:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
    if not a then
        return nil
    end
    d = tonumber(d) + n
    if d < 1 or d > 254 then
        return nil
    end
    return ('%s.%s.%s.%d'):format(a, b, c, d)
end

-- The address and port to query, plus a label for messages, or nil and why.
local function resolve_server()
    if settings.server ~= '' then
        local ip, port = settings.server:match('^([^:]+):?(%d*)$')
        if not ip then
            return nil, ('The server setting "%s" is not an address.'):format(settings.server)
        end
        return ip, tonumber(port) or ss.PORT, ip
    end
    local world = world_name()
    if not world then
        return nil, 'Not logged in, so the world is unknown. Set one with //ahbuddy server <ip>.'
    end
    for i, name in ipairs(worlds) do
        if name == world then
            local ip = bump_ip(settings.base_ip, i - 1)
            if not ip then
                return nil, ('base_ip "%s" is not a usable address.'):format(settings.base_ip)
            end
            return ip, ss.PORT, world
        end
    end
    return nil, ('No search server is known for %s. Set one with //ahbuddy server <ip>.'):format(world)
end

--------------------------------------------------------------------------------
-- Item lookup
--------------------------------------------------------------------------------

-- Items whose name matches the query: exact (short or long name,
-- case-insensitive) first; failing that, names containing the query.
local function find_items(query)
    query = query:lower()
    local exact, partial = {}, {}
    for _, item in pairs(res.items) do
        local en, enl = item.en, item.enl
        if en then
            local lo, lol = en:lower(), enl and enl:lower()
            if lo == query or lol == query then
                exact[#exact + 1] = item
            elseif lo:find(query, 1, true) or (lol and lol:find(query, 1, true)) then
                partial[#partial + 1] = item
            end
        end
    end
    local found = #exact > 0 and exact or partial
    table.sort(found, function(a, b)
        return a.id < b.id
    end)
    return found
end

--------------------------------------------------------------------------------
-- Non-blocking TCP, driven from a coroutine that is resumed every frame so
-- the game never waits on the network.
--------------------------------------------------------------------------------

local function deadline()
    return os.clock() + settings.timeout
end

local function expired(limit)
    return os.clock() > limit
end

-- Open a connection and wait for it to come up.
local function connect(ip, port)
    local sock = socket.tcp()
    sock:settimeout(0)
    local ok, err = sock:connect(ip, port)
    local limit = deadline()
    while not ok do
        if err ~= 'timeout' and err ~= 'Operation already in progress' then
            sock:close()
            return nil, 'connect failed: ' .. tostring(err)
        end
        if expired(limit) then
            sock:close()
            return nil, 'connect timed out'
        end
        coroutine.yield()
        local _, writable = socket.select(nil, {sock}, 0)
        if writable and writable[1] then
            -- Writable means the connect finished; getpeername tells how.
            if sock:getpeername() then
                ok = true
            else
                sock:close()
                return nil, 'connection refused'
            end
        else
            err = 'timeout'
        end
    end
    return sock
end

local function send_all(sock, data)
    local limit = deadline()
    local sent = 0
    while sent < #data do
        local n, err, partial = sock:send(data, sent + 1)
        if n then
            sent = n
        elseif err == 'timeout' then
            sent = partial or sent
            if expired(limit) then
                return nil, 'send timed out'
            end
            coroutine.yield()
        else
            return nil, 'send failed: ' .. tostring(err)
        end
    end
    return true
end

-- Read one reply: as many bytes as its own length field says.
local function receive_packet(sock)
    local limit = deadline()
    local data = ''
    while true do
        local want = ss.declared_length(data)
        if want and #data >= want then
            return data
        end
        local chunk, err, partial = sock:receive(want and (want - #data) or 2)
        if chunk then
            data = data .. chunk
        elseif err == 'timeout' then
            if partial and #partial > 0 then
                data = data .. partial
            elseif expired(limit) then
                return nil, ('reply timed out (%d bytes so far)'):format(#data)
            else
                coroutine.yield()
            end
        elseif err == 'closed' then
            if partial and #partial > 0 then
                data = data .. partial
            end
            local declared = ss.declared_length(data)
            if declared and #data >= declared then
                return data
            end
            return nil, ('connection closed after %d bytes'):format(#data)
        else
            return nil, 'receive failed: ' .. tostring(err)
        end
    end
end

-- One request, one reply, on a fresh connection.
local function exchange(ip, port, request)
    local sock, err = connect(ip, port)
    if not sock then
        return nil, err
    end
    local ok
    ok, err = send_all(sock, request)
    if not ok then
        sock:close()
        return nil, err
    end
    local reply
    reply, err = receive_packet(sock)
    sock:close()
    return reply, err
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

local function fetch_history(ip, port, item_id, stack)
    local reply, err = exchange(ip, port, ss.history_request(item_id, stack))
    if not reply then
        return nil, err
    end
    return ss.parse_history(reply)
end

-- Print one form's most recent sales, newest first, with their price range.
local function report_sales(label, history)
    local total = #history.sales
    if total == 0 then
        say(('  %s: no recent sales'):format(label))
        return
    end
    local first = math.max(1, total - settings.results + 1)
    local low, high = math.huge, 0
    for i = first, total do
        low = math.min(low, history.sales[i].price)
        high = math.max(high, history.sales[i].price)
    end
    say(('  %s: last %d sales, %s - %s gil'):format(label, total - first + 1, gil(low), gil(high)))
    for i = total, first, -1 do
        local sale = history.sales[i]
        say(('    %s  %10s  %s -> %s'):format(date(sale.date), gil(sale.price), sale.seller, sale.buyer))
    end
end

-- The whole lookup for one item, run inside the query coroutine. Each history
-- reply carries the number for sale in that form, so stock and sales come
-- from the same request.
local function lookup(item)
    local ip, port, label = resolve_server()
    if not ip then
        say(port)
        return
    end
    local stackable = (item.stack or 1) > 1
    say(('%s (%d) on %s...'):format(item.en, item.id, label))

    local single, err = fetch_history(ip, port, item.id, false)
    if not single then
        say(('Lookup failed: %s'):format(err))
        return
    end
    if not single.listed then
        say(('  The Auction House does not list %s.'):format(item.en))
        return
    end
    local stack
    if stackable then
        stack, err = fetch_history(ip, port, item.id, true)
        if not stack then
            say(('Stack lookup failed: %s'):format(err))
        end
    end

    local where = categories[single.category] and (' in %s'):format(categories[single.category]) or ''
    if stack then
        say(('  For sale%s: %d singles, %d stacks'):format(where, single.stock, stack.stock))
    else
        say(('  For sale%s: %d'):format(where, single.stock))
    end
    if settings.debug then
        say(('  (category %d)'):format(single.category))
    end
    report_sales('Singles', single)
    if stack then
        report_sales('Stacks', stack)
    end
end

--------------------------------------------------------------------------------
-- Coroutine driver
--------------------------------------------------------------------------------

local worker

local function step(...)
    local ok, err = coroutine.resume(worker, ...)
    if not ok then
        worker = nil
        error('Lookup error: ' .. tostring(err))
    elseif coroutine.status(worker) == 'dead' then
        worker = nil
    end
end

local function start(fn, ...)
    if worker then
        say('A lookup is already running.')
        return
    end
    worker = coroutine.create(fn)
    step(...)
end

windower.register_event('prerender', function()
    if worker then
        step()
    end
end)

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local help_text = [[
ahbuddy commands:
  //ahbuddy <item name>       Stock and recent sales for an item, from your
                              world's search server. Partial names work.
  //ahbuddy results [n]       Show or set how many sales to list per form (1-10).
  //ahbuddy server [ip|auto]  Show or set the search server to ask.
  //ahbuddy debug [on|off]    Show or set extra reply details.
  //ahbuddy help              Show this help.
]]

windower.register_event('addon command', function(...)
    local args = {...}
    local cmd = args[1] and args[1]:lower() or 'help'

    if cmd == 'help' then
        -- One add_to_chat per line; the chat log does not render embedded newlines.
        for line in help_text:gmatch('[^\n]+') do
            windower.add_to_chat(207, line)
        end
    elseif cmd == 'server' then
        local value = args[2]
        if value then
            settings.server = value:lower() == 'auto' and '' or value
            config.save(settings)
        end
        local ip, port, label = resolve_server()
        if ip then
            say(('Server: %s:%d (%s)'):format(ip, port, settings.server == '' and label or 'manual'))
        else
            say('Server: ' .. port)
        end
    elseif cmd == 'results' then
        local value = args[2]
        if value then
            local n = tonumber(value)
            if not n or n ~= math.floor(n) or n < 1 or n > 10 then
                error('results expects a whole number from 1 to 10.')
                return
            end
            settings.results = n
            config.save(settings)
        end
        say(('Results: %d per form'):format(settings.results))
    elseif cmd == 'debug' then
        local value = args[2] and args[2]:lower()
        if value == 'on' or value == 'off' then
            settings.debug = value == 'on'
            config.save(settings)
        elseif value then
            error('debug expects on or off.')
            return
        end
        say('Debug: ' .. (settings.debug and 'on' or 'off'))
    else
        local query = table.concat(args, ' ')
        local found = find_items(query)
        if #found == 0 then
            say(('No item matches "%s".'):format(query))
        elseif #found == 1 then
            start(lookup, found[1])
        else
            say(('%d items match "%s"; be more specific:'):format(#found, query))
            for i = 1, math.min(#found, 10) do
                say(('  %s (%d)'):format(found[i].en, found[i].id))
            end
            if #found > 10 then
                say('  ...')
            end
        end
    end
end)

windower.register_event('unload', function()
    worker = nil
end)
