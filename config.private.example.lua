-- PRIVATE BC-BANKING DISCORD WEBHOOK CONFIG
-- Copy this file to config.private.lua and add your own webhook URLs.
-- Never commit config.private.lua or share it publicly.

Config.DiscordWebhooks = {
    -- Optional: receives every banking transaction.
    general = '',

    -- Optional: separate destinations by transaction category.
    deposits = '',
    withdrawals = '',
    transfers = '',
    fees = '',
    other = ''
}
