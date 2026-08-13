--[[
    dps-vehiclepersistence Server Bridge
    Framework Abstraction for QB / QBX / ESX

    NOTE on QBX:
    This qbx_core build exposes NO GetCoreObject(). The qbx branch MUST use the
    discrete native exports (GetPlayer / GetPlayerByCitizenId / etc). GetCoreObject
    is only ever touched on the legacy 'qb' branch.
]]

local QBCore, ESX = nil, nil

-- Only the legacy qb-core path needs the shared object. qbx uses discrete exports.
if Bridge.Framework == 'qb' then
    QBCore = exports['qb-core']:GetCoreObject()
elseif Bridge.Framework == 'esx' then
    ESX = exports['es_extended']:getSharedObject()
end

-- ═══════════════════════════════════════════════════════
-- PLAYER FUNCTIONS
-- ═══════════════════════════════════════════════════════

function Bridge.GetPlayer(source)
    if Bridge.Framework == 'qbx' then
        return exports.qbx_core:GetPlayer(source)
    elseif Bridge.Framework == 'qb' then
        return QBCore and QBCore.Functions.GetPlayer(source)
    elseif Bridge.Framework == 'esx' then
        return ESX and ESX.GetPlayerFromId(source)
    end
    return nil
end

function Bridge.GetPlayerByIdentifier(identifier)
    if Bridge.Framework == 'qbx' then
        return exports.qbx_core:GetPlayerByCitizenId(identifier)
    elseif Bridge.Framework == 'qb' then
        return QBCore and QBCore.Functions.GetPlayerByCitizenId(identifier)
    elseif Bridge.Framework == 'esx' then
        return ESX and ESX.GetPlayerFromIdentifier(identifier)
    end
    return nil
end

function Bridge.GetIdentifier(source)
    local player = Bridge.GetPlayer(source)
    if not player then return nil end

    -- qbx keeps the qb-style Player.PlayerData table
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return player.PlayerData and player.PlayerData.citizenid
    elseif Bridge.Framework == 'esx' then
        return player.identifier
    end
    return nil
end

function Bridge.GetPlayerJob(source)
    local player = Bridge.GetPlayer(source)
    if not player then return nil end

    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return player.PlayerData and player.PlayerData.job and player.PlayerData.job.name
    elseif Bridge.Framework == 'esx' then
        return player.job and player.job.name
    end
    return nil
end

function Bridge.GetPermissionGroup(source)
    if Bridge.Framework == 'qbx' then
        -- qbx has no GetPermission(); admin status is resolved via ACE by the caller.
        local player = Bridge.GetPlayer(source)
        return (player and player.PlayerData and player.PlayerData.group) or 'user'
    elseif Bridge.Framework == 'qb' then
        local player = Bridge.GetPlayer(source)
        if not player then return 'user' end
        return player.PlayerData.group or (QBCore and QBCore.Functions.GetPermission(source)) or 'user'
    elseif Bridge.Framework == 'esx' then
        local player = Bridge.GetPlayer(source)
        return (player and player.getGroup()) or 'user'
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

-- Check if player owns a vehicle (SERVER-AUTHORITATIVE)
function Bridge.CheckVehicleOwnership(source, plate)
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return false end
    if type(plate) ~= 'string' or plate == '' then return false end

    local column = Bridge.GetIdentifierColumn()
    local tableName = Bridge.GetVehiclesTable()

    -- plate stored in player_vehicles is often space-padded; match trimmed value
    local query = string.format('SELECT %s FROM %s WHERE TRIM(plate) = ? LIMIT 1', column, tableName)
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
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        -- QB/QBX use state = 2 for impounded
        return MySQL.update.await([[
            UPDATE player_vehicles
            SET state = 2, garage = ?, depotprice = ?
            WHERE plate = ?
        ]], { impoundLot or 'impound', fee or 0, plate })
    elseif Bridge.Framework == 'esx' then
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
    if Bridge.Framework == 'qb' then
        QBCore.Commands.Add(name, help, params or {}, false, callback, restricted and 'admin' or false)
    elseif Bridge.Framework == 'esx' then
        ESX.RegisterCommand(name, restricted and 'admin' or 'user', function(xPlayer, args, showError)
            callback(xPlayer.source, args)
        end, true, { help = help })
    else
        -- qbx and standalone both use ox_lib commands (qbx has no QBCore.Commands.Add).
        -- restricted commands are gated to the ACE 'group.admin' principal.
        lib.addCommand(name, {
            help = help,
            params = params or {},
            restricted = restricted and 'group.admin' or false
        }, function(source, args, raw)
            callback(source, args, raw)
        end)
    end
end
