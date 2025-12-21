-- DPS Vehicle Persistence - Client
-- Tracks vehicles and sends data to server for persistence

local QBCore = exports['qb-core']:GetCoreObject()
local currentVehicle = nil
local lastVehicle = nil
local isOwner = false

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

-- Thread to detect vehicle entry/exit
CreateThread(function()
    while true do
        Wait(500)

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

            if exitedVehicle and DoesEntityExist(exitedVehicle) and isOwner then
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
                    citizenid = QBCore.Functions.GetPlayerData().citizenid,
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

-- Listen for garage storage events
RegisterNetEvent('qb-garage:client:vehicleStore', function()
    -- Vehicle is being stored in garage
    local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
    if vehicle and vehicle ~= 0 then
        local plate = GetVehicleNumberPlateText(vehicle)
        plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")
        TriggerServerEvent('dps-vehiclepersistence:vehicleStored', plate)
    end
end)

-- Listen for jg-advancedgarages storage
RegisterNetEvent('jg-advancedgarages:client:VehicleStored', function(data)
    if data and data.plate then
        TriggerServerEvent('dps-vehiclepersistence:vehicleStored', data.plate)
    end
end)

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

-- Thread to detect nearby persisted vehicles and request props
CreateThread(function()
    while true do
        Wait(2000)

        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)

        local vehicles = GetGamePool('CVehicle')
        for _, vehicle in ipairs(vehicles) do
            if DoesEntityExist(vehicle) then
                local vehCoords = GetEntityCoords(vehicle)
                local dist = #(coords - vehCoords)

                -- When within 50 units, request props if not already done
                if dist < 50.0 then
                    local plate = GetVehicleNumberPlateText(vehicle)
                    plate = string.gsub(plate, "^%s*(.-)%s*$", "%1")

                    if plate and plate ~= '' and not propsRequested[plate] then
                        propsRequested[plate] = true
                        TriggerServerEvent('dps-vehiclepersistence:requestProps', plate)

                        if Config.Debug then
                            print('[dps-vehiclepersistence] Requested props for: ' .. plate)
                        end
                    end
                end
            end
        end
    end
end)

-- ox_target integration for towing
if Config.Debug then
    print('[dps-vehiclepersistence] Client initialized')
end
