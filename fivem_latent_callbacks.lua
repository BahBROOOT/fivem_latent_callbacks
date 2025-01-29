local IS_SERVER = IsDuplicityVersion()
local msgpack = msgpack
local mpPack = msgpack.pack
local mpUnpack = msgpack.unpack
local callbackRegistry = {}
local requestPromises = {}
local incomingChunks = {}

-- Bandwidth limit for latent callbacks (in bps). Adjust if necessary.
local BANDWIDTH_LIMIT = 1000000

local function generateTicket()
    return tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
end

-- Registers a callback function for the specified event name.
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

-- Actually handles the request by calling the registered function.
-- @param eventName    [string]  The event name.
-- @param ticket       [string]  The unique request ticket.
-- @param decodedArgs  [table]   Decoded arguments from the client.
-- @param sourcePlayer [number]  The player source (server) or -1 (client).
-- @return table The result of the callback function.
local function handleRequest(eventName, ticket, decodedArgs, sourcePlayer)
    local func = callbackRegistry[eventName]
    if not func then
        return { error = ("No such callback: %s"):format(eventName) }
    end

    -- Build args to pass to the callback function.
    local callbackArgs = { source = sourcePlayer }
    for k, v in pairs(decodedArgs) do
        callbackArgs[k] = v
    end

    -- Return the callback function result in a table.
    return { func(callbackArgs) }
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
        p:resolve(table.unpack(decodedData))
    end

    -- Optionally forward data back to the other side if needed. eg for chain calls.
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

    if timeout and timeout > 0 then
        SetTimeout(timeout * 1000, function()
            if requestPromises[ticket] then
                requestPromises[ticket] = nil
                p:reject("Callback timed out.")
            end
        end)
    end

    local packed = mpPack(args)
    local useLatent = (method == "latent")

    if IS_SERVER then
        local playerId = args.__playerId
        assert(playerId, "TriggerCallback (server): Missing __playerId in args.")
        args.__playerId = nil

        if useLatent then
            TriggerLatentClientEvent("callback:request", playerId, BANDWIDTH_LIMIT, eventName, ticket, packed)
        else
            TriggerClientEvent("callback:request", playerId, eventName, ticket, packed)
        end
    else
        if useLatent then
            TriggerLatentServerEvent("callback:request", BANDWIDTH_LIMIT, eventName, ticket, packed)
        else
            TriggerServerEvent("callback:request", eventName, ticket, packed)
        end
    end

    if asyncCallback then
        Citizen.CreateThread(function()
            local result = Citizen.Await(p)
            asyncCallback(table.unpack(result))
        end)
        return
    else
        local result = Citizen.Await(p)
        if type(result) == "table" then
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
