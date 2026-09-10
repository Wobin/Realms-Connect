--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-01
--]]

local type = type
local pairs = pairs
local tostring = tostring
local math_floor = math.floor
local table_concat = table.concat

local M = {}

M.NOTICE_SECONDS = 4.0

M.ROLE_HOST = "host"

local function text_of(localize, key)
    local value = localize and localize(key)
    if type(value) ~= "string" then
        return key
    end
    return value
end

local function seconds_label(localize, seconds)
    return text_of(localize, "accept_seconds_left") .. " " .. tostring(seconds) ..
        text_of(localize, "accept_seconds_suffix")
end

function M.build(state, localize)
    state = state or {}

    local hosting = state.role == M.ROLE_HOST

    local panel = {
        hosting = hosting,
        tab_label = text_of(localize, "lobby_tab_requests"),
        badge = 0,
        own_code_line = nil,
        own_code_copyable = false,
        broadcast_label = text_of(localize, "lobby_broadcast_start"),
        broadcast_active = false,
        broadcast_available = hosting,
        reach_kind = hosting and state.reach_kind or nil,
        reach_text = hosting and state.reach_text
            and (state.reach_kind == "mapped"
                and (state.reach_text .. " (" .. text_of(localize, "lobby_reach_copy_hint") .. ")")
                or state.reach_text)
            or nil,
        notice = state.notice,
        rows = {},
        overflow = 0,
        queue_full = false,
        empty_text = nil,
    }

    if not hosting then
        panel.empty_text = text_of(localize, "lobby_not_hosting")
        return panel
    end

    if state.own_code then
        panel.own_code_line = text_of(localize, "join_view_own_code_label") .. " " ..
            tostring(state.own_code)
        panel.own_code_copyable = true
        panel.notice = panel.notice or panel.reach_text
            or text_of(localize, "join_view_own_code_copy_hint")
    else
        panel.own_code_line = text_of(localize, "join_view_own_code_unavailable")
        if state.own_code_reason then
            panel.own_code_line = panel.own_code_line .. " (" .. tostring(state.own_code_reason) .. ")"
        end
    end

    local broadcast = state.broadcast
    if type(broadcast) == "table" and broadcast.active then
        local remaining = broadcast.seconds_left
        if type(remaining) ~= "number" or remaining < 0 then
            remaining = 0
        end
        panel.broadcast_active = true
        panel.broadcast_label = text_of(localize, "lobby_broadcast_stop") .. " (" ..
            tostring(math_floor(remaining + 0.5)) .. text_of(localize, "accept_seconds_suffix") .. ")"
    end

    local requests = state.requests
    if type(requests) ~= "table" or #requests == 0 then
        panel.empty_text = text_of(localize, "accept_none")
        return panel
    end

    local visible = #requests
    local cap = state.max_rows

    if type(cap) == "number" and cap > 0 and visible > cap then
        visible = cap
        panel.overflow = #requests - cap
    end

    local waiting = 0

    for i = 1, visible do
        local request = requests[i]
        local row = {
            nonce = request.nonce,
            name = tostring(request.name or ""),
            actionable = true,
        }

        if type(request.symbol) == "string" and request.symbol ~= "" then
            row.name = row.name .. "  " .. request.symbol
        end

        row.relationship = tostring(request.relationship or "")
        row.compatibility = tostring(request.compatibility or "")

        if type(request.seconds_left) == "number" then
            row.countdown = seconds_label(localize, math_floor(request.seconds_left + 0.5))
        else
            waiting = waiting + 1
            row.countdown = text_of(localize, "lobby_request_waiting_turn")
                :gsub("{position}", tostring(waiting))
        end
        panel.rows[#panel.rows + 1] = row
    end

    panel.badge = #requests

    if state.queue_full then
        panel.queue_full = true
        if not state.notice then
            panel.notice = text_of(localize, "lobby_queue_full")
        end
    end

    return panel
end

function M.new(deps)
    deps = deps or {}
    local api = deps.api
    local localize = deps.localize
    local role = deps.role or function() return "none" end
    local clock = deps.clock or function() return 0 end

    local p = {}
    local notice
    local notice_until
    local known = {}
    local acted = {}

    local function notify(text)
        notice = text
        notice_until = clock() + M.NOTICE_SECONDS
    end

    p.notify = notify

    local function call(name, ...)
        if not api or type(api[name]) ~= "function" then
            return false, nil
        end
        return api[name](...)
    end

    function p.copy_code()
        local ok, result = call("copy_own_code")
        if ok then
            notify(text_of(localize, "join_view_own_code_copied"))
        else
            notify(tostring(result or text_of(localize, "join_view_own_code_copy_failed")))
        end
        return ok
    end

    function p.copy_address()
        local ok, result = call("copy_public_address")
        if ok then
            notify(text_of(localize, "lobby_reach_copied"))
        else
            notify(tostring(result or text_of(localize, "lobby_reach_copy_unavailable")))
        end
        return ok
    end

    function p.accept(nonce)
        acted[nonce] = true
        local ok, reason = call("accept_request", nonce)
        if not ok then
            notify(tostring(reason or text_of(localize, "accept_request_gone")))
        end
        return ok
    end

    function p.decline(nonce)
        acted[nonce] = true
        local ok, reason = call("decline_request", nonce)
        if not ok then
            notify(tostring(reason or text_of(localize, "accept_request_gone")))
        end
        return ok
    end

    function p.toggle_broadcast()
        local state = api and type(api.broadcast_state) == "function" and api.broadcast_state() or nil

        if type(state) == "table" and state.active then
            local stopped = call("stop_broadcast")
            if stopped then
                notify(text_of(localize, "lobby_broadcast_stopped"))
            end
            return stopped
        end

        local ok, result = call("broadcast_open")
        if ok then
            notify(text_of(localize, "lobby_broadcast_started"))
        else
            notify(tostring(result or text_of(localize, "lobby_broadcast_failed")))
        end
        return ok
    end

    local max_rows

    function p.set_max_rows(n)
        max_rows = n
    end

    function p.state()
        if notice_until and clock() >= notice_until then
            notice = nil
            notice_until = nil
        end

        local own_code, own_code_reason
        local requests = {}
        local broadcast
        local queue_full = false
        local reach_kind, reach_text

        if api then
            if type(api.own_code) == "function" then
                own_code, own_code_reason = api.own_code()
            end
            if type(api.join_requests) == "function" then
                requests = api.join_requests() or {}
            end
            if type(api.broadcast_state) == "function" then
                broadcast = api.broadcast_state()
            end
            if type(api.requests_full) == "function" then
                queue_full = api.requests_full()
            end
            if type(api.reachability) == "function" then
                reach_kind, reach_text = api.reachability()
            end
        end

        local seen = {}
        for i = 1, #requests do
            local nonce = requests[i].nonce
            seen[nonce] = true
            if not known[nonce] then
                known[nonce] = tostring(requests[i].name or "")
                notice = nil
                notice_until = nil
            end
        end
        for nonce, name in pairs(known) do
            if not seen[nonce] then
                if not acted[nonce] then
                    notify(text_of(localize, "lobby_request_expired") .. " " .. tostring(name))
                end
                known[nonce] = nil
                acted[nonce] = nil
            end
        end

        return M.build({
            role = role(),
            max_rows = max_rows,
            own_code = own_code,
            own_code_reason = own_code_reason,
            requests = requests,
            broadcast = broadcast,
            queue_full = queue_full,
            reach_kind = reach_kind,
            reach_text = reach_text,
            notice = notice,
        }, localize)
    end

    function p.reset()
        notice = nil
        notice_until = nil
        known = {}
        acted = {}
    end

    return p
end

return M
