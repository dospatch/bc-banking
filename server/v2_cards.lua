local QBCore = exports['qb-core']:GetCoreObject()
BCBanking = BCBanking or {}
BCBanking.V2 = BCBanking.V2 or {}

local function token()
    return ('%08x-%04x-4%03x-%04x-%08x%04x'):format(
        math.random(0, 0x7fffffff), math.random(0, 0xffff),
        math.random(0, 0xfff), math.random(0, 0xffff),
        math.random(0, 0xffffffff), math.random(0, 0xffff)
    )
end

QBCore.Functions.CreateCallback('bc-banking:v2:getCards', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not BCBanking.V2.Ready then cb({}); return end
    cb(MySQL.query.await([[
        SELECT id, account_id, last_four, status, failed_pin_attempts, locked_until, created_at
        FROM bc_banking_v2_cards
        WHERE citizenid = ?
        ORDER BY id DESC
    ]], { Player.PlayerData.citizenid }) or {})
end)

RegisterNetEvent('bc-banking:v2:issueCard', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local accountId = tonumber(data.accountId)
    if not accountId or not BCBanking.V2.CanAccessAccount(accountId, cid, 'issue_cards') then
        TriggerClientEvent('bc-banking:client:notify', src, 'You do not have permission to issue a card for this account.', 'error')
        return
    end
    local count = tonumber(MySQL.scalar.await(
        "SELECT COUNT(*) FROM bc_banking_v2_cards WHERE citizenid = ? AND status IN ('active', 'frozen')",
        { cid }
    )) or 0
    if count >= math.max(1, tonumber(Config.V2.MaxCards) or 3) then
        TriggerClientEvent('bc-banking:client:notify', src, 'You have reached your card limit.', 'error')
        return
    end
    local lastFour = ('%04d'):format(math.random(0, 9999))
    local cardToken = token()
    MySQL.insert.await([[
        INSERT INTO bc_banking_v2_cards (account_id, citizenid, card_token, last_four, status)
        VALUES (?, ?, ?, ?, 'active')
    ]], { accountId, cid, cardToken, lastFour })
    BCBanking.V2.Audit(cid, 'card.issued', 'account', accountId, { last_four = lastFour })
    TriggerClientEvent('bc-banking:client:notify', src, 'Virtual card issued ending in ' .. lastFour .. '.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)

RegisterNetEvent('bc-banking:v2:setCardPin', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local cardId = tonumber(data.cardId)
    local pin = tostring(data.pin or '')
    local pepper = tostring(Config.V2.CardPepper or '')
    if not cardId or not pin:match('^%d%d%d%d$') or #pepper < 16 then
        TriggerClientEvent('bc-banking:client:notify', src, 'Set a four-digit PIN and configure a private CardPepper of at least 16 characters.', 'error')
        return
    end
    local affected = MySQL.update.await([[
        UPDATE bc_banking_v2_cards
        SET pin_hash = SHA2(CONCAT(?, ':', ?, ':', ?), 256),
            failed_pin_attempts = 0, locked_until = NULL
        WHERE id = ? AND citizenid = ? AND status = 'active'
    ]], { pin, pepper, cid, cardId, cid })
    if (tonumber(affected) or 0) < 1 then
        TriggerClientEvent('bc-banking:client:notify', src, 'Card not found or inactive.', 'error')
        return
    end
    BCBanking.V2.Audit(cid, 'card.pin_updated', 'card', cardId, {})
    TriggerClientEvent('bc-banking:client:notify', src, 'Card PIN updated.', 'success')
end)

RegisterNetEvent('bc-banking:v2:setCardStatus', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local cardId = tonumber(data.cardId)
    local status = data.status == 'frozen' and 'frozen' or (data.status == 'active' and 'active' or nil)
    if not cardId or not status then return end
    local affected = MySQL.update.await(
        'UPDATE bc_banking_v2_cards SET status = ? WHERE id = ? AND citizenid = ? AND status <> \'replaced\'',
        { status, cardId, cid }
    )
    if (tonumber(affected) or 0) > 0 then
        BCBanking.V2.Audit(cid, 'card.status_changed', 'card', cardId, { status = status })
        TriggerClientEvent('bc-banking:client:notify', src, 'Card status updated.', 'success')
        TriggerClientEvent('bc-banking:client:v2:refresh', src)
    end
end)

RegisterNetEvent('bc-banking:v2:replaceCard', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(data) ~= 'table' or not BCBanking.V2.Ready then return end
    local cid = Player.PlayerData.citizenid
    if not BCBanking.CheckCooldown(cid) then return end
    local cardId = tonumber(data.cardId)
    local card = cardId and MySQL.single.await(
        "SELECT id, account_id FROM bc_banking_v2_cards WHERE id = ? AND citizenid = ? AND status IN ('active', 'frozen') LIMIT 1",
        { cardId, cid }
    )
    if not card then return end
    MySQL.update.await("UPDATE bc_banking_v2_cards SET status = 'replaced', replaced_at = CURRENT_TIMESTAMP WHERE id = ?", { cardId })
    local lastFour = ('%04d'):format(math.random(0, 9999))
    MySQL.insert.await([[
        INSERT INTO bc_banking_v2_cards (account_id, citizenid, card_token, last_four, status)
        VALUES (?, ?, ?, ?, 'active')
    ]], { card.account_id, cid, token(), lastFour })
    BCBanking.V2.Audit(cid, 'card.replaced', 'card', cardId, { new_last_four = lastFour })
    TriggerClientEvent('bc-banking:client:notify', src, 'Card replaced. New card ends in ' .. lastFour .. '.', 'success')
    TriggerClientEvent('bc-banking:client:v2:refresh', src)
end)
