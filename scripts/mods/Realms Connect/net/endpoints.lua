--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-04
--]]

local type = type
local tostring = tostring

local M = {}

local DEFAULT_STUN_TIMEOUT = 8.0
local DEFAULT_TTL = 120.0
local DEFAULT_RETRY_SECONDS = 45.0
local DEFAULT_RETRY_CAP = 600.0

M.RETRY_SECONDS = DEFAULT_RETRY_SECONDS
M.RETRY_CAP = DEFAULT_RETRY_CAP

local STATUS_UNAVAILABLE = "unavailable"
local STATUS_IDLE = "idle"
local STATUS_GATHERING = "gathering"
local STATUS_READY = "ready"
local STATUS_DEGRADED = "degraded"
local STATUS_STALE = "stale"

local function noop() end

local function usable_text(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

local function extract_mapped(report)
    if type(report) ~= "table" then
        return nil
    end
    local servers = report.servers
    if type(servers) ~= "table" then
        return nil
    end
    for i = 1, #servers do
        local s = servers[i]
        if type(s) == "table" then
            local ip = s.mapped_ip
            local port = s.mapped_port
            if type(ip) == "string" and type(port) == "number" then
                return ip, port
            end
        end
    end
    return nil
end

function M.new(deps)
    deps = deps or {}
    local native = deps.native
    local candidates = deps.candidates
    local clock = deps.clock
    local manual = deps.manual
    local host_port = deps.host_port
    local log = deps.log or noop
    local stun_timeout = deps.stun_timeout or DEFAULT_STUN_TIMEOUT
    local ttl = deps.ttl or DEFAULT_TTL
    local retry_seconds = deps.retry_seconds or DEFAULT_RETRY_SECONDS
    local retry_cap = deps.retry_cap or DEFAULT_RETRY_CAP

    local e = {}

    local own_ports
    local private_ips
    local stun_ip, stun_port
    local port_preserved = false
    local mapping_ip, mapping_port
    local stun_active = false
    local stun_deadline
    local settled_at
    local phase = STATUS_IDLE
    local detail = "no gather has been performed yet"
    local retry_at
    local retry_backoff

    local function set_status(new_phase, new_detail)
        phase = new_phase
        detail = new_detail

        if new_phase == STATUS_DEGRADED then
            retry_backoff = retry_backoff and retry_backoff * 2 or retry_seconds
            if retry_backoff > retry_cap then
                retry_backoff = retry_cap
            end
            retry_at = clock() + retry_backoff
        elseif new_phase == STATUS_READY then
            retry_at = nil
            retry_backoff = nil
        elseif new_phase == STATUS_UNAVAILABLE then
            retry_at = nil
        end

        log("endpoints: " .. new_phase .. " - " .. tostring(new_detail))
    end

    local function ordered_ports()
        local session_port = host_port and host_port()
        if type(session_port) ~= "number" then
            return own_ports
        end

        local ports = { session_port }
        if type(own_ports) == "table" then
            for i = 1, #own_ports do
                if own_ports[i] ~= session_port then
                    ports[#ports + 1] = own_ports[i]
                end
            end
        end
        return ports
    end

    local function build_list()
        local sources = { ports = ordered_ports() }

        local manual_text = manual and usable_text(manual())
        if manual_text then
            sources.manual = manual_text
        end

        sources.private_ips = private_ips

        if mapping_ip and mapping_port then
            sources.mapped = { ip = mapping_ip, port = mapping_port }
        end

        if stun_ip and port_preserved then
            sources.public_ip = stun_ip
        end

        return candidates.build(sources)
    end

    function e.set_mapping(ip, port)
        if type(ip) ~= "string" or type(port) ~= "number" then
            return false
        end
        mapping_ip, mapping_port = ip, port
        return true
    end

    function e.clear_mapping()
        mapping_ip, mapping_port = nil, nil
    end

    function e.mapping()
        if mapping_ip and mapping_port then
            return mapping_ip, mapping_port
        end
        return nil
    end

    function e.public_ip()
        return stun_ip
    end

    function e.port_preserved()
        return port_preserved
    end

    function e.refresh()
        if not native or not native.available then
            own_ports = nil
            private_ips = nil
            stun_ip = nil
            stun_port = nil
            set_status(STATUS_UNAVAILABLE, native and native.load_error or "the native component is not installed")
            return
        end

        local ports = native.local_udp_ports()
        own_ports = type(ports) == "table" and ports or nil

        private_ips = nil
        if native.local_addrs then
            local addrs = native.local_addrs()
            if type(addrs) == "table" then
                local kept = {}
                for i = 1, #addrs do
                    local text = usable_text(addrs[i])
                    if text and candidates.is_private_ip(text) then
                        kept[#kept + 1] = text
                    end
                end
                if #kept > 0 then
                    private_ips = kept
                elseif #addrs > 0 then
                    local first = usable_text(addrs[1])
                    private_ips = first and { first } or nil
                end
            end
        end

        if stun_active then
            return
        end

        local ok, err = native.stun.begin()
        if not ok then
            settled_at = clock()
            set_status(STATUS_DEGRADED, "could not start the STUN sweep: " .. tostring(err))
            return
        end

        stun_active = true
        stun_deadline = clock() + stun_timeout
        set_status(STATUS_GATHERING, "waiting for STUN")
    end

    function e.update()
        if not stun_active then
            if phase == STATUS_DEGRADED and retry_at and clock() >= retry_at then
                retry_at = nil
                log("endpoints: retrying the gather that failed " .. tostring(detail))
                e.refresh()
            end
            return
        end

        if clock() >= stun_deadline then
            native.stun.cancel()
            stun_active = false
            settled_at = clock()
            set_status(STATUS_DEGRADED, "STUN did not resolve within " .. tostring(stun_timeout) .. "s")
            return
        end

        local status, payload = native.stun.poll()
        if status == "pending" then
            return
        end

        stun_active = false
        settled_at = clock()

        if status == "ok" then
            local ip, port = extract_mapped(payload)
            if ip then
                stun_ip, stun_port = ip, port
                port_preserved = type(payload) == "table" and payload.port_preserved == true
                set_status(STATUS_READY, "STUN resolved " .. ip .. ":" .. tostring(port) ..
                    (port_preserved and " (ports preserved)"
                        or " (ports NOT preserved, so your public address cannot be advertised)"))
            else
                set_status(STATUS_DEGRADED, "STUN completed without a usable reflexive address")
            end
        elseif status == "overrun" then
            set_status(STATUS_DEGRADED, "STUN sweep overran its budget: " .. tostring(payload))
        elseif status == "cancelled" then
            set_status(STATUS_DEGRADED, "STUN sweep was cancelled")
        else
            set_status(STATUS_DEGRADED, "STUN failed: " .. tostring(payload))
        end
    end

    function e.list()
        return build_list()
    end

    function e.status()
        if phase == STATUS_UNAVAILABLE then
            return phase, detail
        end
        if stun_active then
            return STATUS_GATHERING, detail
        end
        if settled_at and clock() - settled_at > ttl then
            return STATUS_STALE, "the gathered candidate list is older than " .. tostring(ttl) .. "s"
        end
        return phase, detail
    end

    function e.cancel()
        if stun_active then
            native.stun.cancel()
            stun_active = false
            settled_at = clock()
            set_status(STATUS_DEGRADED, "STUN sweep cancelled")
        end
    end

    return e
end

return M
