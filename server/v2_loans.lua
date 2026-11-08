local QBCore = exports['qb-core']:GetCoreObject()
BCBanking = BCBanking or {}
BCBanking.V2 = BCBanking.V2 or {}

local function validAmount(value, maximum)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    n = math.floor(n * 100 + 0.5) / 100
    if n <= 0 or n > maximum then return nil end
    return n
end

local function isAdmin(source)
    return QBCore.Functions.HasPermission(source, 'admin') or QBCore.Functions.HasPermission(source, 'god')
end

QBCore.Functions.CreateCallback('bc-banking:v2:getLoans', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not BCBanking.V2.Ready then cb({}); return end
    cb(MySQL.query.await([[
        SELECT id, account_id, loan_type, principal, apr, months, remaining_balance,
               status, created_at, approved_at
        FROM bc_banking_v2_loans
        WHERE citizenid = ?
        ORDER BY id DESC LIMIT 50
    ]], { Player.PlayerData.citizenid }) or {})
end)

RegisterNetEvent('bc-banking:v2:applyLoan', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local accountId = tonumber(data.accountId)
    local principal = validAmount(data.amount, tonumber(Config.V2.MaxLoan) or 500000)
    local months = math.floor(tonumber(data.months) or 0)
    local apr = tonumber(Config.V2.LoanAPR) or 5.0
    if not accountId or not BCBanking.V2.CanAccessAccount(accountId, cid, 'deposit')
        or not principal or months < 1 or months > (tonumber(Config.V2.MaxLoanMonths) or 24) then
        TriggerClientEvent('bc-banking:client:notify', src, 'Invalid loan application details.', 'error')
        return
    end
    local outstanding = tonumber(MySQL.scalar.await([[
        SELECT COUNT(*) FROM bc_banking_v2_loans
        WHERE citizenid = ? AND loan_type = 'personal' AND status IN ('pending', 'approved')
    ]], { cid })) or 0
    if outstanding > 0 then
        TriggerClientEvent('bc-banking:client:notify', src, 'You already have a pending or active personal loan.', 'error')
        return
    end
    local totalDue = math.floor((principal * (1 + (apr / 100) * (months / 12))) * 100 + 0.5) / 100
    local id = MySQL.insert.await([[
        INSERT INTO bc_banking_v2_loans
            (citizenid, account_id, loan_type, principal, apr, months, remaining_balance, status)
        VALUES (?, ?, 'personal', ?, ?, ?, ?, 'pending')
    ]], { cid, accountId, principal, apr, months, totalDue })
    if id then
        BCBanking.V2.Audit(cid, 'loan.applied', 'loan', id, { principal = principal, total_due = totalDue, months = months })
        TriggerClientEvent('bc-banking:client:notify', src, 'Loan application submitted for review.', 'success')
        TriggerClientEvent('bc-banking:client:v2:refresh', src)
    end
end)

RegisterNetEvent('bc-banking:v2:reviewLoan', function(data)
    local src = source
    local Admin = QBCore.Functions.GetPlayer(src)
    if not Admin or not isAdmin(src) or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local loanId = tonumber(data.loanId)
    local decision = data.decision == 'approve' and 'approved' or (data.decision == 'reject' and 'rejected' or nil)
    if not loanId or not decision then return end
    local loan = MySQL.single.await(
        "SELECT * FROM bc_banking_v2_loans WHERE id = ? AND status = 'pending' LIMIT 1",
        { loanId }
    )
    if not loan then
        TriggerClientEvent('bc-banking:client:notify', src, 'Pending loan not found.', 'error')
        return
    end
    if decision == 'reject' then
        MySQL.update.await(
            "UPDATE bc_banking_v2_loans SET status = 'rejected', approved_by = ? WHERE id = ? AND status = 'pending'",
            { Admin.PlayerData.citizenid, loanId }
        )
        BCBanking.V2.Audit(Admin.PlayerData.citizenid, 'loan.rejected', 'loan', loanId, { applicant = loan.citizenid })
        TriggerClientEvent('bc-banking:client:notify', src, 'Loan application rejected.', 'success')
        return
    end
    local changed = MySQL.update.await([[
        UPDATE bc_banking_v2_loans
        SET status = 'approving', approved_by = ?, approved_at = CURRENT_TIMESTAMP
        WHERE id = ? AND status = 'pending'
    ]], { Admin.PlayerData.citizenid, loanId })
    if (tonumber(changed) < 1) return
    local credited = BCBanking.V2.ApplyDelta(loan.account_id, Admin.PlayerData.citizenid, tonumber(loan.principal), 'loan_disbursement', 'Approved loan disbursement')
    if not credited then
        MySQL.update.await(
            "UPDATE bc_banking_v2_loans SET status = 'pending', approved_by = NULL, approved_at = NULL WHERE id = ? AND status = 'approving'",
            { loanId }
        )
        TriggerClientEvent('bc-banking:client:notify', src, 'Loan payout failed; application returned to pending.', 'error')
        return
    end
    MySQL.update.await(
        "UPDATE bc_banking_v2_loans SET status = 'approved' WHERE id = ? AND status = 'approving'",
        { loanId }
    )
    BCBanking.V2.Audit(Admin.PlayerData.citizenid, 'loan.approved', 'loan', loanId, { applicant = loan.citizenid, principal = loan.principal })
    local Recipient = QBCore.Functions.GetPlayerByCitizenId(loan.citizenid)
    if Recipient then
        TriggerClientEvent('bc-banking:client:notify', Recipient.PlayerData.source, 'Your loan was approved and deposited.', 'success')
        TriggerClientEvent('bc-banking:client:v2:refresh', Recipient.PlayerData.source)
    end
    TriggerClientEvent('bc-banking:client:notify', src, 'Loan approved and deposited.', 'success')
end)

RegisterNetEvent('bc-banking:v2:repayLoan', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local loanId = tonumber(data.loanId)
    local loan = loanId and MySQL.single.await([[
        SELECT id, account_id, loan_type, remaining_balance, status
        FROM bc_banking_v2_loans
        WHERE id = ? AND citizenid = ? AND status = 'approved'
        LIMIT 1
    ]], { loanId, cid })
    local pay = loan and validAmount(data.amount, tonumber(Config.V2.MaxPayment) or 1000000)
    if not loan or not pay then return end
    pay = math.min(pay, tonumber(loan.remaining_balance))
    if pay <= 0 then return end

    local method = data.paymentType == 'cash' and 'cash' or 'bank'
    local debited = false
    if loan.loan_type == 'business' then
        local business = MySQL.single.await(
            'SELECT id FROM bc_banking_v2_businesses WHERE account_id = ? AND owner_citizenid = ? LIMIT 1',
            { loan.account_id, cid }
        )
        if not business or not BCBanking.V2.CanAccessAccount(loan.account_id, cid, 'manage_expenses') then return end
        debited = BCBanking.V2.ApplyDelta(loan.account_id, cid, -pay, 'business_loan_repayment', 'Business loan repayment')
    else
        if (tonumber(Player.PlayerData.money[method]) or 0) < pay then
            TriggerClientEvent('bc-banking:client:notify', src, 'Insufficient funds.', 'error')
            return
        end
        debited = Player.Functions.RemoveMoney(method, pay, 'bc-banking-v2-loan-repayment') == true
    end
    if not debited then
        TriggerClientEvent('bc-banking:client:notify', src, 'Loan repayment could not be taken.', 'error')
        return
    end

    local changed = MySQL.update.await([[
        UPDATE bc_banking_v2_loans
        SET remaining_balance = GREATEST(remaining_balance - ?, 0),
            status = IF(remaining_balance - ? <= 0, 'paid', 'approved')
        WHERE id = ? AND status = 'approved' AND remaining_balance >= ?
    ]], { pay, pay, loanId, pay })
    if (tonumber(changed) or 0) < 1 then
        if loan.loan_type == 'business' then
            BCBanking.V2.ApplyDelta(loan.account_id, cid, pay, 'loan_repayment_reversal', 'Loan repayment failed; reversal')
        else
            Player.Functions.AddMoney(method, pay, 'bc-banking-v2-loan-refund')
        end
        TriggerClientEvent('bc-banking:client:notify', src, 'Repayment failed; funds were returned.', 'error')
        return
    end
    MySQL.insert.await(
        'INSERT INTO bc_banking_v2_loan_payments (loan_id, citizenid, amount) VALUES (?, ?, ?)',
        { loanId, cid, pay }
    )
    BCBanking.V2.Audit(cid, 'loan.repayment', 'loan', loanId, { amount = pay })
    TriggerClientEvent('bc-banking:client:notify', src, 'Loan repayment completed.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

RegisterCommand('bankloanreview', function(source, args)
    if source == 0 then
        print('[bc-banking] Use the in-game /bankloanreview command as an authorized admin.')
        return
    end
    if not isAdmin(source) then return end
    local loanId = tonumber(args[1])
    local decision = args[2]
    if not loanId or (decision ~= 'approve' and decision ~= 'reject') then
        TriggerClientEvent('bc-banking:client:notify', source, 'Usage: /bankloanreview [loanId] [approve/reject]', 'error')
        return
    end
    TriggerEvent('bc-banking:v2:reviewLoan', { loanId = loanId, decision = decision })
end, false)
