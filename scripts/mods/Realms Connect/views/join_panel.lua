--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-04
--]]

local type = type
local tostring = tostring
local table_concat = table.concat

local M = {}

M.SCAN_MAX_LINES = 10

M.MODE_CARD = "card"
M.MODE_CODE = "code"

M.SOURCE_SCAN = "scan"
M.SOURCE_CODE = "code"

local STATUS_KEYS = {
    idle = "join_view_status_idle",
    awaiting = "join_view_status_awaiting",
    done = "join_view_status_done",
}

local STATE_LABELS = {
    locating = "join_view_state_locating",
}

local function text_of(localize, key)
    local value = localize and localize(key)
    if type(value) ~= "string" then
        return key
    end
    return value
end

function M.status_text(state, reason, localize, seconds_left)
    if state == "failed" then
        local text = text_of(localize, "join_view_status_failed")
        if reason then
            text = text .. ": " .. tostring(reason)
        end
        return text
    end

    local key = STATUS_KEYS[state]
    if key then
        return text_of(localize, key)
    end

    local label = state
    local label_key = STATE_LABELS[state]
    if label_key then
        label = text_of(localize, label_key)
    end

    local working = text_of(localize, "join_view_status_working") .. " (" .. tostring(label)

    if type(seconds_left) == "number" and seconds_left > 0 then
        working = working .. ", " .. tostring(seconds_left) .. "s"
    end

    return working .. ")"
end

function M.joinable_lobbies(results)
    local lobbies = {}

    if type(results) ~= "table" then
        return lobbies
    end

    for i = 1, #results do
        local entry = results[i]
        if entry.hosting == true and entry.incompatible ~= true
            and type(entry.account_id) == "string" and entry.account_id ~= "" then
            lobbies[#lobbies + 1] = entry
        end
    end

    return lobbies
end

local function closed_mid_mission(entry)
    return entry.in_progress == true and entry.accepting == false
end

local function describe(entry, localize)
    local detail

    if entry.pending then
        detail = text_of(localize, "join_card_looking_up")
    elseif entry.incompatible then
        detail = text_of(localize, "scan_row_incompatible")
    elseif entry.hosting then
        detail = entry.mission_label or entry.mission or text_of(localize, "scan_row_mission_unknown")
        if entry.players and entry.max then
            detail = detail .. "   " .. tostring(entry.players) .. "/" .. tostring(entry.max)
        end
        if entry.in_progress then
            local key = entry.accepting == false and "scan_row_in_progress_closed" or "scan_row_in_progress"
            detail = detail .. "   " .. text_of(localize, key)
        end
        local labels = entry.circumstance_labels
        if type(labels) == "table" and #labels > 0 then
            detail = detail .. "   " .. table_concat(labels, ", ")
        end
    elseif entry.running then
        detail = text_of(localize, "scan_row_not_hosting")
    else
        detail = text_of(localize, "scan_row_not_running")
    end

    local name = tostring(entry.name or "")
    if type(entry.symbol) == "string" and entry.symbol ~= "" then
        name = name .. "  " .. entry.symbol
    end

    return name, detail
end

function M.lobby_card(state, localize)
    local looked_up = state.looked_up

    if type(looked_up) == "table" then
        local name, detail = describe(looked_up, localize)
        return {
            source = M.SOURCE_CODE,
            account_id = looked_up.account_id,
            name = name,
            detail = detail,
            locked = looked_up.locked == true,
            joinable = looked_up.joinable == true and not closed_mid_mission(looked_up),
            pending = looked_up.pending == true,
            index = 1,
            total = 1,
            can_skip = false,
            position = text_of(localize, "join_card_from_code"),
        }
    end

    local lobbies = M.joinable_lobbies(state.scan_results)
    local total = #lobbies

    if total == 0 then
        return nil
    end

    local at = state.lobby_index or 1
    if at > total or at < 1 then
        at = 1
    end

    local entry = lobbies[at]
    local name, detail = describe(entry, localize)

    return {
        source = M.SOURCE_SCAN,
        account_id = entry.account_id,
        name = name,
        detail = detail,
        locked = entry.locked == true,
        joinable = not closed_mid_mission(entry),
        index = at,
        total = total,
        can_skip = total > 1,
        position = text_of(localize, "join_card_position")
            :gsub("{index}", tostring(at)):gsub("{total}", tostring(total)),
    }
end

function M.build(state, localize)
    state = state or {}

    local busy = state.join_state ~= nil and state.join_state ~= "idle" and
        state.join_state ~= "done" and state.join_state ~= "failed"

    local connected = state.connected == true

    local card
    if not connected then
        card = M.lobby_card(state, localize)
    end
    local mode = card and M.MODE_CARD or M.MODE_CODE

    local connect_enabled
    if connected then
        connect_enabled = false
    elseif card then
        connect_enabled = not busy and card.joinable == true
    else
        connect_enabled = not busy and (state.code_text or "") ~= ""
    end

    local scanned = state.scan_results
    local scanned_count = type(scanned) == "table" and #scanned or 0

    return {
        mode = mode,
        card = card,
        no_hosting = mode == M.MODE_CODE and scanned_count > 0,
        status = M.status_text(state.join_state or "idle", state.join_reason, localize,
            state.join_seconds_left),
        scan_lines = state.scan_lines or { text_of(localize, "scan_idle") },
        scan_running = state.scan_running == true,
        scan_label = state.scan_running and text_of(localize, "join_view_scanning")
            or text_of(localize, "join_view_scan"),
        connect_enabled = connect_enabled,
        busy = busy,
    }
end

function M.new(deps)
    deps = deps or {}
    local api = deps.api
    local localize = deps.localize

    local p = {}
    local last_error
    local lobby_index = 1

    local function call(name, ...)
        if not api or type(api[name]) ~= "function" then
            return nil
        end
        return api[name](...)
    end

    local function results()
        if api and type(api.scan_results) == "function" then
            return api.scan_results()
        end
        return nil
    end

    local function looked_up()
        if api and type(api.looked_up_code) == "function" then
            return api.looked_up_code()
        end
        return nil
    end

    local function current_state(code_text)
        local join_state, join_reason, join_seconds_left

        if api and type(api.status) == "function" then
            join_state, join_reason, join_seconds_left = api.status()
        end

        if last_error then
            join_state, join_reason = "failed", last_error
        end

        local scan_lines
        if api and type(api.scan_lines) == "function" then
            scan_lines = api.scan_lines(M.SCAN_MAX_LINES)
        end

        local scan_running = false
        if api and type(api.scan_state) == "function" then
            local scanning = api.scan_state()
            scan_running = scanning == "enumerating" or scanning == "settling"
        end

        local connected = false
        if api and type(api.connected) == "function" then
            connected = api.connected() == true
        end

        local scanned = results()
        local total = #M.joinable_lobbies(scanned)

        if lobby_index > total then
            lobby_index = 1
        end

        return {
            join_state = join_state,
            join_reason = join_reason,
            join_seconds_left = join_seconds_left,
            scan_lines = scan_lines,
            scan_results = scanned,
            looked_up = looked_up(),
            lobby_index = lobby_index,
            scan_running = scan_running,
            code_text = code_text,
            connected = connected,
        }
    end

    function p.skip_lobby()
        local total = #M.joinable_lobbies(results())

        if total <= 1 then
            lobby_index = 1
            return lobby_index
        end

        lobby_index = lobby_index + 1
        if lobby_index > total then
            lobby_index = 1
        end

        return lobby_index
    end

    function p.lobby_index()
        return lobby_index
    end

    function p.scan()
        lobby_index = 1
        last_error = nil
        call("clear_looked_up_code")

        local ok, err = call("scan_friends")
        if ok == nil then
            return false
        end
        if not ok then
            last_error = tostring(err or "")
        end
        return ok
    end

    function p.cancel_scan()
        call("cancel_scan")
    end

    function p.look_up(code_text)
        last_error = nil

        if api and type(api.is_direct_address) == "function" and api.is_direct_address(code_text) then
            local direct_ok, direct_err = call("join_manual", code_text, "")
            if not direct_ok then
                last_error = tostring(direct_err or text_of(localize, "join_view_status_failed"))
                return false, last_error
            end
            return true
        end

        local ok, err = call("look_up_code", code_text)
        if ok == nil then
            return false
        end
        if not ok then
            last_error = tostring(err or text_of(localize, "join_view_status_failed"))
            return false, last_error
        end
        return ok
    end

    function p.clear_card()
        lobby_index = 1
        last_error = nil
        call("clear_looked_up_code")
    end

    function p.join_card(password)
        last_error = nil

        local card = M.lobby_card(current_state(""), localize)
        if not card then
            return false, text_of(localize, "join_card_gone")
        end

        if not card.joinable then
            return false, card.detail
        end

        if card.locked and (password == nil or password == "") then
            last_error = text_of(localize, "scan_password_needed")
            return false, last_error
        end

        local ok, err = call("join_account", card.account_id, password, card.source)
        if ok == nil then
            return false
        end
        if not ok then
            last_error = tostring(err or text_of(localize, "join_view_status_failed"))
            return false, last_error
        end
        return true
    end

    function p.state(code_text)
        return M.build(current_state(code_text), localize)
    end

    function p.reset()
        last_error = nil
        lobby_index = 1
    end

    return p
end

return M
