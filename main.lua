local QBCore = exports['qb-core']:GetCoreObject()

local function getPlayer(source)
    return QBCore.Functions.GetPlayer(source)
end

local function buildPlayerData(Player)
    local pd = Player.PlayerData
    return {
        name = ((pd.charinfo and pd.charinfo.firstname) or 'Citizen') .. ' ' .. ((pd.charinfo and pd.charinfo.lastname) or ''),
        citizenid = pd.citizenid,
        cash = pd.money and pd.money.cash or 0,
        bank = pd.money and pd.money.bank or 0,
        job = pd.job and pd.job.label or 'Citizen'
    }
end

QBCore.Functions.CreateCallback('bc-banking:server:getData', function(source, cb)
    local Player = getPlayer(source)
    if not Player then
        cb(nil)
        return
    end

    local citizenid = Player.PlayerData.citizenid
    local transactions = exports['bc-banking']:GetTransactions(citizenid, Config.TransactionHistoryLimit)

    cb({
        player = buildPlayerData(Player),
        transactions = transactions or {}
    })
end)

RegisterNetEvent('bc-banking:server:deposit', function(amount)
    local source = source
    local Player = getPlayer(source)
    amount = tonumber(amount)

    if not Player or not BCBanking.IsValidAmount(amount, Config.Deposit.Minimum, Config.Deposit.Maximum) then
        TriggerClientEvent('QBCore:Notify', source, Config.Messages.InvalidAmount, 'error')
        return
    end

    if Player.Functions.RemoveMoney('cash', amount, 'bc-banking-deposit') then
        Player.Functions.AddMoney('bank', amount, 'bc-banking-deposit')
        exports['bc-banking']:AddTransaction(Player.PlayerData.citizenid, 'deposit', amount, 'Cash deposit')
        TriggerClientEvent('QBCore:Notify', source, Config.Messages.DepositSuccess, 'success')
        TriggerClientEvent('bc-banking:client:refresh', source)
    else
        TriggerClientEvent('QBCore:Notify', source, Config.Messages.NoMoney, 'error')
    end
end)

RegisterNetEvent('bc-banking:server:withdraw', function(amount)
    local source = source
    local Player = getPlayer(source)
    amount = tonumber(amount)

    if not Player or not BCBanking.IsValidAmount(amount, Config.Withdraw.Minimum, Config.Withdraw.Maximum) then
        TriggerClientEvent('QBCore:Notify', source, Config.Messages.InvalidAmount, 'error')
        return
    end

    if Player.Functions.RemoveMoney('bank', amount, 'bc-banking-withdraw') then
        Player.Functions.AddMoney('cash', amount, 'bc-banking-withdraw')
        exports['bc-banking']:AddTransaction(Player.PlayerData.citizenid, 'withdraw', amount, 'Cash withdrawal')
        TriggerClientEvent('QBCore:Notify', source, Config.Messages.WithdrawSuccess, 'success')
        TriggerClientEvent('bc-banking:client:refresh', source)
    else
        TriggerClientEvent('QBCore:Notify', source, Config.Messages.NoMoney, 'error')
    end
end)

exports('GetBankBalance', function(source)
    local Player = getPlayer(source)
    if not Player then return 0 end
    return Player.PlayerData.money.bank or 0
end)

exports('GetCashBalance', function(source)
    local Player = getPlayer(source)
    if not Player then return 0 end
    return Player.PlayerData.money.cash or 0
end)

RegisterNetEvent('bc-banking:client:requestData', function()
    local source = source
    local Player = getPlayer(source)
    if not Player then return end

    local transactions = exports['bc-banking']:GetTransactions(Player.PlayerData.citizenid, Config.TransactionHistoryLimit)
    TriggerClientEvent('bc-banking:client:setData', source, {
        player = buildPlayerData(Player),
        transactions = transactions or {}
    })
end)
