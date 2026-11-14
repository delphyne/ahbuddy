-- Tests for ahbuddy's command handling, run outside the game:
--   luajit test/test_ahbuddy.lua        (from the addon directory)
-- Windower's globals and libs are stubbed; the search server module is real
-- but the network is stubbed so every connection is refused at once.

package.path = './?.lua;' .. package.path

local chat = {}
local handlers = {}
local info = nil

_addon = {}
windower = {
    add_to_chat = function(_, line) chat[#chat + 1] = line end,
    register_event = function(name, fn) handlers[name] = fn end,
    ffxi = {get_info = function() return info end},
}

package.preload['logger'] = function() end
package.preload['config'] = function()
    return {
        load = function(defaults)
            local t = {}
            for k, v in pairs(defaults) do t[k] = v end
            return t
        end,
        save = function() end,
    }
end
package.preload['resources'] = function()
    return {
        items = {
            [4096] = {id = 4096, en = 'Fire Crystal', enl = 'fire crystals', stack = 12},
            [4429] = {id = 4429, en = 'Black Eel', enl = 'black eels', stack = 12},
            [5788] = {id = 5788, en = 'Black Eel', enl = 'black eel', stack = 1},
            [4484] = {id = 4484, en = 'Eel Kabob', enl = 'eel kabobs', stack = 12},
            -- Giant Catfish as the real table has it: the second form carries
            -- the No Auction flag (0x0040).
            [4469] = {id = 4469, en = 'Giant Catfish', enl = 'giant catfish', flags = 1544, stack = 1},
            [5799] = {id = 5799, en = 'Giant Catfish', enl = 'giant catfish', flags = 13896, stack = 1},
            -- Both forms unsellable.
            [7001] = {id = 7001, en = 'Contest Trout', enl = 'contest trout', flags = 13896, stack = 1},
            [7002] = {id = 7002, en = 'Contest Trout', enl = 'contest trout', flags = 13896, stack = 1},
            [9999] = {id = 9999},  -- an entry with no name, as the real table has
        },
        servers = {[1] = {en = 'Quezacoatl'}},
    }
end
package.preload['socket'] = function()
    return {
        tcp = function()
            return {
                settimeout = function() end,
                connect = function() return nil, 'refused' end,
                close = function() end,
            }
        end,
        select = function() return {}, {} end,
    }
end

dofile('ahbuddy.lua')
local command = assert(handlers['addon command'], 'no addon command handler')
local prerender = assert(handlers['prerender'], 'no prerender handler')

local failures = 0

local function run(...)
    chat = {}
    command(...)
    for _ = 1, 50 do prerender() end
    return chat
end

local function check(name, lines, ...)
    local want = {...}
    local ok = #lines == #want
    for i = 1, #want do
        if lines[i] ~= want[i] then ok = false end
    end
    if ok then
        print('ok   ' .. name)
    else
        failures = failures + 1
        print('FAIL ' .. name)
        print('  wanted:')
        for _, l in ipairs(want) do print('    ' .. l) end
        print('  got:')
        for _, l in ipairs(lines) do print('    ' .. l) end
    end
end

-- Point at a fixed server so lookups get past world detection.
run('server', '127.0.0.1')

check('unknown name', run('nothing'),
    '[ahbuddy] No item matches "nothing".')

check('unique exact name starts a lookup', run('fire', 'crystal'),
    '[ahbuddy] Fire Crystal (4096) on 127.0.0.1...',
    '[ahbuddy] Lookup failed: connect failed: refused')

check('unique partial name starts a lookup', run('kabob'),
    '[ahbuddy] Eel Kabob (4484) on 127.0.0.1...',
    '[ahbuddy] Lookup failed: connect failed: refused')

check('ambiguous name lists ids', run('black', 'eel'),
    '[ahbuddy] 2 items match "black eel"; be more specific, or use the id:',
    '[ahbuddy]   Black Eel (4429)',
    '[ahbuddy]   Black Eel (5788)')

check('ambiguous partial name lists ids', run('eel'),
    '[ahbuddy] 3 items match "eel"; be more specific, or use the id:',
    '[ahbuddy]   Black Eel (4429)',
    '[ahbuddy]   Eel Kabob (4484)',
    '[ahbuddy]   Black Eel (5788)')

check('unsellable twin is skipped', run('giant', 'catfish'),
    '[ahbuddy] Giant Catfish (4469) on 127.0.0.1...',
    '[ahbuddy] Lookup failed: connect failed: refused')

check('partial match skips the unsellable twin', run('catfish'),
    '[ahbuddy] Giant Catfish (4469) on 127.0.0.1...',
    '[ahbuddy] Lookup failed: connect failed: refused')

check('id still reaches the unsellable twin', run('5799'),
    '[ahbuddy] Giant Catfish (5799) on 127.0.0.1...',
    '[ahbuddy] Lookup failed: connect failed: refused')

check('all unsellable stays ambiguous', run('contest', 'trout'),
    '[ahbuddy] 2 items match "contest trout"; be more specific, or use the id:',
    '[ahbuddy]   Contest Trout (7001)',
    '[ahbuddy]   Contest Trout (7002)')

check('id picks the first Black Eel', run('4429'),
    '[ahbuddy] Black Eel (4429) on 127.0.0.1...',
    '[ahbuddy] Lookup failed: connect failed: refused')

check('id picks the second Black Eel', run('5788'),
    '[ahbuddy] Black Eel (5788) on 127.0.0.1...',
    '[ahbuddy] Lookup failed: connect failed: refused')

check('unknown id', run('123456'),
    '[ahbuddy] No item matches "123456".')

check('id of a nameless entry', run('9999'),
    '[ahbuddy] No item matches "9999".')

-- Without a server setting and not logged in, the world cannot be found.
run('server', 'auto')
check('not logged in', run('4429'),
    '[ahbuddy] Not logged in, so the world is unknown. Set one with //ahbuddy server <ip>.')

if failures > 0 then
    print(failures .. ' failure(s)')
    os.exit(1)
end
print('all tests passed')
