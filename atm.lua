local atmHashes = {}
for _, model in ipairs(Config.ATMModels) do
    atmHashes[#atmHashes + 1] = model
end

local function getClosestATM()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local closest, closestDistance

    for _, hash in ipairs(atmHashes) do
        local object = GetClosestObjectOfType(coords.x, coords.y, coords.z, 2.5, hash, false, false, false)
        if object and object ~= 0 then
            local objectCoords = GetEntityCoords(object)
            local distance = #(coords - objectCoords)
            if not closestDistance or distance < closestDistance then
                closest = object
                closestDistance = distance
            end
        end
    end

    return closest, closestDistance
end

exports('IsNearATM', function()
    local _, distance = getClosestATM()
    return distance and distance <= Config.ATMOpeningDistance or false
end)

CreateThread(function()
    if not Config.UseTarget or Config.TargetResource ~= 'ox_target' then return end

    exports.ox_target:addModel(Config.ATMModels, {
        {
            name = 'bc_banking_atm',
            icon = 'fa-solid fa-credit-card',
            label = 'Use ATM',
            distance = 1.5,
            onSelect = function()
                OpenBCBanking(true)
            end
        }
    })
end)
