# fivem_latent_callbacks

This script enables you to make "latent" callbacks, using the Native Trigger(Client/Server)LatentEvent enabeling to transfer huge payloads from server -> client and opposite. You can use it for Data Transfer or simply for your normal callbacks.

**PLEASE NOTE that when transfering huge payloads the whole server network can freeze, not letting any other event come thru!**

# Usage

1. Use RegisterCallback(eventName, function(args) ... end) to register a callback.
2. UnregisterCallback(eventName) to remove a registered callback.
3. Use TriggerCallback(eventName, args, timeout, asyncCallback, method) to call a callback.
   - eventName: string identifier for the callback.
   - args: any Lua table of arguments, with optional key __playerId for server usage.
   - timeout: number of seconds (optional). Rejects promise if time exceeded.
   - asyncCallback: function (optional). If provided, callback is invoked asynchronously.
   - method: 'normal' or 'latent'. 'latent' can be used for large data.
4. Use TriggerLatentCallback(eventName, args, timeout, asyncCallback) as shorthand for a latent call.

# Example

**FxManifest:**
```
fx_version 'cerulean'
game 'gta5'

shared_script 'fivem_latent_callbacks.lua'
server_script 'server.lua'
client_script 'client.lua'
```

**Server:**
```
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
```

**Client:**

```
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
```
