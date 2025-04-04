# fivem_latent_callbacks

This script enables **client ↔ server callbacks** using both **normal** and **latent** event transfer in FiveM. It supports:

- **Normal callbacks** for typical communication  
- **Latent callbacks** (`TriggerLatentEvent`) for **large data** (chunked over time)  
- **Multiple return values**: `return val1, val2, val3` (no need for `{}`)  
- **Automatic `source`** (no need for `__playerId` from client→server)  
- **Manual `__playerId`** only needed for server→client calls  
- Built-in support for **timeouts**, **chunked data**, and **msgpack serialization**  

---

## How to Use

1. **Download** `fivem_latent_callbacks.lua` (the updated version) and put it in your resource.  
2. **Initialize** it as a **shared_script** in `fxmanifest.lua`:

   ```lua
   shared_script 'fivem_latent_callbacks.lua'
   ```

3. **Register a callback** with `RegisterCallback(eventName, function(args))` in either client or server code.  
4. **Trigger that callback** from the opposite side using `TriggerCallback(...)` or `TriggerLatentCallback(...)`.  
5. **Return values** from your callback just like normal Lua functions: `return someValue, someOtherValue`.  
6. If you do **asynchronous** usage, pass an extra callback parameter to `TriggerCallback(...)`.  
7. **(Server→Client Only)**: If you’re calling the client from the server, pass `__playerId = <Player ID>` in your args so the script knows which client to contact.  

### Example

```lua
-- On the server:
RegisterCallback("myCallback", function(args)
    return "It works!", 42
end)

-- On the client:
local msg, number = TriggerCallback("myCallback")
print(msg, number) -- prints: It works!  42
```

---

## Configuration

Inside `fivem_latent_callbacks.lua`, you can adjust the **bandwidth limit for latent callbacks** (in bits per second):

```lua
local BANDWIDTH_LIMIT = 1000000 -- 1 Mbps default
```

> :warning: Raising this can speed up large data transfers but **risks** choking your network if overused.

---

## API

### `RegisterCallback(eventName, function(args))`

Registers a named callback handler.

```lua
RegisterCallback("myEvent", function(args)
    local src = args.source -- the player who called it, or -1 if client
    return "hello", 123
end)
```

### `UnregisterCallback(eventName)`

Unregisters a previously registered callback by name.

---

### `TriggerCallback(eventName, args, timeout?, asyncCallback?, method?)`

Triggers a callback on the **other side** (client or server).

```lua
local a, b = TriggerCallback(
    "myEvent",      -- callback name
    { foo = "bar" }, -- args to pass
    5,              -- optional timeout in seconds
    nil,            -- optional async callback
    "normal"        -- or "latent" (optional)
)
```

- `args`: Table of data to send.  
  - **Server→Client** must include `args.__playerId = somePlayerId`.  
  - **Client→Server** does *not* need that.  
- `timeout`: If no response by then, it throws a timeout.  
- `asyncCallback`: If provided, the function call is non-blocking and the response is handled in that callback.  
- `method`: `'normal'` (default) or `'latent'` (for large data sets).

---

### `TriggerLatentCallback(eventName, args, timeout?, asyncCallback?)`

Shorthand for triggering a callback in **latent** mode (chunked data).

```lua
TriggerLatentCallback("myLatentEvent", args, 10, function(result)
    -- ...
end)
```

---

## fxmanifest.lua Example

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
-- Normal client→server callback
RegisterCallback("myTestEvent", function(data)
    local src = data.source
    print("[Server] Callback from #"..src, data.foo)
    local name = GetPlayerName(src) or "Unknown"
    return ("Hello %s from the server!"):format(name), 42
end)

-- Latent callback with big data
RegisterCallback("myLatentEvent", function(data)
    local src = data.source
    local payload = {}
    for i = 1, 50000 do
        payload[i] = { id = i, msg = "Massive data chunk" }
    end
    return payload
end)

-- Server triggers a callback on the client
RegisterCommand("testcb", function(source)
    TriggerCallback("client:hello", {
        __playerId = source, -- <== Must specify this so we know which client
        foo = "Hi from the server"
    }, 5, function(msg, num)
        print("[Server] Client returned:", msg, num)
    end)
end, false)
```

---

## Client Example (`client.lua`)

```lua
-- Callback handler for server→client call
RegisterCallback("client:hello", function(args)
    print("[Client] Callback received:", args.foo)
    return "Client here!", 999
end)

-- Normal usage: client→server
RegisterCommand("testcallback", function()
    local greeting, num = TriggerCallback("myTestEvent", { foo = "bar" }, 5)
    print("[Client] Server replied:", greeting, num)
end, false)

-- Latent usage: client→server
RegisterCommand("testlatent", function()
    local data = TriggerLatentCallback("myLatentEvent", {}, 10)

    if data then
        print("[Client] Big data received. Items:", #data)
    else
        print("[Client] No data or timed out.")
    end
end, false)
```

---

## Return Styles

Callbacks support both multiple returns and table returns:

```lua
-- Modern style
return "value1", 123

-- Or table style
return { "value1", 123 }
```

---

## Troubleshooting

| Issue                                       | Fix                                                                                                  |
|--------------------------------------------|-------------------------------------------------------------------------------------------------------|
| **No response / times out**                | Increase `timeout` or ensure the callback name matches (typos?), or that the other side’s script runs |
| **Server sees `table: 0x#######`**         | You might be returning a table-of-tables. Check your usage or just `return "something", 123`         |

---

## Tips

- Use **latent** callbacks for:
  - base64 or big binary data
  - Large lists (e.g., tens of thousands of rows)
- Keep **normal** callbacks for quick & small data to avoid unneeded chunking overhead.

---

## Compatibility

- ✅ Works with both `"return val1, val2"` and `"return { val1, val2 }"`  
- ✅ Works server→client (must specify `__playerId`) and client→server (no `__playerId` needed)  
- ✅ Uses `msgpack` for efficient serialization  
- ✅ Chunked transfers for large payloads  
- ✅ Timeout-based error handling  

---

## Credits

- **Author**: BahBROOOT (aka BahBROOOT1)  
- **License**: MIT — free to use and modify  
- **Last Updated**: April 2025  
