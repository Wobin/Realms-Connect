--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-12
--]]

local mod = get_mod("Realms Connect")
mod.version = mod.get_metadata and mod:get_metadata("version") or "unknown"

local get_mod = get_mod
local print = print
local type = type
local tostring = tostring
local pcall = pcall
local rawget = rawget
local pairs = pairs
local string_match = string.match
local string_format = string.format
local string_find = string.find
local string_sub = string.sub
local math_ceil = math.ceil
local table_sort = table.sort
local table_concat = table.concat
local debug_getinfo = debug.getinfo

local K = {}

K.CONSUMER_ID = "wobin.realms_connect"
K.FRIEND_CODE_RESOLVE_TIMEOUT_SECONDS = 20.0
K.REALMS_ADDRESS_TIMEOUT_SECONDS = 8.0
K.REALMS_JOIN_TIMEOUT_SECONDS = 20.0
K.REALMS_VALIDATION_TIMEOUT_SECONDS = 20.0
K.REALMS_CLIENT_BOOT_BUDGET_SECONDS = K.REALMS_ADDRESS_TIMEOUT_SECONDS +
    K.REALMS_JOIN_TIMEOUT_SECONDS + K.REALMS_VALIDATION_TIMEOUT_SECONDS
K.JOIN_POLL_TIMEOUT = K.REALMS_CLIENT_BOOT_BUDGET_SECONDS
K.DISCOVERY_CAP = 8
K.DISCOVERY_REFRESH_INTERVAL = 15.0
K.BEACON_MISSION_MAX_CHARS = 32
K.LOBBY_GAME_MODES = {
    hub = true,
    hub_singleplay = true,
    prologue_hub = true,
    shooting_range = true,
}
K.SCAN_BATCH_SIZE = 8
K.SCAN_SETTLE_SECONDS = 6.0
K.SCAN_MAX_FRIENDS = 24
K.KNOCK_TIMEOUT_SECONDS = 30.0
K.ENDPOINT_WAIT_SECONDS = 10.0
K.ACCEPT_PROMPT_TIMEOUT_SECONDS = 30.0
K.AUTO_DIAG_COOLDOWN_SECONDS = 600.0
K.UNREACHABLE_REPORT_HOLD_SECONDS = 8.0
K.BROADCAST_WINDOW_SECONDS = 120.0
K.VOX_MANIFOLD_PUBLISH_INTERVAL = 2.0
K.ACCEPT_WIRE_ALLOWANCE_SECONDS = K.VOX_MANIFOLD_PUBLISH_INTERVAL * 2.0 + 1.0
K.LISTEN_CAP = 24
local remembered = { CAP = 8, KEY = "rc_remembered_peers" }
K.LISTEN_REFRESH_INTERVAL = K.DISCOVERY_REFRESH_INTERVAL
K.DIAG_REPORT_FILE = "../mods/rc_diag_report.txt"

local function module_dir()
    local source = debug_getinfo(1, "S").source
    local path = source:match("^@(.*)$") or source
    return path:match("^(.*)[\\/][^\\/]+$")
end

K.DIR = module_dir()

local function load_module(name)
    if mod.io_dofile then
        return mod:io_dofile("Realms Connect/scripts/mods/Realms Connect/" .. name)
    end
    return dofile(K.DIR .. "\\" .. name .. ".lua")
end

local protocol = load_module("net/protocol")
local punch = load_module("net/punch")
local rendezvous = load_module("rendezvous/rendezvous")
local responder = load_module("rendezvous/responder")
local knock_gate = load_module("rendezvous/knock_gate")
local knock_notification = load_module("rendezvous/knock_notification")
local boot_failure = load_module("net/boot_failure")
local browser_lifetime = load_module("net/browser_lifetime")
local labels = load_module("net/labels")
local mask = load_module("util/mask")
local mapping = load_module("diag/mapping")
local loadwatch = load_module("diag/loadwatch")
local idhash = load_module("net/idhash")
local portmap = load_module("net/portmap")
local diag = load_module("diag/diag")
local auto_diag = load_module("diag/auto")
local native = load_module("net/native")
local presence = load_module("net/presence")
local candidates = load_module("net/candidates")
local endpoints = load_module("net/endpoints")
local identity = load_module("social/identity")
local advertise = load_module("social/advertise")
local discovery = load_module("social/discovery")
local liveness_module = load_module("social/liveness")
local resolver_module = load_module("social/resolver")
local scan_module = load_module("social/scan")
local listen_module = load_module("social/listen")

do
    local decoder = rawget(_G, "cjson")
    if type(decoder) == "table" and type(decoder.decode) == "function" then
        protocol.set_decoder(decoder)
    else
        mod:error("[Realms Connect] no bare-global cjson decoder found at load; peer payloads still decode fine via Vox Manifold, but native.decode_json (used by /rc_diag and /rc_report's STUN and mapping data) will fail until this is resolved")
    end
end

local function debug_on()
    return mod:get("rc_debug_mode") == true
end

local function log_fn(msg)
    print("[Realms Connect] " .. tostring(msg))
end

local function log_gated(msg)
    if debug_on() then
        print("[Realms Connect] " .. tostring(msg))
    end
end

local function clock()
    return Managers.time and Managers.time:time("main") or 0
end

local function local_player_safe(player_manager)
    if type(player_manager) ~= "table" then
        return nil
    end

    if type(player_manager.local_player_safe) == "function" then
        local ok, player = pcall(player_manager.local_player_safe, player_manager, 1)
        if ok then
            return player
        end
        return nil
    end

    local connection_manager = Managers.connection
    if type(connection_manager) ~= "table"
        or type(connection_manager.is_initialized) ~= "function"
        or not connection_manager:is_initialized() then
        return nil
    end

    if type(player_manager.local_player) ~= "function" then
        return nil
    end

    local ok, player = pcall(player_manager.local_player, player_manager, 1)
    if ok then
        return player
    end
    return nil
end

local function session_ready()
    return local_player_safe(Managers.player) ~= nil
end

local function social_service()
    local data_service = Managers.data_service
    if not data_service then
        return nil
    end
    return data_service.social
end

local active

local function release_active_host_watch(presence_ref)
    if active and presence_ref and active.host_ref and not active.host_released then
        presence_ref.unwatch(active.host_ref)
        active.host_released = true
    end
end

local function realms_session()
    local realms = get_mod("Realms")
    if not realms then
        return nil, "Realms is not installed"
    end
    local session = realms._session
    if type(session) ~= "table" or type(session.start_client) ~= "function" then
        return nil, "Realms has changed; the join entry point is missing"
    end
    return session
end

local function realms_session_active()
    local session = realms_session()
    if type(session) ~= "table" then
        return false
    end

    if type(session.is_active_client) ~= "function" then
        return false
    end

    local ok, active = pcall(session.is_active_client)

    return ok and active == true
end

local warned_missing_host_api = false

local function realms_setting(name)
    local realms = get_mod("Realms")
    if not realms or type(realms.get) ~= "function" then
        return nil
    end
    local ok, value = pcall(realms.get, realms, name)
    if not ok then
        return nil
    end
    return value
end

local function realms_is_advertisable_host()
    local session = realms_session()
    if not session then
        return false
    end
    if type(session.is_active_host) ~= "function" then
        if not warned_missing_host_api then
            warned_missing_host_api = true
            log_fn("beacon: Realms has changed; Session.is_active_host is missing, so this machine can never advertise")
        end
        return false
    end
    local ok, hosting = pcall(session.is_active_host)
    if not ok or hosting ~= true then
        return false
    end
    return realms_setting("private_mode") ~= true
end

local function realms_host_connection()
    local session = realms_session()
    if not session or type(session.is_active_host) ~= "function" then
        return nil
    end
    local ok, hosting = pcall(session.is_active_host)
    if not ok or hosting ~= true then
        return nil
    end
    local connection_manager = Managers.connection
    local connection = connection_manager and connection_manager._connection_host
    if type(connection) ~= "table" then
        return nil
    end
    return connection
end

local mission_templates_cache

local function mission_templates()
    if mission_templates_cache == nil then
        local ok, templates = pcall(require, "scripts/settings/mission/mission_templates")
        mission_templates_cache = ok and type(templates) == "table" and templates or false
    end
    return mission_templates_cache or nil
end

local circumstance_templates_cache
local circumstance_index_cache

local function circumstance_templates()
    if circumstance_templates_cache == nil then
        local ok, t = pcall(require, "scripts/settings/circumstance/circumstance_templates")
        circumstance_templates_cache = ok and type(t) == "table" and t or false
    end
    return circumstance_templates_cache or nil
end

local function circumstance_index()
    if circumstance_index_cache == nil then
        local t = circumstance_templates()
        circumstance_index_cache = t and idhash.index(t) or false
    end
    return circumstance_index_cache or nil
end

local function localize_game_key(key)
    if type(key) ~= "string" or key == "" then
        return nil
    end

    local manager = rawget(_G, "Managers")
    local localization = manager and manager.localization
    if type(localization) ~= "table" or type(localization.exists) ~= "function" then
        return nil
    end

    local known, exists = pcall(localization.exists, localization, key)
    if not known or not exists then
        return nil
    end

    local localize_fn = rawget(_G, "Localize")
    if type(localize_fn) ~= "function" then
        return nil
    end

    local named, text = pcall(localize_fn, key)
    if not named or type(text) ~= "string" or text == "" then
        return nil
    end

    return text
end

local function parse_havoc_data(text)
    local loaded, havoc = pcall(require, "scripts/utilities/havoc")
    if not loaded or type(havoc) ~= "table" or type(havoc.parse_data) ~= "function" then
        return nil
    end
    return havoc.parse_data(text)
end

local label_resolver = labels.new({
    idhash = idhash,
    mission_templates = mission_templates,
    circumstance_templates = circumstance_templates,
    circumstance_index = circumstance_index,
    localize_key = localize_game_key,
    parse_havoc = parse_havoc_data,
})

local mission_label = label_resolver.mission_label
local circumstance_labels = label_resolver.circumstance_labels

local function host_circumstances()
    local manager = rawget(_G, "Managers")
    local mechanism = manager and manager.mechanism
    if type(mechanism) ~= "table" or type(mechanism.mechanism_data) ~= "function" then
        return nil, {}
    end

    local ok, data = pcall(mechanism.mechanism_data, mechanism)
    if not ok then
        return nil, {}
    end

    return label_resolver.host_circumstances(data)
end

local advertise_instance

local function host_in_mission()
    local connection = realms_host_connection()
    if not connection or type(connection.mission_name) ~= "function" then
        return false
    end

    local ok, name = pcall(connection.mission_name, connection)
    if not ok or type(name) ~= "string" or name == "" then
        return false
    end

    local templates = mission_templates()
    local template = templates and templates[name]
    local game_mode = template and template.game_mode_name

    if type(game_mode) ~= "string" then
        return false
    end

    return K.LOBBY_GAME_MODES[game_mode] ~= true
end

local function connection_number(connection, name)
    if type(connection[name]) ~= "function" then
        return nil
    end
    local ok, value = pcall(connection[name], connection)
    if not ok or type(value) ~= "number" then
        return nil
    end
    return value
end

local function realms_host_port()
    local connection = realms_host_connection()
    if not connection then
        return nil
    end
    return connection_number(connection, "local_port")
end

local function accepting_in_mission()
    return advertise_instance == nil or advertise_instance.accepting_in_mission()
end

local function listen_gate()
    local connection = realms_host_connection()
    if not connection then
        return listen_module.GATE_IDLE
    end

    local connected = connection_number(connection, "num_connections")
    local max_members = connection_number(connection, "max_members")
    if connected and max_members and connected + 1 >= max_members then
        return listen_module.GATE_FULL
    end

    if not accepting_in_mission() then
        return listen_module.GATE_FULL
    end

    return listen_module.GATE_OPEN
end

local function should_force_friend_refresh()
    return listen_gate() == listen_module.GATE_OPEN
end

local function host_beacon_info()
    local connection = realms_host_connection()
    if not connection then
        return nil
    end

    local info = {}

    if type(connection.mission_name) == "function" then
        local ok, name = pcall(connection.mission_name, connection)
        if ok and type(name) == "string" and name ~= "" and #name <= K.BEACON_MISSION_MAX_CHARS then
            info.mission = name
        end
    end

    local connected = connection_number(connection, "num_connections")
    if connected then
        info.players = connected + 1
    end

    info.max = connection_number(connection, "max_members")

    local password = realms_setting("server_password")
    info.locked = type(password) == "string" and password ~= ""

    info.in_progress = host_in_mission()
    info.accepting = accepting_in_mission()

    local main_circumstance, extra_circumstances = host_circumstances()
    info.circumstance = idhash.hash(main_circumstance)
    info.modifiers = idhash.hash_all(extra_circumstances)

    return info
end

local manifold
local presence_instance
local endpoints_instance
local identity_instance
local discovery_instance
local resolver_instance
local responder_instance
local responder_punch
local responder_own_code
local knock_notice
local knock_notice_view_name
local portmap_reported_state
local portmap_advice_echoed = {}
local listen_capacity_echoed

local function addresses_hidden()
    return mod:get("rc_mask_addresses") == true
end

local function screen_text(s)
    return mask.apply(s, addresses_hidden())
end

local function echo_text(s)
    if type(s) ~= "string" then
        s = tostring(s)
    end
    mod:echo((screen_text(s):gsub("%%", "%%%%")))
end

local function echo_localized(key, fields)
    local text = mod:localize(key)
    if type(text) ~= "string" then
        return
    end

    for name, value in pairs(fields or {}) do
        local literal = tostring(value)
        text = text:gsub("{" .. name .. "}", function() return literal end)
    end

    echo_text(text)
end
local pending_join
local pending_resolve
local pending_knock
local code_lookup
local portmap_instance
local loadwatch_instance
local join_pending = false
local resolve_error
local join_token = 0
local diag_state = mod:persistent_table("diag")
local enabled = true

local host_watched = {}
local host_watch_signature
local session_was_ready
local discovery_running = true
local scan_instance
local listen_instance
local beacon_signature
local beacon_refused_signature
local broadcast_until
local broadcast_was_active = false
local tick_view_patches
local knock_owns_the_channel
local unreachable_report_until = 0

local punch_browser
local punch_browser_client

local function ensure_browser()
    local client = Managers.connection and Managers.connection:client()
    if not client then
        log_fn("punch: no connection client available, cannot open a lobby browser to punch with")
        return nil
    end
    if punch_browser and punch_browser_client == client then
        return punch_browser
    end
    punch_browser = nil
    punch_browser_client = nil
    local ok, browser = pcall(LanClient.create_lobby_browser, client)
    if not ok then
        log_fn("punch: create_lobby_browser raised an error - " .. tostring(browser))
        return nil
    end
    if not browser then
        log_fn("punch: create_lobby_browser returned no browser")
        return nil
    end
    punch_browser_client = client
    punch_browser = browser
    return punch_browser
end

local function destroy_browser(exit_game)
    local live_client = Managers.connection and Managers.connection.client
        and Managers.connection:client()

    local disposal = browser_lifetime.disposal({
        browser = punch_browser,
        owner_client = punch_browser_client,
        live_client = live_client,
        api_present = rawget(_G, "LanClient") ~= nil,
        exit_game = exit_game == true,
    })

    if disposal == browser_lifetime.DESTROY then
        pcall(LanClient.destroy_lobby_browser, punch_browser_client, punch_browser)
    elseif disposal == browser_lifetime.ABANDON then
        log_fn("punch: abandoning the lobby browser rather than destroying it")
    end

    punch_browser = nil
    punch_browser_client = nil
end

local function punch_fire(ip, port)
    local browser = ensure_browser()
    if not browser then
        return
    end
    local ok, err = pcall(function() browser:establish_connection_to_server(ip, port) end)
    if not ok then
        log_fn("punch: establish_connection_to_server raised an error for " ..
            tostring(ip) .. ":" .. tostring(port) .. " - " .. tostring(err))
    end
end

local join_password = ""

local function realms_join(ip, port, on_result)
    if pending_join then
        on_result(false, "another join is already pending")
        return
    end
    local session, err = realms_session()
    if not session then
        on_result(false, err)
        return
    end
    local started, start_err = session.start_client(ip, tostring(port), join_password or "")
    if not started then
        on_result(false, start_err or "Realms refused to start the client boot")
        return
    end
    pending_join = { on_result = on_result, deadline = clock() + K.JOIN_POLL_TIMEOUT }
end

local function client_boot_failure_reason()
    local session = Managers.multiplayer_session
    return boot_failure.reason(session and session._session_boot, function(key)
        return mod:localize(key)
    end)
end

mod.rc_on_client_boot_failed = function()
    if not pending_join then
        return
    end
    local cb = pending_join.on_result
    pending_join = nil
    cb(false, client_boot_failure_reason())
end

local api = {}
mod.api = api

K.NO_LOCAL_CANDIDATES_REASON = "no local candidates available to knock with"

local function candidates_empty_message()
    local state = endpoints_instance and endpoints_instance.status()
    if state == "unavailable" then
        return mod:localize("join_no_candidates_no_dll")
    elseif state == "gathering" then
        return mod:localize("join_no_candidates_stun_pending")
    elseif state == "degraded" or state == "stale" then
        return mod:localize("join_no_candidates_stun_failed")
    end
    return mod:localize("join_no_candidates_generic")
end

function api.refresh_endpoints()
    if endpoints_instance then
        endpoints_instance.refresh()
    end
end

local function trimmed_code(text)
    return text:match("^%s*(.-)%s*$")
end

local function fire_pending_knock()
    if not active then
        return
    end

    local ref = active.host_ref
    local ok = active.rendezvous.begin_join(ref, ref.id)
    if not ok then
        local _, reason = active.rendezvous.state()
        presence_instance.unwatch(ref)
        active = nil
        if reason == K.NO_LOCAL_CANDIDATES_REASON then
            resolve_error = candidates_empty_message()
        else
            resolve_error = reason or "could not begin the join"
        end
    end
end

local function begin_join_with_ref(ref)
    if endpoints_instance then
        local state = endpoints_instance.status()
        if state == "idle" or state == "stale" or state == "degraded" then
            endpoints_instance.refresh()
        end
    end

    local watch_ok, watch_err = presence_instance.watch(ref)
    if not watch_ok and discovery_instance then
        if discovery_instance.release_lowest_priority() then
            watch_ok, watch_err = presence_instance.watch(ref)
        end
    end
    if not watch_ok then
        active = nil
        resolve_error = watch_err or "could not watch this account for the join"
        log_gated("begin_join_with_ref: could not take a presence watch on " ..
            tostring(ref and ref.id) .. " - " .. tostring(resolve_error))
        return
    end

    local punch_instance = punch.new({ now = clock, fire = punch_fire, horizon = 3.0, rounds = 3 })
    local rendezvous_instance = rendezvous.new({
        punch = punch_instance,
        presence = presence_instance,
        protocol = protocol,
        clock = clock,
        join = realms_join,
        log = log_gated,
        candidates_provider = function()
            return endpoints_instance and endpoints_instance.list() or {}
        end,
        endpoint_status = function()
            return endpoints_instance and endpoints_instance.status() or nil
        end,
        knock_timeout = K.KNOCK_TIMEOUT_SECONDS,
        joining_timeout = K.REALMS_CLIENT_BOOT_BUDGET_SECONDS,
        accept_wire_allowance = K.ACCEPT_WIRE_ALLOWANCE_SECONDS,
    })

    active = { rendezvous = rendezvous_instance, punch = punch_instance, host_ref = ref }

    local status = endpoints_instance and endpoints_instance.status()
    if knock_gate.decide({ status = status }) == knock_gate.HOLD then
        pending_knock = { deadline = clock() + K.ENDPOINT_WAIT_SECONDS }
        log_gated("join: holding the knock to " .. tostring(ref.id) ..
            " until the public address is worked out, up to " ..
            tostring(K.ENDPOINT_WAIT_SECONDS) .. "s")
        return
    end

    fire_pending_knock()
end

local function can_start_join(requires_presence)
    if active then
        local state = active.rendezvous.state()
        if state ~= "idle" and state ~= "done" and state ~= "failed" then
            return false, "a join is already in progress"
        end
        active.punch.cancel()
    end
    if pending_resolve then
        return false, "still resolving the previous friend code"
    end
    if requires_presence ~= false then
        if not presence_instance or not resolver_instance then
            return false, "Realms Connect has not finished loading yet"
        end
        if not manifold then
            return false, mod:localize("join_needs_vox_manifold")
        end
    end
    if not session_ready() then
        return false, mod:localize("join_needs_a_session")
    end
    if realms_session_active() then
        return false, mod:localize("join_already_in_session")
    end
    if responder_instance and responder_instance.state() ~= "idle" then
        return false, mod:localize("join_channel_busy")
    end
    return true
end

function api.join_account(account_id, password, source)
    if type(account_id) ~= "string" or account_id == "" then
        return false, "no account to join"
    end

    local ok, reason = can_start_join()
    if not ok then
        return false, reason
    end

    join_password = type(password) == "string" and password or ""
    resolve_error = nil
    local route = source == "code" and "a friend code the player typed"
        or source == "scan" and "a lobby found by scanning friends"
        or "an unrecorded route (" .. tostring(source) .. ")"
    log_gated("join: connecting to " .. tostring(account_id) .. " via " .. route)
    begin_join_with_ref({ id = account_id })
    return true
end

function api.join(code_text, password)
    if type(code_text) ~= "string" then
        return false, "enter a friend code first"
    end
    local trimmed = trimmed_code(code_text)
    if trimmed == "" then
        return false, "enter a friend code first"
    end

    local allowed, why = can_start_join()
    if not allowed then
        return false, why
    end

    join_password = type(password) == "string" and password or ""

    local token = join_token
    resolve_error = nil
    pending_resolve = { code = trimmed, deadline = clock() + K.FRIEND_CODE_RESOLVE_TIMEOUT_SECONDS }
    join_pending = true

    resolver_instance.resolve(trimmed, function(ok, ref, reason)
        if token ~= join_token then
            return
        end
        if not pending_resolve or pending_resolve.code ~= trimmed then
            return
        end
        pending_resolve = nil
        join_pending = false
        if not ok then
            resolve_error = reason
            return
        end
        begin_join_with_ref(ref)
    end)

    return true
end

function api.is_direct_address(text)
    if type(text) ~= "string" then
        return false
    end
    local ip, port = string_match(text, "^%s*(.+):(%d+)%s*$")
    return ip ~= nil and port ~= nil
end

function api.join_manual(address_text, password)
    local ip, port = string_match(address_text or "", "^%s*(.+):(%d+)%s*$")
    if not ip then
        return false, "enter the address as ip:port"
    end
    if pending_join then
        return false, "a join is already in progress"
    end

    local allowed, why = can_start_join(false)
    if not allowed then
        return false, why
    end

    local session, err = realms_session()
    if not session then
        return false, err
    end

    local started, start_err = session.start_client(ip, port, password or "")
    if not started then
        return false, start_err or "Realms refused to start the client boot"
    end

    pending_join = {
        deadline = clock() + K.JOIN_POLL_TIMEOUT,
        on_result = function(ok, reason)
            if ok then
                echo_text(mod:localize("join_manual_succeeded"))
            else
                echo_text(mod:localize("join_manual_failed") .. ": " .. tostring(reason))
            end
        end,
    }
    return true
end

function api.cancel()
    join_token = join_token + 1
    pending_resolve = nil
    pending_knock = nil
    join_pending = false
    resolve_error = nil
    if active then
        active.rendezvous.cancel()
        release_active_host_watch(presence_instance)
    end
end

function api.connected()
    return realms_session_active()
end

function api.status()
    if pending_resolve then
        return "resolving"
    end
    if not active then
        if resolve_error then
            return "failed", resolve_error
        end
        return "idle"
    end

    if pending_knock then
        local left = math_ceil(pending_knock.deadline - clock())
        if left < 0 then
            left = 0
        end
        return "locating", nil, left
    end

    local state, reason = active.rendezvous.state()
    if state == "failed" and active.failure_note then
        return state, screen_text(tostring(reason) .. " - " .. active.failure_note)
    end

    local seconds_left
    if type(active.rendezvous.seconds_left) == "function" then
        seconds_left = active.rendezvous.seconds_left()
    end

    return state, screen_text(reason), seconds_left
end

local function scan_is_running()
    if not scan_instance then
        return false
    end
    local state = scan_instance.state()
    return state == scan_module.STATE_ENUMERATING or state == scan_module.STATE_SETTLING
end

function api.scan_friends()
    if not scan_instance then
        return false, mod:localize("scan_failed_no_presence")
    end

    if listen_instance then
        listen_instance.yield("a friends scan was started and needs the shared temporary watch pool")
    end

    local ok, reason = scan_instance.start()
    if ok then
        return true
    end

    local key = scan_module.FAILURE_KEYS[reason]
    if key then
        return false, mod:localize(key)
    end
    return false, mod:localize("scan_busy")
end

function api.cancel_scan()
    if scan_instance then
        scan_instance.cancel()
    end
end

function api.scan_state()
    if not scan_instance then
        return "idle"
    end
    return scan_instance.state()
end

function api.scan_results()
    if not scan_instance or type(scan_instance.results) ~= "function" then
        return {}
    end

    local rows = scan_instance.results()
    local out = {}

    for i = 1, #rows do
        local entry = rows[i]
        out[#out + 1] = {
            account_id = entry.account_id,
            name = entry.name,
            checked = entry.checked == true,
            running = entry.running == true,
            incompatible = entry.incompatible == true,
            hosting = entry.hosting == true,
            mission = entry.mission,
            players = entry.players,
            max = entry.max,
            locked = entry.locked == true,
            joinable = entry.hosting == true and entry.incompatible ~= true
                and type(entry.account_id) == "string" and entry.account_id ~= "",
        }
    end

    return out
end

function api.scan_lines(max_rows)
    if not scan_instance then
        return { mod:localize("scan_failed_no_presence") }
    end
    return scan_instance.lines(function(key) return mod:localize(key) end, max_rows)
end

function api.own_code()
    if not identity_instance then
        return nil, "Realms Connect has not finished loading yet"
    end
    local code, reason = identity_instance.friend_code()
    if not code then
        return nil, reason
    end
    return mask.apply_code(code, addresses_hidden()), reason
end

local function copy_to_clipboard(text, what)
    local clipboard = rawget(_G, "Clipboard")
    if type(clipboard) ~= "table" or type(clipboard.put) ~= "function" then
        log_fn("clipboard: the engine exposes no Clipboard.put, " .. what .. " cannot be copied")
        return false, mod:localize("join_view_own_code_copy_unavailable")
    end

    if not clipboard.put(text) then
        log_fn("clipboard: Clipboard.put refused " .. what)
        return false, mod:localize("join_view_own_code_copy_failed")
    end

    log_fn("clipboard: " .. what .. " was copied to the clipboard")
    return true, text
end

function api.copy_own_code()
    if not identity_instance then
        return false, "Realms Connect has not finished loading yet"
    end

    local own_code, reason = identity_instance.friend_code()
    if not own_code then
        return false, reason or mod:localize("join_view_own_code_unavailable")
    end

    return copy_to_clipboard(own_code, "the local friend code")
end

function api.copy_public_address()
    if not portmap_instance then
        return false, mod:localize("lobby_reach_copy_unavailable")
    end

    local ip, port = portmap_instance.mapping()
    if type(ip) ~= "string" or ip == "" then
        ip = endpoints_instance and endpoints_instance.public_ip() or nil
        port = nil
    end

    if type(ip) ~= "string" or ip == "" then
        return false, mod:localize("lobby_reach_copy_unavailable")
    end

    local text = port and (ip .. ":" .. tostring(port)) or ip
    return copy_to_clipboard(text, "the public address")
end

local function write_diag_file(text)
    local io_lib = Mods and Mods.lua and Mods.lua.io
    if not io_lib then
        return
    end
    local ok, f = pcall(io_lib.open, K.DIAG_REPORT_FILE, "w")
    if not ok or not f then
        print("[Realms Connect] could not open the diag report file for writing")
        return
    end
    f:write(text)
    f:close()
end

local function log_diag_report(text)
    log_fn("=== diagnostic report begin ===")
    local start = 1
    while true do
        local nl = string_find(text, "\n", start, true)
        if not nl then
            log_fn(string_sub(text, start))
            break
        end
        log_fn(string_sub(text, start, nl - 1))
        start = nl + 1
    end
    log_fn("=== diagnostic report end ===")
end

local function finalize_diag_report(report, auto)
    local resolver = mapping.new({})
    local tier, reason = resolver.resolve_tier(report)
    report.outcome = { tier = tier, reason = reason }

    local redaction = mod:get("rc_diag_redaction") or "masked"
    local text = diag.render(report, { redaction = redaction, mod_version = mod.version })

    log_diag_report(text)
    write_diag_file(text)
    if not auto then
        echo_text(diag.summary(report))
    end
end

mod:command("rc_diag", mod:localize("command_diag_description"), function()
    if diag_state.job then
        echo_text(mod:localize("rc_diag_already_running"))
        return
    end
    if not native.available then
        finalize_diag_report({ error = native.load_error or "native DLL not loaded" })
        return
    end

    local ok, err = native.diag.begin(realms_host_port())
    if not ok then
        print("[Realms Connect] /rc_diag: could not start the sweep - " .. tostring(err))
        echo_text(mod:localize("rc_diag_failed"))
        return
    end

    diag_state.job = { warned_overrun = false }
    echo_text(mod:localize("rc_diag_started"))
end)

local auto_diag_instance = auto_diag.new({
    native = native,
    state = diag_state,
    clock = clock,
    log = log_gated,
    cooldown = K.AUTO_DIAG_COOLDOWN_SECONDS,
    report_file = K.DIAG_REPORT_FILE,
    host_port = realms_host_port,
})

local log_environment_banner

local function describe_ref(ref)
    if type(ref) ~= "table" then
        return "<no ref>"
    end
    return tostring(ref.id)
end

local function other_mod_version(name)
    local other = get_mod(name)
    if not other then
        return "MISSING"
    end
    local ok, version = pcall(function() return other:get_metadata("version") end)
    return (ok and version) and tostring(version) or "present, version unknown"
end

local function describe_native()
    if not native.available then
        return "UNAVAILABLE (" .. tostring(native.load_error) .. ")"
    end
    local version, err = native.version()
    return "loaded, version " .. tostring(version or ("unknown: " .. tostring(err)))
end

log_environment_banner = function(at_boot)
    log_fn("=== Realms Connect " .. tostring(mod.version) .. " environment ===")
    if at_boot then
        log_fn("  (this banner runs before a session exists; account id and friend code below" ..
            " are expected to read unavailable here - run /rc_report once in a session, with the" ..
            " join view opened at least once, for live values)")
    end
    log_fn("  Vox Manifold: " .. other_mod_version("Vox Manifold") ..
        ", Realms: " .. other_mod_version("Realms"))
    log_fn("  native DLL: " .. describe_native())

    local session, guard_err = realms_session()
    log_fn("  Realms session entry point: " .. (session and "OK" or tostring(guard_err)))

    local account_id, account_err
    local code_text, code_err
    if identity_instance then
        account_id, account_err = identity_instance.account_id()
        code_text, code_err = identity_instance.friend_code_status()
    else
        account_err = "Realms Connect has not finished loading yet"
        code_err = account_err
    end
    log_fn("  this machine's account id: " .. tostring(account_id or ("unavailable - " .. tostring(account_err))))
    log_fn("  this machine's friend code: " .. tostring(code_text or ("unavailable - " .. tostring(code_err))))

    log_fn("  broadcast: open-lobby window " ..
        (broadcast_until and ("ACTIVE, " .. tostring(broadcast_until - clock()) .. "s left, advertising forced to open")
            or "not running, the saved advertise_mode is in force"))

    log_fn("  settings: advertise_mode=" .. tostring(mod:get("rc_advertise_mode")) ..
        " auto_accept_friends=" .. tostring(mod:get("rc_auto_accept_friends")) ..
        " port_mapping=" .. tostring(mod:get("rc_port_mapping")) ..
        " debug_mode=" .. tostring(mod:get("rc_debug_mode")))

    local saved = mod:get("rc_saved_codes")
    log_fn("  manual_address=" .. tostring(mod:get("rc_manual_address") ~= "" and mod:get("rc_manual_address") or "(none)") ..
        " saved_codes=" .. tostring(saved ~= "" and saved or "(empty)"))
end

mod:command("rc_report", mod:localize("command_report_description"), function()
    log_environment_banner()

    log_fn("=== Realms Connect state snapshot ===")
    log_fn("  session_ready=" .. tostring(session_ready()) ..
        " enabled=" .. tostring(enabled) .. " clock=" .. tostring(clock()))

    if endpoints_instance then
        local state, detail = endpoints_instance.status()
        local list = endpoints_instance.list()
        log_fn("  endpoints: " .. tostring(state) .. " - " .. tostring(detail))
        local rendered = "NONE, a join cannot start"
        if #list > 0 then
            rendered = table.concat(list, ", ")
        end
        log_fn("  local candidates (" .. tostring(#list) .. "): " .. rendered)
    else
        log_fn("  endpoints: not built")
    end

    if discovery_instance then
        local watched = discovery_instance.watched()
        log_fn("  discovery watching " .. tostring(#watched) .. " account(s):")
        for i = 1, #watched do
            log_fn("    " .. describe_ref(watched[i].ref) ..
                " source=" .. tostring(watched[i].source) .. " confirmed via " .. tostring(watched[i].via))
        end
        local dropped = discovery_instance.dropped()
        log_fn("  discovery dropped " .. tostring(#dropped) .. " candidate(s):")
        for i = 1, #dropped do
            log_fn("    " .. describe_ref(dropped[i].ref) .. " - " .. tostring(dropped[i].reason))
        end
    else
        log_fn("  discovery: not built")
    end

    if listen_instance then
        local listening = listen_instance.listening()
        log_fn("  listening while discoverable to " .. tostring(#listening) .. " account(s):")
        for i = 1, #listening do
            log_fn("    " .. describe_ref(listening[i].ref) ..
                " source=" .. tostring(listening[i].source) ..
                (listening[i].pinned and " PINNED" or " rotating"))
        end
        local not_listened = listen_instance.dropped()
        log_fn("  not listened to, " .. tostring(#not_listened) .. " account(s):")
        for i = 1, #not_listened do
            log_fn("    " .. describe_ref(not_listened[i].ref) ..
                " source=" .. tostring(not_listened[i].source) ..
                " - " .. tostring(not_listened[i].reason))
        end
    else
        log_fn("  listening while discoverable: not built")
    end

    if responder_instance then
        local state, queued = responder_instance.state()
        log_fn("  responder: " .. tostring(state) .. " queue=" .. tostring(queued) ..
            " own_code=" .. tostring(responder_own_code) ..
            " active=" .. tostring(responder_instance.active_nonce()))
        local request = responder_instance.pending()
        if request then
            log_fn("    waiting on a human to confirm the knock from " .. describe_ref(request.ref) ..
                " nonce=" .. tostring(request.nonce) ..
                ", expires at " .. tostring(request.deadline) ..
                ", listed in the join window for the player to answer")
        end
    else
        log_fn("  responder: not built, this machine cannot answer a knock")
    end

    if active then
        local state, reason = active.rendezvous.state()
        log_fn("  active join: " .. tostring(state) .. (reason and (" - " .. tostring(reason)) or ""))
    else
        log_fn("  active join: none")
    end

    log_fn("  Realms host: advertisable=" .. tostring(realms_is_advertisable_host()) ..
        " private_mode=" .. tostring(realms_setting("private_mode")))

    local beacon_info = host_beacon_info()
    if beacon_info then
        log_fn("  beacon fields: mission=" .. tostring(beacon_info.mission) ..
            " players=" .. tostring(beacon_info.players) ..
            " max=" .. tostring(beacon_info.max) ..
            " locked=" .. tostring(beacon_info.locked))
    else
        log_fn("  beacon fields: none, this machine is not hosting a Realm")
    end
    log_fn("  beacon published=" .. tostring(beacon_signature ~= nil) ..
        " presence has a payload=" .. tostring(presence_instance ~= nil and presence_instance.has_payload()))

    if scan_instance then
        local scan_state, scan_reason = scan_instance.state()
        local checked, total = scan_instance.progress()
        log_fn("  friends scan: " .. tostring(scan_state) ..
            (scan_reason and (" - " .. tostring(scan_reason)) or "") ..
            " checked " .. tostring(checked) .. "/" .. tostring(total) ..
            " holding temporary watches=" .. tostring(scan_instance.holds_temp_watches()))
    else
        log_fn("  friends scan: not built")
    end

    log_fn("  pending Realms client boot: " .. tostring(pending_join ~= nil))
    log_fn("=== end snapshot ===")
    echo_text(mod:localize("rc_report_written"))
end)

local function responder_candidates()
    return endpoints_instance and endpoints_instance.list() or {}
end

local function release_presence_until_session()
    if discovery_instance then
        discovery_instance.stop()
    end
    if scan_instance then
        scan_instance.cancel()
    end
    if listen_instance then
        listen_instance.reset()
    end
    beacon_signature = nil
    beacon_refused_signature = nil
    broadcast_until = nil
    broadcast_was_active = false
    join_token = join_token + 1
    pending_resolve = nil
    pending_knock = nil
    join_pending = false
    if active then
        active.rendezvous.cancel()
        active = nil
    end
    if responder_instance then
        responder_instance.cancel()
    end
    if presence_instance then
        if presence_instance.has_payload() then
            presence_instance.retract()
        end
        presence_instance.unwatch_all()
    end
    host_watched = {}
    host_watch_signature = nil
    code_lookup = nil
    if portmap_instance then
        portmap_instance.release()
    end
    if endpoints_instance then
        endpoints_instance.clear_mapping()
    end
end

local function build_responder()
    if not identity_instance or not presence_instance or not advertise_instance then
        return
    end

    local account_id = identity_instance.account_id()
    if not account_id or account_id == responder_own_code then
        return
    end

    if not responder_punch then
        responder_punch = punch.new({ now = clock, fire = punch_fire, horizon = 3.0, rounds = 3 })
    end

    responder_own_code = account_id
    responder_instance = responder.new({
        punch = responder_punch,
        presence = presence_instance,
        protocol = protocol,
        clock = clock,
        candidates_provider = responder_candidates,
        decide = function(ref)
            local decision = advertise_instance.decide(ref)
            if decision == advertise.DECISION_ALLOW then
                remembered.add(ref)
            end
            return decision
        end,
        own_short_code = responder_own_code,
        prompt_timeout = K.ACCEPT_PROMPT_TIMEOUT_SECONDS,
        channel_busy = knock_owns_the_channel,
        log = log_gated,
        on_punch_timeout = function()
            auto_diag_instance.maybe("we could not punch through to a peer we accepted")
        end,
        connections = function()
            local connection = realms_host_connection()
            if not connection then
                return nil
            end
            return connection_number(connection, "num_connections")
        end,
        on_peer_unreachable = function()
            auto_diag_instance.maybe("a peer we acked reported they could not reach any of our candidates")
        end,
    })
end

local input_utils_module
local input_utils_missing

local function accept_input_text(alias)
    if input_utils_missing then
        return ""
    end

    if not input_utils_module then
        local ok, module = pcall(require, "scripts/managers/input/input_utils")
        if not ok or type(module) ~= "table" then
            input_utils_missing = true
            log_fn("knock notification: InputUtils could not be read, the accept hint will name no key")
            return ""
        end
        input_utils_module = module
    end

    local ok, text = pcall(input_utils_module.input_text_for_current_input_device,
        "View", alias or knock_notification.ACCEPT_ALIAS, true)
    if not ok or type(text) ~= "string" then
        return ""
    end
    return text
end

local function requests_view_active()
    local ui = Managers.ui
    if not knock_notice_view_name or not ui or type(ui.view_active) ~= "function" then
        return false
    end

    local ok, is_active = pcall(ui.view_active, ui, knock_notice_view_name)
    return ok and is_active == true
end

local party_invite_probe_warned = false

local function party_invite_active()
    local party = Managers.party_immaterium
    if not party then
        return false
    end

    local active, readable = knock_notification.party_invite_state(party._invite_notification_handler)

    if not readable and not party_invite_probe_warned then
        party_invite_probe_warned = true
        log_fn("knock notification: Managers.party_immaterium._invite_notification_handler could not be read, " ..
            "so a live party invite can no longer be detected and the refuse key may also accept one")
    end

    return active
end

local function knock_notice_suppressed()
    return knock_notification.should_suppress({
        view_active = requests_view_active(),
        party_invite_active = party_invite_active(),
    })
end

local function trigger_event(name, ...)
    local events = Managers.event
    if not events or type(events.trigger) ~= "function" then
        return
    end
    pcall(events.trigger, events, name, ...)
end

local function build_knock_notice()
    if knock_notice then
        return knock_notice
    end

    knock_notice = knock_notification.new({
        pending = function()
            return api.pending_request()
        end,
        accept = function(nonce)
            return api.accept_request(nonce)
        end,
        decline = function(nonce)
            return api.decline_request(nonce)
        end,
        suppressed = knock_notice_suppressed,
        localize = function(key)
            return mod:localize(key)
        end,
        input_text = accept_input_text,
        echo = function(text)
            echo_text(tostring(text))
        end,
        events = {
            add = function(kind, data, cb)
                trigger_event("event_add_notification_message", kind, data, cb)
            end,
            remove = function(id)
                trigger_event("event_remove_notification", id)
            end,
            progress = function(id, value)
                trigger_event("event_update_notification_progress", id, value)
            end,
        },
        pressed = function(alias)
            local input = Managers.input
            if not input or type(input.get_input_service) ~= "function" then
                return false
            end

            local found, service = pcall(input.get_input_service, input, "View")
            if not found or type(service) ~= "table" or type(service.get) ~= "function" then
                return false
            end

            local read, value = pcall(service.get, service, alias)
            return read and value == true
        end,
        log = log_gated,
    })

    return knock_notice
end

local ref_key = load_module("util/ref").key

local function confirmed_signature(confirmed)
    local keys = {}
    for i = 1, #confirmed do
        keys[#keys + 1] = ref_key(confirmed[i].ref)
    end
    table_sort(keys)
    return table_concat(keys, ",")
end

local function broadcast_seconds_left()
    if not broadcast_until then
        return 0
    end

    local remaining = broadcast_until - clock()
    if remaining <= 0 then
        broadcast_until = nil
        log_fn("broadcast: the open-lobby window elapsed, advertising falls back to the saved setting")
        return 0
    end

    return remaining
end

local function effective_advertise_mode()
    if broadcast_seconds_left() > 0 then
        return "open"
    end
    return mod:get("rc_advertise_mode")
end

function api.broadcast_state()
    local remaining = broadcast_seconds_left()
    return {
        active = remaining > 0,
        seconds_left = remaining,
        mode = effective_advertise_mode(),
    }
end

function api.broadcast_open()
    if not session_ready() then
        return false, mod:localize("join_needs_a_session")
    end

    broadcast_until = clock() + K.BROADCAST_WINDOW_SECONDS
    host_watch_signature = nil
    if listen_instance then
        listen_instance.invalidate()
    end
    log_fn("broadcast: opening this lobby to anyone reachable for " ..
        tostring(K.BROADCAST_WINDOW_SECONDS) .. "s")
    return true, K.BROADCAST_WINDOW_SECONDS
end

function api.stop_broadcast()
    if not broadcast_until then
        return false
    end

    broadcast_until = nil
    host_watch_signature = nil
    if listen_instance then
        listen_instance.invalidate()
    end
    log_fn("broadcast: the open-lobby window was stopped by the player")
    return true
end

mod.rc_open_lobby_pressed = function()
    local opened, detail = api.broadcast_open()
    local text

    if opened then
        text = (mod:localize("rc_open_lobby_echo")
            :gsub("{seconds}", string_format("%d", tonumber(detail) or 0)))
    elseif type(detail) == "string" and detail ~= "" then
        text = detail
    else
        text = mod:localize("lobby_broadcast_failed")
    end

    echo_text(text)
    trigger_event("event_add_notification_message", "alert", { text = screen_text(text) })
end

function remembered.list()
    local raw = mod:get(remembered.KEY)
    if remembered.parsed and raw == remembered.raw then
        return remembered.parsed
    end
    local out = {}
    if type(raw) == "string" and raw ~= "" then
        for id in string.gmatch(raw, "[^,]+") do
            local trimmed = string_match(id, "^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then
                out[#out + 1] = trimmed
            end
        end
    end
    remembered.raw = raw
    remembered.parsed = out
    return out
end

function remembered.contains(ref)
    local id = type(ref) == "table" and ref.id or nil
    if type(id) ~= "string" then
        return false
    end
    local list = remembered.list()
    for i = 1, #list do
        if list[i] == id then
            return true
        end
    end
    return false
end

function remembered.add(ref)
    local id = type(ref) == "table" and ref.id or ref
    if type(id) ~= "string" or id == "" then
        return false
    end

    local list = remembered.list()
    local kept = { id }
    for i = 1, #list do
        if list[i] ~= id and #kept < remembered.CAP then
            kept[#kept + 1] = list[i]
        end
    end

    local joined = table_concat(kept, ",")
    if joined == mod:get(remembered.KEY) then
        return false
    end

    mod:set(remembered.KEY, joined, false)
    log_fn("remembered " .. tostring(id) ..
        " as someone this machine has connected with, so their knock is heard next time (" ..
        tostring(#kept) .. " of " .. tostring(remembered.CAP) .. ")")
    return true
end

local manual_warning = {}

local function warn_about_manual_address()
    local connection = realms_host_connection()
    if not connection then
        return
    end

    local raw = mod:get("rc_manual_address")
    local manual = type(raw) == "string" and string_match(raw, "^%s*(.-)%s*$") or ""
    local host_port = connection_number(connection, "local_port")
    if manual == manual_warning.text and host_port == manual_warning.port then
        return
    end
    manual_warning.text = manual
    manual_warning.port = host_port

    if manual == "" then
        return
    end

    local problem = candidates.manual_problem(manual, host_port)
    if problem == candidates.MANUAL_UNUSABLE then
        echo_localized("chat_manual_address_unusable", { address = manual })
    elseif problem == candidates.MANUAL_LOCAL then
        echo_localized("chat_manual_address_local", { address = manual })
    elseif problem == candidates.MANUAL_PORT then
        local _, port = candidates.parse(manual)
        echo_localized("chat_manual_address_port", { port = port, host_port = host_port })
    end
end

local function sync_host_watches()
    if not presence_instance or not advertise_instance then
        return
    end

    local raw_codes = mod:get("rc_saved_codes")
    local mode = effective_advertise_mode()
    local hosting = realms_host_connection() ~= nil
    local confirmed = discovery_instance and discovery_instance.watched() or {}
    local known = remembered.list()
    local signature = tostring(hosting) .. "|" .. tostring(mode) .. "|" .. tostring(raw_codes) .. "|" ..
        table_concat(known, ",") .. "|" .. confirmed_signature(confirmed)
    if signature == host_watch_signature then
        return
    end
    host_watch_signature = signature

    local target = {}
    local ordered = {}
    if hosting and mode ~= "off" then
        for i = 1, #confirmed do
            local ref = confirmed[i].ref
            local key = ref_key(ref)
            if key and not target[key] then
                target[key] = ref
                ordered[#ordered + 1] = key
            end
        end
        for i = 1, #known do
            local ref = { id = known[i] }
            local key = ref_key(ref)
            if key and not target[key] then
                target[key] = ref
                ordered[#ordered + 1] = key
            end
        end
    end

    for key, ref in pairs(host_watched) do
        if not target[key] then
            presence_instance.unwatch(ref)
            host_watched[key] = nil
        end
    end
    for i = 1, #ordered do
        local key = ordered[i]
        if not host_watched[key] then
            local ok = presence_instance.watch(target[key])
            if ok then
                host_watched[key] = target[key]
            end
        end
    end
end

knock_owns_the_channel = function()
    if join_pending then
        return true
    end
    if clock() < unreachable_report_until then
        return true
    end
    if not active then
        return false
    end
    local astate = active.rendezvous.state()
    return astate == "knocking" or astate == "awaiting" or astate == "punching" or astate == "joining"
end

local function report_unreachable_to_host()
    if not presence_instance or not active or not active.host_ref then
        return
    end
    if active.host_released then
        return
    end

    local nonce, tried = active.rendezvous.report_context()
    if nonce == nil then
        return
    end

    local payload, why = protocol.build_unreachable(nonce, tried or 0)
    if not payload then
        log_fn("join: could not build the unreachable report for the host - " .. tostring(why))
        return
    end

    local ok, reason = presence_instance.publish(payload)
    if ok == false then
        log_fn("join: could not tell the host we never reached them - " .. tostring(reason))
        return
    end

    unreachable_report_until = clock() + K.UNREACHABLE_REPORT_HOLD_SECONDS
    log_fn("join: told the host we could not reach any of the " .. tostring(tried or 0) ..
        " candidate(s) they offered, holding the channel " ..
        tostring(K.UNREACHABLE_REPORT_HOLD_SECONDS) .. "s so it is not overwritten")
end

local function annotate_join_failure()
    if not active or active.failure_note ~= nil or not presence_instance or not active.host_ref then
        return
    end
    if active.host_released then
        return
    end

    if type(active.rendezvous.failure_kind) == "function"
        and active.rendezvous.failure_kind() == rendezvous.FAIL_UNREACHABLE then
        local detail = type(active.rendezvous.failure_detail) == "function"
            and active.rendezvous.failure_detail() or nil
        if not detail then
            active.failure_note = mod:localize("join_host_unreachable")
        end
        return
    end

    local info = presence_instance.peer_info(active.host_ref)
    if type(info) ~= "table" then
        return
    end

    if info.incompatible then
        active.failure_note = mod:localize("join_host_incompatible")
    elseif info.mod_version == nil then
        active.failure_note = mod:localize("join_host_not_running_the_mod")
    else
        active.failure_note = mod:localize("join_host_running_but_silent")
    end
end

local archetype_symbols = {}
local archetype_icons
local archetype_icons_read = false

local function archetype_icon_table()
    if archetype_icons_read then
        return archetype_icons
    end
    archetype_icons_read = true
    local loaded, ui_settings = pcall(require, "scripts/settings/ui/ui_settings")
    if loaded and type(ui_settings) == "table" then
        archetype_icons = ui_settings.archetype_font_icon
    end
    return archetype_icons
end

local function peer_archetype_symbol(ref)
    if type(ref) ~= "table" or type(ref.id) ~= "string" then
        return nil
    end

    local cached = archetype_symbols[ref.id]
    if cached ~= nil then
        if cached == false then
            return nil
        end
        return cached
    end

    local presence_manager = Managers.presence
    if not presence_manager or type(presence_manager.get_presence) ~= "function" then
        return nil
    end

    local ok, entry = pcall(presence_manager.get_presence, presence_manager, ref.id)
    if not ok or type(entry) ~= "table" or type(entry.character_profile) ~= "function" then
        return nil
    end

    local read, profile = pcall(entry.character_profile, entry)
    if not read or type(profile) ~= "table" then
        return nil
    end

    local archetype = profile.archetype
    if type(archetype) ~= "table" or type(archetype.name) ~= "string" then
        return nil
    end

    local icons = archetype_icon_table()
    if type(icons) ~= "table" then
        return nil
    end

    local symbol = icons[archetype.name]
    archetype_symbols[ref.id] = symbol or false
    return symbol
end

K.PEER_NAME_MAX_CHARS = 24

local function peer_display_name(ref)
    local id = ref and ref.id
    if type(id) ~= "string" or id == "" then
        return "?"
    end

    local presence_manager = Managers.presence
    if presence_manager and type(presence_manager.get_presence) == "function" then
        local ok, entry = pcall(presence_manager.get_presence, presence_manager, id)
        if ok and type(entry) == "table" and type(entry.character_name) == "function" then
            local named, name = pcall(entry.character_name, entry)
            if named and type(name) == "string" and name ~= "" then
                if #name > K.PEER_NAME_MAX_CHARS then
                    return name:sub(1, K.PEER_NAME_MAX_CHARS)
                end
                return name
            end
        end
    end

    return id:sub(1, 8)
end

local function peer_descriptor(ref)
    local name = peer_display_name(ref)

    local relationship = mod:localize("accept_prompt_stranger")
    if advertise_instance and advertise_instance.is_known_friend(ref) then
        relationship = mod:localize("accept_prompt_friend")
    end

    local compatibility = mod:localize("accept_prompt_version_unknown")
    if presence_instance then
        local info = presence_instance.peer_info(ref)
        if type(info) == "table" then
            if info.incompatible then
                compatibility = mod:localize("accept_prompt_version_incompatible")
            elseif info.mod_version ~= nil then
                compatibility = mod:localize("accept_prompt_version_compatible") .. " " .. tostring(info.mod_version)
            end
        end
    end

    return name, relationship, compatibility
end

local function describe_request(request)
    local name, relationship, compatibility = peer_descriptor(request.ref)
    local remaining

    if request.deadline then
        remaining = request.deadline - clock()
        if remaining < 0 then
            remaining = 0
        end
    end

    return {
        nonce = request.nonce,
        name = name,
        symbol = peer_archetype_symbol(request.ref),
        relationship = relationship,
        compatibility = compatibility,
        seconds_left = remaining,
        prompting = request.prompting ~= false,
    }
end

function api.join_requests()
    if not responder_instance or type(responder_instance.requests) ~= "function" then
        return {}
    end

    local requests = responder_instance.requests()
    local out = {}

    for i = 1, #requests do
        out[#out + 1] = describe_request(requests[i])
    end

    return out
end

function api.look_up_code(code_text)
    if type(code_text) ~= "string" then
        return false, "enter a friend code first"
    end

    local trimmed = trimmed_code(code_text)
    if trimmed == "" then
        return false, "enter a friend code first"
    end

    if not presence_instance or not resolver_instance then
        return false, "Realms Connect has not finished loading yet"
    end

    if not session_ready() then
        return false, mod:localize("join_needs_a_session")
    end

    api.clear_looked_up_code()

    code_lookup = {
        code = trimmed,
        entry = { name = trimmed, pending = true, joinable = false },
    }

    local token = join_token

    resolver_instance.resolve(trimmed, function(ok, ref, reason)
        if token ~= join_token or not code_lookup or code_lookup.code ~= trimmed then
            return
        end

        if not ok then
            code_lookup.entry.pending = false
            code_lookup.entry.running = false
            code_lookup.entry.reason = reason
            log_fn("look_up_code: " .. tostring(trimmed) .. " did not resolve - " .. tostring(reason))
            return
        end

        local watch_ok, watch_err = presence_instance.watch(ref)
        if not watch_ok then
            code_lookup.entry.pending = false
            code_lookup.entry.running = false
            code_lookup.entry.reason = watch_err
            log_fn("look_up_code: could not watch " .. tostring(ref and ref.id) ..
                " - " .. tostring(watch_err))
            return
        end

        code_lookup.ref = ref
        code_lookup.entry.account_id = ref.id
        log_fn("look_up_code: watching " .. tostring(ref.id) .. " for their beacon")
    end)

    return true
end

function api.looked_up_code()
    return code_lookup and code_lookup.entry or nil
end

function api.clear_looked_up_code()
    if not code_lookup then
        return false
    end

    if code_lookup.ref and presence_instance then
        presence_instance.unwatch(code_lookup.ref)
    end

    code_lookup = nil
    return true
end

local function refresh_code_lookup()
    if not code_lookup or not code_lookup.ref or not presence_instance then
        return
    end

    local info = presence_instance.peer_info(code_lookup.ref)
    local entry = code_lookup.entry

    if type(info) ~= "table" then
        return
    end

    entry.pending = false
    entry.mod_version = info.mod_version
    entry.incompatible = info.incompatible == true
    entry.running = info.mod_version ~= nil or info.incompatible == true

    local beacon = protocol.read_beacon(info.payload)
    if beacon then
        entry.hosting = true
        entry.mission = beacon.mission
        entry.players = beacon.players
        entry.max = beacon.max
        entry.locked = beacon.locked
        entry.in_progress = beacon.in_progress
        entry.accepting = beacon.accepting
        entry.mission_label = mission_label(beacon.mission)
        entry.circumstance_labels = circumstance_labels(beacon.circumstance, beacon.modifiers)
    else
        entry.hosting = false
    end

    entry.joinable = entry.hosting == true and not entry.incompatible
        and not (entry.in_progress == true and entry.accepting == false)
    entry.symbol = entry.symbol or peer_archetype_symbol(code_lookup.ref)
end

function api.reachability()
    if not portmap_instance then
        return nil
    end

    local state, detail = portmap_instance.state()

    detail = screen_text(detail)

    if state == portmap.STATE_MAPPED then
        local ip, port = portmap_instance.mapping()
        return "mapped", screen_text(mod:localize("lobby_reach_mapped")
            :gsub("{address}", tostring(ip) .. ":" .. tostring(port)))
    elseif state == portmap.STATE_CGNAT then
        return "cgnat", mod:localize("lobby_reach_cgnat")
    elseif state == portmap.STATE_REQUESTING then
        return "working", mod:localize("lobby_reach_working")
    elseif state == portmap.STATE_FAILED then
        return "no_upnp", mod:localize("lobby_reach_no_upnp"), detail
    elseif state == portmap.STATE_UNAVAILABLE then
        return "punch", mod:localize("lobby_reach_no_native")
    elseif state == portmap.STATE_OFF then
        return "punch", mod:localize("lobby_reach_off")
    end

    return "punch", mod:localize("lobby_reach_punch"), detail
end

function api.requests_full()
    if not responder_instance or type(responder_instance.queue_full) ~= "function" then
        return false
    end
    return responder_instance.queue_full()
end

function api.pending_request()
    if not responder_instance then
        return nil
    end

    local request = responder_instance.pending()
    if not request then
        return nil
    end

    return describe_request({
        ref = request.ref,
        nonce = request.nonce,
        deadline = request.deadline,
        prompting = true,
    })
end

function api.accept_request(nonce)
    if not responder_instance then
        return false, "Realms Connect has not finished loading yet"
    end

    local request = responder_instance.pending()
    if not request then
        return false, mod:localize("accept_request_gone")
    end

    if nonce ~= nil and nonce ~= request.nonce then
        return false, mod:localize("accept_request_gone")
    end

    remembered.add(request.ref)

    return responder_instance.accept(request.nonce)
end

function api.decline_request(nonce)
    if not responder_instance then
        return false, "Realms Connect has not finished loading yet"
    end

    local request = responder_instance.pending()
    if not request then
        return false, mod:localize("accept_request_gone")
    end

    if nonce ~= nil and nonce ~= request.nonce then
        return false, mod:localize("accept_request_gone")
    end

    return responder_instance.decline(request.nonce)
end

local function beacon_signature_of(info)
    return tostring(info.mission) .. "|" .. tostring(info.players) ..
        "|" .. tostring(info.max) .. "|" .. tostring(info.locked)
end

local function retract_beacon()
    beacon_signature = nil
    if presence_instance.has_payload() then
        presence_instance.retract()
    end
end

local function refresh_beacon()
    if not presence_instance or not advertise_instance then
        return
    end

    local responder_state = responder_instance and responder_instance.state() or "idle"
    local action = advertise_instance.beacon_action(
        realms_is_advertisable_host(), responder_state, knock_owns_the_channel())

    if action == advertise.ACTION_HOLD then
        beacon_signature = nil
        return
    end

    if action == advertise.ACTION_RETRACT then
        retract_beacon()
        return
    end

    local info = host_beacon_info()
    if not info then
        retract_beacon()
        return
    end

    local signature = beacon_signature_of(info)
    if signature == beacon_signature and presence_instance.has_payload() then
        return
    end

    local ok, err = presence_instance.publish(protocol.build_beacon(info))
    if ok then
        beacon_signature = signature
        beacon_refused_signature = nil
    else
        beacon_signature = nil
        if beacon_refused_signature ~= signature then
            beacon_refused_signature = signature
            log_fn("beacon: could not publish this Realm's beacon - " .. tostring(err))
        end
    end
end

mod.update = function(dt)
    if not enabled then
        return
    end

    if not session_ready() then
        if session_was_ready ~= false then
            session_was_ready = false
            release_presence_until_session()
        end
        return
    end

    session_was_ready = true

    if endpoints_instance then
        endpoints_instance.update()
    end

    if portmap_instance then
        portmap_instance.update()

        local map_ip, map_port = portmap_instance.mapping()
        if map_ip and endpoints_instance then
            endpoints_instance.set_mapping(map_ip, map_port)
        elseif endpoints_instance then
            endpoints_instance.clear_mapping()
        end

        local pstate, pdetail = portmap_instance.state()
        if pstate ~= portmap_reported_state then
            portmap_reported_state = pstate

            if not portmap_advice_echoed[pstate]
                and (pstate == portmap.STATE_FAILED or pstate == portmap.STATE_CGNAT) then
                portmap_advice_echoed[pstate] = true
                local public = endpoints_instance and endpoints_instance.public_ip()
                if pstate == portmap.STATE_CGNAT then
                    echo_localized("chat_reach_cgnat", {
                        public = public or "not known yet",
                        detail = pdetail or "no detail given",
                    })
                else
                    echo_localized("chat_reach_no_upnp", {
                        public = public or "not known yet",
                        detail = pdetail or "no detail given",
                    })
                end
            end
        end
    end

    if discovery_instance then
        local hosting = realms_host_connection() ~= nil
        if hosting then
            if discovery_instance.resume() then
                log_gated("discovery: hosting a Realm, reading the friends list")
            end
            discovery_instance.update()
        elseif discovery_running then
            discovery_instance.stop()
            log_gated("discovery: not hosting a Realm, the friends list is not read")
        end
        discovery_running = hosting
    end

    build_responder()
    refresh_code_lookup()

    if loadwatch_instance then
        loadwatch_instance.update()
    end

    tick_view_patches()

    local broadcasting_now = broadcast_seconds_left() > 0
    if broadcast_was_active and not broadcasting_now and listen_instance then
        listen_instance.invalidate()
    end
    broadcast_was_active = broadcasting_now

    sync_host_watches()
    warn_about_manual_address()

    if listen_instance then
        listen_instance.update()

        if type(listen_instance.pacing) == "function" then
            local pacing = listen_instance.pacing()
            if pacing and pacing.over_capacity then
                if not listen_capacity_echoed then
                    listen_capacity_echoed = true
                    echo_localized("chat_listen_over_capacity", { count = pacing.rotatable })
                end
            else
                listen_capacity_echoed = false
            end
        end
    end

    if presence_instance then
        for ref, payload in presence_instance.read_all() do
            if payload.k == protocol.KIND_KNOCK then
                if responder_instance and not knock_owns_the_channel() and realms_host_connection() then
                    responder_instance.on_knock(ref, payload)
                end
            elseif payload.k == protocol.KIND_ACK or payload.k == protocol.KIND_PENDING then
                if active then
                    active.rendezvous.on_peer_payload(ref, payload)
                end
            elseif payload.k == protocol.KIND_UNREACHABLE then
                if responder_instance then
                    responder_instance.on_unreachable(ref, payload)
                end
            end
        end
    end

    if responder_instance then
        responder_instance.update()
        build_knock_notice().update()
    end
    refresh_beacon()

    if scan_instance then
        scan_instance.update()
    end

    if active then
        active.rendezvous.update()
        local state = active.rendezvous.state()
        if state == "done" or state == "failed" then
            if state == "done" then
                remembered.add(active.host_ref)
            end

            if state == "failed" then
                annotate_join_failure()

                if not active.failure_echoed then
                    active.failure_echoed = true
                    local _, reason = active.rendezvous.state()
                    local kind = type(active.rendezvous.failure_kind) == "function"
                        and active.rendezvous.failure_kind() or nil

                    if kind == rendezvous.FAIL_UNREACHABLE then
                        local detail = type(active.rendezvous.failure_detail) == "function"
                            and active.rendezvous.failure_detail() or nil
                        local full = reason or "no reason given"
                        if detail then
                            full = full .. ". " .. detail
                        end
                        echo_localized("chat_join_unreachable", {
                            host = peer_display_name(active.host_ref),
                            reason = full,
                        })
                        report_unreachable_to_host()
                        auto_diag_instance.maybe("a join failed with every candidate unreachable")
                    elseif kind == rendezvous.FAIL_NO_ANSWER then
                        echo_localized("chat_join_no_answer", {
                            host = peer_display_name(active.host_ref),
                        })
                    end
                end
            end
            release_active_host_watch(presence_instance)
        end
    end

    if pending_knock then
        local status = endpoints_instance and endpoints_instance.status()
        local expired = clock() >= pending_knock.deadline
        local verdict, reason = knock_gate.decide({ status = status, expired = expired })
        if verdict == knock_gate.FIRE then
            pending_knock = nil
            if reason == knock_gate.REASON_EXPIRED then
                log_fn("join: the public address did not arrive in time, knocking with what we have")
            end
            fire_pending_knock()
        end
    end

    if pending_resolve and clock() >= pending_resolve.deadline then
        join_token = join_token + 1
        pending_resolve = nil
        join_pending = false
        resolve_error = "friend code lookup timed out, try again"
        log_fn("api.join: the friend code resolve timed out after " ..
            tostring(K.FRIEND_CODE_RESOLVE_TIMEOUT_SECONDS) .. "s")
    end

    if pending_join then
        local session = realms_session()
        if session and type(session.is_active_client) == "function" and session.is_active_client() then
            local cb = pending_join.on_result
            pending_join = nil
            cb(true)
        elseif clock() >= pending_join.deadline then
            local cb = pending_join.on_result
            pending_join = nil
            cb(false, "Realms did not confirm the join before the local timeout")
        end
    end

    if diag_state.job then
        local auto = diag_state.job.auto
        local status, payload = native.diag.poll()
        if status == "ok" then
            finalize_diag_report(payload, auto)
            diag_state.job = nil
        elseif status == "overrun" then
            if not diag_state.job.warned_overrun then
                diag_state.job.warned_overrun = true
                log_fn("diagnostic sweep is past its expected budget (" .. tostring(payload) .. "), still waiting")
            end
        elseif status ~= "pending" then
            log_fn("diagnostic sweep failed - " .. tostring(payload))
            if not auto then
                echo_text(mod:localize("rc_diag_failed"))
            end
            diag_state.job = nil
        end
    end
end

K.MANIFOLD_REQUIRED = {
    "register", "unregister", "mark_dirty",
    "watch", "unwatch", "watch_temp", "release_temp", "watched",
    "get", "has_mod",
}

local function manifold_missing_functions(api)
    if type(api) ~= "table" then
        return nil
    end

    local missing = {}
    for i = 1, #K.MANIFOLD_REQUIRED do
        local name = K.MANIFOLD_REQUIRED[i]
        if type(api[name]) ~= "function" then
            missing[#missing + 1] = name
        end
    end

    if #missing == 0 then
        return nil
    end
    return missing
end


local function manifold_watch_caps()
    if type(manifold) ~= "table" or type(manifold.usage) ~= "function" then
        return K.DISCOVERY_CAP, K.LISTEN_CAP
    end
    local ok, usage = pcall(manifold.usage)
    local watches = ok and type(usage) == "table" and usage.watches or nil
    if type(watches) ~= "table" then
        return K.DISCOVERY_CAP, K.LISTEN_CAP
    end
    local permanent = type(watches.cap) == "number" and watches.cap or K.DISCOVERY_CAP
    local temp = type(watches.temp_cap) == "number" and watches.temp_cap or K.LISTEN_CAP
    return permanent, temp
end

local function initialize()
    local vm = get_mod("Vox Manifold")
    manifold = vm and vm.api

    local missing = manifold_missing_functions(manifold)
    if missing then
        manifold = nil
        mod:error("[Realms Connect] the installed Vox Manifold is too old: it is missing " ..
            table_concat(missing, ", ") ..
            ". Realms Connect needs Vox Manifold 2.2 or newer, from Nexus. " ..
            "Presence matchmaking is disabled for this session; a direct ip:port still works.")
    end

    local permanent_cap, temp_cap = manifold_watch_caps()

    presence_instance = presence.new({
        mod = mod,
        manifold = manifold,
        protocol = protocol,
        id = K.CONSUMER_ID,
        log = log_gated,
    })

    endpoints_instance = endpoints.new({
        native = native,
        candidates = candidates,
        clock = clock,
        manual = function() return mod:get("rc_manual_address") end,
        host_port = function()
            local connection = realms_host_connection()
            if not connection then
                return nil
            end
            return connection_number(connection, "local_port")
        end,
        log = log_gated,
    })
    endpoints_instance.refresh()

    loadwatch_instance = loadwatch.new({
        clock = clock,
        log = log_gated,
    })

    portmap_instance = portmap.new({
        native = native,
        candidates = candidates,
        clock = clock,
        enabled = function() return mod:get("rc_port_mapping") ~= false end,
        host_port = function()
            local connection = realms_host_connection()
            if not connection then
                return nil
            end
            return connection_number(connection, "local_port")
        end,
        public_ip = function()
            return endpoints_instance and endpoints_instance.public_ip() or nil
        end,
        log = log_gated,
    })

    if manifold then
        local ok, err = presence_instance.register()
        if not ok then
            mod:error("[Realms Connect] could not register with Vox Manifold: " .. tostring(err))
        end
    else
        print("[Realms Connect] Vox Manifold is not available; presence-based matchmaking is disabled, manual address entry still works")
    end

    resolver_instance = resolver_module.new({
        social = social_service,
        log = log_gated,
    })

    identity_instance = identity.new({
        player = function() return Managers.player end,
        connection = function() return Managers.connection end,
        social = social_service,
        log = log_gated,
    })

    scan_instance = scan_module.new({
        social = social_service,
        presence = presence_instance,
        protocol = protocol,
        clock = clock,
        session_ready = session_ready,
        batch_size = K.SCAN_BATCH_SIZE,
        settle_seconds = K.SCAN_SETTLE_SECONDS,
        max_friends = K.SCAN_MAX_FRIENDS,
        mission_label = mission_label,
        circumstance_labels = circumstance_labels,
        log = log_gated,
    })

    discovery_instance = discovery.new({
        social = social_service,
        party = function() return Managers.party_immaterium end,
        presence = presence_instance,
        clock = clock,
        saved_codes = function() return mod:get("rc_saved_codes") end,
        resolver = resolver_instance,
        cap = permanent_cap,
        refresh_interval = K.DISCOVERY_REFRESH_INTERVAL,
        force_gate = should_force_friend_refresh,
        force_interval = function() return mod:get("rc_friend_refetch_seconds") end,
        liveness = liveness_module.new({}),
        log = log_gated,
    })

    advertise_instance = advertise.new({
        resolver = resolver_instance,
        advertise_mode = effective_advertise_mode,
        saved_codes = function() return mod:get("rc_saved_codes") end,
        auto_accept_friends = function() return mod:get("rc_auto_accept_friends") end,
        auto_accept_in_mission = function() return mod:get("rc_auto_accept_friends_in_mission") end,
        in_mission = host_in_mission,
        is_friend = discovery_instance.is_friend,
        is_party = discovery_instance.is_party,
        is_remembered = remembered.contains,
    })

    listen_instance = listen_module.new({
        presence = presence_instance,
        enumerate = discovery_instance.enumerated,
        advertise_mode = effective_advertise_mode,
        already_watched = function(ref)
            return host_watched[ref_key(ref)] ~= nil
        end,
        scan_active = scan_is_running,
        clock = clock,
        cap = temp_cap,
        refresh_interval = K.LISTEN_REFRESH_INTERVAL,
        knock_deadline = K.KNOCK_TIMEOUT_SECONDS,
        joins_open = listen_gate,
        log = log_gated,
    })

    responder_punch = nil
    responder_own_code = nil
    build_responder()

    if Managers.event and type(Managers.event.register) == "function" then
        Managers.event:register(mod, "event_multiplayer_session_failed_to_boot", "rc_on_client_boot_failed")
    end

    log_environment_banner(true)
end

local view_patches_installed = false
local view_patches = {}

tick_view_patches = function()
    if #view_patches == 0 then
        return
    end

    local ui = Managers.ui
    if not ui or type(ui.view_instance) ~= "function" then
        return
    end

    for i = 1, #view_patches do
        local patch = view_patches[i]
        local ok, view = pcall(ui.view_instance, ui, patch.view_name)

        if ok and type(view) == "table" and view.loading and not view:loading() then
            local ran, err = pcall(patch.tick, view)
            if ran then
                patch.reported = nil
            elseif patch.reported ~= tostring(err) then
                patch.reported = tostring(err)
                log_fn("view patch for " .. tostring(patch.view_name) .. " raised: " .. tostring(err))
            end
        end
    end
end

local function install_view_patches()
    if view_patches_installed then
        return
    end

    if not pcall(require, "scripts/managers/ui/ui_widget") then
        return
    end

    view_patches_installed = true

    local style_module = load_module("views/realms_style")
    local lobby_patch = load_module("views/lobby_view_patch")
    local lobby_panel = load_module("views/lobby_panel")
    local lobby_install = load_module("views/lobby_install")
    local join_panel = load_module("views/join_panel")
    local join_install = load_module("views/join_install")

    local function localize(key)
        return mod:localize(key)
    end

    local dmf = get_mod("DMF")
    local ok_input, text_input_utils = pcall(function()
        return dmf:io_dofile("dmf/scripts/mods/dmf/modules/ui/options/text_input_utils")
    end)

    if ok_input and type(text_input_utils) == "table" then
        view_patches[#view_patches + 1] = join_install.install({
            mod = mod,
            style_module = style_module,
            log = log_gated,
            localize = localize,
            text_input_utils = text_input_utils,
            make_panel = function()
                return join_panel.new({ api = api, localize = localize })
            end,
        })
    else
        log_fn("join: DMF's text input helper could not be read, so the join-view section is not installed")
    end

    knock_notice_view_name = lobby_install.VIEW_NAME

    view_patches[#view_patches + 1] = lobby_install.install({
        mod = mod,
        patch = lobby_patch,
        style_module = style_module,
        log = log_gated,
        localize = localize,
        mission_row_count = function()
            local realms = get_mod("Realms")
            local preparation = realms and realms._preparation
            if type(preparation) ~= "table" or type(preparation.mission_details) ~= "function" then
                return 1
            end
            local ok, rows = pcall(preparation.mission_details)
            if not ok or type(rows) ~= "table" then
                return 1
            end
            return #rows
        end,
        make_panel = function()
            return lobby_panel.new({
                api = api,
                localize = localize,
                clock = clock,
                role = function()
                    local realms = get_mod("Realms")
                    local preparation = realms and realms._preparation
                    if type(preparation) ~= "table" or type(preparation.role) ~= "function" then
                        return "none"
                    end
                    local ok, role = pcall(preparation.role)
                    return ok and role or "none"
                end,
            })
        end,
    })
end

mod.on_all_mods_loaded = function()
    initialize()
    install_view_patches()
end

mod.on_enabled = function()
    if enabled then
        return
    end
    enabled = true
    initialize()
end

mod.on_setting_changed = function(setting_id)
    if not enabled then
        return
    end

    if setting_id == "rc_saved_codes" or setting_id == "rc_advertise_mode" then
        if discovery_instance and type(discovery_instance.force_refresh) == "function" then
            discovery_instance.force_refresh()
        end
        if listen_instance and type(listen_instance.invalidate) == "function" then
            listen_instance.invalidate()
        end
        host_watch_signature = nil
    elseif setting_id == "rc_port_mapping" then
        if portmap_instance and type(portmap_instance.update) == "function" then
            portmap_instance.update()
        end
    end

    log_gated("settings: " .. tostring(setting_id) .. " changed, re-applied without waiting for the next poll")
end

local function teardown(exit_game)
    enabled = false

    if Managers.event and type(Managers.event.unregister) == "function" then
        Managers.event:unregister(mod, "event_multiplayer_session_failed_to_boot")
    end

    join_token = join_token + 1
    pending_resolve = nil
    pending_knock = nil
    join_pending = false
    resolve_error = nil

    if active then
        active.rendezvous.cancel()
        release_active_host_watch(presence_instance)
        active = nil
    end

    if responder_instance then
        responder_instance.cancel()
    end

    if knock_notice then
        knock_notice.clear()
        knock_notice = nil
    end

    if discovery_instance then
        discovery_instance.stop()
    end

    if scan_instance then
        scan_instance.cancel()
    end

    if listen_instance then
        listen_instance.reset()
    end

    if portmap_instance then
        portmap_instance.release()
        portmap_instance = nil
    end

    if presence_instance then
        if presence_instance.has_payload() then
            presence_instance.retract()
        end
        presence_instance.unwatch_all()
        presence_instance.unregister()
    end

    if endpoints_instance then
        endpoints_instance.cancel()
    end

    destroy_browser(exit_game)

    for i = 1, #view_patches do
        if type(view_patches[i].uninstall) == "function" then
            view_patches[i].uninstall()
        end
    end

    if diag_state.job then
        print("[Realms Connect] on_unload: a diagnostic sweep is still running natively with no DiagCancel export; its result will be picked up on the next load instead of being abandoned silently")
    end

    host_watched = {}
    host_watch_signature = nil
    beacon_signature = nil
    beacon_refused_signature = nil
    broadcast_until = nil
    broadcast_was_active = false
    pending_join = nil
end

mod.on_unload = function(exit_game)
    teardown(exit_game == true)
end

mod.on_disabled = function()
    teardown(false)
end
