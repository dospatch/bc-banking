-- Discord webhook logging for BC-Banking.
-- Real webhook URLs belong in config.private.lua, which is ignored by Git.
-- Copy config.private.example.lua to config.private.lua and edit the URLs there.

Config.DiscordWebhooks = Config.DiscordWebhooks or {}

local privateConfig = LoadResourceFile(GetCurrentResourceName(), 'config.private.lua')
if privateConfig and privateConfig ~= '' then
    local chunk, loadError = load(privateConfig, '@bc-banking/config.private.lua', 't')
    if chunk then
        local ok, runError = pcall(chunk)
        if not ok then
            print(('[bc-banking] Could not load config.private.lua: %s'):format(tostring(runError)))
        end
    else
        print(('[bc-banking] Could not parse config.private.lua: %s'):format(tostring(loadError)))
    end
end

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
    if transactionType == 'deposit' then return 'deposits' end
    if transactionType == 'withdraw' then return 'withdrawals' end
    if transactionType == 'transfer_out' or transactionType == 'transfer_in' then
        return 'transfers'
    end
    if transactionType == 'transfer_fee' then return 'fees' end
    return 'other'
end

local function getWebhookTargets(data)
    local targets = {}
    local seen = {}
    local webhooks = Config.DiscordWebhooks or {}

    local function addWebhook(name)
        local url = webhooks[name]

        -- Backward compatibility: use the old server.cfg convars when the
        -- matching private config.lua value has not been filled in.
        if url == nil or url == '' then
            local convarName = name == 'general' and 'bc_banking_webhook' or ('bc_banking_webhook_' .. name)
            url = GetConvar(convarName, '')
        end

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
            print('^3[bc-banking] Discord logs are enabled but no valid webhook is configured. Copy config.private.example.lua to config.private.lua and add a valid webhook URL.^7')
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
            footer = { text = 'BCGAMING • BC-Banking V1' },
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
