local QBCore = exports['qb-core']:GetCoreObject()

RegisterNetEvent('bc-banking:client:setData', function(data)
    if not data then return end
    SendNUIMessage({
        action = 'setData',
        data = data
    })
end)

RegisterNetEvent('bc-banking:client:close', function()
    CloseBCBanking()
end)
