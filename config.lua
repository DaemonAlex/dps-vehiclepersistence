Config = {}

-- Master enable/disable toggle (set to false to completely disable persistence)
Config.Enabled = true

-- Exempt staff from vehicle persistence tracking (recommended for testing)
Config.AdminExempt = true
Config.StaffGroups = {
    'admin', 'god', 'superadmin', 'mod', 'moderator',
    'helper', 'staff', 'support', 'dev', 'developer'
}

-- How long a vehicle stays in the world after the owner disconnects (in minutes)
-- Set to 0 for infinite (until server restart or towed)
Config.VehicleTimeout = 0  -- 0 = vehicles persist indefinitely

-- Should vehicles persist through server restarts?
Config.PersistThroughRestart = true

-- Maximum vehicles per player that can persist in the world
Config.MaxVehiclesPerPlayer = 5

-- Minimum time a vehicle must be stationary before being saved (seconds)
Config.MinStationaryTime = 30

-- Distance from garage to auto-store vehicle instead of world persist
Config.GarageProximityCheck = false  -- Enable to auto-store near garages
Config.GarageProximityDistance = 50.0

-- Vehicle types to persist (all = everything)
Config.PersistTypes = {
    'automobile',
    'bike',
    'boat',
    'heli',
    'plane',
    'quadbike',
    'trailer'
}

-- Vehicles that should NOT persist (emergency vehicles, rentals, job vehicles, etc.)
Config.BlacklistedModels = {
    -- Emergency vehicles
    'police',
    'police2',
    'police3',
    'police4',
    'policeb',
    'polmav',
    'riot',
    'riot2',
    'fbi',
    'fbi2',
    'sheriff',
    'sheriff2',
    'ambulance',
    'firetruk',
    'lguard',
    'pbus',
    'pranger',
    -- Job boats (dps-maritime / ocean-delivery)
    'dinghy',
    'dinghy2',
    'dinghy3',
    'dinghy4',
    'dinghy5',
    'jetmax',
    'marquis',
    'toro',
    'toro2',
    'tropic',
    'tropic2',
    'speeder',
    'speeder2',
    'seashark',
    'seashark2',
    'seashark3',
    'squalo',
    'suntrap',
    'tug',
    'costal',
    'costal2',
    'longfin',
    'avisa',
    'submersible',
    'submersible2',
    'patrolboat',
    -- Job vehicles (forklifts, etc.)
    'forklift',
    'mower',
    'tractor',
    'tractor2',
    'tractor3'
}

-- Jobs whose vehicles should not persist (they use job garages)
Config.BlacklistedJobs = {
    'police',
    'sheriff',
    'ambulance',
    'fire',
    'mechanic'
}

-- Spawn delay between each vehicle on server start (ms)
-- Higher = less server load, but slower spawning
Config.SpawnDelay = 500

-- Debug mode - prints vehicle persistence info
Config.Debug = false

-- ============================================
-- ORPHAN VEHICLE HANDLING
-- ============================================
Config.OrphanedVehicles = {
    -- Days before a world vehicle is considered orphaned
    orphanThresholdDays = 7,

    -- What to do with orphaned vehicles: 'impound' or 'delete'
    action = 'impound',

    -- If 'impound', which impound lot to send vehicles to
    -- Uses player_vehicles.state = 2 (impounded) for QB-Core
    impoundLot = 'impound',

    -- Impound fee per orphan day (0 = no fee scaling)
    feePerDay = 100,

    -- Maximum impound fee
    maxFee = 1500,

    -- How often to run the cleanup (minutes)
    cleanupInterval = 30
}
