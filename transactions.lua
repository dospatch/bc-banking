local function addTransaction(citizenid, transactionType, amount, description)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return false end

    MySQL.insert.await([[INSERT INTO bc_banking_transactions
        (citizenid, type, amount, description)
        VALUES (?, ?, ?, ?)]], {
        citizenid,
        transactionType,
        amount,
        description or ''
    })

    return true
end

local function getTransactions(citizenid, limit)
    limit = math.max(1, math.min(100, tonumber(limit) or 50))

    return MySQL.query.await(('SELECT id, type, amount, description, created_at FROM bc_banking_transactions WHERE citizenid = ? ORDER BY id DESC LIMIT %d'):format(limit), {
        citizenid
    }) or {}
end

exports('AddTransaction', addTransaction)
exports('GetTransactions', getTransactions)
