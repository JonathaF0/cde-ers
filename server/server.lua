-- server/main.lua
-- ERS Bridge for CDECAD — Server-side
-- Hooks into night_ers server events and pushes data to the CAD backend API.

local activeCallouts = {} -- Track active ERS callouts per player source
local pendingTrafficStopPed = {} -- Track ped data from pullover NPC interaction (for pairing with vehicle)
local pendingTrafficStopLoc = {} -- Track location data from pullover NPC interaction
local trafficStopHandled = {} -- Dedup: tracks whether a traffic stop was already sent for this player's current pullover

-- ─── Helper: Build headers for CAD API requests ────────────────────────────
local function GetHeaders()
    return {
        ["Content-Type"]  = "application/json",
        ["x-api-key"]     = Config.APIKey,
    }
end

-- ─── Helper: Build API URL ─────────────────────────────────────────────────
local function GetApiUrl(path)
    return Config.CADEndpoint .. "/api/fivem/ers/" .. path
end

-- ─── Helper: Debug logging ─────────────────────────────────────────────────
local function DebugLog(msg)
    if Config.EnableDebug then
        print("[CDE-ERS] " .. msg)
    end
end

-- ─── Helper: Base64 encode (for x-payload fallback) ────────────────────────
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64encode(data)
    return ((data:gsub('.', function(x)
        local r, b = '', x:byte()
        for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end
        return r
    end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
        return b64chars:sub(c + 1, c + 1)
    end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

-- ─── Helper: HTTP POST to CAD API ──────────────────────────────────────────
-- Sends the payload in both the body AND the x-payload header (base64).
-- This ensures delivery even when Cloudflare strips POST bodies from
-- non-browser user agents (FiveM's PerformHttpRequest).
local function PostToCAD(path, data, callback)
    local url = GetApiUrl(path)
    local jsonData = json.encode(data)

    DebugLog("POST " .. url .. " | Body: " .. jsonData)

    local headers = GetHeaders()
    headers["x-payload"] = base64encode(jsonData)

    PerformHttpRequest(url, function(statusCode, responseText, respHeaders)
        DebugLog("Response [" .. tostring(statusCode) .. "]: " .. tostring(responseText))

        if callback then
            local success = statusCode >= 200 and statusCode < 300
            local responseData = nil
            if responseText and responseText ~= "" then
                local ok, decoded = pcall(json.decode, responseText)
                if ok then responseData = decoded end
            end
            callback(success, responseData, statusCode)
        end
    end, "POST", jsonData, headers)
end

-- ─── Helper: Get callout ID from calloutData ───────────────────────────────
local function GetCalloutId(calloutData)
    if not calloutData then return nil end
    -- ERS provides various identifiers; check PascalCase first, then camelCase
    return calloutData.CalloutId
        or calloutData.calloutId
        or calloutData.Id
        or calloutData.id
        or calloutData.callout_id
        or (calloutData.CalloutName or calloutData.calloutType) and (tostring(calloutData.CalloutName or calloutData.calloutType) .. "_" .. tostring(os.time()))
end

-- ─── Helper: Get player callSign ───────────────────────────────────────────
local function GetPlayerCallSign(source)
    local name = GetPlayerName(source)
    return name or ("Unit-" .. tostring(source))
end

-- ─── Helper: Map ERS service type ──────────────────────────────────────────
local function GetServiceType(calloutData)
    if not calloutData then return "police" end

    -- Check explicit service type field first
    local sType = calloutData.ServiceType or calloutData.serviceType or calloutData.service_type
    if type(sType) == "string" then
        sType = sType:lower()
        if sType == "police" or sType == "fire" or sType == "ambulance" or sType == "tow" then
            return sType
        end
    end

    -- Derive from CalloutUnitsRequired (ERS sends this for callouts)
    local units = calloutData.CalloutUnitsRequired
    if units then
        if units.policeRequired then return "police" end
        if units.fireRequired then return "fire" end
        if units.ambulanceRequired then return "ambulance" end
        if units.towRequired then return "tow" end
    end

    return "police"
end

-- ─── Helper: Map ERS priority ──────────────────────────────────────────────
local function GetPriority(calloutData)
    if not calloutData then return "medium" end
    local p = calloutData.Priority or calloutData.priority
    if p == 1 then return "low"
    elseif p == 2 then return "normal"
    elseif p == 3 then return "medium"
    elseif p == 4 then return "high"
    elseif p == 5 then return "critical"
    end
    return "medium"
end

-- ========================================================================
-- ERS EVENT HANDLERS
-- ========================================================================

-- Register ALL ERS network events with RegisterNetEvent.
-- ERS c_functions.lua fires TriggerServerEvent for each of these.
-- Using RegisterNetEvent (not RegisterServerEvent) for consistency —
-- the callout events that WORK use RegisterNetEvent, so use it everywhere.
RegisterNetEvent("ErsIntegration::OnIsOfferedCallout")
RegisterNetEvent("ErsIntegration::OnAcceptedCalloutOffer")
RegisterNetEvent("ErsIntegration::OnArrivedAtCallout")
RegisterNetEvent("ErsIntegration::OnEndedACallout")
RegisterNetEvent("ErsIntegration::OnCalloutCompletedSuccesfully")
RegisterNetEvent("ErsIntegration::OnFirstNPCInteraction")
RegisterNetEvent("ErsIntegration::OnFirstVehicleInteraction")
RegisterNetEvent("ErsIntegration::OnToggleShift")
RegisterNetEvent("ErsIntegration::OnPullover")
RegisterNetEvent("ErsIntegration::OnPulloverEnded")
RegisterNetEvent("ErsIntegration::OnPursuitStarted")
RegisterNetEvent("ErsIntegration::OnPursuitEnded")

-- ─── OnAcceptedCalloutOffer ─────────────────────────────────────────────────
-- Fired when a player accepts an ERS callout offer.
AddEventHandler("ErsIntegration::OnAcceptedCalloutOffer", function(calloutData)
    local source = source
    DebugLog("OnAcceptedCalloutOffer RAW: " .. json.encode(calloutData or {}))

    local calloutId = GetCalloutId(calloutData)

    if not calloutId then
        DebugLog("OnAcceptedCalloutOffer: No callout ID found, skipping")
        return
    end

    -- Track the active callout for this player
    activeCallouts[tostring(source)] = calloutId
    DebugLog("Player " .. tostring(source) .. " accepted callout: " .. calloutId)

    -- Create CAD call
    if Config.CreateCallOnAccept then
        -- ERS uses PascalCase field names (CalloutName, Description, Coordinates, StreetName, etc.)
        local callType = calloutData.CalloutName or calloutData.calloutName or calloutData.calloutType or calloutData.type or "ERS Callout"
        local location = calloutData.StreetName or calloutData.Location or calloutData.location or calloutData.Address or calloutData.address or "Unknown"
        local postal   = calloutData.Postal or calloutData.postal or calloutData.PostalCode or ""

        -- Get coordinates from the callout data (ERS uses PascalCase "Coordinates")
        local coords = nil
        if calloutData.Coordinates then
            coords = calloutData.Coordinates
        elseif calloutData.coordinates then
            coords = calloutData.coordinates
        elseif calloutData.x and calloutData.y then
            coords = { x = calloutData.x, y = calloutData.y, z = calloutData.z or 0.0 }
        end

        PostToCAD("callout", {
            ersCalloutId = calloutId,
            callType     = callType,
            location     = location,
            postal       = postal,
            coordinates  = coords,
            description  = calloutData.Description or calloutData.description or calloutData.desc or "",
            priority     = GetPriority(calloutData),
            serviceType  = GetServiceType(calloutData),
        }, function(success, data)
            if success and data then
                DebugLog("Created CAD call: " .. tostring(data.incidentNumber))

                -- Auto-attach the accepting unit
                if Config.AttachUnitOnAccept then
                    PostToCAD("unit-attach", {
                        ersCalloutId = calloutId,
                        callSign     = GetPlayerCallSign(source),
                    })
                end

                -- NOTE: calloutData.FirstName/LastName is the 911 CALLER, not the
                -- suspect. Actual suspect NPCs arrive via OnFirstNPCInteraction
                -- (which requires forwarding code in night_ers/c_functions.lua).
                -- We skip auto-creating the caller as a civilian since it's not
                -- the person officers need to run in the system.
                if calloutData.FirstName and calloutData.LastName then
                    DebugLog("Callout caller: " .. calloutData.FirstName .. " " .. calloutData.LastName .. " (not creating as civilian — this is the 911 caller)")
                end
            end
        end)
    end
end)

-- ─── OnArrivedAtCallout ─────────────────────────────────────────────────────
-- Fired when a player arrives at the callout scene.
AddEventHandler("ErsIntegration::OnArrivedAtCallout", function(calloutData)
    local source = source
    DebugLog("OnArrivedAtCallout RAW: " .. json.encode(calloutData or {}))

    if not Config.UpdateOnArrival then return end

    local calloutId = activeCallouts[tostring(source)] or GetCalloutId(calloutData)
    if not calloutId then return end

    DebugLog("Player " .. tostring(source) .. " arrived at callout: " .. calloutId)

    PostToCAD("callout-arrived", {
        ersCalloutId = calloutId,
    })
end)

-- ─── OnEndedACallout ────────────────────────────────────────────────────────
-- Fired when an ERS callout ends (completed or abandoned).
AddEventHandler("ErsIntegration::OnEndedACallout", function(calloutData)
    local source = source
    DebugLog("OnEndedACallout RAW: " .. json.encode(calloutData or {}))

    if not Config.CloseCallOnEnd then return end

    local calloutId = activeCallouts[tostring(source)] or GetCalloutId(calloutData)
    if not calloutId then return end

    DebugLog("Callout ended: " .. calloutId)

    PostToCAD("callout-end", {
        ersCalloutId = calloutId,
    })

    -- Clean up tracking
    activeCallouts[tostring(source)] = nil
end)

-- ─── OnCalloutCompletedSuccesfully ──────────────────────────────────────────
-- Fired when an ERS callout is completed successfully.
AddEventHandler("ErsIntegration::OnCalloutCompletedSuccesfully", function(calloutData)
    local source = source
    DebugLog("OnCalloutCompletedSuccesfully RAW: " .. json.encode(calloutData or {}))
    local calloutId = activeCallouts[tostring(source)] or GetCalloutId(calloutData)
    if not calloutId then return end

    DebugLog("Callout completed successfully: " .. calloutId)

    if Config.CloseCallOnEnd then
        PostToCAD("callout-end", {
            ersCalloutId = calloutId,
        })
    end

    activeCallouts[tostring(source)] = nil
end)

-- ─── Helper: Build traffic stop payload and POST to CAD ──────────────────
-- Defined here (before event handlers that reference it) because Lua
-- ─── Helper: Get location data for a player ───────────────────────────────
-- Server-side coords are always available. Street name comes from client callback.
local pendingLocationCallbacks = {}

local function GetPlayerLocation(playerSource, callback)
    -- Get server-side coordinates immediately
    local coords = nil
    local playerPed = GetPlayerPed(playerSource)
    if playerPed and playerPed ~= 0 then
        local pos = GetEntityCoords(playerPed)
        if pos then
            coords = { x = pos.x, y = pos.y, z = pos.z }
        end
    end

    -- Request street name from client
    local key = tostring(playerSource)
    pendingLocationCallbacks[key] = function(clientLoc)
        pendingLocationCallbacks[key] = nil
        local loc = clientLoc or {}
        if not loc.coordinates and coords then
            loc.coordinates = coords
        end
        callback(loc)
    end

    TriggerClientEvent('ErsIntegration::RequestLocation', playerSource)

    -- Fallback: if client doesn't respond within 2 seconds, use coords only
    SetTimeout(2000, function()
        if pendingLocationCallbacks[key] then
            DebugLog("Location callback timeout for player " .. key .. ", using server coords only")
            pendingLocationCallbacks[key] = nil
            callback({ coordinates = coords })
        end
    end)
end

RegisterNetEvent('ErsIntegration::LocationResponse')
AddEventHandler('ErsIntegration::LocationResponse', function(locationData)
    local key = tostring(source)
    if pendingLocationCallbacks[key] then
        pendingLocationCallbacks[key](locationData)
    end
end)

-- ─── SendTrafficStop ──────────────────────────────────────────────────────
-- Builds and sends the traffic stop payload to the CAD API.
-- NOTE: This function must be defined before HandleTrafficStop below.
local function SendTrafficStop(source, pedData, vehicleData, locationData)
    local loc = locationData or {}

    local firstName = "Unknown"
    local lastName  = "Driver"
    local dob       = nil
    local gender    = nil
    local driverStatus  = nil
    local firearmStatus = nil
    local civId     = nil
    local pedId     = nil

    local race       = nil
    local hairColor  = nil
    local eyeColor   = nil
    local height     = nil
    local weight     = nil
    local address    = nil
    local phone      = nil
    local occupation = nil
    local middleName = nil

    -- ERS license status mapping
    local licenseMap = {
        ["VALID"]                         = "VALID",
        ["INTERNATIONAL LICENSE (VALID)"] = "VALID",
        ["REPORTED STOLEN (VALID)"]       = "REVOKED",
        ["EXPIRED"]                       = "EXPIRED",
        ["SUSPENDED"]                     = "SUSPENDED",
        ["REVOKED"]                       = "REVOKED",
        ["NO LICENSE"]                    = "NONE",
        ["NONE"]                          = "NONE",
        ["N/A"]                           = "NONE",
        [""]                              = "NONE",
    }

    if pedData then
        -- ERS confirmed fields: FirstName, LastName, DOB, Gender, Nationality,
        -- License_Car, License_Car_Is_Valid, License_Truck, License_Truck_Is_Valid,
        -- License_Boat_Is_Valid, PostalCode, Address, City, State, PhoneNumber
        firstName    = pedData.FirstName or "Unknown"
        lastName     = pedData.LastName or "Driver"
        middleName   = pedData.MiddleName or nil
        dob          = pedData.DOB or nil
        gender       = pedData.Gender or nil
        race         = pedData.Nationality or nil
        address      = pedData.Address or nil
        phone        = pedData.PhoneNumber or nil
        civId        = pedData.civId or pedData.id or nil
        pedId        = pedData.pedId or pedData.ped_id or nil

        -- Map license status from ERS string
        if pedData.License_Car then
            driverStatus = licenseMap[string.upper(pedData.License_Car)] or pedData.License_Car
        elseif pedData.License_Car_Is_Valid then
            driverStatus = "VALID"
        end
    end

    local plate = nil
    local make  = nil
    local model = nil
    local color = nil
    local year  = nil
    local stolen = false
    local ownerName = nil
    local boloDesc  = nil
    local insurance = nil
    local registration = nil

    if vehicleData then
        -- ERS confirmed fields: license_plate, make, model, color, build_year,
        -- stolen, owner_name, insurance, tax, bolo_description, registration_date
        plate        = vehicleData.license_plate or ("ERS" .. math.random(1000, 9999))
        make         = vehicleData.make or "Unknown"
        model        = vehicleData.model or "Unknown"
        color        = vehicleData.color or "Unknown"
        year         = vehicleData.build_year or 2024
        stolen       = vehicleData.stolen or false
        ownerName    = vehicleData.owner_name or nil
        boloDesc     = vehicleData.bolo_description or nil
        insurance    = vehicleData.insurance or nil
        registration = vehicleData.tax or nil
    end

    -- Location from client
    local loc = locationData or {}

    PostToCAD("traffic-stop", {
        -- Officer
        callSign    = GetPlayerCallSign(source),
        -- Location
        location    = loc.location or nil,
        postal      = loc.postal or nil,
        coordinates = loc.coordinates or nil,
        -- Civilian
        firstName            = firstName,
        middleName           = middleName,
        lastName             = lastName,
        dateOfBirth          = dob,
        gender               = gender,
        race                 = race,
        address              = address,
        phone                = phone,
        driversLicenseStatus = driverStatus,
        civId                = civId,
        pedId                = pedId,
        -- Vehicle
        plate        = plate,
        make         = make,
        model        = model,
        color        = color,
        year         = year,
        stolen       = stolen,
        ownerName    = ownerName,
        boloDescription = boloDesc,
        insurance    = insurance,
        registration = registration,
    }, function(success, data)
        if success and data then
            DebugLog("Traffic stop processed: " .. tostring(data.incidentNumber or "?") ..
                " | Civ: " .. tostring(data.civilianId or "?") ..
                " | Veh: " .. tostring(data.vehicleId or "?"))
        else
            DebugLog("Traffic stop failed")
        end
    end)
end

-- ─── HandleTrafficStop ────────────────────────────────────────────────────
-- Wrapper that resolves player location before sending.
-- If location data was provided (e.g. from client), uses it directly.
-- Otherwise, requests street name from client with server-side coord fallback.
local function HandleTrafficStop(playerSource, pedData, vehicleData, locationData)
    DebugLog("Processing traffic stop for player " .. tostring(playerSource))

    if locationData and locationData.location then
        SendTrafficStop(playerSource, pedData, vehicleData, locationData)
    else
        GetPlayerLocation(playerSource, function(loc)
            SendTrafficStop(playerSource, pedData, vehicleData, loc)
        end)
    end
end

-- ─── OnFirstNPCInteraction ──────────────────────────────────────────────────
-- ERS fires this as a global client function with context values:
--   "on_interaction", "on_aiming_at_ped", "on_pullover", "on_pursuit_start",
--   "on_pursuit_end", "on_pullover_end"
-- This is the PRIMARY way pullover/pursuit NPC data reaches us, since ERS
-- does NOT fire OnPullover as a global function (it's internal to c_functions.lua).
--
-- ERS may fire this EITHER:
--   a) Directly on server: TriggerEvent(..., source, pedData, context)  → src=number
--   b) Via client callback: TriggerServerEvent(..., pedData, context)   → src=table
AddEventHandler("ErsIntegration::OnFirstNPCInteraction", function(srcOrPed, pedDataOrCtx, contextOrNil, locOrNil)
    local playerSource, pedData, context, locationData

    if type(srcOrPed) == "number" then
        -- Server-side direct call: TriggerEvent(event, source, pedData, context, loc)
        playerSource = srcOrPed
        pedData      = pedDataOrCtx
        context      = contextOrNil
        locationData = locOrNil
    else
        -- Client callback: TriggerServerEvent(event, pedData, context, loc)
        -- args map to: srcOrPed=pedData, pedDataOrCtx=context, contextOrNil=loc
        playerSource = source
        pedData      = srcOrPed
        context      = pedDataOrCtx
        locationData = contextOrNil
    end

    -- Always log NPC interactions (not debug-gated) so we can diagnose pullover issues
    print("[CDE-ERS] OnFirstNPCInteraction source=" .. tostring(playerSource) .. " context=" .. tostring(context) .. " pedName=" .. tostring(pedData and (pedData.FirstName .. " " .. pedData.LastName) or "nil"))

    if not pedData then return end

    local calloutId = activeCallouts[tostring(playerSource)]
    local ctx = context and tostring(context):lower() or ""

    -- Detect pullover/pursuit contexts from ERS
    local isPullover = (ctx == "on_pullover")
    local isPursuit  = (ctx == "on_pursuit_start")

    DebugLog("NPC interaction | Context: " .. tostring(context) .. " | Callout: " .. tostring(calloutId or "none") .. " | isPullover: " .. tostring(isPullover) .. " | isPursuit: " .. tostring(isPursuit))

    -- ── Pullover or Pursuit context (outside callout) → traffic-stop endpoint ──
    if (isPullover or isPursuit) and Config.CreateOnTrafficStop then
        DebugLog("Pullover/pursuit NPC detected via context, storing ped data and waiting for vehicle")
        local key = tostring(playerSource)
        -- Store ped data and location for pairing with vehicle data from OnFirstVehicleInteraction
        pendingTrafficStopPed[key] = pedData
        pendingTrafficStopLoc[key] = locationData
        trafficStopHandled[key] = false
        -- Fallback: if vehicle data never arrives within 3 seconds, send ped-only stop
        SetTimeout(3000, function()
            if not trafficStopHandled[key] then
                DebugLog("Fallback: no vehicle data arrived, sending ped-only traffic stop")
                trafficStopHandled[key] = true
                local savedLoc = pendingTrafficStopLoc[key]
                pendingTrafficStopPed[key] = nil
                pendingTrafficStopLoc[key] = nil
                HandleTrafficStop(playerSource, pedData, nil, savedLoc)
            end
        end)
        return
    end

    -- ── During a callout → create civilian linked to the callout ──
    if calloutId and Config.CreateCivilians then
        local licenseMap = {
            ["VALID"] = "VALID", ["INTERNATIONAL LICENSE (VALID)"] = "VALID",
            ["REPORTED STOLEN (VALID)"] = "REVOKED", ["EXPIRED"] = "EXPIRED",
            ["SUSPENDED"] = "SUSPENDED", ["REVOKED"] = "REVOKED",
            ["NONE"] = "NONE", ["N/A"] = "NONE", [""] = "NONE",
        }
        local driverLicStatus = pedData.License_Car and licenseMap[string.upper(pedData.License_Car)] or nil

        PostToCAD("civilian", {
            ersCalloutId     = calloutId,
            firstName        = pedData.FirstName or "Unknown",
            lastName         = pedData.LastName or "Doe",
            dateOfBirth      = pedData.DOB or nil,
            gender           = pedData.Gender or nil,
            race             = pedData.Nationality or nil,
            address          = pedData.Address or nil,
            city             = pedData.City or nil,
            state            = pedData.State or nil,
            postalCode       = pedData.PostalCode or nil,
            phone            = pedData.PhoneNumber or nil,
            hasDriversLicense = pedData.License_Car_Is_Valid or false,
            hasFirearmsLicense = false,
            driversLicenseStatus  = driverLicStatus,
            civId = pedData.civId or pedData.id or nil,
            pedId = pedData.pedId or pedData.ped_id or nil,
        }, function(success, data)
            if success and data then
                DebugLog("Created civilian: " .. tostring(data.fullName) .. " (ID: " .. tostring(data._id) .. ")")
            else
                DebugLog("Failed to create civilian: " .. json.encode(data or {}))
            end
        end)
    elseif not calloutId and not (ctx == "on_pullover_end" or ctx == "on_pursuit_end") and Config.CreateOnTrafficStop then
        -- Generic NPC interaction outside callout (ID check, etc.)
        DebugLog("NPC interaction outside callout, creating via traffic-stop endpoint")
        HandleTrafficStop(playerSource, pedData, nil, locationData)
    else
        DebugLog("NPC interaction skipped (no callout and traffic stop creation disabled)")
    end
end)

-- ─── OnFirstVehicleInteraction ──────────────────────────────────────────────
-- ERS fires this with context "on_pullover", "on_pursuit_start", etc.
-- For pullover/pursuit, the NPC data was already sent via OnFirstNPCInteraction;
-- this adds the vehicle data to the existing traffic stop.
AddEventHandler("ErsIntegration::OnFirstVehicleInteraction", function(srcOrVeh, vehDataOrCtx, contextOrNil, locOrNil)
    local playerSource, vehicleData, context, locationData

    if type(srcOrVeh) == "number" then
        playerSource = srcOrVeh
        vehicleData  = vehDataOrCtx
        context      = contextOrNil
        locationData = locOrNil
    else
        -- Client: TriggerServerEvent(event, vehicleData, context, loc)
        playerSource = source
        vehicleData  = srcOrVeh
        context      = vehDataOrCtx
        locationData = contextOrNil
    end

    print("[CDE-ERS] OnFirstVehicleInteraction source=" .. tostring(playerSource) .. " context=" .. tostring(context) .. " plate=" .. tostring(vehicleData and vehicleData.license_plate or "nil"))

    if not vehicleData then return end

    local ctx = context and tostring(context):lower() or ""
    local isPullover = (ctx == "on_pullover")
    local isPursuit  = (ctx == "on_pursuit_start")
    local calloutId = activeCallouts[tostring(playerSource)]

    -- ── Pullover/pursuit vehicle → send the SINGLE traffic stop with ped + vehicle data ──
    if (isPullover or isPursuit) and Config.CreateOnTrafficStop then
        local key = tostring(playerSource)
        local savedPed = pendingTrafficStopPed[key]
        local savedLoc = pendingTrafficStopLoc[key] or locationData
        pendingTrafficStopPed[key] = nil -- clean up
        pendingTrafficStopLoc[key] = nil
        if trafficStopHandled[key] then
            DebugLog("Pullover/pursuit vehicle arrived but traffic stop already sent, skipping")
            return
        end
        trafficStopHandled[key] = true
        DebugLog("Pullover/pursuit vehicle detected, creating traffic stop with ped + vehicle data")
        HandleTrafficStop(playerSource, savedPed, vehicleData, savedLoc)
        return
    end

    -- ── During a callout → create vehicle linked to the callout ──
    if not Config.CreateVehicles then return end
    if not calloutId then
        DebugLog("Vehicle interaction outside callout, skipping vehicle creation")
        return
    end

    DebugLog("Vehicle interaction during callout " .. calloutId .. " | Context: " .. tostring(context))

    PostToCAD("vehicle", {
        ersCalloutId = calloutId,
        plate        = vehicleData.license_plate or vehicleData.plate or ("ERS" .. math.random(1000, 9999)),
        make         = vehicleData.make or "Unknown",
        model        = vehicleData.model or "Unknown",
        color        = vehicleData.color or "Unknown",
        year         = vehicleData.build_year or vehicleData.year or 2024,
        stolen       = vehicleData.stolen or false,
        ownerName    = vehicleData.owner_name or nil,
    })
end)

-- ─── OnPullover (ERS native event) ───────────────────────────────────────
-- Fired by night_ers c_functions.lua via TriggerServerEvent when a
-- player initiates a traffic stop / pullover.
AddEventHandler("ErsIntegration::OnPullover", function(pedData, vehicleData, locationData)
    local src = source
    -- Always log (not debug-gated) so we can confirm the event fires
    print("[CDE-ERS] >>> OnPullover EVENT RECEIVED | src=" .. tostring(src) ..
        " | ped=" .. tostring(pedData and pedData.FirstName or "nil") ..
        " | veh=" .. tostring(vehicleData and vehicleData.license_plate or "nil"))
    if not Config.CreateOnTrafficStop then return end
    local key = tostring(src)
    -- Skip if already handled by OnFirstNPCInteraction + OnFirstVehicleInteraction
    if trafficStopHandled[key] then
        DebugLog("OnPullover skipped — traffic stop already created via NPC/Vehicle interaction events")
        return
    end
    trafficStopHandled[key] = true
    pendingTrafficStopPed[key] = nil -- clean up any pending data
    pendingTrafficStopLoc[key] = nil
    HandleTrafficStop(src, pedData, vehicleData, locationData)
end)

-- ─── OnPursuitStarted ───────────────────────────────────────────────────────
-- Fired when an ERS pursuit begins.
AddEventHandler("ErsIntegration::OnPursuitStarted", function(pedData, vehicleData)
    local source = source
    DebugLog("OnPursuitStarted RAW pedData=" .. json.encode(pedData or {}) .. " vehicleData=" .. json.encode(vehicleData or {}))

    local calloutId = activeCallouts[tostring(source)]
    if not calloutId then return end

    DebugLog("Pursuit started during callout " .. calloutId)

    if Config.CreateCivilians and pedData then
        local firstName = pedData.FirstName or pedData.firstName or pedData.first_name or "Unknown"
        local lastName  = pedData.LastName or pedData.lastName or pedData.last_name or "Doe"

        PostToCAD("civilian", {
            ersCalloutId     = calloutId,
            firstName        = firstName,
            lastName         = lastName,
            dateOfBirth      = pedData.DOB or pedData.dateOfBirth or pedData.dob or nil,
            gender           = pedData.Gender or pedData.gender or pedData.sex or nil,
            hasDriversLicense = pedData.License_Car_Is_Valid or pedData.hasDriversLicense or false,
            hasFirearmsLicense = pedData.hasFirearmsLicense or false,
            driversLicenseStatus  = pedData.License_Car or pedData.driversLicenseStatus or nil,
            firearmsLicenseStatus = pedData.firearmsLicenseStatus or nil,
            civId = pedData.civId or pedData.id or nil,
            pedId = pedData.pedId or pedData.ped_id or nil,
        })
    end

    if Config.CreateVehicles and vehicleData then
        PostToCAD("vehicle", {
            ersCalloutId = calloutId,
            plate        = vehicleData.license_plate or vehicleData.plate or vehicleData.licensePlate or ("ERS" .. math.random(1000, 9999)),
            make         = vehicleData.make or vehicleData.brand or "Unknown",
            model        = vehicleData.model or "Unknown",
            color        = vehicleData.color or vehicleData.colour or "Unknown",
            year         = vehicleData.build_year or vehicleData.year or 2024,
            stolen       = vehicleData.stolen or vehicleData.isStolen or false,
        })
    end
end)

-- ─── OnPulloverEnded / OnPursuitEnded — reset dedup flag ─────────────────────
AddEventHandler("ErsIntegration::OnPulloverEnded", function(pedData, vehicleData)
    local key = tostring(source)
    DebugLog("Pullover ended for player " .. key .. ", resetting dedup flag")
    trafficStopHandled[key] = nil
    pendingTrafficStopPed[key] = nil
    pendingTrafficStopLoc[key] = nil
end)

AddEventHandler("ErsIntegration::OnPursuitEnded", function(pedData)
    local key = tostring(source)
    DebugLog("Pursuit ended for player " .. key .. ", resetting dedup flag")
    trafficStopHandled[key] = nil
    pendingTrafficStopPed[key] = nil
    pendingTrafficStopLoc[key] = nil
end)

-- ─── Player Disconnect Cleanup ──────────────────────────────────────────────
AddEventHandler("playerDropped", function()
    local source = source
    activeCallouts[tostring(source)] = nil
    pendingTrafficStopPed[tostring(source)] = nil
    pendingTrafficStopLoc[tostring(source)] = nil
    trafficStopHandled[tostring(source)] = nil
end)

-- ========================================================================
-- SERVER CONSOLE TEST COMMANDS
-- ========================================================================

-- ─── ers_test ───────────────────────────────────────────────────────────────
-- Tests connectivity to the CAD backend API.
-- Usage: ers_test
RegisterCommand("ers_test", function(source, args)
    print("[CDE-ERS] ─── Running Connection Test ───")
    print("[CDE-ERS] Endpoint: " .. Config.CADEndpoint)
    print("[CDE-ERS] API Key:  " .. (Config.APIKey ~= "" and (string.sub(Config.APIKey, 1, 8) .. "...") or "NOT SET"))

    if Config.APIKey == "" then
        print("[CDE-ERS] ERROR: No API key configured. Set Config.APIKey in config.lua")
        return
    end

    -- Test 1: Create a test callout
    local testId = "ERS_TEST_" .. tostring(os.time())
    print("[CDE-ERS] [1/4] Creating test callout (" .. testId .. ")...")

    PostToCAD("callout", {
        ersCalloutId = testId,
        callType     = "ERS Test Callout",
        location     = "Test Location - Del Perro Pier",
        postal       = "102",
        coordinates  = { x = -1648.0, y = -1100.0, z = 13.0 },
        description  = "Automated test from cde-ers resource",
        priority     = "low",
        serviceType  = "police",
    }, function(success, data, statusCode)
        if not success then
            print("[CDE-ERS] [1/4] FAIL - Callout creation failed (HTTP " .. tostring(statusCode) .. ")")
            if data and data.msg then print("[CDE-ERS]        " .. data.msg) end
            return
        end
        print("[CDE-ERS] [1/4] OK - Call created: " .. tostring(data.incidentNumber or "?"))

        -- Test 2: Create a test civilian
        print("[CDE-ERS] [2/4] Creating test civilian...")
        PostToCAD("civilian", {
            ersCalloutId     = testId,
            firstName        = "Test",
            lastName         = "Subject",
            dateOfBirth      = "1990-01-15",
            gender           = "male",
            hasDriversLicense = true,
            hasFirearmsLicense = false,
        }, function(civSuccess, civData, civStatus)
            if not civSuccess then
                print("[CDE-ERS] [2/4] FAIL - Civilian creation failed (HTTP " .. tostring(civStatus) .. ")")
                if civData and civData.msg then print("[CDE-ERS]        " .. civData.msg) end
            else
                print("[CDE-ERS] [2/4] OK - Civilian created: " .. tostring(civData.fullName or "?"))
            end

            -- Test 3: Create a test vehicle
            print("[CDE-ERS] [3/4] Creating test vehicle...")
            PostToCAD("vehicle", {
                ersCalloutId = testId,
                plate        = "ERST" .. math.random(100, 999),
                make         = "Vapid",
                model        = "Stanier",
                color        = "Black",
                year         = 2024,
                stolen       = false,
            }, function(vehSuccess, vehData, vehStatus)
                if not vehSuccess then
                    print("[CDE-ERS] [3/4] FAIL - Vehicle creation failed (HTTP " .. tostring(vehStatus) .. ")")
                    if vehData and vehData.msg then print("[CDE-ERS]        " .. vehData.msg) end
                else
                    print("[CDE-ERS] [3/4] OK - Vehicle created: " .. tostring(vehData.plate or "?"))
                end

                -- Test 4: Close the test callout
                print("[CDE-ERS] [4/4] Closing test callout...")
                PostToCAD("callout-end", {
                    ersCalloutId = testId,
                }, function(endSuccess, endData, endStatus)
                    if not endSuccess then
                        print("[CDE-ERS] [4/4] FAIL - Callout close failed (HTTP " .. tostring(endStatus) .. ")")
                        if endData and endData.msg then print("[CDE-ERS]        " .. endData.msg) end
                    else
                        print("[CDE-ERS] [4/4] OK - Call closed: " .. tostring(endData.incidentNumber or "?"))
                    end

                    print("[CDE-ERS] ─── Test Complete ───")
                end)
            end)
        end)
    end)
end, true) -- true = restricted to server console only

-- ─── ers_status ─────────────────────────────────────────────────────────────
-- Shows current ERS bridge status and active callouts.
-- Usage: ers_status
RegisterCommand("ers_status", function(source, args)
    print("[CDE-ERS] ─── Bridge Status ───")
    print("[CDE-ERS] Endpoint:        " .. Config.CADEndpoint)
    print("[CDE-ERS] API Key:         " .. (Config.APIKey ~= "" and (string.sub(Config.APIKey, 1, 8) .. "...") or "NOT SET"))
    print("[CDE-ERS] Debug:           " .. tostring(Config.EnableDebug))
    print("[CDE-ERS] Create Calls:    " .. tostring(Config.CreateCallOnAccept))
    print("[CDE-ERS] Close on End:    " .. tostring(Config.CloseCallOnEnd))
    print("[CDE-ERS] Attach Units:    " .. tostring(Config.AttachUnitOnAccept))
    print("[CDE-ERS] Update Arrival:  " .. tostring(Config.UpdateOnArrival))
    print("[CDE-ERS] Create Civs:     " .. tostring(Config.CreateCivilians))
    print("[CDE-ERS] Create Vehicles: " .. tostring(Config.CreateVehicles))
    print("[CDE-ERS] Traffic Stops:  " .. tostring(Config.CreateOnTrafficStop))

    local count = 0
    for k, v in pairs(activeCallouts) do
        count = count + 1
    end
    print("[CDE-ERS] Active Callouts: " .. tostring(count))
    if count > 0 then
        for playerSrc, calloutId in pairs(activeCallouts) do
            local name = GetPlayerName(tonumber(playerSrc)) or "Unknown"
            print("[CDE-ERS]   Player " .. playerSrc .. " (" .. name .. ") -> " .. calloutId)
        end
    end
    print("[CDE-ERS] ────────────────────")
end, true)

-- ─── ers_debug ──────────────────────────────────────────────────────────────
-- Toggles debug logging on/off at runtime.
-- Usage: ers_debug
RegisterCommand("ers_debug", function(source, args)
    Config.EnableDebug = not Config.EnableDebug
    print("[CDE-ERS] Debug mode: " .. (Config.EnableDebug and "ON" or "OFF"))
end, true)

-- ─── ers_test_traffic ──────────────────────────────────────────────────────
-- Sends a test traffic stop to the CAD to verify the /ers/traffic-stop
-- endpoint is reachable and working.
-- Usage: ers_test_traffic
RegisterCommand("ers_test_traffic", function(source, args)
    print("[CDE-ERS] ─── Running Traffic Stop Test ───")
    print("[CDE-ERS] Endpoint: " .. Config.CADEndpoint)

    if Config.APIKey == "" then
        print("[CDE-ERS] ERROR: No API key configured. Set Config.APIKey in config.lua")
        return
    end

    local testPlate = "TST" .. math.random(1000, 9999)

    print("[CDE-ERS] Sending test traffic stop (plate: " .. testPlate .. ")...")

    PostToCAD("traffic-stop", {
        -- Officer
        callSign             = "TEST-1",
        -- Civilian
        firstName            = "Test",
        lastName             = "Driver",
        dateOfBirth          = "1985-06-20",
        gender               = "male",
        driversLicenseStatus = "Valid",
        firearmsLicenseStatus = nil,
        civId                = nil,
        pedId                = nil,
        -- Vehicle
        plate  = testPlate,
        make   = "Vapid",
        model  = "Stanier",
        color  = "White",
        year   = 2024,
        stolen = false,
    }, function(success, data, statusCode)
        if not success then
            print("[CDE-ERS] FAIL - Traffic stop creation failed (HTTP " .. tostring(statusCode) .. ")")
            if data and data.msg then print("[CDE-ERS]        " .. data.msg) end
        else
            print("[CDE-ERS] OK - Traffic stop processed")
            print("[CDE-ERS]   Incident: " .. tostring(data.incidentNumber or "?"))
            print("[CDE-ERS]   Civilian: " .. tostring(data.civilianId or "?"))
            print("[CDE-ERS]   Vehicle:  " .. tostring(data.vehicleId or "?"))
        end
        print("[CDE-ERS] ─── Traffic Stop Test Complete ───")
    end)
end, true)

-- ─── Catch-all: log ALL ErsIntegration events for diagnostics ────────────
-- This helps diagnose which events ERS actually fires vs which we expect.
for _, evtName in ipairs({
    "OnToggleShift", "OnIsOfferedCallout", "OnAcceptedCalloutOffer",
    "OnArrivedAtCallout", "OnEndedACallout", "OnCalloutCompletedSuccesfully",
    "OnFirstNPCInteraction", "OnFirstVehicleInteraction",
    "OnPullover", "OnPulloverEnded", "OnPursuitStarted", "OnPursuitEnded"
}) do
    AddEventHandler("ErsIntegration::" .. evtName, function(...)
        print("[CDE-ERS] EVENT >> " .. evtName .. " (source=" .. tostring(source) .. ")")
    end)
end

-- ─── Startup ────────────────────────────────────────────────────────────────
print("[CDE-ERS] ERS Bridge for CDECAD loaded successfully")
print("[CDE-ERS] Console commands: ers_test | ers_test_traffic | ers_status | ers_debug")
if Config.APIKey == "" then
    print("[CDE-ERS] WARNING: No API key configured! Set Config.APIKey in config.lua")
end