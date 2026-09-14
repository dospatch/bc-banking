-- BC-Banking V1 uses the QBCore player bank account as the primary account.
-- This file is reserved for future multi-account / savings account features.

exports('GetAccount', function(source)
    local QBCore = exports['qb-core']:GetCoreObject()
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return nil end

    return {
        citizenid = Player.PlayerData.citizenid,
        balance = Player.PlayerData.money.bank or 0
    }
end)
