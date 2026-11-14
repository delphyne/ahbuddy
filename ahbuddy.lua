_addon.name = 'ahbuddy'
_addon.author = 'Mithrael@Quezacoatl'
_addon.version = '0.1.0'
_addon.commands = {'ahbuddy', 'ah'}

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
    -- Rows the game's AH list shows per page, used to say which page an item
    -- is on. 0 skips the page lookup, which costs one more query.
    page_size = 7,
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

-- The top-level AH menu each category sits under.
local groups = {}
for group, members in pairs({
    Weapons = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 62},
    Armor = {16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26},
    Scrolls = {28, 29, 30, 31, 32, 45},
    Medicines = {33},
    Items = {34, 35, 36, 37, 60, 61, 48, 49, 46, 64, 65},
    Materials = {38, 39, 40, 41, 42, 43, 44, 63, 47, 50},
    Food = {51, 52, 53, 54, 55, 56, 57, 58, 59},
}) do
    for _, category in ipairs(members) do
        groups[category] = group
    end
end

-- "Items > Crystals", or just the number when the category is unknown.
local function category_path(category)
    local name = categories[category]
    if not name then
        return ('category %d'):format(category)
    end
    return groups[category] and (groups[category] .. ' > ' .. name) or name
end

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

-- The game marks items the Auction House refuses with this bit in the item
-- flags that Windower's item table carries. Many fish and some other items
-- exist twice under one name, one form sellable and one not (quest or
-- fishing-contest versions); this bit tells them apart.
local NO_AUCTION = 0x0040

local function sellable(item)
    return math.floor((item.flags or 0) / NO_AUCTION) % 2 == 0
end

-- Items whose name matches the query: exact (short or long name,
-- case-insensitive) first; failing that, names containing the query. Items
-- the Auction House refuses are dropped when at least one match is sellable,
-- so a name shared by a sellable and an unsellable form is not ambiguous. A
-- query that is only digits is an item id, which picks out one item exactly;
-- the ambiguity list prints each item's id for this.
local function find_items(query)
    query = query:lower()
    if query:match('^%d+$') then
        local item = res.items[tonumber(query)]
        return item and item.en and {item} or {}
    end
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
    local listed = {}
    for _, item in ipairs(found) do
        if sellable(item) then
            listed[#listed + 1] = item
        end
    end
    if #listed > 0 then
        found = listed
    end
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

-- Every item in a category in the order the game's AH list shows them,
-- paging through the listing on a single connection. Returns the array of
-- item ids, or nil and a reason.
local function fetch_listing(ip, port, category)
    local sock, err = connect(ip, port)
    if not sock then
        return nil, err
    end
    local order = {}
    local request = ss.list_request(category)
    for _ = 1, 80 do
        local ok
        ok, err = send_all(sock, request)
        if not ok then
            sock:close()
            return nil, err
        end
        local reply
        reply, err = receive_packet(sock)
        if not reply then
            sock:close()
            return nil, err
        end
        local page
        page, err = ss.parse_list(reply)
        if not page then
            sock:close()
            return nil, err
        end
        for _, id in ipairs(page.order) do
            order[#order + 1] = id
        end
        if page.last or #page.order == 0 then
            break
        end
        request = ss.more_request()
    end
    sock:close()
    return order
end

-- Say where in the game's AH list an item sits: its category's menu path and
-- the page it is on.
local function report_page(ip, port, item, category)
    local order, err = fetch_listing(ip, port, category)
    if not order then
        say(('  Page lookup failed: %s'):format(err))
        return
    end
    for position, id in ipairs(order) do
        if id == item.id then
            local pages = math.ceil(#order / settings.page_size)
            local page = math.ceil(position / settings.page_size)
            say(('  Listed under %s, page %d of %d (item %d of %d)'):format(
                category_path(category), page, pages, position, #order))
            return
        end
    end
    say(('  Not found in the %s listing (%d items).'):format(category_path(category), #order))
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

    if stack then
        say(('  For sale: %d singles, %d stacks'):format(single.stock, stack.stock))
    else
        say(('  For sale: %d'):format(single.stock))
    end
    if settings.page_size > 0 then
        report_page(ip, port, item, single.category)
    else
        say(('  Listed under %s'):format(category_path(single.category)))
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
  //ahbuddy <item name|id>    Stock and recent sales for an item, from your
                              world's search server. Partial names work; an
                              item id picks one of several with the same name.
  //ahbuddy results [n]       Show or set how many sales to list per form (1-10).
  //ahbuddy pagesize [n]      Show or set rows per page of the game's AH list,
                              for the page report; 0 turns the report off.
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
    elseif cmd == 'pagesize' then
        local value = args[2]
        if value then
            local n = tonumber(value)
            if not n or n ~= math.floor(n) or n < 0 or n > 50 then
                error('pagesize expects a whole number from 0 to 50.')
                return
            end
            settings.page_size = n
            config.save(settings)
        end
        if settings.page_size > 0 then
            say(('Page size: %d rows'):format(settings.page_size))
        else
            say('Page size: 0 (page report off)')
        end
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
            say(('%d items match "%s"; be more specific, or use the id:'):format(#found, query))
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
