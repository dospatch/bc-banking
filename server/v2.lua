local QBCore = exports['qb-core']:GetCoreObject()
BCBanking = BCBanking or {}
BCBanking.V2 = BCBanking.V2 or {}

local V2 = BCBanking.V2
local function playerFor(src) return QBCore.Functions.GetPlayer(src) end

local function claimIdempotency(citizenid, operation, payload)
    if not BCBanking.V2Ready then return nil, 'v2_not_ready' end
    local key = type(payload) == 'table' and tostring(payload.idempotencyKey or '') or ''
    if #key < 8 or #key > 80 then return nil, 'idempotency_key_required' end
    local scoped = MySQL.scalar.await("SELECT SHA2(CONCAT(?, ':', ?, ':', ?), 256)", { citizenid, operation, key })
    local requestHash = MySQL.scalar.await("SELECT SHA2(?, 256)", { json.encode(payload) })
    local inserted = MySQL.insert.await([[
        INSERT IGNORE INTO bc_banking_v2_idempotency
        (idempotency_key, actor_citizenid, operation, request_hash, status)
        VALUES (?, ?, ?, ?, 'processing')
    ]], { scoped, citizenid, operation, requestHash })
    if inserted and inserted > 0 then return scoped, 'claimed' end
    local previous = MySQL.single.await('SELECT request_hash, status FROM bc_banking_v2_idempotency WHERE idempotency_key = ?', { scoped })
    if previous and previous.request_hash == requestHash and previous.status == 'completed' then
        return nil, 'already_completed'
    end
    if previous and previous.request_hash == requestHash and previous.status == 'failed' then
        local retried = MySQL.update.await([[
            UPDATE bc_banking_v2_idempotency
            SET status = 'processing', result_json = NULL, completed_at = NULL, created_at = CURRENT_TIMESTAMP
            WHERE idempotency_key = ? AND request_hash = ? AND status = 'failed'
        ]], { scoped, requestHash })
        if retried and retried > 0 then return scoped, 'claimed' end
        previous = MySQL.single.await('SELECT request_hash, status FROM bc_banking_v2_idempotency WHERE idempotency_key = ?', { scoped })
    end
    return nil, previous and previous.request_hash ~= requestHash and 'idempotency_conflict' or 'already_processing'
end

local function failIdempotency(key, reason)
    if not key then return end
    pcall(function()
        MySQL.update.await([[
            UPDATE bc_banking_v2_idempotency
            SET status = 'failed', result_json = ?, completed_at = CURRENT_TIMESTAMP
            WHERE idempotency_key = ? AND status = 'processing'
        ]], { json.encode({ success=false, reason=tostring(reason or 'failed'):sub(1,120) }), key })
    end)
end

local function completeIdempotency(key, result)
    if not key then return end
    MySQL.update.await([[
        UPDATE bc_banking_v2_idempotency
        SET status = 'completed', result_json = ?, completed_at = CURRENT_TIMESTAMP
        WHERE idempotency_key = ? AND status = 'processing'
    ]], { json.encode(result or { success=true }), key })
end

local function cidFor(src)
    if not BCBanking.V2Ready then return nil end
    local p = playerFor(src)
    return p and p.PlayerData and p.PlayerData.citizenid
end
local function amount(value, max)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    n = math.floor(n * 100 + 0.5) / 100
    if n <= 0 or (max and n > max) then return nil end
    return n
end

local function isNearConfiguredATM(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local coords = GetEntityCoords(ped)
    for _, atmCoords in ipairs(Config.ATMLocations or {}) do
        if #(coords - atmCoords) <= 3.0 then return true end
    end
    return false
end
local function accountNumber()
    local length = math.max(8, math.min(20, tonumber(Config.AccountNumberLength) or 10))
    for _ = 1, 20 do
        local out = ''
        for _ = 1, length do out = out .. tostring(math.random(0, 9)) end
        if tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM bc_banking_v2_accounts WHERE account_number = ?', { out }) or 0) == 0 then
            return out
        end
    end
    return nil
end
local function member(accountId, citizenid)
    if not BCBanking.V2Ready then return nil end
    return MySQL.single.await([[
        SELECT m.*, a.account_type, a.account_number, a.display_name, a.balance, a.status AS account_status
        FROM bc_banking_v2_account_members m
        JOIN bc_banking_v2_accounts a ON a.id = m.account_id
        WHERE m.account_id = ? AND m.citizenid = ? AND m.status = 'active' AND a.status = 'active'
        LIMIT 1
    ]], { accountId, citizenid })
end
local function logAudit(actor, action, target, details)
    local detailsJson = json.encode(details or {})
    MySQL.insert.await([[
        INSERT INTO bc_banking_v2_audit (actor_citizenid, action, target_type, target_id, details)
        VALUES (?, ?, ?, ?, ?)
    ]], { actor, action, 'account', tostring(target or ''), detailsJson })
    if BCBanking.SendDiscordLog then
        pcall(function()
            BCBanking.SendDiscordLog({
                type = action,
                title = 'BC-Banking V2 • ' .. tostring(action),
                color = 0xD97706,
                fields = {
                    { name = 'Actor', value = tostring(actor or 'N/A'), inline = true },
                    { name = 'Target', value = tostring(target or 'N/A'), inline = true },
                    { name = 'Details', value = tostring(detailsJson):sub(1, 900), inline = false }
                }
            })
        end)
    end
end

local function givePhysicalCardItem(src, cardId, last4)
    local itemConfig = Config.V2 and Config.V2.CardItem
    if not itemConfig or itemConfig.Enabled ~= true then return true end
    if GetResourceState('ox_inventory') ~= 'started' then return false end
    local itemName = tostring(itemConfig.Name or 'bc_bank_card'):sub(1, 64)
    local ok, added = pcall(function()
        return exports.ox_inventory:AddItem(src, itemName, 1, {
            cardId = tonumber(cardId),
            last4 = tostring(last4),
            issuer = 'BC-Banking'
        })
    end)
    return ok and added == true
end
local function createAccount(citizenid, kind, name, initial)
    if not BCBanking.V2Ready then return nil, 'V2 database is not ready.' end

    local permissions = json.encode({
        view=true, deposit=true, withdraw=true, transfer=true,
        manage=true, statements=true
    })

    -- Account and owner membership are committed together. A failed second
    -- insert must never leave an orphaned account with no authorized owner.
    for attempt = 1, 5 do
        local number = accountNumber()
        if not number then return nil, 'Could not allocate an account number.' end

        local transactionOk, committed = pcall(function()
            return MySQL.transaction.await({
                {
                    query = [[
                        INSERT INTO bc_banking_v2_accounts
                        (account_number, account_type, display_name, owner_citizenid, balance, status)
                        VALUES (?, ?, ?, ?, ?, 'active')
                    ]],
                    values = { number, kind, name, initial or 0 }
                },
                {
                    query = [[
                        INSERT INTO bc_banking_v2_account_members
                        (account_id, citizenid, role, permissions, status)
                        SELECT id, ?, 'owner', ?, 'active'
                        FROM bc_banking_v2_accounts
                        WHERE account_number = ? AND owner_citizenid = ?
                    ]],
                    values = { citizenid, permissions, number, citizenid }
                }
            })
        end)

        if transactionOk and committed == true then
            local account = MySQL.single.await(
                'SELECT * FROM bc_banking_v2_accounts WHERE account_number = ? LIMIT 1',
                { number }
            )
            if account then return account end
            return nil, 'Account was committed but could not be loaded.'
        end
    end

    return nil, 'Account creation failed after multiple safe attempts.'
end

QBCore.Functions.CreateCallback('bc-banking:v2:getAccounts', function(src, cb)
    local cid = cidFor(src)
    if not cid then cb({}); return end
    cb(MySQL.query.await([[
        SELECT a.id, a.account_number, a.account_type, a.display_name, a.balance, a.status,
               m.role, m.permissions
        FROM bc_banking_v2_accounts a
        JOIN bc_banking_v2_account_members m ON m.account_id = a.id
        WHERE m.citizenid = ? AND m.status = 'active' AND a.status = 'active'
          AND JSON_UNQUOTE(JSON_EXTRACT(m.permissions, '$.view')) = 'true'
        ORDER BY a.id ASC
    ]], { cid }) or {})
end)

RegisterNetEvent('bc-banking:v2:createAccount', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end

    local kind = tostring(data.type or 'checking')
    local allowed = { checking=true, savings=true }
    if not allowed[kind] then
        TriggerClientEvent('bc-banking:client:notify', src, 'Invalid account type.', 'error')
        return
    end

    local name = tostring(data.name or (kind == 'savings' and 'Savings Account' or 'Checking Account'))
        :gsub('[%c]', ''):sub(1, 80)

    -- Serialize the account-limit check and insert per character so two rapid
    -- create requests cannot both pass the same limit check.
    local account, err = BCBanking.WithPlayerLocks({ cid }, function()
        local count = tonumber(MySQL.scalar.await([[
            SELECT COUNT(*)
            FROM bc_banking_v2_account_members m
            JOIN bc_banking_v2_accounts a ON a.id = m.account_id
            WHERE m.citizenid = ? AND m.status = 'active'
              AND a.status = 'active'
              AND a.account_type IN ('checking','savings')
        ]], { cid }) or 0)

        local cap = math.max(1, math.min(20, tonumber(Config.V2 and Config.V2.MaxPersonalAccounts) or 5))
        if count >= cap then
            return nil, 'You have reached your account limit.'
        end

        return createAccount(cid, kind, name, 0)
    end)

    if not account then
        TriggerClientEvent('bc-banking:client:notify', src, err or 'Account creation failed.', 'error')
        return
    end

    logAudit(cid, 'account.created', account.id, { type=kind })
    TriggerClientEvent('bc-banking:client:notify', src, 'Account created: ' .. account.account_number, 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

RegisterNetEvent('bc-banking:v2:transfer', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local fromId, toNumber = tonumber(data.accountId), tostring(data.recipient or '')
    local value = amount(data.amount, tonumber(Config.MaxTransfer) or 1000000)
    if not fromId or not value or #toNumber < 6 or #toNumber > 24 then return end
    local from = member(fromId, cid)
    local to = MySQL.single.await("SELECT * FROM bc_banking_v2_accounts WHERE account_number = ? AND status = 'active' LIMIT 1", { toNumber })
    if not from or not to then return end
    local permissions = type(from.permissions) == 'table' and from.permissions or json.decode(from.permissions or '{}') or {}
    if not permissions.transfer or tonumber(from.id) == tonumber(to.id) then return end
    local idempotencyKey, idemState = claimIdempotency(cid, 'account.transfer', data)
    if idemState == 'already_completed' then TriggerClientEvent('bc-banking:client:notify', src, 'This transfer was already processed.', 'success'); return end
    if not idempotencyKey then TriggerClientEvent('bc-banking:client:notify', src, 'Transfer request rejected: ' .. tostring(idemState), 'error'); return end
    local fee = math.max(0, tonumber(Config.V2 and Config.V2.InternalTransferFee) or 0)
    local total = value + fee
    local ref = ('%s-%s-%s'):format(os.time(), src, math.random(100000, 999999))
    -- One atomic multi-table update prevents the recipient being credited when
    -- the source account lacks funds. Both balances are changed by one SQL statement.
    local changed = MySQL.update.await([[
        UPDATE bc_banking_v2_accounts AS src
        JOIN bc_banking_v2_accounts AS dst ON dst.id = ?
        SET src.balance = src.balance - ?, dst.balance = dst.balance + ?
        WHERE src.id = ? AND src.status = 'active' AND dst.status = 'active'
          AND src.balance >= ?
    ]], { to.id, total, value, fromId, total })
    if not changed or changed < 2 then
        failIdempotency(idempotencyKey, 'insufficient_funds_or_account_unavailable')
        TriggerClientEvent('bc-banking:client:notify', src, 'Transfer failed or insufficient funds.', 'error')
        return
    end
    local logged, err = pcall(function()
        MySQL.insert.await([[
            INSERT INTO bc_banking_v2_ledger
            (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description, metadata)
            SELECT id, ?, 'transfer_out', ?, balance, ?, ?, ?
            FROM bc_banking_v2_accounts WHERE id = ?
        ]], { ref, total, cid, tostring(data.description or 'Account transfer'):sub(1, 255), json.encode({ recipient=to.account_number, fee=fee }), fromId })
        MySQL.insert.await([[
            INSERT INTO bc_banking_v2_ledger
            (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description, metadata)
            SELECT id, ?, 'transfer_in', ?, balance, ?, ?, ?
            FROM bc_banking_v2_accounts WHERE id = ?
        ]], { ref, value, cid, tostring(data.description or 'Incoming transfer'):sub(1, 255), json.encode({ sender=from.account_number }), to.id })
    end)
    if not logged then
        -- Compensating reversal if audit ledger persistence fails.
        MySQL.update.await([[
            UPDATE bc_banking_v2_accounts AS src
            JOIN bc_banking_v2_accounts AS dst ON dst.id = ?
            SET src.balance = src.balance + ?, dst.balance = dst.balance - ?
            WHERE src.id = ?
        ]], { to.id, total, value, fromId })
        failIdempotency(idempotencyKey, 'ledger_write_failed')
        print(('[bc-banking] V2 transfer ledger failure; balances reversed: %s'):format(tostring(err)))
        TriggerClientEvent('bc-banking:client:notify', src, 'Transfer was reversed because it could not be recorded.', 'error')
        return
    end
    completeIdempotency(idempotencyKey, { success=true, reference=ref })
    logAudit(cid, 'account.transfer', fromId, { to=to.account_number, amount=value, fee=fee })
    TriggerClientEvent('bc-banking:client:notify', src, 'Transfer completed.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

QBCore.Functions.CreateCallback('bc-banking:v2:getGoals', function(src, cb)
    local cid = cidFor(src)
    if not cid then cb({}); return end
    cb(MySQL.query.await('SELECT * FROM bc_banking_v2_savings_goals WHERE citizenid = ? ORDER BY id DESC', { cid }) or {})
end)

RegisterNetEvent('bc-banking:v2:createGoal', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local target = amount(data.target, 1000000000)
    if not target then return end
    local name = tostring(data.name or 'Savings goal'):sub(1, 80)
    MySQL.insert.await('INSERT INTO bc_banking_v2_savings_goals (citizenid, name, target_amount, current_amount, status) VALUES (?, ?, ?, 0, ?)', { cid, name, target, 'active' })
    logAudit(cid, 'savings_goal.created', cid, { name=name, target=target })
    TriggerClientEvent('bc-banking:client:notify', src, 'Savings goal created.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

RegisterNetEvent('bc-banking:v2:contributeGoal', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local goalId, value = tonumber(data.goalId), amount(data.amount, 100000000)
    if not goalId or not value then return end
    local goal = MySQL.single.await("SELECT * FROM bc_banking_v2_savings_goals WHERE id = ? AND citizenid = ? AND status = 'active'", { goalId, cid })
    if not goal then return end
    local idempotencyKey, idemState = claimIdempotency(cid, 'savings.contribution', data)
    if idemState == 'already_completed' then return end
    if not idempotencyKey then return end
    local player = playerFor(src)
    if not player or (tonumber(player.PlayerData.money.bank) or 0) < value then
        failIdempotency(idempotencyKey, 'insufficient_funds')
        TriggerClientEvent('bc-banking:client:notify', src, 'Insufficient checking balance.', 'error'); return
    end
    local removed = player.Functions.RemoveMoney('bank', value, 'bc-banking-savings-goal')
    if not removed then failIdempotency(idempotencyKey, 'money_removal_failed'); return end
    local updated = MySQL.update.await("UPDATE bc_banking_v2_savings_goals SET status = IF(current_amount + ? >= target_amount, 'completed', status), current_amount = current_amount + ? WHERE id = ? AND citizenid = ?", { value, value, goalId, cid })
    if not updated then
        player.Functions.AddMoney('bank', value, 'bc-banking-savings-goal-refund')
        failIdempotency(idempotencyKey, 'goal_update_failed')
        return
    end
    completeIdempotency(idempotencyKey, { success=true })
    logAudit(cid, 'savings_goal.contribution', goalId, { amount=value })
    TriggerClientEvent('bc-banking:client:notify', src, 'Savings goal updated.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

QBCore.Functions.CreateCallback('bc-banking:v2:getCards', function(src, cb)
    local cid = cidFor(src)
    if not cid then cb({}); return end
    cb(MySQL.query.await('SELECT id, account_id, card_last4, card_type, status, expires_at, created_at FROM bc_banking_v2_cards WHERE citizenid = ? ORDER BY id DESC', { cid }) or {})
end)

RegisterNetEvent('bc-banking:v2:issueCard', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local accountId = tonumber(data.accountId)
    local cardType = tostring(data.cardType or 'physical')
    if cardType ~= 'physical' and cardType ~= 'virtual' then return end
    if not accountId or not member(accountId, cid) then return end
    local count = tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM bc_banking_v2_cards WHERE citizenid = ? AND status = 'active'", { cid }) or 0)
    if count >= (tonumber(Config.V2 and Config.V2.MaxCards) or 3) then
        TriggerClientEvent('bc-banking:client:notify', src, 'You have reached your active card limit.', 'error'); return
    end
    local nonce, salt = '', tostring(math.random(100000, 999999)) .. tostring(os.time()) .. tostring(math.random(100000,999999))
    for _ = 1, 32 do nonce = nonce .. tostring(math.random(0, 9)) end
    local last4 = nonce:sub(-4)
    -- The token is hashed by the database and never stored in plaintext.
    local id = MySQL.insert.await([[
        INSERT INTO bc_banking_v2_cards (citizenid, account_id, card_hash, card_last4, card_type, status, expires_at)
        VALUES (?, ?, SHA2(CONCAT(?, ?, ?), 256), ?, ?, 'active', DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 4 YEAR))
    ]], { cid, accountId, nonce, salt, tostring(Config.V2 and Config.V2.CardPepper or ''), last4, cardType })
    if id then
        local secretOk = pcall(function()
            MySQL.insert.await('INSERT INTO bc_banking_v2_card_secrets (card_id, pin_salt) VALUES (?, ?)', { id, salt })
        end)
        if not secretOk then
            MySQL.update.await('DELETE FROM bc_banking_v2_cards WHERE id = ? AND citizenid = ?', { id, cid })
            TriggerClientEvent('bc-banking:client:notify', src, 'Card could not be completed; no card was issued.', 'error')
            return
        end
        local itemDelivered = cardType ~= 'physical' or givePhysicalCardItem(src, id, last4)
        logAudit(cid, 'card.issued', id, { last4=last4, card_type=cardType, inventory_item_delivered=itemDelivered })
        local notice = cardType .. ' card issued ending in ' .. last4 .. '. Card number is not recoverable.'
        if cardType == 'physical' and Config.V2.CardItem and Config.V2.CardItem.Enabled and not itemDelivered then
            notice = notice .. ' Inventory item delivery failed; check ox_inventory item setup.'
        end
        TriggerClientEvent('bc-banking:client:notify', src, notice, itemDelivered and 'success' or 'error')
        TriggerClientEvent('bc-banking:client:v2:refresh', src)
    end
end)

RegisterNetEvent('bc-banking:v2:setCardStatus', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local id = tonumber(data.cardId)
    local status = data.frozen == true and 'frozen' or 'active'
    if not id then return end
    local changed = MySQL.update.await('UPDATE bc_banking_v2_cards SET status = ? WHERE id = ? AND citizenid = ? AND status IN ("active", "frozen")', { status, id, cid })
    if changed and changed > 0 then
        logAudit(cid, 'card.status_changed', id, { status=status })
        TriggerClientEvent('bc-banking:client:notify', src, 'Card status updated.', 'success')
        TriggerClientEvent('bc-banking:client:v2:refresh', src)
    end
end)

RegisterNetEvent('bc-banking:v2:applyLoan', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local principal = amount(data.amount, tonumber(Config.V2 and Config.V2.MaxLoan) or 500000)
    local months = math.floor(tonumber(data.months) or 0)
    if not principal or months < 1 or months > (tonumber(Config.V2 and Config.V2.MaxLoanMonths) or 24) then return end
    local rate = math.max(0, tonumber(Config.V2 and Config.V2.LoanAPR) or 5)
    local id, err = BCBanking.WithPlayerLocks({ cid }, function()
        local open = tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM bc_banking_v2_loans WHERE citizenid = ? AND status IN ('pending','approved','active','processing')", { cid }) or 0)
        if open > 0 then return nil, 'You already have an open loan application or loan.' end
        return MySQL.insert.await([[
            INSERT INTO bc_banking_v2_loans (citizenid, principal, apr, term_months, status)
            VALUES (?, ?, ?, ?, 'pending')
        ]], { cid, principal, rate, months })
    end)
    if not id then
        TriggerClientEvent('bc-banking:client:notify', src, err or 'Loan application could not be submitted.', 'error')
        return
    end
    logAudit(cid, 'loan.applied', id, { principal=principal, months=months, apr=rate })
    TriggerClientEvent('bc-banking:client:notify', src, 'Loan application submitted for review.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

QBCore.Functions.CreateCallback('bc-banking:v2:getLoans', function(src, cb)
    local cid = cidFor(src)
    if not cid then cb({}); return end
    cb(MySQL.query.await('SELECT id, principal, apr, term_months, monthly_payment, balance_due, status, created_at, reviewed_at FROM bc_banking_v2_loans WHERE citizenid = ? ORDER BY id DESC', { cid }) or {})
end)

QBCore.Functions.CreateCallback('bc-banking:v2:getBusinesses', function(src, cb)
    local cid = cidFor(src)
    if not cid then cb({}); return end
    cb(MySQL.query.await([[
        SELECT b.id, b.name, b.account_id, b.status, m.role, m.permissions
        FROM bc_banking_v2_businesses b
        JOIN bc_banking_v2_business_members m ON m.business_id = b.id
        WHERE m.citizenid = ? AND m.status = 'active' AND b.status = 'active'
          AND JSON_UNQUOTE(JSON_EXTRACT(m.permissions, '$.view')) = 'true'
    ]], { cid }) or {})
end)

RegisterNetEvent('bc-banking:v2:createBusiness', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local name = tostring(data.name or ''):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 80)
    if #name < 3 then return end
    local id = MySQL.insert.await('INSERT INTO bc_banking_v2_businesses (name, owner_citizenid, status) VALUES (?, ?, "active")', { name, cid })
    if not id then return end
    local account, err = createAccount(cid, 'business', name, 0)
    if not account then
        MySQL.update.await('UPDATE bc_banking_v2_businesses SET status = "failed" WHERE id = ?', { id })
        TriggerClientEvent('bc-banking:client:notify', src, err or 'Business account failed.', 'error')
        return
    end
    local setupOk, setupCommitted = pcall(function()
        return MySQL.transaction.await({
            {
                query = "UPDATE bc_banking_v2_businesses SET account_id = ? WHERE id = ? AND owner_citizenid = ? AND status = 'active'",
                values = { account.id, id, cid }
            },
            {
                query = [[
                    INSERT INTO bc_banking_v2_business_members
                    (business_id, citizenid, role, permissions, status)
                    VALUES (?, ?, 'owner', ?, 'active')
                ]],
                values = { id, cid, json.encode({ view=true, deposit=true, withdraw=true, transfer=true, payroll=true, manage=true }) }
            }
        })
    end)
    if not setupOk or setupCommitted ~= true then
        MySQL.update.await("UPDATE bc_banking_v2_businesses SET status = 'failed' WHERE id = ?", { id })
        MySQL.update.await("UPDATE bc_banking_v2_accounts SET status = 'closed' WHERE id = ? AND owner_citizenid = ?", { account.id, cid })
        TriggerClientEvent('bc-banking:client:notify', src, 'Business setup failed; its account was closed safely.', 'error')
        return
    end
    logAudit(cid, 'business.created', id, { name=name, account_id=account.id })
    TriggerClientEvent('bc-banking:client:notify', src, 'Business account created.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

RegisterNetEvent('bc-banking:v2:addBusinessEmployee', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local businessId, employeeCid = tonumber(data.businessId), tostring(data.citizenid or '')
    if not businessId or #employeeCid < 2 or #employeeCid > 50 or employeeCid == cid then return end
    local owner = MySQL.single.await("SELECT id FROM bc_banking_v2_business_members WHERE business_id = ? AND citizenid = ? AND role = 'owner' AND status = 'active'", { businessId, cid })
    if not owner then return end
    local requested = type(data.permissions) == 'table' and data.permissions or {}
    local perms = {
        view=requested.view == true,
        deposit=requested.deposit == true,
        withdraw=requested.withdraw == true,
        transfer=requested.transfer == true,
        payroll=requested.payroll == true,
        manage=false
    }
    local business = MySQL.single.await("SELECT account_id FROM bc_banking_v2_businesses WHERE id = ? AND owner_citizenid = ? AND status = 'active'", { businessId, cid })
    if not business or not business.account_id then return end
    local saved, committed = pcall(function()
        return MySQL.transaction.await({
            {
                query = [[
                    INSERT INTO bc_banking_v2_business_members
                    (business_id, citizenid, role, permissions, status)
                    VALUES (?, ?, 'employee', ?, 'active')
                    ON DUPLICATE KEY UPDATE permissions = VALUES(permissions), status = 'active'
                ]],
                values = { businessId, employeeCid, json.encode(perms) }
            },
            {
                query = [[
                    INSERT INTO bc_banking_v2_account_members
                    (account_id, citizenid, role, permissions, status)
                    VALUES (?, ?, 'employee', ?, 'active')
                    ON DUPLICATE KEY UPDATE permissions = VALUES(permissions), status = 'active'
                ]],
                values = { business.account_id, employeeCid, json.encode(perms) }
            }
        })
    end)
    if not saved or committed ~= true then
        TriggerClientEvent('bc-banking:client:notify', src, 'Employee permissions could not be saved.', 'error')
        return
    end
    logAudit(cid, 'business.employee_added', businessId, { employee=employeeCid })
    TriggerClientEvent('bc-banking:client:notify', src, 'Business employee permissions saved.', 'success')
end)

RegisterNetEvent('bc-banking:v2:payroll', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local businessId, employeeCid = tonumber(data.businessId), tostring(data.citizenid or '')
    local value = amount(data.amount, tonumber(Config.V2 and Config.V2.MaxPayrollPayment) or 100000)
    if not businessId or not value or #employeeCid < 2 then return end
    local business = MySQL.single.await([[
        SELECT b.account_id, m.permissions FROM bc_banking_v2_businesses b
        JOIN bc_banking_v2_business_members m ON m.business_id = b.id
        WHERE b.id = ? AND m.citizenid = ? AND m.status = 'active' AND b.status = 'active'
    ]], { businessId, cid })
    if not business then return end
    local perms = type(business.permissions) == 'table' and business.permissions or json.decode(business.permissions or '{}') or {}
    if not perms.payroll then return end
    local idempotencyKey, idemState = claimIdempotency(cid, 'business.payroll', data)
    if idemState == 'already_completed' then return end
    if not idempotencyKey then return end
    local ref = ('pay-%s-%s-%s'):format(os.time(), src, math.random(100000,999999))
    local success = MySQL.update.await("UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ? AND balance >= ? AND status = 'active'", { value, business.account_id, value })
    if not success or success < 1 then
        failIdempotency(idempotencyKey, 'insufficient_business_funds')
        TriggerClientEvent('bc-banking:client:notify', src, 'Insufficient business funds.', 'error'); return
    end
    local recipient = QBCore.Functions.GetPlayerByCitizenId(employeeCid)
    if recipient then
        local paid = recipient.Functions.AddMoney('bank', value, 'bc-banking-business-payroll')
        if not paid then
            MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { value, business.account_id })
            failIdempotency(idempotencyKey, 'payroll_payout_failed')
            TriggerClientEvent('bc-banking:client:notify', src, 'Payroll failed; business funds were returned.', 'error'); return
        end
    else
        local result = MySQL.update.await("UPDATE players SET money = JSON_SET(money, '$.bank', COALESCE(JSON_EXTRACT(money, '$.bank'), 0) + ?) WHERE citizenid = ?", { value, employeeCid })
        if not result or result < 1 then
            MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { value, business.account_id })
            failIdempotency(idempotencyKey, 'employee_not_found')
            TriggerClientEvent('bc-banking:client:notify', src, 'Employee not found; payroll reversed.', 'error'); return
        end
    end
    local balance = MySQL.scalar.await('SELECT balance FROM bc_banking_v2_accounts WHERE id = ?', { business.account_id })
    local recorded, recordResult = pcall(function()
        return MySQL.transaction.await({
            {
                query = [[
                    INSERT INTO bc_banking_v2_ledger
                    (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description, metadata)
                    VALUES (?, ?, 'payroll', ?, ?, ?, 'Business payroll payment', ?)
                ]],
                values = { business.account_id, ref, -value, balance, cid, json.encode({ employee=employeeCid }) }
            },
            {
                query = [[
                    INSERT INTO bc_banking_v2_payroll
                    (business_id, employee_citizenid, amount, actor_citizenid, status)
                    VALUES (?, ?, ?, ?, 'paid')
                ]],
                values = { businessId, employeeCid, value, cid }
            }
        })
    end)
    if not recorded or recordResult ~= true then
        local reversed = false
        if recipient then
            reversed = recipient.Functions.RemoveMoney('bank', value, 'bc-banking-business-payroll-reversal') == true
        else
            local rollback = MySQL.update.await(
                "UPDATE players SET money = JSON_SET(money, '$.bank', GREATEST(0, COALESCE(JSON_EXTRACT(money, '$.bank'), 0) - ?)) WHERE citizenid = ?",
                { value, employeeCid }
            )
            reversed = rollback and rollback > 0
        end
        MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { value, business.account_id })
        failIdempotency(idempotencyKey, 'payroll_recording_failed')
        if not reversed then
            print(('[bc-banking] CRITICAL: payroll reversal could not be confirmed for employee %s'):format(employeeCid))
        end
        TriggerClientEvent('bc-banking:client:notify', src, 'Payroll record failed; reversal was attempted.', 'error')
        return
    end
    completeIdempotency(idempotencyKey, { success=true })
    logAudit(cid, 'business.payroll_paid', businessId, { employee=employeeCid, amount=value })
    TriggerClientEvent('bc-banking:client:notify', src, 'Payroll payment sent.', 'success')
end)

-- Admin review commands are ACE-gated. Approval never runs from a client event.
RegisterCommand('bcbankloan', function(src, args)
    if not BCBanking.V2Ready then print('[bc-banking] V2 database is not ready.'); return end
    if src ~= 0 and not IsPlayerAceAllowed(src, 'bc-banking.admin') then return end
    local id, decision = tonumber(args[1]), tostring(args[2] or '')
    if not id or (decision ~= 'approve' and decision ~= 'reject') then
        print('Usage: bcbankloan <applicationId> <approve|reject>'); return
    end
    local loan = MySQL.single.await("SELECT * FROM bc_banking_v2_loans WHERE id = ? AND status = 'pending'", { id })
    if not loan then print('[bc-banking] Pending loan not found.'); return end
    local actor = src == 0 and 'SERVER_CONSOLE' or (cidFor(src) or 'UNKNOWN')
    if decision == 'reject' then
        local rejected = MySQL.update.await("UPDATE bc_banking_v2_loans SET status = 'rejected', reviewed_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'pending'", { id })
        if rejected and rejected > 0 then logAudit(actor, 'loan.rejected', id, { applicant=loan.citizenid }) end
    else
        local claimed = MySQL.update.await("UPDATE bc_banking_v2_loans SET status = 'processing' WHERE id = ? AND status = 'pending'", { id })
        if not claimed or claimed < 1 then print('[bc-banking] Loan application is no longer pending.'); return end
        local payment = loan.principal * (1 + (loan.apr / 100) * (loan.term_months / 12)) / loan.term_months
        local player = QBCore.Functions.GetPlayerByCitizenId(loan.citizenid)
        if player then
            local paid = player.Functions.AddMoney('bank', tonumber(loan.principal), 'bc-banking-loan-disbursement')
            if not paid then MySQL.update.await("UPDATE bc_banking_v2_loans SET status = 'pending' WHERE id = ? AND status = 'processing'", { id }); print('[bc-banking] Loan disbursement failed; application left pending.'); return end
        else
            local changed = MySQL.update.await("UPDATE players SET money = JSON_SET(money, '$.bank', COALESCE(JSON_EXTRACT(money, '$.bank'), 0) + ?) WHERE citizenid = ?", { loan.principal, loan.citizenid })
            if not changed or changed < 1 then MySQL.update.await("UPDATE bc_banking_v2_loans SET status = 'pending' WHERE id = ? AND status = 'processing'", { id }); print('[bc-banking] Loan disbursement failed; application left pending.'); return end
        end
        local finalized = MySQL.update.await("UPDATE bc_banking_v2_loans SET status = 'active', monthly_payment = ?, balance_due = principal * (1 + (apr / 100) * (term_months / 12)), reviewed_at = CURRENT_TIMESTAMP, next_payment_at = DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 1 MONTH) WHERE id = ? AND status = 'processing'", { payment, id })
        if not finalized or finalized < 1 then
            if player then player.Functions.RemoveMoney('bank', tonumber(loan.principal), 'bc-banking-loan-reversal')
            else MySQL.update.await("UPDATE players SET money = JSON_SET(money, '$.bank', GREATEST(0, COALESCE(JSON_EXTRACT(money, '$.bank'), 0) - ?)) WHERE citizenid = ?", { loan.principal, loan.citizenid }) end
            MySQL.update.await("UPDATE bc_banking_v2_loans SET status = 'pending' WHERE id = ? AND status = 'processing'", { id })
            print('[bc-banking] Loan activation failed; disbursement reversed.')
            return
        end
        logAudit(actor, 'loan.approved', id, { applicant=loan.citizenid, principal=tonumber(loan.principal) })
        pcall(function()
            exports['bc-banking']:AddTransaction(loan.citizenid, 'loan_disbursement', tonumber(loan.principal), 'Loan disbursement')
        end)
    end
    print(('[bc-banking] Loan %s %s.'):format(id, decision))
end, true)

exports('GetV2Accounts', function(citizenid)
    if not BCBanking.V2Ready then return {} end
    return MySQL.query.await([[
        SELECT a.* FROM bc_banking_v2_accounts a
        JOIN bc_banking_v2_account_members m ON m.account_id = a.id
        WHERE m.citizenid = ? AND m.status = 'active' AND a.status = 'active'
          AND JSON_UNQUOTE(JSON_EXTRACT(m.permissions, '$.view')) = 'true'
    ]], { citizenid }) or {}
end)

exports('GetV2AccountBalance', function(accountId, citizenid)
    local access = member(tonumber(accountId), citizenid)
    if not access then return nil end
    local perms = type(access.permissions) == 'table' and access.permissions or json.decode(access.permissions or '{}') or {}
    return perms.view == true and tonumber(access.balance) or nil
end)

exports('DepositToV2Account', function(accountId, citizenid, value, description, idempotencyKey)
    if not BCBanking.V2Ready then return false, 'v2_not_ready' end
    local n = amount(value, tonumber(Config.MaxDeposit) or 1000000)
    if not n then return false, 'invalid_amount' end
    local access = member(tonumber(accountId), citizenid)
    if not access then return false, 'not_authorized' end
    local perms = type(access.permissions) == 'table' and access.permissions or json.decode(access.permissions or '{}') or {}
    if not perms.deposit then return false, 'not_authorized' end
    local idem, idemState = claimIdempotency(citizenid, 'api.account.deposit', {
        idempotencyKey=idempotencyKey, accountId=tonumber(accountId), amount=n, description=description
    })
    if idemState == 'already_completed' then return true end
    if not idem then return false, idemState end

    local changed = MySQL.update.await("UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ? AND status = 'active'", { n, tonumber(accountId) })
    if not changed or changed < 1 then
        failIdempotency(idem, 'account_unavailable')
        return false, 'account_unavailable'
    end
    local ref = ('api-dep-%s-%s'):format(os.time(), math.random(100000,999999))
    local logged = pcall(function()
        MySQL.insert.await([[
            INSERT INTO bc_banking_v2_ledger
            (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
            SELECT id, ?, 'deposit', ?, balance, ?, ?
            FROM bc_banking_v2_accounts WHERE id = ? AND status = 'active'
        ]], { ref, n, citizenid, tostring(description or 'External deposit'):sub(1,255), tonumber(accountId) })
    end)
    if not logged then
        MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ?', { n, tonumber(accountId) })
        failIdempotency(idem, 'ledger_write_failed')
        return false, 'ledger_error'
    end
    completeIdempotency(idem, { success=true, reference=ref })
    logAudit(citizenid, 'account.deposit_api', accountId, { amount=n, reference=ref })
    return true
end)

exports('WithdrawFromV2Account', function(accountId, citizenid, value, description, idempotencyKey)
    if not BCBanking.V2Ready then return false, 'v2_not_ready' end
    local n = amount(value, tonumber(Config.MaxWithdrawal) or 1000000)
    if not n then return false, 'invalid_amount' end
    local access = member(tonumber(accountId), citizenid)
    if not access then return false, 'not_authorized' end
    local perms = type(access.permissions) == 'table' and access.permissions or json.decode(access.permissions or '{}') or {}
    if not perms.withdraw then return false, 'not_authorized' end
    local idem, idemState = claimIdempotency(citizenid, 'api.account.withdraw', {
        idempotencyKey=idempotencyKey, accountId=tonumber(accountId), amount=n, description=description
    })
    if idemState == 'already_completed' then return true end
    if not idem then return false, idemState end

    local changed = MySQL.update.await([[
        UPDATE bc_banking_v2_accounts
        SET balance = balance - ?
        WHERE id = ? AND status = 'active' AND balance >= ?
    ]], { n, tonumber(accountId), n })
    if not changed or changed < 1 then
        failIdempotency(idem, 'insufficient_funds_or_account_unavailable')
        return false, 'insufficient_funds_or_account_unavailable'
    end
    local ref = ('api-wd-%s-%s'):format(os.time(), math.random(100000,999999))
    local logged = pcall(function()
        MySQL.insert.await([[
            INSERT INTO bc_banking_v2_ledger
            (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
            SELECT id, ?, 'withdrawal', ?, balance, ?, ?
            FROM bc_banking_v2_accounts WHERE id = ? AND status = 'active'
        ]], { ref, -n, citizenid, tostring(description or 'External withdrawal'):sub(1,255), tonumber(accountId) })
    end)
    if not logged then
        MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { n, tonumber(accountId) })
        failIdempotency(idem, 'ledger_write_failed')
        return false, 'ledger_error'
    end
    completeIdempotency(idem, { success=true, reference=ref })
    logAudit(citizenid, 'account.withdraw_api', accountId, { amount=n, reference=ref })
    return true
end)

exports('CreateV2Account', function(citizenid, kind, name)
    if type(citizenid) ~= 'string' or #citizenid < 2 then return false end
    if kind ~= 'checking' and kind ~= 'savings' and kind ~= 'business' then return false end
    return createAccount(citizenid, kind, tostring(name or kind):sub(1,80), 0)
end)

exports('GetV2Ledger', function(accountId, citizenid, limit)
    local access = member(tonumber(accountId), citizenid)
    if not access then return {} end
    local perms = type(access.permissions) == 'table' and access.permissions or json.decode(access.permissions or '{}') or {}
    if perms.view ~= true and perms.statements ~= true then return {} end
    return MySQL.query.await('SELECT entry_type, amount, balance_after, description, created_at FROM bc_banking_v2_ledger WHERE account_id = ? ORDER BY id DESC LIMIT ?', { accountId, math.max(1, math.min(tonumber(limit) or 50, 200)) }) or {}
end)

print('[bc-banking] V2 account, savings, card, business, loan and integration APIs loaded.')


QBCore.Functions.CreateCallback('bc-banking:v2:getScheduledPayments', function(src, cb)
    local cid = cidFor(src)
    if not cid then cb({}); return end
    cb(MySQL.query.await('SELECT id, source_account_id, destination_account_id, amount, description, frequency, next_run_at, status FROM bc_banking_v2_scheduled_payments WHERE owner_citizenid = ? ORDER BY id DESC LIMIT 100', { cid }) or {})
end)

RegisterNetEvent('bc-banking:v2:createScheduledPayment', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local fromId, toId = tonumber(data.sourceAccountId), tonumber(data.destinationAccountId)
    local value = amount(data.amount, tonumber(Config.MaxTransfer) or 1000000)
    local frequency = tostring(data.frequency or 'once')
    if not fromId or not toId or fromId == toId or not value or not ({ once=true, weekly=true, monthly=true })[frequency] then return end
    local from, to = member(fromId, cid), member(toId, cid)
    if not from or not to then return end
    local perms = type(from.permissions) == 'table' and from.permissions or json.decode(from.permissions or '{}') or {}
    if not perms.transfer then return end
    local runAt = tostring(data.nextRunAt or '')
    if not runAt:match('^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$') then return end
    local id = MySQL.insert.await([[
        INSERT INTO bc_banking_v2_scheduled_payments
        (owner_citizenid, source_account_id, destination_account_id, amount, description, frequency, next_run_at, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'active')
    ]], { cid, fromId, toId, value, tostring(data.description or 'Scheduled payment'):sub(1,120), frequency, runAt })
    if id then
        logAudit(cid, 'payment.scheduled', id, { amount=value, frequency=frequency })
        TriggerClientEvent('bc-banking:client:notify', src, 'Scheduled payment created.', 'success')
    end
end)

RegisterNetEvent('bc-banking:v2:cancelScheduledPayment', function(data)
    local src, cid = source, cidFor(source)
    local id = type(data) == 'table' and tonumber(data.id)
    if not cid or not id then return end
    local changed = MySQL.update.await("UPDATE bc_banking_v2_scheduled_payments SET status = 'cancelled' WHERE id = ? AND owner_citizenid = ? AND status = 'active'", { id, cid })
    if changed and changed > 0 then logAudit(cid, 'payment.cancelled', id, {}) end
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

RegisterNetEvent('bc-banking:v2:repayLoan', function(data)
    local src, cid = source, cidFor(source)
    local id = type(data) == 'table' and tonumber(data.loanId)
    local value = type(data) == 'table' and amount(data.amount, 100000000)
    if not cid or not id or not value then return end
    local loan = MySQL.single.await("SELECT * FROM bc_banking_v2_loans WHERE id = ? AND citizenid = ? AND status = 'active'", { id, cid })
    if not loan then return end
    local idempotencyKey, idemState = claimIdempotency(cid, 'loan.repayment', data)
    if idemState == 'already_completed' then return end
    if not idempotencyKey then return end
    local due = tonumber(loan.balance_due) or 0
    if due <= 0 then failIdempotency(idempotencyKey, 'no_outstanding_balance'); return end
    if value > due then value = due end
    local player = playerFor(src)
    if not player or (tonumber(player.PlayerData.money.bank) or 0) < value then
        failIdempotency(idempotencyKey, 'insufficient_funds')
        TriggerClientEvent('bc-banking:client:notify', src, 'Insufficient bank funds for repayment.', 'error'); return
    end
    if not player.Functions.RemoveMoney('bank', value, 'bc-banking-loan-repayment') then
        failIdempotency(idempotencyKey, 'money_removal_failed'); return
    end
    local remaining = math.max(0, due - value)
    local changed = MySQL.update.await("UPDATE bc_banking_v2_loans SET balance_due = ?, status = ?, next_payment_at = IF(? <= 0, NULL, DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 1 MONTH)) WHERE id = ? AND citizenid = ? AND status = 'active' AND balance_due >= ?", { remaining, remaining <= 0 and 'paid' or 'active', remaining, id, cid, value })
    if not changed or changed < 1 then
        player.Functions.AddMoney('bank', value, 'bc-banking-loan-repayment-refund')
        failIdempotency(idempotencyKey, 'loan_update_failed')
        return
    end
    local auditOk = pcall(function()
        logAudit(cid, 'loan.repayment', id, { amount=value, remaining=remaining })
    end)
    if not auditOk then
        MySQL.update.await("UPDATE bc_banking_v2_loans SET balance_due = ?, status = 'active', next_payment_at = DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 1 MONTH) WHERE id = ? AND citizenid = ?", { due, id, cid })
        player.Functions.AddMoney('bank', value, 'bc-banking-loan-repayment-refund')
        failIdempotency(idempotencyKey, 'repayment_audit_failed')
        return
    end
    completeIdempotency(idempotencyKey, { success=true })
    TriggerClientEvent('bc-banking:client:notify', src, 'Loan repayment received.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

-- Interest is accrued once per account per server-local calendar day. A unique
-- account/date key makes repeated resource restarts safe against double credit.
local function accrueSavingsInterest()
    if not BCBanking.V2Ready then return end
    local rate = math.max(0, tonumber(Config.V2 and Config.V2.SavingsAPR) or 0)
    if rate <= 0 then return end
    local accounts = MySQL.query.await("SELECT id, balance, owner_citizenid FROM bc_banking_v2_accounts WHERE account_type = 'savings' AND status = 'active' AND balance > 0") or {}
    local date = os.date('%Y-%m-%d')
    for _, account in ipairs(accounts) do
        local interest = math.floor((tonumber(account.balance) * rate / 100 / 365) * 100 + 0.5) / 100
        if interest > 0 then
            -- The unique date row prevents duplicate accruals. The account and
            -- accrual row are then updated together in one atomic SQL statement.
            MySQL.insert.await([[
                INSERT IGNORE INTO bc_banking_v2_interest_accruals
                (account_id, accrual_date, annual_rate, amount, balance_after)
                VALUES (?, ?, ?, ?, 0)
            ]], { account.id, date, rate, interest })
            local accrued = MySQL.update.await([[
                UPDATE bc_banking_v2_accounts a
                JOIN bc_banking_v2_interest_accruals i ON i.account_id = a.id
                SET a.balance = a.balance + i.amount,
                    i.balance_after = a.balance + i.amount
                WHERE a.id = ? AND i.accrual_date = ? AND i.balance_after = 0
                  AND a.status = 'active'
            ]], { account.id, date })
            if accrued and accrued > 0 then
                -- A unique ledger reference prevents duplicate entries if the
                -- ledger insert is retried after the balance/accrual update.
                local ledgerOk = pcall(function()
                    MySQL.insert.await([[
                        INSERT IGNORE INTO bc_banking_v2_ledger
                        (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
                        SELECT a.id, ?, 'interest', i.amount, i.balance_after, a.owner_citizenid, 'Daily savings interest'
                        FROM bc_banking_v2_accounts a
                        JOIN bc_banking_v2_interest_accruals i ON i.account_id = a.id
                        WHERE a.id = ? AND i.accrual_date = ? AND i.balance_after > 0
                    ]], { ('int-%s-%s'):format(date, account.id), account.id, date })
                end)
                if ledgerOk then
                    logAudit(account.owner_citizenid, 'savings.interest_accrued', account.id, { amount=interest, date=date })
                end
            end
        end
    end
end
CreateThread(function()
    while true do
        Wait(3600000)
        local ok, err = pcall(accrueSavingsInterest)
        if not ok then print(('[bc-banking] Savings interest job failed: %s'):format(tostring(err))) end
    end
end)

-- Server-side payment source API for BC resources. Client requests never decide
-- whether funds exist; this export resolves the player's live QBCore balance.
exports('ChargePlayer', function(source, value, paymentSource, reason, idempotencyKey)
    if not BCBanking.V2Ready then return false, 'v2_not_ready' end
    local player = playerFor(source)
    local n = amount(value, tonumber(Config.V2 and Config.V2.MaxPayment) or 1000000)
    if not player or not n then return false, 'invalid_request' end

    -- Validate the requested tender and current funds before reserving the
    -- idempotency key. Rejected payment attempts must not leave a permanent
    -- "processing" key that blocks a later legitimate retry.
    local account = paymentSource == 'cash' and 'cash' or (paymentSource == 'bank' and 'bank' or nil)
    if not account then return false, 'invalid_payment_source' end
    if (tonumber(player.PlayerData.money[account]) or 0) < n then return false, 'insufficient_funds' end

    local cid = player.PlayerData.citizenid
    local idem, idemState = claimIdempotency(cid, 'player.charge', {
        idempotencyKey=idempotencyKey,
        amount=n,
        source=paymentSource,
        reason=reason
    })
    if idemState == 'already_completed' then return true end
    if not idem then return false, idemState end

    local removed = player.Functions.RemoveMoney(account, n, tostring(reason or 'BC Systems payment'):sub(1,100))
    if not removed then
        MySQL.update.await("UPDATE bc_banking_v2_idempotency SET status = 'failed' WHERE idempotency_key = ? AND status = 'processing'", { idem })
        return false, 'payment_failed'
    end

    completeIdempotency(idem, { success=true })
    pcall(function()
        exports['bc-banking']:AddTransaction(cid, 'payment_' .. account, n, tostring(reason or 'BC Systems payment'))
    end)
    return true
end)

exports('RecordBusinessExpense', function(businessId, actorCitizenid, value, category, description, idempotencyKey)
    if not BCBanking.V2Ready then return false, 'v2_not_ready' end
    local n = amount(value, tonumber(Config.V2 and Config.V2.MaxPayrollPayment) or 100000)
    if not n then return false, 'invalid_amount' end
    local business = MySQL.single.await([[
        SELECT b.account_id, m.permissions FROM bc_banking_v2_businesses b
        JOIN bc_banking_v2_business_members m ON m.business_id = b.id
        WHERE b.id = ? AND m.citizenid = ? AND m.status = 'active' AND b.status = 'active'
    ]], { businessId, actorCitizenid })
    if not business then return false, 'not_authorized' end
    local perms = type(business.permissions) == 'table' and business.permissions or json.decode(business.permissions or '{}') or {}
    if not perms.withdraw then return false, 'not_authorized' end
    local idem, idemState = claimIdempotency(actorCitizenid, 'business.expense', { idempotencyKey=idempotencyKey, businessId=businessId, amount=n, category=category, description=description })
    if idemState == 'already_completed' then return true end
    if not idem then return false, idemState end
    local changed = MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ? AND balance >= ? AND status = "active"', { n, business.account_id, n })
    if not changed or changed < 1 then failIdempotency(idem, 'insufficient_funds'); return false, 'insufficient_funds' end
    local ok, committed = pcall(function()
        return MySQL.transaction.await({
            {
                query = [[
                    INSERT INTO bc_banking_v2_business_expenses
                    (business_id, actor_citizenid, amount, category, description)
                    VALUES (?, ?, ?, ?, ?)
                ]],
                values = { businessId, actorCitizenid, n, tostring(category or 'general'):sub(1,48), tostring(description or 'Business expense'):sub(1,255) }
            },
            {
                query = [[
                    INSERT INTO bc_banking_v2_ledger
                    (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
                    SELECT id, ?, 'business_expense', ?, balance, ?, ?
                    FROM bc_banking_v2_accounts WHERE id = ?
                ]],
                values = { ('exp-%s-%s'):format(os.time(), math.random(100000,999999)), -n, actorCitizenid, tostring(description or 'Business expense'):sub(1,255), business.account_id }
            }
        })
    end)
    if not ok or committed ~= true then
        MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { n, business.account_id })
        failIdempotency(idem, 'recording_failed')
        return false, 'recording_failed'
    end
    completeIdempotency(idem, { success=true })
    logAudit(actorCitizenid, 'business.expense', businessId, { amount=n, category=category, description=description })
    return true
end)

exports('GetAccountStatement', function(accountId, citizenid, fromDate, toDate, limit)
    local access = member(tonumber(accountId), citizenid)
    if not access then return {} end
    local perms = type(access.permissions) == 'table' and access.permissions or json.decode(access.permissions or '{}') or {}
    if perms.view ~= true and perms.statements ~= true then return {} end
    local startDate = type(fromDate) == 'string' and fromDate:match('^%d%d%d%d%-%d%d%-%d%d$') and fromDate or '1000-01-01'
    local endDate = type(toDate) == 'string' and toDate:match('^%d%d%d%d%-%d%d%-%d%d$') and toDate or '9999-12-31'
    return MySQL.query.await([[
        SELECT transaction_ref, entry_type, amount, balance_after, description, created_at
        FROM bc_banking_v2_ledger
        WHERE account_id = ? AND created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
        ORDER BY id DESC LIMIT ?
    ]], { accountId, startDate, endDate, math.max(1, math.min(tonumber(limit) or 100, 500)) }) or {}
end)


local function processScheduledPayments()
    local due = MySQL.query.await([[
        SELECT * FROM bc_banking_v2_scheduled_payments
        WHERE status = 'active' AND next_run_at <= CURRENT_TIMESTAMP
        ORDER BY next_run_at ASC LIMIT 100
    ]]) or {}
    for _, payment in ipairs(due) do
        local claimed = MySQL.update.await([[
            UPDATE bc_banking_v2_scheduled_payments SET status = 'processing'
            WHERE id = ? AND status = 'active' AND next_run_at <= CURRENT_TIMESTAMP
        ]], { payment.id })
        if claimed and claimed > 0 then
            local ref = ('sch-%s-%s'):format(payment.id, os.time())
            local changed = MySQL.update.await([[
                UPDATE bc_banking_v2_accounts AS src
                JOIN bc_banking_v2_accounts AS dst ON dst.id = ?
                SET src.balance = src.balance - ?, dst.balance = dst.balance + ?
                WHERE src.id = ? AND src.status = 'active' AND dst.status = 'active'
                  AND src.balance >= ? AND src.id <> dst.id
            ]], { payment.destination_account_id, payment.amount, payment.amount, payment.source_account_id, payment.amount })
            if changed and changed >= 2 then
                local ok = pcall(function()
                    MySQL.insert.await([[
                        INSERT INTO bc_banking_v2_ledger
                        (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description, metadata)
                        SELECT id, ?, 'scheduled_out', ?, balance, ?, ?, ?
                        FROM bc_banking_v2_accounts WHERE id = ?
                    ]], { ref, payment.amount, payment.owner_citizenid, payment.description, json.encode({ payment_id=payment.id }), payment.source_account_id })
                    MySQL.insert.await([[
                        INSERT INTO bc_banking_v2_ledger
                        (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description, metadata)
                        SELECT id, ?, 'scheduled_in', ?, balance, ?, ?, ?
                        FROM bc_banking_v2_accounts WHERE id = ?
                    ]], { ref, payment.amount, payment.owner_citizenid, payment.description, json.encode({ payment_id=payment.id }), payment.destination_account_id })
                end)
                if ok then
                    if payment.frequency == 'weekly' then
                        MySQL.update.await("UPDATE bc_banking_v2_scheduled_payments SET status = 'active', next_run_at = DATE_ADD(next_run_at, INTERVAL 7 DAY) WHERE id = ?", { payment.id })
                    elseif payment.frequency == 'monthly' then
                        MySQL.update.await("UPDATE bc_banking_v2_scheduled_payments SET status = 'active', next_run_at = DATE_ADD(next_run_at, INTERVAL 1 MONTH) WHERE id = ?", { payment.id })
                    else
                        MySQL.update.await("UPDATE bc_banking_v2_scheduled_payments SET status = 'completed' WHERE id = ?", { payment.id })
                    end
                    logAudit(payment.owner_citizenid, 'scheduled_payment.executed', payment.id, { amount=payment.amount, frequency=payment.frequency, reference=ref })
                else
                    MySQL.update.await([[
                        UPDATE bc_banking_v2_accounts AS src
                        JOIN bc_banking_v2_accounts AS dst ON dst.id = ?
                        SET src.balance = src.balance + ?, dst.balance = dst.balance - ?
                        WHERE src.id = ?
                    ]], { payment.destination_account_id, payment.amount, payment.amount, payment.source_account_id })
                    MySQL.update.await('DELETE FROM bc_banking_v2_ledger WHERE transaction_ref = ?', { ref })
                    MySQL.update.await("UPDATE bc_banking_v2_scheduled_payments SET status = 'failed' WHERE id = ?", { payment.id })
                end
            else
                MySQL.update.await("UPDATE bc_banking_v2_scheduled_payments SET status = 'failed' WHERE id = ?", { payment.id })
            end
        end
    end
end

CreateThread(function()
    Wait(5000)
    if BCBanking.V2Ready then
        local ok, err = pcall(function()
            MySQL.update.await("UPDATE bc_banking_v2_scheduled_payments SET status = 'failed' WHERE status = 'processing'")
        end)
        if not ok then print(('[bc-banking] Scheduled payment recovery check failed: %s'):format(tostring(err))) end
    end
    while true do
        Wait(60000)
        if BCBanking.V2Ready then
            local ok, err = pcall(processScheduledPayments)
            if not ok then print(('[bc-banking] Scheduled payment processor failed: %s'):format(tostring(err))) end
        end
    end
end)


RegisterNetEvent('bc-banking:v2:setCardPin', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local cardId, pin = tonumber(data.cardId), tostring(data.pin or '')
    if not cardId or not pin:match('^%d%d%d%d%d?%d?$') then
        TriggerClientEvent('bc-banking:client:notify', src, 'PIN must contain 4 to 6 digits.', 'error'); return
    end
    local card = MySQL.single.await("SELECT id FROM bc_banking_v2_cards WHERE id = ? AND citizenid = ? AND status = 'active'", { cardId, cid })
    if not card then return end
    local salt = tostring(math.random(100000,999999)) .. tostring(os.time()) .. tostring(math.random(100000,999999))
    local changed = MySQL.query.await([[
        INSERT INTO bc_banking_v2_card_secrets (card_id, pin_salt, pin_hash, pin_attempts, pin_locked_until)
        VALUES (?, ?, SHA2(CONCAT(?, ?, ?), 256), 0, NULL)
        ON DUPLICATE KEY UPDATE pin_salt = VALUES(pin_salt), pin_hash = VALUES(pin_hash),
            pin_attempts = 0, pin_locked_until = NULL
    ]], { cardId, salt, pin, salt, tostring(Config.V2 and Config.V2.CardPepper or '') })
    if changed ~= nil then
        logAudit(cid, 'card.pin_changed', cardId, {})
        TriggerClientEvent('bc-banking:client:notify', src, 'Card PIN updated.', 'success')
    end
end)

RegisterNetEvent('bc-banking:v2:replaceCard', function(data)
    local src, cid = source, cidFor(source)
    local oldId = type(data) == 'table' and tonumber(data.cardId)
    if not cid or not oldId then return end
    local card = MySQL.single.await("SELECT account_id, card_type FROM bc_banking_v2_cards WHERE id = ? AND citizenid = ? AND status IN ('active','frozen')", { oldId, cid })
    if not card then return end
    local nonce, salt = '', tostring(math.random(100000,999999)) .. tostring(os.time()) .. tostring(math.random(100000,999999))
    for _ = 1, 32 do nonce = nonce .. tostring(math.random(0,9)) end
    local last4 = nonce:sub(-4)
    local newId = MySQL.insert.await([[INSERT INTO bc_banking_v2_cards
        (citizenid, account_id, card_hash, card_last4, card_type, status, expires_at)
        VALUES (?, ?, SHA2(CONCAT(?, ?, ?), 256), ?, ?, 'active', DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 4 YEAR))
    ]], { cid, card.account_id, nonce, salt, tostring(Config.V2 and Config.V2.CardPepper or ''), last4, card.card_type })
    if not newId then
        TriggerClientEvent('bc-banking:client:notify', src, 'Replacement card could not be created; your existing card remains unchanged.', 'error')
        return
    end
    local secretOk = pcall(function()
        MySQL.insert.await('INSERT INTO bc_banking_v2_card_secrets (card_id, pin_salt) VALUES (?, ?)', { newId, salt })
    end)
    if not secretOk then
        MySQL.update.await('DELETE FROM bc_banking_v2_cards WHERE id = ? AND citizenid = ?', { newId, cid })
        TriggerClientEvent('bc-banking:client:notify', src, 'Replacement card setup failed; your existing card remains unchanged.', 'error')
        return
    end
    local retired = MySQL.update.await("UPDATE bc_banking_v2_cards SET status = 'replaced' WHERE id = ? AND citizenid = ? AND status IN ('active','frozen')", { oldId, cid })
    if not retired or retired < 1 then
        MySQL.update.await('DELETE FROM bc_banking_v2_cards WHERE id = ? AND citizenid = ?', { newId, cid })
        TriggerClientEvent('bc-banking:client:notify', src, 'Your existing card changed before replacement completed. No replacement was issued.', 'error')
        return
    end
    local itemDelivered = card.card_type ~= 'physical' or givePhysicalCardItem(src, newId, last4)
    logAudit(cid, 'card.replaced', oldId, { new_card_id=newId, last4=last4, card_type=card.card_type, inventory_item_delivered=itemDelivered })
    local notice = 'Replacement card issued ending in ' .. last4 .. '.'
    if card.card_type == 'physical' and Config.V2.CardItem and Config.V2.CardItem.Enabled and not itemDelivered then
        notice = notice .. ' Inventory item delivery failed; check ox_inventory item setup.'
    end
    TriggerClientEvent('bc-banking:client:notify', src, notice, itemDelivered and 'success' or 'error')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

exports('VerifyCardPin', function(cardId, citizenid, pin)
    if not BCBanking.V2Ready then return false end
    pin = tostring(pin or '')
    if not tostring(pin):match('^%d%d%d%d%d?%d?$') then return false end
    local row = MySQL.single.await([[
        SELECT c.id, s.pin_salt, s.pin_hash, s.pin_attempts, s.pin_locked_until
        FROM bc_banking_v2_cards c
        JOIN bc_banking_v2_card_secrets s ON s.card_id = c.id
        WHERE c.id = ? AND c.citizenid = ? AND c.status = 'active'
        LIMIT 1
    ]], { cardId, citizenid })
    if not row or not row.pin_hash then return false end
    if row.pin_locked_until and tostring(row.pin_locked_until) > os.date('%Y-%m-%d %H:%M:%S') then return false end
    local valid = MySQL.scalar.await([[
        SELECT (pin_hash = SHA2(CONCAT(?, pin_salt, ?), 256))
        FROM bc_banking_v2_card_secrets WHERE card_id = ?
    ]], { pin, tostring(Config.V2 and Config.V2.CardPepper or ''), cardId })
    if tonumber(valid) == 1 then
        MySQL.update.await('UPDATE bc_banking_v2_card_secrets SET pin_attempts = 0, pin_locked_until = NULL WHERE card_id = ?', { cardId })
        return true
    end
    MySQL.update.await([[
        UPDATE bc_banking_v2_card_secrets
        SET pin_attempts = pin_attempts + 1,
            pin_locked_until = IF(pin_attempts + 1 >= 5, DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 15 MINUTE), pin_locked_until)
        WHERE card_id = ?
    ]], { cardId })
    return false
end)


QBCore.Functions.CreateCallback('bc-banking:v2:getLedger', function(src, cb, accountId)
    local cid = cidFor(src)
    if not cid or not tonumber(accountId) then cb({}); return end
    cb(exports['bc-banking']:GetV2Ledger(tonumber(accountId), cid, 50))
end)

RegisterNetEvent('bc-banking:v2:fundAccount', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local accountId, value = tonumber(data.accountId), amount(data.amount, tonumber(Config.MaxDeposit) or 1000000)
    local sourceType = data.source == 'cash' and 'cash' or (data.source == 'bank' and 'bank' or nil)
    local usingATM = isNearConfiguredATM(src)
    local fee = usingATM and BCBanking.RoundMoney(Config.V2 and Config.V2.ATMDepositFee or 0) or 0
    local total = value and (value + fee) or 0
    if not accountId or not value or not sourceType or fee < 0 then return end
    local access = member(accountId, cid)
    if not access then return end
    local perms = type(access.permissions) == 'table' and access.permissions or json.decode(access.permissions or '{}') or {}
    if not perms.deposit then return end
    local idempotencyKey, idemState = claimIdempotency(cid, 'account.deposit', data)
    if idemState == 'already_completed' then TriggerClientEvent('bc-banking:client:notify', src, 'This deposit was already processed.', 'success'); return end
    if not idempotencyKey then TriggerClientEvent('bc-banking:client:notify', src, 'Deposit request rejected: ' .. tostring(idemState), 'error'); return end
    local player = playerFor(src)
    if not player then failIdempotency(idempotencyKey, 'player_unavailable'); return end
    local ok, message = BCBanking.WithPlayerLocks({ cid }, function()
        if (tonumber(player.PlayerData.money[sourceType]) or 0) < total then return false, 'Insufficient funds for the deposit and ATM fee.' end
        if not player.Functions.RemoveMoney(sourceType, total, 'bc-banking-v2-account-deposit') then return false, 'Money could not be removed.' end
        local changed = MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ? AND status = "active"', { value, accountId })
        if not changed or changed < 1 then
            player.Functions.AddMoney(sourceType, total, 'bc-banking-v2-account-deposit-refund')
            return false, 'Deposit failed and was reversed.'
        end
        local logged = pcall(function()
            MySQL.insert.await([[
                INSERT INTO bc_banking_v2_ledger (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
                SELECT id, ?, 'deposit', ?, balance, ?, ? FROM bc_banking_v2_accounts WHERE id = ?
            ]], { ('fund-%s-%s'):format(os.time(), math.random(100000,999999)), value, cid, 'Deposit from ' .. sourceType, accountId })
        end)
        if not logged then
            MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ?', { value, accountId })
            player.Functions.AddMoney(sourceType, total, 'bc-banking-v2-account-deposit-refund')
            return false, 'Deposit could not be recorded and was reversed.'
        end
        completeIdempotency(idempotencyKey, { success=true })
        logAudit(cid, 'account.deposit', accountId, { amount=value, source=sourceType, atm=usingATM, fee=fee })
        if fee > 0 then pcall(function() exports['bc-banking']:AddTransaction(cid, 'fee', fee, 'V2 ATM deposit fee') end) end
        return true, 'Account funded.'
    end)
    if not ok then failIdempotency(idempotencyKey, message or 'deposit_failed') end
    TriggerClientEvent('bc-banking:client:notify', src, message or (ok and 'Account funded.' or 'Deposit failed.'), ok and 'success' or 'error')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

RegisterNetEvent('bc-banking:v2:withdrawAccount', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local accountId, value = tonumber(data.accountId), amount(data.amount, tonumber(Config.MaxWithdrawal) or 1000000)
    local destination = data.destination == 'cash' and 'cash' or (data.destination == 'bank' and 'bank' or nil)
    local usingATM = isNearConfiguredATM(src)
    local fee = usingATM and BCBanking.RoundMoney(Config.V2 and Config.V2.ATMWithdrawalFee or 0) or 0
    local total = value and (value + fee) or 0
    if not accountId or not value or not destination or fee < 0 then return end
    local access = member(accountId, cid)
    if not access then return end
    local perms = type(access.permissions) == 'table' and access.permissions or json.decode(access.permissions or '{}') or {}
    if not perms.withdraw then return end
    local idempotencyKey, idemState = claimIdempotency(cid, 'account.withdraw', data)
    if idemState == 'already_completed' then TriggerClientEvent('bc-banking:client:notify', src, 'This withdrawal was already processed.', 'success'); return end
    if not idempotencyKey then TriggerClientEvent('bc-banking:client:notify', src, 'Withdrawal request rejected: ' .. tostring(idemState), 'error'); return end
    local player = playerFor(src)
    if not player then failIdempotency(idempotencyKey, 'player_unavailable'); return end
    local ok, message = BCBanking.WithPlayerLocks({ cid }, function()
        local changed = MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ? AND status = "active" AND balance >= ?', { total, accountId, total })
        if not changed or changed < 1 then return false, 'Insufficient account funds for the withdrawal and ATM fee.' end
        if not player.Functions.AddMoney(destination, value, 'bc-banking-v2-account-withdrawal') then
            MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { total, accountId })
            return false, 'Withdrawal failed and was reversed.'
        end
        local withdrawalRef = ('cashout-%s-%s'):format(os.time(), math.random(100000,999999))
        local feeRef = ('atmfee-%s-%s'):format(os.time(), math.random(100000,999999))
        local logged = pcall(function()
            MySQL.insert.await([[
                INSERT INTO bc_banking_v2_ledger (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
                SELECT id, ?, 'withdrawal', ?, balance, ?, ? FROM bc_banking_v2_accounts WHERE id = ?
            ]], { withdrawalRef, -value, cid, 'Withdrawal to ' .. destination, accountId })
            if fee > 0 then
                MySQL.insert.await([[
                    INSERT INTO bc_banking_v2_ledger (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
                    SELECT id, ?, 'fee', ?, balance, ?, 'ATM withdrawal fee' FROM bc_banking_v2_accounts WHERE id = ?
                ]], { feeRef, -fee, cid, accountId })
            end
        end)
        if not logged then
            player.Functions.RemoveMoney(destination, value, 'bc-banking-v2-account-withdrawal-reversal')
            MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { total, accountId })
            MySQL.update.await('DELETE FROM bc_banking_v2_ledger WHERE transaction_ref IN (?, ?)', { withdrawalRef, feeRef })
            return false, 'Withdrawal could not be recorded and was reversed.'
        end
        completeIdempotency(idempotencyKey, { success=true })
        logAudit(cid, 'account.withdraw', accountId, { amount=value, destination=destination, atm=usingATM, fee=fee })
        if fee > 0 then pcall(function() exports['bc-banking']:AddTransaction(cid, 'fee', fee, 'V2 ATM withdrawal fee') end) end
        return true, 'Withdrawal completed.'
    end)
    if not ok then failIdempotency(idempotencyKey, message or 'withdrawal_failed') end
    TriggerClientEvent('bc-banking:client:notify', src, message or (ok and 'Withdrawal completed.' or 'Withdrawal failed.'), ok and 'success' or 'error')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)


RegisterCommand('bcbankaccount', function(src, args)
    if not BCBanking.V2Ready then print('[bc-banking] V2 database is not ready.'); return end
    if src ~= 0 and not IsPlayerAceAllowed(src, 'bc-banking.admin') then return end
    local id, action = tonumber(args[1]), tostring(args[2] or '')
    if not id or (action ~= 'freeze' and action ~= 'unfreeze' and action ~= 'close' and action ~= 'reopen') then
        print('Usage: bcbankaccount <accountId> <freeze|unfreeze|close|reopen>'); return
    end
    local status = ({ freeze='frozen', unfreeze='active', close='closed', reopen='active' })[action]
    local account = MySQL.single.await('SELECT id, owner_citizenid, status FROM bc_banking_v2_accounts WHERE id = ?', { id })
    if not account then print('[bc-banking] V2 account not found.'); return end
    local changed = MySQL.update.await('UPDATE bc_banking_v2_accounts SET status = ? WHERE id = ?', { status, id })
    if changed and changed > 0 then
        logAudit(src == 0 and 'SERVER_CONSOLE' or (cidFor(src) or 'UNKNOWN'), 'admin.account_' .. action, id, { previous=account.status, current=status })
        print(('[bc-banking] Account %s status changed to %s.'):format(id, status))
    end
end, true)

RegisterCommand('bcbankaudit', function(src, args)
    if not BCBanking.V2Ready then print('[bc-banking] V2 database is not ready.'); return end
    if src ~= 0 and not IsPlayerAceAllowed(src, 'bc-banking.admin') then return end
    local citizenid = tostring(args[1] or '')
    if #citizenid < 2 then print('Usage: bcbankaudit <citizenid>'); return end
    local rows = MySQL.query.await([[
        SELECT actor_citizenid, action, target_type, target_id, details, created_at
        FROM bc_banking_v2_audit
        WHERE actor_citizenid = ? OR (target_type = 'account' AND target_id IN (
            SELECT CAST(id AS CHAR) FROM bc_banking_v2_accounts WHERE owner_citizenid = ?
        ))
        ORDER BY id DESC LIMIT 25
    ]], { citizenid, citizenid }) or {}
    print(('[bc-banking] Audit records for %s: %s'):format(citizenid, #rows))
    for _, row in ipairs(rows) do
        print(('%s | %s | %s:%s | %s'):format(tostring(row.created_at), row.action, row.target_type, row.target_id, tostring(row.details or '{}')))
    end
end, true)

exports('SetV2AccountStatus', function(accountId, status, actor)
    if not BCBanking.V2Ready then return false end
    if not ({ active=true, frozen=true, closed=true })[status] then return false end
    local changed = MySQL.update.await('UPDATE bc_banking_v2_accounts SET status = ? WHERE id = ?', { status, accountId })
    if changed and changed > 0 then
        logAudit(tostring(actor or 'SYSTEM'), 'account.status_changed', accountId, { status=status })
        return true
    end
    return false
end)


QBCore.Functions.CreateCallback('bc-banking:v2:getBusinessLoans', function(src, cb)
    local cid = cidFor(src)
    if not cid then cb({}); return end
    cb(MySQL.query.await([[
        SELECT l.id, l.business_id, b.name AS business_name, l.principal, l.apr,
               l.term_months, l.monthly_payment, l.balance_due, l.status,
               l.created_at, l.reviewed_at
        FROM bc_banking_v2_business_loans l
        JOIN bc_banking_v2_businesses b ON b.id = l.business_id
        JOIN bc_banking_v2_business_members m ON m.business_id = b.id
        WHERE m.citizenid = ? AND m.status = 'active'
          AND JSON_UNQUOTE(JSON_EXTRACT(m.permissions, '$.view')) = 'true'
        ORDER BY l.id DESC
    ]], { cid }) or {})
end)

RegisterNetEvent('bc-banking:v2:applyBusinessLoan', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local businessId = tonumber(data.businessId)
    local principal = amount(data.amount, tonumber(Config.V2 and Config.V2.MaxLoan) or 500000)
    local months = math.floor(tonumber(data.months) or 0)
    if not businessId or not principal or months < 1 or months > (tonumber(Config.V2 and Config.V2.MaxLoanMonths) or 24) then return end
    local owner = MySQL.single.await("SELECT id FROM bc_banking_v2_business_members WHERE business_id = ? AND citizenid = ? AND role = 'owner' AND status = 'active'", { businessId, cid })
    if not owner then TriggerClientEvent('bc-banking:client:notify', src, 'Only the business owner can apply for a business loan.', 'error'); return end
    local rate = math.max(0, tonumber(Config.V2 and Config.V2.LoanAPR) or 5)
    local id, err = BCBanking.WithPlayerLocks({ cid }, function()
        local open = tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM bc_banking_v2_business_loans WHERE business_id = ? AND status IN ('pending','active','processing')", { businessId }) or 0)
        if open > 0 then return nil, 'This business already has an open loan.' end
        return MySQL.insert.await([[
            INSERT INTO bc_banking_v2_business_loans (business_id, applicant_citizenid, principal, apr, term_months, status)
            VALUES (?, ?, ?, ?, ?, 'pending')
        ]], { businessId, cid, principal, rate, months })
    end)
    if not id then
        TriggerClientEvent('bc-banking:client:notify', src, err or 'Business loan application could not be submitted.', 'error')
        return
    end
    logAudit(cid, 'business_loan.applied', id, { business_id=businessId, principal=principal, term=months })
    TriggerClientEvent('bc-banking:client:notify', src, 'Business loan application submitted.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

RegisterNetEvent('bc-banking:v2:repayBusinessLoan', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local loanId = tonumber(data.loanId)
    local value = amount(data.amount, 100000000)
    if not loanId or not value then return end
    local loan = MySQL.single.await([[
        SELECT l.*, b.account_id FROM bc_banking_v2_business_loans l
        JOIN bc_banking_v2_businesses b ON b.id = l.business_id
        JOIN bc_banking_v2_business_members m ON m.business_id = b.id
        WHERE l.id = ? AND m.citizenid = ? AND m.role = 'owner'
          AND m.status = 'active' AND l.status = 'active'
        LIMIT 1
    ]], { loanId, cid })
    if not loan then return end
    local idempotencyKey, idemState = claimIdempotency(cid, 'business_loan.repayment', data)
    if idemState == 'already_completed' then return end
    if not idempotencyKey then return end
    local due = tonumber(loan.balance_due) or 0
    if due <= 0 then failIdempotency(idempotencyKey, 'no_outstanding_balance'); return end
    if value > due then value = due end
    local debited = MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ? AND balance >= ? AND status = "active"', { value, loan.account_id, value })
    if not debited or debited < 1 then
        failIdempotency(idempotencyKey, 'insufficient_business_funds')
        TriggerClientEvent('bc-banking:client:notify', src, 'Insufficient business account funds.', 'error'); return
    end
    local remaining = math.max(0, due - value)
    local changed = MySQL.update.await("UPDATE bc_banking_v2_business_loans SET balance_due = ?, status = ? WHERE id = ? AND status = 'active' AND balance_due >= ?", { remaining, remaining <= 0 and 'paid' or 'active', loanId, value })
    if not changed or changed < 1 then
        MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { value, loan.account_id })
        failIdempotency(idempotencyKey, 'loan_update_failed')
        return
    end
    local balance = MySQL.scalar.await('SELECT balance FROM bc_banking_v2_accounts WHERE id = ?', { loan.account_id })
    local ledgerOk = pcall(function()
        MySQL.insert.await([[
            INSERT INTO bc_banking_v2_ledger (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description, metadata)
            VALUES (?, ?, 'loan_repayment', ?, ?, ?, 'Business loan repayment', ?)
        ]], { loan.account_id, ('bizloan-%s-%s-%s'):format(loanId, os.time(), math.random(100000,999999)), value, balance, cid, json.encode({ loan_id=loanId }) })
    end)
    if not ledgerOk then
        MySQL.update.await("UPDATE bc_banking_v2_business_loans SET balance_due = ?, status = 'active' WHERE id = ? AND status IN ('active','paid')", { due, loanId })
        MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { value, loan.account_id })
        failIdempotency(idempotencyKey, 'repayment_ledger_failed')
        return
    end
    completeIdempotency(idempotencyKey, { success=true })
    logAudit(cid, 'business_loan.repayment', loanId, { amount=value, remaining=remaining })
    TriggerClientEvent('bc-banking:client:notify', src, 'Business loan repayment received.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

RegisterCommand('bcbankbusinessloan', function(src, args)
    if not BCBanking.V2Ready then print('[bc-banking] V2 database is not ready.'); return end
    if src ~= 0 and not IsPlayerAceAllowed(src, 'bc-banking.admin') then return end
    local id, decision = tonumber(args[1]), tostring(args[2] or '')
    if not id or (decision ~= 'approve' and decision ~= 'reject') then
        print('Usage: bcbankbusinessloan <applicationId> <approve|reject>'); return
    end
    local loan = MySQL.single.await("SELECT * FROM bc_banking_v2_business_loans WHERE id = ? AND status = 'pending'", { id })
    if not loan then print('[bc-banking] Pending business loan not found.'); return end
    if decision == 'reject' then
        MySQL.update.await("UPDATE bc_banking_v2_business_loans SET status = 'rejected', reviewed_at = CURRENT_TIMESTAMP WHERE id = ?", { id })
    else
        local claimed = MySQL.update.await("UPDATE bc_banking_v2_business_loans SET status = 'processing' WHERE id = ? AND status = 'pending'", { id })
        if not claimed or claimed < 1 then print('[bc-banking] Business loan application is no longer pending.'); return end
        local business = MySQL.single.await("SELECT account_id FROM bc_banking_v2_businesses WHERE id = ? AND status = 'active'", { loan.business_id })
        if not business or not business.account_id then MySQL.update.await("UPDATE bc_banking_v2_business_loans SET status = 'pending' WHERE id = ? AND status = 'processing'", { id }); print('[bc-banking] Business account unavailable; loan left pending.'); return end
        local changed = MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ? AND status = "active"', { loan.principal, business.account_id })
        if not changed or changed < 1 then MySQL.update.await("UPDATE bc_banking_v2_business_loans SET status = 'pending' WHERE id = ? AND status = 'processing'", { id }); print('[bc-banking] Business loan disbursement failed.'); return end
        local monthly = loan.principal * (1 + (loan.apr / 100) * (loan.term_months / 12)) / loan.term_months
        local total = loan.principal * (1 + (loan.apr / 100) * (loan.term_months / 12))
        MySQL.update.await("UPDATE bc_banking_v2_business_loans SET status = 'active', monthly_payment = ?, balance_due = ?, reviewed_at = CURRENT_TIMESTAMP, next_payment_at = DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 1 MONTH) WHERE id = ? AND status = 'processing'", { monthly, total, id })
        local finalized = MySQL.scalar.await("SELECT status FROM bc_banking_v2_business_loans WHERE id = ?", { id })
        if finalized ~= 'active' then
            MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ?', { loan.principal, business.account_id })
            MySQL.update.await("UPDATE bc_banking_v2_business_loans SET status = 'pending' WHERE id = ? AND status = 'processing'", { id })
            print('[bc-banking] Business loan activation failed; disbursement reversed.')
            return
        end
        local balance = MySQL.scalar.await('SELECT balance FROM bc_banking_v2_accounts WHERE id = ?', { business.account_id })
        local ledgerOk = pcall(function()
            MySQL.insert.await([[
                INSERT INTO bc_banking_v2_ledger (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description, metadata)
                VALUES (?, ?, 'loan_disbursement', ?, ?, ?, 'Business loan disbursement', ?)
            ]], { business.account_id, ('bizloan-start-%s'):format(id), loan.principal, balance, loan.applicant_citizenid, json.encode({ loan_id=id }) })
        end)
        if not ledgerOk then
            MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ?', { loan.principal, business.account_id })
            MySQL.update.await("UPDATE bc_banking_v2_business_loans SET status = 'pending', monthly_payment = 0, balance_due = 0, reviewed_at = NULL, next_payment_at = NULL WHERE id = ? AND status = 'active'", { id })
            print('[bc-banking] Business loan ledger write failed; disbursement was reversed.')
            return
        end
    end
    logAudit(src == 0 and 'SERVER_CONSOLE' or (cidFor(src) or 'UNKNOWN'), 'business_loan.' .. decision, id, { business_id=loan.business_id, applicant=loan.applicant_citizenid })
    print(('[bc-banking] Business loan %s %s.'):format(id, decision))
end, true)


QBCore.Functions.CreateCallback('bc-banking:v2:getBusinessExpenses', function(src, cb, businessId)
    local cid = cidFor(src)
    businessId = tonumber(businessId)
    if not cid or not businessId then cb({}); return end
    local membership = MySQL.single.await("SELECT permissions FROM bc_banking_v2_business_members WHERE business_id = ? AND citizenid = ? AND status = 'active'", { businessId, cid })
    if not membership then cb({}); return end
    local permissions = type(membership.permissions) == 'table' and membership.permissions or json.decode(membership.permissions or '{}') or {}
    if not permissions.view then cb({}); return end
    cb(MySQL.query.await([[
        SELECT id, amount, category, description, actor_citizenid, created_at
        FROM bc_banking_v2_business_expenses WHERE business_id = ?
        ORDER BY id DESC LIMIT 50
    ]], { businessId }) or {})
end)

RegisterNetEvent('bc-banking:v2:businessExpense', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local ok, reason = exports['bc-banking']:RecordBusinessExpense(
        tonumber(data.businessId), cid, tonumber(data.amount),
        tostring(data.category or 'general'), tostring(data.description or 'Business expense'),
        data.idempotencyKey
    )
    TriggerClientEvent('bc-banking:client:notify', src, ok and 'Business expense recorded.' or ('Expense failed: ' .. tostring(reason)), ok and 'success' or 'error')
    if ok then TriggerClientEvent('bc-banking:client:v2:refresh', src) end
end)
