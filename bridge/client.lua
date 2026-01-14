--[[
    dps-vehiclepersistence Client Bridge
    Framework Abstraction
]]

local QBCore, ESX = nil, nil
local PlayerData = {}

-- Initialize framework objects
CreateThread(function()
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        QBCore = exports['qb-core']:GetCoreObject()
    elseif Bridge.Framework == 'esx' then
        ESX = exports['es_extended']:getSharedObject()
    end
end)

-- ═══════════════════════════════════════════════════════
-- PLAYER DATA
-- ═══════════════════════════════════════════════════════

function Bridge.GetPlayerData()
    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return QBCore and QBCore.Functions.GetPlayerData() or {}
    elseif Bridge.Framework == 'esx' then
        return ESX and ESX.GetPlayerData() or {}
    end
    return {}
end

function Bridge.GetIdentifier()
    local data = Bridge.GetPlayerData()

    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return data.citizenid
    elseif Bridge.Framework == 'esx' then
        return data.identifier
    end
    return nil
end

function Bridge.GetJob()
    local data = Bridge.GetPlayerData()

    if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
        return data.job and data.job.name or nil
    elseif Bridge.Framework == 'esx' then
        return data.job and data.job.name or nil
    end
    return nil
end

-- ═══════════════════════════════════════════════════════
-- NOTIFICATIONS
-- ═══════════════════════════════════════════════════════

function Bridge.Notify(title, message, notifyType, duration)
    notifyType = notifyType or 'inform'
    duration = duration or 5000

    lib.notify({
        title = title,
        description = message,
        type = notifyType,
        duration = duration
    })
end

-- ═══════════════════════════════════════════════════════
-- PLAYER LOADED EVENT HANDLERS
-- ═══════════════════════════════════════════════════════

-- QB/QBX
if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
    RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
        TriggerEvent('dps-vehiclepersistence:client:playerLoaded')
    end)

    RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
        TriggerEvent('dps-vehiclepersistence:client:playerUnloaded')
    end)
end

-- ESX
if Bridge.Framework == 'esx' then
    RegisterNetEvent('esx:playerLoaded', function(xPlayer)
        PlayerData = xPlayer
        TriggerEvent('dps-vehiclepersistence:client:playerLoaded')
    end)

    RegisterNetEvent('esx:onPlayerLogout', function()
        PlayerData = {}
        TriggerEvent('dps-vehiclepersistence:client:playerUnloaded')
    end)
end
