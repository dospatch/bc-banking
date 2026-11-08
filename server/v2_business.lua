local QBCore = exports['qb-core']:GetCoreObject()
BCBanking = BCBanking or {}
BCBanking.V2 = BCBanking.V2 or {}

local function amount(value, max)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    n = math.floor(n * 100 + 0.5) / 100
    if n <= 0 or n > max then return nil end
    return n
end

local function number()
    for _ = 1, 20 do
        local n = ''
        for _ = 1, math.max(10, math.min(20, tonumber(Config.AccountNumberLength) or 12)) do
            n = n .. tostring(math.random(0, 9))
        end
        if not MySQL.scalar.await('SELECT id FROM bc_banking_v2_accounts WHERE account_number = ? LIMIT 1', { n }) then
            return n
        end
    end
end

local function getBusiness(businessId)
    return MySQL.single.await([[
        SELECT b.id, b.business_name, b.owner_citizenid, b.account_id,
               a.account_number, a.balance, a.status
        FROM bc_banking_v2_businesses b
        INNER JOIN bc_banking_v2_accounts a ON a.id = b.account_id
        WHERE b.id = ? AND b.status = 'active' AND a.status = 'active'
        LIMIT 1
    ]], { businessId })
end

QBCore.Functions.CreateCallback('bc-banking:v2:getBusinesses', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not BCBanking.V2.Ready then cb({}); return end
    cb(MySQL.query.await([[
        SELECT b.id, b.business_name, b.owner_citizenid, b.account_id,
               a.account_number, a.balance, m.role, m.permissions
        FROM bc_banking_v2_businesses b
        INNER JOIN bc_banking_v2_accounts a ON a.id = b.account_id
        INNER JOIN bc_banking_v2_account_members m ON m.account_id = a.id
        WHERE m.citizenid = ? AND m.status = 'active'
          AND b.status = 'active' AND a.status = 'active'
        ORDER BY b.id DESC
    ]], { Player.PlayerData.citizenid }) or {})
end)

QBCore.Functions.CreateCallback('bc-banking:v2:getBusinessExpenses', function(source, cb, businessId)
    local Player = QBCore.Functions.GetPlayer(source)
    businessId = tonumber(businessId)
    if not Player or not businessId or not BCBanking.V2.Ready then cb({}); return end
    local business = getBusiness(businessId)
    if not business or not BCBanking.V2.CanAccessAccount(business.account_id, Player.PlayerData.citizenid, 'view_expenses') then
        cb({})
        return
    end
    cb(MySQL.query.await([[
        SELECT id, citizenid, amount, description, created_at
        FROM bc_banking_v2_business_expenses
        WHERE business_id = ? ORDER BY id DESC LIMIT 100
    ]], { businessId }) or {})
end)

RegisterNetEvent('bc-banking:v2:createBusiness', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local name = BCBanking.Trim(data.businessName):sub(1, 100)
    if name == '' then
        TriggerClientEvent('bc-banking:client:notify', src, 'Enter a business name.', 'error')
        return
    end
    local accountNumber = number()
    if not accountNumber then return end
    local accountId = MySQL.insert.await([[
        INSERT INTO bc_banking_v2_accounts
            (account_number, account_type, display_name, owner_citizenid, balance)
        VALUES (?, 'business', ?, ?, 0.00)
    ]], { accountNumber, name, cid })
    if not accountId then return end
    local ok = pcall(function()
        MySQL.insert.await([[
            INSERT INTO bc_banking_v2_account_members (account_id, citizenid, role, permissions, status)
            VALUES (?, ?, 'owner', ?, 'active')
        ]], { accountId, cid, json.encode({}) })
        MySQL.insert.await([[
            INSERT INTO bc_banking_v2_businesses (business_name, owner_citizenid, account_id)
            VALUES (?, ?, ?)
        ]], { name, cid, accountId })
    end)
    if not ok then
        MySQL.query.await('DELETE FROM bc_banking_v2_accounts WHERE id = ?', { accountId })
        TriggerClientEvent('bc-banking:client:notify', src, 'Business setup failed.', 'error')
        return
    end
    BCBanking.V2.Audit(cid, 'business.created', 'account', accountId, { business_name = name })
    TriggerClientEvent('bc-banking:client:notify', src, 'Business account created.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

RegisterNetEvent('bc-banking:v2:addBusinessEmployee', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local business = getBusiness(tonumber(data.businessId))
    local employee = BCBanking.Trim(data.citizenid)
    if not business or business.owner_citizenid ~= cid or employee == '' or employee == cid then
        TriggerClientEvent('bc-banking:client:notify', src, 'Only the business owner can add a valid employee.', 'error')
        return
    end
    local exists = MySQL.scalar.await('SELECT citizenid FROM players WHERE citizenid = ? LIMIT 1', { employee })
    if not exists then
        TriggerClientEvent('bc-banking:client:notify', src, 'That citizen ID was not found.', 'error')
        return
    end
    local allowed = { view_transactions = true, view_expenses = true, deposit = true, withdraw = true, manage_expenses = true, manage_payroll = true }
    local permissions = {}
    if type(data.permissions) == 'table' then
        for key, value in pairs(data.permissions) do
            if allowed[key] and value == true then permissions[key] = true end
        end
    end
    MySQL.insert.await([[
        INSERT INTO bc_banking_v2_account_members (account_id, citizenid, role, permissions, status)
        VALUES (?, ?, 'employee', ?, 'active')
        ON DUPLICATE KEY UPDATE permissions = VALUES(permissions), status = 'active', role = 'employee'
    ]], { business.account_id, employee, json.encode(permissions) })
    BCBanking.V2.Audit(cid, 'business.employee_added', 'business', business.id, { employee = employee, permissions = permissions })
    TriggerClientEvent('bc-banking:client:notify', src, 'Business employee access updated.', 'success')
end)

RegisterNetEvent('bc-banking:v2:businessExpense', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local business = getBusiness(tonumber(data.businessId))
    local cost = amount(data.amount, tonumber(Config.V2.MaxPayment) or 1000000)
    local description = BCBanking.Trim(data.description):sub(1, 255)
    if not business or not cost or description == '' or not BCBanking.V2.CanAccessAccount(business.account_id, cid, 'manage_expenses') then
        TriggerClientEvent('bc-banking:client:notify', src, 'Invalid expense or permission.', 'error')
        return
    end
    local ok = BCBanking.V2.ApplyDelta(business.account_id, cid, -cost, 'business_expense', description)
    if not ok then
        TriggerClientEvent('bc-banking:client:notify', src, 'Insufficient business funds.', 'error')
        return
    end
    local inserted = MySQL.insert.await([[
        INSERT INTO bc_banking_v2_business_expenses (business_id, citizenid, amount, description)
        VALUES (?, ?, ?, ?)
    ]], { business.id, cid, cost, description })
    if not inserted then
        BCBanking.V2.ApplyDelta(business.account_id, cid, cost, 'expense_reversal', 'Expense record failed; reversal')
        TriggerClientEvent('bc-banking:client:notify', src, 'Expense failed and funds were restored.', 'error')
        return
    end
    BCBanking.V2.Audit(cid, 'business.expense', 'business', business.id, { amount = cost, description = description })
    TriggerClientEvent('bc-banking:client:notify', src, 'Business expense recorded.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

RegisterNetEvent('bc-banking:v2:payroll', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or type(data.items) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local business = getBusiness(tonumber(data.businessId))
    if not business or not BCBanking.V2.CanAccessAccount(business.account_id, cid, 'manage_payroll') then
        TriggerClientEvent('bc-banking:client:notify', src, 'You do not have payroll permission.', 'error')
        return
    end
    if #data.items < 1 or #data.items > 25 then
        TriggerClientEvent('bc-banking:client:notify', src, 'Payroll must contain between 1 and 25 employees.', 'error')
        return
    end
    local batchId = MySQL.insert.await([[
        INSERT INTO bc_banking_v2_payroll_batches (business_id, created_by, total_amount, status)
        VALUES (?, ?, 0, 'processing')
    ]], { business.id, cid })
    if not batchId then return end

    local totalPaid, totalFailed = 0, 0
    for _, item in ipairs(data.items) do
        local employee = BCBanking.Trim(item.citizenid)
        local pay = amount(item.amount, tonumber(Config.V2.MaxPayrollPayment) or 100000)
        local exists = employee ~= '' and MySQL.scalar.await('SELECT citizenid FROM players WHERE citizenid = ? LIMIT 1', { employee })
        if pay and exists then
            local debit = BCBanking.V2.ApplyDelta(business.account_id, cid, -pay, 'payroll', 'Employee payroll')
            if debit then
                local online = QBCore.Functions.GetPlayerByCitizenId(employee)
                local paid = false
                if online then
                    paid = online.Functions.AddMoney('bank', pay, 'bc-banking-v2-payroll') == true
                else
                    local changed = MySQL.update.await([[
                        UPDATE players
                        SET money = JSON_SET(
                            money, '$.bank',
                            CAST(COALESCE(JSON_UNQUOTE(JSON_EXTRACT(money, '$.bank')), '0') AS DECIMAL(15,2)) + ?
                        )
                        WHERE citizenid = ?
                    ]], { pay, employee })
                    paid = (tonumber(changed) or 0) > 0
                end
                if paid then
                    MySQL.insert.await([[
                        INSERT INTO bc_banking_v2_payroll_items (batch_id, employee_citizenid, amount, status)
                        VALUES (?, ?, ?, 'paid')
                    ]], { batchId, employee, pay })
                    totalPaid = totalPaid + pay
                else
                    BCBanking.V2.ApplyDelta(business.account_id, cid, pay, 'payroll_reversal', 'Payroll payout failed; reversal')
                    MySQL.insert.await([[
                        INSERT INTO bc_banking_v2_payroll_items (batch_id, employee_citizenid, amount, status)
                        VALUES (?, ?, ?, 'failed')
                    ]], { batchId, employee, pay })
                    totalFailed = totalFailed + 1
                end
            else
                totalFailed = totalFailed + 1
            end
        else
            totalFailed = totalFailed + 1
        end
    end
    MySQL.update.await([[
        UPDATE bc_banking_v2_payroll_batches
        SET total_amount = ?, status = ?
        WHERE id = ?
    ]], { totalPaid, totalFailed > 0 and (totalPaid > 0 and 'partial' or 'failed') or 'completed', batchId })
    BCBanking.V2.Audit(cid, 'business.payroll', 'business', business.id, { batch_id = batchId, total_paid = totalPaid, failed = totalFailed })
    TriggerClientEvent('bc-banking:client:notify', src, ('Payroll finished: %s paid, %s failed.'):format(totalPaid, totalFailed), totalFailed > 0 and 'error' or 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

RegisterNetEvent('bc-banking:v2:applyBusinessLoan', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local business = getBusiness(tonumber(data.businessId))
    local principal = amount(data.amount, tonumber(Config.V2.MaxLoan) or 500000)
    local months = math.floor(tonumber(data.months) or 0)
    if not business or business.owner_citizenid ~= cid or not principal or months < 1 or months > (tonumber(Config.V2.MaxLoanMonths) or 24) then
        TriggerClientEvent('bc-banking:client:notify', src, 'Invalid business loan application.', 'error')
        return
    end
    MySQL.insert.await([[
        INSERT INTO bc_banking_v2_loans
            (citizenid, account_id, loan_type, principal, apr, months, remaining_balance, status)
        VALUES (?, ?, 'business', ?, ?, ?, ?, 'pending')
    ]], { cid, business.account_id, principal, tonumber(Config.V2.LoanAPR) or 5.0, months, principal })
    BCBanking.V2.Audit(cid, 'business.loan_applied', 'business', business.id, { amount = principal, months = months })
    TriggerClientEvent('bc-banking:client:notify', src, 'Business loan application submitted for review.', 'success')
end)
