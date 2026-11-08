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

QBCore.Functions.CreateCallback('bc-banking:v2:getGoals', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not BCBanking.V2.Ready then cb({}); return end
    cb(MySQL.query.await([[
        SELECT g.id, g.account_id, g.name, g.target_amount, g.saved_amount, g.status, g.created_at
        FROM bc_banking_v2_savings_goals g
        WHERE g.citizenid = ? AND g.status = 'active'
        ORDER BY g.id DESC
    ]], { Player.PlayerData.citizenid }) or {})
end)

RegisterNetEvent('bc-banking:v2:createGoal', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local accountId = tonumber(data.accountId)
    local target = validAmount(data.targetAmount, tonumber(Config.V2.MaxPayment) or 1000000)
    local name = BCBanking.Trim(data.name):sub(1, 80)
    if not accountId or not target or name == '' or not BCBanking.V2.CanAccessAccount(accountId, cid, 'deposit') then
        TriggerClientEvent('bc-banking:client:notify', src, 'Enter valid savings goal details.', 'error')
        return
    end
    local account = MySQL.single.await(
        "SELECT id, account_type FROM bc_banking_v2_accounts WHERE id = ? AND status = 'active' LIMIT 1",
        { accountId }
    )
    if not account or account.account_type ~= 'savings' then
        TriggerClientEvent('bc-banking:client:notify', src, 'Savings goals must be linked to a savings account.', 'error')
        return
    end
    MySQL.insert.await([[
        INSERT INTO bc_banking_v2_savings_goals (account_id, citizenid, name, target_amount)
        VALUES (?, ?, ?, ?)
    ]], { accountId, cid, name, target })
    BCBanking.V2.Audit(cid, 'savings_goal.created', 'account', accountId, { name = name, target = target })
    TriggerClientEvent('bc-banking:client:notify', src, 'Savings goal created.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

RegisterNetEvent('bc-banking:v2:contributeGoal', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local goalId = tonumber(data.goalId)
    local amount = validAmount(data.amount, tonumber(Config.V2.MaxPayment) or 1000000)
    local method = data.paymentType == 'cash' and 'cash' or 'bank'
    local goal = goalId and MySQL.single.await([[
        SELECT id, account_id, target_amount, saved_amount
        FROM bc_banking_v2_savings_goals
        WHERE id = ? AND citizenid = ? AND status = 'active'
        LIMIT 1
    ]], { goalId, cid })
    if not goal or not amount or (tonumber(Player.PlayerData.money[method]) or 0) < amount then
        TriggerClientEvent('bc-banking:client:notify', src, 'Invalid goal or insufficient funds.', 'error')
        return
    end
    if Player.Functions.RemoveMoney(method, amount, 'bc-banking-v2-savings-goal') ~= true then return end
    local credited = BCBanking.V2.ApplyDelta(goal.account_id, cid, amount, 'savings_contribution', 'Savings goal contribution')
    if not credited then
        Player.Functions.AddMoney(method, amount, 'bc-banking-v2-savings-refund')
        TriggerClientEvent('bc-banking:client:notify', src, 'Contribution failed; funds were returned.', 'error')
        return
    end
    local newSaved = tonumber(goal.saved_amount) + amount
    local status = newSaved >= tonumber(goal.target_amount) and 'completed' or 'active'
    MySQL.update.await([[
        UPDATE bc_banking_v2_savings_goals
        SET saved_amount = ?, status = ?, completed_at = IF(? = 'completed', CURRENT_TIMESTAMP, completed_at)
        WHERE id = ? AND citizenid = ?
    ]], { newSaved, status, status, goalId, cid })
    BCBanking.V2.Audit(cid, 'savings_goal.contribution', 'goal', goalId, { amount = amount })
    TriggerClientEvent('bc-banking:client:notify', src, 'Savings contribution completed.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)
