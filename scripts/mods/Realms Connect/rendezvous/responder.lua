--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-12
--]]

local type = type
local tostring = tostring
local table_remove = table.remove
local table_insert = table.insert
local math_floor = math.floor
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

local DEFAULT_ACK_HORIZON = 2.5
local DEFAULT_PUNCH_GRACE = 5.0
local DEFAULT_MAX_QUEUE = 8
local DEFAULT_SEEN_CAP = 64
local DEFAULT_PROMPT_TIMEOUT = 30.0
local DEFAULT_PENDING_REFRESH = 2.5

local STATE_IDLE = "idle"
local STATE_PUNCHING = "punching"
local STATE_PROMPTING = "prompting"

local DECISION_ALLOW = "allow"
local DECISION_PROMPT = "prompt"

M.STATE_IDLE = STATE_IDLE
M.STATE_PUNCHING = STATE_PUNCHING
M.STATE_PROMPTING = STATE_PROMPTING

local function noop() end

local function refs_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    return a.platform == b.platform and a.id == b.id
end

local function nonce_key(ref, nonce)
    if type(ref) ~= "table" then
        return nil
    end
    return tostring(ref.platform) .. ":" .. tostring(ref.id) .. ":" .. tostring(nonce)
end

local function usable_candidate_count(list)
    local n = 0
    for i = 1, #list do
        local ip = candidates.parse(list[i])
        if ip then
            n = n + 1
        end
    end
    return n
end

function M.new(deps)
    deps = deps or {}
    local punch = deps.punch
    local presence = deps.presence
    local protocol = deps.protocol
    local clock = deps.clock
    local candidates_provider = deps.candidates_provider
    local decide = deps.decide
    local own_short_code = deps.own_short_code
    local log = deps.log or noop
    local ack_horizon = deps.ack_horizon or DEFAULT_ACK_HORIZON
    local punch_grace = deps.punch_grace or DEFAULT_PUNCH_GRACE
    local max_queue = deps.max_queue or DEFAULT_MAX_QUEUE
    local prompt_timeout = deps.prompt_timeout or DEFAULT_PROMPT_TIMEOUT
    local pending_refresh_interval = deps.pending_refresh_interval or DEFAULT_PENDING_REFRESH
    local channel_busy = deps.channel_busy or function() return false end
    local on_punch_timeout = deps.on_punch_timeout or noop
    local on_peer_unreachable = deps.on_peer_unreachable or noop
    local connections = deps.connections
    local max_cands = candidates.MAX

    local r = {}

    local state = STATE_IDLE
    local active_ref
    local active_nonce
    local active_t_punch
    local active_cand_count
    local punch_baseline
    local punch_logged
    local deadline
    local pending

    local queue = {}
    local last_pending_publish = 0
    local pending_rotation = 0
    local seen = {}
    local replay_logged = {}
    local seen_order = {}
    local refused_logged = {}
    local unreachable_handled = {}
    local unreachable_order = {}

    local process_next

    local function mark_seen(key)
        if seen[key] then
            return
        end
        seen[key] = true
        seen_order[#seen_order + 1] = key
        if #seen_order > DEFAULT_SEEN_CAP then
            local oldest = table_remove(seen_order, 1)
            seen[oldest] = nil
            replay_logged[oldest] = nil
        end
    end

    local function queue_push(item)
        if #queue >= max_queue then
            log("responder: knock queue is full, dropping the knock from " .. tostring(nonce_key(item.ref, item.nonce)))
            return false
        end
        if item.prompt and not item.deadline then
            item.deadline = clock() + prompt_timeout
        end
        queue[#queue + 1] = item
        return true
    end

    local function queue_pop()
        local item = queue[1]
        if not item then
            return nil
        end
        table_remove(queue, 1)
        return item
    end

    local function reset_active()
        active_ref = nil
        active_nonce = nil
        active_t_punch = nil
        active_cand_count = nil
        punch_baseline = nil
        punch_logged = nil
        deadline = nil
        pending = nil
        state = STATE_IDLE
    end

    local function connection_count()
        if not connections then
            return nil
        end
        local ok, count = pcall(connections)
        if ok and type(count) == "number" then
            return count
        end
        return nil
    end

    local function start_job(ref, nonce, cands)
        if channel_busy() then
            table_insert(queue, 1, { ref = ref, nonce = nonce, cands = cands, prompt = false })
            reset_active()
            log("responder: an outgoing join owns the presence channel, holding the answer for " ..
                tostring(nonce_key(ref, nonce)) .. " until it is free")
            return
        end

        local my_cands = candidates_provider and candidates_provider()
        if type(my_cands) ~= "table" or #my_cands == 0 then
            log("responder: no local candidates available, cannot answer the knock from " .. tostring(nonce_key(ref, nonce)))
            reset_active()
            process_next()
            return
        end

        if punch.reset then
            punch.reset()
        end

        local t_punch = clock() + ack_horizon
        local ack = protocol.build_ack(nonce, ack_horizon, my_cands)
        local ok, reason = presence.publish(ack)
        if ok == false then
            log("responder: ack publish failed for " .. tostring(nonce_key(ref, nonce)) .. " - " .. tostring(reason))
            reset_active()
            process_next()
            return
        end

        local scheduled = punch.schedule(t_punch, cands)
        if not scheduled then
            log("responder: could not schedule the punch for " .. tostring(nonce_key(ref, nonce)) .. ", abandoning this job")
            reset_active()
            process_next()
            return
        end

        active_ref = ref
        active_nonce = nonce
        active_t_punch = t_punch
        active_cand_count = #cands
        punch_baseline = connection_count()
        punch_logged = false
        state = STATE_PUNCHING
        deadline = t_punch + punch_grace
        log("responder: answered a knock from " .. tostring(nonce_key(ref, nonce)) ..
            ", acked our " .. candidates.describe(my_cands) ..
            ", punching at their " .. candidates.describe(cands) ..
            " in " .. tostring(ack_horizon) .. "s")
    end

    local function remaining_for(item)
        local left = (item.deadline or 0) - clock()
        if left < 1 then
            left = 1
        end
        return left
    end

    local function publish_pending(item, why)
        if channel_busy() then
            return false
        end

        local announcement, build_err = protocol.build_pending(item.nonce, remaining_for(item))
        if not announcement then
            log("responder: could not build the pending notice for " ..
                tostring(nonce_key(item.ref, item.nonce)) .. " - " .. tostring(build_err) ..
                "; they will time out as though there was no response")
            return false
        end

        local ok, reason = presence.publish(announcement)
        if ok == false then
            log("responder: could not tell " .. tostring(nonce_key(item.ref, item.nonce)) ..
                " that a human is being asked - " .. tostring(reason) ..
                "; they will time out as though there was no response")
            return false
        end

        if why then
            log("responder: told " .. tostring(nonce_key(item.ref, item.nonce)) .. " a human is deciding (" ..
                why .. "), " .. tostring(math_floor(remaining_for(item))) .. "s left on their request")
        end

        last_pending_publish = clock()
        return true
    end

    local function begin_prompt(item)
        reset_active()
        pending = {
            ref = item.ref,
            nonce = item.nonce,
            cands = item.cands,
            deadline = item.deadline or (clock() + prompt_timeout),
        }
        state = STATE_PROMPTING

        publish_pending(pending, "now being negotiated")
    end

    process_next = function()
        local item = queue_pop()
        if not item then
            reset_active()
            return
        end
        if item.prompt then
            begin_prompt(item)
            return
        end
        start_job(item.ref, item.nonce, item.cands)
    end

    function r.on_unreachable(ref, payload)
        if type(payload) ~= "table" or payload.pv ~= protocol.PV then
            return
        end

        local report = protocol.read_unreachable(payload)
        if not report then
            return
        end

        local key = nonce_key(ref, report.nonce)
        if key == nil or unreachable_handled[key] then
            return
        end
        unreachable_handled[key] = true
        unreachable_order[#unreachable_order + 1] = key
        if #unreachable_order > DEFAULT_SEEN_CAP then
            unreachable_handled[table_remove(unreachable_order, 1)] = nil
        end

        log("responder: " .. tostring(key) ..
            " reported they could not reach any of the " .. tostring(report.tried) ..
            " candidate(s) we acked")
        on_peer_unreachable(ref, report.nonce, report.tried)
    end

    function r.on_knock(ref, payload)
        if type(payload) == "string" then
            local decoded, decode_err = protocol.decode(payload)
            if not decoded then
                if decode_err == "no decoder available" then
                    log("responder: no JSON decoder is installed, this is a mod bug, not a bad knock")
                else
                    log("responder: rejected a malformed or hostile knock - " .. tostring(decode_err))
                end
                return
            end
            payload = decoded
        end
        if type(payload) ~= "table" then
            return
        end

        if payload.pv ~= protocol.PV then
            return
        end
        if payload.k ~= protocol.KIND_KNOCK then
            return
        end
        if type(own_short_code) ~= "string" or payload.a ~= own_short_code then
            return
        end

        local nonce = payload.n
        if nonce == nil then
            return
        end

        local from = tostring(nonce_key(ref, nonce))

        local cands = payload.c
        if type(cands) ~= "table" or #cands == 0 or #cands > max_cands then
            log("responder: rejected a knock from " .. from .. " with an unusable candidate list (" ..
                tostring(type(cands) == "table" and #cands or type(cands)) .. " entries, max " ..
                tostring(max_cands) .. ")")
            return
        end
        if usable_candidate_count(cands) == 0 then
            log("responder: rejected a knock from " .. from ..
                ", no candidate in the list could be parsed")
            return
        end

        local key = nonce_key(ref, nonce)
        if key == nil then
            return
        end
        if seen[key] then
            if not replay_logged[key] then
                replay_logged[key] = true
                log("responder: ignored a replayed knock from " .. from ..
                    " (presence is last-write-wins, so their knock stays readable" ..
                    " until they retract it; further replays of this one are not logged)")
            end
            return
        end

        local decision = decide and decide(ref) or nil

        if decision ~= DECISION_ALLOW and decision ~= DECISION_PROMPT then
            if not refused_logged[key] then
                refused_logged[key] = true
                log("responder: refused a knock from " .. from ..
                    ", not on the allow list - silent to the peer")
            end
            return
        end

        local item = { ref = ref, nonce = nonce, cands = cands, prompt = decision == DECISION_PROMPT }

        if state == STATE_PROMPTING and pending and refs_equal(pending.ref, ref) then
            log("responder: " .. from .. " knocked again while their earlier knock was still" ..
                " waiting on a decision, replacing the pending confirmation")
            mark_seen(key)
            begin_prompt(item)
            return
        end

        if state == STATE_IDLE then
            mark_seen(key)
            if item.prompt then
                begin_prompt(item)
            else
                start_job(item.ref, item.nonce, item.cands)
            end
        elseif queue_push(item) then
            mark_seen(key)
        end
    end

    function r.pending()
        if state ~= STATE_PROMPTING or not pending then
            return nil
        end
        return { ref = pending.ref, nonce = pending.nonce, deadline = pending.deadline }
    end

    local function take_from_queue(nonce)
        for i = 1, #queue do
            if queue[i].nonce == nonce then
                return table_remove(queue, i)
            end
        end
        return nil
    end

    function r.requests()
        local out = {}

        if state == STATE_PROMPTING and pending then
            out[#out + 1] = {
                ref = pending.ref,
                nonce = pending.nonce,
                deadline = pending.deadline,
                prompting = true,
            }
        end

        for i = 1, #queue do
            local item = queue[i]
            if item.prompt then
                out[#out + 1] = {
                    ref = item.ref,
                    nonce = item.nonce,
                    deadline = item.deadline,
                    prompting = false,
                }
            end
        end

        return out
    end

    function r.accept(nonce)
        if state == STATE_PROMPTING and pending and pending.nonce == nonce then
            local item = pending
            log("responder: the knock from " .. tostring(nonce_key(item.ref, item.nonce)) ..
                " was accepted, answering it now")
            reset_active()
            start_job(item.ref, item.nonce, item.cands)
            return true
        end

        local queued = take_from_queue(nonce)
        if not queued or not queued.prompt then
            if queued then
                table_insert(queue, 1, queued)
            end
            return false
        end

        queued.prompt = false
        table_insert(queue, 1, queued)
        log("responder: the queued knock from " .. tostring(nonce_key(queued.ref, queued.nonce)) ..
            " was accepted ahead of its turn, it will be answered without a second prompt")

        if state == STATE_IDLE then
            process_next()
        end

        return true
    end

    function r.decline(nonce)
        if state == STATE_PROMPTING and pending and pending.nonce == nonce then
            local item = pending
            log("responder: the knock from " .. tostring(nonce_key(item.ref, item.nonce)) ..
                " was declined - nothing further is sent to them")
            reset_active()
            process_next()
            return true
        end

        local queued = take_from_queue(nonce)
        if not queued or not queued.prompt then
            if queued then
                table_insert(queue, 1, queued)
            end
            return false
        end

        log("responder: the queued knock from " .. tostring(nonce_key(queued.ref, queued.nonce)) ..
            " was declined - nothing further is sent to them")
        return true
    end

    local function expire_queued()
        for i = #queue, 1, -1 do
            local item = queue[i]
            if item.prompt and item.deadline and clock() >= item.deadline then
                table_remove(queue, i)
                log("responder: the queued request from " .. tostring(nonce_key(item.ref, item.nonce)) ..
                    " expired unanswered after " .. tostring(prompt_timeout) ..
                    "s - nothing further is sent to them")
            end
        end
    end

    local function rotate_pending()
        if clock() - last_pending_publish < pending_refresh_interval then
            return
        end

        local outstanding = {}
        if state == STATE_PROMPTING and pending then
            outstanding[#outstanding + 1] = pending
        end
        for i = 1, #queue do
            if queue[i].prompt then
                outstanding[#outstanding + 1] = queue[i]
            end
        end

        if #outstanding == 0 then
            return
        end

        pending_rotation = pending_rotation % #outstanding + 1
        publish_pending(outstanding[pending_rotation])
    end

    function r.update()
        expire_queued()

        if state == STATE_PROMPTING then
            if pending and clock() >= pending.deadline then
                local item = pending
                log("responder: the confirmation for " .. tostring(nonce_key(item.ref, item.nonce)) ..
                    " expired unanswered after " .. tostring(prompt_timeout) ..
                    "s - nothing further is sent to them")
                reset_active()
                process_next()
                return
            end

            rotate_pending()
            return
        end

        if state ~= STATE_PUNCHING then
            if state == STATE_IDLE and #queue > 0 then
                process_next()
            end
            return
        end

        if clock() >= active_t_punch then
            rotate_pending()
        end

        if clock() >= deadline then
            punch.cancel()
            log("responder: punching timed out for the active join")
            on_punch_timeout()
            process_next()
            return
        end

        punch.update()

        if clock() < active_t_punch then
            return
        end

        if not punch_logged then
            punch_logged = true
            log("responder: punched at " .. tostring(active_cand_count) .. " candidate(s) for " ..
                tostring(nonce_key(active_ref, active_nonce)))
        end

        if punch_baseline == nil then
            process_next()
            return
        end

        local connected = connection_count()
        if connected and connected > punch_baseline then
            log("responder: " .. tostring(nonce_key(active_ref, active_nonce)) ..
                " connected after the punch")
            process_next()
        end
    end

    function r.cancel()
        if state == STATE_PUNCHING then
            punch.cancel()
        end
        queue = {}
        refused_logged = {}
        reset_active()
    end

    function r.state()
        return state, #queue
    end

    function r.queue_full()
        return #queue >= max_queue
    end

    function r.active_ref()
        return active_ref
    end

    function r.active_nonce()
        return active_nonce
    end

    return r
end

return M
