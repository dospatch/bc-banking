fx_version 'cerulean'
game 'gta5'

author 'BCGAMING'
description 'BC-Banking - QBCore Banking System'
version '1.0.0'

lua54 'yes'

dependency 'qb-core'
dependency 'oxmysql'

shared_scripts {
    'config.lua',
    'shared/utils.lua'
}

client_scripts {
    'client/main.lua',
    'client/commands.lua',
    'client/atm.lua',
    'client/banking.lua',
    'client/nui.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/accounts.lua',
    'server/transactions.lua',
    'server/players.lua',
    'server/transfers.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/style.css',
    'html/js/app.js',
    'html/assets/*'
}
