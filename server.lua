-- DPS Vehicle Persistence - Server
-- Realistic vehicle world persistence system

local QBCore = exports['qb-core']:GetCoreObject()
local worldVehicles = {}  -- Track vehicles in the world
local playerVehicles = {} -- Track which vehicles belong to which player
local vehiclePropsQueue = {} -- Queue for vehicles needing props applied

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
                worldVehicles[veh.plate] = {
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

-- Periodic cleanup of orphaned vehicles (vehicles whose owners haven't logged in for X days)
CreateThread(function()
    while true do
        Wait(1800000) -- Every 30 minutes

        -- Clean up vehicles older than 7 days whose owners haven't been online
        local deleted = MySQL.query.await([[
            DELETE wv FROM dps_world_vehicles wv
            LEFT JOIN players p ON wv.citizenid = p.citizenid
            WHERE wv.saved_at < DATE_SUB(NOW(), INTERVAL 7 DAY)
            AND (p.last_updated IS NULL OR p.last_updated < DATE_SUB(NOW(), INTERVAL 7 DAY))
        ]])

        if Config.Debug and deleted and deleted.affectedRows > 0 then
            print('^3[dps-vehiclepersistence] Cleaned up ' .. deleted.affectedRows .. ' orphaned vehicles')
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
