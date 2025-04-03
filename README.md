# fivem_latent_callbacks

This script enables **client↔server callbacks** using both **normal** and **latent** event transfer in FiveM. It supports:

- **Normal callbacks** for typical communication  
- **Latent callbacks** using `Trigger(Client/Server)LatentEvent` for **large data**  
- **Multiple return values**: `return val1, val2, val3` (no need for `{}`!)  
- **Backwards compatibility**: supports `return { data }`  
- No need to manually pass `__playerId` from client to server  
- Built-in support for timeouts, chunked data, and msgpack serialization  

---

## How to Use

1. **Download fivem_latent_callbacks.lua** and put it into your ressource somewhere
2. **Initialize the file** as a shared script in your fxmanifest.lua using `shared_script 'fivem_latent_callbacks.lua`
3. **Register a callback** using `RegisterCallback(eventName, function(args))` on the client or server.  
4. **Trigger a callback** using `TriggerCallback(...)` or `TriggerLatentCallback(...)` from the opposite side.  
5. **Receive and return values** just like a function.  
6. **Optionally handle responses asynchronously** by providing a callback function.  
7. Use `UnregisterCallback(...)` if you need to remove it dynamically.

Example:
```lua
-- Server
RegisterCallback("myCallback", function(args)
    return "It works!", 42
end)

-- Client
local msg, number = TriggerCallback("myCallback")
print(msg, number) -- prints: It works!  42
```

---

## Configuration

Inside `fivem_latent_callbacks.lua`, you can adjust the **bandwidth limit for latent callbacks** (in bits per second):

```lua
local BANDWIDTH_LIMIT = 1000000 -- 1 Mbps default
```

> ⚠️ Raising this value increases transfer speed for large payloads, but **may cause network freezes** if overused.

---

## API

### `RegisterCallback(eventName, function(args))`

Registers a callback handler.

```lua
RegisterCallback("myEvent", function(args)
    local src = args.source
    return "hello", 123
end)
```

### `UnregisterCallback(eventName)`

Unregisters a previously registered callback.

### `TriggerCallback(eventName, args, timeout?, asyncCallback?, method?)`

Triggers a callback on the other side (client ↔ server).

```lua
local a, b = TriggerCallback(
    "myEvent",     -- event name
    { foo = "bar" },  -- args (optional)
    5,             -- timeout in seconds (optional)
    nil,           -- async callback (optional)
    "normal"       -- or "latent" (optional)
)
```

- `args`: table of arguments (client → server doesn’t need `__playerId`)  
- `timeout`: seconds before the promise is rejected  
- `asyncCallback`: if provided, callback runs asynchronously  
- `method`: `'normal'` (default) or `'latent'` (for large data)

### `TriggerLatentCallback(eventName, args, timeout?, asyncCallback?)`

Shorthand for triggering a latent callback:

```lua
TriggerLatentCallback("myLatentEvent", args, timeout, callback)
```

---

## fxmanifest.lua

```lua
fx_version 'cerulean'
game 'gta5'

shared_script 'fivem_latent_callbacks.lua'
server_script 'server.lua'
client_script 'client.lua'
```

---

## Server Example (`server.lua`)

```lua
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
```

---

## Client Example (`client.lua`)

```lua
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
```

---

## Return Styles

Both of these are supported:

```lua
-- Preferred modern style
return "value1", 123

-- Legacy compatible
return { "value1", 123 }
```

Your scripts don't need to be changed — both formats will work.

---

## Troubleshooting

| Issue                         | Fix                                                                 |
|------------------------------|----------------------------------------------------------------------|
| Ping is `nil`                | Ensure you're calling `GetPlayerPing(src)` when player is fully connected |
| Callback times out           | Increase `timeout` param; check if callback handler exists          |
| Server prints `table: ...`   | You're returning `{}` instead of multiple values, or unpacking too early |

---

## Tips

- Use **latent** callbacks for:
  - base64 data
  - Huge lists
- Keep **normal** callbacks for quick responses (e.g., validation, permission checks)

---

## Compatibility

- ✅ Works with both `return ...` and `return { ... }`  
- ✅ Works server→client and client→server  
- ✅ Uses `msgpack` for efficiency  
- ✅ Supports large payloads and timeouts  

---

## Credits

**Author**: BahBROOOT (aka BahBROOOT1)  
**License**: MIT — free to use and modify  
**Last Updated**: April 2025

---