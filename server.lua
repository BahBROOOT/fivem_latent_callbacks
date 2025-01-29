-- Example: Register a server-side callback.
RegisterCallback("myTestEvent", function(data)
    local src = data.source
    print("[Server] Callback triggered by player #" .. src)
    print("[Server] Received data from client:", data)

    -- Return any data you want.
    local playerName = GetPlayerName(src) or "Unknown"
    return { ("Hello %s! This is the server." ):format(playerName), 42 }
end)

-- Another callback to test latent transfer of large data.
RegisterCallback("myLatentEvent", function(data)
    local src = data.source
    print("[Server] Latent callback triggered by #"..src)

    -- Return a large payload.
    local bigPayload = {}
    for i=1,50000 do
        table.insert(bigPayload, { index = i, msg = "Some large data" })
    end
    return { bigPayload }
end)