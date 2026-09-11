--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-11
--]]

local type = type
local pairs = pairs
local tostring = tostring
local table_sort = table.sort
local table_concat = table.concat
local math_ceil = math.ceil
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

local M = {}

local MODE_FRIENDS = "friends"
local MODE_OPEN = "open"

local SOURCE_PARTY = "party"
local SOURCE_FRIEND = "friend"
local SOURCE_HUB = "hub"

local DEFAULT_CAP = 10
local DEFAULT_REFRESH_INTERVAL = 15.0
local DEFAULT_KNOCK_DEADLINE = 30.0
local DEFAULT_MIN_INTERVAL = 5.0
local DEFAULT_SAFETY = 0.8

M.DEFAULT_KNOCK_DEADLINE = DEFAULT_KNOCK_DEADLINE
M.DEFAULT_MIN_INTERVAL = DEFAULT_MIN_INTERVAL
M.DEFAULT_SAFETY = DEFAULT_SAFETY

local RANK = { [SOURCE_PARTY] = 1, [SOURCE_FRIEND] = 2, [SOURCE_HUB] = 3 }

local GATE_OPEN = "open"
local GATE_FULL = "full"
local GATE_IDLE = "idle"

M.GATE_OPEN = GATE_OPEN
M.GATE_FULL = GATE_FULL
M.GATE_IDLE = GATE_IDLE

local LIVE_RANK = { in_game = 1, platform_online = 2 }
local LIVE_RANK_NONE = 3

local function live_rank(entry)
    return LIVE_RANK[entry.live] or LIVE_RANK_NONE
end

M.REASON_ALREADY_WATCHED = "already watched permanently, a temporary watch would waste a slot"
M.REASON_MODE_FRIENDS = "only co-present in this hub, and advertising is limited to friends"
M.REASON_CAP = "cap reached"

M.TAG_ALREADY_WATCHED = "already watched"
M.TAG_MODE_FRIENDS = "hub-only under friends mode"
M.TAG_CAP = "cap reached"
M.TAG_REFUSED = "watch refused"

M.TAG_ORDER = { M.TAG_CAP, M.TAG_MODE_FRIENDS, M.TAG_ALREADY_WATCHED, M.TAG_REFUSED }

function M.tally(dropped)
    if type(dropped) ~= "table" or #dropped == 0 then
        return ""
    end

    local counts = {}
    local unknown = 0
    for i = 1, #dropped do
        local tag = dropped[i] and dropped[i].tag
        if type(tag) == "string" then
            counts[tag] = (counts[tag] or 0) + 1
        else
            unknown = unknown + 1
        end
    end

    local parts = {}
    for i = 1, #M.TAG_ORDER do
        local tag = M.TAG_ORDER[i]
        if counts[tag] then
            parts[#parts + 1] = tostring(counts[tag]) .. " " .. tag
        end
    end
    if unknown > 0 then
        parts[#parts + 1] = tostring(unknown) .. " unclassified"
    end

    if #parts == 0 then
        return ""
    end

    return " (" .. table_concat(parts, ", ") .. ")"
end

local function noop() end
local function false_fn() return false end
local function empty_list() return {} end


local function rank_of(entry)
    if entry.party then
        return RANK[SOURCE_PARTY], SOURCE_PARTY
    end
    if entry.friend then
        return RANK[SOURCE_FRIEND], SOURCE_FRIEND
    end
    return RANK[SOURCE_HUB], SOURCE_HUB
end

function M.new(deps)
    deps = deps or {}
    local presence = deps.presence
    local enumerate = deps.enumerate or empty_list
    local advertise_mode = deps.advertise_mode or noop
    local already_watched = deps.already_watched or false_fn
    local scan_active = deps.scan_active or false_fn
    local clock = deps.clock or noop
    local cap = deps.cap or DEFAULT_CAP
    local refresh_interval = deps.refresh_interval or DEFAULT_REFRESH_INTERVAL
    local knock_deadline = deps.knock_deadline or DEFAULT_KNOCK_DEADLINE
    local min_interval = deps.min_interval or DEFAULT_MIN_INTERVAL
    local safety = deps.safety or DEFAULT_SAFETY
    local log = deps.log or noop
    local joins_open = deps.joins_open or function() return GATE_OPEN end

    local l = {}

    local held = {}
    local held_order = {}
    local dropped_list = {}
    local offset = 0
    local next_refresh_at = 0
    local needs_resync = true
    local pacing = { sweeps = 1, interval = refresh_interval, rotatable = 0, slots = 0, over_capacity = false }
    local held_signature
    local yielded_for_scan = false
    local last_sweep_text
    local last_release_text
    local last_listen_text

    local function held_count()
        local n = 0
        for _ in pairs(held) do
            n = n + 1
        end
        return n
    end

    local function release(reason, rotating)
        if held_count() == 0 then
            held = {}
            held_order = {}
            held_signature = nil
            return false
        end

        local names = {}
        for i = 1, #held_order do
            names[#names + 1] = tostring(held_order[i].ref.id)
        end

        if presence then
            presence.release_temp()
        end

        held = {}
        held_order = {}
        held_signature = nil

        local text
        if rotating then
            text = "listen: released " .. tostring(#names) .. " listening watch(es), rotating - " ..
                tostring(reason)
        else
            text = "listen: released every listening watch (" .. table_concat(names, ", ") .. ") - " ..
                tostring(reason)
        end

        if text ~= last_release_text then
            last_release_text = text
            log(text)
        end

        return true
    end

    local function eligible_entries(mode)
        local kept = {}
        local rejected = {}

        local list = enumerate()
        if type(list) ~= "table" then
            list = {}
        end

        for i = 1, #list do
            local entry = list[i]
            local key = type(entry) == "table" and ref_key(entry.ref) or nil
            if key then
                local _, via = rank_of(entry)
                if already_watched(entry.ref) then
                    rejected[#rejected + 1] = {
                        ref = entry.ref, source = via, reason = M.REASON_ALREADY_WATCHED,
                        tag = M.TAG_ALREADY_WATCHED,
                    }
                elseif mode == MODE_FRIENDS and not entry.party and not entry.friend then
                    rejected[#rejected + 1] = {
                        ref = entry.ref, source = via, reason = M.REASON_MODE_FRIENDS,
                        tag = M.TAG_MODE_FRIENDS,
                    }
                else
                    kept[#kept + 1] = { ref = entry.ref, source = via, key = key, live = entry.live }
                end
            end
        end

        table_sort(kept, function(a, b)
            if RANK[a.source] ~= RANK[b.source] then
                return RANK[a.source] < RANK[b.source]
            end
            local la, lb = live_rank(a), live_rank(b)
            if la ~= lb then
                return la < lb
            end
            return a.ref.id < b.ref.id
        end)

        table_sort(rejected, function(a, b)
            return a.ref.id < b.ref.id
        end)

        return kept, rejected
    end

    local function choose(mode)
        local kept, rejected = eligible_entries(mode)

        local pinned = {}
        local rotatable = {}

        for i = 1, #kept do
            if kept[i].source == SOURCE_PARTY or kept[i].live == "in_game" then
                pinned[#pinned + 1] = kept[i]
            else
                rotatable[#rotatable + 1] = kept[i]
            end
        end

        local chosen = {}
        local taken = {}

        for i = 1, #pinned do
            if #chosen < cap then
                chosen[#chosen + 1] = { ref = pinned[i].ref, source = pinned[i].source, key = pinned[i].key, pinned = true }
                taken[pinned[i].key] = true
            else
                rejected[#rejected + 1] = {
                    ref = pinned[i].ref,
                    source = pinned[i].source,
                    reason = M.REASON_CAP .. " (" .. tostring(cap) .. "/" .. tostring(cap) .. ")",
                    tag = M.TAG_CAP,
                }
            end
        end

        local slots = cap - #chosen
        local n = #rotatable

        if n > 0 and slots > 0 then
            local start = 0
            if n > slots then
                start = offset % n
            end
            for i = 1, n do
                local pick = rotatable[((start + i - 1) % n) + 1]
                if i <= slots then
                    chosen[#chosen + 1] = { ref = pick.ref, source = pick.source, key = pick.key, pinned = false }
                    taken[pick.key] = true
                end
            end
        end

        for i = 1, n do
            local pick = rotatable[i]
            if not taken[pick.key] then
                rejected[#rejected + 1] = {
                    ref = pick.ref,
                    source = pick.source,
                    reason = M.REASON_CAP .. " (" .. tostring(cap) .. "/" .. tostring(cap) ..
                        "), waiting for the next rotation",
                    tag = M.TAG_CAP,
                }
            end
        end

        return chosen, rejected, #rotatable, slots
    end

    local function signature_of(chosen)
        local keys = {}
        for i = 1, #chosen do
            keys[#keys + 1] = chosen[i].key
        end
        table_sort(keys)
        return table_concat(keys, ",")
    end

    function l.sync()
        if scan_active() then
            l.yield("a friends scan is using the shared temporary watch pool")
            return false
        end

        local mode = advertise_mode()

        if mode ~= MODE_FRIENDS and mode ~= MODE_OPEN then
            release("advertising is " .. tostring(mode) .. ", this machine listens to nobody")
            dropped_list = {}
            needs_resync = false
            return false
        end

        if not presence or type(presence.watch_temp) ~= "function" then
            dropped_list = {}
            needs_resync = false
            return false
        end

        local chosen, rejected, rotatable_count, slots = choose(mode)
        local signature = signature_of(chosen)
        local rotating = rotatable_count > slots

        dropped_list = rejected
        needs_resync = false

        if signature == held_signature then
            return true
        end

        release("the set of people worth listening to changed", rotating)

        local names = {}

        for i = 1, #chosen do
            local pick = chosen[i]
            local ok, err = presence.watch_temp(pick.ref)
            if ok then
                held[pick.key] = pick
                held_order[#held_order + 1] = pick
                names[#names + 1] = tostring(pick.ref.id) .. " (" .. tostring(pick.source) .. ")"
            else
                dropped_list[#dropped_list + 1] = {
                    ref = pick.ref,
                    source = pick.source,
                    reason = "the temporary watch was refused - " .. tostring(err),
                    tag = M.TAG_REFUSED,
                }
            end
        end

        held_signature = signature_of(held_order)

        if #held_order > 0 then
            local text
            if rotating then
                text = "listen: advertising is " .. tostring(mode) .. ", listening to " ..
                    tostring(#held_order) .. " account(s); " .. tostring(#dropped_list) ..
                    " not listened to" .. M.tally(dropped_list) .. ", rotating on the next refresh"
            else
                text = "listen: advertising is " .. tostring(mode) .. ", listening to " ..
                    tostring(#held_order) .. " account(s): " .. table_concat(names, ", ") ..
                    "; " .. tostring(#dropped_list) .. " not listened to" .. M.tally(dropped_list)
            end
            if text ~= last_listen_text then
                last_listen_text = text
                log(text)
            end
        end

        return true
    end

    function l.update()
        if scan_active() then
            if not yielded_for_scan then
                yielded_for_scan = true
                l.yield("a friends scan is using the shared temporary watch pool")
            end
            return
        end

        if yielded_for_scan then
            yielded_for_scan = false
            needs_resync = true
            log("listen: the friends scan finished, re-establishing the listening watches it displaced")
        end

        local due = clock() >= next_refresh_at

        if not needs_resync and not due then
            return
        end

        l.sync()

        if not due then
            return
        end

        local mode = advertise_mode()
        if mode ~= MODE_FRIENDS and mode ~= MODE_OPEN then
            next_refresh_at = clock() + refresh_interval
            return
        end

        local _, _, rotatable_count, slots = choose(mode)

        local gate = joins_open()
        if gate ~= GATE_FULL and gate ~= GATE_IDLE then
            gate = GATE_OPEN
        end

        local sweeps = 1
        if rotatable_count > slots and slots > 0 then
            sweeps = math_ceil(rotatable_count / slots)
            if gate ~= GATE_IDLE then
                offset = offset + slots
            end
        end

        local interval = refresh_interval
        if sweeps > 1 and gate == GATE_OPEN then
            interval = (knock_deadline * safety) / sweeps
            if interval < min_interval then
                interval = min_interval
            end
            if interval > refresh_interval then
                interval = refresh_interval
            end
        end

        local over_capacity = sweeps * interval >= knock_deadline
        if slots == 0 and rotatable_count > 0 then
            over_capacity = true
        end
        if gate ~= GATE_OPEN then
            over_capacity = false
        end

        pacing = {
            sweeps = sweeps,
            interval = interval,
            rotatable = rotatable_count,
            slots = slots,
            over_capacity = over_capacity,
        }

        if sweeps > 1 then
            local text = "listen: more people to watch than slots, sweeping " ..
                tostring(rotatable_count) .. " candidate(s) through " .. tostring(slots) ..
                " slot(s) in " .. tostring(sweeps) .. " passes, full pass every " ..
                string_format("%.1f", sweeps * interval) .. "s"
            if text ~= last_sweep_text then
                last_sweep_text = text
                log(text)
            end
        end

        next_refresh_at = clock() + interval
    end

    function l.pacing()
        return pacing
    end

    function l.invalidate()
        needs_resync = true
    end

    function l.yield(reason)
        local released = release(reason or "yielded")
        needs_resync = true
        return released
    end

    function l.reset()
        held = {}
        held_order = {}
        held_signature = nil
        dropped_list = {}
        offset = 0
        next_refresh_at = 0
        needs_resync = true
        yielded_for_scan = false
    end

    function l.listening()
        local out = {}
        for i = 1, #held_order do
            local pick = held_order[i]
            out[#out + 1] = { ref = pick.ref, source = pick.source, pinned = pick.pinned }
        end
        return out
    end

    function l.dropped()
        return dropped_list
    end

    function l.holds_temp_watches()
        return held_count() > 0
    end

    return l
end

return M
