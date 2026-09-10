--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-04
--]]

local type = type
local pcall = pcall
local tostring = tostring
local table_sort = table.sort
local table_remove = table.remove
local table_concat = table.concat

local M = {}

local STATE_IDLE = "idle"
local STATE_ENUMERATING = "enumerating"
local STATE_SETTLING = "settling"
local STATE_DONE = "done"
local STATE_FAILED = "failed"

local ONLINE = "online"

local DEFAULT_BATCH_SIZE = 8
local DEFAULT_SETTLE_SECONDS = 2.0
local DEFAULT_MAX_FRIENDS = 24
local DEFAULT_ENUMERATE_TIMEOUT = 15.0

M.STATE_IDLE = STATE_IDLE
M.STATE_ENUMERATING = STATE_ENUMERATING
M.STATE_SETTLING = STATE_SETTLING
M.STATE_DONE = STATE_DONE
M.STATE_FAILED = STATE_FAILED

M.UNCHECKED_CAP = "cap"
M.UNCHECKED_NO_WATCH = "no_watch"
M.UNCHECKED_ABORTED = "aborted"

local function noop() end
local function false_fn() return false end

local function player_account_id(player)
    if type(player) ~= "table" or type(player.account_id) ~= "function" then
        return nil
    end
    local ok, id = pcall(player.account_id, player)
    if not ok or type(id) ~= "string" or id == "" then
        return nil
    end
    return id
end

local function player_is_online(player)
    if type(player) ~= "table" or type(player.online_status) ~= "function" then
        return false
    end
    local ok, status = pcall(player.online_status, player)
    return ok and status == ONLINE
end

local function player_is_myself(player)
    if type(player) ~= "table" or type(player.is_myself) ~= "function" then
        return false
    end
    local ok, value = pcall(player.is_myself, player)
    return ok and value == true
end

local function player_name(player, account_id)
    if type(player) == "table" then
        if type(player.user_display_name) == "function" then
            local ok, name = pcall(player.user_display_name, player, false, true)
            if ok and type(name) == "string" and name ~= "" then
                return name
            end
        end
        if type(player.character_name) == "function" then
            local ok, name = pcall(player.character_name, player)
            if ok and type(name) == "string" and name ~= "" then
                return name
            end
        end
    end
    return tostring(account_id)
end

local FAILURE_KEYS = {
    no_session = "scan_failed_no_session",
    no_social = "scan_failed_no_social",
    no_presence = "scan_failed_no_presence",
    fetch_failed = "scan_failed_fetch",
    fetch_timed_out = "scan_failed_timeout",
    session_ended = "scan_failed_session_ended",
}

M.FAILURE_KEYS = FAILURE_KEYS

local UNCHECKED_KEYS = {
    [M.UNCHECKED_CAP] = "scan_row_unchecked_cap",
    [M.UNCHECKED_NO_WATCH] = "scan_row_unchecked_no_watch",
    [M.UNCHECKED_ABORTED] = "scan_row_unchecked_aborted",
}

local function row_text(entry, localize)
    local name = tostring(entry.name)

    if not entry.checked then
        local key = UNCHECKED_KEYS[entry.unchecked_reason] or "scan_row_unchecked_aborted"
        return name .. " - " .. localize(key)
    end

    if entry.incompatible then
        return name .. " - " .. localize("scan_row_incompatible")
    end

    if not entry.running then
        return name .. " - " .. localize("scan_row_not_running")
    end

    local version = entry.mod_version and (" v" .. tostring(entry.mod_version)) or ""

    if not entry.hosting then
        return name .. " - " .. localize("scan_row_not_hosting") .. version
    end

    local text = name .. " - " .. localize("scan_row_hosting")

    local mission = entry.mission_label or entry.mission
    if mission then
        text = text .. " " .. tostring(mission)
    else
        text = text .. " " .. localize("scan_row_mission_unknown")
    end

    if entry.players and entry.max then
        text = text .. " " .. tostring(entry.players) .. "/" .. tostring(entry.max)
    end

    if entry.locked then
        text = text .. " " .. localize("scan_row_locked")
    end

    if entry.in_progress then
        text = text .. " " .. localize(entry.accepting == false
            and "scan_row_in_progress_closed" or "scan_row_in_progress")
    end

    local labels = entry.circumstance_labels
    if type(labels) == "table" and #labels > 0 then
        text = text .. " " .. table_concat(labels, ", ")
    end

    return text .. version
end

function M.lines(state, reason, results, checked, total, localize, max_rows)
    local out = {}

    if state == STATE_FAILED then
        out[#out + 1] = localize(FAILURE_KEYS[reason] or "scan_failed_fetch")
        return out
    end

    if state == STATE_ENUMERATING then
        out[#out + 1] = localize("scan_enumerating")
        return out
    end

    if state == STATE_SETTLING then
        out[#out + 1] = localize("scan_checking") .. " " .. tostring(checked) .. "/" .. tostring(total)
    elseif state == STATE_IDLE and total == 0 then
        out[#out + 1] = localize("scan_idle")
        return out
    elseif state == STATE_DONE and total == 0 then
        out[#out + 1] = localize("scan_no_friends_online")
        return out
    end

    local shown = #results
    if type(max_rows) == "number" and max_rows >= 0 and shown > max_rows then
        shown = max_rows
    end

    for i = 1, shown do
        out[#out + 1] = row_text(results[i], localize)
    end

    if shown < #results then
        out[#out + 1] = localize("scan_more_rows") .. " " .. tostring(#results - shown)
    end

    return out
end

function M.new(deps)
    deps = deps or {}
    local social_fn = deps.social or noop
    local presence = deps.presence
    local protocol = deps.protocol
    local clock = deps.clock or noop
    local session_ready = deps.session_ready or false_fn
    local log = deps.log or noop
    local batch_size = deps.batch_size or DEFAULT_BATCH_SIZE
    local settle_seconds = deps.settle_seconds or DEFAULT_SETTLE_SECONDS
    local max_friends = deps.max_friends or DEFAULT_MAX_FRIENDS
    local enumerate_timeout = deps.enumerate_timeout or DEFAULT_ENUMERATE_TIMEOUT
    local mission_label = deps.mission_label
    local circumstance_labels = deps.circumstance_labels

    local s = {}

    local state = STATE_IDLE
    local failure_reason
    local generation = 0
    local pending = {}
    local results = {}
    local by_account = {}
    local batch = {}
    local settle_deadline = 0
    local enumerate_deadline = 0
    local held_temp = false

    local function release()
        if held_temp and presence then
            presence.release_temp()
        end
        held_temp = false
        batch = {}
    end

    local function finish(new_state, reason)
        release()
        state = new_state
        failure_reason = reason
        pending = {}
    end

    local function mark_remaining(reason)
        for i = 1, #pending do
            local entry = by_account[pending[i]]
            if entry then
                entry.unchecked_reason = reason
            end
        end
    end

    local function fail(reason)
        generation = generation + 1
        mark_remaining(M.UNCHECKED_ABORTED)
        finish(STATE_FAILED, reason)
        log("scan: " .. tostring(reason))
    end

    local function read_batch()
        for i = 1, #batch do
            local entry = batch[i]
            local info = presence and presence.peer_info(entry.ref)
            if type(info) == "table" then
                entry.checked = true
                entry.unchecked_reason = nil
                entry.mod_version = info.mod_version
                entry.incompatible = info.incompatible == true
                entry.running = info.mod_version ~= nil or info.incompatible == true

                local beacon = protocol and protocol.read_beacon(info.payload) or nil
                if beacon then
                    entry.hosting = true
                    entry.mission = beacon.mission
                    entry.players = beacon.players
                    entry.max = beacon.max
                    entry.locked = beacon.locked
                    entry.in_progress = beacon.in_progress
                    entry.accepting = beacon.accepting
                    if type(mission_label) == "function" then
                        local ok, label = pcall(mission_label, beacon.mission)
                        entry.mission_label = ok and label or nil
                    end
                    if type(circumstance_labels) == "function" then
                        local ok, labels = pcall(circumstance_labels, beacon.circumstance, beacon.modifiers)
                        entry.circumstance_labels = ok and labels or nil
                    end
                else
                    entry.hosting = false
                end
            else
                entry.unchecked_reason = M.UNCHECKED_NO_WATCH
            end
        end
    end

    local function take_batch()
        batch = {}

        local blocked = false

        while #batch < batch_size and #pending > 0 and not blocked do
            local account_id = pending[1]
            local entry = by_account[account_id]
            local ok, err = presence.watch_temp(entry.ref)
            if ok then
                held_temp = true
                batch[#batch + 1] = entry
                table_remove(pending, 1)
            elseif #batch == 0 then
                entry.unchecked_reason = M.UNCHECKED_NO_WATCH
                table_remove(pending, 1)
                log("scan: could not take a temporary watch on " .. tostring(account_id) ..
                    " - " .. tostring(err))
            else
                blocked = true
            end
        end

        if #batch == 0 then
            return false
        end

        settle_deadline = clock() + settle_seconds
        state = STATE_SETTLING
        return true
    end

    local function advance()
        if #pending == 0 then
            finish(STATE_DONE, nil)
            return
        end
        if not take_batch() then
            finish(STATE_DONE, nil)
        end
    end

    local function accept_friends(list)
        local seen = {}
        local online = {}

        if type(list) ~= "table" then
            list = {}
        end

        for i = 1, #list do
            local player = list[i]
            if not player_is_myself(player) then
                local account_id = player_account_id(player)
                if account_id and not seen[account_id] and player_is_online(player) then
                    seen[account_id] = true
                    online[#online + 1] = {
                        account_id = account_id,
                        name = player_name(player, account_id),
                    }
                end
            end
        end

        table_sort(online, function(a, b)
            if a.name == b.name then
                return a.account_id < b.account_id
            end
            return a.name < b.name
        end)

        results = {}
        by_account = {}
        pending = {}

        for i = 1, #online do
            local entry = {
                account_id = online[i].account_id,
                name = online[i].name,
                ref = { id = online[i].account_id },
                checked = false,
                running = false,
                hosting = false,
                incompatible = false,
            }
            results[#results + 1] = entry
            by_account[entry.account_id] = entry
            if i <= max_friends then
                pending[#pending + 1] = entry.account_id
            else
                entry.unchecked_reason = M.UNCHECKED_CAP
            end
        end

        advance()
    end

    function s.start()
        if state == STATE_ENUMERATING or state == STATE_SETTLING then
            return false, "a scan is already running"
        end
        if not session_ready() then
            return false, "no_session"
        end
        if not presence or type(presence.watch_temp) ~= "function" then
            return false, "no_presence"
        end

        local social = social_fn()
        if type(social) ~= "table" or type(social.fetch_friends) ~= "function" then
            return false, "no_social"
        end

        generation = generation + 1
        local gen = generation

        release()
        results = {}
        by_account = {}
        pending = {}
        failure_reason = nil
        state = STATE_ENUMERATING
        enumerate_deadline = clock() + enumerate_timeout

        local ok, promise = pcall(social.fetch_friends, social, true)
        if not ok or type(promise) ~= "table" or type(promise.next) ~= "function" then
            finish(STATE_FAILED, "no_social")
            return false, "no_social"
        end

        promise:next(function(list)
            if gen ~= generation or state ~= STATE_ENUMERATING then
                return
            end
            accept_friends(list)
        end, function(err)
            if gen ~= generation or state ~= STATE_ENUMERATING then
                return
            end
            finish(STATE_FAILED, "fetch_failed")
            log("scan: fetch_friends failed - " .. tostring(err))
        end)

        return true
    end

    function s.update()
        if state ~= STATE_ENUMERATING and state ~= STATE_SETTLING then
            return
        end

        if not session_ready() then
            fail("session_ended")
            return
        end

        if state == STATE_ENUMERATING then
            if clock() >= enumerate_deadline then
                fail("fetch_timed_out")
            end
            return
        end

        if clock() < settle_deadline then
            return
        end

        read_batch()
        release()
        advance()
    end

    function s.cancel()
        if state == STATE_IDLE then
            return false
        end
        generation = generation + 1
        mark_remaining(M.UNCHECKED_ABORTED)
        finish(STATE_IDLE, nil)
        return true
    end

    function s.state()
        return state, failure_reason
    end

    function s.results()
        return results
    end

    function s.progress()
        local checked = 0
        for i = 1, #results do
            if results[i].checked then
                checked = checked + 1
            end
        end
        return checked, #results
    end

    function s.holds_temp_watches()
        return held_temp
    end

    function s.lines(localize, max_rows)
        local checked, total = s.progress()
        return M.lines(state, failure_reason, results, checked, total, localize, max_rows)
    end

    return s
end

return M
