--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-08-31
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

local candidates = load_sibling("net/candidates")

local M = {}

local DEFAULT_HORIZON = 3.0
local DEFAULT_ROUNDS = 3

function M.new(deps)
    deps = deps or {}
    local now = deps.now
    local fire = deps.fire
    local horizon = deps.horizon or DEFAULT_HORIZON
    local rounds_cap = deps.rounds or DEFAULT_ROUNDS

    local p = {}

    local pending_t
    local pending_cands
    local rounds_used = 0

    function p.schedule(t_punch, cands)
        if rounds_used >= rounds_cap then
            return false
        end
        if type(t_punch) ~= "number" or type(cands) ~= "table" then
            return false
        end
        pending_t = t_punch
        pending_cands = cands
        return true
    end

    function p.update()
        if pending_t == nil then
            return
        end
        local n = now()
        if n < pending_t then
            return
        end

        if n - pending_t <= horizon then
            for i = 1, #pending_cands do
                local ip, port = candidates.parse(pending_cands[i])
                if ip then
                    fire(ip, port)
                end
            end
        end

        rounds_used = rounds_used + 1
        pending_t = nil
        pending_cands = nil
    end

    function p.rounds_used()
        return rounds_used
    end

    function p.cancel()
        pending_t = nil
        pending_cands = nil
    end

    function p.reset()
        pending_t = nil
        pending_cands = nil
        rounds_used = 0
    end

    return p
end

return M
