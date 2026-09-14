local QBCore = exports['qb-core']:GetCoreObject()

QBCore.Functions.CreateCallback('bc-banking:server:getPlayerByAccount', function(source, cb, accountNumber)
    accountNumber = BCBanking.Trim(accountNumber)

    if accountNumber == '' then
        cb(nil)
        return
    end

    local account = exports['bc-banking']:GetAccountByNumber(accountNumber)

    if not account then
        cb(nil)
        return
    end

    local Player = QBCore.Functions.GetPlayerByCitizenId(account.citizenid)

    local displayName = 'Account Holder'

    if Player then
        displayName =
            Player.PlayerData.charinfo.firstname ..
            ' ' ..
            Player.PlayerData.charinfo.lastname
    else
        local character = MySQL.single.await(
            'SELECT charinfo FROM players WHERE citizenid = ? LIMIT 1',
            { account.citizenid }
        )

        if character and character.charinfo then
            local charinfo = json.decode(character.charinfo)

            if charinfo then
                displayName =
                    (charinfo.firstname or '') ..
                    ' ' ..
                    (charinfo.lastname or '')
            end
        end
    end

    cb({
        account_number = account.account_number,
        name = BCBanking.Trim(displayName)
    })
end)
