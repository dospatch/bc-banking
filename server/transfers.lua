local QBCore = exports['qb-core']:GetCoreObject()

local function notify(src, msg, kind)
    TriggerClientEvent('bc-banking:client:notify', src, msg, kind or 'error')
end

local function validAmount(value)
    local amount = tonumber(value)
    if not amount or amount ~= amount or amount == math.huge or amount == -math.huge then return nil end
    amount = BCBanking.RoundMoney(amount)
    if amount <= 0 or amount > Config.MaxTransfer then return nil end
    return amount
end

RegisterNetEvent('bc-banking:server:transfer', function(targetAccountNumber, value, description)
    local src = source
    local initial = QBCore.Functions.GetPlayer(src)
    if not initial then return end

    local senderCid = initial.PlayerData.citizenid
    if not BCBanking.CheckCooldown(senderCid) then
        notify(src, 'Please wait a moment before making another banking request.')
        return
    end

    targetAccountNumber = BCBanking.Trim(targetAccountNumber)
    description = BCBanking.Trim(description)
    local amount = validAmount(value)
    local fee = tonumber(Config.TransferFee) or 0

    if not amount then
        notify(src, 'Enter a valid transfer amount within the transaction limit.')
        return
    end

    if fee < 0 or fee ~= fee or fee == math.huge or fee == -math.huge then
        notify(src, 'Bank transfer fees are configured incorrectly. Contact staff.')
        print('[bc-banking] Config.TransferFee must be finite and non-negative.')
        return
    end

    fee = BCBanking.RoundMoney(fee)
    if targetAccountNumber == '' or not targetAccountNumber:match('^%d+$') then
        notify(src, 'Enter a valid destination account number.')
        return
    end

    local senderAccount = exports['bc-banking']:GetAccountByCitizenId(senderCid)
    if not senderAccount then senderAccount = exports['bc-banking']:CreateAccount(initial) end
    local receiverAccount = exports['bc-banking']:GetAccountByNumber(targetAccountNumber)

    if not senderAccount or not receiverAccount then
        notify(src, 'The destination account was not found.')
        return
    end

    if receiverAccount.citizenid == senderCid then
        notify(src, 'You cannot transfer money to yourself.')
        return
    end

    local ok, message = BCBanking.WithPlayerLocks({ senderCid, receiverAccount.citizenid }, function()
        local Sender = QBCore.Functions.GetPlayer(src)
        if not Sender or Sender.PlayerData.citizenid ~= senderCid then
            return false, 'Your banking session is no longer available.'
        end

        local currentAccount = exports['bc-banking']:GetAccountByNumber(targetAccountNumber)
        if not currentAccount or currentAccount.citizenid ~= receiverAccount.citizenid then
            return false, 'The destination account is no longer available.'
        end

        local total = amount + fee
        if (tonumber(Sender.PlayerData.money.bank) or 0) < total then
            return false, 'Insufficient bank funds, including the transfer fee.'
        end

        if Sender.Functions.RemoveMoney('bank', total, 'bc-banking-transfer') ~= true then
            return false, 'Your bank funds could not be removed. Transfer cancelled.'
        end

        -- Treat recipient credit as one guarded operation. An exception from the
        -- live-player or offline database path must enter the same refund path.
        local creditCallOk, credited, creditError = pcall(function()
            local Receiver = QBCore.Functions.GetPlayerByCitizenId(receiverAccount.citizenid)

            if Receiver then
                local success = Receiver.Functions.AddMoney('bank', amount, 'bc-banking-transfer') == true
                if not success then return false end

                local syncOk, syncError = pcall(function()
                    exports['bc-banking']:SyncAccountBalance(receiverAccount.citizenid, Receiver.PlayerData.money.bank)
                end)
                if not syncOk then
                    print(('[bc-banking] Could not sync recipient account mirror for %s: %s'):format(receiverAccount.citizenid, syncError))
                end

                return true
            end

            local affected = MySQL.update.await([[
                UPDATE players
                SET money = JSON_SET(
                    money,
                    '$.bank',
                    CAST(COALESCE(JSON_UNQUOTE(JSON_EXTRACT(money, '$.bank')), '0') AS DECIMAL(15,2)) + ?
                )
                WHERE citizenid = ?
            ]], { amount, receiverAccount.citizenid })

            if (tonumber(affected) or 0) < 1 then return false end

            local syncOk, syncError = pcall(function()
                exports['bc-banking']:IncrementAccountBalance(receiverAccount.citizenid, amount)
            end)
            if not syncOk then
                print(('[bc-banking] Could not sync offline recipient account mirror for %s: %s'):format(receiverAccount.citizenid, syncError))
            end

            return true
        end)

        if not creditCallOk or not credited then
            if not creditCallOk then
                print(('[bc-banking] Recipient credit operation raised an error. Sender=%s Receiver=%s Error=%s'):format(senderCid, receiverAccount.citizenid, tostring(credited)))
            elseif creditError then
                print(('[bc-banking] Recipient credit failed. Sender=%s Receiver=%s Error=%s'):format(senderCid, receiverAccount.citizenid, tostring(creditError)))
            end

            local refundCallOk, refunded = pcall(function()
                return Sender.Functions.AddMoney('bank', total, 'bc-banking-transfer-refund') == true
            end)

            if not refundCallOk or not refunded then
                print(('[bc-banking] CRITICAL: recipient credit failed and sender refund could not be confirmed. Sender=%s Receiver=%s Amount=%.2f'):format(senderCid, receiverAccount.citizenid, total))
                return false, 'Transfer failed and refund could not be confirmed. Contact staff immediately.'
            end

            return false, 'The recipient could not be credited. Your money was refunded.'
        end

        local senderSyncOk, senderSyncError = pcall(function()
            exports['bc-banking']:SyncAccountBalance(senderCid, Sender.PlayerData.money.bank)
        end)
        if not senderSyncOk then
            print(('[bc-banking] Could not sync sender account mirror for %s: %s'):format(senderCid, senderSyncError))
        end

        local senderText = description ~= '' and description or 'Bank transfer sent'
        local outOk, outId = pcall(function()
            return exports['bc-banking']:AddTransaction(senderCid, 'transfer_out', amount, senderText, receiverAccount.account_number)
        end)
        local inOk, inId = pcall(function()
            return exports['bc-banking']:AddTransaction(receiverAccount.citizenid, 'transfer_in', amount, 'Bank transfer received', senderAccount.account_number)
        end)

        local feeOk, feeId = true, true
        if fee > 0 then
            feeOk, feeId = pcall(function()
                return exports['bc-banking']:AddTransaction(senderCid, 'transfer_fee', fee, 'Bank transfer fee', receiverAccount.account_number)
            end)
        end

        if not outOk or not outId or not inOk or not inId or not feeOk or not feeId then
            print(('[bc-banking] Transfer completed but transaction log insert failed. Sender=%s Receiver=%s'):format(senderCid, receiverAccount.citizenid))
        end

        return true, 'Transfer completed successfully.'
    end)

    notify(src, message or (ok and 'Transfer completed successfully.' or 'Transfer failed.'), ok and 'success' or 'error')
end)
