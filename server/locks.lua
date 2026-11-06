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
