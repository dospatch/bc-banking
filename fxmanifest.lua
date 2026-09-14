fx_version 'cerulean'
game 'gta5'

lua54 'yes'

author 'BCGAMING'
description 'BC-Banking - QBCore + oxmysql + ox_target'
version '1.0.0'

shared_scripts {
    'config.lua',
    'shared/utils.lua'
}

client_scripts {
    'client/main.lua',
    'client/banking.lua',
    'client/atm.lua',
    'client/nui.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/accounts.lua',
    'server/transactions.lua',
    'server/transfers.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/style.css',
    'html/js/app.js'
}

dependencies {
    'qb-core',
    'oxmysql',
    'ox_target'
}
