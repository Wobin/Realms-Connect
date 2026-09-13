--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-13
--]]

local string_match = string.match
local table_concat = table.concat
local tonumber = tonumber
local tostring = tostring
local type = type

local M = { MAX = 4 }

local function octet_valid(text)
    if #text == 0 or #text > 3 then
        return false
    end
    local n = tonumber(text)
    return n ~= nil and n >= 0 and n <= 255
end

function M.parse(text)
    if type(text) ~= "string" then
        return nil, "not a string"
    end
    local o1, o2, o3, o4, port_text = string_match(text, "^(%d+)%.(%d+)%.(%d+)%.(%d+):(%d+)$")
    if not o1 then
        return nil, "malformed candidate"
    end
    if not (octet_valid(o1) and octet_valid(o2) and octet_valid(o3) and octet_valid(o4)) then
        return nil, "octet out of range"
    end
    local port = tonumber(port_text)
    if port < 1 or port > 65535 then
        return nil, "port out of range"
    end
    return o1 .. "." .. o2 .. "." .. o3 .. "." .. o4, port
end

local function canonicalize_ip(ip)
    local o1, o2, o3, o4 = string_match(ip, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not o1 then
        return ip
    end
    return tonumber(o1) .. "." .. tonumber(o2) .. "." .. tonumber(o3) .. "." .. tonumber(o4)
end

local function add_candidate(list, seen, candidate)
    if seen[candidate] then
        return
    end
    if #list >= M.MAX then
        return
    end
    seen[candidate] = true
    list[#list + 1] = candidate
end

function M.build(sources)
    sources = sources or {}
    local list = {}
    local seen = {}

    if sources.manual then
        local candidate = sources.manual
        local m_ip, m_port = string_match(candidate, "^(.+):(%d+)$")
        if m_ip then
            candidate = canonicalize_ip(m_ip) .. ":" .. m_port
        end
        if M.manual_problem(candidate) ~= M.MANUAL_UNUSABLE then
            add_candidate(list, seen, candidate)
        end
    end

    if sources.mapped and sources.mapped.ip and sources.mapped.port then
        add_candidate(list, seen, canonicalize_ip(sources.mapped.ip) .. ":" .. sources.mapped.port)
    end

    local ports = sources.ports
    if ports then
        local public_ip = sources.public_ip and canonicalize_ip(sources.public_ip)

        local privates = {}
        if sources.private_ips then
            for i = 1, #sources.private_ips do
                privates[#privates + 1] = canonicalize_ip(sources.private_ips[i])
            end
        elseif sources.private_ip then
            privates[1] = canonicalize_ip(sources.private_ip)
        end

        for i = 1, #ports do
            if public_ip then
                add_candidate(list, seen, public_ip .. ":" .. ports[i])
            end
            for p = 1, #privates do
                add_candidate(list, seen, privates[p] .. ":" .. ports[i])
            end
        end
    end

    return list
end

local PRIVATE_PATTERNS = {
    "^10%.",
    "^192%.168%.",
    "^127%.",
    "^169%.254%.",
}

function M.is_private_ip(text)
    if type(text) ~= "string" then
        return false
    end

    for i = 1, #PRIVATE_PATTERNS do
        if text:find(PRIVATE_PATTERNS[i]) then
            return true
        end
    end

    local second = text:match("^172%.(%d+)%.")
    if second then
        local n = tonumber(second)
        if n and n >= 16 and n <= 31 then
            return true
        end
    end

    return false
end

function M.is_carrier_nat_ip(text)
    if type(text) ~= "string" then
        return false
    end

    local second = string_match(text, "^100%.(%d+)%.%d+%.%d+$")
    if not second then
        return false
    end

    local n = tonumber(second)
    return n ~= nil and n >= 64 and n <= 127
end

local function subnet24(ip)
    return string_match(ip, "^(%d+%.%d+%.%d+)%.%d+$")
end

function M.dial_order(host_cands, own_public_ip, own_cands)
    local out = {}
    if type(host_cands) ~= "table" then
        return out
    end

    local own_public = type(own_public_ip) == "string" and canonicalize_ip(own_public_ip) or nil
    local shared_public = false
    local host_has_public = false
    for i = 1, #host_cands do
        local ip = M.parse(host_cands[i])
        if ip and not M.is_private_ip(ip) then
            host_has_public = true
            if canonicalize_ip(ip) == own_public then
                shared_public = true
            end
        end
    end

    local drop_private = own_public ~= nil and host_has_public and not shared_public
    local own_subnets = {}
    if type(own_cands) == "table" then
        for i = 1, #own_cands do
            local ip = M.parse(own_cands[i])
            if ip and M.is_private_ip(ip) then
                own_subnets[subnet24(canonicalize_ip(ip))] = true
            end
        end
    end

    for i = 1, #host_cands do
        local candidate = host_cands[i]
        local ip = M.parse(candidate)
        local keep = true
        if drop_private and ip and M.is_private_ip(ip) then
            keep = own_subnets[subnet24(canonicalize_ip(ip))] == true
        end
        if keep then
            out[#out + 1] = candidate
        end
    end
    return out
end

M.MANUAL_UNUSABLE = "unusable"
M.MANUAL_LOCAL = "local"
M.MANUAL_PORT = "port"

local UNUSABLE_PATTERNS = {
    "^127%.",
    "^0%.",
    "^255%.",
}

function M.manual_problem(text, host_port)
    local ip, port = M.parse(text)
    if not ip then
        return M.MANUAL_UNUSABLE
    end
    ip = canonicalize_ip(ip)

    for i = 1, #UNUSABLE_PATTERNS do
        if ip:find(UNUSABLE_PATTERNS[i]) then
            return M.MANUAL_UNUSABLE
        end
    end

    if M.is_private_ip(ip) or M.is_carrier_nat_ip(ip) then
        return M.MANUAL_LOCAL
    end

    if type(host_port) == "number" and port ~= host_port then
        return M.MANUAL_PORT
    end

    return nil
end

function M.describe(list)
    if type(list) ~= "table" or #list == 0 then
        return "0 candidate(s)"
    end

    local private_n, public_n, unparsed_n = 0, 0, 0
    local shown = {}
    for i = 1, #list do
        local ip = M.parse(list[i])
        if not ip then
            unparsed_n = unparsed_n + 1
        elseif M.is_private_ip(ip) or M.is_carrier_nat_ip(ip) then
            private_n = private_n + 1
        else
            public_n = public_n + 1
        end
        shown[i] = tostring(list[i])
    end

    local text = tostring(#list) .. " candidate(s) [" ..
        tostring(private_n) .. " private, " .. tostring(public_n) .. " public"
    if unparsed_n > 0 then
        text = text .. ", " .. tostring(unparsed_n) .. " unparsable"
    end

    return text .. "]: " .. table_concat(shown, ", ")
end

return M
