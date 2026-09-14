CreateThread(function()
    while true do
        local sleep = 1000
        local playerPed = PlayerPedId()
        local coords = GetEntityCoords(playerPed)

        for _, location in ipairs(Config.ATMLocations) do
            local distance = #(coords - location)

            if distance < 2.0 then
                sleep = 0

                BeginTextCommandDisplayHelp('STRING')
                AddTextComponentSubstringPlayerName('Press ~INPUT_CONTEXT~ to access ~b~BC-Banking ATM~s~')
                EndTextCommandDisplayHelp(0, false, true, -1)

                if IsControlJustReleased(0, 38) then
                    BCBanking.OpenBank()
                end

                break
            end
        end

        Wait(sleep)
    end
end)
