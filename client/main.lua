local QBCore = exports['qb-core']:GetCoreObject()

BCBanking = BCBanking or {}

function BCBanking.OpenBank(isATM)
    TriggerEvent('bc-banking:client:open', isATM == true)
end

function BCBanking.CloseBank()
    SetNuiFocus(false, false)

    SendNUIMessage({
        action = 'close'
    })
end

RegisterNetEvent('bc-banking:client:notify', function(message, messageType)
    QBCore.Functions.Notify(message, messageType or 'primary')
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        SetNuiFocus(false, false)
    end
end)
