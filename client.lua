-- DPS Vehicle Persistence - Client
-- Tracks vehicles and sends data to server for persistence
-- Framework: QB/QBX/ESX (via Bridge)

local currentVehicle = nil
local lastVehicle = nil
local lastVehicleCoords = nil  -- Cache last vehicle position
local isOwner = false

-- Ownership cache to prevent DB spam
local ownershipCache = {}
local OWNERSHIP_CACHE_DURATION = 30000  -- Default 30 seconds, overridden by Config

-- Tiered throttling system
local ThrottleTiers = {
    DRIVING = 100,      -- In vehicle or <10m from owned vehicle
    NEARBY = 500,       -- 10-20m from owned vehicle
    WALKING = 2000,     -- 20-100m from any tracked vehicle
    DISTANT = 5000      -- >100m from all tracked vehicles
}

-- Get dynamic wait interval based on player state (OPTIMIZED)
local function GetThrottleInterval()
    local ped = PlayerPedId()
    local playerCoords = GetEntityCoords(ped)

    -- If driving, use fastest interval
    if currentVehicle and currentVehicle ~= 0 then
        return ThrottleTiers.DRIVING
    end

    -- Check distance to last vehicle (just exited)
    if lastVehicle and DoesEntityExist(lastVehicle) then
        local vehCoords = GetEntityCoords(lastVehicle)
        lastVehicleCoords = vehCoords  -- Cache for optimization
        local dist = #(playerCoords - vehCoords)

        if dist < 10.0 then
            return ThrottleTiers.DRIVING
        elseif dist < 20.0 then
            return ThrottleTiers.NEARBY
        end
    end

    -- OPTIMIZATION: If we have a cached lastVehicleCoords and player is far from it,
    -- skip the expensive GetGamePool scan and default to WALKING tier
    if lastVehicleCoords then
        local distToLast = #(playerCoords - lastVehicleCoords)
        if distToLast > 20.0 then
            -- Player is far from their last known vehicle
            -- No need to scan all vehicles in city - use WALKING tier
            return ThrottleTiers.WALKING
        end
    end

    -- Only scan game pool if player might be near a tracked vehicle
    -- (either no lastVehicle or within 20m of last known position)
    local vehicles = GetGamePool('CVehicle')
    local closestDist = 999.0

    for _, vehicle in ipairs(vehicles) do
        if DoesEntityExist(vehicle) then
            local vehCoords = GetEntityCoords(vehicle)
            local dist = #(playerCoords - vehCoords)
            if dist < closestDist then
                closestDist = dist
            end
            -- Early exit if we find something close
            if closestDist < 10.0 then
                break
            end
        end
    end

    if closestDist < 20.0 then
        return ThrottleTiers.NEARBY
    elseif closestDist < 100.0 then
        return ThrottleTiers.WALKING
    end

    return ThrottleTiers.DISTANT
end

-- Get vehicle properties using ox_lib
local function GetVehicleProperties(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return nil
    end

    return lib.getVehicleProperties(vehicle)
end

-- Detect the active fuel resource ONCE, honoring Config.FuelResource (#13).
-- Read and apply both route through this, so they can never disagree.
local detectedFuelResource = nil
local function GetFuelResource()
    if detectedFuelResource then return detectedFuelResource end

    local cfg = Config.FuelResource
    if cfg and cfg ~= 'auto' and cfg ~= 'native' then
        if GetResourceState(cfg) == 'started' then
            detectedFuelResource = cfg
            return cfg
        end
    elseif cfg == 'native' then
        detectedFuelResource = 'native'
        return 'native'
    end

    for _, res in ipairs({ 'ox_fuel', 'LegacyFuel', 'cdn-fuel', 'ps-fuel' }) do
        if GetResourceState(res) == 'started' then
            detectedFuelResource = res
            return res
        end
    end

    detectedFuelResource = 'native'
    return 'native'
end

-- Get fuel level (uses the single detected fuel resource)
local function GetVehicleFuel(vehicle)
    if not vehicle or vehicle == 0 then return 100.0 end

    local res = GetFuelResource()
    if res ~= 'native' then
        local ok, fuel = pcall(function()
            return exports[res]:GetFuel(vehicle)
        end)
        if ok and type(fuel) == 'number' then return fuel end
    end

    return GetVehicleFuelLevel(vehicle)
end

-- Set fuel level (uses the single detected fuel resource)
local function SetVehicleFuel(vehicle, fuel)
    if not vehicle or vehicle == 0 or type(fuel) ~= 'number' then return end

    local res = GetFuelResource()
    if res ~= 'native' then
        local ok = pcall(function()
            exports[res]:SetFuel(vehicle, fuel)
        end)
        if ok then return end
    end

    SetVehicleFuelLevel(vehicle, fuel + 0.0)
end

-- State-bag helpers (defined early so the destroy/live-state threads can use them)
local function IsVehiclePersistedLocal(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) then return false end
    local state = Entity(vehicle).state
    return state['dps:persisted'] == true
end

local function GetVehicleOwnerLocal(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) then return nil end
    local state = Entity(vehicle).state
    return state['dps:owner']
end

-- Check if player owns this vehicle using server callback (WITH CACHING)
local function IsVehicleOwner(vehicle, plate)
    -- Get cache duration from config or use default
    local cacheDuration = (Config.OwnershipCacheDuration or 30) * 1000

    -- Check cache first
    local cached = ownershipCache[plate]
    if cached then
        local age = GetGameTimer() - cached.timestamp
        if age < cacheDuration then
            if Config.Debug then
                print('[dps-vehiclepersistence] Ownership cache hit for: ' .. plate .. ' (owned: ' .. tostring(cached.owned) .. ')')
            end
            return cached.owned
        else
            -- Cache expired, remove it
            ownershipCache[plate] = nil
        end
    end

    -- Cache miss - query server
    local owned = lib.callback.await('dps-vehiclepersistence:checkOwnership', false, plate)
    owned = owned or false

    -- Store in cache
    ownershipCache[plate] = {
        owned = owned,
        timestamp = GetGameTimer()
    }

    if Config.Debug then
        print('[dps-vehiclepersistence] Ownership cache miss for: ' .. plate .. ' (owned: ' .. tostring(owned) .. ')')
    end

    return owned
end

-- Clear ownership cache for a specific plate (call when ownership changes)
local function ClearOwnershipCache(plate)
    if plate then
        ownershipCache[plate] = nil
    end
end

-- Alternative ownership check using ox_inventory vehicle keys (fallback)
local function HasVehicleKeys(plate)
    local success, result = pcall(function()
        return exports.ox_inventory:Search('count', 'vehiclekey', { plate = plate }) > 0
    end)
    return success and result
end

-- ============================================
-- GARAGE SPAWN TRACKING (forward declarations)
-- ============================================
local garageSpawnedVehicles = {}

-- Get grace period from config (default 10 seconds for high-ping servers)
local function GetGarageGracePeriod()
    return Config.GarageSpawnGracePeriod or 10000
end

-- Check if vehicle was recently spawned from garage (skip persistence save)
local function IsGarageSpawned(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) then return false end
    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    local data = garageSpawnedVehicles[netId]
    if data then
        local gracePeriod = GetGarageGracePeriod()
        if GetGameTimer() - data.spawnTime < gracePeriod then
            return true
        else
            -- Grace period expired, remove from tracking
            garageSpawnedVehicles[netId] = nil
        end
    end
    return false
end

-- Thread to detect vehicle entry/exit (with tiered throttling)
CreateThread(function()
    while true do
        local interval = GetThrottleInterval()
        Wait(interval)

        local ped = PlayerPedId()
        local vehicle = GetVehiclePedIsIn(ped, false)

        if vehicle ~= 0 and vehicle ~= currentVehicle then
            -- Entered a new vehicle
            currentVehicle = vehicle
            local plate = GetVehicleNumberPlateText(vehicle)
            plate = string.gsub(plate, "^%s*(.-)%s*$", "%1") -- Trim whitespace

            -- Check if we own this vehicle
            isOwner = IsVehicleOwner(vehicle, plate)

            if isOwner then
                local netId = NetworkGetNetworkIdFromEntity(vehicle)
                TriggerServerEvent('dps-vehiclepersistence:vehicleEntered', netId, plate, true)

                if Config.Debug then
                    print('[dps-vehiclepersistence] Entered owned vehicle: ' .. plate)
                end
            end

            lastVehicle = vehicle

        elseif vehicle == 0 and currentVehicle ~= nil then
            -- Exited a vehicle
            local exitedVehicle = lastVehicle

            -- Skip if vehicle was just spawned from garage (grace period)
            if exitedVehicle and IsGarageSpawned(exitedVehicle) then
                if Config.Debug then
                    print('[dps-vehiclepersistence] Skipping save - vehicle recently spawned from garage')
                end
                currentVehicle = nil
                isOwner = false
                -- Continue to next iteration
            elseif exitedVehicle and DoesEntityExist(exitedVehicle) and isOwner then
                -- Get vehicle data
                local plate = GetVehicleNumberPlateText(exitedVehicle)
                plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

                local coords = GetEntityCoords(exitedVehicle)
                local heading = GetEntityHeading(exitedVehicle)
                local model = GetEntityModel(exitedVehicle)
                local props = GetVehicleProperties(exitedVehicle)
                local fuel = GetVehicleFuel(exitedVehicle)
                local body = GetVehicleBodyHealth(exitedVehicle)
                local engine = GetVehicleEngineHealth(exitedVehicle)
                local netId = NetworkGetNetworkIdFromEntity(exitedVehicle)

                -- Get model name + setter type so the server can respawn it correctly (#7)
                local modelName = GetDisplayNameFromVehicleModel(model)
                local vehicleType = GetVehicleType(exitedVehicle)

                -- Send to server (server re-validates ownership + sanitizes everything)
                local vehicleData = {
                    netId = netId,
                    plate = plate,
                    model = modelName,
                    vehicleType = vehicleType,
                    coords = { x = coords.x, y = coords.y, z = coords.z },
                    heading = heading,
                    props = props,
                    fuel = fuel,
                    body = body,
                    engine = engine
                }

                TriggerServerEvent('dps-vehiclepersistence:vehicleExited', vehicleData)

                if Config.Debug then
                    print('[dps-vehiclepersistence] Parked vehicle: ' .. plate .. ' at ' .. coords.x .. ', ' .. coords.y .. ', ' .. coords.z)
                end
            end

            currentVehicle = nil
            isOwner = false
        end
    end
end)

-- Handle vehicle destruction.
-- Only report vehicles that are PERSISTED (state bag) AND owned by THIS player (#4),
-- to stop spam/grief. The server re-validates ownership before deleting anything.
CreateThread(function()
    local myId = nil
    while true do
        Wait(10000) -- Reduced scan frequency (was 5s)

        myId = myId or Bridge.GetIdentifier()

        local vehicles = GetGamePool('CVehicle')
        for _, vehicle in ipairs(vehicles) do
            if DoesEntityExist(vehicle) and IsVehiclePersistedLocal(vehicle) then
                local owner = GetVehicleOwnerLocal(vehicle)
                if owner and myId and owner == myId then
                    local health = GetEntityHealth(vehicle)
                    local engineHealth = GetVehicleEngineHealth(vehicle)

                    -- Check if vehicle is destroyed
                    if health == 0 or IsEntityDead(vehicle) or (IsVehicleDriveable(vehicle) == false and engineHealth < 0) then
                        local plate = GetVehicleNumberPlateText(vehicle)
                        plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

                        if plate and plate ~= '' then
                            TriggerServerEvent('dps-vehiclepersistence:vehicleDestroyed', plate)

                            if Config.Debug then
                                print('[dps-vehiclepersistence] Reported destroyed owned vehicle: ' .. plate)
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- NOTE: the old getProps/receiveProps round-trip was dead code (server never fired
-- getProps and had no receiveProps handler). Restore uses requestProps -> applyProps. (#9)

-- Apply vehicle properties when spawned from persistence
RegisterNetEvent('dps-vehiclepersistence:applyProps', function(netId, props, fuel, body, engine)
    local vehicle = NetworkGetEntityFromNetworkId(netId)

    if not vehicle or not DoesEntityExist(vehicle) then
        -- Wait for vehicle to exist
        local timeout = 0
        while (not vehicle or not DoesEntityExist(vehicle)) and timeout < 5000 do
            Wait(100)
            timeout = timeout + 100
            vehicle = NetworkGetEntityFromNetworkId(netId)
        end
    end

    if not vehicle or not DoesEntityExist(vehicle) then
        if Config.Debug then
            print('[dps-vehiclepersistence] Failed to find vehicle for props: ' .. netId)
        end
        return
    end

    -- Apply properties
    if props and next(props) then
        lib.setVehicleProperties(vehicle, props)
    end

    -- Apply damage
    if body then
        SetVehicleBodyHealth(vehicle, body)
    end
    if engine then
        SetVehicleEngineHealth(vehicle, engine)
    end

    -- Apply fuel (same detection as the read path, #13)
    if fuel then
        SetVehicleFuel(vehicle, fuel)
    end

    if Config.Debug then
        print('[dps-vehiclepersistence] Applied props to vehicle: ' .. netId)
    end
end)

-- ============================================
-- LIVE-STATE PUSH (disconnect-while-driving persistence, #12)
-- While the owner is actively driving their vehicle, push a compact snapshot to the
-- server every LIVE_STATE_INTERVAL. If they disconnect mid-drive, the server flushes
-- this cached snapshot to the DB (playerDropped), fulfilling the README's
-- "Disconnect Persistence" claim. The server re-validates ownership (cached TTL).
-- ============================================
CreateThread(function()
    local LIVE_STATE_INTERVAL = 15000
    while true do
        Wait(LIVE_STATE_INTERVAL)

        if currentVehicle and currentVehicle ~= 0 and DoesEntityExist(currentVehicle) and isOwner then
            -- Don't push freshly garage-spawned vehicles (grace period)
            if not IsGarageSpawned(currentVehicle) then
                local ped = PlayerPedId()
                -- Only when actually the driver of this vehicle
                if GetVehiclePedIsIn(ped, false) == currentVehicle and GetPedInVehicleSeat(currentVehicle, -1) == ped then
                    local coords = GetEntityCoords(currentVehicle)
                    local plate = GetVehicleNumberPlateText(currentVehicle)
                    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

                    TriggerServerEvent('dps-vehiclepersistence:updateLiveState', {
                        netId = NetworkGetNetworkIdFromEntity(currentVehicle),
                        plate = plate,
                        model = GetDisplayNameFromVehicleModel(GetEntityModel(currentVehicle)),
                        vehicleType = GetVehicleType(currentVehicle),
                        coords = { x = coords.x, y = coords.y, z = coords.z },
                        heading = GetEntityHeading(currentVehicle),
                        props = GetVehicleProperties(currentVehicle),
                        fuel = GetVehicleFuel(currentVehicle),
                        body = GetVehicleBodyHealth(currentVehicle),
                        engine = GetVehicleEngineHealth(currentVehicle)
                    })

                    if Config.Debug then
                        print('[dps-vehiclepersistence] Pushed live state for: ' .. plate)
                    end
                end
            end
        end
    end
end)

-- ============================================
-- EVENT-BASED GARAGE INTEGRATION
-- Comprehensive support for all major garage systems
-- ============================================

-- Track props requests
local propsRequested = {}

-- Helper to notify server of garage storage
local function NotifyVehicleStored(plate)
    if plate and plate ~= '' then
        plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")
        TriggerServerEvent('dps-vehiclepersistence:vehicleStored', plate)
        propsRequested[plate] = nil
        Bridge.Debug('Vehicle stored in garage: ' .. plate)
    end
end

-- Helper to mark vehicle as garage-spawned
local function MarkGarageSpawned(vehicle, plate)
    if vehicle and DoesEntityExist(vehicle) then
        local netId = NetworkGetNetworkIdFromEntity(vehicle)
        garageSpawnedVehicles[netId] = {
            plate = plate,
            spawnTime = GetGameTimer()
        }
        Bridge.Debug('Vehicle spawned from garage: ' .. plate)
    end
end

-- Helper to find vehicle by plate
local function FindVehicleByPlate(targetPlate)
    local vehicles = GetGamePool('CVehicle')
    for _, veh in ipairs(vehicles) do
        local plate = GetVehicleNumberPlateText(veh)
        plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")
        if plate == targetPlate then
            return veh
        end
    end
    return nil
end

-- ═══════════════════════════════════════════════════════
-- QB-GARAGES (QBCore Official)
-- ═══════════════════════════════════════════════════════
RegisterNetEvent('qb-garage:client:vehicleStore', function()
    local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
    if vehicle and vehicle ~= 0 then
        local plate = GetVehicleNumberPlateText(vehicle)
        NotifyVehicleStored(plate)
    end
end)

RegisterNetEvent('qb-garage:client:TakeOutVehicle', function(vehicleInfo)
    if vehicleInfo and vehicleInfo.plate then
        Wait(500)
        local veh = FindVehicleByPlate(vehicleInfo.plate)
        if veh then MarkGarageSpawned(veh, vehicleInfo.plate) end
    end
end)

-- ═══════════════════════════════════════════════════════
-- QS-ADVANCEDGARAGES (Quasar)
-- ═══════════════════════════════════════════════════════
RegisterNetEvent('qs-advancedgarages:client:vehicleStored', function(data)
    if data and data.plate then
        NotifyVehicleStored(data.plate)
    elseif type(data) == 'string' then
        NotifyVehicleStored(data)
    end
end)

RegisterNetEvent('qs-advancedgarages:client:vehicleSpawned', function(vehicle, plate)
    if vehicle and plate then
        MarkGarageSpawned(vehicle, plate)
    end
end)

-- Alternative Quasar events
RegisterNetEvent('qs-advancedgarages:vehicleStored', function(data)
    if data and data.plate then NotifyVehicleStored(data.plate) end
end)

RegisterNetEvent('qs-advancedgarages:vehicleSpawned', function(vehicle, plate)
    MarkGarageSpawned(vehicle, plate)
end)

-- ═══════════════════════════════════════════════════════
-- JG-ADVANCEDGARAGES (JG Scripts)
-- ═══════════════════════════════════════════════════════
RegisterNetEvent('jg-advancedgarages:client:VehicleStored', function(data)
    if data and data.plate then
        NotifyVehicleStored(data.plate)
    end
end)

RegisterNetEvent('jg-advancedgarages:client:vehicleSpawned', function(vehicle, plate)
    MarkGarageSpawned(vehicle, plate)
end)

-- ═══════════════════════════════════════════════════════
-- CD_GARAGE (Codesign)
-- ═══════════════════════════════════════════════════════
RegisterNetEvent('cd_garage:client:Stored', function(plate)
    NotifyVehicleStored(plate)
end)

RegisterNetEvent('cd_garage:client:Spawned', function(vehicle, plate)
    MarkGarageSpawned(vehicle, plate)
end)

RegisterNetEvent('cd_garage:StoreVehicle', function(plate)
    NotifyVehicleStored(plate)
end)

-- ═══════════════════════════════════════════════════════
-- LOAF_GARAGE (Loaf Scripts)
-- ═══════════════════════════════════════════════════════
RegisterNetEvent('loaf_garage:stored', function(plate)
    NotifyVehicleStored(plate)
end)

RegisterNetEvent('loaf_garage:spawned', function(vehicle, plate)
    MarkGarageSpawned(vehicle, plate)
end)

-- ═══════════════════════════════════════════════════════
-- OKOKGARAGE (okok Scripts)
-- ═══════════════════════════════════════════════════════
RegisterNetEvent('okokGarage:vehicleStored', function(plate)
    NotifyVehicleStored(plate)
end)

RegisterNetEvent('okokGarage:vehicleSpawned', function(vehicle, plate)
    MarkGarageSpawned(vehicle, plate)
end)

-- ═══════════════════════════════════════════════════════
-- ESX_ADVANCEDGARAGE (ESX)
-- ═══════════════════════════════════════════════════════
RegisterNetEvent('esx_advancedgarage:stored', function(plate)
    NotifyVehicleStored(plate)
end)

RegisterNetEvent('esx_advancedgarage:spawned', function(vehicle, plate)
    MarkGarageSpawned(vehicle, plate)
end)

-- ═══════════════════════════════════════════════════════
-- GENERIC / FALLBACK EVENTS
-- ═══════════════════════════════════════════════════════
RegisterNetEvent('vehiclekeys:client:SetOwner', function(plate)
    if plate then propsRequested[plate] = nil end
end)

-- Generic garage store (many scripts use this)
RegisterNetEvent('garage:vehicleStored', function(plate)
    NotifyVehicleStored(plate)
end)

RegisterNetEvent('garage:vehicleSpawned', function(vehicle, plate)
    MarkGarageSpawned(vehicle, plate)
end)

-- ═══════════════════════════════════════════════════════
-- DEALERSHIP INTEGRATIONS
-- ═══════════════════════════════════════════════════════

-- JG-Dealerships
RegisterNetEvent('jg-dealerships:client:vehiclePurchased', function(vehicleData)
    if vehicleData and vehicleData.plate then
        Wait(1000)
        local veh = FindVehicleByPlate(vehicleData.plate)
        if veh then MarkGarageSpawned(veh, vehicleData.plate) end
    end
end)

-- QS-Dealership (Quasar)
RegisterNetEvent('qs-dealership:vehiclePurchased', function(plate)
    Wait(1000)
    local veh = FindVehicleByPlate(plate)
    if veh then MarkGarageSpawned(veh, plate) end
end)

-- QB-Dealerships
RegisterNetEvent('qb-vehicleshop:client:buyShowroomVehicle', function(vehicleData)
    if vehicleData and vehicleData.plate then
        Wait(1000)
        local veh = FindVehicleByPlate(vehicleData.plate)
        if veh then MarkGarageSpawned(veh, vehicleData.plate) end
    end
end)

-- Generic dealership
RegisterNetEvent('dealership:vehiclePurchased', function(plate)
    Wait(1000)
    local veh = FindVehicleByPlate(plate)
    if veh then MarkGarageSpawned(veh, plate) end
end)

-- ═══════════════════════════════════════════════════════
-- LAW ENFORCEMENT INTEGRATIONS
-- ═══════════════════════════════════════════════════════

-- Police impound (removes from persistence)
RegisterNetEvent('police:client:ImpoundVehicle', function(plate, data)
    if plate then NotifyVehicleStored(plate) end
end)

RegisterNetEvent('ps-mdt:client:ImpoundVehicle', function(plate)
    if plate then NotifyVehicleStored(plate) end
end)

RegisterNetEvent('qb-policejob:client:ImpoundVehicle', function(plate)
    if plate then NotifyVehicleStored(plate) end
end)

-- Seized vehicles
RegisterNetEvent('police:client:SeizeVehicle', function(plate)
    if plate then NotifyVehicleStored(plate) end
end)

-- Evidence system - don't persist evidence vehicles
RegisterNetEvent('evidence:client:storeVehicle', function(plate)
    if plate then NotifyVehicleStored(plate) end
end)

-- ═══════════════════════════════════════════════════════
-- TOWING INTEGRATIONS (dps-towjob, qb-tow, etc.)
-- ═══════════════════════════════════════════════════════

-- DPS-TowJob integration
RegisterNetEvent('dps-towjob:client:vehicleTowed', function(plate)
    if plate then
        NotifyVehicleStored(plate)
        Bridge.Debug('Vehicle towed by dps-towjob: ' .. plate)
    end
end)

RegisterNetEvent('dps-towjob:client:vehicleDropped', function(vehicleData)
    if vehicleData and vehicleData.plate then
        Wait(500)
        local veh = FindVehicleByPlate(vehicleData.plate)
        if veh then MarkGarageSpawned(veh, vehicleData.plate) end
    end
end)

-- QB-Tow integration
RegisterNetEvent('qb-tow:client:VehicleTowed', function(plate)
    if plate then NotifyVehicleStored(plate) end
end)

-- Generic tow events
RegisterNetEvent('tow:client:vehicleTowed', function(plate)
    if plate then NotifyVehicleStored(plate) end
end)

RegisterNetEvent('tow:vehicleImpounded', function(plate)
    if plate then NotifyVehicleStored(plate) end
end)

-- ═══════════════════════════════════════════════════════
-- MECHANIC SHOP INTEGRATIONS
-- ═══════════════════════════════════════════════════════

-- JG-Mechanic - vehicle stored at shop
RegisterNetEvent('jg-mechanic:client:vehicleStored', function(plate)
    if plate then NotifyVehicleStored(plate) end
end)

-- QS-Mechanic
RegisterNetEvent('qs-mechanicjob:vehicleStored', function(plate)
    if plate then NotifyVehicleStored(plate) end
end)

-- ═══════════════════════════════════════════════════════
-- RENTAL VEHICLE INTEGRATIONS
-- ═══════════════════════════════════════════════════════

-- Mark rental vehicles (shouldn't persist)
RegisterNetEvent('rental:client:vehicleRented', function(vehicle, plate)
    if vehicle and plate then
        -- Mark as excluded from persistence
        TriggerServerEvent('dps-vehiclepersistence:excludeVehicle', plate, 'rental')
    end
end)

RegisterNetEvent('rental:client:vehicleReturned', function(plate)
    if plate then
        TriggerServerEvent('dps-vehiclepersistence:removeExclusion', plate)
        NotifyVehicleStored(plate)
    end
end)

-- ═══════════════════════════════════════════════════════
-- ADMIN MENU INTEGRATIONS
-- Handle vehicles spawned/deleted by admin tools
-- ═══════════════════════════════════════════════════════

-- vMenu vehicle spawn
RegisterNetEvent('vMenu:PlayerSpawnedVehicle', function(vehicle)
    if vehicle and DoesEntityExist(vehicle) then
        local plate = GetVehicleNumberPlateText(vehicle)
        -- Admin spawned vehicles should NOT persist
        TriggerServerEvent('dps-vehiclepersistence:excludeVehicle', plate, 'admin-spawn')
    end
end)

-- txAdmin/Lambda vehicle spawn
RegisterNetEvent('txAdmin:spawnedVehicle', function(vehicle, plate)
    if plate then
        TriggerServerEvent('dps-vehiclepersistence:excludeVehicle', plate, 'txadmin-spawn')
    end
end)

-- qb-adminmenu spawn
RegisterNetEvent('qb-admin:client:SpawnVehicle', function()
    Wait(500)
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle and vehicle ~= 0 then
        local plate = GetVehicleNumberPlateText(vehicle)
        TriggerServerEvent('dps-vehiclepersistence:excludeVehicle', plate, 'qb-admin-spawn')
    end
end)

-- Generic admin delete event - remove from persistence
RegisterNetEvent('admin:deleteVehicle', function(plate)
    if plate then
        TriggerServerEvent('dps-vehiclepersistence:notifyHandled', plate, 'deleted')
    end
end)

-- QBCore admin vehicle delete
RegisterNetEvent('qb-admin:client:DeleteVehicle', function()
    local ped = PlayerPedId()
    local vehicle = GetLastVehiclePedWasIn(ped)
    if vehicle and DoesEntityExist(vehicle) then
        local plate = GetVehicleNumberPlateText(vehicle)
        TriggerServerEvent('dps-vehiclepersistence:notifyHandled', plate, 'deleted')
    end
end)

-- ═══════════════════════════════════════════════════════
-- TOW VEHICLE COMMAND
-- ═══════════════════════════════════════════════════════

-- Tow vehicle command (for police/tow jobs)
RegisterNetEvent('dps-vehiclepersistence:towNearestVehicle', function()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)

    local closestVehicle = nil
    local closestDist = 10.0

    local vehicles = GetGamePool('CVehicle')
    for _, vehicle in ipairs(vehicles) do
        if DoesEntityExist(vehicle) then
            local vehCoords = GetEntityCoords(vehicle)
            local dist = #(coords - vehCoords)
            if dist < closestDist and GetPedInVehicleSeat(vehicle, -1) == 0 then
                closestVehicle = vehicle
                closestDist = dist
            end
        end
    end

    if closestVehicle then
        local plate = GetVehicleNumberPlateText(closestVehicle)
        plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")
        TriggerServerEvent('dps-vehiclepersistence:towVehicle', plate)
    else
        lib.notify({
            title = 'Tow Failed',
            description = 'No unoccupied vehicle nearby',
            type = 'error'
        })
    end
end)

-- NOTE: propsRequested is declared earlier at line ~380 (garage integration section)
-- Removed duplicate declaration here

-- Render distance thresholds for prop application
local RenderDistances = {
    IMMEDIATE = 30.0,   -- Apply props immediately when this close
    STANDARD = 75.0,    -- Normal render distance
    EXTENDED = 150.0    -- Extended check for high-density areas
}

-- Thread to detect nearby persisted vehicles and request props (render distance optimized)
CreateThread(function()
    while true do
        -- Use slower interval when no vehicles nearby
        local interval = GetThrottleInterval()
        -- Cap props check to max 2 seconds even when distant
        Wait(math.min(interval, 2000))

        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)

        -- Only process if player is on foot or moving slowly
        local playerVehicle = GetVehiclePedIsIn(ped, false)
        local checkDistance = RenderDistances.STANDARD

        -- Extend check distance when in a vehicle (driving past parked cars)
        if playerVehicle ~= 0 then
            local speed = GetEntitySpeed(playerVehicle)
            if speed > 20.0 then -- ~72 km/h
                checkDistance = RenderDistances.EXTENDED
            end
        end

        local vehicles = GetGamePool('CVehicle')
        local requestCount = 0
        local maxRequestsPerTick = 3 -- Batch limit to prevent server spam
        local now = GetGameTimer()
        local REREQUEST_COOLDOWN = 30000 -- allow a retry after 30s (failed applies self-heal)

        for _, vehicle in ipairs(vehicles) do
            if requestCount >= maxRequestsPerTick then break end

            -- Only request for PERSISTED vehicles (state bag). This is the fix for the
            -- unbounded propsRequested growth (#10): we no longer stamp every traffic
            -- car we drive past, only actual persisted ones that need props.
            if DoesEntityExist(vehicle) and IsVehiclePersistedLocal(vehicle) then
                local vehCoords = GetEntityCoords(vehicle)
                local dist = #(coords - vehCoords)

                if dist < checkDistance then
                    local plate = GetVehicleNumberPlateText(vehicle)
                    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

                    local last = propsRequested[plate]
                    if plate and plate ~= '' and (not last or (now - last) > REREQUEST_COOLDOWN) then
                        propsRequested[plate] = now -- store timestamp, not a permanent flag
                        requestCount = requestCount + 1
                        TriggerServerEvent('dps-vehiclepersistence:requestProps', plate)

                        if Config.Debug then
                            print('[dps-vehiclepersistence] Requested props for: ' .. plate .. ' (dist: ' .. math.floor(dist) .. 'm)')
                        end
                    end
                end
            end
        end

        -- Prune stale entries so the table cannot grow without bound (#10)
        local pruneOlderThan = 120000 -- 2 minutes
        local size = 0
        for plate, ts in pairs(propsRequested) do
            size = size + 1
            if (now - ts) > pruneOlderThan then
                propsRequested[plate] = nil
            end
        end
        -- Hard cap safety valve
        if size > 300 then
            propsRequested = {}
        end
    end
end)

-- ============================================
-- STATE BAG INTEGRATION
-- Read persistence data without server events
-- (IsVehiclePersistedLocal / GetVehicleOwnerLocal are defined earlier in the file)
-- ============================================

-- Update vehicle damage via state bag (reduces server events)
local function UpdateVehicleDamageStateBag(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) then return end
    if not IsVehiclePersistedLocal(vehicle) then return end

    local body = GetVehicleBodyHealth(vehicle)
    local engine = GetVehicleEngineHealth(vehicle)

    local state = Entity(vehicle).state
    state:set('dps:damage', { body = body, engine = engine }, false)
end

-- Periodic damage sync for owned vehicles (uses state bags)
CreateThread(function()
    local lastDamageSync = {}

    while true do
        Wait(10000) -- Every 10 seconds

        if currentVehicle and DoesEntityExist(currentVehicle) and isOwner then
            local body = GetVehicleBodyHealth(currentVehicle)
            local engine = GetVehicleEngineHealth(currentVehicle)

            -- Only sync if damage changed significantly
            local plate = GetVehicleNumberPlateText(currentVehicle)
            plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

            local lastSync = lastDamageSync[plate]
            if not lastSync or math.abs(lastSync.body - body) > 50 or math.abs(lastSync.engine - engine) > 50 then
                UpdateVehicleDamageStateBag(currentVehicle)
                lastDamageSync[plate] = { body = body, engine = engine }

                if Config.Debug then
                    print('[dps-vehiclepersistence] Damage synced via state bag: ' .. plate)
                end
            end
        end
    end
end)

-- ═══════════════════════════════════════════════════════
-- DSRP JOB VEHICLE INTEGRATION
-- Auto-exclude vehicles spawned by job scripts
-- ═══════════════════════════════════════════════════════

-- Helper to exclude job-spawned vehicle
local function ExcludeJobVehicle(vehicle, plate, source)
    if not vehicle or not DoesEntityExist(vehicle) then return end

    plate = plate or GetVehicleNumberPlateText(vehicle)
    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

    local reason = Config.JobVehicleExclusion and Config.JobVehicleExclusion.reason or 'job-vehicle'
    TriggerServerEvent('dps-vehiclepersistence:excludeVehicle', plate, source or reason)

    if Config.Debug then
        print('[dps-vehiclepersistence] Job vehicle excluded: ' .. plate .. ' (source: ' .. (source or reason) .. ')')
    end
end

-- Register job vehicle spawn event listeners dynamically from config
CreateThread(function()
    Wait(1000) -- Wait for config to load

    if not Config.JobVehicleExclusion or not Config.JobVehicleExclusion.enabled then
        return
    end

    local events = Config.JobVehicleExclusion.spawnEvents or {}

    for _, eventName in ipairs(events) do
        RegisterNetEvent(eventName, function(vehicleOrData, plate)
            Wait(500) -- Wait for vehicle to spawn

            local vehicle = nil

            -- Handle different event data formats
            if type(vehicleOrData) == 'number' then
                -- Direct vehicle entity passed
                vehicle = vehicleOrData
            elseif type(vehicleOrData) == 'table' and vehicleOrData.plate then
                -- Data table with plate
                plate = vehicleOrData.plate
                vehicle = FindVehicleByPlate(plate)
            else
                -- Try to find vehicle player is in
                local ped = PlayerPedId()
                vehicle = GetVehiclePedIsIn(ped, false)
                if vehicle == 0 then
                    vehicle = GetLastVehiclePedWasIn(ped)
                end
            end

            if vehicle and DoesEntityExist(vehicle) then
                ExcludeJobVehicle(vehicle, plate, eventName)
            end
        end)

        if Config.Debug then
            print('[dps-vehiclepersistence] Registered job exclusion listener: ' .. eventName)
        end
    end
end)

-- Direct DSRP Police Job integration (common patterns)
RegisterNetEvent('dps-policejob:client:VehicleSpawned', function(vehicle, plate)
    if vehicle and DoesEntityExist(vehicle) then
        ExcludeJobVehicle(vehicle, plate, 'dps-policejob')
    end
end)

RegisterNetEvent('dps-ambulancejob:client:VehicleSpawned', function(vehicle, plate)
    if vehicle and DoesEntityExist(vehicle) then
        ExcludeJobVehicle(vehicle, plate, 'dps-ambulancejob')
    end
end)

-- QBCore police job vehicle spawn
RegisterNetEvent('qb-policejob:client:VehicleSpawned', function(vehData)
    Wait(500)
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle and vehicle ~= 0 then
        local plate = vehData and vehData.plate or GetVehicleNumberPlateText(vehicle)
        ExcludeJobVehicle(vehicle, plate, 'qb-policejob')
    end
end)

-- Clear ownership cache when vehicle is sold/transferred
RegisterNetEvent('vehiclekeys:client:SetOwner', function(plate)
    if plate then
        ClearOwnershipCache(plate)
    end
end)

-- ox_target integration for towing
if Config.Debug then
    print('[dps-vehiclepersistence] Client initialized')
end
