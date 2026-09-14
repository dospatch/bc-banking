local QBCore = exports['qb-core']:GetCoreObject()

RegisterNetEvent('bc-banking:client:open', function()
    QBCore.Functions.TriggerCallback(
        'bc-banking:server:getDashboard',
        function(data)
            if not data then
                QBCore.Functions.Notify('Unable to load your bank account.', 'error')
                return
            end

            SetNuiFocus(true, true)

            SendNUIMessage({
                action = 'open',
                data = data
            })
        end
    )
end)
