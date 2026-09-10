--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-07
--]]

local type = type
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

local M = {}

local TIER_MAPPED = 1
local TIER_PUNCH = 2
local TIER_MANUAL = 3

local function has_text(value)
    return type(value) == "string" and #value > 0
end

local function igd_ready(report)
    return report.igd ~= nil and has_text(report.igd.control_url)
end

local function stun_ip(stun)
    if not stun then
        return nil
    end
    if has_text(stun.public_ip) then
        return stun.public_ip
    end
    return nil
end

local function stun_ready(report)
    local stun = report.stun
    return stun ~= nil and stun.mapping_behaviour == "endpoint_independent" and stun_ip(stun) ~= nil
end

local function stun_symmetric(report)
    local stun = report.stun
    return stun ~= nil and stun.mapping_behaviour == "address_dependent"
end

local function igd_reason(report)
    local reason = "no IGD available"
    if report.igd ~= nil and has_text(report.igd.error) then
        reason = reason .. " (" .. report.igd.error .. ")"
    end
    return reason
end

local function resolve_tier(report)
    if type(report) ~= "table" then
        return TIER_MANUAL, "no diagnostic report available"
    end

    json.strip_null(report)

    local cgnat = report.cgnat
    local verdict = cgnat ~= nil and cgnat.verdict

    if verdict == "cgnat" then
        if igd_ready(report) then
            return TIER_MANUAL, "CGNAT detected: the router mapping succeeds locally, but the WAN address is carrier-private and reaches nobody from outside"
        end
        return TIER_MANUAL, "CGNAT detected and no router mapping is available"
    end

    if igd_ready(report) then
        if verdict == "address_mismatch" then
            return TIER_MAPPED, "a working router mapping (IGD) is available; the router's reported WAN address disagrees with the one the internet sees, which is usually a stale reading after a reconnect"
        end
        if report.igd ~= nil and has_text(report.igd.error) then
            return TIER_MAPPED, "a working router mapping (IGD) is available, but the router could not report its own WAN address (" ..
                report.igd.error .. "), so the STUN-observed address is advertised instead"
        end
        return TIER_MAPPED, "a working router mapping (IGD) is available"
    end

    local reason = igd_reason(report)

    if stun_ready(report) then
        return TIER_PUNCH, reason .. "; falling back to a mutual NAT punch over a cone NAT"
    end

    if stun_symmetric(report) then
        return TIER_MANUAL, reason .. "; symmetric NAT cannot be punched"
    end

    return TIER_MANUAL, reason .. "; NAT behaviour could not be determined"
end

local function can_host(report)
    local tier, reason = resolve_tier(report)
    if tier == TIER_MANUAL then
        return false, "cannot host (" .. reason .. "); joining another Realm still works, since joining only needs an outbound connection"
    end
    return true, reason
end

function M.new(opts)
    opts = opts or {}
    local log = opts.log

    local function emit(tier, reason)
        if type(log) == "function" then
            log(tier, reason)
        end
        return tier, reason
    end

    local m = { native = opts.native }

    function m.resolve_tier(report)
        return emit(resolve_tier(report))
    end

    function m.can_host(report)
        return can_host(report)
    end

    return m
end

return M
