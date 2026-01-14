-- DPS Vehicle Persistence - Client
-- Tracks vehicles and sends data to server for persistence
-- Framework: QB/QBX/ESX (via Bridge)

local currentVehicle = nil
local lastVehicle = nil
local isOwner = false

-- Tiered throttling system
local ThrottleTiers = {
    DRIVING = 100,      -- In vehicle or <10m from owned vehicle
    NEARBY = 500,       -- 10-20m from owned vehicle
    WALKING = 2000,     -- 20-100m from any tracked vehicle
    DISTANT = 5000      -- >100m from all tracked vehicles
}

-- Get dynamic wait interval based on player state
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
        local dist = #(playerCoords - vehCoords)

        if dist < 10.0 then
            return ThrottleTiers.DRIVING
        elseif dist < 20.0 then
            return ThrottleTiers.NEARBY
        end
    end

    -- Check for any nearby vehicles in game pool
    local vehicles = GetGamePool('CVehicle')
    local closestDist = 999.0

    for _, vehicle in ipairs(vehicles) do
        if DoesEntityExist(vehicle) then
            local vehCoords = GetEntityCoords(vehicle)
            local dist = #(playerCoords - vehCoords)
            if dist < closestDist then
                closestDist = dist
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

-- Get fuel level (supports multiple fuel systems)
local function GetVehicleFuel(vehicle)
    if not vehicle or vehicle == 0 then return 100.0 end

    -- Try ox_fuel
    local success, fuel = pcall(function()
        return exports.ox_fuel:GetFuel(vehicle)
    end)
    if success and fuel then return fuel end

    -- Try LegacyFuel
    success, fuel = pcall(function()
        return exports.LegacyFuel:GetFuel(vehicle)
    end)
    if success and fuel then return fuel end

    -- Try cdn-fuel
    success, fuel = pcall(function()
        return exports['cdn-fuel']:GetFuel(vehicle)
    end)
    if success and fuel then return fuel end

    -- Try ps-fuel
    success, fuel = pcall(function()
        return exports['ps-fuel']:GetFuel(vehicle)
    end)
    if success and fuel then return fuel end

    -- Fallback to native (may not be accurate)
    return GetVehicleFuelLevel(vehicle)
end

-- Check if player owns this vehicle using server callback
local function IsVehicleOwner(vehicle, plate)
    local owned = lib.callback.await('dps-vehiclepersistence:checkOwnership', false, plate)
    return owned or false
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
local GARAGE_SPAWN_GRACE_PERIOD = 5000 -- 5 seconds

-- Check if vehicle was recently spawned from garage (skip persistence save)
local function IsGarageSpawned(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) then return false end
    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    local data = garageSpawnedVehicles[netId]
    if data then
        if GetGameTimer() - data.spawnTime < GARAGE_SPAWN_GRACE_PERIOD then
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

                -- Get model name
                local modelName = GetDisplayNameFromVehicleModel(model)

                -- Send to server
                local vehicleData = {
                    netId = netId,
                    plate = plate,
                    model = modelName,
                    identifier = Bridge.GetIdentifier(),
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

-- Handle vehicle destruction
CreateThread(function()
    while true do
        Wait(5000) -- Check every 5 seconds

        local vehicles = GetGamePool('CVehicle')
        for _, vehicle in ipairs(vehicles) do
            if DoesEntityExist(vehicle) then
                local health = GetEntityHealth(vehicle)
                local engineHealth = GetVehicleEngineHealth(vehicle)

                -- Check if vehicle is destroyed
                if health == 0 or IsEntityDead(vehicle) or IsVehicleDriveable(vehicle) == false and engineHealth < 0 then
                    local plate = GetVehicleNumberPlateText(vehicle)
                    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

                    if plate and plate ~= '' then
                        TriggerServerEvent('dps-vehiclepersistence:vehicleDestroyed', plate)

                        if Config.Debug then
                            print('[dps-vehiclepersistence] Vehicle destroyed: ' .. plate)
                        end
                    end
                end
            end
        end
    end
end)

-- Server requests vehicle properties
RegisterNetEvent('dps-vehiclepersistence:getProps', function(netId)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle and DoesEntityExist(vehicle) then
        local props = GetVehicleProperties(vehicle)
        TriggerServerEvent('dps-vehiclepersistence:receiveProps', netId, props)
    end
end)

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

    -- Apply fuel
    if fuel then
        local success = pcall(function()
            exports.ox_fuel:SetFuel(vehicle, fuel)
        end)
        if not success then
            pcall(function()
                exports.LegacyFuel:SetFuel(vehicle, fuel)
            end)
        end
    end

    if Config.Debug then
        print('[dps-vehiclepersistence] Applied props to vehicle: ' .. netId)
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

-- Track vehicles we've already requested props for
local propsRequested = {}

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

        for _, vehicle in ipairs(vehicles) do
            if requestCount >= maxRequestsPerTick then break end

            if DoesEntityExist(vehicle) then
                local vehCoords = GetEntityCoords(vehicle)
                local dist = #(coords - vehCoords)

                -- Only request props within render distance
                if dist < checkDistance then
                    local plate = GetVehicleNumberPlateText(vehicle)
                    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

                    if plate and plate ~= '' and not propsRequested[plate] then
                        propsRequested[plate] = true
                        requestCount = requestCount + 1
                        TriggerServerEvent('dps-vehiclepersistence:requestProps', plate)

                        if Config.Debug then
                            print('[dps-vehiclepersistence] Requested props for: ' .. plate .. ' (dist: ' .. math.floor(dist) .. 'm)')
                        end
                    end
                end
            end
        end
    end
end)

-- ============================================
-- STATE BAG INTEGRATION
-- Read persistence data without server events
-- ============================================

-- Check if vehicle is persisted using state bag (faster than server callback)
local function IsVehiclePersistedLocal(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) then return false end
    local state = Entity(vehicle).state
    return state['dps:persisted'] == true
end

-- Get vehicle owner from state bag
local function GetVehicleOwnerLocal(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) then return nil end
    local state = Entity(vehicle).state
    return state['dps:owner']
end

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

-- ox_target integration for towing
if Config.Debug then
    print('[dps-vehiclepersistence] Client initialized')
end
