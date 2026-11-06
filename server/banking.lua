local QBCore = exports['qb-core']:GetCoreObject()
local function notify(src, msg, kind) TriggerClientEvent('bc-banking:client:notify', src, msg, kind or 'error') end
local function validAmount(value, maximum)
    local amount = tonumber(value)
    if not amount or amount ~= amount or amount == math.huge or amount == -math.huge then return nil end
    amount = BCBanking.RoundMoney(amount)
    if amount <= 0 or amount > maximum then return nil end
    return amount
end

RegisterNetEvent('bc-banking:server:deposit', function(value)
    local src = source
    local initial = QBCore.Functions.GetPlayer(src)
    if not initial then return end
    local cid = initial.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then notify(src, 'Please wait a moment before making another banking request.') return end
    local amount = validAmount(value, Config.MaxDeposit)
    if not amount then notify(src, 'Enter a valid deposit amount within the transaction limit.') return end

    local ok, message = BCBanking.WithPlayerLocks({ cid }, function()
        local Player = QBCore.Functions.GetPlayer(src)
        if not Player or Player.PlayerData.citizenid ~= cid then return false, 'Your banking session is no longer available.' end
        if (tonumber(Player.PlayerData.money.cash) or 0) < amount then return false, 'Insufficient cash.' end
        if Player.Functions.RemoveMoney('cash', amount, 'bc-banking-deposit') ~= true then
            return false, 'Cash could not be removed. No deposit was made.'
        end
        if Player.Functions.AddMoney('bank', amount, 'bc-banking-deposit') ~= true then
            local refunded = Player.Functions.AddMoney('cash', amount, 'bc-banking-deposit-refund') == true
            if not refunded then print(('[bc-banking] CRITICAL: deposit credit and cash refund failed for %s'):format(cid)) end
            return false, refunded and 'Your bank account could not be credited. The deposit was reversed.' or 'Deposit failed and refund could not be confirmed. Contact staff.'
        end
        local synced, syncError = pcall(function() return exports['bc-banking']:SyncAccountBalance(cid, Player.PlayerData.money.bank) end)
        if not synced then print(('[bc-banking] Could not sync account balance mirror for %s: %s'):format(cid, syncError)) end
        local logged, id = pcall(function() return exports['bc-banking']:AddTransaction(cid, 'deposit', amount, 'Cash deposit') end)
        if not logged or not id then print(('[bc-banking] Deposit succeeded but transaction logging failed for %s.'):format(cid)) end
        return true, 'Deposit completed.'
    end)
    notify(src, message or (ok and 'Deposit completed.' or 'Deposit failed.'), ok and 'success' or 'error')
end)

RegisterNetEvent('bc-banking:server:withdraw', function(value)
    local src = source
    local initial = QBCore.Functions.GetPlayer(src)
    if not initial then return end
    local cid = initial.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then notify(src, 'Please wait a moment before making another banking request.') return end
    local amount = validAmount(value, Config.MaxWithdrawal)
    if not amount then notify(src, 'Enter a valid withdrawal amount within the transaction limit.') return end

    local ok, message = BCBanking.WithPlayerLocks({ cid }, function()
        local Player = QBCore.Functions.GetPlayer(src)
        if not Player or Player.PlayerData.citizenid ~= cid then return false, 'Your banking session is no longer available.' end
        if (tonumber(Player.PlayerData.money.bank) or 0) < amount then return false, 'Insufficient bank funds.' end
        if Player.Functions.RemoveMoney('bank', amount, 'bc-banking-withdraw') ~= true then
            return false, 'Bank funds could not be removed. No withdrawal was made.'
        end
        if Player.Functions.AddMoney('cash', amount, 'bc-banking-withdraw') ~= true then
            local refunded = Player.Functions.AddMoney('bank', amount, 'bc-banking-withdraw-refund') == true
            if not refunded then print(('[bc-banking] CRITICAL: cash credit and bank refund failed for %s'):format(cid)) end
            return false, refunded and 'Cash could not be credited. The withdrawal was reversed.' or 'Withdrawal failed and refund could not be confirmed. Contact staff.'
        end
        local synced, syncError = pcall(function() return exports['bc-banking']:SyncAccountBalance(cid, Player.PlayerData.money.bank) end)
        if not synced then print(('[bc-banking] Could not sync account balance mirror for %s: %s'):format(cid, syncError)) end
        local logged, id = pcall(function() return exports['bc-banking']:AddTransaction(cid, 'withdraw', amount, 'Cash withdrawal') end)
        if not logged or not id then print(('[bc-banking] Withdrawal succeeded but transaction logging failed for %s.'):format(cid)) end
        return true, 'Withdrawal completed.'
    end)
    notify(src, message or (ok and 'Withdrawal completed.' or 'Withdrawal failed.'), ok and 'success' or 'error')
end)
