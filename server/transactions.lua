local QBCore = exports['qb-core']:GetCoreObject()

exports('AddTransaction', function(citizenid, transactionType, amount, description, relatedAccount)
    amount = BCBanking.RoundMoney(amount)

    local transactionId = MySQL.insert.await(
        [[
            INSERT INTO bc_banking_transactions
            (citizenid, transaction_type, amount, description, related_account)
            VALUES (?, ?, ?, ?, ?)
        ]],
        {
            citizenid,
            transactionType,
            amount,
            description or 'Bank transaction',
            relatedAccount or nil
        }
    )

    if transactionId and BCBanking.SendDiscordLog then
        local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
        local characterName = 'Offline player'
        if Player and Player.PlayerData and Player.PlayerData.charinfo then
            local info = Player.PlayerData.charinfo
            characterName = ((info.firstname or '') .. ' ' .. (info.lastname or '')):gsub('^%s*(.-)%s*$', '%1')
        end

        BCBanking.SendDiscordLog({
            title = 'Bank Transaction: ' .. tostring(transactionType),
            color = (transactionType == 'deposit' or transactionType == 'transfer_in') and 0x2ECC71 or 0xE67E22,
            fields = {
                { name = 'Character', value = characterName, inline = true },
                { name = 'Citizen ID', value = tostring(citizenid), inline = true },
                { name = 'Amount', value = tostring(Config.Currency or '$') .. string.format('%.2f', amount), inline = true },
                { name = 'Description', value = tostring(description or 'Bank transaction'):sub(1, 900), inline = false },
                { name = 'Related Account', value = tostring(relatedAccount or 'N/A'), inline = true },
                { name = 'Transaction ID', value = tostring(transactionId), inline = true }
            }
        })
    end

    return transactionId
end)

exports('GetTransactions', function(citizenid)
    return MySQL.query.await(
        [[
            SELECT
                id,
                transaction_type,
                amount,
                description,
                related_account,
                created_at
            FROM bc_banking_transactions
            WHERE citizenid = ?
            ORDER BY id DESC
            LIMIT ?
        ]],
        {
            citizenid,
            Config.TransactionHistoryLimit
        }
    ) or {}
end)
