RegisterNUICallback('close', function(_, cb)
    CloseBCBanking()
    cb({ ok = true })
end)

RegisterNUICallback('deposit', function(data, cb)
    TriggerServerEvent('bc-banking:server:deposit', tonumber(data.amount))
    cb({ ok = true })
end)

RegisterNUICallback('withdraw', function(data, cb)
    TriggerServerEvent('bc-banking:server:withdraw', tonumber(data.amount))
    cb({ ok = true })
end)

RegisterNUICallback('transfer', function(data, cb)
    TriggerServerEvent('bc-banking:server:transfer', tonumber(data.target), tonumber(data.amount), data.note or '')
    cb({ ok = true })
end)

RegisterNUICallback('refresh', function(_, cb)
    TriggerServerEvent('bc-banking:client:requestData')
    cb({ ok = true })
end)

RegisterNetEvent('bc-banking:client:nuiClose', function()
    CloseBCBanking()
end)

CreateThread(function()
    while true do
        Wait(0)
        if IsControlJustReleased(0, 322) then
            if exports['bc-banking']:IsBankMenuOpen() then
                CloseBCBanking()
            end
        end
    end
end)
