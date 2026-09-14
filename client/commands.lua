RegisterCommand(Config.BankCommand, function()
    BCBanking.OpenBank()
end, false)

RegisterCommand(Config.ATMCommand, function()
    BCBanking.OpenBank()
end, false)
