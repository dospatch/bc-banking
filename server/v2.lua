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
    return nil, previous and previous.request_hash ~= requestHash and 'idempotency_conflict' or 'already_processing'
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
    MySQL.insert.await([[
        INSERT INTO bc_banking_v2_audit (actor_citizenid, action, target_type, target_id, details)
        VALUES (?, ?, ?, ?, ?)
    ]], { actor, action, 'account', tostring(target or ''), json.encode(details or {}) })
end
local function createAccount(citizenid, kind, name, initial)
    if not BCBanking.V2Ready then return nil, 'V2 database is not ready.' end
    local number = accountNumber()
    if not number then return nil, 'Could not allocate an account number.' end
    local id = MySQL.insert.await([[
        INSERT INTO bc_banking_v2_accounts
        (account_number, account_type, display_name, owner_citizenid, balance, status)
        VALUES (?, ?, ?, ?, ?, 'active')
    ]], { number, kind, name, initial or 0 })
    if not id then return nil, 'Account creation failed.' end
    MySQL.insert.await([[
        INSERT INTO bc_banking_v2_account_members
        (account_id, citizenid, role, permissions, status)
        VALUES (?, ?, 'owner', ?, 'active')
    ]], { id, citizenid, json.encode({ view=true, deposit=true, withdraw=true, transfer=true, manage=true, statements=true }) })
    return MySQL.single.await('SELECT * FROM bc_banking_v2_accounts WHERE id = ?', { id })
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
        ORDER BY a.id ASC
    ]], { cid }) or {})
end)

RegisterNetEvent('bc-banking:v2:createAccount', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local kind = tostring(data.type or 'checking')
    local allowed = { checking=true, savings=true }
    if not allowed[kind] then TriggerClientEvent('bc-banking:client:notify', src, 'Invalid account type.', 'error'); return end
    local count = tonumber(MySQL.scalar.await([[
        SELECT COUNT(*) FROM bc_banking_v2_account_members m JOIN bc_banking_v2_accounts a ON a.id = m.account_id WHERE m.citizenid = ? AND m.status = 'active' AND a.account_type IN ('checking','savings')
    ]], { cid }) or 0)
    local cap = tonumber(Config.V2 and Config.V2.MaxPersonalAccounts) or 5
    if count >= cap then TriggerClientEvent('bc-banking:client:notify', src, 'You have reached your account limit.', 'error'); return end
    local name = tostring(data.name or (kind == 'savings' and 'Savings Account' or 'Checking Account')):sub(1, 80)
    local account, err = createAccount(cid, kind, name, 0)
    if not account then TriggerClientEvent('bc-banking:client:notify', src, err, 'error'); return end
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
    local idempotencyKey, idemState = claimIdempotency(cid, 'account.transfer', data)
    if idemState == 'already_completed' then TriggerClientEvent('bc-banking:client:notify', src, 'This transfer was already processed.', 'success'); return end
    if not idempotencyKey then TriggerClientEvent('bc-banking:client:notify', src, 'Transfer request rejected: ' .. tostring(idemState), 'error'); return end
    local permissions = type(from.permissions) == 'table' and from.permissions or json.decode(from.permissions or '{}') or {}
    if not permissions.transfer or tonumber(from.id) == tonumber(to.id) then return end
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
        TriggerClientEvent('bc-banking:client:notify', src, 'Insufficient checking balance.', 'error'); return
    end
    local removed = player.Functions.RemoveMoney('bank', value, 'bc-banking-savings-goal')
    if not removed then return end
    local updated = MySQL.update.await("UPDATE bc_banking_v2_savings_goals SET status = IF(current_amount + ? >= target_amount, 'completed', status), current_amount = current_amount + ? WHERE id = ? AND citizenid = ?", { value, value, goalId, cid })
    if not updated then
        player.Functions.AddMoney('bank', value, 'bc-banking-savings-goal-refund')
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
        VALUES (?, ?, SHA2(CONCAT(?, ?, ?), 256), ?, 'debit', 'active', DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 4 YEAR))
    ]], { cid, accountId, nonce, salt, tostring(Config.V2 and Config.V2.CardPepper or ''), last4 })
    if id then
        MySQL.insert.await('INSERT INTO bc_banking_v2_card_secrets (card_id, pin_salt) VALUES (?, ?)', { id, salt })
        logAudit(cid, 'card.issued', id, { last4=last4 })
        TriggerClientEvent('bc-banking:client:notify', src, 'Card issued ending in ' .. last4 .. '. Card number is not recoverable.', 'success')
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
    local open = tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM bc_banking_v2_loans WHERE citizenid = ? AND status IN ('pending','approved','active')", { cid }) or 0)
    if open > 0 then TriggerClientEvent('bc-banking:client:notify', src, 'You already have an open loan application or loan.', 'error'); return end
    local rate = math.max(0, tonumber(Config.V2 and Config.V2.LoanAPR) or 5)
    local id = MySQL.insert.await([[
        INSERT INTO bc_banking_v2_loans (citizenid, principal, apr, term_months, status)
        VALUES (?, ?, ?, ?, 'pending')
    ]], { cid, principal, rate, months })
    if id then
        logAudit(cid, 'loan.applied', id, { principal=principal, months=months, apr=rate })
        TriggerClientEvent('bc-banking:client:notify', src, 'Loan application submitted for review.', 'success')
    end
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
    MySQL.update.await('UPDATE bc_banking_v2_businesses SET account_id = ? WHERE id = ?', { account.id, id })
    MySQL.insert.await('INSERT INTO bc_banking_v2_business_members (business_id, citizenid, role, permissions, status) VALUES (?, ?, "owner", ?, "active")', { id, cid, json.encode({ view=true, deposit=true, withdraw=true, transfer=true, payroll=true, manage=true }) })
    logAudit(cid, 'business.created', id, { name=name })
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
    local perms = { view=data.permissions and data.permissions.view == true, deposit=data.permissions and data.permissions.deposit == true, withdraw=data.permissions and data.permissions.withdraw == true, transfer=data.permissions and data.permissions.transfer == true, payroll=data.permissions and data.permissions.payroll == true, manage=false }
    local businessAccount = MySQL.scalar.await('SELECT account_id FROM bc_banking_v2_businesses WHERE id = ?', { businessId })
    MySQL.insert.await([[
        INSERT INTO bc_banking_v2_business_members (business_id, citizenid, role, permissions, status)
        VALUES (?, ?, 'employee', ?, 'active')
        ON DUPLICATE KEY UPDATE permissions = VALUES(permissions), status = 'active'
    ]], { businessId, employeeCid, json.encode(perms) })
    if businessAccount then
        MySQL.insert.await([[
            INSERT INTO bc_banking_v2_account_members (account_id, citizenid, role, permissions, status)
            VALUES (?, ?, 'employee', ?, 'active')
            ON DUPLICATE KEY UPDATE permissions = VALUES(permissions), status = 'active'
        ]], { businessAccount, employeeCid, json.encode(perms) })
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
    local success = MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ? AND balance >= ?', { value, business.account_id, value })
    if not success or success < 1 then TriggerClientEvent('bc-banking:client:notify', src, 'Insufficient business funds.', 'error'); return end
    local recipient = QBCore.Functions.GetPlayerByCitizenId(employeeCid)
    if recipient then
        local paid = recipient.Functions.AddMoney('bank', value, 'bc-banking-business-payroll')
        if not paid then
            MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { value, business.account_id })
            TriggerClientEvent('bc-banking:client:notify', src, 'Payroll failed; business funds were returned.', 'error'); return
        end
    else
        local result = MySQL.update.await("UPDATE players SET money = JSON_SET(money, '$.bank', COALESCE(JSON_EXTRACT(money, '$.bank'), 0) + ?) WHERE citizenid = ?", { value, employeeCid })
        if not result or result < 1 then
            MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { value, business.account_id })
            TriggerClientEvent('bc-banking:client:notify', src, 'Employee not found; payroll reversed.', 'error'); return
        end
    end
    local balance = MySQL.scalar.await('SELECT balance FROM bc_banking_v2_accounts WHERE id = ?', { business.account_id })
    MySQL.insert.await([[
        INSERT INTO bc_banking_v2_ledger (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description, metadata)
        VALUES (?, ?, 'payroll', ?, ?, ?, 'Business payroll payment', ?)
    ]], { business.account_id, ref, value, balance, cid, json.encode({ employee=employeeCid }) })
    MySQL.insert.await('INSERT INTO bc_banking_v2_payroll (business_id, employee_citizenid, amount, actor_citizenid, status) VALUES (?, ?, ?, ?, "paid")', { businessId, employeeCid, value, cid })
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
    if decision == 'reject' then
        MySQL.update.await("UPDATE bc_banking_v2_loans SET status = 'rejected', reviewed_at = CURRENT_TIMESTAMP WHERE id = ?", { id })
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
    end
    print(('[bc-banking] Loan %s %s.'):format(id, decision))
end, true)

exports('GetV2Accounts', function(citizenid)
    if not BCBanking.V2Ready then return {} end
    return MySQL.query.await([[
        SELECT a.* FROM bc_banking_v2_accounts a
        JOIN bc_banking_v2_account_members m ON m.account_id = a.id
        WHERE m.citizenid = ? AND m.status = 'active' AND a.status = 'active'
    ]], { citizenid }) or {}
end)

exports('GetV2AccountBalance', function(accountId, citizenid)
    local access = member(tonumber(accountId), citizenid)
    return access and tonumber(access.balance) or nil
end)

exports('DepositToV2Account', function(accountId, citizenid, value, description)
    local n = amount(value, tonumber(Config.MaxDeposit) or 1000000)
    if not n then return false, 'invalid_amount' end
    local access = member(tonumber(accountId), citizenid)
    if not access then return false, 'not_authorized' end
    local perms = type(access.permissions) == 'table' and access.permissions or json.decode(access.permissions or '{}') or {}
    if not perms.deposit then return false, 'not_authorized' end
    local changed = MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ? AND status = "active"', { n, accountId })
    if not changed or changed < 1 then return false, 'database_error' end
    local ok, err = pcall(function()
        MySQL.insert.await([[INSERT INTO bc_banking_v2_ledger
            (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
            SELECT id, ?, 'deposit', ?, balance, ?, ? FROM bc_banking_v2_accounts WHERE id = ?]],
            { ('dep-%s-%s'):format(os.time(), math.random(100000,999999)), n, citizenid, tostring(description or 'External deposit'):sub(1,255), accountId })
    end)
    if not ok then
        MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ?', { n, accountId })
        return false, 'ledger_error'
    end
    return true
end)

exports('WithdrawFromV2Account', function(accountId, citizenid, value, description)
    local n = amount(value, tonumber(Config.MaxWithdrawal) or 1000000)
    if not n then return false, 'invalid_amount' end
    local access = member(tonumber(accountId), citizenid)
    if not access then return false, 'not_authorized' end
    local perms = type(access.permissions) == 'table' and access.permissions or json.decode(access.permissions or '{}') or {}
    if not perms.withdraw then return false, 'not_authorized' end
    local changed = MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ? AND status = "active" AND balance >= ?', { n, accountId, n })
    if not changed or changed < 1 then return false, 'insufficient_funds' end
    local ok, err = pcall(function()
        MySQL.insert.await([[INSERT INTO bc_banking_v2_ledger
            (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
            SELECT id, ?, 'withdrawal', ?, balance, ?, ? FROM bc_banking_v2_accounts WHERE id = ?]],
            { ('wd-%s-%s'):format(os.time(), math.random(100000,999999)), n, citizenid, tostring(description or 'External withdrawal'):sub(1,255), accountId })
    end)
    if not ok then
        MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { n, accountId })
        return false, 'ledger_error'
    end
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
    if value > due then value = due end
    local player = playerFor(src)
    if not player or (tonumber(player.PlayerData.money.bank) or 0) < value then
        TriggerClientEvent('bc-banking:client:notify', src, 'Insufficient bank funds for repayment.', 'error'); return
    end
    if not player.Functions.RemoveMoney('bank', value, 'bc-banking-loan-repayment') then return end
    local remaining = math.max(0, due - value)
    local changed = MySQL.update.await("UPDATE bc_banking_v2_loans SET balance_due = ?, status = ?, next_payment_at = IF(? <= 0, NULL, DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 1 MONTH)) WHERE id = ? AND citizenid = ? AND status = 'active' AND balance_due >= ?", { remaining, remaining <= 0 and 'paid' or 'active', remaining, id, cid, value })
    if not changed or changed < 1 then
        player.Functions.AddMoney('bank', value, 'bc-banking-loan-repayment-refund')
        return
    end
    completeIdempotency(idempotencyKey, { success=true })
    logAudit(cid, 'loan.repayment', id, { amount=value, remaining=remaining })
    TriggerClientEvent('bc-banking:client:notify', src, 'Loan repayment received.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

-- Interest is accrued once per account per server-local calendar day. A unique
-- account/date key makes repeated resource restarts safe against double credit.
local function accrueSavingsInterest()
    if not BCBanking.V2Ready then return end
    local rate = math.max(0, tonumber(Config.V2 and Config.V2.SavingsAPR) or 0)
    if rate <= 0 then return end
    local accounts = MySQL.query.await("SELECT id, balance FROM bc_banking_v2_accounts WHERE account_type = 'savings' AND status = 'active' AND balance > 0") or {}
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
            MySQL.update.await([[
                UPDATE bc_banking_v2_accounts a
                JOIN bc_banking_v2_interest_accruals i ON i.account_id = a.id
                SET a.balance = a.balance + i.amount,
                    i.balance_after = a.balance + i.amount
                WHERE a.id = ? AND i.accrual_date = ? AND i.balance_after = 0
                  AND a.status = 'active'
            ]], { account.id, date })
            -- INSERT IGNORE + deterministic reference makes this safe to retry
            -- if the process stopped after the balance update but before logging.
            MySQL.insert.await([[
                INSERT IGNORE INTO bc_banking_v2_ledger
                (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
                SELECT a.id, ?, 'interest', i.amount, i.balance_after, a.owner_citizenid, 'Daily savings interest'
                FROM bc_banking_v2_accounts a
                JOIN bc_banking_v2_interest_accruals i ON i.account_id = a.id
                WHERE a.id = ? AND i.accrual_date = ? AND i.balance_after > 0
            ]], { ('int-%s-%s'):format(date, account.id), account.id, date })
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
    local cid = player.PlayerData.citizenid
    local idem, idemState = claimIdempotency(cid, 'player.charge', { idempotencyKey=idempotencyKey, amount=n, source=paymentSource, reason=reason })
    if idemState == 'already_completed' then return true end
    if not idem then return false, idemState end
    local account = paymentSource == 'cash' and 'cash' or (paymentSource == 'bank' and 'bank' or nil)
    if not account then return false, 'invalid_payment_source' end
    if (tonumber(player.PlayerData.money[account]) or 0) < n then return false, 'insufficient_funds' end
    local removed = player.Functions.RemoveMoney(account, n, tostring(reason or 'BC Systems payment'):sub(1,100))
    if not removed then return false, 'payment_failed' end
    completeIdempotency(idem, { success=true })
    pcall(function()
        exports['bc-banking']:AddTransaction(cid, 'payment_' .. account, n, tostring(reason or 'BC Systems payment'))
    end)
    return true
end)

exports('RecordBusinessExpense', function(businessId, actorCitizenid, value, category, description, idempotencyKey)
    local n = amount(value, tonumber(Config.V2 and Config.V2.MaxPayrollPayment) or 100000)
    if not n then return false, 'invalid_amount' end
    local business = MySQL.single.await([[
        SELECT b.account_id, m.permissions FROM bc_banking_v2_businesses b
        JOIN bc_banking_v2_business_members m ON m.business_id = b.id
        WHERE b.id = ? AND m.citizenid = ? AND m.status = 'active' AND b.status = 'active'
    ]], { businessId, actorCitizenid })
    if not business then return false, 'not_authorized' end
    local idem, idemState = claimIdempotency(actorCitizenid, 'business.expense', { idempotencyKey=idempotencyKey, businessId=businessId, amount=n, category=category, description=description })
    if idemState == 'already_completed' then return true end
    if not idem then return false, idemState end
    local perms = type(business.permissions) == 'table' and business.permissions or json.decode(business.permissions or '{}') or {}
    if not perms.withdraw then return false, 'not_authorized' end
    local changed = MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ? AND balance >= ? AND status = "active"', { n, business.account_id, n })
    if not changed or changed < 1 then return false, 'insufficient_funds' end
    local ok = pcall(function()
        MySQL.insert.await('INSERT INTO bc_banking_v2_business_expenses (business_id, actor_citizenid, amount, category, description) VALUES (?, ?, ?, ?, ?)', { businessId, actorCitizenid, n, tostring(category or 'general'):sub(1,48), tostring(description or 'Business expense'):sub(1,255) })
        MySQL.insert.await([[
            INSERT INTO bc_banking_v2_ledger (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
            SELECT id, ?, 'business_expense', ?, balance, ?, ? FROM bc_banking_v2_accounts WHERE id = ?
        ]], { ('exp-%s-%s'):format(os.time(), math.random(100000,999999)), n, actorCitizenid, tostring(description or 'Business expense'):sub(1,255), business.account_id })
    end)
    if not ok then
        MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { n, business.account_id })
        return false, 'recording_failed'
    end
    completeIdempotency(idem, { success=true })
    return true
end)

exports('GetAccountStatement', function(accountId, citizenid, fromDate, toDate, limit)
    local access = member(tonumber(accountId), citizenid)
    if not access then return {} end
    return MySQL.query.await([[
        SELECT transaction_ref, entry_type, amount, balance_after, description, created_at
        FROM bc_banking_v2_ledger
        WHERE account_id = ?
          AND (? IS NULL OR created_at >= ?)
          AND (? IS NULL OR created_at <= ?)
        ORDER BY id DESC LIMIT ?
    ]], { accountId, fromDate, fromDate, toDate, toDate, math.max(1, math.min(tonumber(limit) or 100, 500)) }) or {}
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
                else
                    MySQL.update.await([[
                        UPDATE bc_banking_v2_accounts AS src
                        JOIN bc_banking_v2_accounts AS dst ON dst.id = ?
                        SET src.balance = src.balance + ?, dst.balance = dst.balance - ?
                        WHERE src.id = ?
                    ]], { payment.destination_account_id, payment.amount, payment.amount, payment.source_account_id })
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
    MySQL.update.await("UPDATE bc_banking_v2_scheduled_payments SET status = 'failed' WHERE status = 'processing'")
    while true do
        Wait(60000)
        local ok, err = pcall(processScheduledPayments)
        if not ok then print(('[bc-banking] Scheduled payment processor failed: %s'):format(tostring(err))) end
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
    local card = MySQL.single.await("SELECT account_id FROM bc_banking_v2_cards WHERE id = ? AND citizenid = ? AND status IN ('active','frozen')", { oldId, cid })
    if not card then return end
    MySQL.update.await("UPDATE bc_banking_v2_cards SET status = 'replaced' WHERE id = ? AND citizenid = ?", { oldId, cid })
    local nonce, salt = '', tostring(math.random(100000,999999)) .. tostring(os.time()) .. tostring(math.random(100000,999999))
    for _ = 1, 32 do nonce = nonce .. tostring(math.random(0,9)) end
    local last4 = nonce:sub(-4)
    local newId = MySQL.insert.await([[INSERT INTO bc_banking_v2_cards
        (citizenid, account_id, card_hash, card_last4, card_type, status, expires_at)
        VALUES (?, ?, SHA2(CONCAT(?, ?, ?), 256), ?, 'debit', 'active', DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 4 YEAR))
    ]], { cid, card.account_id, nonce, salt, tostring(Config.V2 and Config.V2.CardPepper or ''), last4 })
    if newId then
        MySQL.insert.await('INSERT INTO bc_banking_v2_card_secrets (card_id, pin_salt) VALUES (?, ?)', { newId, salt })
        logAudit(cid, 'card.replaced', oldId, { new_card_id=newId, last4=last4 })
        TriggerClientEvent('bc-banking:client:notify', src, 'Replacement card issued ending in ' .. last4 .. '.', 'success')
    end
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
    if not accountId or not value or not sourceType then return end
    local access = member(accountId, cid)
    if not access then return end
    local perms = type(access.permissions) == 'table' and access.permissions or json.decode(access.permissions or '{}') or {}
    if not perms.deposit then return end
    local idempotencyKey, idemState = claimIdempotency(cid, 'account.deposit', data)
    if idemState == 'already_completed' then TriggerClientEvent('bc-banking:client:notify', src, 'This deposit was already processed.', 'success'); return end
    if not idempotencyKey then TriggerClientEvent('bc-banking:client:notify', src, 'Deposit request rejected: ' .. tostring(idemState), 'error'); return end
    local player = playerFor(src)
    if not player then return end
    local ok, message = BCBanking.WithPlayerLocks({ cid }, function()
        if (tonumber(player.PlayerData.money[sourceType]) or 0) < value then return false, 'Insufficient funds.' end
        if not player.Functions.RemoveMoney(sourceType, value, 'bc-banking-v2-account-deposit') then return false, 'Money could not be removed.' end
        local changed = MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ? AND status = "active"', { value, accountId })
        if not changed or changed < 1 then
            player.Functions.AddMoney(sourceType, value, 'bc-banking-v2-account-deposit-refund')
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
            player.Functions.AddMoney(sourceType, value, 'bc-banking-v2-account-deposit-refund')
            return false, 'Deposit could not be recorded and was reversed.'
        end
        completeIdempotency(idempotencyKey, { success=true })
        return true, 'Account funded.'
    end)
    TriggerClientEvent('bc-banking:client:notify', src, message or (ok and 'Account funded.' or 'Deposit failed.'), ok and 'success' or 'error')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

RegisterNetEvent('bc-banking:v2:withdrawAccount', function(data)
    local src, cid = source, cidFor(source)
    if not cid or type(data) ~= 'table' then return end
    local accountId, value = tonumber(data.accountId), amount(data.amount, tonumber(Config.MaxWithdrawal) or 1000000)
    local destination = data.destination == 'cash' and 'cash' or (data.destination == 'bank' and 'bank' or nil)
    if not accountId or not value or not destination then return end
    local access = member(accountId, cid)
    if not access then return end
    local perms = type(access.permissions) == 'table' and access.permissions or json.decode(access.permissions or '{}') or {}
    if not perms.withdraw then return end
    local idempotencyKey, idemState = claimIdempotency(cid, 'account.withdraw', data)
    if idemState == 'already_completed' then TriggerClientEvent('bc-banking:client:notify', src, 'This withdrawal was already processed.', 'success'); return end
    if not idempotencyKey then TriggerClientEvent('bc-banking:client:notify', src, 'Withdrawal request rejected: ' .. tostring(idemState), 'error'); return end
    local player = playerFor(src)
    if not player then return end
    local ok, message = BCBanking.WithPlayerLocks({ cid }, function()
        local changed = MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ? AND status = "active" AND balance >= ?', { value, accountId, value })
        if not changed or changed < 1 then return false, 'Insufficient account funds.' end
        if not player.Functions.AddMoney(destination, value, 'bc-banking-v2-account-withdrawal') then
            MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { value, accountId })
            return false, 'Withdrawal failed and was reversed.'
        end
        local logged = pcall(function()
            MySQL.insert.await([[
                INSERT INTO bc_banking_v2_ledger (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
                SELECT id, ?, 'withdrawal', ?, balance, ?, ? FROM bc_banking_v2_accounts WHERE id = ?
            ]], { ('cashout-%s-%s'):format(os.time(), math.random(100000,999999)), value, cid, 'Withdrawal to ' .. destination, accountId })
        end)
        if not logged then
            player.Functions.RemoveMoney(destination, value, 'bc-banking-v2-account-withdrawal-reversal')
            MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { value, accountId })
            return false, 'Withdrawal could not be recorded and was reversed.'
        end
        completeIdempotency(idempotencyKey, { success=true })
        return true, 'Withdrawal completed.'
    end)
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
    local open = tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM bc_banking_v2_business_loans WHERE business_id = ? AND status IN ('pending','active')", { businessId }) or 0)
    if open > 0 then TriggerClientEvent('bc-banking:client:notify', src, 'This business already has an open loan.', 'error'); return end
    local rate = math.max(0, tonumber(Config.V2 and Config.V2.LoanAPR) or 5)
    local id = MySQL.insert.await([[
        INSERT INTO bc_banking_v2_business_loans (business_id, applicant_citizenid, principal, apr, term_months, status)
        VALUES (?, ?, ?, ?, ?, 'pending')
    ]], { businessId, cid, principal, rate, months })
    if id then
        logAudit(cid, 'business_loan.applied', id, { business_id=businessId, principal=principal, term=months })
        TriggerClientEvent('bc-banking:client:notify', src, 'Business loan application submitted.', 'success')
        TriggerClientEvent('bc-banking:client:v2:refresh', src)
    end
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
    if value > due then value = due end
    local debited = MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ? AND balance >= ? AND status = "active"', { value, loan.account_id, value })
    if not debited or debited < 1 then
        TriggerClientEvent('bc-banking:client:notify', src, 'Insufficient business account funds.', 'error'); return
    end
    local remaining = math.max(0, due - value)
    local changed = MySQL.update.await("UPDATE bc_banking_v2_business_loans SET balance_due = ?, status = ? WHERE id = ? AND status = 'active' AND balance_due >= ?", { remaining, remaining <= 0 and 'paid' or 'active', loanId, value })
    if not changed or changed < 1 then
        MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ?', { value, loan.account_id })
        return
    end
    local balance = MySQL.scalar.await('SELECT balance FROM bc_banking_v2_accounts WHERE id = ?', { loan.account_id })
    MySQL.insert.await([[
        INSERT INTO bc_banking_v2_ledger (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description, metadata)
        VALUES (?, ?, 'loan_repayment', ?, ?, ?, 'Business loan repayment', ?)
    ]], { loan.account_id, ('bizloan-%s-%s'):format(loanId, os.time()), value, balance, cid, json.encode({ loan_id=loanId }) })
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
        MySQL.insert.await([[
            INSERT INTO bc_banking_v2_ledger (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description, metadata)
            VALUES (?, ?, 'loan_disbursement', ?, ?, ?, 'Business loan disbursement', ?)
        ]], { business.account_id, ('bizloan-start-%s'):format(id), loan.principal, balance, loan.applicant_citizenid, json.encode({ loan_id=id }) })
    end
    logAudit(src == 0 and 'SERVER_CONSOLE' or (cidFor(src) or 'UNKNOWN'), 'business_loan.' .. decision, id, {})
    print(('[bc-banking] Business loan %s %s.'):format(id, decision))
end, true)
