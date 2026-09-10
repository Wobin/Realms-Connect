--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-07
--]]

local string_format = string.format
local string_match = string.match
local string_gsub = string.gsub
local table_insert = table.insert
local table_concat = table.concat
local tostring = tostring
local tonumber = tonumber
local type = type
local pairs = pairs
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

local json = load_sibling("util/json")
local mask = load_sibling("util/mask")

local M = {}

M.mask_ip = mask.mask_ip

local function redact(ip, ro)
    if ip == nil then
        return "unknown"
    end
    if ro.redaction == "full" then
        return tostring(ip)
    end
    return M.mask_ip(ip)
end

local function split_ip_port(s)
    local ip, port = string_match(s, "^(%d+%.%d+%.%d+%.%d+):(%d+)$")
    if ip then
        return ip, port
    end
    return s, nil
end

local function redact_addr(s, ro)
    if type(s) ~= "string" then
        return "unknown"
    end
    local ip, port = split_ip_port(s)
    local r = redact(ip, ro)
    if port then
        return r .. ":" .. port
    end
    return r
end

local function redact_url(s, ro, fallback)
    if type(s) ~= "string" then
        return fallback or "unknown"
    end
    return (string_gsub(s, "%d+%.%d+%.%d+%.%d+", function(ip)
        return redact(ip, ro)
    end))
end

local function bool_text(v, when_true, when_false, when_nil)
    if v == nil then
        return when_nil or "unknown"
    end
    if v then
        return when_true or "yes"
    end
    return when_false or "no"
end

local function push(lines, str)
    table_insert(lines, str)
end

local function render_header(lines, report, ro)
    push(lines, "Realms Connect diagnostic report")
    if ro.redaction == "full" then
        push(lines, "FULL MODE: this report is about to reveal your public IP address(es) and other identifying network details in the clear. Only share this with someone you trust, such as the mod author.")
    end
    local schema = report.schema ~= nil and tostring(report.schema) or "unknown"
    local dll_version = report.dll_version or "unknown"
    local mod_version = ro.mod_version or "unknown"
    local elapsed = report.elapsed_ms ~= nil and (tostring(report.elapsed_ms) .. "ms") or "unknown"
    push(lines, string_format("mod version: %s | dll version: %s | schema: %s | probe elapsed: %s", mod_version, dll_version, schema, elapsed))
    if report.process then
        push(lines, string_format("probe process: %s (pid %s)", tostring(report.process.name or "unknown"), tostring(report.process.pid or "unknown")))
    end
    if report.error then
        push(lines, string_format("NATIVE ERROR: %s", redact_url(report.error, ro)))
        push(lines, "The native diagnostics DLL could not be loaded or run. Manual address entry still works; only in-app network diagnosis is unavailable this session.")
    end
end

local function render_interfaces(lines, report, ro)
    push(lines, "")
    push(lines, "-- Interfaces --")
    local ifaces = report.interfaces
    if not ifaces or #ifaces == 0 then
        push(lines, "no interfaces captured")
        return
    end
    for i = 1, #ifaces do
        local f = ifaces[i]
        push(lines, string_format("  %-28s addr=%-15s index=%-4s metric=%-4s state=%-4s gateway=%s",
            redact_url(f.alias, ro, "?"), M.mask_ip(f.addr), tostring(f.index or "?"), tostring(f.metric or "?"),
            bool_text(f.up, "up", "down"),
            f.gateway and M.mask_ip(f.gateway) or "none"))
    end
end

local function render_natpmp(lines, report, ro)
    push(lines, "")
    push(lines, "-- NAT-PMP --")
    local n = report.natpmp
    if not n then
        push(lines, "not attempted")
        return
    end
    push(lines, string_format("attempted: %s, gateway: %s", bool_text(n.attempted), redact(n.gateway, ro)))
    push(lines, string_format("replied: %s", bool_text(n.replied)))
    if n.replied then
        push(lines, string_format("external ip: %s, result code: %s", redact(n.external_ip, ro), tostring(n.result_code or "unknown")))
    elseif n.error then
        push(lines, "error: " .. redact_url(n.error, ro))
    end
end

local function metric_of(interfaces, addr)
    if not interfaces then
        return nil
    end
    for i = 1, #interfaces do
        if interfaces[i].addr == addr then
            return interfaces[i].metric
        end
    end
    return nil
end

local function find_metric_tie(interfaces, searched)
    if not interfaces or not searched then
        return nil
    end
    local counts = {}
    for i = 1, #searched do
        local m = metric_of(interfaces, searched[i].iface)
        if m then
            counts[m] = (counts[m] or 0) + 1
        end
    end
    for m, n in pairs(counts) do
        if n > 1 then
            return m, n
        end
    end
    return nil
end

local function render_ssdp(lines, report, ro)
    push(lines, "")
    push(lines, "-- SSDP (UPnP discovery) --")
    local s = report.ssdp
    if not s then
        push(lines, "not attempted")
        return
    end
    local targets = s.search_targets
    if targets and #targets > 0 then
        push(lines, "search targets: " .. table_concat(targets, ", "))
    end
    local searched = s.searched_interfaces
    if searched and #searched > 0 then
        local parts = {}
        for i = 1, #searched do
            local si = searched[i]
            table_insert(parts, M.mask_ip(si.iface) .. (si.error and (" (error: " .. redact_url(si.error, ro) .. ")") or ""))
        end
        push(lines, string_format("interfaces searched (%d): %s", #searched, table_concat(parts, "; ")))
    else
        push(lines, "interfaces searched: none recorded")
    end
    local responders = s.responders or {}
    if #responders == 0 then
        push(lines, "0 responders across the searched interfaces. This can mean the router genuinely rejects UPnP, or that the search itself failed to reach it - wrong-adapter multicast, a metric tie between interfaces, or another service holding the SSDP port. Cross-check the interface list above and the NAT-PMP and STUN results below before concluding the router is at fault.")
        local tie_metric, tie_count = find_metric_tie(report.interfaces, searched)
        if tie_metric then
            push(lines, string_format("%d of the searched interfaces are tied at metric %d - a metric tie is a known cause of multicast egressing the wrong adapter, and does not by itself mean the router lacks UPnP.", tie_count, tie_metric))
        end
    else
        push(lines, string_format("responders (%d):", #responders))
        for i = 1, #responders do
            local r = responders[i]
            push(lines, string_format("  from %s via %s: %s (%s) wan_service=%s%s",
                M.mask_ip(r.from), M.mask_ip(r.via_iface), tostring(r.device_type or "?"),
                redact_url(r.server, ro, "?"), bool_text(r.has_wan_service),
                r.reject_reason and (" reject_reason=" .. redact_url(r.reject_reason, ro)) or ""))
        end
    end
    if s.selected then
        push(lines, "selected: " .. redact_url(s.selected, ro))
    else
        push(lines, "selected: none - no WAN-capable device was found among the responders above")
    end
end

local function render_igd(lines, report, ro)
    push(lines, "")
    push(lines, "-- IGD (Internet Gateway Device) --")
    local igd = report.igd
    if not igd then
        push(lines, "no IGD selected from SSDP results (see SSDP section above)")
        return
    end
    push(lines, "location: " .. redact_url(igd.location, ro))
    push(lines, "control url: " .. redact_url(igd.control_url, ro))
    push(lines, "service type: " .. tostring(igd.service_type or "unknown"))
    if igd.external_ip then
        push(lines, "external ip (SOAP GetExternalIPAddress): " .. redact(igd.external_ip, ro))
    elseif igd.external_ip_error then
        push(lines, "external ip: error - " .. redact_url(igd.external_ip_error, ro))
    end
    if igd.status then
        push(lines, "connection status (GetStatusInfo): " .. tostring(igd.status))
    elseif igd.status_error then
        push(lines, "connection status: error - " .. redact_url(igd.status_error, ro))
    end

    local pm = igd.port_mapping
    if type(pm) == "table" then
        if pm.checked ~= true then
            push(lines, "our port mapping: not checked - " .. tostring(pm.reason or "no host port"))
        elseif pm.present == true then
            push(lines, "our port mapping: PRESENT for UDP " .. tostring(pm.port) ..
                " -> " .. redact(pm.internal_client, ro) .. ":" .. tostring(pm.internal_port) ..
                " (enabled=" .. tostring(pm.enabled) .. ", lease=" .. tostring(pm.lease_duration) .. ")")
        elseif pm.present == false then
            push(lines, "our port mapping: ABSENT - the router is NOT forwarding UDP " ..
                tostring(pm.port) .. ", so nobody outside can reach this machine")
        else
            push(lines, "our port mapping: could not be checked for UDP " .. tostring(pm.port) ..
                " - " .. redact_url(pm.error, ro))
        end
    end
end

local function render_stun(lines, report, ro)
    push(lines, "")
    push(lines, "-- STUN --")
    local st = report.stun
    if not st then
        push(lines, "not attempted")
        return
    end
    push(lines, "local port: " .. tostring(st.local_port or "unknown"))
    push(lines, "public ip (STUN-observed): " .. redact(st.public_ip, ro))
    push(lines, "mapping behaviour: " .. tostring(st.mapping_behaviour or "unknown"))
    push(lines, "port preserved: " .. bool_text(st.port_preserved))
    local servers = st.servers or {}
    for i = 1, #servers do
        local sv = servers[i]
        push(lines, string_format("  %s (server %s) -> mapped %s:%s%s", tostring(sv.host or "?"),
            redact(sv.server_ip, ro), redact(sv.mapped_ip, ro), tostring(sv.mapped_port or "?"),
            sv.other_address and (", other-address " .. redact_addr(sv.other_address, ro)) or ""))
    end
end

local function render_filtering(lines, report, ro)
    push(lines, "")
    push(lines, "-- NAT filtering (RFC 5780) --")
    local f = report.filtering
    if not f or not f.tested_with then
        push(lines, "not tested: no STUN server offered OTHER-ADDRESS")
        return
    end
    push(lines, "tested with: " .. tostring(f.tested_with))
    push(lines, "test II (change ip+port): " .. bool_text(f.test_ii, "reply received", "no reply", "unknown"))
    push(lines, "test III (change port): " .. bool_text(f.test_iii, "reply received", "no reply", "unknown"))
    push(lines, "behaviour: " .. tostring(f.behaviour or "unknown"))
end

local function render_cgnat(lines, report, ro)
    push(lines, "")
    push(lines, "-- CGNAT check --")
    local c = report.cgnat
    if not c then
        push(lines, "not computed")
        return
    end
    push(lines, "router-reported WAN address: " .. redact(c.wan, ro))
    push(lines, "STUN-observed public address: " .. redact(c.stun, ro))
    push(lines, "verdict: " .. tostring(c.verdict or "unknown"))
    if c.verdict == "cgnat" then
        push(lines, "You are behind Carrier-Grade NAT: the router's port mapping will report success but the traffic never actually reaches you. You cannot host through tier 1, but you can still join other players' games normally.")
    elseif c.verdict == "address_mismatch" then
        push(lines, "The router and the internet disagree about this connection's public address, but both are ordinary public addresses, so this is NOT carrier-grade NAT. It is usually a stale reading from the router after the WAN address changed. The address STUN observed is the one being advertised; if the router has not caught up within a few minutes, renewing its WAN lease clears it.")
    end
end

local function render_engine(lines, report, ro)
    push(lines, "")
    push(lines, "-- Engine --")
    local u = report.udp_ports
    if not u then
        push(lines, "own-process UDP ports: not captured")
        return
    end
    local ports = u.ports or {}
    if #ports == 0 then
        push(lines, "own-process UDP ports: none bound" .. (u.note and (" (" .. redact_url(u.note, ro) .. ")") or ""))
    else
        push(lines, "own-process UDP ports: " .. table_concat(ports, ", "))
    end
end

local function is_backend_join_failure(report)
    local b = report.backend
    if not b or not b.connection then
        return false
    end
    if not b.connection.peer_connected then
        return false
    end
    if b.connection.failed_stage ~= "dlc_verified" then
        return false
    end
    local arche = b.archetype
    if not arche or not arche.requires_dlc then
        return false
    end
    return true
end

local function render_backend(lines, report, ro)
    push(lines, "")
    push(lines, "-- Backend / DLC verification --")
    local b = report.backend
    if not b then
        push(lines, "not captured")
        return
    end
    local conn = b.connection or {}
    if conn.peer_connected then
        push(lines, string_format("peer connection: SUCCEEDED (Realms handshake reached stage '%s')", tostring(conn.last_stage or "unknown")))
    else
        push(lines, "peer connection: did not complete")
    end
    push(lines, "backend authentication: " .. bool_text(b.authenticated, "ok", "FAILED"))
    if b.auth_error then
        push(lines, "backend auth error: " .. redact_url(b.auth_error, ro))
    end
    local arche = b.archetype
    if arche and arche.requires_dlc then
        push(lines, string_format("local archetype '%s' requires_dlc: %s (this class performs a live HTTPS licence check against the Fatshark backend)", tostring(arche.name or "?"), tostring(arche.requires_dlc)))
        if conn.peer_connected and conn.failed_stage == "dlc_verified" then
            push(lines, string_format("CONCLUSION: this is not a reachability problem. The connection to your teammate succeeded. The join failed because this client's backend licence check for '%s' did not complete. Try: confirm you are logged in and this account owns the DLC, check VPN/firewall rules against the backend's HTTPS endpoints, or join again on a core class (Veteran, Zealot, Psyker or Ogryn - no licence check) to confirm the peer link itself is fine.", tostring(arche.requires_dlc)))
        end
    elseif arche then
        push(lines, string_format("local archetype '%s' requires no DLC licence check", tostring(arche.name or "?")))
    end
end

function M.render(report, opts)
    opts = opts or {}
    report = type(report) == "table" and report or {}
    json.strip_null(report)
    local ro = {
        redaction = (opts.redaction == "full") and "full" or "masked",
        mod_version = opts.mod_version,
    }

    local lines = {}
    render_header(lines, report, ro)

    if is_backend_join_failure(report) then
        push(lines, "")
        push(lines, "Network: peer-to-peer connection SUCCEEDED. Reachability was not the problem here; see the backend section below.")
        render_backend(lines, report, ro)
    else
        render_interfaces(lines, report, ro)
        render_natpmp(lines, report, ro)
        render_ssdp(lines, report, ro)
        render_igd(lines, report, ro)
        render_stun(lines, report, ro)
        render_filtering(lines, report, ro)
        render_cgnat(lines, report, ro)
        render_engine(lines, report, ro)
        if report.backend then
            render_backend(lines, report, ro)
        end
    end

    if report.outcome then
        push(lines, "")
        push(lines, "-- Outcome --")
        push(lines, "tier: " .. tostring(report.outcome.tier or "unknown"))
        if report.outcome.reason then
            push(lines, "reason: " .. tostring(report.outcome.reason))
        end
    end

    return table_concat(lines, "\n")
end

function M.summary(report)
    report = type(report) == "table" and report or {}
    json.strip_null(report)
    if report.error then
        return "Realms Connect diagnostics: native DLL unavailable (" .. tostring(report.error) .. "); manual address entry still works."
    end
    if is_backend_join_failure(report) then
        local dlc = report.backend and report.backend.archetype and report.backend.archetype.requires_dlc
        local suffix = dlc and (" for '" .. tostring(dlc) .. "'") or ""
        return "Realms Connect diagnostics: peer connection succeeded; join failed at the backend DLC licence check" .. suffix .. ". Not a reachability problem. Full report in the log."
    end
    local verdict = report.cgnat and report.cgnat.verdict
    if verdict == "cgnat" then
        return "Realms Connect diagnostics: you appear to be behind CGNAT; you can join but likely cannot host through tier 1. Full report in the log."
    end
    if report.igd and report.igd.location then
        return "Realms Connect diagnostics: UPnP IGD found and reachable. Full report in the log."
    end
    return "Realms Connect diagnostics complete. Full report in the log."
end

return M
