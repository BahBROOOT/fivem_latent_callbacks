-- This command tests the normal callback.
RegisterCommand("testcallback", function()
    print("[Client] Triggering normal callback...")

    -- We'll call the server callback with a small data table.
    local greeting, number = TriggerCallback(
        "myTestEvent",                     -- callback event name
        { __playerId = GetPlayerServerId(PlayerId()), foo="bar" }, -- arguments
        5                                   -- timeout in seconds
    )

    print("[Client] Received from server:", greeting, number)
end, false)

-- This command tests the latent callback.
RegisterCommand("testlatent", function()
    print("[Client] Triggering latent callback...")

    -- We'll request a large payload from the server.
    local data = TriggerLatentCallback(
        "myLatentEvent",                   -- callback event name
        { __playerId = GetPlayerServerId(PlayerId()) },
        10                                  -- timeout in seconds
    )

    if data then
        print("[Client] Received large payload from server. Length:", #data[1])
    else
        print("[Client] No data received or timed out.")
    end
end, false)