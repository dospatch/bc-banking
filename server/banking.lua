local QBCore = exports['qb-core']:GetCoreObject()

RegisterNetEvent('bc-banking:server:deposit', function(amount)
    local source = source
    local Player = QBCore.Functions.GetPlayer(source)

    if not Player then
        return
    end

    amount = tonumber(amount)

    if not amount or amount <= 0 then
        TriggerClientEvent('bc-banking:client:notify', source, 'Invalid deposit amount.', 'error')
        return
    end

    amount = BCBanking.RoundMoney(amount)

    if amount > Config.MaxDeposit then
        TriggerClientEvent('bc-banking:client:notify', source, 'Deposit exceeds the maximum allowed amount.', 'error')
        return
    end

    local cash = tonumber(Player.PlayerData.money.cash) or 0

    if cash < amount then
        TriggerClientEvent('bc-banking:client:notify', source, 'Insufficient cash.', 'error')
        return
    end

    Player.Functions.RemoveMoney(
        'cash',
        amount,
        'bc-banking-deposit'
    )

    Player.Functions.AddMoney(
        'bank',
        amount,
        'bc-banking-deposit'
    )

    exports['bc-banking']:AddTransaction(
        Player.PlayerData.citizenid,
        'deposit',
        amount,
        'Cash deposit'
    )

    TriggerClientEvent('bc-banking:client:notify', source, 'Deposit completed.', 'success')
end)

RegisterNetEvent('bc-banking:server:withdraw', function(amount)
    local source = source
    local Player = QBCore.Functions.GetPlayer(source)

    if not Player then
        return
    end

    amount = tonumber(amount)

    if not amount or amount <= 0 then
        TriggerClientEvent('bc-banking:client:notify', source, 'Invalid withdrawal amount.', 'error')
        return
    end

    amount = BCBanking.RoundMoney(amount)

    if amount > Config.MaxWithdrawal then
        TriggerClientEvent('bc-banking:client:notify', source, 'Withdrawal exceeds the maximum allowed amount.', 'error')
        return
    end

    local bank = tonumber(Player.PlayerData.money.bank) or 0

    if bank < amount then
        TriggerClientEvent('bc-banking:client:notify', source, 'Insufficient bank funds.', 'error')
        return
    end

    Player.Functions.RemoveMoney(
        'bank',
        amount,
        'bc-banking-withdraw'
    )

    Player.Functions.AddMoney(
        'cash',
        amount,
        'bc-banking-withdraw'
    )

    exports['bc-banking']:AddTransaction(
        Player.PlayerData.citizenid,
        'withdraw',
        amount,
        'Cash withdrawal'
    )

    TriggerClientEvent('bc-banking:client:notify', source, 'Withdrawal completed.', 'success')
end)
