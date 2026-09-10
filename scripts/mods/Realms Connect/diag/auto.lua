--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-07
--]]

local type = type
local tostring = tostring
local string_format = string.format

local M = {}

M.DEFAULT_COOLDOWN_SECONDS = 600.0

local function noop() end

function M.new(deps)
    deps = deps or {}
    local native = deps.native
    local state = deps.state
    local clock = deps.clock
    local log = deps.log or noop
    local cooldown = deps.cooldown or M.DEFAULT_COOLDOWN_SECONDS
    local report_file = deps.report_file
    local host_port = deps.host_port or noop

    local a = {}

    function a.maybe(why)
        why = tostring(why)

        if type(native) ~= "table" or not native.available then
            local reason = (type(native) == "table" and native.load_error) or "no reason recorded"
            log("auto-diag: not sweeping after " .. why ..
                " - the native DLL is not loaded (" .. tostring(reason) .. ")")
            return false
        end

        if type(state) ~= "table" then
            log("auto-diag: not sweeping after " .. why .. " - there is no diagnostic state to track the sweep in")
            return false
        end

        if state.job then
            log("auto-diag: not sweeping after " .. why .. " - a sweep is already running")
            return false
        end

        local now = clock()
        local last = state.auto_last_at
        if type(last) == "number" and type(now) == "number" and now - last < cooldown then
            log("auto-diag: not sweeping after " .. why .. " - the last automatic sweep was " ..
                string_format("%.0f", now - last) .. "s ago and the cooldown is " ..
                string_format("%.0f", cooldown) .. "s")
            return false
        end

        local port = host_port()
        if type(port) ~= "number" then
            port = 0
        end

        local ok, err = native.diag.begin(port)
        if not ok then
            log("auto-diag: could not start a sweep after " .. why .. " - " .. tostring(err))
            return false
        end

        state.auto_last_at = now
        state.job = { warned_overrun = false, auto = true }
        log("auto-diag: sweeping after " .. why .. "; the report will follow in this log" ..
            (report_file and (" and be written to " .. tostring(report_file)) or ""))
        return true
    end

    return a
end

return M
