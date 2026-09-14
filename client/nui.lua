RegisterNUICallback('close', function(_, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('refresh', function(_, cb)
    QBCore.Functions.TriggerCallback(
        'bc-banking:server:getDashboard',
        function(data)
            cb(data or {})
        end
    )
end)

RegisterNUICallback('deposit', function(data, cb)
    TriggerServerEvent(
        'bc-banking:server:deposit',
        tonumber(data.amount)
    )

    cb('ok')
end)

RegisterNUICallback('withdraw', function(data, cb)
    TriggerServerEvent(
        'bc-banking:server:withdraw',
        tonumber(data.amount)
    )

    cb('ok')
end)

RegisterNUICallback('transfer', function(data, cb)
    TriggerServerEvent(
        'bc-banking:server:transfer',
        data.account,
        tonumber(data.amount),
        data.description
    )

    cb('ok')
end)

RegisterNUICallback('lookupAccount', function(data, cb)
    QBCore.Functions.TriggerCallback(
        'bc-banking:server:getPlayerByAccount',
        function(result)
            cb(result or {})
        end,
        data.account
    )
end)

RegisterCommand('+bc_banking_close', function()
    BCBanking.CloseBank()
end, false)

RegisterKeyMapping(
    '+bc_banking_close',
    'Close BC-Banking',
    'keyboard',
    'ESC'
)
