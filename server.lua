-- DPS Vehicle Persistence - Server
-- Realistic vehicle world persistence system
-- Framework: QB/QBX/ESX (via Bridge)

local worldVehicles = {}  -- Track vehicles in the world
local playerVehicles = {} -- Track which vehicles belong to which player
local vehiclePropsQueue = {} -- Queue for vehicles needing props applied
local liveDriving = {}    -- [src] = last validated live vehicle payload while driving (for disconnect-save)
local srcIdentifiers = {} -- [src] = identifier, cached so playerDropped can still resolve it

-- Drop any cached live-driving payload for a plate. Storing a vehicle from inside
-- it deletes the entity, so the client never fires vehicleExited and the payload
-- stayed cached; the disconnect flush then re-inserted the row and the car existed
-- in the world AND in the garage. Called from RemoveVehicleFromDB so every removal
-- path (stored / destroyed / towed / excluded / admin) is covered.
local function InvalidateLiveDriving(plate)
    for s, live in pairs(liveDriving) do
        if live and live.plate == plate then
            liveDriving[s] = nil
        end
    end
end
local ownerCheckCache = {} -- [identifier|plate] = { owned = bool, t = os.time() } server-side ownership cache

-- Vehicle-control coordination tables (declared here so the save path can see them)
local jobVehicles = {}    -- [plate] = { resource, reason, timestamp } permanent exclusions
local lockedVehicles = {} -- [plate] = { resource, locked_at } temporary locks

-- Forward declarations for state bag functions
local SetVehicleStateBag, ClearVehicleStateBag

-- ============================================
-- INPUT VALIDATION / SANITIZATION (untrusted client payloads)
-- ============================================

-- Valid CreateVehicleServerSetter types
local VALID_VEHICLE_TYPES = {
    automobile = true, bike = true, boat = true, heli = true, plane = true,
    trailer = true, train = true, submarine = true, submarinecar = true,
    quadbike = true, blimp = true, amphibious_automobile = true,
    amphibious_quadbike = true, heli_blade = true
}

local function SanitizePlate(plate)
    if type(plate) ~= 'string' then return nil end
    plate = plate:gsub('^%s*(.-)%s*$', '%1')
    if #plate == 0 or #plate > 8 then return nil end
    if plate:match('[^%w]') then return nil end -- alphanumeric only
    return plate
end

local function ClampNumber(v, minV, maxV, default)
    if type(v) ~= 'number' or v ~= v then return default end -- reject non-number / NaN
    if v < minV then return minV end
    if v > maxV then return maxV end
    return v
end

local function ValidateCoords(coords)
    if type(coords) ~= 'table' then return nil end
    local x, y, z = coords.x, coords.y, coords.z
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
    if x ~= x or y ~= y or z ~= z then return nil end -- NaN
    if math.abs(x) > 10000.0 or math.abs(y) > 10000.0 or z < -1000.0 or z > 5000.0 then return nil end
    return { x = x + 0.0, y = y + 0.0, z = z + 0.0 }
end

-- props are re-applied to nearby players on restore, so treat as fully untrusted:
-- must be a table, bounded key count, bounded nesting depth, no functions/threads/userdata.
local function ValidateProps(props, depth)
    depth = depth or 0
    if props == nil then return {} end
    if type(props) ~= 'table' then return nil end
    if depth > 4 then return nil end
    local count = 0
    for _, v in pairs(props) do
        count = count + 1
        if count > 250 then return nil end
        local tv = type(v)
        if tv == 'table' then
            if ValidateProps(v, depth + 1) == nil then return nil end
        elseif tv == 'function' or tv == 'thread' or tv == 'userdata' then
            return nil
        end
    end
    return props
end

local function SanitizeVehicleType(vtype)
    if type(vtype) == 'string' and VALID_VEHICLE_TYPES[vtype] then
        return vtype
    end
    return 'automobile'
end

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

    -- Await the CREATE so we never SELECT against a missing table (#6).
    MySQL.query.await([[
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
            UNIQUE KEY `plate_unique` (`plate`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- Migrate older installs that predate the vehicle_type column (#7).
    local col = MySQL.query.await([[
        SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'dps_world_vehicles'
          AND COLUMN_NAME = 'vehicle_type'
    ]])
    if not col or #col == 0 then
        MySQL.query.await("ALTER TABLE `dps_world_vehicles` ADD COLUMN `vehicle_type` VARCHAR(24) NOT NULL DEFAULT 'automobile'")
        if Config.Debug then
            print('^3[dps-vehiclepersistence] Added vehicle_type column to existing table')
        end
    end

    if Config.Debug then
        print('^2[dps-vehiclepersistence] Database table initialized')
    end

    -- Spawn persisted vehicles (SELECT has its own bounded retry loop, #6).
    if Config.PersistThroughRestart then
        SpawnPersistedVehicles()
    end
end)

-- Check if vehicle model is blacklisted.
-- The client sends the resolved display/spawn name (e.g. "POLICE"), so compare directly.
local function IsBlacklisted(modelName)
    if type(modelName) ~= 'string' then return false end
    modelName = string.lower(modelName)
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

-- Does this source hold admin/staff permissions? (independent of Config.AdminExempt)
-- Used both for persistence-exemption AND as the permission gate on client-reachable events.
local function HasAdminPerms(source)
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

-- Check if player is staff (exempt from persistence saving)
local function IsPlayerAdmin(source)
    if not Config.AdminExempt then return false end
    return HasAdminPerms(source)
end

-- Server-side ownership check with a short TTL cache (avoids DB spam on live updates).
local function CachedOwnership(source, identifier, plate)
    local key = (identifier or ('src:' .. tostring(source))) .. '|' .. plate
    local now = os.time()
    local cached = ownerCheckCache[key]
    if cached and (now - cached.t) < (Config.OwnershipCacheDuration or 30) then
        return cached.owned
    end
    local owned = Bridge.CheckVehicleOwnership(source, plate) and true or false
    ownerCheckCache[key] = { owned = owned, t = now }
    return owned
end

-- May this client mutate persistence state for `plate`? (owns it, or is admin)
local function ClientMayMutate(source, plate)
    if HasAdminPerms(source) then return true end
    return Bridge.CheckVehicleOwnership(source, plate)
end

-- Callback for client to check admin status
lib.callback.register('dps-vehiclepersistence:isAdmin', function(source)
    return IsPlayerAdmin(source)
end)

-- Save a single vehicle to database
local function SaveVehicleToDB(vehicleData)
    if not vehicleData or not vehicleData.plate then return false end

    -- worldVehicles entries key the owner as `identifier`; the save payload uses
    -- `citizenid`. Accept either so the shutdown/live paths both persist correctly.
    local ownerId = vehicleData.citizenid or vehicleData.identifier
    if not ownerId then return false end

    MySQL.insert([[
        INSERT INTO dps_world_vehicles (plate, citizenid, model, vehicle_type, coords, heading, props, fuel, body, engine, saved_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
        ON DUPLICATE KEY UPDATE
            vehicle_type = VALUES(vehicle_type),
            coords = VALUES(coords),
            heading = VALUES(heading),
            props = VALUES(props),
            fuel = VALUES(fuel),
            body = VALUES(body),
            engine = VALUES(engine),
            saved_at = NOW()
    ]], {
        vehicleData.plate,
        ownerId,
        vehicleData.model,
        vehicleData.vehicleType or 'automobile',
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
    InvalidateLiveDriving(plate)
    MySQL.query('DELETE FROM dps_world_vehicles WHERE plate = ?', {plate})
    if Config.Debug then
        print('^1[dps-vehiclepersistence] Removed vehicle from DB: ' .. plate)
    end
end

-- Spawn all persisted vehicles on server start
function SpawnPersistedVehicles()
    -- Bounded retry against the (remote) DB instead of a blind fixed sleep (#6).
    local vehicles = nil
    for attempt = 1, 6 do
        local ok, res = pcall(function()
            return MySQL.query.await('SELECT * FROM dps_world_vehicles')
        end)
        if ok and res then
            vehicles = res
            break
        end
        if Config.Debug then
            print('^3[dps-vehiclepersistence] Initial SELECT not ready (attempt ' .. attempt .. '/6), retrying...')
        end
        Wait(2000)
    end

    if not vehicles then
        print('^1[dps-vehiclepersistence] Could not load persisted vehicles from DB after retries')
        return
    end

    if #vehicles == 0 then
        print('^2[dps-vehiclepersistence] No persisted vehicles to spawn')
        return
    end

    print('^3[dps-vehiclepersistence] Spawning ' .. #vehicles .. ' persisted vehicles...')

    local spawned = 0
    for _, veh in ipairs(vehicles) do
        local coords = json.decode(veh.coords)
        local props = json.decode(veh.props or '{}')
        local vehType = SanitizeVehicleType(veh.vehicle_type)

        -- Spawn the vehicle using its stored/derived setter type (#7)
        local modelHash = joaat(veh.model)
        local vehicle = CreateVehicleServerSetter(modelHash, vehType, coords.x, coords.y, coords.z, veh.heading)

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
                    vehicleType = vehType,
                    plate = veh.plate,
                    coords = { x = coords.x, y = coords.y, z = coords.z },
                    heading = veh.heading,
                    fuel = veh.fuel,
                    body = veh.body,
                    engine = veh.engine,
                    props = props,
                    -- restoredAt fallback so MaxVehiclesPerPlayer eviction can order DB-restored rows (#11)
                    savedAt = os.time(),
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
RegisterNetEvent('dps-vehiclepersistence:vehicleEntered', function(netId, plate, _clientIsOwner)
    if Config.Enabled == false then return end
    local src = source
    if IsPlayerAdmin(src) then return end -- Admin exempt

    local identifier = Bridge.GetIdentifier(src)
    if not identifier then return end
    srcIdentifiers[src] = identifier

    -- The plate and the ownership flag both came from the client. An arbitrary
    -- plate marked isOwner=true was recorded as beingDriven, which excludes it
    -- from the shutdown save and from EnforceVehicleLimit - a way to bypass
    -- MaxVehiclesPerPlayer - and grew playerVehicles unboundedly. Sanitise the
    -- plate and resolve ownership on the server instead.
    plate = SanitizePlate(plate)
    if not plate then return end

    local isOwner = ClientMayMutate(src, plate)

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

-- Validate + sanitize an untrusted client vehicle payload (#2). Server-authoritative:
-- returns a clean table or nil. `useCache` uses the short-TTL ownership cache (live updates).
local function ValidateVehiclePayload(src, vehicleData, useCache)
    if type(vehicleData) ~= 'table' then return nil end

    local identifier = Bridge.GetIdentifier(src)
    if not identifier then return nil end

    local plate = SanitizePlate(vehicleData.plate)
    if not plate then return nil end

    -- SERVER-SIDE ownership check — never trust the client's identifier field (#2)
    local owns
    if useCache then
        owns = CachedOwnership(src, identifier, plate)
    else
        owns = Bridge.CheckVehicleOwnership(src, plate)
    end
    if not owns then return nil end

    -- Exclusion / lock guard (job vehicles, rentals, active tow/mechanic work)
    if jobVehicles[plate] or lockedVehicles[plate] then return nil end

    local model = vehicleData.model
    if type(model) ~= 'string' or #model == 0 or #model > 50 then return nil end

    if IsBlacklisted(model) then return nil end
    if IsJobBlacklisted(identifier) then return nil end

    local coords = ValidateCoords(vehicleData.coords)
    if not coords then return nil end

    local props = ValidateProps(vehicleData.props)
    if props == nil then return nil end -- explicit table check; {} is valid

    return {
        plate = plate,
        citizenid = identifier,      -- always server-derived
        identifier = identifier,
        model = model,
        vehicleType = SanitizeVehicleType(vehicleData.vehicleType),
        netId = vehicleData.netId,
        coords = coords,
        heading = ClampNumber(vehicleData.heading, -360.0, 360.0, 0.0),
        props = props,
        fuel = ClampNumber(vehicleData.fuel, 0.0, 100.0, 100.0),
        body = ClampNumber(vehicleData.body, 0.0, 1000.0, 1000.0),
        engine = ClampNumber(vehicleData.engine, -4000.0, 1000.0, 1000.0)
    }
end

-- Enforce MaxVehiclesPerPlayer by evicting the oldest tracked world vehicle for this owner.
local function EnforceVehicleLimit(identifier, excludePlate)
    local count = 0
    for _, veh in pairs(worldVehicles) do
        if veh.identifier == identifier and not veh.beingDriven then
            count = count + 1
        end
    end

    if count >= (Config.MaxVehiclesPerPlayer or 5) then
        local oldest, oldestTime = nil, math.huge
        for plate, veh in pairs(worldVehicles) do
            if veh.identifier == identifier and plate ~= excludePlate then
                local t = veh.savedAt or 0
                if t < oldestTime then
                    oldest, oldestTime = plate, t
                end
            end
        end
        if oldest then
            RemoveVehicleFromDB(oldest)
            worldVehicles[oldest] = nil
        end
    end
end

-- Persist a validated payload to memory + DB (shared by exit-save and disconnect-save).
local function PersistWorldVehicle(clean)
    EnforceVehicleLimit(clean.identifier, clean.plate)

    worldVehicles[clean.plate] = {
        netId = clean.netId,
        identifier = clean.identifier,
        model = clean.model,
        vehicleType = clean.vehicleType,
        plate = clean.plate,
        coords = clean.coords,
        heading = clean.heading,
        props = clean.props,
        fuel = clean.fuel,
        body = clean.body,
        engine = clean.engine,
        savedAt = os.time(),
        beingDriven = false
    }

    SaveVehicleToDB(clean) -- clean.citizenid is the server-derived identifier
end

-- Handle player exiting a vehicle
RegisterNetEvent('dps-vehiclepersistence:vehicleExited', function(vehicleData)
    if Config.Enabled == false then return end
    local src = source
    if IsPlayerAdmin(src) then return end -- Admin exempt

    local clean = ValidateVehiclePayload(src, vehicleData, false)
    if not clean then return end

    liveDriving[src] = nil -- they parked it; no longer "driving"
    PersistWorldVehicle(clean)

    if Config.Debug then
        print('^2[dps-vehiclepersistence] Vehicle parked: ' .. clean.plate .. ' by ' .. clean.identifier)
    end
end)

-- Live state push while driving an owned vehicle. Cached so a disconnect mid-drive
-- still persists the vehicle (#12). Ownership is verified (cached TTL) so this cannot
-- be used to inject an arbitrary plate.
RegisterNetEvent('dps-vehiclepersistence:updateLiveState', function(vehicleData)
    if Config.Enabled == false then return end
    local src = source
    if IsPlayerAdmin(src) then return end

    local clean = ValidateVehiclePayload(src, vehicleData, true)
    if not clean then return end

    srcIdentifiers[src] = clean.identifier
    liveDriving[src] = clean
end)

-- Handle vehicle stored in garage (removes from world persistence).
-- Client-reachable → must own the plate or be admin (#3).
RegisterNetEvent('dps-vehiclepersistence:vehicleStored', function(plate)
    if Config.Enabled == false then return end
    local src = source
    plate = SanitizePlate(plate)
    if not plate then return end
    if not ClientMayMutate(src, plate) then return end

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
    -- qb/qbx/esx remove the player object in their OWN playerDropped handler,
    -- which runs first, so Bridge.GetIdentifier returned nil here and every
    -- cleanup below was dead code. Fall back to the cached identifier.
    local identifier = Bridge.GetIdentifier(src) or srcIdentifiers[src]

    -- Disconnect-while-driving persistence (#12): flush the last validated live payload.
    local live = liveDriving[src]
    -- Only flush a vehicle still tracked as a world vehicle; if it was stored,
    -- destroyed, towed or excluded since the payload was cached, re-persisting
    -- it would duplicate the car.
    if live and not worldVehicles[live.plate] then
        liveDriving[src] = nil
        live = nil
    end
    if live then
        PersistWorldVehicle(live)
        liveDriving[src] = nil
        if Config.Debug then
            print('^2[dps-vehiclepersistence] Disconnect-saved driven vehicle: ' .. live.plate)
        end
    end

    srcIdentifiers[src] = nil

    if identifier and playerVehicles[identifier] then
        for plate, _ in pairs(playerVehicles[identifier]) do
            if worldVehicles[plate] then
                worldVehicles[plate].beingDriven = false
            end
        end
        playerVehicles[identifier] = nil
    end

    -- Drop this player's cached ownership entries
    if identifier then
        local prefix = identifier .. '|'
        for key in pairs(ownerCheckCache) do
            if key:sub(1, #prefix) == prefix then
                ownerCheckCache[key] = nil
            end
        end
    end

    if Config.Debug and identifier then
        print('^3[dps-vehiclepersistence] Player disconnected: ' .. identifier)
    end
end)

-- Handle vehicle destroyed/deleted. Client-reachable → must own the plate or be admin (#3, #4).
RegisterNetEvent('dps-vehiclepersistence:vehicleDestroyed', function(plate)
    if Config.Enabled == false then return end
    local src = source
    plate = SanitizePlate(plate)
    if not plate then return end
    if not worldVehicles[plate] then return end
    if not ClientMayMutate(src, plate) then return end

    RemoveVehicleFromDB(plate)
    worldVehicles[plate] = nil

    if Config.Debug then
        print('^1[dps-vehiclepersistence] Vehicle destroyed: ' .. plate)
    end
end)

-- Tow/impound a vehicle (removes from persistence)
RegisterNetEvent('dps-vehiclepersistence:towVehicle', function(plate)
    local src = source
    plate = SanitizePlate(plate)
    if not plate then return end

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

-- Delete all spawned world-vehicle entities when THIS resource stops (#5).
-- Without this, a restart reloads every DB row while the previously-spawned entities
-- linger, so duplicates accumulate on each restart.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    local deleted = 0
    for _, veh in pairs(worldVehicles) do
        local ent = veh.entity
        if (not ent or ent == 0 or not DoesEntityExist(ent)) and veh.netId then
            ent = NetworkGetEntityFromNetworkId(veh.netId)
        end
        if ent and ent ~= 0 and DoesEntityExist(ent) then
            DeleteEntity(ent)
            deleted = deleted + 1
        end
    end

    if deleted > 0 then
        print('^3[dps-vehiclepersistence] Cleaned up ' .. deleted .. ' spawned entities on resource stop')
    end
end)

-- ============================================
-- VEHICLE TIMEOUT (hard expiry of stale parked vehicles) (#16)
-- Config.VehicleTimeout is in MINUTES; 0 = infinite. A vehicle's saved_at is
-- refreshed every park/live-update, so only genuinely abandoned vehicles expire.
-- ============================================
CreateThread(function()
    if Config.Enabled == false then return end
    if not Config.VehicleTimeout or Config.VehicleTimeout <= 0 then return end

    local timeoutMinutes = Config.VehicleTimeout
    local checkInterval = math.max(60000, math.min(timeoutMinutes * 60000, 300000)) -- 1-5 min cadence

    while true do
        Wait(checkInterval)

        local expired = MySQL.query.await([[
            SELECT plate FROM dps_world_vehicles
            WHERE saved_at < DATE_SUB(NOW(), INTERVAL ? MINUTE)
        ]], { timeoutMinutes })

        if expired and #expired > 0 then
            for _, row in ipairs(expired) do
                local plate = row.plate
                local veh = worldVehicles[plate]
                if veh then
                    local ent = veh.entity
                    if (not ent or ent == 0 or not DoesEntityExist(ent)) and veh.netId then
                        ent = NetworkGetEntityFromNetworkId(veh.netId)
                    end
                    if ent and ent ~= 0 and DoesEntityExist(ent) then
                        DeleteEntity(ent)
                    end
                    worldVehicles[plate] = nil
                end
                RemoveVehicleFromDB(plate)
            end
            print('^3[dps-vehiclepersistence] Expired ' .. #expired .. ' parked vehicles past VehicleTimeout (' .. timeoutMinutes .. ' min)')
        end
    end
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
-- (jobVehicles / lockedVehicles are declared at the top of the file so the
--  save path can consult them.)
-- ============================================

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

-- ═══════════════════════════════════════════════════════
-- CLIENT-REACHABLE EVENT MIRRORS (#3)
-- Other RESOURCES should call the exports above (server-to-server, trusted).
-- These net mirrors exist for client-side integrations (rentals, admin menus),
-- so every one is gated: the source must OWN the plate or be an admin. Without
-- this gate any client could exclude/lock/DELETE any player's persisted vehicle.
-- ═══════════════════════════════════════════════════════
RegisterNetEvent('dps-vehiclepersistence:excludeVehicle', function(plate, reason)
    local src = source
    plate = SanitizePlate(plate)
    if not plate then return end
    if not ClientMayMutate(src, plate) then return end
    exports['dps-vehiclepersistence']:ExcludeFromPersistence(plate, 'client', type(reason) == 'string' and reason or 'client')
end)

RegisterNetEvent('dps-vehiclepersistence:removeExclusion', function(plate)
    local src = source
    plate = SanitizePlate(plate)
    if not plate then return end
    if not ClientMayMutate(src, plate) then return end
    exports['dps-vehiclepersistence']:RemoveExclusion(plate)
end)

RegisterNetEvent('dps-vehiclepersistence:lockVehicle', function(plate)
    local src = source
    plate = SanitizePlate(plate)
    if not plate then return end
    if not ClientMayMutate(src, plate) then return end
    exports['dps-vehiclepersistence']:LockVehicle(plate, 'client')
end)

RegisterNetEvent('dps-vehiclepersistence:unlockVehicle', function(plate)
    local src = source
    plate = SanitizePlate(plate)
    if not plate then return end
    if not ClientMayMutate(src, plate) then return end
    exports['dps-vehiclepersistence']:UnlockVehicle(plate)
end)

RegisterNetEvent('dps-vehiclepersistence:notifyHandled', function(plate, action)
    local src = source
    plate = SanitizePlate(plate)
    if not plate then return end
    -- 'deleted'/'stored'/'impounded' all call RemoveVehicleFromDB — must own or be admin.
    if not ClientMayMutate(src, plate) then return end
    exports['dps-vehiclepersistence']:NotifyVehicleHandled(plate, action, 'client')
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
