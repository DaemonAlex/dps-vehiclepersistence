<p align="center"><img src=".github/dps-logo.svg" alt="DelPerroSands" width="360"></p>

# DPS Vehicle Persistence

Realistic vehicle world persistence system for FiveM servers. Vehicles stay where you park them - just like real life.

**Version:** 2.2.0
**Framework:** QB-Core / QBX / ESX (auto-detected)

## What it is for

In stock FiveM a car left on the street is gone after a server restart, and often sooner. Players then store every car in a garage before they log off, or ask staff where their car went. This script keeps an owned vehicle where the player parked it, with its mods, fuel and damage, through a disconnect and through a restart.

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

## On its own, and with other scripts

**On its own.** With `ox_lib`, `oxmysql` and a framework, owned cars, bikes, boats, quads and trailers stay where they were parked. They come back after a restart with mods, fuel and damage. Each player can have 5 vehicles in the world. Job vehicles and staff vehicles are left out. A vehicle whose owner has not been on for 7 days goes to the impound.

**With a paid garage (jg-advancedgarages, qs-advancedgarages, cd_garage, loaf_garage, okokGarage).** When a player stores a car in the garage, it leaves the world list, so it does not also spawn in the street at the next restart. When a player takes a car out, a short grace period stops it being saved before the player gets in. The script only listens for the garage's store and spawn events. It calls nothing in the garage and writes nothing to it, so a garage update does not break it.

**With a paid dealership or mechanic (jg-dealerships, qs-dealership, jg-mechanic, qs-mechanicjob).** A newly bought car gets the same short grace period as a car taken out of a garage. A car left at a mechanic shop leaves the world list. Again the script only listens for their events.

**With a fuel script (ox_fuel, LegacyFuel, cdn-fuel, ps-fuel).** The saved fuel level is read from, and put back through, the fuel script that is running. With none, the game's own fuel level is used.

**With [dps-parking](https://github.com/DaemonAlex/dps-parking).** dps-parking reads the list of parked vehicles from this script through its exports. It can also remove a vehicle from the list when it handles one.

**With [dps-towjob](https://github.com/DaemonAlex/dps-towjob).** A towed car is handed to the garage or the impound, and dps-towjob tells this script the car was handled. The car then does not spawn in the street again at the next restart.

**With your own scripts.** Use the lock and exclude exports below for rentals, job vehicles and anything else that should not stay in the world.

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
| qs-advancedgarages (Quasar) | Full support |
| jg-advancedgarages (JG Scripts) | Full support |
| qb-garages (QBCore) | Full support |
| cd_garage (Codesign) | Full support |
| loaf_garage (Loaf) | Full support |
| okokGarage (okok) | Full support |
| esx_advancedgarage (ESX) | Full support |

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
Config.VehicleTimeout = 0  -- Minutes untouched before expiry (0 = infinite)
Config.PersistThroughRestart = true
Config.MaxVehiclesPerPlayer = 5
Config.SpawnDelay = 500  -- MS between spawns on restart

-- Garage Integration is fully event-driven / auto-detected (no config key)

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
Config.TowJobs = { 'police', 'bcso', 'sasp', 'tow', 'mechanic' }

-- Jobs whose vehicles never persist
Config.BlacklistedJobs = {
    'police', 'bcso', 'sasp', 'fib', 'doc', 'dfw', 'uscg', 'natguard',
    'sams', 'lsmc', 'lsfd',
    'mechanic', 'tow',
    'taxi', 'bus',
}

-- Vehicle types that persist (helicopters and planes are off)
Config.PersistTypes = { 'automobile', 'bike', 'boat', 'quadbike', 'trailer' }

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
    `vehicle_type` VARCHAR(24) NOT NULL DEFAULT 'automobile',
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

> The `vehicle_type` column is added automatically on start for existing installs (used to respawn boats/helis/planes/bikes/trailers with the correct physics type). Helicopters and planes are switched off in `Config.PersistTypes` since 29 October 2026.

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

### Recent changes

- **19 November 2026 (2.2.1). One owner per car.** A car the garage script has stored or impounded, or that dps-parking keeps, is not saved here and is not spawned at start; its record is removed. This stops the same car existing twice.
- **12 November 2026.** README: what it is for, how it works alone and with paid scripts, other DPS scripts.
- **31 October 2026.** Job lists updated after the Roxwood map and its departments left the server. `rpd`, `rcso`, `rfd`, `omc` and `rmc` are gone from `Config.BlacklistedJobs` and `Config.TowJobs`. The hospital job is `lsmc`.
- **29 October 2026.** Helicopters and planes no longer persist. The flight script on the server owns aircraft, and keeping them in place fought its clean-up. Cars, bikes, boats, quads and trailers still persist.
- **25 September 2026.** `Config.BlacklistedJobs` and `Config.TowJobs` use the server's real job names. The vendor names (`sheriff`, `sahp`, `lspd`, `ambulance`, `ems`, `fire`) are removed.

### v2.2.0
- **QBX fix:** bridge no longer calls `GetCoreObject()` on qbx (this qbx_core build has none). QBX now uses discrete exports (`qbx_core:GetPlayer` / `GetPlayerByCitizenId` / `GetPlayerData`) and `lib.addCommand` for admin commands. Resource now starts on pure Qbox.
- **Security:** the save path is now server-authoritative — server-side ownership check + full sanitization (plate, coords bounds, fuel/body/engine clamps, untrusted props validation) before any DB write.
- **Security:** all client-reachable net events (`vehicleStored`, `vehicleDestroyed`, `excludeVehicle`, `removeExclusion`, `lockVehicle`, `unlockVehicle`, `notifyHandled`) now require the caller to own the plate or hold admin perms. Closes remote wipe/exclude griefing.
- **Restart dedupe:** added `onResourceStop` cleanup that deletes all spawned entities, preventing duplicate accumulation across restarts.
- **Cold-boot:** awaited CREATE TABLE + bounded retry on the initial SELECT (no more blind 5s sleep against the remote DB).
- **Vehicle types:** boats/helis/planes/bikes/trailers now respawn with the correct physics type (stored in new `vehicle_type` column).
- **Disconnect persistence:** vehicles are now saved even if the owner disconnects while driving (live-state cache flushed on drop).
- **Destroy scan:** now only reports persisted, owner-owned vehicles (server re-validates); scan interval raised to 10s.
- **Fuel:** read and apply now use one shared detection path and honor `Config.FuelResource`.
- Fixed `MaxVehiclesPerPlayer` eviction for restart-restored vehicles; fixed unbounded `propsRequested` growth; fixed model blacklist matching.
- Implemented `Config.VehicleTimeout` (hard expiry of abandoned parked vehicles).
- Removed dead config keys (`MinStationaryTime`, `GarageProximityCheck/Distance`, `GarageResource`) and dead prop round-trip code.
- Aligned repository URL to `DaemonAlex/dps-vehiclepersistence`.

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

## Author

Made by [DaemonAlex](https://github.com/DaemonAlex) for DelPerroSands.

## Credits

- DaemonAlex
- DPSRP Development Team
- QBCore/ESX Framework Teams
- Overextended (ox_lib, oxmysql)

## Other DPS scripts

All of these are made for DelPerroSands and run together on one Qbox server. Each one works on
its own. The ones marked "pairs with" do more when both are running.

| Script | What it does |
|---|---|
| [dps-inventory](https://github.com/DaemonAlex/dps-inventory) | The inventory: ox_inventory with equipment slots, backpacks, armour plates and a self status panel, in the DelPerroSands colours. |
| [dps-medical](https://github.com/DaemonAlex/dps-medical) | Patient records, illness and diagnostic tests. A companion to wasabi_ambulance. Pairs with dps-inventory: symptoms and diagnoses show on the status panel. |
| [dps-insurance](https://github.com/DaemonAlex/dps-insurance) | Ties m-Insurance into the MDT, impound, hospital and medical chart, and raises premiums for incidents other scripts report. Pairs with dps-medical and dps-fuel. |
| [dps-studio](https://github.com/DaemonAlex/dps-studio) | Build rooms, doors and portals in game from one panel (`/studio`), with owners and managers so staff do not have to support them. |
| [dps-shops](https://github.com/DaemonAlex/dps-shops) | Shop clerks who greet, react to robberies, talk back through dps-ainpcs and remember trouble, plus player-owned stores with delivery runs. Pairs with dps-ainpcs. |
| [dps-fleet](https://github.com/DaemonAlex/dps-fleet) | Vehicle browser and workshop on one panel: extras, liveries and mods for emergency vehicles. |
| [dps-parking](https://github.com/DaemonAlex/dps-parking) | Parking with valet, impound, violations and reserved spots. |
| [dps-towjob](https://github.com/DaemonAlex/dps-towjob) | Queue-based tow job with jg-mechanic integration. |
| [dps-services](https://github.com/DaemonAlex/dps-services) | Request a tow and follow it live on the lb-phone and lb-tablet. Pairs with dps-towjob. |
| [dps-autoshops](https://github.com/DaemonAlex/dps-autoshops) | Self-service repair shops when no mechanic is on duty. |
| [dps-cityworker](https://github.com/DaemonAlex/dps-cityworker) | City infrastructure job and career. |
| [dps-ainpcs](https://github.com/DaemonAlex/dps-ainpcs) | NPCs you can talk to, with trust, quests and intel. Other scripts can make their own NPCs talk (dps-shops clerks). |
| [dps-badpeds](https://github.com/DaemonAlex/dps-badpeds) | Police interaction with NPCs: stops, arrests, intel and jail records. |
| [dps-gangwars](https://github.com/DaemonAlex/dps-gangwars) | Ambient gang NPCs, territory population and war reinforcements. |
| [dps-rotations](https://github.com/DaemonAlex/dps-rotations) | Moves dealers, harvests and other spots on a fixed schedule. |
| [dps-trains](https://github.com/DaemonAlex/dps-trains) | The train system. Pairs with dps-trains-stock, dps-traintools and dps-transitapp. |
| [dps-transitapp](https://github.com/DaemonAlex/dps-transitapp) | Live train arrival boards on the lb-phone. |
| [dps-faceplant](https://github.com/DaemonAlex/dps-faceplant) | City help, reports and staff tools on the lb-phone and lb-tablet. |
| [dps-chat](https://github.com/DaemonAlex/dps-chat) | A command box for voice-only servers. No chat feed. |
| [dps-filmmode](https://github.com/DaemonAlex/dps-filmmode) | One key hides every HUD layer and gives a smooth free camera for recording. |
| [dps-fuel](https://github.com/DaemonAlex/dps-fuel) | Gas station drive-offs for the ox_fuel nozzle: ripped hose, pump fire, station camera and a police call, by odds. Pairs with dps-insurance. |
| [dps-voice](https://github.com/DaemonAlex/dps-voice) | Spoken lines for NPCs, station announcements, dispatch and shops, from local voice models first. Pairs with dps-ainpcs. |
| [dps-bags](https://github.com/DaemonAlex/dps-bags) | Real bags for ox_inventory: the bag you carry shows on your character. |
| [dps-items](https://github.com/DaemonAlex/dps-items) | Item rules for ox_inventory: locked items, glovebox seats and an exploit watch. |
| [dps-furniture](https://github.com/DaemonAlex/dps-furniture) | Puts streamed furniture packs into the qs-housing furniture shop. |
| [dps-shellbrowser](https://github.com/DaemonAlex/dps-shellbrowser) | Staff tool to look at every qs-housing shell and set its door. |
| [dps-signs](https://github.com/DaemonAlex/dps-signs) | Rotates city messages across the SmartSigns road boards. |
| [dps-stationclear](https://github.com/DaemonAlex/dps-stationclear) | Hides map props that are in the way and keeps stray game peds off chosen spots. |
| [dps-citymap](https://github.com/DaemonAlex/dps-citymap) | A ready-made map of the whole city, cut into tiles for in-game screens. |
| [dps-cayo](https://github.com/DaemonAlex/dps-cayo) | Switches on the game's own Cayo Perico island, and nothing else. |
| [dps-aviation](https://github.com/DaemonAlex/dps-aviation) | Flight behaviour: aircraft idle instead of cutting out, sane taxi speed, a real start sequence. |
| [dps-airlines](https://github.com/DaemonAlex/dps-airlines) | Airlines job: passenger flights, cargo, charters, flight school and maintenance. |
| [dps-traintools](https://github.com/DaemonAlex/dps-traintools) | Rider tools for trains: board, sit, get off at a stop, ambient passengers. Pairs with dps-trains. |
| [dps-trains-stock](https://github.com/DaemonAlex/dps-trains-stock) | Train models and carriage sets for the train system. No scripts. Pairs with dps-trains. |
| [dps-traintracks](https://github.com/DaemonAlex/dps-traintracks) | Extra train track data. No scripts. Pairs with dps-trains. |
| [dps-crossings](https://github.com/DaemonAlex/dps-crossings) | Level crossings that close when a train comes. Pairs with dps-trains. |
| [dps-transit](https://github.com/DaemonAlex/dps-transit) | Passenger rail planning and scheduling (older system; dps-trains runs today). |
| [dps-maritime](https://github.com/DaemonAlex/dps-maritime) | Dock work and boat deliveries with progression. |
| [dps-maritime-maps](https://github.com/DaemonAlex/dps-maritime-maps) | Map files for the Jetsam docks, the map half of dps-maritime. |
| [dps-proracing](https://github.com/DaemonAlex/dps-proracing) | Circuit racing with lobbies, an AI practice grid and lap times. |
| [dps-carmenu](https://github.com/DaemonAlex/dps-carmenu) | Staff vehicle browser and spawner over the live Qbox vehicle list. |
| [dps-clothingbrowser](https://github.com/DaemonAlex/dps-clothingbrowser) | Staff tool to browse, identify and export clothing and uniforms. |
| [dps-lootpeds](https://github.com/DaemonAlex/dps-lootpeds) | Loot dead NPCs, with loot tables per model. |
| [dps-hookers](https://github.com/DaemonAlex/dps-hookers) | Adults-only RP (18+), adapted from MH Hookers by MaDHouSe. |
| [dps-weatherbridge](https://github.com/DaemonAlex/dps-weatherbridge) | Lets qb-weathersync and Renewed-Weathersync scripts work with night_natural_disasters. |
| [dps-fixes](https://github.com/DaemonAlex/dps-fixes) | Small server fixes kept in one resource. |
| [dps-bucketfix](https://github.com/DaemonAlex/dps-bucketfix) | Puts players back in the main world after spawning. |
| [dps-unfocus](https://github.com/DaemonAlex/dps-unfocus) | One key that frees a player stuck in a menu. |
| [dps-welcomecam](https://github.com/DaemonAlex/dps-welcomecam) | Aims the first camera a new player sees. |
| [dps-handlingdump](https://github.com/DaemonAlex/dps-handlingdump) | Developer tool: saves the stock handling of every vanilla vehicle. |
| [dps-weaponsounds](https://github.com/DaemonAlex/dps-weaponsounds) | Custom weapon sounds (planning; no code yet). |
| [dps-events](https://github.com/DaemonAlex/dps-events) | Playtime reward events (planning; no code yet). |
