--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-02
--]]

local type = type
local tostring = tostring
local pairs = pairs
local table_concat = table.concat

local M = {}

M.SAMPLE_INTERVAL = 2.0
M.STALL_AFTER = 6.0

local function noop() end

local function count(t)
    local n = 0
    if type(t) == "table" then
        for _ in pairs(t) do
            n = n + 1
        end
    end
    return n
end

local function safe_call(object, name)
    if type(object) ~= "table" or type(object[name]) ~= "function" then
        return nil, "absent"
    end
    local ok, value = pcall(object[name], object)
    if not ok then
        return nil, "error"
    end
    return value, nil
end

function M.new(deps)
    deps = deps or {}
    local clock = deps.clock
    local log = deps.log or noop
    local managers = deps.managers or function() return rawget(_G, "Managers") end

    local w = {}
    local next_sample = 0
    local began_at
    local last_signature

    local function package_detail(mgr)
        local pkg = mgr.package_synchronization
        if not pkg then
            return "package_sync=absent"
        end

        local ready = safe_call(pkg, "is_ready")
        local host = pkg._package_synchronizer_host
        local client = pkg._package_synchronizer_client
        local bits = { "package_ready=" .. tostring(ready) }

        bits[#bits + 1] = "host=" .. tostring(host ~= nil)
        bits[#bits + 1] = "client=" .. tostring(client ~= nil)

        if host then
            local items = safe_call(host, "item_definitions_initialized")
            bits[#bits + 1] = "host_items=" .. tostring(items)
        end
        if client then
            local items = safe_call(client, "item_definitions_initialized")
            bits[#bits + 1] = "client_items=" .. tostring(items)
        end

        return table_concat(bits, " ")
    end

    local function profile_detail(mgr)
        local prof = mgr.profile_synchronization
        if not prof then
            return "profile_sync=absent"
        end
        local ready = safe_call(prof, "is_ready")
        return "profile_ready=" .. tostring(ready and true or false) ..
            " host=" .. tostring(prof._profile_synchronizer_host ~= nil) ..
            " client=" .. tostring(prof._profile_synchronizer_client ~= nil)
    end

    local function group_detail(host)
        local groups = host._spawn_groups
        if type(groups) ~= "table" or #groups == 0 then
            return "groups=0"
        end

        local bits = {}
        for i = 1, #groups do
            local g = groups[i]
            bits[#bits + 1] = "group" .. tostring(g.id) .. "=" .. tostring(g.state) ..
                "(peers=" .. count(g.peers) .. " level_loaded=" .. count(g.level_loaded) .. ")"
        end
        return table_concat(bits, " ")
    end

    function w.update()
        local mgr = managers()
        if type(mgr) ~= "table" then
            return
        end

        local loading = mgr.loading
        local host = loading and loading._loading_host

        if not host or host._level_state ~= "unloaded" then
            began_at = nil
            last_signature = nil
            return
        end

        local now = clock()
        began_at = began_at or now

        if now - began_at < M.STALL_AFTER or now < next_sample then
            return
        end
        next_sample = now + M.SAMPLE_INTERVAL

        local line = "loadwatch: state=" .. tostring(host._state) ..
            " level=" .. tostring(host._level_state) ..
            " spawned_peers=" .. count(host._spawned_peers) ..
            " pkg_enabled=" .. count(host._package_sync_enabled_peers) ..
            "  " .. group_detail(host) ..
            "  " .. package_detail(mgr) ..
            "  " .. profile_detail(mgr)

        if line ~= last_signature then
            last_signature = line
            log(line)
        end
    end

    function w.reset()
        began_at = nil
        last_signature = nil
        next_sample = 0
    end

    return w
end

return M
