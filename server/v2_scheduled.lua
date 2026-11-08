local QBCore = exports['qb-core']:GetCoreObject()
BCBanking = BCBanking or {}
BCBanking.V2 = BCBanking.V2 or {}

local function validAmount(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    n = math.floor(n * 100 + 0.5) / 100
    if n <= 0 or n > (tonumber(Config.V2.MaxPayment) or 1000000) then return nil end
    return n
end

QBCore.Functions.CreateCallback('bc-banking:v2:getScheduledPayments', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not BCBanking.V2.Ready then cb({}); return end
    cb(MySQL.query.await([[
        SELECT p.id, p.account_id, p.recipient_account_id, p.amount, p.frequency,
               p.next_run_at, p.status, a.account_number AS source_account,
               r.account_number AS recipient_account
        FROM bc_banking_v2_scheduled_payments p
        INNER JOIN bc_banking_v2_accounts a ON a.id = p.account_id
        LEFT JOIN bc_banking_v2_accounts r ON r.id = p.recipient_account_id
        WHERE p.citizenid = ? ORDER BY p.id DESC LIMIT 100
    ]], { Player.PlayerData.citizenid }) or {})
end)

RegisterNetEvent('bc-banking:v2:createScheduledPayment', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local fromId, toId = tonumber(data.accountId), tonumber(data.recipientAccountId)
    local pay = validAmount(data.amount)
    local frequency = data.frequency
    if frequency ~= 'once' and frequency ~= 'weekly' and frequency ~= 'monthly' then
        TriggerClientEvent('bc-banking:client:notify', src, 'Choose once, weekly, or monthly.', 'error')
        return
    end
    if not fromId or not toId or not pay or fromId == toId
        or not BCBanking.V2.CanAccessAccount(fromId, cid, 'withdraw')
        or not BCBanking.V2.CanAccessAccount(toId, cid, 'deposit') then
        TriggerClientEvent('bc-banking:client:notify', src, 'Invalid scheduled payment details or permissions.', 'error')
        return
    end
    local id = MySQL.insert.await([[
        INSERT INTO bc_banking_v2_scheduled_payments
            (account_id, citizenid, recipient_account_id, amount, frequency, next_run_at, status)
        VALUES (?, ?, ?, ?, ?, DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 1 MINUTE), 'active')
    ]], { fromId, cid, toId, pay, frequency })
    if id then
        BCBanking.V2.Audit(cid, 'scheduled_payment.created', 'scheduled_payment', id, { amount = pay, frequency = frequency })
        TriggerClientEvent('bc-banking:client:notify', src, 'Scheduled payment created.', 'success')
        TriggerClientEvent('bc-banking:client:v2:refresh', src)
    end
end)

RegisterNetEvent('bc-banking:v2:cancelScheduledPayment', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local id = tonumber(data.paymentId or data.id)
    if not id then return end
    local affected = MySQL.update.await([[
        UPDATE bc_banking_v2_scheduled_payments
        SET status = 'cancelled'
        WHERE id = ? AND citizenid = ? AND status = 'active'
    ]], { id, cid })
    if (tonumber(affected) or 0) > 0 then
        BCBanking.V2.Audit(cid, 'scheduled_payment.cancelled', 'scheduled_payment', id, {})
        TriggerClientEvent('bc-banking:client:notify', src, 'Scheduled payment cancelled.', 'success')
        TriggerClientEvent('bc-banking:client:v2:refresh', src)
    end
end)

CreateThread(function()
    while true do
        Wait(60000)
        if BCBanking.V2.Ready then
            local due = MySQL.query.await([[
                SELECT id, account_id, citizenid, recipient_account_id, amount, frequency
                FROM bc_banking_v2_scheduled_payments
                WHERE status = 'active' AND next_run_at <= CURRENT_TIMESTAMP
                ORDER BY next_run_at ASC LIMIT 25
            ]]) or {}
            for _, payment in ipairs(due) do
                local claimed = MySQL.update.await([[
                    UPDATE bc_banking_v2_scheduled_payments
                    SET status = 'processing'
                    WHERE id = ? AND status = 'active' AND next_run_at <= CURRENT_TIMESTAMP
                ]], { payment.id })
                if (tonumber(claimed) or 0) > 0 then
                    local ok = BCBanking.V2.Transfer(
                        payment.account_id, payment.recipient_account_id,
                        payment.citizenid, tonumber(payment.amount),
                        'Scheduled ' .. payment.frequency .. ' payment'
                    )
                    if ok then
                        if payment.frequency == 'once' then
                            MySQL.update.await(
                                "UPDATE bc_banking_v2_scheduled_payments SET status = 'completed' WHERE id = ? AND status = 'processing'",
                                { payment.id }
                            )
                        else
                            local interval = payment.frequency == 'weekly' and '7 DAY' or '1 MONTH'
                            MySQL.update.await(
                                ('UPDATE bc_banking_v2_scheduled_payments SET status = \'active\', next_run_at = DATE_ADD(CURRENT_TIMESTAMP, INTERVAL %s) WHERE id = ? AND status = \'processing\''):format(interval),
                                { payment.id }
                            )
                        end
                        BCBanking.V2.Audit(payment.citizenid, 'scheduled_payment.processed', 'scheduled_payment', payment.id, { amount = payment.amount })
                    else
                        MySQL.update.await([[
                            UPDATE bc_banking_v2_scheduled_payments
                            SET status = 'active', next_run_at = DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 1 HOUR)
                            WHERE id = ? AND status = 'processing'
                        ]], { payment.id })
                    end
                end
            end
        end
    end
end)
