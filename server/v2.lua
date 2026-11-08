local QBCore = exports['qb-core']:GetCoreObject()
BCBanking = BCBanking or {}
BCBanking.V2 = BCBanking.V2 or {}

local V2 = BCBanking.V2
local function playerFor(src) return QBCore.Functions.GetPlayer(src) end
local function cidFor(src)
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
        SELECT COUNT(*) FROM bc_banking_v2_account_members WHERE citizenid = ? AND status = 'active'
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
    if not from or not to or from.permissions == nil then return end
    local permissions = type(from.permissions) == 'table' and from.permissions or json.decode(from.permissions or '{}') or {}
    if not permissions.transfer then return end
    if tonumber(from.id) == tonumber(to.id) then return end
    local fee = math.max(0, tonumber(Config.V2 and Config.V2.InternalTransferFee) or 0)
    local total = value + fee
    local ref = ('%s-%s-%s'):format(os.time(), src, math.random(100000, 999999))
    local ok = MySQL.transaction.await({
        { query = "UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ? AND status = 'active' AND balance >= ?", values = { total, fromId, total } },
        { query = "UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ? AND status = 'active'", values = { value, to.id } },
        { query = [[INSERT INTO bc_banking_v2_ledger (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description, metadata)
                    SELECT id, ?, 'transfer_out', ?, balance, ?, ?, ? FROM bc_banking_v2_accounts WHERE id = ?]], values = { ref, value, cid, tostring(data.description or 'Account transfer'):sub(1, 255), json.encode({ recipient=to.account_number, fee=fee }), fromId } },
        { query = [[INSERT INTO bc_banking_v2_ledger (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description, metadata)
                    SELECT id, ?, 'transfer_in', ?, balance, ?, ?, ? FROM bc_banking_v2_accounts WHERE id = ?]], values = { ref, value, cid, tostring(data.description or 'Incoming transfer'):sub(1, 255), json.encode({ sender=from.account_number }), to.id } }
    })
    if not ok then TriggerClientEvent('bc-banking:client:notify', src, 'Transfer failed or insufficient funds.', 'error'); return end
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
    local player = playerFor(src)
    if not player or (tonumber(player.PlayerData.money.bank) or 0) < value then
        TriggerClientEvent('bc-banking:client:notify', src, 'Insufficient checking balance.', 'error'); return
    end
    local removed = player.Functions.RemoveMoney('bank', value, 'bc-banking-savings-goal')
    if not removed then return end
    local updated = MySQL.update.await('UPDATE bc_banking_v2_savings_goals SET current_amount = current_amount + ?, status = IF(current_amount + ? >= target_amount, "completed", status) WHERE id = ? AND citizenid = ?', { value, value, goalId, cid })
    if not updated then
        player.Functions.AddMoney('bank', value, 'bc-banking-savings-goal-refund')
        return
    end
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
    local raw = ''
    for _ = 1, 16 do raw = raw .. tostring(math.random(0, 9)) end
    local last4 = raw:sub(-4)
    -- Only a salted server hash is stored. The full PAN is never persisted or logged.
    local salt = tostring(math.random(100000, 999999)) .. tostring(os.time())
    local hash = GetHashKey(salt .. raw .. (Config.V2 and Config.V2.CardPepper or ''))
    local id = MySQL.insert.await([[
        INSERT INTO bc_banking_v2_cards (citizenid, account_id, card_hash, card_last4, card_type, status, expires_at)
        VALUES (?, ?, ?, ?, 'debit', 'active', DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 4 YEAR))
    ]], { cid, accountId, tostring(hash), last4 })
    if id then
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
    cb(MySQL.query.await('SELECT id, principal, apr, term_months, status, created_at, reviewed_at FROM bc_banking_v2_loans WHERE citizenid = ? ORDER BY id DESC', { cid }) or {})
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
    if not businessId or #employeeCid < 2 or #employeeCid > 50 then return end
    local owner = MySQL.single.await("SELECT id FROM bc_banking_v2_business_members WHERE business_id = ? AND citizenid = ? AND role = 'owner' AND status = 'active'", { businessId, cid })
    if not owner then return end
    local perms = { view=data.permissions and data.permissions.view == true, deposit=data.permissions and data.permissions.deposit == true, withdraw=data.permissions and data.permissions.withdraw == true, transfer=data.permissions and data.permissions.transfer == true, payroll=data.permissions and data.permissions.payroll == true, manage=false }
    MySQL.insert.await([[
        INSERT INTO bc_banking_v2_business_members (business_id, citizenid, role, permissions, status)
        VALUES (?, ?, 'employee', ?, 'active')
        ON DUPLICATE KEY UPDATE permissions = VALUES(permissions), status = 'active'
    ]], { businessId, employeeCid, json.encode(perms) })
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
    local ref = ('pay-%s-%s-%s'):format(os.time(), src, math.random(100000,999999))
    local success = MySQL.update.await('UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ? AND balance >= ?', { value, business.account_id, value })
    if not success or success < 1 then TriggerClientEvent('bc-banking:client:notify', src, 'Insufficient business funds.', 'error'); return end
    local recipient = QBCore.Functions.GetPlayerByCitizenId(employeeCid)
    if recipient then
        recipient.Functions.AddMoney('bank', value, 'bc-banking-business-payroll')
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
    logAudit(cid, 'business.payroll_paid', businessId, { employee=employeeCid, amount=value })
    TriggerClientEvent('bc-banking:client:notify', src, 'Payroll payment sent.', 'success')
end)

-- Admin review commands are ACE-gated. Approval never runs from a client event.
RegisterCommand('bcbankloan', function(src, args)
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
        local payment = loan.principal * (1 + (loan.apr / 100) * (loan.term_months / 12)) / loan.term_months
        local player = QBCore.Functions.GetPlayerByCitizenId(loan.citizenid)
        if player then
            player.Functions.AddMoney('bank', tonumber(loan.principal), 'bc-banking-loan-disbursement')
        else
            local changed = MySQL.update.await("UPDATE players SET money = JSON_SET(money, '$.bank', COALESCE(JSON_EXTRACT(money, '$.bank'), 0) + ?) WHERE citizenid = ?", { loan.principal, loan.citizenid })
            if not changed or changed < 1 then print('[bc-banking] Loan disbursement failed; application left pending.'); return end
        end
        MySQL.update.await("UPDATE bc_banking_v2_loans SET status = 'active', monthly_payment = ?, balance_due = principal * (1 + (apr / 100) * (term_months / 12)), reviewed_at = CURRENT_TIMESTAMP, next_payment_at = DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 1 MONTH) WHERE id = ?", { payment, id })
    end
    print(('[bc-banking] Loan %s %s.'):format(id, decision))
end, true)

exports('GetV2Accounts', function(citizenid)
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
    local ref = ('dep-%s-%s'):format(os.time(), math.random(100000,999999))
    local ok = MySQL.transaction.await({
        { query='UPDATE bc_banking_v2_accounts SET balance = balance + ? WHERE id = ? AND status = "active"', values={ n, accountId } },
        { query=[[INSERT INTO bc_banking_v2_ledger (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
                  SELECT id, ?, 'deposit', ?, balance, ?, ? FROM bc_banking_v2_accounts WHERE id = ?]], values={ ref, n, citizenid, tostring(description or 'External deposit'):sub(1,255), accountId } }
    })
    return ok == true, ok and nil or 'database_error'
end)

exports('WithdrawFromV2Account', function(accountId, citizenid, value, description)
    local n = amount(value, tonumber(Config.MaxWithdrawal) or 1000000)
    if not n then return false, 'invalid_amount' end
    local access = member(tonumber(accountId), citizenid)
    if not access then return false, 'not_authorized' end
    local perms = type(access.permissions) == 'table' and access.permissions or json.decode(access.permissions or '{}') or {}
    if not perms.withdraw then return false, 'not_authorized' end
    local ref = ('wd-%s-%s'):format(os.time(), math.random(100000,999999))
    local ok = MySQL.transaction.await({
        { query='UPDATE bc_banking_v2_accounts SET balance = balance - ? WHERE id = ? AND status = "active" AND balance >= ?', values={ n, accountId, n } },
        { query=[[INSERT INTO bc_banking_v2_ledger (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
                  SELECT id, ?, 'withdrawal', ?, balance, ?, ? FROM bc_banking_v2_accounts WHERE id = ?]], values={ ref, n, citizenid, tostring(description or 'External withdrawal'):sub(1,255), accountId } }
    })
    return ok == true, ok and nil or 'insufficient_or_database_error'
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
