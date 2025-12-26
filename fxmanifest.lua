fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'dps-vehiclepersistence'
author 'DPSRP'
description 'Realistic vehicle world persistence - vehicles stay where parked'
version '1.1.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server.lua'
}

client_scripts {
    'client.lua'
}

dependencies {
    'ox_lib',
    'oxmysql',
    'qb-core'
}
