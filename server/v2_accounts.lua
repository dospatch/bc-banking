local QBCore = exports['qb-core']:GetCoreObject()

BCBanking = BCBanking or {}
BCBanking.V2 = BCBanking.V2 or {}

local function validAmount(value, maximum)
    local amount = tonumber(value)
    if not amount or amount ~= amount or amount == math.huge or amount == -math.huge then return nil end
    amount = math.floor(amount * 100 + 0.5) / 100
    if amount <= 0 or amount > maximum then return nil end
    return amount
end

local function uuid()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return (template:gsub('[xy]', function(c)
        local r = math.random(0, 15)
        local v = c == 'x' and r or (r % 4 + 8)
        return ('%x'):format(v)
    end))
end

local function getCitizen(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return nil end
    return Player, Player.PlayerData.citizenid
end

local function generateAccountNumber()
    local length = math.max(10, math.min(20, math.floor(tonumber(Config.AccountNumberLength) or 12)))
    for _ = 1, 20 do
        local number = ''
        for _ = 1, length do number = number .. tostring(math.random(0, 9)) end
        local exists = MySQL.scalar.await(
            'SELECT id FROM bc_banking_v2_accounts WHERE account_number = ? LIMIT 1',
            { number }
        )
        if not exists then return number end
    end
    return nil
end

function BCBanking.V2.GetAccounts(citizenid)
    return MySQL.query.await([[
        SELECT a.id, a.account_number, a.account_type, a.display_name,
               a.owner_citizenid, a.balance, a.status, m.role, m.permissions
        FROM bc_banking_v2_accounts a
        INNER JOIN bc_banking_v2_account_members m ON m.account_id = a.id
        WHERE m.citizenid = ? AND m.status = 'active' AND a.status = 'active'
        ORDER BY a.id ASC
    ]], { citizenid }) or {}
end

function BCBanking.V2.CanAccessAccount(accountId, citizenid, permission)
    local member = MySQL.single.await([[
        SELECT m.role, m.permissions
        FROM bc_banking_v2_account_members m
        INNER JOIN bc_banking_v2_accounts a ON a.id = m.account_id
        WHERE m.account_id = ? AND m.citizenid = ?
          AND m.status = 'active' AND a.status = 'active'
        LIMIT 1
    ]], { accountId, citizenid })
    if not member then return false end
    if member.role == 'owner' then return true end
    local ok, permissions = pcall(json.decode, member.permissions or '{}')
    return ok and type(permissions) == 'table' and permissions[permission] == true
end

function BCBanking.V2.CreateAccount(citizenid, accountType, displayName)
    if accountType ~= 'checking' and accountType ~= 'savings' then
        return false, 'Only personal checking and savings accounts can be created here.'
    end
    local maximum = math.max(1, tonumber(Config.V2 and Config.V2.MaxPersonalAccounts) or 5)
    local count = tonumber(MySQL.scalar.await([[
        SELECT COUNT(*)
        FROM bc_banking_v2_account_members m
        INNER JOIN bc_banking_v2_accounts a ON a.id = m.account_id
        WHERE m.citizenid = ? AND m.status = 'active' AND a.status = 'active'
          AND a.account_type IN ('checking', 'savings')
    ]], { citizenid })) or 0
    if count >= maximum then return false, 'You have reached your personal account limit.' end

    local accountNumber = generateAccountNumber()
    if not accountNumber then return false, 'Unable to generate an account number. Try again.' end

    local name = BCBanking.Trim(displayName)
    if name == '' then name = accountType == 'savings' and 'Savings Account' or 'Additional Checking' end
    name = name:sub(1, 80)

    local accountId = MySQL.insert.await([[
        INSERT INTO bc_banking_v2_accounts
            (account_number, account_type, display_name, owner_citizenid, balance)
        VALUES (?, ?, ?, ?, 0.00)
    ]], { accountNumber, accountType, name, citizenid })
    if not accountId then return false, 'Account creation failed.' end

    local memberOk, memberErr = pcall(function()
        MySQL.insert.await([[
            INSERT INTO bc_banking_v2_account_members
                (account_id, citizenid, role, permissions, status)
            VALUES (?, ?, 'owner', ?, 'active')
        ]], { accountId, citizenid, json.encode({}) })
    end)
    if not memberOk then
        MySQL.query.await('DELETE FROM bc_banking_v2_accounts WHERE id = ?', { accountId })
        print(('[bc-banking] V2 account membership creation failed: %s'):format(tostring(memberErr)))
        return false, 'Account creation failed. No account was opened.'
    end

    BCBanking.V2.Audit(citizenid, 'account.created', 'account', accountId, {
        account_type = accountType,
        account_number = accountNumber
    })
    return MySQL.single.await('SELECT * FROM bc_banking_v2_accounts WHERE id = ?', { accountId })
end

function BCBanking.V2.Audit(actor, action, targetType, targetId, details)
    MySQL.insert.await([[
        INSERT INTO bc_banking_v2_audit_log
            (actor_citizenid, action, target_type, target_id, details)
        VALUES (?, ?, ?, ?, ?)
    ]], {
        actor, action, targetType, tostring(targetId or ''),
        details and json.encode(details) or nil
    })
end

function BCBanking.V2.ApplyDelta(accountId, citizenid, delta, entryType, description)
    if not BCBanking.V2.Ready then return false, 'V2 database is not ready.' end
    delta = tonumber(delta)
    if not delta or delta ~= delta or delta == math.huge or delta == -math.huge or delta == 0 then
        return false, 'Invalid ledger amount.'
    end
    if delta >= 0 then
        delta = math.floor(delta * 100 + 0.5) / 100
    else
        delta = math.ceil(delta * 100 - 0.5) / 100
    end
    local transactionRef = uuid()

    local ok, err = pcall(function()
        return MySQL.transaction.await({
            {
                query = [[
                    UPDATE bc_banking_v2_accounts
                    SET balance = balance + ?
                    WHERE id = ? AND status = 'active' AND balance + ? >= 0
                ]],
                values = { delta, accountId, delta }
            },
            { query = 'SET @bc_banking_v2_changed = ROW_COUNT()', values = {} },
            {
                query = [[
                    INSERT INTO bc_banking_v2_ledger
                        (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
                    SELECT id, ?, ?, ?, balance, ?, ?
                    FROM bc_banking_v2_accounts
                    WHERE id = ? AND status = 'active' AND @bc_banking_v2_changed = 1
                ]],
                values = { transactionRef, entryType, delta, citizenid, description, accountId }
            }
        })
    end)
    if not ok or err ~= true then
        return false, 'Ledger transaction failed.'
    end

    local entry = MySQL.single.await(
        'SELECT id FROM bc_banking_v2_ledger WHERE transaction_ref = ? AND account_id = ? LIMIT 1',
        { transactionRef, accountId }
    )
    if not entry then return false, 'Insufficient funds or account unavailable.' end
    return true, entry.id
end

QBCore.Functions.CreateCallback('bc-banking:v2:getAccounts', function(source, cb)
    local _, citizenid = getCitizen(source)
    if not citizenid or not BCBanking.V2.Ready then cb({}); return end
    cb(BCBanking.V2.GetAccounts(citizenid))
end)

QBCore.Functions.CreateCallback('bc-banking:v2:getLedger', function(source, cb, accountId)
    local _, citizenid = getCitizen(source)
    accountId = tonumber(accountId)
    if not BCBanking.V2.Ready or not citizenid or not accountId or not BCBanking.V2.CanAccessAccount(accountId, citizenid, 'view_transactions') then
        cb({})
        return
    end
    cb(MySQL.query.await([[
        SELECT id, entry_type, amount, balance_after, description, created_at
        FROM bc_banking_v2_ledger
        WHERE account_id = ?
        ORDER BY id DESC LIMIT 100
    ]], { accountId }) or {})
end)

RegisterNetEvent('bc-banking:v2:createAccount', function(data)
    local src = source
    local _, citizenid = getCitizen(src)
    if not citizenid or type(data) ~= 'table' then return end
    if not BCBanking.V2.Ready then
        TriggerClientEvent('bc-banking:client:notify', src, 'V2 banking is not ready. Contact staff.', 'error')
        return
    end
    if not BCBanking.CheckCooldown(citizenid) then return end
    local result, message = BCBanking.V2.CreateAccount(citizenid, tostring(data.accountType or ''), data.displayName)
    TriggerClientEvent('bc-banking:client:notify', src,
        result and ('Created ' .. result.display_name .. '.') or (message or 'Account creation failed.'),
        result and 'success' or 'error')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

local function moveQBCoreMoney(src, data, direction)
    local Player, citizenid = getCitizen(src)
    if not Player or type(data) ~= 'table' then return end
    if not BCBanking.V2.Ready then
        TriggerClientEvent('bc-banking:client:notify', src, 'V2 banking is not ready. Contact staff.', 'error')
        return
    end
    if not BCBanking.CheckCooldown(citizenid) then return end

    local accountId = tonumber(data.accountId)
    local amount = validAmount(data.amount, tonumber(Config.V2 and Config.V2.MaxPayment) or 1000000)
    local method = data.paymentType == 'cash' and 'cash' or 'bank'
    if not accountId or not amount or not BCBanking.V2.CanAccessAccount(accountId, citizenid, direction == 'deposit' and 'deposit' or 'withdraw') then
        TriggerClientEvent('bc-banking:client:notify', src, 'Invalid account or permission.', 'error')
        return
    end

    local total = tonumber(Player.PlayerData.money[method]) or 0
    if direction == 'deposit' then
        if total < amount then
            TriggerClientEvent('bc-banking:client:notify', src, 'Insufficient funds.', 'error')
            return
        end
        if Player.Functions.RemoveMoney(method, amount, 'bc-banking-v2-deposit') ~= true then
            TriggerClientEvent('bc-banking:client:notify', src, 'Payment could not be taken.', 'error')
            return
        end
        local ok = BCBanking.V2.ApplyDelta(accountId, citizenid, amount, 'deposit', 'Deposit from ' .. method)
        if not ok then
            Player.Functions.AddMoney(method, amount, 'bc-banking-v2-deposit-refund')
            TriggerClientEvent('bc-banking:client:notify', src, 'Deposit failed; funds were returned.', 'error')
            return
        end
    else
        local account = MySQL.single.await(
            'SELECT balance FROM bc_banking_v2_accounts WHERE id = ? AND status = \'active\' LIMIT 1',
            { accountId }
        )
        if not account or tonumber(account.balance) < amount then
            TriggerClientEvent('bc-banking:client:notify', src, 'Insufficient account funds.', 'error')
            return
        end
        local ok = BCBanking.V2.ApplyDelta(accountId, citizenid, -amount, 'withdrawal', 'Withdrawal to ' .. method)
        if not ok then
            TriggerClientEvent('bc-banking:client:notify', src, 'Withdrawal failed.', 'error')
            return
        end
        if Player.Functions.AddMoney(method, amount, 'bc-banking-v2-withdrawal') ~= true then
            local restored = BCBanking.V2.ApplyDelta(accountId, citizenid, amount, 'withdrawal_reversal', 'Failed payout reversal')
            print(('[bc-banking] V2 withdrawal payout failed; account reversal=%s citizenid=%s'):format(tostring(restored), citizenid))
            TriggerClientEvent('bc-banking:client:notify', src, 'Payout failed. Contact staff if your account was not restored.', 'error')
            return
        end
    end

    BCBanking.V2.Audit(citizenid, 'account.' .. direction, 'account', accountId, {
        amount = amount, payment_type = method
    })
    TriggerClientEvent('bc-banking:client:notify', src, direction == 'deposit' and 'Deposit completed.' or 'Withdrawal completed.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end

RegisterNetEvent('bc-banking:v2:fundAccount', function(data)
    moveQBCoreMoney(source, data, 'deposit')
end)

RegisterNetEvent('bc-banking:v2:withdrawAccount', function(data)
    moveQBCoreMoney(source, data, 'withdraw')
end)

exports('GetV2Accounts', function(citizenid)
    return BCBanking.V2.GetAccounts(citizenid)
end)

exports('CreateV2Account', function(citizenid, accountType, displayName)
    return BCBanking.V2.CreateAccount(citizenid, accountType, displayName)
end)

exports('ApplyV2LedgerEntry', function(accountId, citizenid, delta, entryType, description)
    return BCBanking.V2.ApplyDelta(accountId, citizenid, delta, entryType, description)
end)
