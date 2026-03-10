Config = {}

-- ========================================
-- CAD BACKEND CONFIGURATION
-- ========================================
Config.CADEndpoint = "https://cdecad.com"  -- Your CAD backend URL (no trailing slash)
Config.APIKey      = ""                     -- Your community's FiveM API key (fvm_...)

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
-- TRAFFIC STOP SETTINGS
-- ========================================
-- Create civilian + vehicle records and a CAD call when initiating an ERS traffic stop
Config.CreateOnTrafficStop = true
