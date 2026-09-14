local QBCore = exports['qb-core']:GetCoreObject()

BCBanking = BCBanking or {}

function BCBanking.OpenBank()
    TriggerEvent('bc-banking:client:open')
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

CreateThread(function()
    while true do
        local sleep = 1000
        local playerPed = PlayerPedId()
        local coords = GetEntityCoords(playerPed)

        for _, location in ipairs(Config.BankLocations) do
            local distance = #(coords - location)

            if distance < 15.0 then
                sleep = 0

                DrawMarker(
                    2,
                    location.x,
                    location.y,
                    location.z,
                    0.0,
                    0.0,
                    0.0,
                    0.0,
                    0.0,
                    0.0,
                    0.25,
                    0.25,
                    0.25,
                    255,
                    255,
                    255,
                    150,
                    false,
                    true,
                    2,
                    false,
                    nil,
                    nil,
                    false
                )

                if distance < 2.0 then
                    BeginTextCommandDisplayHelp('STRING')
                    AddTextComponentSubstringPlayerName('Press ~INPUT_CONTEXT~ to open ~b~BC-Banking~s~')
                    EndTextCommandDisplayHelp(0, false, true, -1)

                    if IsControlJustReleased(0, 38) then
                        BCBanking.OpenBank()
                    end
                end
            end
        end

        Wait(sleep)
    end
end)
