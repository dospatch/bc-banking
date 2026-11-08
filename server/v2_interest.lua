BCBanking = BCBanking or {}
BCBanking.V2 = BCBanking.V2 or {}

local function accrueAccount(account)
    local apr = tonumber(Config.V2 and Config.V2.SavingsAPR) or 0
    if apr <= 0 then return false end
    local amount = math.floor((tonumber(account.balance) * apr / 100 / 365) * 100 + 0.5) / 100
    if amount <= 0 then return false end

    local ok, result = pcall(function()
        return MySQL.transaction.await({
            {
                query = [[
                    INSERT IGNORE INTO bc_banking_v2_interest_runs
                        (account_id, accrual_date, interest_amount, status)
                    VALUES (?, CURDATE(), ?, 'processing')
                ]],
                values = { account.id, amount }
            },
            { query = 'SET @bc_v2_interest_inserted = ROW_COUNT()', values = {} },
            {
                query = [[
                    UPDATE bc_banking_v2_accounts a
                    INNER JOIN bc_banking_v2_interest_runs r ON r.account_id = a.id
                    SET a.balance = a.balance + r.interest_amount
                    WHERE a.id = ? AND r.accrual_date = CURDATE()
                      AND r.status = 'processing' AND @bc_v2_interest_inserted = 1
                ]],
                values = { account.id }
            },
            { query = 'SET @bc_v2_interest_updated = ROW_COUNT()', values = {} },
            {
                query = [[
                    INSERT INTO bc_banking_v2_ledger
                        (account_id, transaction_ref, entry_type, amount, balance_after, actor_citizenid, description)
                    SELECT a.id, UUID(), 'savings_interest', r.interest_amount,
                           a.balance, a.owner_citizenid, 'Daily savings interest'
                    FROM bc_banking_v2_accounts a
                    INNER JOIN bc_banking_v2_interest_runs r ON r.account_id = a.id
                    WHERE a.id = ? AND r.accrual_date = CURDATE()
                      AND r.status = 'processing' AND @bc_v2_interest_updated = 1
                ]],
                values = { account.id }
            },
            {
                query = [[
                    UPDATE bc_banking_v2_interest_runs
                    SET status = 'completed'
                    WHERE account_id = ? AND accrual_date = CURDATE()
                      AND status = 'processing' AND @bc_v2_interest_updated = 1
                ]],
                values = { account.id }
            }
        })
    end)
    return ok and result == true
end

CreateThread(function()
    while true do
        Wait(30000)
        if BCBanking.V2.Ready and Config.V2 and Config.V2.Enabled then
            local apr = tonumber(Config.V2.SavingsAPR) or 0
            if apr > 0 then
                local accounts = MySQL.query.await([[
                    SELECT id, owner_citizenid, balance
                    FROM bc_banking_v2_accounts
                    WHERE account_type = 'savings' AND status = 'active' AND balance > 0
                ]]) or {}
                for _, account in ipairs(accounts) do
                    local ok = accrueAccount(account)
                    if not ok and Config.Debug then
                        print(('[bc-banking] Savings interest was not applied for account %s.'):format(account.id))
                    end
                end
            end
        end
        Wait(1800000)
    end
end)
