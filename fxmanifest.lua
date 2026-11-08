fx_version 'cerulean'
game 'gta5'

author 'BCGAMING'
description 'BC-Banking - Custom QBCore Banking System'
version '2.0.0-dev'

lua54 'yes'

dependencies {
    'qb-core',
    'oxmysql',
    'ox_target'
}

shared_scripts {
    'config.lua',
    'shared/utils.lua'
}

client_scripts {
    'client/main.lua',
    'client/commands.lua',
    'client/targets.lua',
    'client/banking.lua',
    'client/nui.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/discord.lua',
    'server/migrations.lua',
    'server/v2.lua',
    'server/locks.lua',
    'server/accounts.lua',
    'server/transactions.lua',
    'server/players.lua',
    'server/transfers.lua',
    'server/banking.lua',
    'server/v2_accounts.lua',
    'server/v2_savings.lua',
    'server/v2_cards.lua',
    'server/v2_business.lua',
    'server/v2_loans.lua',
    'server/v2_scheduled.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/style.css',
    'html/js/app.js',
    'html/assets/*'
}
