--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-08-31
--]]

local mod = get_mod("Realms Connect")

local ffi = Mods.lua.ffi
local print = print
local type = type
local pcall = pcall
local rawget = rawget
local tostring = tostring

local ERR_CAP = 256

if not pcall(ffi.typeof, "RealmsConnect_CDEF2") then
    ffi.cdef([[
        typedef struct { int32_t unused; } RealmsConnect_CDEF2;

        int32_t RealmsConnect_Version(char *out, int32_t cap);
        int32_t RealmsConnect_LocalUdpPorts(char *out, int32_t cap, char *err, int32_t errlen);
        int32_t RealmsConnect_LocalAddrs(char *out, int32_t cap, char *err, int32_t errlen);
        int32_t RealmsConnect_StunBegin(char *err, int32_t errlen);
        int32_t RealmsConnect_StunPoll(char *out, int32_t cap, char *err, int32_t errlen);
        void RealmsConnect_StunCancel(void);
        int32_t RealmsConnect_DiagBegin(int32_t host_port, char *err, int32_t errlen);
        int32_t RealmsConnect_DiagPoll(char *out, int32_t cap, char *err, int32_t errlen);
        int32_t RealmsConnect_MapBegin(int32_t internal_port, int32_t lease_seconds, char *err, int32_t errlen);
        int32_t RealmsConnect_MapPoll(char *out, int32_t cap, char *err, int32_t errlen);
        int32_t RealmsConnect_MapRelease(int32_t internal_port, char *err, int32_t errlen);
    ]])
end

local function decode_json(raw)
    if type(raw) ~= "string" then
        return nil, "not a string"
    end
    local c = rawget(_G, "cjson")
    if type(c) ~= "table" or type(c.decode) ~= "function" then
        return nil, "no json decoder available"
    end
    local ok, parsed = pcall(function() return c.decode(raw) end)
    if not ok then
        return nil, "malformed json: " .. tostring(parsed)
    end
    if type(parsed) ~= "table" then
        return nil, "decoded value is not a table"
    end
    return parsed
end

local function call_begin(fn, ...)
    local err = ffi.new("char[?]", ERR_CAP)
    local n = select("#", ...)
    local rc
    if n == 0 then
        rc = fn(err, ERR_CAP)
    elseif n == 1 then
        local a1 = ...
        rc = fn(a1, err, ERR_CAP)
    elseif n == 2 then
        local a1, a2 = ...
        rc = fn(a1, a2, err, ERR_CAP)
    else
        return false, "call_begin: unsupported argument count " .. tostring(n)
    end
    if rc == 1 then
        return true
    end
    return false, ffi.string(err)
end

local function call_poll(fn, start_cap, max_cap)
    local cap = start_cap
    while cap <= max_cap do
        local out = ffi.new("char[?]", cap)
        local err = ffi.new("char[?]", ERR_CAP)
        local rc = fn(out, cap, err, ERR_CAP)
        if rc == 1 then
            return "ok", ffi.string(out)
        elseif rc == -1 then
            return "pending"
        elseif rc == -2 then
            return "overrun", ffi.string(err)
        elseif rc == -3 then
            return "cancelled", ffi.string(err)
        elseif rc == 0 then
            local msg = ffi.string(err)
            if msg == "output buffer too small" and cap < max_cap then
                cap = cap * 2
            else
                return "error", msg
            end
        else
            return "error", "unexpected return code " .. tostring(rc)
        end
    end
    return "error", "result too large to read"
end

local function call_version(fn, start_cap, max_cap)
    local cap = start_cap
    while cap <= max_cap do
        local out = ffi.new("char[?]", cap)
        local rc = fn(out, cap)
        if rc == 1 then
            return ffi.string(out)
        end
        cap = cap * 2
    end
    return nil
end

local M = {}
M.available = false
M.stun = {}
M.diag = {}
M.map = {}

local instances = mod:persistent_table("instances")

local lib = instances.lib
local load_error = instances.load_error

if not lib then
    local ok, loaded = pcall(ffi.load, "../mods/Realms Connect/bin/darktide-realms-connect.dll")
    if ok then
        lib = loaded
        instances.lib = lib
        load_error = nil
        instances.load_error = nil
    else
        load_error = tostring(loaded)
        instances.load_error = load_error
        print("[Realms Connect] native DLL failed to load: " .. load_error)
    end
end

M.available = lib ~= nil
M.load_error = load_error

function M.version()
    if not lib then
        return nil, "native unavailable"
    end
    local s = call_version(lib.RealmsConnect_Version, 64, 4096)
    if not s then
        return nil, "version query failed"
    end
    return s
end

function M.local_udp_ports()
    if not lib then
        return nil, "native unavailable"
    end
    local status, payload = call_poll(lib.RealmsConnect_LocalUdpPorts, 512, 65536)
    if status ~= "ok" then
        return nil, payload or status
    end
    return decode_json(payload)
end

function M.local_addrs()
    if not lib then
        return nil, "native unavailable"
    end
    local status, payload = call_poll(lib.RealmsConnect_LocalAddrs, 512, 65536)
    if status ~= "ok" then
        return nil, payload or status
    end
    return decode_json(payload)
end

function M.stun.begin()
    if not lib then
        return false, "native unavailable"
    end
    return call_begin(lib.RealmsConnect_StunBegin)
end

function M.stun.poll()
    if not lib then
        return "error", "native unavailable"
    end
    local status, payload = call_poll(lib.RealmsConnect_StunPoll, 2048, 65536)
    if status ~= "ok" then
        return status, payload
    end
    local decoded, derr = decode_json(payload)
    if not decoded then
        return "error", derr
    end
    return "ok", decoded
end

function M.stun.cancel()
    if lib then
        lib.RealmsConnect_StunCancel()
    end
end

function M.diag.begin(host_port)
    if not lib then
        return false, "native unavailable"
    end
    if type(host_port) ~= "number" then
        host_port = 0
    end
    return call_begin(lib.RealmsConnect_DiagBegin, host_port)
end

function M.diag.poll()
    if not lib then
        return "error", "native unavailable"
    end
    local status, payload = call_poll(lib.RealmsConnect_DiagPoll, 4096, 262144)
    if status ~= "ok" then
        return status, payload
    end
    local decoded, derr = decode_json(payload)
    if not decoded then
        return "error", derr
    end
    return "ok", decoded
end

function M.map.begin(internal_port, lease_seconds)
    if not lib then
        return false, "native unavailable"
    end
    return call_begin(lib.RealmsConnect_MapBegin, internal_port, lease_seconds or 0)
end

function M.map.poll()
    if not lib then
        return "error", "native unavailable"
    end
    local status, payload = call_poll(lib.RealmsConnect_MapPoll, 512, 8192)
    if status ~= "ok" then
        return status, payload
    end
    local decoded, derr = decode_json(payload)
    if not decoded then
        return "error", derr
    end
    return "ok", decoded
end

function M.map.release(internal_port)
    if not lib then
        return false, "native unavailable"
    end
    return call_begin(lib.RealmsConnect_MapRelease, internal_port)
end

return M
