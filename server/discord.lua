-- Discord webhook logging for BC-Banking.
-- Configure the secret URL in server.cfg:
-- set bc_banking_webhook "https://discord.com/api/webhooks/ID/TOKEN"
-- Do not put the webhook URL in config.lua or commit it to GitHub.

local function clean(value, maxLength)
    local text = tostring(value or 'N/A')
    text = text:gsub('[%c]', ' ')
    return text:sub(1, maxLength or 1000)
end

function BCBanking.SendDiscordLog(data)
    if not Config.DiscordLogs then return false end

    local webhook = GetConvar('bc_banking_webhook', '')
    if webhook == '' then
        if not BCBanking._discordWebhookWarning then
            print('^3[bc-banking] Discord logs are enabled but bc_banking_webhook is not configured in server.cfg.^7')
            BCBanking._discordWebhookWarning = true
        end
        return false
    end

    if type(data) ~= 'table' then return false end

    local fields = {}
    for _, field in ipairs(data.fields or {}) do
        fields[#fields + 1] = {
            name = clean(field.name, 256),
            value = clean(field.value, 1024),
            inline = field.inline == true
        }
    end

    local payload = {
        username = 'BC-Banking Logs',
        embeds = {{
            title = clean(data.title or 'BC-Banking Event', 256),
            color = tonumber(data.color) or 0xD97706,
            fields = fields,
            footer = { text = 'BCGAMING • BC-Banking V1' },
            timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
        }}
    }

    PerformHttpRequest(webhook, function(statusCode, responseBody)
        if statusCode < 200 or statusCode >= 300 then
            print(('[bc-banking] Discord webhook returned HTTP %s: %s'):format(
                tostring(statusCode),
                clean(responseBody, 300)
            ))
        end
    end, 'POST', json.encode(payload), {
        ['Content-Type'] = 'application/json'
    })

    return true
end

exports('SendDiscordLog', function(data)
    return BCBanking.SendDiscordLog(data)
end)
