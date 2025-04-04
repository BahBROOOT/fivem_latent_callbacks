--[[
    MIT License

    Copyright (c) [2025] [BahBROOOT (BahBROOOT1)]

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

-- Thx LLM's for the comments hehe (This looked like garbage before)

--[[
    This module provides a callback system for client-server communication in FiveM.
    It allows for both normal and latent callbacks, with support for binary data
    serialization using msgpack. The system handles request-response patterns and
    manages timeouts and chunked data transfer for large payloads.
]]--

--------------------------------------------------------------------------------
-- Shared Callback Implementation
--------------------------------------------------------------------------------

local IS_SERVER = IsDuplicityVersion()

-- Use msgpack for binary serialization of payloads
local msgpack = msgpack
local mpPack = msgpack.pack
local mpUnpack = msgpack.unpack

-- Internal state tables
local callbackRegistry = {}       -- Stores registered callbacks (eventName => function)
local requestPromises = {}        -- Stores awaiting callback responses (ticket => promise)
local incomingChunks = {}         -- Stores chunks received for a ticket (used in latent mode)
local resolvedTickets = {}        -- Prevents double-resolution of a ticket

-- Bandwidth limit for latent callbacks (in bits per second)
local BANDWIDTH_LIMIT = 1000000 -- 1 Mbps by default

local debug = false -- Set to true for debug messages
if debug then
    print("[Callback] Debug mode enabled.")
end

-- Generates a random unique string used as a ticket ID
local function generateTicket()
    return tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
end

--------------------------------------------------------------------------------
-- Register/Unregister
--------------------------------------------------------------------------------

--- Registers a named callback handler
---@param eventName string
---@param func function
function RegisterCallback(eventName, func)
    assert(type(eventName) == "string", "RegisterCallback: eventName must be a string.")
    assert(type(func) == "function", "RegisterCallback: func must be a function.")
    callbackRegistry[eventName] = func
end

--- Unregisters a named callback
---@param eventName string
function UnregisterCallback(eventName)
    callbackRegistry[eventName] = nil
end

--------------------------------------------------------------------------------
-- Internal - Handling Requests
--------------------------------------------------------------------------------

local function handleRequest(eventName, ticket, decodedArgs, sourcePlayer)
    local func = callbackRegistry[eventName]
    if not func then
        return table.pack(nil, ("No such callback: %s"):format(eventName))
    end

    -- Build the argument table that the callback sees
    local callbackArgs = { source = sourcePlayer }
    for k, v in pairs(decodedArgs) do
        callbackArgs[k] = v
    end

    -- Run the registered callback
    local results = { func(callbackArgs) }

    -- Always wrap returns so they can be unpacked consistently
    if #results > 1 then
        return table.pack(table.unpack(results))
    elseif type(results[1]) == "table" then
        return table.pack(results[1])
    else
        return table.pack(results[1])
    end
end

--------------------------------------------------------------------------------
-- Internal - Handling Responses
--------------------------------------------------------------------------------

local function handleResponse(ticket, decodedData, isLatent, target)
    if resolvedTickets[ticket] then
        if debug then
            print("[Callback] Ticket already resolved:", ticket)
        end
        return
    end

    resolvedTickets[ticket] = true

    local p = requestPromises[ticket]
    if p then
        requestPromises[ticket] = nil
        if debug then
            print("[Callback] Resolving ticket:", ticket, "with data size:", #decodedData)
        end

        -- If data is a packed table with .n, unpack it
        if type(decodedData) == "table" and decodedData.n then
            p:resolve(table.unpack(decodedData, 1, decodedData.n))
        else
            p:resolve(decodedData)
        end
    else
        if debug then
            print("[Callback] No promise found for ticket:", ticket)
        end
    end
end

--------------------------------------------------------------------------------
-- Internal - Accumulate Data for Latent
--------------------------------------------------------------------------------

local function accumulateData(ticket, chunk)
    if not incomingChunks[ticket] then
        incomingChunks[ticket] = { data = "", complete = false }
    end

    local entry = incomingChunks[ticket]
    entry.data = entry.data .. chunk

    -- 10MB payload limit for safety
    if #entry.data > 10 * 1024 * 1024 then
        print("[Callback] Payload too large. Discarding:", ticket)
        incomingChunks[ticket] = nil
        return nil
    end

    local success, decoded = pcall(mpUnpack, entry.data)
    if success and decoded then
        entry.complete = true
        if debug then
            print("[Callback] Successfully decoded data for ticket:", ticket, "Size:", #entry.data)
        end
        return decoded
    else
        if debug then
            print("[Callback] Waiting for more chunks. Ticket:", ticket, "Size:", #entry.data)
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- Public API - TriggerCallback
--------------------------------------------------------------------------------

--- Triggers a callback on the other side (client->server or server->client)
---@param eventName string
---@param args table|nil
---@param timeout number|nil
---@param asyncCallback function|nil
---@param method "normal"|"latent"|nil
function TriggerCallback(eventName, args, timeout, asyncCallback, method)
    assert(type(eventName) == "string", "TriggerCallback: eventName must be a string.")

    args = args or {}
    method = method or "normal"
    local ticket = generateTicket()
    local p = promise.new()
    requestPromises[ticket] = p

    if timeout and timeout > 0 then
        SetTimeout(timeout * 1000, function()
            if requestPromises[ticket] then
                requestPromises[ticket] = nil
                -- Fix "SCRIPT ERROR: error object is not a string"
                p:reject("Callback timed out.")
            end
        end)
    end

    local useLatent = (method == "latent")
    local packed = mpPack(args)

    if IS_SERVER then
        local playerId = args.__playerId
        assert(playerId, "TriggerCallback (server): Missing __playerId in args.")
        args.__playerId = nil

        if useLatent then
            
            TriggerLatentClientEvent("callback:request", playerId, BANDWIDTH_LIMIT, eventName, ticket, packed, true)
        else
            TriggerClientEvent("callback:request", playerId, eventName, ticket, packed, false)
        end
    else
        if useLatent then
            TriggerLatentServerEvent("callback:request", BANDWIDTH_LIMIT, eventName, ticket, packed, true)
        else
            TriggerServerEvent("callback:request", eventName, ticket, packed, false)
        end
    end

    -- If asyncCallback is provided, we handle asynchronously
    if asyncCallback then
        Citizen.CreateThread(function()
            local result = Citizen.Await(p)
            if type(result) == "table" and result.n then
                asyncCallback(table.unpack(result, 1, result.n))
            elseif type(result) == "table" and not getmetatable(result) then
                asyncCallback(table.unpack(result))
            else
                asyncCallback(result)
            end
        end)
        return
    else
        -- Otherwise, wait (blocking) for the response
        local result = Citizen.Await(p)
        if type(result) == "table" and result.n then
            return table.unpack(result, 1, result.n)
        elseif type(result) == "table" and not getmetatable(result) then
            return table.unpack(result)
        else
            return result
        end
    end
end

--- Triggers a latent callback (wrapper)
function TriggerLatentCallback(eventName, args, timeout, asyncCallback)
    return TriggerCallback(eventName, args, timeout, asyncCallback, "latent")
end

--------------------------------------------------------------------------------
-- Event Handlers
--------------------------------------------------------------------------------

if IS_SERVER then
    -- Server receives a request from the client
    RegisterNetEvent("callback:request", function(eventName, ticket, partialData, useLatentResponse)
        local myCallback = callbackRegistry[eventName]

        if not myCallback then
            if debug then
                print("[Callback] This callback is not registered or meant for me:", eventName)
            end
        end

        if myCallback then
            local _source = source
            local decoded = accumulateData(ticket, partialData)

            if decoded then
                incomingChunks[ticket] = nil
                local response = handleRequest(eventName, ticket, decoded, _source)
                local packedRes = mpPack(response)
                if useLatentResponse then
                    if debug then
                        print("[Callback] Latent response sent. Ticket:", ticket, "Size:", #packedRes)
                    end
                    TriggerLatentClientEvent("callback:response", _source, BANDWIDTH_LIMIT, eventName, ticket, true, packedRes)
                else
                    if debug then
                        print("[Callback] Normal response sent. Ticket:", ticket, "Size:", #packedRes)
                    end
                    TriggerClientEvent("callback:response", _source, eventName, ticket, false, packedRes)
                end
            end
        end
    end)

    -- Server receives a response from the client
    RegisterNetEvent("callback:response", function(eventName, ticket, isLatent, partialData)
        if debug then
            print("[Callback] Received response. Ticket:", ticket, "Size:", #partialData, "Latent:", isLatent)
        end

        local decoded = isLatent and accumulateData(ticket, partialData) or (select(2, pcall(mpUnpack, partialData)))
        if decoded then
            incomingChunks[ticket] = nil
            handleResponse(ticket, decoded, isLatent, source)
        else
            if debug then
                print("[Callback] Waiting for more chunks. Ticket:", ticket)
            end
        end
    end)
else
    -- Client receives a request from the server
    RegisterNetEvent("callback:request", function(eventName, ticket, partialData, useLatentResponse)
        local myCallback = callbackRegistry[eventName]

        if not myCallback then
            if debug then
                print("[Callback] This callback is not registered or meant for me:", eventName)
            end
        end

        if myCallback then
            local decoded = accumulateData(ticket, partialData)

            if decoded then
                incomingChunks[ticket] = nil
                local response = handleRequest(eventName, ticket, decoded, -1)
                local packedRes = mpPack(response)
                if useLatentResponse then
                    if debug then
                        print("[Callback] Latent response sent. Ticket:", ticket, "Size:", #packedRes)
                    end
                    TriggerLatentServerEvent("callback:response", BANDWIDTH_LIMIT, eventName, ticket, true, packedRes)
                else
                    if debug then
                        print("[Callback] Normal response sent. Ticket:", ticket, "Size:", #packedRes)
                    end
                    TriggerServerEvent("callback:response", eventName, ticket, false, packedRes)
                end
            end
        end
    end)

    -- Client receives a response from the server
    RegisterNetEvent("callback:response", function(eventName, ticket, isLatent, partialData)
        if debug then
            print("[Callback] Received response. Ticket:", ticket, "Size:", #partialData, "Latent:", isLatent)
        end

        local decoded = isLatent and accumulateData(ticket, partialData) or (select(2, pcall(mpUnpack, partialData)))
        if decoded then
            incomingChunks[ticket] = nil
            handleResponse(ticket, decoded, isLatent, -1)
        else
            if debug then
                print("[Callback] Waiting for more chunks. Ticket:", ticket)
            end
        end
    end)
end