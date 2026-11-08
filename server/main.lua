local QBCore = exports['qb-core']:GetCoreObject()

BCBanking = BCBanking or {}

local function getPlayer(source)
    return QBCore.Functions.GetPlayer(source)
end

exports('GetBankBalance', function(source)
    local Player = getPlayer(source)
    if not Player then return 0 end
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
        account = exports['bc-banking']:CreateAccount(Player)
    else
        -- QBCore's live balance is authoritative; keep the account mirror current
        -- whenever the player opens or refreshes the banking dashboard.
        local balance = tonumber(Player.PlayerData.money.bank) or 0
        local syncOk, syncError = pcall(function()
            exports['bc-banking']:SyncAccountBalance(citizenid, balance)
        end)
        if not syncOk then
            print(('[bc-banking] Dashboard balance mirror sync failed for %s: %s'):format(citizenid, syncError))
        else
            account.balance = balance
        end
    end

    local transactions = exports['bc-banking']:GetTransactions(citizenid)
    local charinfo = Player.PlayerData.charinfo or {}

    cb({
        player = {
            name = (charinfo.firstname or '') .. ' ' .. (charinfo.lastname or ''),
            citizenid = citizenid
        },
        cash = tonumber(Player.PlayerData.money.cash) or 0,
        bank = tonumber(Player.PlayerData.money.bank) or 0,
        currency = Config.Currency or '$',
        account = account,
        transactions = transactions
    })
end)
