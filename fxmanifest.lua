fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'dps-vehiclepersistence'
author 'DPSRP'
description 'Realistic vehicle world persistence - vehicles stay where parked'
version '2.0.0'
repository 'https://github.com/DaemonAlex/dps-vehiclepersistence'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'bridge/init.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/server.lua',
    'server.lua'
}

client_scripts {
    'bridge/client.lua',
    'client.lua'
}

dependencies {
    'ox_lib',
    'oxmysql'
}

-- Optional dependencies (auto-detected)
-- qb-core, qbx_core, or es_extended

provides {
    'dps-vehiclepersistence'
}
