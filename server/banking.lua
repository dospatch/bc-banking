local QBCore = exports['qb-core']:GetCoreObject()

local function notify(src, msg, kind)
    TriggerClientEvent('bc-banking:client:notify', src, msg, kind or 'error')
end

local function validAmount(value, maximum)
    local amount = tonumber(value)
    if not amount or amount ~= amount or amount == math.huge or amount == -math.huge then return nil end
    amount = BCBanking.RoundMoney(amount)
    if amount <= 0 or amount > maximum then return nil end
    return amount
end

local function safeMoneyCall(Player, method, account, amount, reason)
    local callOk, result = pcall(function()
        return Player.Functions[method](account, amount, reason)
    end)
    return callOk and result == true, callOk and nil or result
end

local function refundOrLog(Player, account, amount, reason, citizenid)
    local refundOk, refunded = safeMoneyCall(Player, 'AddMoney', account, amount, reason)
    if not refundOk then
        print(('[bc-banking] CRITICAL: refund failed for %s (%s %.2f). Contact staff and reconcile manually.'):format(citizenid, account, amount))
    end
    return refundOk
end

RegisterNetEvent('bc-banking:server:deposit', function(value, isATM)
    local src = source
    local initial = QBCore.Functions.GetPlayer(src)
    if not initial then return end

    local cid = initial.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then
        notify(src, 'Please wait a moment before making another banking request.')
        return
    end

    local amount = validAmount(value, Config.MaxDeposit)
    local fee = isATM == true and BCBanking.RoundMoney(Config.V2 and Config.V2.ATMDepositFee or 0) or 0
    if not amount or fee < 0 then
        notify(src, 'Enter a valid deposit amount within the transaction limit.')
        return
    end

    local ok, message = BCBanking.WithPlayerLocks({ cid }, function()
        local Player = QBCore.Functions.GetPlayer(src)
        if not Player or Player.PlayerData.citizenid ~= cid then
            return false, 'Your banking session is no longer available.'
        end

        if (tonumber(Player.PlayerData.money.cash) or 0) < amount + fee then
            return false, 'Insufficient cash.'
        end

        local removed = safeMoneyCall(Player, 'RemoveMoney', 'cash', amount + fee, 'bc-banking-deposit')
        if not removed then
            return false, 'Cash could not be removed. No deposit was made.'
        end

        local credited = safeMoneyCall(Player, 'AddMoney', 'bank', amount, 'bc-banking-deposit')
        if not credited then
            local refunded = refundOrLog(Player, 'cash', amount + fee, 'bc-banking-deposit-refund', cid)
            return false, refunded
                and 'Your bank account could not be credited. The deposit was reversed.'
                or 'Deposit failed and refund could not be confirmed. Contact staff.'
        end

        local synced, syncError = pcall(function()
            exports['bc-banking']:SyncAccountBalance(cid, Player.PlayerData.money.bank)
        end)
        if not synced then
            print(('[bc-banking] Could not sync account balance mirror for %s: %s'):format(cid, syncError))
        end

        local logged, id = pcall(function()
            return exports['bc-banking']:AddTransaction(cid, 'deposit', amount, 'Cash deposit')
        end)
        if not logged or not id then
            print(('[bc-banking] Deposit succeeded but transaction logging failed for %s.'):format(cid))
        end

        if fee > 0 then pcall(function() exports['bc-banking']:AddTransaction(cid, 'fee', fee, 'ATM deposit fee') end) end
        return true, fee > 0 and ('Deposit completed. ATM fee: ' .. (Config.Currency or '
    end)

    notify(src, message or (ok and 'Deposit completed.' or 'Deposit failed.'), ok and 'success' or 'error')
end)

RegisterNetEvent('bc-banking:server:withdraw', function(value, isATM)
    local src = source
    local initial = QBCore.Functions.GetPlayer(src)
    if not initial then return end

    local cid = initial.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then
        notify(src, 'Please wait a moment before making another banking request.')
        return
    end

    local amount = validAmount(value, Config.MaxWithdrawal)
    local fee = isATM == true and BCBanking.RoundMoney(Config.V2 and Config.V2.ATMWithdrawalFee or 0) or 0
    if not amount or fee < 0 then
        notify(src, 'Enter a valid withdrawal amount within the transaction limit.')
        return
    end

    local ok, message = BCBanking.WithPlayerLocks({ cid }, function()
        local Player = QBCore.Functions.GetPlayer(src)
        if not Player or Player.PlayerData.citizenid ~= cid then
            return false, 'Your banking session is no longer available.'
        end

        if (tonumber(Player.PlayerData.money.bank) or 0) < amount + fee then
            return false, 'Insufficient bank funds.'
        end

        local removed = safeMoneyCall(Player, 'RemoveMoney', 'bank', amount + fee, 'bc-banking-withdraw')
        if not removed then
            return false, 'Bank funds could not be removed. No withdrawal was made.'
        end

        local credited = safeMoneyCall(Player, 'AddMoney', 'cash', amount, 'bc-banking-withdraw')
        if not credited then
            local refunded = refundOrLog(Player, 'bank', amount + fee, 'bc-banking-withdraw-refund', cid)
            return false, refunded
                and 'Cash could not be credited. The withdrawal was reversed.'
                or 'Withdrawal failed and refund could not be confirmed. Contact staff.'
        end

        local synced, syncError = pcall(function()
            exports['bc-banking']:SyncAccountBalance(cid, Player.PlayerData.money.bank)
        end)
        if not synced then
            print(('[bc-banking] Could not sync account balance mirror for %s: %s'):format(cid, syncError))
        end

        local logged, id = pcall(function()
            return exports['bc-banking']:AddTransaction(cid, 'withdraw', amount, 'Cash withdrawal')
        end)
        if not logged or not id then
            print(('[bc-banking] Withdrawal succeeded but transaction logging failed for %s.'):format(cid))
        end

        if fee > 0 then pcall(function() exports['bc-banking']:AddTransaction(cid, 'fee', fee, 'ATM withdrawal fee') end) end
        return true, fee > 0 and ('Withdrawal completed. ATM fee: ' .. (Config.Currency or '
    end)

    notify(src, message or (ok and 'Withdrawal completed.' or 'Withdrawal failed.'), ok and 'success' or 'error')
end)
) .. string.format('%.2f', fee)) or 'Deposit completed.'
    end)

    notify(src, message or (ok and 'Deposit completed.' or 'Deposit failed.'), ok and 'success' or 'error')
end)

RegisterNetEvent('bc-banking:server:withdraw', function(value)
    local src = source
    local initial = QBCore.Functions.GetPlayer(src)
    if not initial then return end

    local cid = initial.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then
        notify(src, 'Please wait a moment before making another banking request.')
        return
    end

    local amount = validAmount(value, Config.MaxWithdrawal)
    if not amount then
        notify(src, 'Enter a valid withdrawal amount within the transaction limit.')
        return
    end

    local ok, message = BCBanking.WithPlayerLocks({ cid }, function()
        local Player = QBCore.Functions.GetPlayer(src)
        if not Player or Player.PlayerData.citizenid ~= cid then
            return false, 'Your banking session is no longer available.'
        end

        if (tonumber(Player.PlayerData.money.bank) or 0) < amount then
            return false, 'Insufficient bank funds.'
        end

        local removed = safeMoneyCall(Player, 'RemoveMoney', 'bank', amount, 'bc-banking-withdraw')
        if not removed then
            return false, 'Bank funds could not be removed. No withdrawal was made.'
        end

        local credited = safeMoneyCall(Player, 'AddMoney', 'cash', amount, 'bc-banking-withdraw')
        if not credited then
            local refunded = refundOrLog(Player, 'bank', amount, 'bc-banking-withdraw-refund', cid)
            return false, refunded
                and 'Cash could not be credited. The withdrawal was reversed.'
                or 'Withdrawal failed and refund could not be confirmed. Contact staff.'
        end

        local synced, syncError = pcall(function()
            exports['bc-banking']:SyncAccountBalance(cid, Player.PlayerData.money.bank)
        end)
        if not synced then
            print(('[bc-banking] Could not sync account balance mirror for %s: %s'):format(cid, syncError))
        end

        local logged, id = pcall(function()
            return exports['bc-banking']:AddTransaction(cid, 'withdraw', amount, 'Cash withdrawal')
        end)
        if not logged or not id then
            print(('[bc-banking] Withdrawal succeeded but transaction logging failed for %s.'):format(cid))
        end

        return true, 'Withdrawal completed.'
    end)

    notify(src, message or (ok and 'Withdrawal completed.' or 'Withdrawal failed.'), ok and 'success' or 'error')
end)
) .. string.format('%.2f', fee)) or 'Withdrawal completed.'
    end)

    notify(src, message or (ok and 'Withdrawal completed.' or 'Withdrawal failed.'), ok and 'success' or 'error')
end)
) .. string.format('%.2f', fee)) or 'Deposit completed.'
    end)

    notify(src, message or (ok and 'Deposit completed.' or 'Deposit failed.'), ok and 'success' or 'error')
end)

RegisterNetEvent('bc-banking:server:withdraw', function(value)
    local src = source
    local initial = QBCore.Functions.GetPlayer(src)
    if not initial then return end

    local cid = initial.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then
        notify(src, 'Please wait a moment before making another banking request.')
        return
    end

    local amount = validAmount(value, Config.MaxWithdrawal)
    if not amount then
        notify(src, 'Enter a valid withdrawal amount within the transaction limit.')
        return
    end

    local ok, message = BCBanking.WithPlayerLocks({ cid }, function()
        local Player = QBCore.Functions.GetPlayer(src)
        if not Player or Player.PlayerData.citizenid ~= cid then
            return false, 'Your banking session is no longer available.'
        end

        if (tonumber(Player.PlayerData.money.bank) or 0) < amount then
            return false, 'Insufficient bank funds.'
        end

        local removed = safeMoneyCall(Player, 'RemoveMoney', 'bank', amount, 'bc-banking-withdraw')
        if not removed then
            return false, 'Bank funds could not be removed. No withdrawal was made.'
        end

        local credited = safeMoneyCall(Player, 'AddMoney', 'cash', amount, 'bc-banking-withdraw')
        if not credited then
            local refunded = refundOrLog(Player, 'bank', amount, 'bc-banking-withdraw-refund', cid)
            return false, refunded
                and 'Cash could not be credited. The withdrawal was reversed.'
                or 'Withdrawal failed and refund could not be confirmed. Contact staff.'
        end

        local synced, syncError = pcall(function()
            exports['bc-banking']:SyncAccountBalance(cid, Player.PlayerData.money.bank)
        end)
        if not synced then
            print(('[bc-banking] Could not sync account balance mirror for %s: %s'):format(cid, syncError))
        end

        local logged, id = pcall(function()
            return exports['bc-banking']:AddTransaction(cid, 'withdraw', amount, 'Cash withdrawal')
        end)
        if not logged or not id then
            print(('[bc-banking] Withdrawal succeeded but transaction logging failed for %s.'):format(cid))
        end

        return true, 'Withdrawal completed.'
    end)

    notify(src, message or (ok and 'Withdrawal completed.' or 'Withdrawal failed.'), ok and 'success' or 'error')
end)
