--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-07
--]]

local type = type
local tostring = tostring
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

local M = {}

M.STATE_OFF = "off"
M.STATE_UNAVAILABLE = "unavailable"
M.STATE_IDLE = "idle"
M.STATE_REQUESTING = "requesting"
M.STATE_MAPPED = "mapped"
M.STATE_FAILED = "failed"
M.STATE_CGNAT = "cgnat"

M.DEFAULT_LEASE = 1800
M.DEFAULT_RENEW_MARGIN = 300
M.DEFAULT_RETRY_SECONDS = 120
M.DEFAULT_MISMATCH_RECHECK_SECONDS = 60

local function noop() end

function M.new(deps)
    deps = deps or {}

    local candidates = deps.candidates or load_sibling("net/candidates")
    local native = deps.native
    local clock = deps.clock
    local host_port = deps.host_port or noop
    local enabled = deps.enabled or function() return true end
    local public_ip = deps.public_ip or noop
    local log = deps.log or noop
    local lease = deps.lease or M.DEFAULT_LEASE
    local renew_margin = deps.renew_margin or M.DEFAULT_RENEW_MARGIN
    local retry_seconds = deps.retry_seconds or M.DEFAULT_RETRY_SECONDS
    local mismatch_recheck_seconds = deps.mismatch_recheck_seconds or M.DEFAULT_MISMATCH_RECHECK_SECONDS

    local p = {}

    local state = M.STATE_IDLE
    local reason
    local mapped_ip, mapped_port
    local mapped_for_port
    local requesting_port
    local renew_at
    local retry_at

    local function set_state(new_state, new_reason)
        if state == new_state and reason == new_reason then
            return
        end
        state = new_state
        reason = new_reason
        log("portmap: " .. new_state .. (new_reason and (" - " .. tostring(new_reason)) or ""))
    end

    local function forget_mapping()
        mapped_ip, mapped_port, mapped_for_port = nil, nil, nil
        renew_at = nil
    end

    local function release_now(port)
        if not port or not native or not native.available then
            return
        end
        local ok, err = native.map.release(port)
        if not ok then
            log("portmap: the release of port " .. tostring(port) .. " was refused - " .. tostring(err))
        end
    end

    function p.release()
        local port = mapped_for_port or requesting_port
        forget_mapping()
        requesting_port = nil
        retry_at = nil
        if port then
            release_now(port)
        end
        set_state(M.STATE_IDLE, nil)
    end

    local function begin(port)
        local ok, err = native.map.begin(port, lease)
        if not ok then
            requesting_port = nil
            retry_at = clock() + retry_seconds
            set_state(M.STATE_FAILED, "the router mapping could not be started: " .. tostring(err))
            return
        end
        requesting_port = port
        set_state(M.STATE_REQUESTING, "asking the router to forward port " .. tostring(port))
    end

    local function settle(decoded)
        local port = requesting_port
        requesting_port = nil

        if type(decoded) ~= "table" or decoded.ok ~= true then
            local why = type(decoded) == "table" and decoded.error or "the router refused the mapping"
            retry_at = clock() + retry_seconds
            set_state(M.STATE_FAILED, tostring(why))
            return
        end

        local ip = decoded.external_ip
        local external = decoded.external_port

        if type(ip) ~= "string" or ip == "" then
            ip = nil
        end

        if type(external) ~= "number" then
            retry_at = clock() + retry_seconds
            set_state(M.STATE_FAILED, "the router answered without a usable external port")
            return
        end

        local seen = public_ip()
        if type(seen) ~= "string" or seen == "" then
            seen = nil
        end

        local function unreachable_state(address, observed)
            release_now(port)
            forget_mapping()
            retry_at = clock() + retry_seconds

            if candidates.is_carrier_nat_ip(address) then
                set_state(M.STATE_CGNAT,
                    "the mapping's public address is " .. address .. ", which is carrier-private" .. observed ..
                    ", so this mapping reaches nobody: you are behind carrier-grade NAT and cannot host")
            else
                set_state(M.STATE_CGNAT,
                    "the mapping's public address is " .. address ..
                    ", which no one on the internet can reach" .. observed ..
                    ", so this mapping reaches nobody: your router is itself behind another router" ..
                    " or a carrier NAT, and you cannot host")
            end
        end

        local mismatched = ip ~= nil and seen ~= nil and seen ~= ip

        if ip and (candidates.is_carrier_nat_ip(ip) or candidates.is_private_ip(ip)) then
            unreachable_state(ip, mismatched and (" (the internet sees " .. seen .. ")") or "")
            return
        end

        local advertised = ip
        local disagreement = nil

        if mismatched then
            advertised = seen
            disagreement = "the router reports its WAN address as " .. ip ..
                " but the internet sees " .. seen ..
                "; both are ordinary public addresses, so this is usually a stale router reading" ..
                " after a reconnect - advertising " .. seen .. " and re-checking in " ..
                tostring(mismatch_recheck_seconds) .. "s"
        elseif not ip then
            if not seen then
                retry_at = clock() + retry_seconds
                set_state(M.STATE_FAILED,
                    "the router forwarded the port but could not report its own WAN address," ..
                    " and STUN has not worked one out either, so there is nothing to advertise yet")
                return
            end
            advertised = seen
            disagreement = "the router could not report its own WAN address, so the STUN-observed " ..
                seen .. " is being advertised instead; the forwarded port itself is fine"
        end

        if candidates.is_carrier_nat_ip(advertised) or candidates.is_private_ip(advertised) then
            unreachable_state(advertised, ip and (" (the router reported " .. ip .. ")") or "")
            return
        end

        local verified = decoded.verified
        local note
        if verified == false then
            note = "the router accepted this mapping and then does not hold it, so inbound traffic may never" ..
                " arrive - if joins keep timing out, forward the port by hand"
        elseif verified == true then
            note = "the router confirms it holds this mapping"
        else
            note = "the router could not confirm the mapping, so it is unverified - it may still be" ..
                " forwarding, but nothing here proves it"
        end

        local recorded_client = decoded.internal_client
        if type(recorded_client) == "string" and recorded_client ~= "" then
            note = note .. " | the router recorded the mapping against internal client " .. recorded_client
        end

        mapped_ip = advertised
        mapped_port = external
        mapped_for_port = port

        local granted = type(decoded.lease) == "number" and decoded.lease or lease
        if decoded.permanent == true or granted <= 0 then
            renew_at = nil
        else
            local margin = renew_margin
            if margin >= granted then
                margin = granted / 2
            end
            renew_at = clock() + (granted - margin)
        end

        if disagreement then
            local recheck = clock() + mismatch_recheck_seconds
            if not renew_at or recheck < renew_at then
                renew_at = recheck
            end
        end

        retry_at = nil
        set_state(M.STATE_MAPPED, advertised .. ":" .. tostring(external) ..
            (disagreement and (" | " .. disagreement) or "") ..
            (note and (" | " .. note) or ""))
    end

    function p.update()
        if not enabled() then
            if mapped_for_port or requesting_port then
                p.release()
            end
            set_state(M.STATE_OFF, "router port mapping is switched off in the settings")
            return
        end

        if not native or not native.available then
            forget_mapping()
            requesting_port = nil
            set_state(M.STATE_UNAVAILABLE,
                native and native.load_error or "the native component is not installed")
            return
        end

        if requesting_port then
            local status, payload = native.map.poll()
            if status == "pending" then
                return
            end
            if status == "ok" then
                settle(payload)
            else
                requesting_port = nil
                retry_at = clock() + retry_seconds
                set_state(M.STATE_FAILED, tostring(payload))
            end
            return
        end

        local port = host_port()

        if type(port) ~= "number" then
            if mapped_for_port then
                local held = mapped_for_port
                forget_mapping()
                release_now(held)
                log("portmap: no longer hosting, released the router mapping on port " .. tostring(held))
            end
            retry_at = nil
            set_state(M.STATE_IDLE, "not hosting, so no mapping is needed")
            return
        end

        if mapped_for_port and mapped_for_port ~= port then
            local held = mapped_for_port
            forget_mapping()
            release_now(held)
            log("portmap: the host port changed from " .. tostring(held) ..
                " to " .. tostring(port) .. ", remapping")
        end

        if mapped_for_port == port then
            local seen = public_ip()
            if mapped_ip and type(seen) == "string" and seen ~= "" and seen ~= mapped_ip then
                if candidates.is_carrier_nat_ip(seen) or candidates.is_private_ip(seen) then
                    local held = mapped_for_port
                    forget_mapping()
                    release_now(held)
                    retry_at = clock() + retry_seconds
                    set_state(M.STATE_CGNAT,
                        "the internet now sees " .. seen ..
                        ", which no one can reach, so this mapping reaches nobody" ..
                        ": you are behind carrier-grade NAT and cannot host")
                    return
                end

                local was = mapped_ip
                mapped_ip = seen
                set_state(M.STATE_MAPPED, seen .. ":" .. tostring(mapped_port) ..
                    " | the public address moved from " .. was .. " to " .. seen ..
                    ", so the mapping is now advertised as " .. seen)
            end

            if renew_at and clock() >= renew_at then
                begin(port)
            end
            return
        end

        if retry_at and clock() < retry_at then
            return
        end

        begin(port)
    end

    function p.state()
        return state, reason
    end

    function p.mapping()
        if mapped_ip and mapped_port then
            return mapped_ip, mapped_port
        end
        return nil
    end

    return p
end

return M
