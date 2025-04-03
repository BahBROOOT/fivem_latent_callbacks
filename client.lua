-- Callback handler for server-triggered call
RegisterCallback("client:hello", function(args)
    print("[Client] Callback received:", args.foo)
    return "Client here!", 999
end)

-- Normal callback usage
RegisterCommand("testcallback", function()
    local greeting, num = TriggerCallback("myTestEvent", { foo = "bar" }, 5)
    print("[Client] Server replied:", greeting, num)
end, false)

-- Latent callback for big data
RegisterCommand("testlatent", function()
    local data = TriggerLatentCallback("myLatentEvent", {}, 10)

    if data then
        print("[Client] Big data received. Items:", #data)
    else
        print("[Client] No data or timeout.")
    end
end, false)