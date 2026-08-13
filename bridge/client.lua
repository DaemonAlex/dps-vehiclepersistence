--[[
    dps-vehiclepersistence Client Bridge
    Framework Abstraction

    NOTE on QBX:
    This qbx_core build exposes NO GetCoreObject(). The qbx branch reads player
    data via the discrete export exports.qbx_core:GetPlayerData(). GetCoreObject
    is only ever touched on the legacy 'qb' branch.
]]

local QBCore, ESX = nil, nil
local PlayerData = {}
local frameworkReady = false

-- Initialize framework objects (only the legacy qb/esx paths need a shared object).
CreateThread(function()
    if Bridge.Framework == 'qb' then
        while QBCore == nil do
            QBCore = exports['qb-core']:GetCoreObject()
            if QBCore == nil then Wait(100) end
        end
        frameworkReady = true
    elseif Bridge.Framework == 'esx' then
        while ESX == nil do
            ESX = exports['es_extended']:getSharedObject()
            if ESX == nil then Wait(100) end
        end
        frameworkReady = true
    elseif Bridge.Framework == 'qbx' then
        -- qbx ready-gate: wait until the export answers with player data.
        while not frameworkReady do
            local ok, data = pcall(function() return exports.qbx_core:GetPlayerData() end)
            if ok and data and data.citizenid then
                frameworkReady = true
            else
                Wait(250)
            end
        end
    else
        frameworkReady = true
    end
end)

function Bridge.IsReady()
    return frameworkReady
end

-- ═══════════════════════════════════════════════════════
-- PLAYER DATA
-- ═══════════════════════════════════════════════════════

function Bridge.GetPlayerData()
    if Bridge.Framework == 'qbx' then
        local ok, data = pcall(function() return exports.qbx_core:GetPlayerData() end)
        return (ok and data) or {}
    elseif Bridge.Framework == 'qb' then
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
    return data.job and data.job.name or nil
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

-- QB / QBX both fire the QBCore:Client compatibility events.
if Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
    RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
        frameworkReady = true
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
        frameworkReady = true
        TriggerEvent('dps-vehiclepersistence:client:playerLoaded')
    end)

    RegisterNetEvent('esx:onPlayerLogout', function()
        PlayerData = {}
        TriggerEvent('dps-vehiclepersistence:client:playerUnloaded')
    end)
end
