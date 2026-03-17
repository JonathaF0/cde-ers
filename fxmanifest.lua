fx_version 'cerulean'
game 'gta5'

author 'CDE Inc'
description 'ERS (Emergency Response Simulator) Bridge for CDECAD'
version '1.0.0'

-- Requires the night_ers resource to be running
-- dependency 'night_ers' -- Uncomment if you want to enforce ERS as a dependency

shared_scripts {
    'config.lua'
}

client_scripts {
    'client/*.lua'
}

server_scripts {
    'server/*.lua'
}
