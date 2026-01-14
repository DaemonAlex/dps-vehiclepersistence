--[[
    dps-vehiclepersistence Configuration
    Framework: QB/QBX/ESX
]]

Config = {}

-- Master enable/disable toggle
Config.Enabled = true
Config.Debug = false

-- ═══════════════════════════════════════════════════════
-- ADMIN SETTINGS
-- ═══════════════════════════════════════════════════════

Config.AdminExempt = true  -- Staff vehicles don't persist (good for testing)
Config.StaffGroups = {
    'admin', 'god', 'superadmin', 'mod', 'moderator',
    'helper', 'staff', 'support', 'dev', 'developer'
}

-- ═══════════════════════════════════════════════════════
-- PERSISTENCE SETTINGS
-- ═══════════════════════════════════════════════════════

-- How long vehicles persist after owner disconnects (minutes)
-- 0 = infinite until restart/towed
Config.VehicleTimeout = 0

-- Persist through server restarts
Config.PersistThroughRestart = true

-- Max vehicles per player in the world
Config.MaxVehiclesPerPlayer = 5

-- Min time stationary before saving (seconds)
Config.MinStationaryTime = 30

-- Spawn delay between vehicles on restart (ms)
Config.SpawnDelay = 500

-- ═══════════════════════════════════════════════════════
-- GARAGE PROXIMITY (Optional)
-- ═══════════════════════════════════════════════════════

Config.GarageProximityCheck = false
Config.GarageProximityDistance = 50.0

-- ═══════════════════════════════════════════════════════
-- GARAGE INTEGRATIONS
-- Auto-detected at runtime, but can be forced here
-- ═══════════════════════════════════════════════════════

Config.GarageResource = 'auto'  -- 'auto', 'qs-advancedgarages', 'jg-advancedgarages', 'qb-garages', 'cd_garage', 'loaf_garage'

-- Supported garage systems (auto-detected):
-- qs-advancedgarages (Quasar)
-- jg-advancedgarages (JG Scripts)
-- qb-garages (QBCore official)
-- cd_garage (Codesign)
-- loaf_garage (Loaf)
-- okokGarage (okok)
-- esx_advancedgarage (ESX)

-- ═══════════════════════════════════════════════════════
-- VEHICLE TYPES TO PERSIST
-- ═══════════════════════════════════════════════════════

Config.PersistTypes = {
    'automobile',
    'bike',
    'boat',
    'heli',
    'plane',
    'quadbike',
    'trailer'
}

-- ═══════════════════════════════════════════════════════
-- BLACKLISTED MODELS (Never persist these)
-- ═══════════════════════════════════════════════════════

Config.BlacklistedModels = {
    -- Emergency vehicles
    'police', 'police2', 'police3', 'police4', 'police5',
    'policeb', 'polmav', 'riot', 'riot2',
    'fbi', 'fbi2', 'sheriff', 'sheriff2',
    'ambulance', 'firetruk', 'lguard',
    'pbus', 'pranger',

    -- Coast Guard / Maritime (job boats for dps-maritime)
    'dinghy', 'dinghy2', 'dinghy3', 'dinghy4', 'dinghy5',
    'jetmax', 'marquis', 'toro', 'toro2',
    'tropic', 'tropic2', 'speeder', 'speeder2',
    'seashark', 'seashark2', 'seashark3',
    'squalo', 'suntrap', 'tug',
    'costal', 'costal2', 'longfin',
    'avisa', 'submersible', 'submersible2',
    'patrolboat',

    -- Work vehicles
    'forklift', 'mower',
    'tractor', 'tractor2', 'tractor3',

    -- Utility
    'trash', 'trash2', 'bus', 'coach',
}

-- ═══════════════════════════════════════════════════════
-- BLACKLISTED JOBS (Their vehicles don't persist)
-- ═══════════════════════════════════════════════════════

Config.BlacklistedJobs = {
    'police', 'sheriff', 'bcso', 'sasp', 'sahp', 'lspd',
    'ambulance', 'ems', 'fire',
    'mechanic', 'tow',
    'taxi', 'bus',
}

-- ═══════════════════════════════════════════════════════
-- ORPHANED VEHICLE CLEANUP
-- ═══════════════════════════════════════════════════════

Config.OrphanedVehicles = {
    -- Days before a world vehicle is considered orphaned
    orphanThresholdDays = 7,

    -- What to do: 'impound' or 'delete'
    action = 'impound',

    -- Impound lot name (for QBCore state = 2)
    impoundLot = 'impound',

    -- Fee per day orphaned
    feePerDay = 100,

    -- Maximum fee
    maxFee = 1500,

    -- Cleanup interval (minutes)
    cleanupInterval = 30
}

-- ═══════════════════════════════════════════════════════
-- TOW INTEGRATION (dps-towjob, qb-tow, etc.)
-- ═══════════════════════════════════════════════════════

Config.TowJobs = {
    'police', 'sheriff', 'bcso', 'sasp', 'sahp', 'lspd',
    'tow', 'mechanic'
}

-- ═══════════════════════════════════════════════════════
-- FUEL SYSTEM (Auto-detected)
-- ═══════════════════════════════════════════════════════

Config.FuelResource = 'auto'  -- 'auto', 'ox_fuel', 'LegacyFuel', 'cdn-fuel', 'ps-fuel', 'native'
