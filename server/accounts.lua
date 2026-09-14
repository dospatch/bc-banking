local QBCore = exports['qb-core']:GetCoreObject()

local function generateAccountNumber()
    local accountNumber

    repeat
        accountNumber = ''

        for _ = 1, Config.AccountNumberLength do
            accountNumber = accountNumber .. tostring(math.random(0, 9))
        end

        local exists = MySQL.scalar.await(
            'SELECT COUNT(*) FROM bc_banking_accounts WHERE account_number = ?',
            { accountNumber }
        )
    until exists == 0

    return accountNumber
end

exports('GetAccountByCitizenId', function(citizenid)
    return MySQL.single.await(
        'SELECT * FROM bc_banking_accounts WHERE citizenid = ? LIMIT 1',
        { citizenid }
    )
end)

exports('GetAccountByNumber', function(accountNumber)
    return MySQL.single.await(
        'SELECT * FROM bc_banking_accounts WHERE account_number = ? LIMIT 1',
        { accountNumber }
    )
end)

exports('CreateAccount', function(Player)
    if not Player then
        return false
    end

    local citizenid = Player.PlayerData.citizenid

    local existing = MySQL.single.await(
        'SELECT * FROM bc_banking_accounts WHERE citizenid = ? LIMIT 1',
        { citizenid }
    )

    if existing then
        return existing
    end

    local accountNumber = generateAccountNumber()

    MySQL.insert.await(
        [[
            INSERT INTO bc_banking_accounts
            (citizenid, account_number, account_type, balance)
            VALUES (?, ?, ?, ?)
        ]],
        {
            citizenid,
            accountNumber,
            'checking',
            Config.StartingBankBalance
        }
    )

    return MySQL.single.await(
        'SELECT * FROM bc_banking_accounts WHERE citizenid = ? LIMIT 1',
        { citizenid }
    )
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if Player then
        exports['bc-banking']:CreateAccount(Player)
    end
end)
