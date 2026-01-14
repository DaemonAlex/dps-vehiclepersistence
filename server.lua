-- DPS Vehicle Persistence - Server
-- Realistic vehicle world persistence system
-- Framework: QB/QBX/ESX (via Bridge)

local worldVehicles = {}  -- Track vehicles in the world
local playerVehicles = {} -- Track which vehicles belong to which player
local vehiclePropsQueue = {} -- Queue for vehicles needing props applied

-- Forward declarations for state bag functions
local SetVehicleStateBag, ClearVehicleStateBag

-- ============================================
-- VERSION CHECKER
-- ============================================
local currentVersion = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '1.0.0'
local githubRepo = 'DaemonAlex/dps-vehiclepersistence'
local updateAvailable = false
local latestVersionCached = nil

-- Semantic version comparison (returns true if latest > current)
local function CompareVersions(current, latest)
    if not current or not latest then return false end

    local function parseVersion(v)
        local major, minor, patch = v:match("(%d+)%.(%d+)%.?(%d*)")
        return {
            tonumber(major) or 0,
            tonumber(minor) or 0,
            tonumber(patch) or 0
        }
    end

    local c = parseVersion(current)
    local l = parseVersion(latest)

    for i = 1, 3 do
        if l[i] > c[i] then return true end
        if l[i] < c[i] then return false end
    end
    return false
end

-- Check for updates from GitHub
local function CheckVersion()
    local url = ('https://raw.githubusercontent.com/%s/main/fxmanifest.lua'):format(githubRepo)

    PerformHttpRequest(url, function(statusCode, response, headers)
        if statusCode ~= 200 then
            if Config.Debug then
                print('^1[dps-vehiclepersistence] Version check failed: HTTP ' .. tostring(statusCode))
            end
            return
        end

        local latestVersion = response:match("version ['\"]([%d%.]+)")
        if not latestVersion then
            if Config.Debug then
                print('^1[dps-vehiclepersistence] Could not parse version from GitHub')
            end
            return
        end

        latestVersionCached = latestVersion

        if CompareVersions(currentVersion, latestVersion) then
            updateAvailable = true
            print('^3━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
            print('^3[dps-vehiclepersistence] Update Available!')
            print('^7Current: v' .. currentVersion .. ' → Latest: ^2v' .. latestVersion)
            print('^7Download: https://github.com/' .. githubRepo .. '/releases')
            print('^3━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
        else
            print('^2[dps-vehiclepersistence] Running latest version: v' .. currentVersion)
        end
    end, 'GET')
end

-- Notify admins when they join if update is available
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if updateAvailable and latestVersionCached then
        -- Check if player has admin permissions
        local src = Player.PlayerData.source
        if IsPlayerAceAllowed(src, 'command') then
            Wait(5000) -- Delay to ensure client is ready
            TriggerClientEvent('ox_lib:notify', src, {
                title = 'dps-vehiclepersistence',
                description = 'Update available: v' .. currentVersion .. ' → v' .. latestVersionCached,
                type = 'warning',
                duration = 10000
            })
        end
    end
end)

-- Run version check on resource start (zero resmon impact)
CreateThread(function()
    Wait(5000) -- Wait for server to be ready
    CheckVersion()
end)

-- Callback to check if player owns a vehicle
lib.callback.register('dps-vehiclepersistence:checkOwnership', function(source, plate)
    return Bridge.CheckVehicleOwnership(source, plate)
end)

-- Initialize database table
CreateThread(function()
    -- Skip everything if persistence is disabled
    if Config.Enabled == false then
        print('^3[dps-vehiclepersistence] Persistence DISABLED - not loading vehicles')
        return
    end

    MySQL.query([[
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
            UNIQUE KEY `plate_unique` (`plate`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    if Config.Debug then
        print('^2[dps-vehiclepersistence] Database table initialized')
    end

    -- Spawn persisted vehicles after short delay
    if Config.PersistThroughRestart then
        Wait(5000) -- Wait for server to fully start
        SpawnPersistedVehicles()
    end
end)

-- Check if vehicle model is blacklisted
local function IsBlacklisted(model)
    local modelName = string.lower(GetDisplayNameFromVehicleModel(model) or '')
    for _, blacklisted in ipairs(Config.BlacklistedModels) do
        if string.lower(blacklisted) == modelName then
            return true
        end
    end
    return false
end

-- Check if player's job is blacklisted
local function IsJobBlacklisted(identifier)
    local player = Bridge.GetPlayerByIdentifier(identifier)
    if player then
        local job = nil
        if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
            job = player.PlayerData.job.name
        elseif Bridge.Framework == 'esx' then
            job = player.job.name
        end

        if job then
            for _, blacklisted in ipairs(Config.BlacklistedJobs) do
                if blacklisted == job then
                    return true
                end
            end
        end
    end
    return false
end

-- Check if player is staff (exempt from persistence)
local function IsPlayerAdmin(source)
    if not Config.AdminExempt then return false end
    if not source then return false end

    -- Check ACE permissions (txAdmin, vMenu, etc.)
    if IsPlayerAceAllowed(source, 'command') then return true end
    if IsPlayerAceAllowed(source, 'admin') then return true end

    -- Check framework-specific staff permissions
    local group = Bridge.GetPermissionGroup(source)
    local staffGroups = Config.StaffGroups or { 'admin', 'god' }
    for _, staffGroup in ipairs(staffGroups) do
        if group == staffGroup then
            return true
        end
    end

    return false
end

-- Callback for client to check admin status
lib.callback.register('dps-vehiclepersistence:isAdmin', function(source)
    return IsPlayerAdmin(source)
end)

-- Get vehicle properties from networked entity
local function GetVehicleProps(netId)
    local props = nil
    local success = pcall(function()
        -- Request props from client
        local playerId = NetworkGetEntityOwner(NetworkGetEntityFromNetworkId(netId))
        if playerId then
            TriggerClientEvent('dps-vehiclepersistence:getProps', playerId, netId)
        end
    end)
    return props
end

-- Save a single vehicle to database
local function SaveVehicleToDB(vehicleData)
    if not vehicleData or not vehicleData.plate then return false end

    MySQL.insert([[
        INSERT INTO dps_world_vehicles (plate, citizenid, model, coords, heading, props, fuel, body, engine, saved_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
        ON DUPLICATE KEY UPDATE
            coords = VALUES(coords),
            heading = VALUES(heading),
            props = VALUES(props),
            fuel = VALUES(fuel),
            body = VALUES(body),
            engine = VALUES(engine),
            saved_at = NOW()
    ]], {
        vehicleData.plate,
        vehicleData.citizenid,
        vehicleData.model,
        json.encode(vehicleData.coords),
        vehicleData.heading,
        json.encode(vehicleData.props or {}),
        vehicleData.fuel or 100.0,
        vehicleData.body or 1000.0,
        vehicleData.engine or 1000.0
    })

    if Config.Debug then
        print('^3[dps-vehiclepersistence] Saved vehicle: ' .. vehicleData.plate)
    end

    return true
end

-- Remove vehicle from database
local function RemoveVehicleFromDB(plate)
    MySQL.query('DELETE FROM dps_world_vehicles WHERE plate = ?', {plate})
    if Config.Debug then
        print('^1[dps-vehiclepersistence] Removed vehicle from DB: ' .. plate)
    end
end

-- Spawn all persisted vehicles on server start
function SpawnPersistedVehicles()
    local vehicles = MySQL.query.await('SELECT * FROM dps_world_vehicles')

    if not vehicles or #vehicles == 0 then
        print('^2[dps-vehiclepersistence] No persisted vehicles to spawn')
        return
    end

    print('^3[dps-vehiclepersistence] Spawning ' .. #vehicles .. ' persisted vehicles...')

    local spawned = 0
    for _, veh in ipairs(vehicles) do
        local coords = json.decode(veh.coords)
        local props = json.decode(veh.props or '{}')

        -- Spawn the vehicle
        local modelHash = joaat(veh.model)
        local vehicle = CreateVehicleServerSetter(modelHash, 'automobile', coords.x, coords.y, coords.z, veh.heading)

        if vehicle and vehicle ~= 0 then
            -- Wait for entity to exist
            local timeout = 0
            while not DoesEntityExist(vehicle) and timeout < 5000 do
                Wait(100)
                timeout = timeout + 100
            end

            if DoesEntityExist(vehicle) then
                -- Set the plate
                SetVehicleNumberPlateText(vehicle, veh.plate)

                -- Track this vehicle
                local netId = NetworkGetNetworkIdFromEntity(vehicle)
                local vehicleData = {
                    netId = netId,
                    entity = vehicle,
                    identifier = veh.citizenid, -- citizenid column stores the identifier
                    model = veh.model,
                    plate = veh.plate,
                    fuel = veh.fuel,
                    body = veh.body,
                    engine = veh.engine,
                    props = props,
                    needsProps = true
                }
                worldVehicles[veh.plate] = vehicleData

                -- Set state bag for this vehicle
                SetVehicleStateBag(vehicle, vehicleData)

                -- Queue for props application when a player gets near
                vehiclePropsQueue[veh.plate] = {
                    netId = netId,
                    props = props,
                    fuel = veh.fuel,
                    body = veh.body,
                    engine = veh.engine
                }

                spawned = spawned + 1

                if Config.Debug then
                    print('^2[dps-vehiclepersistence] Spawned: ' .. veh.plate .. ' at ' .. coords.x .. ', ' .. coords.y .. ', ' .. coords.z)
                end
            end
        end

        Wait(Config.SpawnDelay)
    end

    print('^2[dps-vehiclepersistence] Successfully spawned ' .. spawned .. '/' .. #vehicles .. ' vehicles')
end

-- When a player requests props for a nearby vehicle
RegisterNetEvent('dps-vehiclepersistence:requestProps', function(plate)
    local src = source
    if vehiclePropsQueue[plate] then
        local data = vehiclePropsQueue[plate]
        TriggerClientEvent('dps-vehiclepersistence:applyProps', src, data.netId, data.props, data.fuel, data.body, data.engine)
        vehiclePropsQueue[plate] = nil

        if worldVehicles[plate] then
            worldVehicles[plate].needsProps = false
        end

        if Config.Debug then
            print('^2[dps-vehiclepersistence] Props sent to client for: ' .. plate)
        end
    end
end)

-- Handle player entering a vehicle
RegisterNetEvent('dps-vehiclepersistence:vehicleEntered', function(netId, plate, isOwner)
    if Config.Enabled == false then return end
    local src = source
    if IsPlayerAdmin(src) then return end -- Admin exempt

    local identifier = Bridge.GetIdentifier(src)
    if not identifier then return end

    -- If this is the owner's vehicle, track it
    if isOwner then
        if not playerVehicles[identifier] then
            playerVehicles[identifier] = {}
        end
        playerVehicles[identifier][plate] = netId

        -- Remove from world vehicles since owner is driving
        if worldVehicles[plate] then
            worldVehicles[plate].beingDriven = true
        end
    end
end)

-- Handle player exiting a vehicle
RegisterNetEvent('dps-vehiclepersistence:vehicleExited', function(vehicleData)
    if Config.Enabled == false then return end
    local src = source
    if IsPlayerAdmin(src) then return end -- Admin exempt

    local identifier = Bridge.GetIdentifier(src)
    if not identifier then return end

    -- Check if player owns this vehicle (client sends identifier)
    if vehicleData.identifier ~= identifier then return end

    -- Check blacklists
    if IsBlacklisted(vehicleData.model) then return end
    if IsJobBlacklisted(identifier) then return end

    -- Count player's world vehicles
    local count = 0
    for plate, veh in pairs(worldVehicles) do
        if veh.identifier == identifier and not veh.beingDriven then
            count = count + 1
        end
    end

    -- Check max vehicles limit
    if count >= Config.MaxVehiclesPerPlayer then
        -- Remove oldest vehicle
        local oldest = nil
        local oldestTime = math.huge
        for plate, veh in pairs(worldVehicles) do
            if veh.identifier == identifier and veh.savedAt and veh.savedAt < oldestTime then
                oldest = plate
                oldestTime = veh.savedAt
            end
        end
        if oldest then
            RemoveVehicleFromDB(oldest)
            worldVehicles[oldest] = nil
        end
    end

    -- Track this vehicle
    worldVehicles[vehicleData.plate] = {
        netId = vehicleData.netId,
        identifier = identifier,
        model = vehicleData.model,
        plate = vehicleData.plate,
        coords = vehicleData.coords,
        heading = vehicleData.heading,
        props = vehicleData.props,
        fuel = vehicleData.fuel,
        body = vehicleData.body,
        engine = vehicleData.engine,
        savedAt = os.time(),
        beingDriven = false
    }

    -- Save to database (uses citizenid column for QB compat)
    local dbData = {
        plate = vehicleData.plate,
        citizenid = identifier, -- Column name in DB
        model = vehicleData.model,
        coords = vehicleData.coords,
        heading = vehicleData.heading,
        props = vehicleData.props,
        fuel = vehicleData.fuel,
        body = vehicleData.body,
        engine = vehicleData.engine
    }
    SaveVehicleToDB(dbData)

    if Config.Debug then
        print('^2[dps-vehiclepersistence] Vehicle parked: ' .. vehicleData.plate .. ' by ' .. identifier)
    end
end)

-- Handle vehicle stored in garage
RegisterNetEvent('dps-vehiclepersistence:vehicleStored', function(plate)
    if Config.Enabled == false then return end
    if worldVehicles[plate] then
        RemoveVehicleFromDB(plate)
        worldVehicles[plate] = nil

        if Config.Debug then
            print('^3[dps-vehiclepersistence] Vehicle stored in garage: ' .. plate)
        end
    end
end)

-- Handle player disconnect
AddEventHandler('playerDropped', function(reason)
    local src = source
    local identifier = Bridge.GetIdentifier(src)
    if not identifier then return end

    -- Save all vehicles the player was near/driving
    if playerVehicles[identifier] then
        for plate, netId in pairs(playerVehicles[identifier]) do
            -- Vehicle will be tracked by world vehicles system
            -- Mark as no longer being driven
            if worldVehicles[plate] then
                worldVehicles[plate].beingDriven = false
            end
        end
        playerVehicles[identifier] = nil
    end

    if Config.Debug then
        print('^3[dps-vehiclepersistence] Player disconnected: ' .. identifier)
    end
end)

-- Handle vehicle destroyed/deleted
RegisterNetEvent('dps-vehiclepersistence:vehicleDestroyed', function(plate)
    if Config.Enabled == false then return end
    if worldVehicles[plate] then
        RemoveVehicleFromDB(plate)
        worldVehicles[plate] = nil

        if Config.Debug then
            print('^1[dps-vehiclepersistence] Vehicle destroyed: ' .. plate)
        end
    end
end)

-- Tow/impound a vehicle (removes from persistence)
RegisterNetEvent('dps-vehiclepersistence:towVehicle', function(plate)
    local src = source
    local job = Bridge.GetPlayerJob(src)
    if not job then return end

    -- Check if player has tow permissions
    local hasTowPerm = false
    for _, towJob in ipairs(Config.TowJobs or {'police', 'sheriff', 'tow', 'mechanic'}) do
        if job == towJob then
            hasTowPerm = true
            break
        end
    end
    if not hasTowPerm then return end

    if worldVehicles[plate] then
        RemoveVehicleFromDB(plate)
        worldVehicles[plate] = nil

        TriggerClientEvent('ox_lib:notify', src, {
            title = 'Vehicle Towed',
            description = 'Vehicle ' .. plate .. ' has been towed/impounded',
            type = 'success'
        })

        if Config.Debug then
            print('^3[dps-vehiclepersistence] Vehicle towed: ' .. plate)
        end
    end
end)

-- Admin command to clear all persisted vehicles
Bridge.AddCommand('clearworldvehicles', 'Clear all persisted world vehicles (Admin)', {}, true, function(source, args)
    MySQL.query('DELETE FROM dps_world_vehicles')
    worldVehicles = {}

    Bridge.Notify(source, 'Vehicles Cleared', 'All persisted world vehicles have been removed', 'success')
    print('^1[dps-vehiclepersistence] All world vehicles cleared by admin')
end)

-- Admin command to list persisted vehicles
Bridge.AddCommand('listworldvehicles', 'List all persisted world vehicles (Admin)', {}, true, function(source, args)
    local vehicles = MySQL.query.await('SELECT plate, citizenid, model FROM dps_world_vehicles')

    if not vehicles or #vehicles == 0 then
        Bridge.Notify(source, 'World Vehicles', 'No persisted vehicles found', 'inform')
        return
    end

    print('^3=== Persisted World Vehicles ===')
    for _, veh in ipairs(vehicles) do
        print(string.format('^7[%s] %s - Owner: %s', veh.plate, veh.model, veh.citizenid))
    end
    print('^3Total: ' .. #vehicles .. ' vehicles')

    Bridge.Notify(source, 'World Vehicles', #vehicles .. ' vehicles persisted (check console)', 'success')
end)

-- Save all vehicles on server shutdown
AddEventHandler('txAdmin:events:serverShuttingDown', function()
    print('^3[dps-vehiclepersistence] Server shutting down - saving all world vehicles...')

    local saved = 0
    for plate, veh in pairs(worldVehicles) do
        if not veh.beingDriven then
            SaveVehicleToDB(veh)
            saved = saved + 1
        end
    end

    print('^2[dps-vehiclepersistence] Saved ' .. saved .. ' vehicles before shutdown')
end)

-- ============================================
-- ORPHANED VEHICLE CLEANUP / IMPOUND MIGRATION
-- ============================================

-- Calculate impound fee based on orphan age
local function CalculateImpoundFee(savedAt)
    if not Config.OrphanedVehicles or Config.OrphanedVehicles.feePerDay == 0 then
        return 0
    end

    local now = os.time()
    local savedTime = savedAt or now
    local daysOrphaned = math.floor((now - savedTime) / 86400)
    local fee = daysOrphaned * Config.OrphanedVehicles.feePerDay

    return math.min(fee, Config.OrphanedVehicles.maxFee or 1500)
end

-- Migrate orphaned vehicle to impound
local function MigrateToImpound(vehicleData)
    if not vehicleData or not vehicleData.plate then return false end

    local impoundLot = Config.OrphanedVehicles and Config.OrphanedVehicles.impoundLot or 'impound'
    local depotPrice = CalculateImpoundFee(vehicleData.savedAt)

    -- Update player_vehicles to set state = 2 (impounded) with depot info
    local result = MySQL.update.await([[
        UPDATE player_vehicles
        SET state = 2, garage = ?, depotprice = ?
        WHERE plate = ?
    ]], { impoundLot, depotPrice, vehicleData.plate })

    if result and result > 0 then
        -- Remove from world vehicles table
        MySQL.query('DELETE FROM dps_world_vehicles WHERE plate = ?', { vehicleData.plate })
        worldVehicles[vehicleData.plate] = nil

        if Config.Debug then
            print('^3[dps-vehiclepersistence] Impounded orphaned vehicle: ' .. vehicleData.plate .. ' (Fee: $' .. depotPrice .. ')')
        end
        return true
    end

    return false
end

-- Periodic cleanup of orphaned vehicles (migrate to impound or delete)
CreateThread(function()
    -- Skip if persistence is disabled
    if Config.Enabled == false then return end

    local intervalMs = ((Config.OrphanedVehicles and Config.OrphanedVehicles.cleanupInterval) or 30) * 60000

    while true do
        Wait(intervalMs)

        local thresholdDays = (Config.OrphanedVehicles and Config.OrphanedVehicles.orphanThresholdDays) or 7
        local action = (Config.OrphanedVehicles and Config.OrphanedVehicles.action) or 'impound'

        -- Find orphaned vehicles
        local orphaned = MySQL.query.await([[
            SELECT wv.*, UNIX_TIMESTAMP(wv.saved_at) as saved_timestamp
            FROM dps_world_vehicles wv
            LEFT JOIN players p ON wv.citizenid = p.citizenid
            WHERE wv.saved_at < DATE_SUB(NOW(), INTERVAL ? DAY)
            AND (p.last_updated IS NULL OR p.last_updated < DATE_SUB(NOW(), INTERVAL ? DAY))
        ]], { thresholdDays, thresholdDays })

        if orphaned and #orphaned > 0 then
            local processed = 0

            for _, veh in ipairs(orphaned) do
                if action == 'impound' then
                    -- Migrate to impound lot
                    local vehicleData = {
                        plate = veh.plate,
                        citizenid = veh.citizenid,
                        savedAt = veh.saved_timestamp
                    }
                    if MigrateToImpound(vehicleData) then
                        processed = processed + 1
                    end
                else
                    -- Just delete
                    MySQL.query('DELETE FROM dps_world_vehicles WHERE plate = ?', { veh.plate })
                    worldVehicles[veh.plate] = nil
                    processed = processed + 1
                end
            end

            if processed > 0 then
                local actionLabel = action == 'impound' and 'impounded' or 'deleted'
                print('^3[dps-vehiclepersistence] ' .. string.upper(actionLabel) .. ' ' .. processed .. ' orphaned vehicles')
            end
        end
    end
end)

-- ============================================
-- STATE BAG SYNCING
-- Reduces network events by using FiveM's state bag system
-- ============================================

-- Set vehicle state bag with persistence data
SetVehicleStateBag = function(entity, vehicleData)
    if not entity or not DoesEntityExist(entity) then return end

    local state = Entity(entity).state

    -- Core persistence data (minimal, frequently accessed)
    state:set('dps:persisted', true, true)
    state:set('dps:owner', vehicleData.identifier, true)
    state:set('dps:plate', vehicleData.plate, true)

    -- Optional detailed data (set but not replicated frequently)
    if vehicleData.fuel then
        state:set('dps:fuel', vehicleData.fuel, false)
    end
    if vehicleData.body then
        state:set('dps:body', vehicleData.body, false)
    end
    if vehicleData.engine then
        state:set('dps:engine', vehicleData.engine, false)
    end

    if Config.Debug then
        print('^2[dps-vehiclepersistence] State bag set for: ' .. vehicleData.plate)
    end
end

-- Clear vehicle state bag when removed from persistence
ClearVehicleStateBag = function(entity)
    if not entity or not DoesEntityExist(entity) then return end

    local state = Entity(entity).state
    state:set('dps:persisted', nil, true)
    state:set('dps:owner', nil, true)
    state:set('dps:plate', nil, true)
    state:set('dps:fuel', nil, false)
    state:set('dps:body', nil, false)
    state:set('dps:engine', nil, false)
end

-- Listen for state bag changes from client (damage updates)
AddStateBagChangeHandler('dps:damage', nil, function(bagName, key, value, reserved, replicated)
    if replicated then return end -- Ignore if already replicated

    local entity = GetEntityFromStateBagName(bagName)
    if not entity or entity == 0 then return end

    local plate = GetVehicleNumberPlateText(entity)
    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

    if worldVehicles[plate] and value then
        -- Update tracked damage values
        worldVehicles[plate].body = value.body
        worldVehicles[plate].engine = value.engine

        if Config.Debug then
            print('^3[dps-vehiclepersistence] Damage updated via state bag: ' .. plate)
        end
    end
end)

-- Export functions for other resources
exports('GetWorldVehicles', function()
    return worldVehicles
end)

exports('IsVehiclePersisted', function(plate)
    return worldVehicles[plate] ~= nil
end)

exports('RemovePersistedVehicle', function(plate)
    if worldVehicles[plate] then
        RemoveVehicleFromDB(plate)
        worldVehicles[plate] = nil
        return true
    end
    return false
end)

-- ============================================
-- VEHICLE CONTROL COORDINATION
-- Any script that controls vehicles should use these
-- to prevent conflicts with persistence
-- ============================================

local jobVehicles = {} -- [plate] = { resource, reason, timestamp }
local lockedVehicles = {} -- [plate] = { resource, locked_at } - temporarily locked from persistence

-- ═══════════════════════════════════════════════════════
-- EXCLUSION SYSTEM (Permanent - for job vehicles, rentals, etc.)
-- ═══════════════════════════════════════════════════════

-- Mark a vehicle as excluded from persistence
exports('ExcludeFromPersistence', function(plate, resource, reason)
    if not plate then return false end

    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

    jobVehicles[plate] = {
        resource = resource or 'unknown',
        reason = reason or 'job vehicle',
        timestamp = os.time()
    }

    -- Remove from persistence if already tracked
    if worldVehicles[plate] then
        RemoveVehicleFromDB(plate)
        worldVehicles[plate] = nil
    end

    Bridge.Debug('Vehicle excluded by ' .. (resource or 'unknown') .. ': ' .. plate .. ' (' .. (reason or 'no reason') .. ')')
    return true
end)

-- Remove exclusion
exports('RemoveExclusion', function(plate)
    if not plate then return false end
    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

    if jobVehicles[plate] then
        jobVehicles[plate] = nil
        Bridge.Debug('Vehicle exclusion removed: ' .. plate)
        return true
    end
    return false
end)

-- Check if excluded
exports('IsExcludedFromPersistence', function(plate)
    if not plate then return false end
    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")
    return jobVehicles[plate] ~= nil
end)

-- ═══════════════════════════════════════════════════════
-- LOCK SYSTEM (Temporary - during active use by another script)
-- ═══════════════════════════════════════════════════════

-- Lock vehicle from persistence (during active towing, mechanic work, etc.)
exports('LockVehicle', function(plate, resource)
    if not plate then return false end
    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

    lockedVehicles[plate] = {
        resource = resource or 'unknown',
        locked_at = os.time()
    }

    Bridge.Debug('Vehicle locked by ' .. (resource or 'unknown') .. ': ' .. plate)
    return true
end)

-- Unlock vehicle (allow persistence again)
exports('UnlockVehicle', function(plate)
    if not plate then return false end
    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

    if lockedVehicles[plate] then
        lockedVehicles[plate] = nil
        Bridge.Debug('Vehicle unlocked: ' .. plate)
        return true
    end
    return false
end)

-- Check if locked
exports('IsVehicleLocked', function(plate)
    if not plate then return false end
    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")
    return lockedVehicles[plate] ~= nil
end)

-- ═══════════════════════════════════════════════════════
-- NOTIFICATION SYSTEM (For other scripts to coordinate)
-- ═══════════════════════════════════════════════════════

-- Notify persistence that a vehicle is being handled by another script
exports('NotifyVehicleHandled', function(plate, action, resource)
    if not plate then return false end
    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

    if action == 'stored' or action == 'impounded' or action == 'deleted' then
        -- Remove from world persistence
        if worldVehicles[plate] then
            RemoveVehicleFromDB(plate)
            worldVehicles[plate] = nil
        end
        Bridge.Debug('Vehicle ' .. action .. ' by ' .. (resource or 'external') .. ': ' .. plate)
    elseif action == 'spawned' then
        -- New vehicle spawned - will be tracked when owner exits
        Bridge.Debug('Vehicle spawned notification from ' .. (resource or 'external') .. ': ' .. plate)
    end

    return true
end)

-- ═══════════════════════════════════════════════════════
-- QUERY EXPORTS (For other scripts to check status)
-- ═══════════════════════════════════════════════════════

-- Get full status of a vehicle
exports('GetVehicleStatus', function(plate)
    if not plate then return nil end
    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

    return {
        isPersisted = worldVehicles[plate] ~= nil,
        isExcluded = jobVehicles[plate] ~= nil,
        isLocked = lockedVehicles[plate] ~= nil,
        exclusionInfo = jobVehicles[plate],
        lockInfo = lockedVehicles[plate],
        persistenceData = worldVehicles[plate]
    }
end)

-- Event versions for client-side use
RegisterNetEvent('dps-vehiclepersistence:excludeVehicle', function(plate, reason)
    local src = source
    exports['dps-vehiclepersistence']:ExcludeFromPersistence(plate, GetInvokingResource() or 'client', reason)
end)

RegisterNetEvent('dps-vehiclepersistence:removeExclusion', function(plate)
    exports['dps-vehiclepersistence']:RemoveExclusion(plate)
end)

RegisterNetEvent('dps-vehiclepersistence:lockVehicle', function(plate)
    exports['dps-vehiclepersistence']:LockVehicle(plate, GetInvokingResource() or 'client')
end)

RegisterNetEvent('dps-vehiclepersistence:unlockVehicle', function(plate)
    exports['dps-vehiclepersistence']:UnlockVehicle(plate)
end)

RegisterNetEvent('dps-vehiclepersistence:notifyHandled', function(plate, action)
    exports['dps-vehiclepersistence']:NotifyVehicleHandled(plate, action, GetInvokingResource() or 'client')
end)

-- Auto-cleanup stale locks (5 minute timeout)
CreateThread(function()
    while true do
        Wait(60000) -- Check every minute

        local now = os.time()
        local staleTimeout = 300 -- 5 minutes

        for plate, lockInfo in pairs(lockedVehicles) do
            if now - lockInfo.locked_at > staleTimeout then
                lockedVehicles[plate] = nil
                Bridge.Debug('Stale lock removed for: ' .. plate)
            end
        end
    end
end)
