-- client/main.lua
-- ERS Bridge for CDECAD — Client-side
-- Provides coordinate/postal data to server-side events when needed.

local isOnCallout = false

-- ─── Helper: Debug logging (matches server DebugLog) ─────────────────────────
local function DebugLog(msg)
    if Config and Config.EnableDebug then
        print("[CDE-ERS Client] " .. tostring(msg))
    end
end

-- ─── Helper: Check if player is on an ERS shift ────────────────────────────
function IsPlayerOnErsShift()
    local success, result = pcall(function()
        return exports['night_ers']:getIsPlayerOnShift()
    end)
    return success and result or false
end

-- ─── Helper: Check if player is attached to an ERS callout ─────────────────
function IsPlayerOnCallout()
    local success, result = pcall(function()
        return exports['night_ers']:getIsPlayerAttachedToCallout()
    end)
    return success and result or false
end

-- ─── Helper: Get player's active ERS service type ──────────────────────────
function GetPlayerServiceType()
    local success, result = pcall(function()
        return exports['night_ers']:getPlayerActiveServiceType()
    end)
    return success and result or "police"
end

-- ─── Helper: Get nearest postal code ───────────────────────────────────────
function GetNearestPostal()
    local success, result = pcall(function()
        return exports['nearest-postal']:getPostal()
    end)
    if success and result then
        return tostring(result)
    end
    return ""
end

-- ─── Helper: Get player location data for CAD ──────────────────────────────
local function GetPlayerLocationData()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    -- Street name
    local streetHash, crossingHash = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    local streetName = GetStreetNameFromHashKey(streetHash) or ""
    local crossingName = GetStreetNameFromHashKey(crossingHash) or ""
    local location = streetName
    if crossingName ~= "" then
        location = location .. " / " .. crossingName
    end

    -- Zone name
    local zoneHash = GetNameOfZone(coords.x, coords.y, coords.z)
    local zoneName = GetLabelText(zoneHash)
    if zoneName and zoneName ~= "NULL" and zoneName ~= "" then
        location = location .. ", " .. zoneName
    end

    -- Postal
    local postal = GetNearestPostal()

    return {
        location = location,
        postal = postal,
        coordinates = { x = coords.x, y = coords.y, z = coords.z },
    }
end

-- ─── Server location request handler ─────────────────────────────────────
-- Server requests location data when it needs street names for traffic stops
RegisterNetEvent('ErsIntegration::RequestLocation')
AddEventHandler('ErsIntegration::RequestLocation', function()
    local loc = GetPlayerLocationData()
    TriggerServerEvent('ErsIntegration::LocationResponse', loc)
end)

-- ========================================================================
-- ERS OPEN-SOURCE CALLBACK FUNCTIONS
-- ========================================================================
-- ERS calls these global functions on the client when events occur.
-- We forward them to the server via TriggerServerEvent so our server
-- handlers can process the data and push it to the CAD API.
-- Ref: https://docs.nights-software.com/resources/ers/#-open-source-functions--events

-- ─── Callout Lifecycle ───────────────────────────────────────────────────────

--- Fired when a callout is offered to the player.
function OnIsOfferedCallout(calloutData)
    DebugLog("OnIsOfferedCallout called")
    TriggerServerEvent('ErsIntegration::OnIsOfferedCallout', calloutData)
end

--- Fired when the player accepts a callout offer.
function OnAcceptedCalloutOffer(calloutData)
    DebugLog("OnAcceptedCalloutOffer called")
    TriggerServerEvent('ErsIntegration::OnAcceptedCalloutOffer', calloutData)
end

--- Fired when the player arrives at the callout (before entities spawn).
function OnArrivedAtCallout(calloutData)
    DebugLog("OnArrivedAtCallout called")
    TriggerServerEvent('ErsIntegration::OnArrivedAtCallout', calloutData)
end

--- Fired before entities are deleted or callout is cancelled.
function OnEndedACallout(calloutData)
    DebugLog("OnEndedACallout called")
    TriggerServerEvent('ErsIntegration::OnEndedACallout', calloutData)
end

--- Fired after the entire callout task list is completed.
function OnCalloutCompletedSuccesfully(calloutData)
    DebugLog("OnCalloutCompletedSuccesfully called")
    TriggerServerEvent('ErsIntegration::OnCalloutCompletedSuccesfully', calloutData)
end

-- ─── NPC & Vehicle Interactions ────────────────────────────────────────────────
-- ERS may fire these as server events directly OR as client callbacks depending
-- on version/context. We define both client functions (forwarding to server)
-- and server handlers to cover all cases.

--- Fired on the first interaction with an NPC (during callout, pullover, etc.).
function OnFirstNPCInteraction(pedData, context)
    DebugLog("OnFirstNPCInteraction called | context=" .. tostring(context))
    local loc = GetPlayerLocationData()
    TriggerServerEvent('ErsIntegration::OnFirstNPCInteraction', pedData, context, loc)
end

--- Fired on the first interaction with a vehicle (during callout, pullover, etc.).
function OnFirstVehicleInteraction(vehicleData, context)
    DebugLog("OnFirstVehicleInteraction called | context=" .. tostring(context))
    local loc = GetPlayerLocationData()
    TriggerServerEvent('ErsIntegration::OnFirstVehicleInteraction', vehicleData, context, loc)
end

-- ─── Traffic Stops ───────────────────────────────────────────────────────────

--- Fired when a traffic stop / pullover is initiated.
function OnPullover(pedData, vehicleData)
    print("[CDE-ERS] >>> OnPullover CALLED | pedData=" .. tostring(pedData ~= nil) .. " vehicleData=" .. tostring(vehicleData ~= nil))
    local loc = GetPlayerLocationData()
    TriggerServerEvent('ErsIntegration::OnPullover', pedData, vehicleData, loc)
end

--- Fired when a traffic stop / pullover ends.
function OnPulloverEnded(pedData, vehicleData)
    print("[CDE-ERS] >>> OnPulloverEnded CALLED")
    TriggerServerEvent('ErsIntegration::OnPulloverEnded', pedData, vehicleData)
end

-- ─── Pursuits ────────────────────────────────────────────────────────────────

--- Fired when a pursuit begins.
function OnPursuitStarted(pedData, vehicleData)
    print("[CDE-ERS] >>> OnPursuitStarted CALLED")
    TriggerServerEvent('ErsIntegration::OnPursuitStarted', pedData, vehicleData)
end

--- Fired when a pursuit ends.
function OnPursuitEnded(pedData)
    print("[CDE-ERS] >>> OnPursuitEnded CALLED")
    TriggerServerEvent('ErsIntegration::OnPursuitEnded', pedData)
end