--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-13
--]]

local type = type
local tostring = tostring
local pcall = pcall
local string_format = string.format
local math_ceil = math.ceil
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

local DEFAULT_MAX_ROUNDS = 3
local DEFAULT_KNOCK_TIMEOUT = 30.0
local DEFAULT_ACK_WINDOW = 30.0
local DEFAULT_PUNCH_GRACE = 5.0
local DEFAULT_JOINING_TIMEOUT = 8.0
local DEFAULT_ACCEPT_WIRE_ALLOWANCE = 5.0
local DEFAULT_CANDIDATE_RETRY_DELAY = 2.5
local DEFAULT_BUSY_RETRY_DELAY = 3.0
local MAX_BUSY_RETRIES = 3
local BUSY_MARKER = "already in progress"

M.FAIL_UNREACHABLE = "unreachable"
M.FAIL_NO_ANSWER = "no_answer"

M.DEFAULT_CANDIDATE_RETRY_DELAY = DEFAULT_CANDIDATE_RETRY_DELAY
M.DEFAULT_BUSY_RETRY_DELAY = DEFAULT_BUSY_RETRY_DELAY
M.MAX_BUSY_RETRIES = MAX_BUSY_RETRIES

function M.is_busy_reason(reason)
    return type(reason) == "string" and reason:find(BUSY_MARKER, 1, true) ~= nil
end

local STATE_IDLE = "idle"
local STATE_KNOCKING = "knocking"
local STATE_AWAITING = "awaiting"
local STATE_PUNCHING = "punching"
local STATE_JOINING = "joining"
local STATE_DONE = "done"
local STATE_FAILED = "failed"

M.STATE_IDLE = STATE_IDLE
M.STATE_KNOCKING = STATE_KNOCKING
M.STATE_AWAITING = STATE_AWAITING
M.STATE_PUNCHING = STATE_PUNCHING
M.STATE_JOINING = STATE_JOINING
M.STATE_DONE = STATE_DONE
M.STATE_FAILED = STATE_FAILED

local function refs_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    return a.platform == b.platform and a.id == b.id
end

local function echoed_nonce(payload)
    local a = payload.a
    if a ~= nil then
        return a
    end
    return payload.n
end

local function pick_candidate(list, from)
    if type(list) ~= "table" then
        return nil
    end
    for i = from or 1, #list do
        local ip, port = candidates.parse(list[i])
        if ip then
            return ip, port, i
        end
    end
    return nil
end

local function noop() end

function M.describe_unreachable(ack_list, classifier)
    if type(ack_list) ~= "table" or #ack_list == 0 then
        return ""
    end

    local private_n, public_n = 0, 0
    local first_private
    for i = 1, #ack_list do
        local ip = classifier.parse(ack_list[i])
        if ip then
            if classifier.is_private_ip(ip) or classifier.is_carrier_nat_ip(ip) then
                private_n = private_n + 1
                first_private = first_private or ip
            else
                public_n = public_n + 1
            end
        end
    end

    if private_n == 0 or public_n > 0 then
        return ""
    end

    return "Every address they offered was a private one (" .. tostring(first_private) ..
        "), which only reaches them on their own network" ..
        ", so their game never worked out a public address for itself" ..
        ": they are behind carrier-grade NAT, or their router refused to forward a port" ..
        ". Swapping roles and letting them join you is the quickest thing to try."
end

function M.new(deps)
    deps = deps or {}
    local punch = deps.punch
    local presence = deps.presence
    local protocol = deps.protocol
    local clock = deps.clock
    local candidates_provider = deps.candidates_provider
    local endpoint_status = deps.endpoint_status
    local join = deps.join
    local log = deps.log or noop
    local max_rounds = deps.max_rounds or DEFAULT_MAX_ROUNDS
    local knock_timeout = deps.knock_timeout or DEFAULT_KNOCK_TIMEOUT
    local ack_window = deps.ack_window or DEFAULT_ACK_WINDOW
    local punch_grace = deps.punch_grace or DEFAULT_PUNCH_GRACE
    local joining_timeout = deps.joining_timeout or DEFAULT_JOINING_TIMEOUT
    local candidate_retry_delay = deps.candidate_retry_delay or DEFAULT_CANDIDATE_RETRY_DELAY
    local busy_retry_delay = deps.busy_retry_delay or DEFAULT_BUSY_RETRY_DELAY
    local max_busy_retries = deps.max_busy_retries or MAX_BUSY_RETRIES
    local accept_wire_allowance = deps.accept_wire_allowance or DEFAULT_ACCEPT_WIRE_ALLOWANCE
    local own_public_ip = deps.own_public_ip or noop

    local r = {}

    local state = STATE_IDLE
    local expected_ref
    local nonce
    local t_punch
    local ack_cands
    local tried_index
    local retry_at
    local retry_index
    local busy_retries
    local best_reason
    local fail_reason
    local fail_detail
    local fail_kind
    local deadline
    local knock_code
    local knock_cand_count
    local knock_status
    local nonce_seq = 0

    local function make_nonce()
        nonce_seq = nonce_seq + 1
        return string_format("%x-%x", clock() * 1000, nonce_seq)
    end

    local function fail(reason, kind)
        local was = state
        punch.cancel()
        fail_reason = reason
        fail_kind = kind
        state = STATE_FAILED
        deadline = nil

        local address_note = ""
        if was == STATE_KNOCKING and knock_status then
            local now_status = endpoint_status and endpoint_status() or nil
            address_note = " (our address was " .. tostring(knock_status) .. " when we knocked"
            if now_status and now_status ~= knock_status then
                address_note = address_note .. ", " .. tostring(now_status) .. " when it expired"
            end
            address_note = address_note .. ")"
        end

        local tried_note = ""
        if ack_cands then
            tried_note = " | they advertised " .. candidates.describe(ack_cands) ..
                ", we reached candidate " .. tostring(tried_index or 0) .. " of " .. tostring(#ack_cands)
        end

        log("rendezvous: FAILED in state " .. tostring(was) .. " nonce=" .. tostring(nonce) ..
            " - " .. reason .. address_note .. tried_note ..
            (fail_detail and fail_detail ~= "" and (" | " .. fail_detail) or ""))
    end

    local attempt_join

    local function on_join_result(ok, reason)
        if state ~= STATE_JOINING then
            return
        end
        if ok then
            state = STATE_DONE
            deadline = nil
            log("rendezvous: joined")
            return
        end

        if M.is_busy_reason(reason) then
            busy_retries = (busy_retries or 0) + 1

            if busy_retries <= max_busy_retries then
                retry_index = tried_index
                retry_at = clock() + busy_retry_delay
                deadline = retry_at + joining_timeout
                log("rendezvous: candidate " .. tostring(tried_index) ..
                    " was not tried, Realms is still holding the previous boot" ..
                    " (attempt " .. tostring(busy_retries) .. " of " .. tostring(max_busy_retries) ..
                    "), re-dialling the SAME candidate in " .. tostring(busy_retry_delay) .. "s")
                return
            end

            log("rendezvous: candidate " .. tostring(tried_index) ..
                " gave up after " .. tostring(max_busy_retries) ..
                " busy replies, moving on")
        else
            best_reason = reason or best_reason
        end

        busy_retries = nil

        local next_index = (tried_index or 0) + 1
        if pick_candidate(ack_cands, next_index) then
            retry_index = next_index
            retry_at = clock() + candidate_retry_delay
            deadline = retry_at + joining_timeout
            log("rendezvous: candidate " .. tostring(tried_index) .. " refused (" ..
                tostring(reason) .. "), waiting " .. tostring(candidate_retry_delay) ..
                "s for Realms to release the failed boot before trying the next one")
            return
        end

        local reported = best_reason or reason

        if tried_index and tried_index > 1 then
            fail_detail = M.describe_unreachable(ack_cands, candidates)
            fail("every candidate the host advertised refused, the clearest reason was: " ..
                tostring(reported or "no reason given"), M.FAIL_UNREACHABLE)
            return
        end

        fail(reported or "join failed", M.FAIL_UNREACHABLE)
    end

    attempt_join = function(from)
        local ip, port, index = pick_candidate(ack_cands, from)
        if not ip then
            if from and from > 1 then
                fail_detail = M.describe_unreachable(ack_cands, candidates)
                fail("every candidate the host advertised refused the connection")
            else
                fail("no usable candidate in the ack")
            end
            return
        end
        tried_index = index
        retry_at = nil
        retry_index = nil
        state = STATE_JOINING
        deadline = clock() + joining_timeout
        log("rendezvous: dialling candidate " .. tostring(index) .. " of " ..
            tostring(#ack_cands) .. " - " .. tostring(ip) .. ":" .. tostring(port))
        local ok, err = pcall(join, ip, port, on_join_result)
        if not ok then
            fail("join raised an error: " .. tostring(err))
        end
    end

    function r.begin_join(ref, code)
        if state ~= STATE_IDLE then
            log("rendezvous: begin_join refused, not idle")
            return false
        end

        expected_ref = ref
        nonce = make_nonce()
        t_punch = nil
        ack_cands = nil
        tried_index = nil
        retry_at = nil
        retry_index = nil
        busy_retries = nil
        best_reason = nil
        fail_reason = nil
        fail_detail = nil

        local own_cands = candidates_provider and candidates_provider()
        if type(own_cands) ~= "table" or #own_cands == 0 then
            fail("no local candidates available to knock with")
            return false
        end

        local knock = protocol.build_knock(code, nonce, own_cands)
        local published, publish_err = presence.publish(knock)
        if published == false then
            fail(publish_err or "could not publish the knock")
            return false
        end
        state = STATE_KNOCKING
        deadline = clock() + knock_timeout
        knock_code = code
        knock_cand_count = #own_cands
        knock_status = endpoint_status and endpoint_status() or nil
        log("rendezvous: knocking at " .. tostring(code) .. " nonce=" .. tostring(nonce) ..
            " with " .. candidates.describe(own_cands) ..
            ", our address is " .. tostring(knock_status or "unknown") ..
            ", deadline in " .. tostring(knock_timeout) .. "s")
        return true
    end

    function r.on_peer_payload(ref, payload)
        if state ~= STATE_KNOCKING and state ~= STATE_AWAITING then
            return
        end
        if not refs_equal(ref, expected_ref) then
            return
        end

        if type(payload) == "string" then
            local decoded, decode_err = protocol.decode(payload)
            if not decoded then
                if decode_err == "no decoder available" then
                    log("rendezvous: no JSON decoder is installed, this is a mod bug, not a bad payload")
                else
                    log("rendezvous: rejected a malformed or hostile peer payload - " .. tostring(decode_err))
                end
                return
            end
            payload = decoded
        end
        if type(payload) ~= "table" then
            return
        end

        if echoed_nonce(payload) ~= nonce then
            return
        end

        local waiting = protocol.read_pending(payload)
        if waiting then
            local extended = clock() + waiting.seconds + accept_wire_allowance
            if deadline and extended <= deadline then
                return
            end
            deadline = extended
            if state ~= STATE_AWAITING then
                state = STATE_AWAITING
                log("rendezvous: they are running the mod and a human is being asked to confirm" ..
                    " this join, nonce=" .. tostring(nonce) .. ", waiting up to " ..
                    tostring(waiting.seconds) .. "s for them plus " ..
                    tostring(accept_wire_allowance) .. "s for the reply to travel")
            end
            return
        end

        local delay = payload.t
        local cands = payload.c
        if type(delay) ~= "number" or type(cands) ~= "table" then
            return
        end

        if #cands == 0 or #cands > candidates.MAX then
            log("rendezvous: ack rejected, unusable candidate list")
            return
        end

        if not (delay > 0 and delay <= ack_window) then
            log("rendezvous: ack rejected, punch delay outside the acceptable window")
            return
        end

        t_punch = clock() + delay
        ack_cands = candidates.dial_order(cands, own_public_ip(), candidates_provider and candidates_provider())
        punch.schedule(t_punch, cands)
        state = STATE_PUNCHING
        deadline = t_punch + punch_grace
        log("rendezvous: ack accepted for nonce=" .. tostring(nonce) .. ", punching in " ..
            tostring(delay) .. "s at host " .. candidates.describe(cands))
    end

    function r.update()
        if state == STATE_IDLE or state == STATE_DONE or state == STATE_FAILED then
            return
        end

        if clock() >= deadline then
            if state == STATE_AWAITING then
                fail("awaiting timed out, they were asked to confirm this join and did not accept in time",
                    M.FAIL_NO_ANSWER)
            elseif state == STATE_KNOCKING then
                fail("knocking timed out", M.FAIL_NO_ANSWER)
            else
                fail(state .. " timed out")
            end
            return
        end

        if state == STATE_KNOCKING and knock_cand_count then
            local own_cands = candidates_provider and candidates_provider()
            if type(own_cands) == "table" and #own_cands > knock_cand_count then
                local knock = protocol.build_knock(knock_code, nonce, own_cands)
                if presence.publish(knock) ~= false then
                    log("rendezvous: re-published the knock to " .. tostring(knock_code) ..
                        " nonce=" .. tostring(nonce) .. " with " .. tostring(#own_cands) ..
                        " candidate(s), up from " .. tostring(knock_cand_count))
                    knock_cand_count = #own_cands
                end
            end
        end

        if state == STATE_JOINING and retry_at and clock() >= retry_at then
            attempt_join(retry_index)
            return
        end

        if state == STATE_PUNCHING then
            punch.update()
            if clock() >= t_punch then
                attempt_join()
                return
            end
            if punch.rounds_used() >= max_rounds then
                fail("punch budget exhausted before a candidate was reachable")
            end
        end
    end

    function r.cancel()
        if state == STATE_IDLE or state == STATE_DONE or state == STATE_FAILED then
            return
        end
        fail("cancelled")
    end

    function r.state()
        return state, fail_reason
    end

    function r.failure_kind()
        return fail_kind
    end

    function r.report_context()
        if nonce == nil then
            return nil
        end
        return nonce, (type(ack_cands) == "table") and #ack_cands or 0
    end

    function r.failure_detail()
        if type(fail_detail) == "string" and fail_detail ~= "" then
            return fail_detail
        end
        return nil
    end

    function r.seconds_left()
        if state == STATE_IDLE or state == STATE_DONE or state == STATE_FAILED or not deadline then
            return nil
        end
        local left = deadline - clock()
        if left < 0 then
            left = 0
        end
        return math_ceil(left)
    end

    return r
end

return M
