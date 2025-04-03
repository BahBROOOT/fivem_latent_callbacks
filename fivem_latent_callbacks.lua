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

local IS_SERVER = IsDuplicityVersion()
local msgpack = msgpack
local mpPack = msgpack.pack
local mpUnpack = msgpack.unpack
local callbackRegistry = {}
local requestPromises = {}
local incomingChunks = {}

-- Bandwidth limit for latent callbacks in bitspersecond (bps). Adjust if necessary.
local BANDWIDTH_LIMIT = 1000000

-- Generates a random ticket string to uniquely identify each callback request.
local function generateTicket()
    return tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
end

-- Registers a callback function for the provided event name.
-- @param eventName [string]    The event name.
-- @param func      [function]  The callback function.
function RegisterCallback(eventName, func)
    assert(type(eventName) == "string", "RegisterCallback: eventName must be a string.")
    assert(type(func) == "function", "RegisterCallback: func must be a function.")
    callbackRegistry[eventName] = func
end

-- Unregisters (removes) a callback.
-- @param eventName [string]  The event name to remove.
function UnregisterCallback(eventName)
    callbackRegistry[eventName] = nil
end

-- Handles the request by calling the registered function.
-- @param eventName    [string]  The event name.
-- @param ticket       [string]  The unique request ticket.
-- @param decodedArgs  [table]   Decoded arguments from the client.
-- @param sourcePlayer [number]  The player source (server) or -1 (client).
-- @return table The result of the callback function.
local function handleRequest(eventName, ticket, decodedArgs, sourcePlayer)
    local func = callbackRegistry[eventName]
    if not func then
        return table.pack(nil, ("No such callback: %s"):format(eventName))
    end

    -- Build args to pass to the callback function.
    local callbackArgs = { source = sourcePlayer }
    for k, v in pairs(decodedArgs) do
        callbackArgs[k] = v
    end

    -- Return the callback function result using table.pack to preserve multiple return values.
    return table.pack(func(callbackArgs))
end

-- Called when a response is received.
-- Resolves the stored promise for the request.
-- @param ticket      [string] The request ticket.
-- @param decodedData [table]  Decoded response data.
-- @param useLatent   [bool]   Whether latent was used.
-- @param target      [number] Target player or -1 (client).
local function handleResponse(ticket, decodedData, useLatent, target)
    local p = requestPromises[ticket]
    if p then
        requestPromises[ticket] = nil
        p:resolve(decodedData)
    end
end

-- Accumulates data chunks for latent events.
-- @param ticket [string] Unique request ticket.
-- @param chunk  [string] Data chunk.
-- @return table|nil Decoded data if complete, otherwise nil.
local function accumulateData(ticket, chunk)
    if not incomingChunks[ticket] then
        incomingChunks[ticket] = { data = "", complete = false }
    end

    local entry = incomingChunks[ticket]
    entry.data = entry.data .. chunk

    local success, decoded = pcall(mpUnpack, entry.data)
    if success and decoded then
        entry.complete = true
        return decoded
    end

    return nil
end

-- Triggers a callback on the other side (server->client or client->server).
-- @param eventName     [string]          The callback event name.
-- @param args          [table]           Arguments for the callback.
-- @param timeout       [number, optional]Timeout in seconds.
-- @param asyncCallback [function]        Async callback.
-- @param method        [string]          'normal' or 'latent'.
function TriggerCallback(eventName, args, timeout, asyncCallback, method)
    assert(type(eventName) == "string", "TriggerCallback: eventName must be a string.")

    args = args or {}
    method = method or "normal"

    local ticket = generateTicket()
    local p = promise.new()
    requestPromises[ticket] = p

    -- Set optional timeout to reject the promise if not resolved.
    if timeout and timeout > 0 then
        SetTimeout(timeout * 1000, function()
            if requestPromises[ticket] then
                requestPromises[ticket] = nil
                p:reject({ error = "Callback timed out." })
            end
        end)
    end

    local useLatent = (method == "latent")

    if IS_SERVER then
        -- Server must be calling a client. Extract playerId from args.
        local playerId = args.__playerId
        assert(playerId, "TriggerCallback (server): Missing __playerId in args.")
        args.__playerId = nil

        local packed = mpPack(args)

        if useLatent then
            TriggerLatentClientEvent("callback:request", playerId, BANDWIDTH_LIMIT, eventName, ticket, packed)
        else
            TriggerClientEvent("callback:request", playerId, eventName, ticket, packed)
        end
    else
        -- Client to server, no __playerId needed.
        local packed = mpPack(args)

        if useLatent then
            TriggerLatentServerEvent("callback:request", BANDWIDTH_LIMIT, eventName, ticket, packed)
        else
            TriggerServerEvent("callback:request", eventName, ticket, packed)
        end
    end

    -- If asyncCallback is provided, run in a new thread and invoke it with results.
    if asyncCallback then
        Citizen.CreateThread(function()
            local result = Citizen.Await(p)
            if type(result) == "table" and result.n ~= nil then
                asyncCallback(table.unpack(result, 1, result.n))
            elseif type(result) == "table" then
                asyncCallback(table.unpack(result))
            else
                asyncCallback(result)
            end
        end)    
        return
    else
        local result = Citizen.Await(p)

        -- If this is a packed return (table with `n`), unpack it.
        if type(result) == "table" and result.n ~= nil then
            return table.unpack(result, 1, result.n)
        -- If it's a regular table (not packed), just return it
        elseif type(result) == "table" then
            return table.unpack(result)
        else
            return result
        end
    
    end
end

-- Wrapper function for triggering a latent callback.
-- @param eventName     [string]
-- @param args          [table]
-- @param timeout       [number]
-- @param asyncCallback [function]
function TriggerLatentCallback(eventName, args, timeout, asyncCallback)
    return TriggerCallback(eventName, args, timeout, asyncCallback, "latent")
end

-- Event Handlers
--------------------------------------------------------------------------------

if IS_SERVER then
    -- Called when client requests a callback.
    RegisterNetEvent("callback:request", function(eventName, ticket, partialData)
        local _source = source
        local decoded
        local success, result = pcall(mpUnpack, partialData)
        if success and result then
            decoded = result
        else
            decoded = accumulateData(ticket, partialData)
        end

        if decoded then
            incomingChunks[ticket] = nil
            local response = handleRequest(eventName, ticket, decoded, _source)
            local packedRes = mpPack(response)

            -- We respond using latent event to handle large data.
            TriggerLatentClientEvent("callback:response", _source, BANDWIDTH_LIMIT, ticket, packedRes)
        end
    end)

    -- Called when client sends a response.
    RegisterNetEvent("callback:response", function(ticket, partialData)
        local decoded
        local success, result = pcall(mpUnpack, partialData)
        if success and result then
            decoded = result
        else
            decoded = accumulateData(ticket, partialData)
        end

        if decoded then
            incomingChunks[ticket] = nil
            handleResponse(ticket, decoded, true, source)
        end
    end)
else
    -- Called when server requests a callback.
    RegisterNetEvent("callback:request", function(eventName, ticket, partialData)
        local decoded
        local success, result = pcall(mpUnpack, partialData)
        if success and result then
            decoded = result
        else
            decoded = accumulateData(ticket, partialData)
        end

        if decoded then
            incomingChunks[ticket] = nil
            local response = handleRequest(eventName, ticket, decoded, -1)
            local packedRes = mpPack(response)

            -- Respond with a latent server event.
            TriggerLatentServerEvent("callback:response", BANDWIDTH_LIMIT, ticket, packedRes)
        end
    end)

    -- Called when server sends a response.
    RegisterNetEvent("callback:response", function(ticket, partialData)
        local decoded
        local success, result = pcall(mpUnpack, partialData)
        if success and result then
            decoded = result
        else
            decoded = accumulateData(ticket, partialData)
        end

        if decoded then
            incomingChunks[ticket] = nil
            handleResponse(ticket, decoded, true, -1)
        end
    end)
end
