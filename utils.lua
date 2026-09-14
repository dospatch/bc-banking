BCBanking = {}

function BCBanking.Debug(...)
    if not Config.Debug then return end
    print('[BC-Banking]', ...)
end

function BCBanking.FormatMoney(amount)
    amount = tonumber(amount) or 0
    local formatted = tostring(math.floor(amount))
    while true do
        local result, count = formatted:gsub('^(-?%d+)(%d%d%d)', '%1,%2')
        formatted = result
        if count == 0 then break end
    end
    return Config.Currency .. formatted
end

function BCBanking.IsValidAmount(amount, minimum, maximum)
    amount = tonumber(amount)
    if not amount or amount <= 0 then return false end
    if minimum and amount < minimum then return false end
    if maximum and amount > maximum then return false end
    return math.floor(amount) == amount
end
