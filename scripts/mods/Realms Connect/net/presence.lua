--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-11
--]]

local type = type
local tostring = tostring
local pairs = pairs
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

local ref_key = load_sibling("util/ref").key

local ENVELOPE_OVERHEAD_BYTES = 19

local M = {}

local function noop() end

function M.new(deps)
    deps = deps or {}
    local mod = deps.mod
    local manifold = deps.manifold
    local protocol = deps.protocol
    local id = deps.id
    local log = deps.log or noop

    local p = {}

    local current_payload
    local watched_refs = {}
    local temp_refs = {}
    local warned_version = {}

    local function version_text()
        return tostring(mod and mod.version or "")
    end

    local function budget()
        local cap = protocol.MAX_BYTES - ENVELOPE_OVERHEAD_BYTES - #version_text()
        if cap < 0 then
            return 0
        end
        return cap
    end

    local function builder()
        return current_payload
    end

    function p.register()
        if not manifold then
            return false, "Vox Manifold is not available"
        end
        return manifold.register(id, mod, builder)
    end

    function p.unregister()
        if manifold then
            manifold.unregister(id)
        end
        current_payload = nil
    end

    function p.publish(payload)
        if type(payload) ~= "table" then
            return false, "payload must be a table"
        end

        local encoded, encode_err = protocol.encode(payload)
        if not encoded then
            log("presence: refused to publish - " .. tostring(encode_err))
            return false, encode_err
        end

        local cap = budget()
        if #encoded > cap then
            local reason = string_format(
                "payload is %d bytes, exceeds the %d-byte Vox Manifold budget for this consumer (%d envelope + %d version)",
                #encoded, cap, ENVELOPE_OVERHEAD_BYTES, #version_text())
            log("presence: refused to publish - " .. reason)
            return false, reason
        end

        current_payload = payload
        if manifold then
            manifold.mark_dirty(id)
        end
        return true
    end

    function p.retract()
        current_payload = nil
        if manifold then
            manifold.mark_dirty(id)
        end
    end

    function p.has_payload()
        return current_payload ~= nil
    end

    function p.watch(ref)
        if not manifold then
            return nil, "Vox Manifold is not available"
        end
        local key = ref_key(ref)
        if not key then
            return nil, "watch requires a table with an id"
        end

        local held = watched_refs[key]
        if held then
            held.count = held.count + 1
            return true
        end

        local ok, err = manifold.watch(id, ref)
        if not ok then
            return nil, err
        end

        watched_refs[key] = { ref = ref, count = 1 }
        return true
    end

    function p.unwatch(ref)
        local key = ref_key(ref)
        local held = key and watched_refs[key]
        if not held then
            return false
        end
        held.count = held.count - 1
        if held.count > 0 then
            return true
        end
        if manifold then
            manifold.unwatch(id, held.ref)
        end
        watched_refs[key] = nil
        return true
    end

    function p.unwatch_all()
        for key, held in pairs(watched_refs) do
            if manifold then
                manifold.unwatch(id, held.ref)
            end
            watched_refs[key] = nil
        end
        warned_version = {}
        p.release_temp()
    end

    function p.watch_temp(ref)
        if not manifold then
            return nil, "Vox Manifold is not available"
        end
        if type(manifold.watch_temp) ~= "function" then
            return nil, "this build of Vox Manifold has no temporary watch pool"
        end

        local key = ref_key(ref)
        if not key then
            return nil, "watch requires a table with an id"
        end

        if temp_refs[key] then
            return true
        end

        local ok, err = manifold.watch_temp(id, ref)
        if not ok then
            return nil, err
        end

        temp_refs[key] = ref
        return true
    end

    function p.release_temp()
        local held = 0
        for _ in pairs(temp_refs) do
            held = held + 1
        end

        temp_refs = {}

        if manifold and type(manifold.release_temp) == "function" then
            manifold.release_temp(id)
        end

        return held
    end

    function p.temp_watched()
        local out = {}
        for _, ref in pairs(temp_refs) do
            out[#out + 1] = ref
        end
        return out
    end

    local function decoded_payload(handle)
        if not manifold then
            return nil
        end
        local payload = manifold.get(handle, id)
        if payload == false or payload == nil or type(payload) ~= "table" then
            return nil
        end
        if payload.pv ~= protocol.PV then
            local key = type(handle) == "table" and ref_key(handle.vm_ref) or nil
            if not key or not warned_version[key] then
                if key then
                    warned_version[key] = true
                end
                log(string_format("presence: ignored a payload with pv=%s (expected %s)",
                    tostring(payload.pv), tostring(protocol.PV)))
            end
            return nil, "version mismatch"
        end
        return payload
    end

    local function handle_for(ref)
        if not manifold or type(manifold.watched) ~= "function" then
            return nil
        end
        local key = ref_key(ref)
        if not key then
            return nil
        end
        local handles = manifold.watched(id)
        if type(handles) ~= "table" then
            return nil
        end
        for i = 1, #handles do
            local handle = handles[i]
            if type(handle) == "table" and type(handle.vm_ref) == "table" and ref_key(handle.vm_ref) == key then
                return handle
            end
        end
        return nil
    end

    function p.peer_info(ref)
        if not manifold then
            return nil, "Vox Manifold is not available"
        end

        local handle = handle_for(ref)
        if not handle then
            return nil, "no live presence handle for this account"
        end

        local mod_version
        if type(manifold.has_mod) == "function" then
            mod_version = manifold.has_mod(handle, id)
        end

        local payload, payload_err = decoded_payload(handle)

        return {
            mod_version = type(mod_version) == "string" and mod_version or nil,
            payload = payload,
            incompatible = payload_err == "version mismatch",
        }
    end

    function p.read_all()
        local handles = manifold and manifold.watched(id) or {}
        local i = 0
        return function()
            while true do
                i = i + 1
                local handle = handles[i]
                if not handle then
                    return nil
                end
                local ref = type(handle) == "table" and handle.vm_ref
                if type(ref) == "table" then
                    local payload = decoded_payload(handle)
                    if payload then
                        return ref, payload
                    end
                end
            end
        end
    end

    return p
end

return M
