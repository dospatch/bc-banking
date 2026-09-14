local QBCore = exports['qb-core']:GetCoreObject()

RegisterNetEvent('bc-banking:server:transfer', function(targetAccountNumber, amount, description)
    local source = source
    local Player = QBCore.Functions.GetPlayer(source)

    if not Player then
        return
    end

    targetAccountNumber = BCBanking.Trim(targetAccountNumber)
    amount = tonumber(amount)
    description = BCBanking.Trim(description)

    if not amount or amount <= 0 then
        TriggerClientEvent('bc-banking:client:notify', source, 'Invalid transfer amount.', 'error')
        return
    end

    amount = BCBanking.RoundMoney(amount)

    if amount > Config.MaxTransfer then
        TriggerClientEvent('bc-banking:client:notify', source, 'Transfer exceeds the maximum allowed amount.', 'error')
        return
    end

    if targetAccountNumber == '' then
        TriggerClientEvent('bc-banking:client:notify', source, 'Enter a valid account number.', 'error')
        return
    end

    local senderCitizenId = Player.PlayerData.citizenid

    local senderAccount = exports['bc-banking']:GetAccountByCitizenId(senderCitizenId)
    local receiverAccount = exports['bc-banking']:GetAccountByNumber(targetAccountNumber)

    if not senderAccount then
        senderAccount = exports['bc-banking']:CreateAccount(Player)
    end

    if not receiverAccount then
        TriggerClientEvent('bc-banking:client:notify', source, 'The destination account was not found.', 'error')
        return
    end

    if receiverAccount.citizenid == senderCitizenId then
        TriggerClientEvent('bc-banking:client:notify', source, 'You cannot transfer money to yourself.', 'error')
        return
    end

    local senderBank = tonumber(Player.PlayerData.money.bank) or 0

    local total = amount + Config.TransferFee

    if senderBank < total then
        TriggerClientEvent('bc-banking:client:notify', source, 'Insufficient bank funds.', 'error')
        return
    end

    local Receiver = QBCore.Functions.GetPlayerByCitizenId(receiverAccount.citizenid)

    Player.Functions.RemoveMoney(
        'bank',
        total,
        'bc-banking-transfer'
    )

    if Receiver then
        Receiver.Functions.AddMoney(
            'bank',
            amount,
            'bc-banking-transfer'
        )
    else
        MySQL.update.await(
            'UPDATE players SET money = JSON_SET(money, "$.bank", JSON_EXTRACT(money, "$.bank") + ?) WHERE citizenid = ?',
            {
                amount,
                receiverAccount.citizenid
            }
        )
    end

    local senderDescription =
        description ~= '' and description or 'Bank transfer sent'

    exports['bc-banking']:AddTransaction(
        senderCitizenId,
        'transfer_out',
        amount,
        senderDescription,
        receiverAccount.account_number
    )

    exports['bc-banking']:AddTransaction(
        receiverAccount.citizenid,
        'transfer_in',
        amount,
        'Bank transfer received',
        senderAccount.account_number
    )

    TriggerClientEvent(
        'bc-banking:client:notify',
        source,
        'Transfer completed successfully.',
        'success'
    )
end)
