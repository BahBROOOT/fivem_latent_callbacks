# Safe Callbacks for FiveM — README

Tiny, security-hardened client↔server callback layer with optional **latent** events for large payloads.

## Features

* Safe request/response with **promises** (sync or async style)
* **Latent** mode for big transfers (bandwidth-capped, BYTES/sec)
* Ticket **duplicate** protection
* **Owner verification** (only the asked client can resolve)
* Strict **event name validation** (configurable)
* Helper: **`RegisterSecureCallback`** with a validator

## Install

1. Put the script in your resource (both client & server).
2. Ensure it’s loaded on each side where you’ll call/register.
3. (Optional) Tweak the **Config** section at the top:

   * `BANDWIDTH_LIMIT` (bytes/sec, latent)
   * `MAX_PAYLOAD`, `CHUNK_TTL_MS`, rate limits, concurrency
   * `STRICT_EVENT_NAMES`, `EVENTNAME_PATTERN`
   * `debug` (set `true` to log)

---

## Quickstart

### Register a callback (server or client)

```lua
RegisterCallback("inventory:get", function(args)
    -- args.source is trusted: player id on server, -1 on client
    return { items = { "bread", "water" } }
end)
```

### Client → Server (sync)

```lua
local data, err = TriggerCallback("inventory:get", {}, 10)
if not data then
    print("Failed:", err)           -- e.g., "Callback timed out."
else
    print(json.encode(data))
end
```

### Client → Server (async)

```lua
TriggerCallback("inventory:get", {}, 10, function(data, err)
    if err then return print("Failed:", err) end
    print("Items:", json.encode(data))
end)
```

### Server → Client (targeted)

```lua
-- Prefer this helper to avoid putting __playerId in args
TriggerCallbackFor(playerId, "ui:open", { page = "shop" }, 15)
```

### Latent (either side)

```lua
-- Use for large payloads (e.g., > 128KB)
TriggerLatentCallback("data:bulk", hugeTable, 60, function(ok, err)
    if err then print("bulk err:", err) end
end)
```

---

## API

### `RegisterCallback(eventName, handler)`

Registers a function to handle requests.

* `handler(args)` returns any values; they’ll round-trip back to the caller.
* `args.source` is injected and **cannot** be overridden by the caller.

### `RegisterSecureCallback(eventName, validator, handler)`

Wraps your handler with a validator.

* `validator(args)` → `true` or `false,"reason"`
* On `false`, the caller receives `(nil, "reason")`.

### `TriggerCallback(event, args?, timeoutSec?, async?, method?)`

Sends a request to the other side.

* `method`: `"normal"` (default) or `"latent"`
* **Sync**: returns `...` on success or `nil, "error"` on failure/timeout.
* **Async**: calls `asyncCallback(result..., err)`; on success, `err` is `nil`.

### `TriggerCallbackFor(playerId, event, args?, timeoutSec?, async?, method?)` (server only)

Server→client convenience wrapper that never exposes `__playerId` in user args.

### `TriggerLatentCallback(event, args?, timeoutSec?, async?)`

Shorthand for latent mode.

---

## Safety Defaults & Limits (server)

* **Rate limit**: token bucket (`RATE_TOKENS_PER_SEC`, `RATE_BURST`)
* **Size cost**: `RATE_COST_PER_64KB` per 64KB to thwart spammy large requests
* **Concurrency cap**: `MAX_INFLIGHT_PER_PLAYER` inflight requests per player
* **Payload cap**: `MAX_PAYLOAD` (\~10MB) with TTL cleanup
* **Owner check**: responses must come from the same player that was asked
* **Duplicate/Replay**: tickets tracked; duplicates ignored briefly (`SEEN_TTL_MS`)

**Note:** FiveM latent bandwidth arg is **bytes/sec**. `BANDWIDTH_LIMIT = 1_000_000` ≈ 1 MB/s per target; tune for your player counts.

---

## Examples

### 1) Validated purchase (server)

```lua
RegisterSecureCallback("shop:buy",
  function(a)
    if type(a.item) ~= "string" then return false, "invalid item" end
    if type(a.qty)  ~= "number" or a.qty < 1 or a.qty > 50 then
      return false, "invalid qty"
    end
    return true
  end,
  function(a)
    local src = a.source
    -- do billing/inventory checks here…
    return true, "ok"
  end
)
```

Client:

```lua
local ok, msg = TriggerCallback("shop:buy", { item = "bread", qty = 2 }, 10)
if not ok then print("Purchase failed:", msg) end
```

### 2) Server pushes UI data to a player

```lua
RegisterCallback("ui:getDashboard", function(a)
    return { cash = 12345, jobs = { "miner", "trucker" } }
end)

-- later, from server:
TriggerCallbackFor(src, "ui:getDashboard", {}, 10, function(data, err)
    if err then print("dash err:", err) return end
    -- send to NUI or client state
end)
```

### 3) Big data with latent

```lua
-- either side
local big = { entries = {} }
for i=1, 500000 do big.entries[i] = { id=i, v=i*2 } end
TriggerLatentCallback("data:sync", big, 90, function(_, err)
    if err then print("sync failed:", err) end
end)
```

---

## Tips

* Don’t set `args.source` yourself; it’s injected.
* Keep event names simple; with `STRICT_EVENT_NAMES` they must match: `[%w%._%-:/]+`.
* Use validators (`RegisterSecureCallback`) for any action that changes state or money.
* Prefer **latent** for anything you expect to exceed \~128KB.

---

## License

MIT — see header in the source file.
