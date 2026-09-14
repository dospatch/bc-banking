local QBCore = exports['qb-core']:GetCoreObject()

exports('AddTransaction', function(citizenid, transactionType, amount, description, relatedAccount)
    amount = BCBanking.RoundMoney(amount)

    return MySQL.insert.await(
        [[
            INSERT INTO bc_banking_transactions
            (citizenid, transaction_type, amount, description, related_account)
            VALUES (?, ?, ?, ?, ?)
        ]],
        {
            citizenid,
            transactionType,
            amount,
            description or 'Bank transaction',
            relatedAccount or nil
        }
    )
end)

exports('GetTransactions', function(citizenid)
    return MySQL.query.await(
        [[
            SELECT
                id,
                transaction_type,
                amount,
                description,
                related_account,
                created_at
            FROM bc_banking_transactions
            WHERE citizenid = ?
            ORDER BY id DESC
            LIMIT ?
        ]],
        {
            citizenid,
            Config.TransactionHistoryLimit
        }
    ) or {}
end)
