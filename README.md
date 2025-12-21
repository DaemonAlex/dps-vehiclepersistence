# DPS Vehicle Persistence

Realistic vehicle world persistence system for QBCore FiveM servers. Vehicles stay where you park them - just like real life.

## Features

- **Disconnect Persistence** - Vehicles remain in the world when owners disconnect
- **Restart Persistence** - Vehicles respawn after server restarts in the same location
- **Full Property Saving** - Mods, colors, liveries, fuel, and damage are preserved
- **Ownership Tracking** - Only owned vehicles are persisted
- **Automatic Cleanup** - Destroyed vehicles and orphaned vehicles are cleaned up
- **Towing System** - Police/Tow jobs can remove persistent vehicles
- **Configurable Limits** - Max vehicles per player, blacklisted models/jobs
- **Garage Integration** - Vehicles stored in garages are removed from world persistence

## Requirements

- [qb-core](https://github.com/qbcore-framework/qb-core)
- [ox_lib](https://github.com/overextended/ox_lib)
- [oxmysql](https://github.com/overextended/oxmysql)

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

## Database

The resource automatically creates the required database table on first start. If you need to create it manually, run the following SQL:

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

## Configuration

Edit `config.lua` to customize the system:

```lua
Config = {}

-- How long a vehicle stays in the world after the owner disconnects (in minutes)
-- Set to 0 for infinite (until server restart or towed)
Config.VehicleTimeout = 0

-- Should vehicles persist through server restarts?
Config.PersistThroughRestart = true

-- Maximum vehicles per player that can persist in the world
Config.MaxVehiclesPerPlayer = 5

-- Minimum time a vehicle must be stationary before being saved (seconds)
Config.MinStationaryTime = 30

-- Distance from garage to auto-store vehicle instead of world persist
Config.GarageProximityCheck = false
Config.GarageProximityDistance = 50.0

-- Vehicle types to persist
Config.PersistTypes = {
    'automobile',
    'bike',
    'boat',
    'heli',
    'plane',
    'quadbike',
    'trailer'
}

-- Vehicles that should NOT persist (emergency vehicles, rentals, etc.)
Config.BlacklistedModels = {
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
    'pranger'
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
Config.SpawnDelay = 500

-- Debug mode - prints vehicle persistence info to console
Config.Debug = false
```

## Admin Commands

| Command | Permission | Description |
|---------|------------|-------------|
| `/clearworldvehicles` | admin | Remove all persisted vehicles from the world and database |
| `/listworldvehicles` | admin | List all persisted vehicles in the server console |

## How It Works

1. **Vehicle Exit Detection** - When a player exits their owned vehicle, the system saves:
   - Position and heading
   - All vehicle properties (mods, colors, extras, liveries)
   - Fuel level
   - Body and engine damage

2. **Player Disconnect** - When a player disconnects, their parked vehicles remain in the world

3. **Server Restart** - On server start, all persisted vehicles are respawned with their saved properties

4. **Garage Storage** - When a vehicle is stored in a garage (jg-advancedgarages or qb-garage), it's removed from world persistence

5. **Cleanup** - The system automatically:
   - Removes destroyed vehicles
   - Cleans up vehicles from inactive players (7+ days)
   - Enforces per-player vehicle limits (oldest removed first)

## Exports

For other resources to interact with the system:

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

-- Tow a vehicle (requires police/sheriff/tow/mechanic job)
TriggerServerEvent('dps-vehiclepersistence:towVehicle', plate)
```

### Client Events

```lua
-- Tow the nearest unoccupied vehicle
TriggerEvent('dps-vehiclepersistence:towNearestVehicle')
```

## Fuel System Compatibility

The resource automatically detects and works with:
- ox_fuel
- LegacyFuel
- cdn-fuel
- ps-fuel
- Native fuel (fallback)

## Garage Compatibility

Automatically integrates with:
- jg-advancedgarages
- qb-garage

When vehicles are stored, they're removed from world persistence.

## Performance

- Vehicles spawn with a configurable delay to prevent server lag
- Props are applied when players get within 50 units of spawned vehicles
- Cleanup runs every 30 minutes to remove orphaned vehicles
- Minimal client-side impact with 500ms/2000ms check intervals

## Troubleshooting

**Vehicles not persisting?**
- Check if the vehicle model is blacklisted in config
- Check if the player's job is blacklisted
- Ensure the player owns the vehicle (in `player_vehicles` table)
- Enable `Config.Debug = true` to see console output

**Vehicles not spawning after restart?**
- Check `Config.PersistThroughRestart = true`
- Check database table exists and has entries
- Check server console for spawn errors

**Props not applying?**
- Props apply when a player gets within 50 units
- Check for ox_lib errors in console

## License

This resource is provided for use on DPSRP servers. Feel free to modify for your own use.

## Credits

- DPSRP Development Team
- QBCore Framework
- Overextended (ox_lib, oxmysql)
