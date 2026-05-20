Config = {}

-- ========================================
-- ERS INTEGRATION SETTINGS
-- ========================================
-- These can also be toggled from the CAD admin panel (FiveM Settings).
-- Server-side checks are enforced regardless of these client settings.

Config.EnableDebug = false  -- Enable verbose debug logging in server console

-- ========================================
-- CALLOUT SETTINGS
-- ========================================
-- Automatically create a 911 call in the CAD when a player accepts an ERS callout
Config.CreateCallOnAccept = true

-- Automatically close the CAD call when the ERS callout ends
Config.CloseCallOnEnd = true

-- Automatically attach the accepting unit to the CAD call
Config.AttachUnitOnAccept = true

-- Update call status to on-scene when player arrives at callout
Config.UpdateOnArrival = true

-- ========================================
-- CIVILIAN / VEHICLE SETTINGS
-- ========================================
-- Create civilian records in CAD when interacting with ERS NPCs
-- NOTE: Only NPCs that are part of an active callout will be created
Config.CreateCivilians = true

-- Create vehicle records in CAD when interacting with ERS vehicles
Config.CreateVehicles = true

-- ========================================
-- DISPATCH CALLOUT SETTINGS
-- ========================================
-- Allow dispatchers to create ERS callouts from the CAD livemap.
-- When enabled, this resource polls the CAD for dispatch-created callouts
-- and triggers them in-game via the night_ers exports.
Config.EnableDispatchCallouts = true

-- How often (in seconds) to poll the CAD for new dispatch callouts.
-- The in-game callout is triggered immediately via the client event, so
-- this polling is only a fallback. 30s keeps API usage low.
Config.DispatchPollInterval = 30

-- ========================================
-- TRAFFIC STOP SETTINGS
-- ========================================
-- Create civilian + vehicle records and a CAD call when initiating an ERS traffic stop
Config.CreateOnTrafficStop = true

-- ========================================
-- DUTY / SHIFT SYNC
-- ========================================
-- When a player toggles their ERS shift on/off, mirror that to the CAD by
-- setting their unit status to 10-8 (on) or 10-42 (off). The CAD enforces
-- this as well via the "Auto On-Duty" toggle in FiveM Settings; both must be
-- enabled for the sync to fire.
Config.ToggleDutyOnShift = true
