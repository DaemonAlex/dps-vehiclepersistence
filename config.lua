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

-- Hard expiry for a parked vehicle, in MINUTES. 0 = infinite (never expire).
-- saved_at is refreshed on every park and every live-state push, so an actively
-- used vehicle never expires; only genuinely abandoned ones are cleaned up.
-- Example: 1440 = expire vehicles untouched for 24h. Prevents unbounded world growth.
Config.VehicleTimeout = 0

-- Persist through server restarts
Config.PersistThroughRestart = true

-- Max vehicles per player in the world
Config.MaxVehiclesPerPlayer = 5

-- Spawn delay between vehicles on restart (ms)
Config.SpawnDelay = 500

-- Grace period after garage spawn before persistence kicks in (ms)
-- Prevents saving vehicles player just spawned but hasn't entered yet
-- Increase if you have high ping/server load
Config.GarageSpawnGracePeriod = 10000  -- 10 seconds (was hardcoded 5s)

-- Ownership check cache duration (seconds)
-- Prevents DB spam when hopping in/out of vehicles repeatedly
Config.OwnershipCacheDuration = 30

-- ═══════════════════════════════════════════════════════
-- GARAGE INTEGRATIONS
-- Fully event-driven (client listens for each garage system's store/spawn events).
-- Supported (auto-detected, no config needed):
--   qs-advancedgarages (Quasar), jg-advancedgarages (JG), qb-garages (QBCore),
--   cd_garage (Codesign), loaf_garage (Loaf), okokGarage (okok),
--   esx_advancedgarage (ESX)
-- ═══════════════════════════════════════════════════════

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

-- ═══════════════════════════════════════════════════════
-- DSRP JOB INTEGRATION
-- Vehicles spawned by these job scripts are auto-excluded
-- ═══════════════════════════════════════════════════════

Config.JobVehicleExclusion = {
    enabled = true,

    -- Job vehicle spawn events to listen for (auto-exclude from persistence)
    spawnEvents = {
        -- DSRP Police Job
        'dps-policejob:client:SpawnVehicle',
        'police:client:SpawnVehicle',

        -- DSRP EMS Job
        'dps-ambulancejob:client:SpawnVehicle',
        'ambulance:client:SpawnVehicle',

        -- QB Police/EMS
        'qb-policejob:client:spawnVehicle',
        'qb-ambulancejob:client:spawnVehicle',

        -- Generic patterns
        'job:client:spawnVehicle',
    },

    -- Exclusion reason logged
    reason = 'job-vehicle'
}
