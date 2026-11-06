local function openBank()
    BCBanking.OpenBank()
end

CreateThread(function()
    for index, location in ipairs(Config.BankLocations) do
        exports.ox_target:addBoxZone({
            name = ('bc_banking_bank_%s'):format(index),
            coords = location,
            size = Config.Target.BankSize,
            rotation = 0.0,
            debug = Config.Debug,
            options = {
                {
                    name = ('bc_banking_bank_option_%s'):format(index),
                    icon = Config.Target.BankIcon,
                    label = 'Access BC-Banking',
                    distance = Config.Target.BankDistance,
                    onSelect = openBank
                }
            }
        })
    end

    exports.ox_target:addModel(Config.ATMModels, {
        {
            name = 'bc_banking_atm',
            icon = Config.Target.ATMIcon,
            label = 'Use BC-Banking ATM',
            distance = Config.Target.ATMDistance,
            onSelect = openBank
        }
    })
end)
