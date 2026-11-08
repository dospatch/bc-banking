local QBCore = exports['qb-core']:GetCoreObject()

local function generateAccountNumber()
    local length = math.max(6, math.min(20, math.floor(tonumber(Config.AccountNumberLength) or 10)))
    local accountNumber

    repeat
        accountNumber = ''
        for _ = 1, length do
            accountNumber = accountNumber .. tostring(math.random(0, 9))
        end

        local exists = MySQL.scalar.await(
            'SELECT COUNT(*) FROM bc_banking_accounts WHERE account_number = ?',
            { accountNumber }
        )
    until tonumber(exists) == 0

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
    if not Player or not Player.PlayerData or not Player.PlayerData.citizenid then
        return false
    end

    local citizenid = Player.PlayerData.citizenid
    local currentBank = tonumber(Player.PlayerData.money and Player.PlayerData.money.bank) or 0

    local existing = MySQL.single.await(
        'SELECT * FROM bc_banking_accounts WHERE citizenid = ? LIMIT 1',
        { citizenid }
    )

    if existing then
        MySQL.update.await(
            'UPDATE bc_banking_accounts SET balance = ? WHERE citizenid = ?',
            { BCBanking.RoundMoney(currentBank), citizenid }
        )
        existing.balance = currentBank
        return existing
    end

    -- The unique citizen ID and account number indexes are the final authority.
    -- Re-read after a failed insert so concurrent PlayerLoaded/dashboard requests
    -- converge on the same account instead of failing the resource callback.
    for attempt = 1, 10 do
        local accountNumber = generateAccountNumber()
        local inserted, insertResult = pcall(function()
            return MySQL.insert.await(
                [[
                    INSERT INTO bc_banking_accounts
                    (citizenid, account_number, account_type, balance)
                    VALUES (?, ?, ?, ?)
                ]],
                {
                    citizenid,
                    accountNumber,
                    'checking',
                    BCBanking.RoundMoney(currentBank)
                }
            )
        end)

        if inserted and insertResult then
            return MySQL.single.await(
                'SELECT * FROM bc_banking_accounts WHERE citizenid = ? LIMIT 1',
                { citizenid }
            )
        end

        existing = MySQL.single.await(
            'SELECT * FROM bc_banking_accounts WHERE citizenid = ? LIMIT 1',
            { citizenid }
        )

        if existing then
            return existing
        end

        if not inserted then
            print(('[bc-banking] Account creation attempt %s failed: %s'):format(attempt, tostring(insertResult)))
        end
    end

    print(('[bc-banking] CRITICAL: unable to create account after 10 attempts for citizen ID %s'):format(citizenid))
    return false
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if Player then
        local ok, result = pcall(function()
            return exports['bc-banking']:CreateAccount(Player)
        end)
        if not ok or not result then
            print(('[bc-banking] Account initialization failed: %s'):format(tostring(result)))
        end
    end
end)

-- QBCore remains the source of truth; this column is a synchronized display mirror.
exports('SyncAccountBalance', function(citizenid, balance)
    return MySQL.update.await(
        'UPDATE bc_banking_accounts SET balance = ? WHERE citizenid = ?',
        { BCBanking.RoundMoney(balance), citizenid }
    )
end)

exports('IncrementAccountBalance', function(citizenid, amount)
    return MySQL.update.await(
        'UPDATE bc_banking_accounts SET balance = balance + ? WHERE citizenid = ?',
        { BCBanking.RoundMoney(amount), citizenid }
    )
end)
