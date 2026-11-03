_addon.name = 'ahbuddy'
_addon.author = 'Mithrael@Quezacoatl'
_addon.version = '0.0.1'
_addon.command = 'ahbuddy'

require('logger')
local config = require('config')
local packets = require('packets')
local res = require('resources')

local defaults = {
}
local settings = config.load(defaults)

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local help_text = [[
ahbuddy commands:
  //ahbuddy help    Show this help.
]]

windower.register_event('addon command', function(...)
    local args = {...}
    local cmd = args[1] and args[1]:lower() or 'help'

    if cmd == 'help' then
        -- One add_to_chat per line; the chat log does not render embedded newlines.
        for line in help_text:gmatch('[^\n]+') do
            windower.add_to_chat(207, line)
        end
    else
        error('Unknown command: %s':format(cmd))
    end
end)

windower.register_event('load', function()
    log('Loaded.')
end)

windower.register_event('unload', function()
end)
