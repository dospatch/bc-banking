local QBCore = exports['qb-core']:GetCoreObject()

BCBanking = BCBanking or {}

local function getPlayer(source)
    return QBCore.Functions.GetPlayer(source)
end

exports('GetBankBalance', function(source)
    local Player = getPlayer(source)

    if not Player then
        return 0
    end

    return tonumber(Player.PlayerData.money.bank) or 0
end)

QBCore.Functions.CreateCallback('bc-banking:server:getDashboard', function(source, cb)
    local Player = getPlayer(source)

    if not Player then
        cb(nil)
        return
    end

    local citizenid = Player.PlayerData.citizenid

    local account = exports['bc-banking']:GetAccountByCitizenId(citizenid)

    if not account then
        exports['bc-banking']:CreateAccount(Player)
        account = exports['bc-banking']:GetAccountByCitizenId(citizenid)
    end

    local transactions = exports['bc-banking']:GetTransactions(citizenid)

    cb({
        player = {
            name = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname,
            citizenid = citizenid
        },
        cash = tonumber(Player.PlayerData.money.cash) or 0,
        bank = tonumber(Player.PlayerData.money.bank) or 0,
        account = account,
        transactions = transactions
    })
end)
