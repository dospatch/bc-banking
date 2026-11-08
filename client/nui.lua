local QBCore = exports['qb-core']:GetCoreObject()

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


-- V2 NUI bridge. All money and permission checks remain server-authoritative.
local function v2Callback(name, data, cb)
    QBCore.Functions.TriggerCallback('bc-banking:v2:' .. name, function(result)
        cb(result or {})
    end, data)
end

RegisterNUICallback('v2Accounts', function(_, cb) v2Callback('getAccounts', nil, cb) end)
RegisterNUICallback('v2Goals', function(_, cb) v2Callback('getGoals', nil, cb) end)
RegisterNUICallback('v2Cards', function(_, cb) v2Callback('getCards', nil, cb) end)
RegisterNUICallback('v2Loans', function(_, cb) v2Callback('getLoans', nil, cb) end)
RegisterNUICallback('v2Businesses', function(_, cb) v2Callback('getBusinesses', nil, cb) end)
RegisterNUICallback('v2ScheduledPayments', function(_, cb) v2Callback('getScheduledPayments', nil, cb) end)

local v2Events = {
    createV2Account = 'bc-banking:v2:createAccount',
    v2Transfer = 'bc-banking:v2:transfer',
    createGoal = 'bc-banking:v2:createGoal',
    contributeGoal = 'bc-banking:v2:contributeGoal',
    issueCard = 'bc-banking:v2:issueCard',
    setCardPin = 'bc-banking:v2:setCardPin',
    replaceCard = 'bc-banking:v2:replaceCard',
    setCardStatus = 'bc-banking:v2:setCardStatus',
    applyLoan = 'bc-banking:v2:applyLoan',
    createBusiness = 'bc-banking:v2:createBusiness',
    addBusinessEmployee = 'bc-banking:v2:addBusinessEmployee',
    payroll = 'bc-banking:v2:payroll',
    createScheduledPayment = 'bc-banking:v2:createScheduledPayment',
    cancelScheduledPayment = 'bc-banking:v2:cancelScheduledPayment',
    repayLoan = 'bc-banking:v2:repayLoan'
}

for callbackName, eventName in pairs(v2Events) do
    RegisterNUICallback(callbackName, function(data, cb)
        TriggerServerEvent(eventName, data or {})
        cb({ submitted = true })
    end)
end

RegisterNetEvent('bc-banking:client:v2:refresh', function()
    SendNUIMessage({ action = 'refreshV2' })
end)
