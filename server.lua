-- DPS Vehicle Persistence - Server
-- Realistic vehicle world persistence system

local QBCore = exports['qb-core']:GetCoreObject()
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
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then
        return false
    end

    local citizenid = Player.PlayerData.citizenid

    -- Check player_vehicles table
    local result = MySQL.query.await('SELECT citizenid FROM player_vehicles WHERE plate = ?', {plate})

    if result and result[1] then
        return result[1].citizenid == citizenid
    else
        return false
    end
end)

-- Initialize database table
CreateThread(function()
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
local function IsJobBlacklisted(citizenid)
    local player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if player then
        local job = player.PlayerData.job.name
        for _, blacklisted in ipairs(Config.BlacklistedJobs) do
            if blacklisted == job then
                return true
            end
        end
    end
    return false
end

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
                    citizenid = veh.citizenid,
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
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid

    -- If this is the owner's vehicle, track it
    if isOwner then
        if not playerVehicles[citizenid] then
            playerVehicles[citizenid] = {}
        end
        playerVehicles[citizenid][plate] = netId

        -- Remove from world vehicles since owner is driving
        if worldVehicles[plate] then
            worldVehicles[plate].beingDriven = true
        end
    end
end)

-- Handle player exiting a vehicle
RegisterNetEvent('dps-vehiclepersistence:vehicleExited', function(vehicleData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid

    -- Check if player owns this vehicle
    if vehicleData.citizenid ~= citizenid then return end

    -- Check blacklists
    if IsBlacklisted(vehicleData.model) then return end
    if IsJobBlacklisted(citizenid) then return end

    -- Count player's world vehicles
    local count = 0
    for plate, veh in pairs(worldVehicles) do
        if veh.citizenid == citizenid and not veh.beingDriven then
            count = count + 1
        end
    end

    -- Check max vehicles limit
    if count >= Config.MaxVehiclesPerPlayer then
        -- Remove oldest vehicle
        local oldest = nil
        local oldestTime = math.huge
        for plate, veh in pairs(worldVehicles) do
            if veh.citizenid == citizenid and veh.savedAt and veh.savedAt < oldestTime then
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
        citizenid = citizenid,
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

    -- Save to database
    SaveVehicleToDB(worldVehicles[vehicleData.plate])

    if Config.Debug then
        print('^2[dps-vehiclepersistence] Vehicle parked: ' .. vehicleData.plate .. ' by ' .. citizenid)
    end
end)

-- Handle vehicle stored in garage
RegisterNetEvent('dps-vehiclepersistence:vehicleStored', function(plate)
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
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid

    -- Save all vehicles the player was near/driving
    if playerVehicles[citizenid] then
        for plate, netId in pairs(playerVehicles[citizenid]) do
            -- Vehicle will be tracked by world vehicles system
            -- Mark as no longer being driven
            if worldVehicles[plate] then
                worldVehicles[plate].beingDriven = false
            end
        end
        playerVehicles[citizenid] = nil
    end

    if Config.Debug then
        print('^3[dps-vehiclepersistence] Player disconnected: ' .. citizenid)
    end
end)

-- Handle vehicle destroyed/deleted
RegisterNetEvent('dps-vehiclepersistence:vehicleDestroyed', function(plate)
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
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- Check if player is police/tow job
    local job = Player.PlayerData.job.name
    if job ~= 'police' and job ~= 'sheriff' and job ~= 'tow' and job ~= 'mechanic' then
        return
    end

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
QBCore.Commands.Add('clearworldvehicles', 'Clear all persisted world vehicles (Admin)', {}, false, function(source, args)
    MySQL.query('DELETE FROM dps_world_vehicles')
    worldVehicles = {}

    TriggerClientEvent('ox_lib:notify', source, {
        title = 'Vehicles Cleared',
        description = 'All persisted world vehicles have been removed',
        type = 'success'
    })

    print('^1[dps-vehiclepersistence] All world vehicles cleared by admin')
end, 'admin')

-- Admin command to list persisted vehicles
QBCore.Commands.Add('listworldvehicles', 'List all persisted world vehicles (Admin)', {}, false, function(source, args)
    local vehicles = MySQL.query.await('SELECT plate, citizenid, model FROM dps_world_vehicles')

    if not vehicles or #vehicles == 0 then
        TriggerClientEvent('ox_lib:notify', source, {
            title = 'World Vehicles',
            description = 'No persisted vehicles found',
            type = 'inform'
        })
        return
    end

    print('^3=== Persisted World Vehicles ===')
    for _, veh in ipairs(vehicles) do
        print(string.format('^7[%s] %s - Owner: %s', veh.plate, veh.model, veh.citizenid))
    end
    print('^3Total: ' .. #vehicles .. ' vehicles')

    TriggerClientEvent('ox_lib:notify', source, {
        title = 'World Vehicles',
        description = #vehicles .. ' vehicles persisted (check console)',
        type = 'success'
    })
end, 'admin')

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
    state:set('dps:owner', vehicleData.citizenid, true)
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
