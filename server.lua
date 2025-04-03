-- Normal callback example
RegisterCallback("myTestEvent", function(data)
    local src = data.source
    print("[Server] Callback from #"..src, data.foo)
    local name = GetPlayerName(src) or "Unknown"
    return ("Hello %s from the server!"):format(name), 42
end)

-- Latent callback (big data example)
RegisterCallback("myLatentEvent", function(data)
    local src = data.source
    local payload = {}
    for i = 1, 50000 do
        payload[i] = { id = i, msg = "Chunky data" }
    end
    return payload
end)

-- Server triggers a callback on the client
RegisterCommand("testcb", function(source)
    TriggerCallback("client:hello", {
        __playerId = source,
        foo = "Hi from the server"
    }, 5, function(msg, num)
        print("[Server] Client returned:", msg, num)
    end)
end, false)