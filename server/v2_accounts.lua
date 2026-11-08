local QBCore = exports['qb-core']:GetCoreObject()

BCBanking = BCBanking or {}

local allowedTypes = {
    checking = true,
    savings = true
}

local function cleanText(value, limit)
    local text = BCBanking.Trim(value)
    text = text:gsub('[%c]', ''):sub(1, limit)
    return text
end

local function generateV2AccountNumber()
    local length = math.max(8, math.min(20, math.floor(tonumber(Config.AccountNumberLength) or 10)))
    for _ = 1, 20 do
        local number = ''
        for _ = 1, length do
            number = number .. tostring(math.random(0, 9))
        end

        local exists = MySQL.scalar.await(
            'SELECT id FROM bc_banking_v2_accounts WHERE account_number = ? LIMIT 1',
            { number }
        )
        if not exists then return number end
    end
    return nil
end

local function getAccountMembership(accountId, citizenid)
    return MySQL.single.await([[
        SELECT a.*, m.role, m.permissions
        FROM bc_banking_v2_accounts a
        INNER JOIN bc_banking_v2_account_members m ON m.account_id = a.id
        WHERE a.id = ? AND m.citizenid = ? AND m.status = 'active' AND a.status = 'active'
        LIMIT 1
    ]], { accountId, citizenid })
end

local function createPersonalAccount(citizenid, accountType, displayName)
    if not Config.V2 or Config.V2.Enabled ~= true then
        return false, 'BC-Banking V2 is currently disabled.'
    end

    if not allowedTypes[accountType] then
        return false, 'Choose a valid account type.'
    end

    local maxAccounts = math.max(1, math.min(20, tonumber(Config.V2.MaxPersonalAccounts) or 5))
    local count = tonumber(MySQL.scalar.await([[
        SELECT COUNT(*) FROM bc_banking_v2_accounts
        WHERE owner_citizenid = ? AND account_type IN ('checking', 'savings')
          AND status = 'active'
    ]], { citizenid })) or 0

    if count >= maxAccounts then
        return false, ('You can have up to %s additional personal accounts.'):format(maxAccounts)
    end

    local accountNumber = generateV2AccountNumber()
    if not accountNumber then
        return false, 'A new account number could not be generated. Please try again.'
    end

    local name = cleanText(displayName, 80)
    if name == '' then
        name = accountType == 'savings' and 'Personal Savings' or 'Personal Checking'
    end

    local ok, result = pcall(function()
        return MySQL.transaction.await({
            {
                query = [[
                    INSERT INTO bc_banking_v2_accounts
                    (account_number, account_type, display_name, owner_citizenid, balance, status)
                    VALUES (?, ?, ?, ?, 0.00, 'active')
                ]],
                values = { accountNumber, accountType, name, citizenid }
            },
            {
                query = [[
                    INSERT INTO bc_banking_v2_account_members
                    (account_id, citizenid, role, permissions, status)
                    SELECT id, ?, 'owner',
                        JSON_OBJECT('view', true, 'deposit', true, 'withdraw', true, 'transfer', true, 'manage', true),
                        'active'
                    FROM bc_banking_v2_accounts
                    WHERE account_number = ?
                ]],
                values = { citizenid, accountNumber }
            }
        })
    end)

    if not ok or result ~= true then
        print(('[bc-banking] V2 account creation failed for %s: %s'):format(citizenid, tostring(result)))
        return false, 'The account could not be created. No V1 balance was changed.'
    end

    local account = MySQL.single.await(
        'SELECT id, account_number, account_type, display_name, balance, status, created_at FROM bc_banking_v2_accounts WHERE account_number = ? LIMIT 1',
        { accountNumber }
    )

    if not account then
        return false, 'The account was created but could not be loaded. Contact staff.'
    end

    return true, account
end

exports('GetV2Accounts', function(citizenid)
    return MySQL.query.await([[
        SELECT a.id, a.account_number, a.account_type, a.display_name,
               a.balance, a.status, m.role, m.permissions, a.created_at
        FROM bc_banking_v2_accounts a
        INNER JOIN bc_banking_v2_account_members m ON m.account_id = a.id
        WHERE m.citizenid = ? AND m.status = 'active' AND a.status = 'active'
        ORDER BY a.id ASC
    ]], { citizenid }) or {}
end)

exports('GetV2AccountMembership', function(accountId, citizenid)
    return getAccountMembership(accountId, citizenid)
end)

QBCore.Functions.CreateCallback('bc-banking:v2:getAccounts', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not Config.V2 or Config.V2.Enabled ~= true then
        cb({ enabled = false, accounts = {} })
        return
    end

    local accounts = exports['bc-banking']:GetV2Accounts(Player.PlayerData.citizenid)
    cb({ enabled = true, accounts = accounts })
end)

RegisterNetEvent('bc-banking:v2:createAccount', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    local accountType = cleanText(type(data) == 'table' and data.accountType or '', 16):lower()
    local displayName = cleanText(type(data) == 'table' and data.name or '', 80)

    local ok, result = BCBanking.WithPlayerLocks({ citizenid }, function()
        return createPersonalAccount(citizenid, accountType, displayName)
    end)

    if not ok then
        TriggerClientEvent('bc-banking:client:notify', src, result or 'Account creation failed.', 'error')
        return
    end

    TriggerClientEvent('bc-banking:client:notify', src, 'Your new account is ready.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)
