-- Serializes money operations per citizen ID to prevent concurrent requests
-- from spending the same balance more than once.
local activeLocks = {}

BCBanking = BCBanking or {}

function BCBanking.WithPlayerLocks(citizenIds, callback)
    local ids = {}
    local seen = {}

    for _, citizenid in ipairs(citizenIds or {}) do
        if citizenid and not seen[citizenid] then
            seen[citizenid] = true
            ids[#ids + 1] = citizenid
        end
    end

    table.sort(ids)

    for _, citizenid in ipairs(ids) do
        while activeLocks[citizenid] do
            Wait(0)
        end
        activeLocks[citizenid] = true
    end

    local ok, result, message = xpcall(callback, debug.traceback)

    for i = #ids, 1, -1 do
        activeLocks[ids[i]] = nil
    end

    if not ok then
        print(('[bc-banking] Locked operation failed: %s'):format(result))
        return false, 'A banking error occurred. Please try again.'
    end

    return result, message
end

-- Lightweight server-side request throttling to reject rapid duplicate clicks/events.
local lastRequest = {}

function BCBanking.CheckCooldown(citizenid)
    local now = GetGameTimer()
    local cooldown = math.max(250, tonumber(Config.TransactionCooldown) or 1000)
    local previous = lastRequest[citizenid]

    if previous and now - previous < cooldown then
        return false
    end

    lastRequest[citizenid] = now
    return true
end

