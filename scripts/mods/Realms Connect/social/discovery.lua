--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-08
--]]

local type = type
local tostring = tostring
local pairs = pairs
local pcall = pcall
local table_concat = table.concat
local table_sort = table.sort

local M = {}

local SOURCE_PARTY = "party"
local SOURCE_FRIEND = "friend"
local SOURCE_SAVED = "saved"
local SOURCE_HUB = "hub"

local DEFAULT_CAP = 8
local DEFAULT_REFRESH_INTERVAL = 15.0
local DEFAULT_FORCE_INTERVAL = 60.0
local DEFAULT_GATED_REFRESH_INTERVAL = 120.0

M.DEFAULT_FORCE_INTERVAL = DEFAULT_FORCE_INTERVAL
M.DEFAULT_GATED_REFRESH_INTERVAL = DEFAULT_GATED_REFRESH_INTERVAL

local function noop() end
local function false_fn() return false end
local function no_liveness() return nil end

local function trimmed(text)
    return text:match("^%s*(.-)%s*$")
end

local function split_codes(text)
    local out = {}
    if type(text) ~= "string" then
        return out
    end
    for piece in text:gmatch("[^,]+") do
        local clean = trimmed(piece)
        if clean ~= "" then
            out[#out + 1] = clean
        end
    end
    return out
end

local function ref_key(ref)
    if type(ref) ~= "table" or type(ref.id) ~= "string" then
        return nil
    end
    return tostring(ref.platform) .. ":" .. ref.id
end

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

local function player_platform_id(player)
    if type(player) ~= "table" or type(player.platform_user_id) ~= "function" then
        return nil
    end
    local ok, id = pcall(player.platform_user_id, player)
    if not ok or type(id) ~= "string" or id == "" then
        return nil
    end
    return id
end

local function player_is_myself(player)
    if type(player) ~= "table" or type(player.is_myself) ~= "function" then
        return false
    end
    local ok, value = pcall(player.is_myself, player)
    return ok and value == true
end

local ONLINE = "online"

local function player_online_status(player)
    if type(player) ~= "table" or type(player.online_status) ~= "function" then
        return nil
    end
    local ok, status = pcall(player.online_status, player)
    if not ok then
        return nil
    end
    return status
end

local function player_is_online(player)
    return player_online_status(player) == ONLINE
end

local PLATFORM_PSN = "psn"

local function player_platform_cheap(player)
    if type(player) ~= "table" then
        return nil
    end

    local saved = rawget(player, "_platform")
    if type(saved) == "string" and saved ~= "" then
        return saved
    end

    local platform_social = rawget(player, "_platform_social")
    if type(platform_social) == "table" and type(platform_social.platform) == "function" then
        local ok, value = pcall(platform_social.platform, platform_social)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end

    return nil
end

local function player_is_console_only(player)
    return player_platform_cheap(player) == PLATFORM_PSN
end

local function player_is_friend(player)
    if type(player) ~= "table" or type(player.is_friend) ~= "function" then
        return false
    end
    local ok, value = pcall(player.is_friend, player)
    return ok and value == true
end

function M.new(deps)
    deps = deps or {}
    local social_fn = deps.social or noop
    local party_fn = deps.party or noop
    local presence = deps.presence
    local clock = deps.clock or noop
    local saved_codes_fn = deps.saved_codes or noop
    local resolver = deps.resolver
    local cap = deps.cap or DEFAULT_CAP
    local refresh_interval = deps.refresh_interval or DEFAULT_REFRESH_INTERVAL
    local force_interval = deps.force_interval or DEFAULT_FORCE_INTERVAL
    local force_gate = deps.force_gate
    local gated_refresh_interval = deps.gated_refresh_interval or DEFAULT_GATED_REFRESH_INTERVAL
    local log = deps.log or noop
    local liveness = deps.liveness or { of = no_liveness }

    local d = {}

    local stopped = false
    local generation = 0
    local next_refresh_at = 0
    local next_force_at = 0
    local last_refresh_at = -math.huge
    local force_next = false
    local refresh_now = false
    local last_codes_signature

    local watched = {}
    local dropped_list = {}
    local dropped_signature
    local friend_keys = {}
    local party_keys = {}
    local warned_unresolvable = {}

    local party_list = {}
    local last_tally_text
    local friend_list = {}
    local saved_list = {}
    local hub_list = {}

    local apply
    local decide_online

    local function resolve_saved(gen)
        local texts = split_codes(saved_codes_fn())

        local still_present = {}
        for i = 1, #texts do
            still_present[texts[i]] = true
        end
        for text in pairs(warned_unresolvable) do
            if not still_present[text] then
                warned_unresolvable[text] = nil
            end
        end

        if #texts == 0 then
            saved_list = {}
            return
        end

        if type(resolver) ~= "table" or type(resolver.resolve) ~= "function" then
            saved_list = {}
            return
        end

        local resolved = {}
        local dispatching = true

        local function publish_saved()
            local out = {}
            for i = 1, #texts do
                local ref = resolved[texts[i]]
                if ref then
                    out[#out + 1] = ref
                end
            end
            saved_list = out
        end

        for i = 1, #texts do
            local text = texts[i]
            resolver.resolve(text, function(ok, ref, reason)
                if stopped or gen ~= generation then
                    return
                end
                if ok then
                    resolved[text] = ref
                elseif not warned_unresolvable[text] then
                    warned_unresolvable[text] = true
                    log("discovery: saved code could not be resolved - " .. text .. " - " .. tostring(reason))
                end
                publish_saved()
                if not dispatching then
                    apply()
                end
            end)
        end

        dispatching = false
    end

    local function party_refs()
        local out = {}
        party_keys = {}
        local party = party_fn()
        if type(party) ~= "table" or type(party.other_members_account_ids) ~= "function" then
            return out
        end
        local ok, ids = pcall(party.other_members_account_ids, party)
        if not ok or type(ids) ~= "table" then
            return out
        end
        for i = 1, #ids do
            local id = ids[i]
            if type(id) == "string" and id ~= "" then
                out[#out + 1] = { id = id, online = true }
                party_keys[id] = true
            end
        end
        return out
    end

    local function extract_players(list, trust_as_friend, assume_online, tally, want_liveness)
        local out = {}
        if type(list) ~= "table" then
            return out
        end
        for i = 1, #list do
            local player = list[i]
            if tally then
                tally.total = tally.total + 1
            end
            if player_is_console_only(player) then
                if tally then
                    tally.console = tally.console + 1
                end
            elseif not player_is_myself(player) then
                local id = player_account_id(player)
                local platform_id = player_platform_id(player)
                if id then
                    if trust_as_friend or player_is_friend(player) then
                        friend_keys[id] = true
                        if platform_id then
                            friend_keys[platform_id] = true
                        end
                    end
                    local status = assume_online and ONLINE or player_online_status(player)
                    if tally then
                        local key = status == nil and "unknown" or tostring(status)
                        tally.status[key] = (tally.status[key] or 0) + 1
                        tally.order[#tally.order + 1] = tally.status[key] == 1 and key or nil
                    end
                    local live = nil
                    if want_liveness then
                        live = liveness.of(player)
                    end
                    out[#out + 1] = {
                        id = id,
                        platform_id = platform_id,
                        online = status == ONLINE,
                        live = live,
                    }
                end
            end
        end
        return out
    end

    local function new_tally()
        return { total = 0, console = 0, status = {}, order = {} }
    end

    local function tally_text(tally)
        local parts = {}
        for i = 1, #tally.order do
            local key = tally.order[i]
            parts[#parts + 1] = key .. "=" .. tostring(tally.status[key])
        end
        local text = "discovery: " .. tostring(tally.total) .. " friend(s) enumerated"
        if #parts > 0 then
            text = text .. " (" .. table_concat(parts, ", ") .. ")"
        end
        if tally.console > 0 then
            text = text .. "; " .. tostring(tally.console) .. " skipped as console-only (psn)"
        end
        return text
    end

    decide_online = function(ref, online)
        if type(ref) ~= "table" or type(ref.id) ~= "string" then
            return nil
        end
        return online[ref.id]
    end

    local function build_online()
        local online = {}

        local function mark_online(entry, source)
            if type(entry) ~= "table" or not entry.online or not entry.id then
                return
            end
            online[entry.id] = source
        end

        for i = 1, #party_list do
            mark_online(party_list[i], SOURCE_PARTY)
        end
        for i = 1, #friend_list do
            mark_online(friend_list[i], SOURCE_FRIEND)
        end
        for i = 1, #hub_list do
            mark_online(hub_list[i], SOURCE_HUB)
        end

        return online
    end

    apply = function()
        local ordered = {}
        local seen = {}

        local function identity_key(ref)
            if type(ref) ~= "table" or type(ref.id) ~= "string" then
                return nil
            end
            return "a:" .. ref.id
        end

        local function add(ref, source, via)
            local key = ref_key(ref)
            local identity = identity_key(ref)
            if key and identity and not seen[identity] then
                seen[identity] = true
                ordered[#ordered + 1] = { ref = ref, source = source, key = key, via = via }
            end
        end

        local online = build_online()

        local new_dropped = {}

        local unconfirmed = {}

        for i = 1, #saved_list do
            local ref = saved_list[i]
            local via = decide_online(ref, online)
            if via then
                add(ref, SOURCE_SAVED, via)
            else
                unconfirmed[#unconfirmed + 1] = ref
            end
        end

        for i = 1, #unconfirmed do
            add(unconfirmed[i], SOURCE_SAVED, SOURCE_SAVED)
        end

        local new_watched = {}

        for i = 1, #ordered do
            local item = ordered[i]
            if i <= cap then
                new_watched[item.key] = item
            else
                new_dropped[#new_dropped + 1] = {
                    ref = item.ref,
                    source = item.source,
                    reason = "cap reached (" .. cap .. "/" .. cap .. " watches already taken)",
                }
            end
        end

        if presence then
            for key, item in pairs(watched) do
                if not new_watched[key] then
                    presence.unwatch(item.ref)
                end
            end
            for key, item in pairs(new_watched) do
                if not watched[key] then
                    local ok, err = presence.watch(item.ref)
                    if not ok then
                        log("discovery: could not watch a " .. tostring(item.source) .. " candidate - " .. tostring(err))
                        new_watched[key] = nil
                    end
                end
            end
        end

        watched = new_watched
        dropped_list = new_dropped

        local parts = {}
        for i = 1, #dropped_list do
            local item = dropped_list[i]
            parts[#parts + 1] = tostring(item.source) .. ":" .. tostring(ref_key(item.ref)) .. ":" .. tostring(item.reason)
        end
        local signature = table_concat(parts, "|")
        if signature ~= dropped_signature then
            dropped_signature = signature
            for i = 1, #dropped_list do
                local item = dropped_list[i]
                log("discovery: dropped a " .. tostring(item.source) .. " candidate, " .. tostring(item.reason))
            end
        end
    end

    function d.refresh()
        if stopped then
            return
        end

        generation = generation + 1
        local gen = generation

        local force = force_next
        if not force and clock() >= next_force_at then
            force = type(force_gate) ~= "function" or force_gate() == true
        end

        if force then
            next_force_at = clock() + force_interval
            force_next = false
        end

        party_list = party_refs()
        friend_keys = {}
        resolve_saved(gen)

        local social = social_fn()

        if type(social) == "table" and type(social.fetch_friends) == "function" then
            local ok, promise = pcall(social.fetch_friends, social, force)
            if ok and type(promise) == "table" and type(promise.next) == "function" then
                promise:next(function(list)
                    if stopped or gen ~= generation then
                        return
                    end
                    local tally = new_tally()
                    friend_list = extract_players(list, true, false, tally, true)
                    local text = tally_text(tally)
                    if text ~= last_tally_text then
                        last_tally_text = text
                        log(text)
                    end
                    apply()
                end, function(err)
                    if stopped or gen ~= generation then
                        return
                    end
                    friend_list = {}
                    log("discovery: fetch_friends failed, friends list cleared rather than kept stale - " ..
                        tostring(err))
                    apply()
                end)
            end
        end

        if type(social) == "table" and type(social.fetch_players_on_server) == "function" then
            local ok, promise = pcall(social.fetch_players_on_server, social)
            if ok and type(promise) == "table" and type(promise.next) == "function" then
                promise:next(function(list)
                    if stopped or gen ~= generation then
                        return
                    end
                    hub_list = extract_players(list, false, true, nil, false)
                    apply()
                end, function(err)
                    if stopped or gen ~= generation then
                        return
                    end
                    hub_list = {}
                    log("discovery: fetch_players_on_server failed, hub list cleared rather than kept stale - " ..
                        tostring(err))
                    apply()
                end)
            end
        end

        apply()
    end

    function d.force_refresh()
        force_next = true
        next_refresh_at = 0
    end

    function d.update()
        if stopped then
            return
        end
        if clock() >= next_refresh_at then
            next_refresh_at = clock() + refresh_interval

            local codes = saved_codes_fn()
            local codes_signature = type(codes) == "string" and codes or ""
            if codes_signature ~= last_codes_signature then
                last_codes_signature = codes_signature
                refresh_now = true
            end

            local open = force_next or refresh_now
                or type(force_gate) ~= "function" or force_gate() == true
            if open or clock() - last_refresh_at >= gated_refresh_interval then
                refresh_now = false
                last_refresh_at = clock()
                d.refresh()
            end
        end
    end

    function d.watched()
        local out = {}
        for _, item in pairs(watched) do
            out[#out + 1] = { ref = item.ref, source = item.source, via = item.via }
        end
        return out
    end

    function d.dropped()
        return dropped_list
    end

    local RELEASE_ORDER = { SOURCE_HUB, SOURCE_FRIEND, SOURCE_PARTY }

    function d.release_lowest_priority()
        for i = 1, #RELEASE_ORDER do
            local weakest = RELEASE_ORDER[i]
            for key, item in pairs(watched) do
                if item.via == weakest then
                    if presence then
                        presence.unwatch(item.ref)
                    end
                    watched[key] = nil
                    log("discovery: released a watch confirmed online via " .. tostring(weakest) ..
                        " to make room for an explicit join")
                    return true
                end
            end
        end
        return false
    end

    function d.enumerated()
        local online = build_online()

        local membership = {}

        local function note(list, field)
            for i = 1, #list do
                local entry = list[i]
                if type(entry) == "table" and entry.id then
                    membership[entry.id] = membership[entry.id] or {}
                    membership[entry.id][field] = true
                end
            end
        end

        note(party_list, SOURCE_PARTY)
        note(friend_list, SOURCE_FRIEND)
        note(hub_list, SOURCE_HUB)

        local live_by_id = {}
        for i = 1, #friend_list do
            local entry = friend_list[i]
            if type(entry) == "table" and entry.id then
                live_by_id[entry.id] = entry.live
            end
        end

        local out = {}

        for id in pairs(membership) do
            local ref = { id = id }
            local via = decide_online(ref, online)
            local source = via
            if not source then
                if membership[id][SOURCE_PARTY] then
                    source = SOURCE_PARTY
                elseif membership[id][SOURCE_FRIEND] then
                    source = SOURCE_FRIEND
                else
                    source = SOURCE_HUB
                end
            end

            out[#out + 1] = {
                ref = ref,
                source = source,
                party = membership[id][SOURCE_PARTY] == true,
                friend = membership[id][SOURCE_FRIEND] == true,
                hub = membership[id][SOURCE_HUB] == true,
                live = live_by_id[id],
            }
        end

        table_sort(out, function(a, b)
            return a.ref.id < b.ref.id
        end)

        return out
    end

    function d.is_friend(ref)
        if type(ref) ~= "table" or type(ref.id) ~= "string" then
            return false
        end
        return friend_keys[ref.id] == true
    end

    function d.is_party(ref)
        if type(ref) ~= "table" or type(ref.id) ~= "string" then
            return false
        end
        return party_keys[ref.id] == true
    end

    function d.stop()
        if presence then
            for _, item in pairs(watched) do
                presence.unwatch(item.ref)
            end
        end
        watched = {}
        dropped_list = {}
        dropped_signature = nil
        friend_keys = {}
        warned_unresolvable = {}
        party_list = {}
        friend_list = {}
        saved_list = {}
        hub_list = {}
        stopped = true
    end

    function d.resume()
        if not stopped then
            return false
        end
        stopped = false
        generation = generation + 1
        next_refresh_at = 0
        refresh_now = true
        return true
    end

    return d
end

M.false_fn = false_fn

return M
