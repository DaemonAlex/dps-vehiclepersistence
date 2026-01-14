# DPS Vehicle Persistence

Realistic vehicle world persistence system for FiveM servers. Vehicles stay where you park them - just like real life.

**Version:** 2.0.0
**Framework:** QB-Core / QBX / ESX (auto-detected)

## Features

- **Disconnect Persistence** - Vehicles remain in the world when owners disconnect
- **Restart Persistence** - Vehicles respawn after server restarts in the same location
- **Full Property Saving** - Mods, colors, liveries, fuel, and damage are preserved
- **Ownership Tracking** - Only owned vehicles are persisted
- **Multi-Framework** - Supports QB-Core, QBX, and ESX
- **Garage Integration** - Works with 7+ garage systems
- **Script Coordination** - Exports to prevent conflicts with other vehicle scripts
- **State Bags** - Efficient synchronization using FiveM's state bag system
- **Orphaned Cleanup** - Auto-impound or delete abandoned vehicles
- **Admin Exempt** - Staff vehicles don't persist (configurable)

## Requirements

- [ox_lib](https://github.com/overextended/ox_lib)
- [oxmysql](https://github.com/overextended/oxmysql)
- One of: qb-core, qbx_core, or es_extended

## Installation

1. Download and extract to your resources folder:
   ```
   resources/[standalone]/[dps]/dps-vehiclepersistence/
   ```

2. Add to your `server.cfg`:
   ```cfg
   ensure dps-vehiclepersistence
   ```

3. Restart your server - the database table creates automatically

## Supported Integrations

### Garage Systems
| System | Status |
|--------|--------|
| qs-advancedgarages (Quasar) | ✅ Full Support |
| jg-advancedgarages (JG Scripts) | ✅ Full Support |
| qb-garages (QBCore) | ✅ Full Support |
| cd_garage (Codesign) | ✅ Full Support |
| loaf_garage (Loaf) | ✅ Full Support |
| okokGarage (okok) | ✅ Full Support |
| esx_advancedgarage (ESX) | ✅ Full Support |

### Other Integrations
- **Dealerships:** jg-dealerships, qs-dealership, qb-vehicleshop
- **Towing:** dps-towjob, qb-tow, generic
- **Law Enforcement:** police impound, ps-mdt, qb-policejob
- **Mechanics:** jg-mechanic, qs-mechanicjob
- **Admin Menus:** vMenu, txAdmin, qb-adminmenu

## Configuration

Edit `config.lua` to customize the system:

```lua
Config = {}

Config.Enabled = true
Config.Debug = false

-- Admin/Staff vehicles don't persist (good for testing)
Config.AdminExempt = true
Config.StaffGroups = { 'admin', 'god', 'superadmin', 'mod', 'dev' }

-- Persistence Settings
Config.VehicleTimeout = 0  -- Minutes (0 = infinite)
Config.PersistThroughRestart = true
Config.MaxVehiclesPerPlayer = 5
Config.MinStationaryTime = 30  -- Seconds
Config.SpawnDelay = 500  -- MS between spawns on restart

-- Garage Integration (auto-detected)
Config.GarageResource = 'auto'

-- Orphaned Vehicle Cleanup
Config.OrphanedVehicles = {
    orphanThresholdDays = 7,
    action = 'impound',  -- 'impound' or 'delete'
    impoundLot = 'impound',
    feePerDay = 100,
    maxFee = 1500,
    cleanupInterval = 30  -- Minutes
}

-- Tow Job Permissions
Config.TowJobs = { 'police', 'sheriff', 'tow', 'mechanic' }

-- Fuel System (auto-detected)
Config.FuelResource = 'auto'
```

## Admin Commands

| Command | Permission | Description |
|---------|------------|-------------|
| `/clearworldvehicles` | admin | Remove all persisted vehicles |
| `/listworldvehicles` | admin | List all persisted vehicles (console) |

## Exports for Script Integration

### Vehicle Control Coordination

Other scripts should use these exports to prevent conflicts:

```lua
-- EXCLUSION SYSTEM (Permanent - job vehicles, rentals, etc.)
exports['dps-vehiclepersistence']:ExcludeFromPersistence(plate, 'my-resource', 'reason')
exports['dps-vehiclepersistence']:RemoveExclusion(plate)
exports['dps-vehiclepersistence']:IsExcludedFromPersistence(plate)

-- LOCK SYSTEM (Temporary - during towing, mechanic work, etc.)
exports['dps-vehiclepersistence']:LockVehicle(plate, 'my-resource')
exports['dps-vehiclepersistence']:UnlockVehicle(plate)
exports['dps-vehiclepersistence']:IsVehicleLocked(plate)

-- NOTIFICATION SYSTEM
-- Actions: 'stored', 'impounded', 'deleted', 'spawned'
exports['dps-vehiclepersistence']:NotifyVehicleHandled(plate, action, 'my-resource')

-- QUERY
exports['dps-vehiclepersistence']:GetVehicleStatus(plate)
-- Returns: { isPersisted, isExcluded, isLocked, exclusionInfo, lockInfo, persistenceData }
```

### Basic Exports

```lua
-- Get all world vehicles
local vehicles = exports['dps-vehiclepersistence']:GetWorldVehicles()

-- Check if a vehicle is persisted
local isPersisted = exports['dps-vehiclepersistence']:IsVehiclePersisted(plate)

-- Remove a persisted vehicle (for towing/impound scripts)
local removed = exports['dps-vehiclepersistence']:RemovePersistedVehicle(plate)
```

## Events

### Server Events

```lua
-- Vehicle stored in garage (removes from persistence)
TriggerServerEvent('dps-vehiclepersistence:vehicleStored', plate)

-- Vehicle destroyed
TriggerServerEvent('dps-vehiclepersistence:vehicleDestroyed', plate)

-- Exclude vehicle from persistence
TriggerServerEvent('dps-vehiclepersistence:excludeVehicle', plate, 'reason')

-- Lock/Unlock vehicle
TriggerServerEvent('dps-vehiclepersistence:lockVehicle', plate)
TriggerServerEvent('dps-vehiclepersistence:unlockVehicle', plate)

-- Notify vehicle handled by another script
TriggerServerEvent('dps-vehiclepersistence:notifyHandled', plate, 'action')
```

### Client Events

```lua
-- Tow the nearest unoccupied vehicle (requires tow job)
TriggerEvent('dps-vehiclepersistence:towNearestVehicle')
```

## State Bags

The script uses FiveM state bags for efficient sync:

```lua
-- Check if vehicle is persisted (client-side)
local state = Entity(vehicle).state
local isPersisted = state['dps:persisted']
local owner = state['dps:owner']
local plate = state['dps:plate']
```

## Database

The resource automatically creates the required database table on first start:

```sql
CREATE TABLE IF NOT EXISTS `dps_world_vehicles` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `plate` VARCHAR(8) NOT NULL,
    `citizenid` VARCHAR(50) NOT NULL,
    `model` VARCHAR(50) NOT NULL,
    `coords` LONGTEXT NOT NULL,
    `heading` FLOAT NOT NULL,
    `props` LONGTEXT,
    `fuel` FLOAT DEFAULT 100.0,
    `body` FLOAT DEFAULT 1000.0,
    `engine` FLOAT DEFAULT 1000.0,
    `saved_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY `plate_unique` (`plate`),
    INDEX `idx_citizenid` (`citizenid`),
    INDEX `idx_saved_at` (`saved_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

## Fuel System Compatibility

Auto-detects and works with:
- ox_fuel
- LegacyFuel
- cdn-fuel
- ps-fuel
- Native fuel (fallback)

## How It Works

1. **Vehicle Exit Detection** - When a player exits their owned vehicle, the system saves position, properties, fuel, and damage

2. **Player Disconnect** - Vehicles remain in the world with owner identifier attached

3. **Server Restart** - All persisted vehicles respawn with saved properties

4. **Garage Storage** - When stored in any supported garage, the vehicle is removed from world persistence

5. **Orphan Cleanup** - Vehicles from inactive players (7+ days) are auto-impounded or deleted

6. **Script Coordination** - Other scripts can lock, exclude, or notify about vehicles to prevent conflicts

## Performance

- Tiered throttling: faster checks near vehicles, slower when distant
- Batched prop requests (max 3 per tick)
- State bags reduce network events
- Configurable spawn delay prevents server lag
- Stale lock auto-cleanup (5 minute timeout)

## Troubleshooting

**Vehicles not persisting?**
- Check if the vehicle model is blacklisted
- Check if the player's job is blacklisted
- Ensure the player owns the vehicle (in database)
- Check if Config.AdminExempt is excluding staff
- Enable `Config.Debug = true`

**Vehicles not spawning after restart?**
- Check `Config.PersistThroughRestart = true`
- Check database table exists and has entries
- Check server console for spawn errors

**Props not applying?**
- Props apply when a player gets within render distance
- Check for ox_lib errors in console

**Conflicts with other scripts?**
- Use the exclusion/lock exports
- Ensure garage integration events are firing
- Check if admin-spawned vehicles are being excluded

## Changelog

### v2.0.0
- Multi-framework support (QB/QBX/ESX)
- Bridge architecture for framework abstraction
- 7+ garage system integrations
- Script coordination exports (Lock, Exclude, Notify)
- State bag synchronization
- Admin menu integrations (vMenu, txAdmin, qb-admin)
- Dealership, tow, mechanic integrations
- Orphaned vehicle impound system
- Version checker with admin notifications

### v1.1.0
- Initial public release
- Basic persistence for QBCore

## License

This resource is provided for use on DPSRP servers. Feel free to modify for your own use.

## Credits

- DaemonAlex
- DPSRP Development Team
- QBCore/ESX Framework Teams
- Overextended (ox_lib, oxmysql)
