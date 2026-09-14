Config = {}

-- General
Config.Debug = false
Config.Framework = 'qbcore'
Config.Currency = '$'

-- Commands
Config.OpenCommand = 'bank'
Config.ATMCommand = 'atm'

-- Target
Config.UseTarget = true
Config.TargetResource = 'ox_target'

-- Interaction distances
Config.BankOpeningDistance = 2.0
Config.ATMOpeningDistance = 1.5

-- Transaction history
Config.TransactionHistoryLimit = 50

-- Transfers
Config.Transfer = {
    Enabled = true,
    Minimum = 1,
    Maximum = 100000,
    Fee = 0
}

-- Deposits
Config.Deposit = {
    Minimum = 1,
    Maximum = 1000000
}

-- Withdrawals
Config.Withdraw = {
    Minimum = 1,
    Maximum = 100000
}

-- Bank locations
Config.BankLocations = {
    {
        name = 'Legion Square',
        coords = vector3(149.94, -1040.82, 29.37)
    },
    {
        name = 'Hawick',
        coords = vector3(314.19, -278.62, 54.17)
    },
    {
        name = 'Rockford Hills',
        coords = vector3(-1212.98, -330.84, 37.78)
    },
    {
        name = 'Alta',
        coords = vector3(-2962.58, 482.63, 15.70)
    },
    {
        name = 'Great Ocean Highway',
        coords = vector3(-111.17, 6470.07, 31.63)
    }
}

-- ATM models
Config.ATMModels = {
    'prop_atm_01',
    'prop_atm_02',
    'prop_atm_03',
    'prop_fleeca_atm'
}

-- Bank blip
Config.Blip = {
    sprite = 108,
    color = 2,
    scale = 0.75,
    name = 'Bank'
}

-- Messages
Config.Messages = {
    NoMoney = 'You do not have enough money.',
    InvalidAmount = 'Invalid amount.',
    DepositSuccess = 'Deposit completed.',
    WithdrawSuccess = 'Withdrawal completed.',
    TransferSuccess = 'Transfer completed.',
    TransferFailed = 'Transfer failed.',
    SamePlayer = 'You cannot transfer money to yourself.',
    TargetNotFound = 'The recipient is not online.',
    TransferDisabled = 'Transfers are disabled.',
    TooMuch = 'The amount exceeds the allowed limit.',
    TooLittle = 'The amount is below the allowed minimum.',
    BankOnly = 'You must be at a bank.',
    ATMOnly = 'You must be at an ATM.'
}