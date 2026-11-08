-- Discord webhook logging for BC-Banking.
-- Webhook destinations are configured directly in config.lua.

local function clean(value, maxLength)
    local text = tostring(value or 'N/A')
    text = text:gsub('[%c]', ' ')
    return text:sub(1, maxLength or 1000)
end

local function isWebhookUrl(url)
    return type(url) == 'string'
        and (url:match('^https://discord%.com/api/webhooks/')
            or url:match('^https://discordapp%.com/api/webhooks/'))
end

local function getCategory(transactionType)
    local kind = tostring(transactionType or ''):lower()
    if kind:find('fee', 1, true) then return 'fees' end
    if kind:find('transfer', 1, true) then return 'transfers' end
    if kind:find('deposit', 1, true) or kind:find('fund', 1, true) then return 'deposits' end
    if kind:find('withdraw', 1, true) or kind:find('repayment', 1, true) then return 'withdrawals' end
    return 'other'
end

local function getWebhookTargets(data)
    local targets = {}
    local seen = {}
    local webhooks = Config.DiscordWebhooks or {}

    local function addWebhook(name)
        local url = webhooks[name]
        if url == nil or url == '' then return end

        if not isWebhookUrl(url) then
            print(('[bc-banking] Ignoring invalid Discord webhook URL for destination %s.'):format(name))
            return
        end

        if not seen[url] then
            seen[url] = true
            targets[#targets + 1] = url
        end
    end

    -- General receives every event; category receives its matching event.
    addWebhook('general')
    addWebhook(getCategory(data.type or data.transactionType))

    return targets
end

local function sendToWebhook(webhook, payload)
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
end

function BCBanking.SendDiscordLog(data)
    if not Config.DiscordLogs then return false end
    if type(data) ~= 'table' then return false end

    local targets = getWebhookTargets(data)
    if #targets == 0 then
        if not BCBanking._discordWebhookWarning then
            print('^3[bc-banking] Discord logs are enabled but no valid webhook is configured. Add a valid webhook URL to Config.DiscordWebhooks in config.lua.^7')
            BCBanking._discordWebhookWarning = true
        end
        return false
    end

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
            footer = { text = 'BCGAMING • BC-Banking' },
            timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
        }}
    }

    for _, webhook in ipairs(targets) do
        sendToWebhook(webhook, payload)
    end

    return true
end

exports('SendDiscordLog', function(data)
    return BCBanking.SendDiscordLog(data)
end)
