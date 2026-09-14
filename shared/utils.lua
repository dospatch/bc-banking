BCBanking = {}

function BCBanking.Trim(value)
    if not value then
        return ''
    end

    return tostring(value):gsub('^%s*(.-)%s*$', '%1')
end

function BCBanking.IsPositiveNumber(value)
    local number = tonumber(value)

    return number ~= nil and number > 0
end

function BCBanking.RoundMoney(value)
    value = tonumber(value) or 0
    return math.floor(value * 100 + 0.5) / 100
end

function BCBanking.FormatMoney(value)
    value = BCBanking.RoundMoney(value)

    local formatted = string.format('%.2f', value)

    while true do
        local result, count = formatted:gsub('^(-?%d+)(%d%d%d)', '%1,%2')

        formatted = result

        if count == 0 then
            break
        end
    end

    return Config.Currency .. formatted
end
