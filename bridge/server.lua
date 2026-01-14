--[[
    dps-vehiclepersistence Server Bridge
    Framework Abstraction for QB/QBX/ESX
]]

local QBCore, ESX = nil, nil

-- Initialize framework objects
CreateThread(function()
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        QBCore = exports['qb-core']:GetCoreObject()
    elseif Bridge.Framework == 'esx' then
        ESX = exports['es_extended']:getSharedObject()
    end
end)

-- ═══════════════════════════════════════════════════════
-- PLAYER FUNCTIONS
-- ═══════════════════════════════════════════════════════

function Bridge.GetPlayer(source)
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return QBCore and QBCore.Functions.GetPlayer(source)
    elseif Bridge.Framework == 'esx' then
        return ESX and ESX.GetPlayerFromId(source)
    end
    return nil
end

function Bridge.GetPlayerByIdentifier(identifier)
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return QBCore and QBCore.Functions.GetPlayerByCitizenId(identifier)
    elseif Bridge.Framework == 'esx' then
        return ESX and ESX.GetPlayerFromIdentifier(identifier)
    end
    return nil
end

function Bridge.GetIdentifier(source)
    local player = Bridge.GetPlayer(source)
    if not player then return nil end

    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return player.PlayerData.citizenid
    elseif Bridge.Framework == 'esx' then
        return player.identifier
    end
    return nil
end

function Bridge.GetPlayerJob(source)
    local player = Bridge.GetPlayer(source)
    if not player then return nil end

    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return player.PlayerData.job.name
    elseif Bridge.Framework == 'esx' then
        return player.job.name
    end
    return nil
end

function Bridge.GetPermissionGroup(source)
    local player = Bridge.GetPlayer(source)
    if not player then return 'user' end

    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return player.PlayerData.group or QBCore.Functions.GetPermission(source) or 'user'
    elseif Bridge.Framework == 'esx' then
        return player.getGroup() or 'user'
    end
    return 'user'
end

-- ═══════════════════════════════════════════════════════
-- VEHICLE OWNERSHIP
-- ═══════════════════════════════════════════════════════

-- Get the identifier column name for the database
function Bridge.GetIdentifierColumn()
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return 'citizenid'
    elseif Bridge.Framework == 'esx' then
        return 'owner'
    end
    return 'citizenid'
end

-- Get player vehicles table name
function Bridge.GetVehiclesTable()
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return 'player_vehicles'
    elseif Bridge.Framework == 'esx' then
        return 'owned_vehicles'
    end
    return 'player_vehicles'
end

-- Check if player owns a vehicle
function Bridge.CheckVehicleOwnership(source, plate)
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return false end

    local column = Bridge.GetIdentifierColumn()
    local table = Bridge.GetVehiclesTable()

    local query = string.format('SELECT %s FROM %s WHERE plate = ?', column, table)
    local result = MySQL.query.await(query, { plate })

    if result and result[1] then
        return result[1][column] == identifier
    end
    return false
end

-- ═══════════════════════════════════════════════════════
-- IMPOUND / GARAGE STATE
-- ═══════════════════════════════════════════════════════

-- Set vehicle to impounded state
function Bridge.SetVehicleImpounded(plate, impoundLot, fee)
    local table = Bridge.GetVehiclesTable()

    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        -- QBCore uses state = 2 for impounded
        return MySQL.update.await([[
            UPDATE player_vehicles
            SET state = 2, garage = ?, depotprice = ?
            WHERE plate = ?
        ]], { impoundLot or 'impound', fee or 0, plate })
    elseif Bridge.Framework == 'esx' then
        -- ESX may use stored = 2 or a separate impound column
        return MySQL.update.await([[
            UPDATE owned_vehicles
            SET stored = 2, pound = ?, impoundfee = ?
            WHERE plate = ?
        ]], { impoundLot or 'impound', fee or 0, plate })
    end
    return 0
end

-- ═══════════════════════════════════════════════════════
-- NOTIFICATIONS
-- ═══════════════════════════════════════════════════════

function Bridge.Notify(source, title, message, notifyType, duration)
    notifyType = notifyType or 'inform'
    duration = duration or 5000

    -- Always use ox_lib
    TriggerClientEvent('ox_lib:notify', source, {
        title = title,
        description = message,
        type = notifyType,
        duration = duration
    })
end

-- ═══════════════════════════════════════════════════════
-- COMMANDS
-- ═══════════════════════════════════════════════════════

function Bridge.AddCommand(name, help, params, restricted, callback)
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        QBCore.Commands.Add(name, help, params or {}, false, callback, restricted and 'admin' or false)
    elseif Bridge.Framework == 'esx' then
        ESX.RegisterCommand(name, restricted and 'admin' or 'user', function(xPlayer, args, showError)
            callback(xPlayer.source, args)
        end, true, { help = help })
    else
        -- Fallback to ox_lib command
        lib.addCommand(name, {
            help = help,
            restricted = restricted and 'group.admin' or false
        }, callback)
    end
end

-- ═══════════════════════════════════════════════════════
-- PLAYER LOADED EVENTS
-- ═══════════════════════════════════════════════════════

-- Register callback for when player loads
function Bridge.OnPlayerLoaded(callback)
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
            callback(Player.PlayerData.source, Player)
        end)
    elseif Bridge.Framework == 'esx' then
        RegisterNetEvent('esx:playerLoaded', function(playerId, xPlayer)
            callback(playerId, xPlayer)
        end)
    end
end

-- Register callback for when player drops
function Bridge.OnPlayerDropped(callback)
    AddEventHandler('playerDropped', function(reason)
        local src = source
        local player = Bridge.GetPlayer(src)
        local identifier = nil

        if player then
            if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
                identifier = player.PlayerData.citizenid
            elseif Bridge.Framework == 'esx' then
                identifier = player.identifier
            end
        end

        callback(src, identifier, reason)
    end)
end
