local QBCore = exports['qb-core']:GetCoreObject()

RegisterNetEvent('bc-banking:server:transfer', function(targetSource, amount, note)
    local source = source
    local sender = QBCore.Functions.GetPlayer(source)
    local target = QBCore.Functions.GetPlayer(tonumber(targetSource))
    amount = tonumber(amount)
    note = tostring(note or ''):sub(1, 100)

    if not Config.Transfer.Enabled then
        TriggerClientEvent('QBCore:Notify', source, Config.Messages.TransferDisabled, 'error')
        return
    end

    if not sender or not BCBanking.IsValidAmount(amount, Config.Transfer.Minimum, Config.Transfer.Maximum) then
        TriggerClientEvent('QBCore:Notify', source, Config.Messages.InvalidAmount, 'error')
        return
    end

    if not target then
        TriggerClientEvent('QBCore:Notify', source, Config.Messages.TargetNotFound, 'error')
        return
    end

    if target.PlayerData.source == sender.PlayerData.source then
        TriggerClientEvent('QBCore:Notify', source, Config.Messages.SamePlayer, 'error')
        return
    end

    local fee = math.floor(tonumber(Config.Transfer.Fee) or 0)
    local total = amount + fee

    if not sender.Functions.RemoveMoney('bank', total, 'bc-banking-transfer') then
        TriggerClientEvent('QBCore:Notify', source, Config.Messages.NoMoney, 'error')
        return
    end

    target.Functions.AddMoney('bank', amount, 'bc-banking-transfer')

    local senderCid = sender.PlayerData.citizenid
    local targetCid = target.PlayerData.citizenid
    local senderName = ((sender.PlayerData.charinfo and sender.PlayerData.charinfo.firstname) or 'Citizen') .. ' ' .. ((sender.PlayerData.charinfo and sender.PlayerData.charinfo.lastname) or '')
    local targetName = ((target.PlayerData.charinfo and target.PlayerData.charinfo.firstname) or 'Citizen') .. ' ' .. ((target.PlayerData.charinfo and target.PlayerData.charinfo.lastname) or '')

    exports['bc-banking']:AddTransaction(senderCid, 'transfer_sent', amount, ('Transfer to %s%s'):format(targetName, note ~= '' and (' - ' .. note) or ''))
    exports['bc-banking']:AddTransaction(targetCid, 'transfer_received', amount, ('Transfer from %s%s'):format(senderName, note ~= '' and (' - ' .. note) or ''))

    TriggerClientEvent('QBCore:Notify', source, Config.Messages.TransferSuccess, 'success')
    TriggerClientEvent('QBCore:Notify', target.PlayerData.source, ('You received %s.'):format(BCBanking.FormatMoney(amount)), 'success')
    TriggerClientEvent('bc-banking:client:refresh', source)
    TriggerClientEvent('bc-banking:client:refresh', target.PlayerData.source)
end)
