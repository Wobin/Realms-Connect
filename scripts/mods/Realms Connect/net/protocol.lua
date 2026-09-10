--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-04
--]]

local type = type
local pcall = pcall
local require = require
local string_format = string.format
local debug_getinfo = debug.getinfo

local function root_dir()
    local source = debug_getinfo(1, "S").source
    local path = source:match("^@(.*)$") or source
    local dir = path:match("^(.*)[\\/][^\\/]+$")
    return dir:match("^(.*)[\\/][^\\/]+$")
end

local function load_sibling(name)
    local host = rawget(_G, "get_mod") and get_mod("Realms Connect")
    if host and host.io_dofile then
        return host:io_dofile("Realms Connect/scripts/mods/Realms Connect/" .. name)
    end
    return dofile(root_dir() .. "\\" .. name .. ".lua")
end

local json = load_sibling("util/json")

local cjson_lib
do
    local ok, lib = pcall(require, "cjson")
    if ok then
        cjson_lib = lib
    end
end

local M = {
    PV = 1,
    MAX_BYTES = 250,
    KIND_KNOCK = "k",
    KIND_ACK = "a",
    KIND_BEACON = "b",
    KIND_PENDING = "p",
    KIND_UNREACHABLE = "u",
}

function M.set_decoder(lib)
    cjson_lib = lib
end

local MAX_DECODE_BYTES = 16384

local function as_array_field(cands)
    if cands == nil then
        return nil
    end
    return json.as_array(cands)
end

function M.build_knock(to_short, nonce, cands)
    return { pv = M.PV, k = M.KIND_KNOCK, a = to_short, n = nonce, c = as_array_field(cands) }
end

function M.build_ack(nonce, punch_delay, cands)
    return { pv = M.PV, k = M.KIND_ACK, n = nonce, t = punch_delay, c = as_array_field(cands) }
end

M.MAX_PENDING_SECONDS = 120

function M.build_pending(nonce, seconds)
    if type(seconds) ~= "number" or seconds <= 0 then
        return nil, "a pending needs a positive number of seconds"
    end
    if seconds > M.MAX_PENDING_SECONDS then
        seconds = M.MAX_PENDING_SECONDS
    end
    return { pv = M.PV, k = M.KIND_PENDING, n = nonce, t = seconds }
end

function M.read_pending(payload)
    if type(payload) ~= "table" or payload.k ~= M.KIND_PENDING then
        return nil
    end
    if payload.n == nil then
        return nil
    end
    local seconds = payload.t
    if type(seconds) ~= "number" or seconds <= 0 then
        return nil
    end
    if seconds > M.MAX_PENDING_SECONDS then
        seconds = M.MAX_PENDING_SECONDS
    end
    return { nonce = payload.n, seconds = seconds }
end

M.UNREACHABLE_MAX_TRIED = 32

function M.build_unreachable(nonce, tried)
    if nonce == nil then
        return nil, "an unreachable report needs the nonce it answers"
    end
    if type(tried) ~= "number" or tried < 0 then
        return nil, "an unreachable report needs how many candidates were tried"
    end
    if tried > M.UNREACHABLE_MAX_TRIED then
        tried = M.UNREACHABLE_MAX_TRIED
    end
    return { pv = M.PV, k = M.KIND_UNREACHABLE, n = nonce, c = tried }
end

function M.read_unreachable(payload)
    if type(payload) ~= "table" or payload.k ~= M.KIND_UNREACHABLE then
        return nil
    end
    if payload.n == nil then
        return nil
    end
    local tried = payload.c
    if type(tried) ~= "number" or tried < 0 then
        return nil
    end
    if tried > M.UNREACHABLE_MAX_TRIED then
        tried = M.UNREACHABLE_MAX_TRIED
    end
    return { nonce = payload.n, tried = tried }
end

M.MISSION_NONE = ""

function M.build_beacon(info)
    info = info or {}

    local mission = info.mission
    if type(mission) ~= "string" then
        mission = M.MISSION_NONE
    end

    local players = info.players
    if type(players) ~= "number" then
        players = 0
    end

    local max = info.max
    if type(max) ~= "number" then
        max = 0
    end

    return {
        pv = M.PV,
        k = M.KIND_BEACON,
        b = json.as_array({
            mission,
            players,
            max,
            info.locked == true,
            info.in_progress == true,
            info.accepting ~= false,
            type(info.circumstance) == "string" and info.circumstance or M.MISSION_NONE,
            json.as_array(type(info.modifiers) == "table" and info.modifiers or {}),
        }),
    }
end

function M.read_beacon(payload)
    if type(payload) ~= "table" or payload.k ~= M.KIND_BEACON then
        return nil
    end

    local b = payload.b
    if type(b) ~= "table" then
        return nil
    end

    local mission = b[1]
    if type(mission) ~= "string" or mission == M.MISSION_NONE then
        mission = nil
    end

    local circumstance = b[7]
    if type(circumstance) ~= "string" or circumstance == M.MISSION_NONE then
        circumstance = nil
    end

    local modifiers = {}
    if type(b[8]) == "table" then
        for i = 1, #b[8] do
            if type(b[8][i]) == "string" and b[8][i] ~= "" then
                modifiers[#modifiers + 1] = b[8][i]
            end
        end
    end

    return {
        mission = mission,
        players = type(b[2]) == "number" and b[2] or nil,
        max = type(b[3]) == "number" and b[3] or nil,
        locked = b[4] == true,
        in_progress = b[5] == true,
        accepting = b[6] ~= false,
        circumstance = circumstance,
        modifiers = modifiers,
    }
end

function M.encode(payload)
    local encoded, err = json.encode(payload)
    if not encoded then
        return nil, err
    end
    if #encoded > M.MAX_BYTES then
        return nil, string_format("payload exceeds max bytes (%d > %d)", #encoded, M.MAX_BYTES)
    end
    return encoded
end

function M.decode(raw)
    if type(raw) ~= "string" or #raw == 0 then
        return nil, "not a string"
    end
    if #raw > MAX_DECODE_BYTES then
        return nil, "oversized"
    end
    if not cjson_lib then
        return nil, "no decoder available"
    end
    local ok, parsed = pcall(cjson_lib.decode, raw)
    if not ok or type(parsed) ~= "table" then
        return nil, "malformed"
    end
    if parsed.pv ~= M.PV then
        return nil, "version mismatch"
    end
    return parsed
end

return M
