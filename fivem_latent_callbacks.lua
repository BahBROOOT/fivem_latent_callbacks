--[[
    MIT License

    Copyright (c) 2025 BahBROOOT

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
]]--

-- Version very IMPORTANT in order for different versions in different scripts to work alongside
VERSION = "2.0.0" -- Do NOT edit

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local IS_SERVER = IsDuplicityVersion()
local RESOURCE  = GetCurrentResourceName()

-- Make Sure different versions dont collide. (Wont Accept each other callbacks but wont break)
local EVENT_PREFIX  = ("v-%s-cb:"):format(VERSION)
local REQ_EVENT     = EVENT_PREFIX .. "request"
local RES_EVENT     = EVENT_PREFIX .. "response"

-- Latent bandwidth limit (BYTES/sec). Tune per your server.
local BANDWIDTH_LIMIT = 1_000_000   -- ~1 MB/s per target

-- Safety caps
local MAX_PAYLOAD        = 10 * 1024 * 1024  -- 10 MB max unpacked payload per ticket
local CHUNK_TTL_MS       = 60 * 1000         -- 60s TTL for partial data
local SEEN_TTL_MS        = 120 * 1000        -- 120s TTL for processed ticket markers
local TIMEOUT_DEFAULT_S  = 30                -- If a caller passes nil as timeout you can use this.

-- Per-player DoS controls (server side on inbound client->server requests)
local RATE_TOKENS_PER_SEC   = 60             -- logical "ops" per second refill
local RATE_BURST            = 120            -- allow short bursts
local RATE_COST_PER_REQUEST = 1              -- cost per logical request (plus size-based cost)
local RATE_COST_PER_64KB    = 1              -- additional cost per 64KB of payload

-- Concurrency caps per player (server-side)
local MAX_INFLIGHT_PER_PLAYER = 8

-- Event name hygiene (for your own callback registry)
local STRICT_EVENT_NAMES = true
local EVENTNAME_PATTERN  = "^[%w%._%-:/]+$"  -- loosen/tighten as you wish

-- Debug logging
local debug = false
local function dbg(...)
    if debug then
        print(("[Callback][v:%s][DEBUG]"):format(VERSION), ...)
    end
end

--------------------------------------------------------------------------------
-- Primitives & State
--------------------------------------------------------------------------------

-- FiveM msgpack
local mpPack   = msgpack.pack
local mpUnpack = msgpack.unpack

-- Global-ish state
local callbackRegistry     = {}   -- eventName => function(args)
local requestPromises      = {}   -- ticket => promise
local incomingChunks       = {}   -- ticket => { data, complete, owner, ttlSet }
local inflightRequests     = {}   -- ticket => true (duplicate guard)
local processedTickets     = {}   -- ticket => true (seen marker with TTL)
local expectedOwner        = {}   -- ticket => owner id ("server" or player id)

-- Server-only state
local perPlayerInflight    = {}   -- [playerId] => count
local perPlayerRate        = {}   -- [playerId] => { tokens, last_ms }

-- Ticket generator (time + random + counter)
local _ctr = 0
local function generateTicket()
    _ctr = (_ctr + 1) % 1000000000
    return ("%d-%08d-%09d"):format(GetGameTimer(), math.random(0, 99999999), _ctr)
end

local function setTTL(tbl, key, ttl_ms)
    if tbl[key] and not tbl[key].ttlSet then
        tbl[key].ttlSet = true
        SetTimeout(ttl_ms, function()
            tbl[key] = nil
        end)
    end
end

-- Promise await without crashing thread on reject
local function awaitPromise(p)
    local ok, result = pcall(function() return Citizen.Await(p) end)
    if ok then return true, result end
    return false, tostring(result)
end

-- Build safe args (block 'source' spoofing)
local function buildSafeArgs(decodedArgs, sourcePlayer)
    local callbackArgs = {}
    for k, v in pairs(decodedArgs or {}) do
        if k ~= "source" then
            callbackArgs[k] = v
        end
    end
    callbackArgs.source = sourcePlayer
    return callbackArgs
end

local function handleRequest(eventName, ticket, decodedArgs, sourcePlayer)
    local func = callbackRegistry[eventName]
    if not func then
        return table.pack(nil, ("No such callback: %s"):format(eventName))
    end
    local results = { func(buildSafeArgs(decodedArgs, sourcePlayer)) }
    if #results > 1 then
        return table.pack(table.unpack(results))
    elseif type(results[1]) == "table" then
        return table.pack(results[1])
    else
        return table.pack(results[1])
    end
end

local function handleResponse(ticket, decodedData)
    local p = requestPromises[ticket]
    if not p then
        dbg("No pending promise for ticket:", ticket)
        return
    end
    requestPromises[ticket] = nil
    expectedOwner[ticket]   = nil
    inflightRequests[ticket]= nil
    incomingChunks[ticket]  = nil

    if type(decodedData) == "table" and decodedData.n then
        p:resolve(table.unpack(decodedData, 1, decodedData.n))
    else
        p:resolve(decodedData)
    end
end

-- Accumulate latent chunks until msgpack.unpack succeeds (harmless if whole-at-once)
local function accumulateData(ticket, chunk, owner)
    local entry = incomingChunks[ticket]
    if not entry then
        entry = { data = "", complete = false, owner = owner, ttlSet = false }
        incomingChunks[ticket] = entry
        setTTL(incomingChunks, ticket, CHUNK_TTL_MS)
    else
        if entry.owner ~= owner then
            dbg("Chunk owner mismatch for ticket", ticket, "ignoring")
            return nil
        end
    end

    entry.data = entry.data .. (chunk or "")
    if #entry.data > MAX_PAYLOAD then
        print(("[Callback][%s] Payload too large (>%d bytes). Discarding ticket %s."):format(RESOURCE, MAX_PAYLOAD, ticket))
        incomingChunks[ticket] = nil
        return nil
    end

    local ok, decoded = pcall(mpUnpack, entry.data)
    if ok and decoded ~= nil then
        entry.complete = true
        return decoded
    end
    return nil
end

local function markProcessed(ticket)
    processedTickets[ticket] = true
    SetTimeout(SEEN_TTL_MS, function()
        processedTickets[ticket] = nil
    end)
end

--------------------------------------------------------------------------------
-- REGISTER / UNREGISTER
--------------------------------------------------------------------------------

function RegisterCallback(eventName, handler)
    assert(type(eventName) == "string", "RegisterCallback: eventName must be a string.")
    assert(type(handler) == "function", "RegisterCallback: handler must be a function.")
    if STRICT_EVENT_NAMES then
        assert(eventName:match(EVENTNAME_PATTERN), ("RegisterCallback: invalid event name '%s'"):format(eventName))
    end
    callbackRegistry[eventName] = handler
end

function UnregisterCallback(eventName)
    callbackRegistry[eventName] = nil
end

--------------------------------------------------------------------------------
-- RATE LIMITING & CONCURRENCY (server-side)
--------------------------------------------------------------------------------

local function rateAllow(playerId, bytes)
    local now = GetGameTimer()
    local r = perPlayerRate[playerId]
    if not r then
        r = { tokens = RATE_BURST, last_ms = now }
        perPlayerRate[playerId] = r
    end
    local elapsed = (now - r.last_ms) / 1000.0
    r.tokens = math.min(RATE_BURST, r.tokens + elapsed * RATE_TOKENS_PER_SEC)
    r.last_ms = now

    local sizeCost = math.floor((bytes or 0) / (64 * 1024)) * RATE_COST_PER_64KB
    local cost = RATE_COST_PER_REQUEST + sizeCost
    if r.tokens >= cost then
        r.tokens = r.tokens - cost
        return true
    end
    return false
end

local function inflightInc(playerId)
    local n = (perPlayerInflight[playerId] or 0) + 1
    perPlayerInflight[playerId] = n
    return n <= MAX_INFLIGHT_PER_PLAYER
end

local function inflightDec(playerId)
    if perPlayerInflight[playerId] then
        perPlayerInflight[playerId] = math.max(0, perPlayerInflight[playerId] - 1)
        if perPlayerInflight[playerId] == 0 then
            perPlayerInflight[playerId] = nil
        end
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API - TRIGGER
--------------------------------------------------------------------------------

--- Generic trigger (client->server or server->client).
--- On server pass playerId via TriggerCallbackFor instead of stuffing __playerId.
function TriggerCallback(eventName, args, timeout, asyncCallback, method)
    assert(type(eventName) == "string", "TriggerCallback: eventName must be a string.")
    args   = args or {}
    method = method or "normal"

    local ticket = generateTicket()
    local p = promise.new()
    requestPromises[ticket] = p

    local to = tonumber(timeout or TIMEOUT_DEFAULT_S)
    if to and to > 0 then
        SetTimeout(to * 1000, function()
            if requestPromises[ticket] then
                requestPromises[ticket] = nil
                expectedOwner[ticket]   = nil
                incomingChunks[ticket]  = nil
                inflightRequests[ticket]= nil
                p:reject("Callback timed out.")
            end
        end)
    end

    local useLatent = (method == "latent")

    if IS_SERVER then
        -- SERVER -> CLIENT
        local playerId = args.__playerId
        assert(playerId, "TriggerCallback (server): Missing __playerId. Use TriggerCallbackFor(playerId, ...).")
        args.__playerId = nil                -- scrub BEFORE packing
        local packed = mpPack(args)
        expectedOwner[ticket] = playerId

        if useLatent then
            TriggerLatentClientEvent(REQ_EVENT, playerId, BANDWIDTH_LIMIT, eventName, ticket, packed, true)
        else
            TriggerClientEvent(REQ_EVENT, playerId, eventName, ticket, packed, false)
        end
    else
        -- CLIENT -> SERVER
        local packed = mpPack(args)
        expectedOwner[ticket] = "server"

        if useLatent then
            TriggerLatentServerEvent(REQ_EVENT, BANDWIDTH_LIMIT, eventName, ticket, packed, true)
        else
            TriggerServerEvent(REQ_EVENT, eventName, ticket, packed, false)
        end
    end

    -- Async style
    if asyncCallback then
        Citizen.CreateThread(function()
            local ok, result = awaitPromise(p)
            if not ok then
                asyncCallback(nil, result)
                return
            end
            if type(result) == "table" and result.n then
                asyncCallback(table.unpack(result, 1, result.n))
            elseif type(result) == "table" and not getmetatable(result) then
                asyncCallback(table.unpack(result))
            else
                asyncCallback(result)
            end
        end)
        return
    end

    -- Sync style
    local ok, result = awaitPromise(p)
    if not ok then return nil, result end
    if type(result) == "table" and result.n then
        return table.unpack(result, 1, result.n)
    elseif type(result) == "table" and not getmetatable(result) then
        return table.unpack(result)
    else
        return result
    end
end

--- Convenience: SERVER ONLY. Avoids ever putting playerId in args.
function TriggerCallbackFor(playerId, eventName, args, timeout, asyncCallback, method)
    assert(IS_SERVER, "TriggerCallbackFor can only be used server-side.")
    args = args or {}
    args.__playerId = playerId
    return TriggerCallback(eventName, args, timeout, asyncCallback, method)
end

--- Wrappper for latent mode.
function TriggerLatentCallback(eventName, args, timeout, asyncCallback)
    return TriggerCallback(eventName, args, timeout, asyncCallback, "latent")
end

--------------------------------------------------------------------------------
-- NET EVENT HANDLERS
--------------------------------------------------------------------------------

if IS_SERVER then
    --------------------------------------------------------------------------
    -- SERVER receives a REQUEST from a client
    --------------------------------------------------------------------------
    RegisterNetEvent(REQ_EVENT, function(eventName, ticket, partialData, useLatentResponse)
        local _source = source

        if STRICT_EVENT_NAMES and not (type(eventName)=="string" and eventName:match(EVENTNAME_PATTERN)) then
            dbg("Rejecting request with bad eventName from", _source)
            return
        end

        local myCallback = callbackRegistry[eventName]
        if not myCallback then
            dbg("Ignoring unregistered callback:", eventName)
            return
        end

        -- Basic rate limit by chunk size (works even if latent delivers whole-at-once)
        local bytes = type(partialData) == "string" and #partialData or 0
        if not rateAllow(_source, bytes) then
            dbg("Rate limit exceeded for", _source, "bytes:", bytes)
            return
        end

        -- Concurrency cap
        if not inflightInc(_source) then
            dbg("Too many inflight requests for", _source)
            return
        end

        -- Deduplicate
        if processedTickets[ticket] then
            dbg("Duplicate request (already processed) ticket:", ticket)
            inflightDec(_source)
            return
        end

        local decoded
        if useLatentResponse then
            decoded = accumulateData(ticket, partialData, _source)
        else
            local ok, obj = pcall(mpUnpack, partialData)
            decoded = ok and obj or nil
        end

        if not decoded then
            -- Still waiting for more chunks OR unpack failed
            inflightDec(_source)
            return
        end

        -- Guard duplicate completion
        if inflightRequests[ticket] then
            dbg("Request already in-flight; ignoring duplicate completion:", ticket)
            inflightDec(_source)
            return
        end
        inflightRequests[ticket] = true
        incomingChunks[ticket]   = nil

        -- Execute user callback
        local response = handleRequest(eventName, ticket, decoded, _source)
        local packedRes = mpPack(response)

        -- Mark processed & release inflight
        markProcessed(ticket)
        inflightRequests[ticket] = nil
        inflightDec(_source)

        -- Send response (mirror latent preference)
        if useLatentResponse then
            TriggerLatentClientEvent(RES_EVENT, _source, BANDWIDTH_LIMIT, eventName, ticket, true, packedRes)
        else
            TriggerClientEvent(RES_EVENT, _source, eventName, ticket, false, packedRes)
        end
    end)

    --------------------------------------------------------------------------
    -- SERVER receives a RESPONSE from a client
    --------------------------------------------------------------------------
    RegisterNetEvent(RES_EVENT, function(eventName, ticket, isLatent, partialData)
        local _source = source
        dbg("Server got response ticket:", ticket, "latent:", isLatent)

        -- Only for tickets we are awaiting
        if not requestPromises[ticket] then
            dbg("Dropping response for unknown/expired ticket:", ticket)
            return
        end

        -- Verify responder is the expected owner
        local expected = expectedOwner[ticket]
        if expected and expected ~= _source then
            dbg("Response owner mismatch. Expected:", expected, "got:", _source)
            return
        end

        local decoded
        if isLatent then
            decoded = accumulateData(ticket, partialData, _source)
        else
            local ok, obj = pcall(mpUnpack, partialData)
            decoded = ok and obj or nil
        end

        if decoded then
            incomingChunks[ticket] = nil
            handleResponse(ticket, decoded)
        end
    end)

else
    --------------------------------------------------------------------------
    -- CLIENT receives a REQUEST from the server
    --------------------------------------------------------------------------
    RegisterNetEvent(REQ_EVENT, function(eventName, ticket, partialData, useLatentResponse)
        if STRICT_EVENT_NAMES and not (type(eventName)=="string" and eventName:match(EVENTNAME_PATTERN)) then
            dbg("Rejecting request with bad eventName on client")
            return
        end

        local myCallback = callbackRegistry[eventName]
        if not myCallback then
            dbg("Ignoring unregistered callback on client:", eventName)
            return
        end

        local decoded
        if useLatentResponse then
            decoded = accumulateData(ticket, partialData, "server")
        else
            local ok, obj = pcall(mpUnpack, partialData)
            decoded = ok and obj or nil
        end

        if not decoded then
            return
        end

        if inflightRequests[ticket] then
            dbg("Client in-flight duplicate:", ticket)
            return
        end
        inflightRequests[ticket] = true
        incomingChunks[ticket]   = nil

        local response = handleRequest(eventName, ticket, decoded, -1)
        local packedRes = mpPack(response)
        markProcessed(ticket)
        inflightRequests[ticket] = nil

        if useLatentResponse then
            TriggerLatentServerEvent(RES_EVENT, BANDWIDTH_LIMIT, eventName, ticket, true, packedRes)
        else
            TriggerServerEvent(RES_EVENT, eventName, ticket, false, packedRes)
        end
    end)

    --------------------------------------------------------------------------
    -- CLIENT receives a RESPONSE from the server
    --------------------------------------------------------------------------
    RegisterNetEvent(RES_EVENT, function(eventName, ticket, isLatent, partialData)
        dbg("Client got response ticket:", ticket, "latent:", isLatent)

        if not requestPromises[ticket] then
            dbg("Client dropping unknown/expired ticket:", ticket)
            return
        end

        local decoded
        if isLatent then
            decoded = accumulateData(ticket, partialData, "server")
        else
            local ok, obj = pcall(mpUnpack, partialData)
            decoded = ok and obj or nil
        end

        if decoded then
            incomingChunks[ticket] = nil
            handleResponse(ticket, decoded)
        end
    end)
end

--------------------------------------------------------------------------------
-- CLEANUP ON RESOURCE STOP
--------------------------------------------------------------------------------

AddEventHandler("onResourceStop", function(res)
    if res ~= RESOURCE then return end
    -- Reject all pending promises to avoid dangling awaits
    for ticket, p in pairs(requestPromises) do
        p:reject("Resource stopping")
        requestPromises[ticket] = nil
    end
    incomingChunks      = {}
    inflightRequests    = {}
    processedTickets    = {}
    expectedOwner       = {}
    perPlayerInflight   = {}
    perPlayerRate       = {}
end)

--------------------------------------------------------------------------------
-- OPTIONAL: HELPER API FOR VALIDATION LAYER
--------------------------------------------------------------------------------
-- Example usage:
-- RegisterSecureCallback("inv:buy", function(args)
--     -- return false, "reason" to reject before user handler runs
--     if type(args.item) ~= "string" then return false, "bad item" end
--     return true
-- end, function(args)
--     -- your handler
-- end)

function RegisterSecureCallback(eventName, validator, handler)
    assert(type(validator) == "function", "RegisterSecureCallback: validator must be a function.")
    RegisterCallback(eventName, function(args)
        local ok, reason = validator(args)
        if ok == false then
            return nil, tostring(reason or "validation failed")
        end
        return handler(args)
    end)
end
