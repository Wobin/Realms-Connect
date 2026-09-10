--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-08
--]]

local string_format = string.format
local string_match = string.match
local string_gsub = string.gsub
local tonumber = tonumber
local type = type

local M = {}

local function is_private_octets(a, b)
    if a == 0 then return true end
    if a == 10 then return true end
    if a == 172 and b >= 16 and b <= 31 then return true end
    if a == 192 and b == 168 then return true end
    if a == 127 then return true end
    if a == 169 and b == 254 then return true end
    if a == 100 and b >= 64 and b <= 127 then return true end
    return false
end

function M.mask_ip(ip)
    if type(ip) ~= "string" then
        return "unknown"
    end
    local a, b, c, d = string_match(ip, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return ip
    end
    a, b = tonumber(a), tonumber(b)
    if is_private_octets(a, b) then
        return ip
    end
    return string_format("%d.%d.x.x", a, b)
end

function M.mask_text(s)
    if type(s) ~= "string" then
        return s
    end
    return (string_gsub(s, "%d+%.%d+%.%d+%.%d+", function(ip)
        return M.mask_ip(ip)
    end))
end

M.HIDDEN_IP = "x.x.x.x"

function M.hide_ip(ip)
    if type(ip) ~= "string" then
        return "unknown"
    end
    local a, b = string_match(ip, "^(%d+)%.(%d+)%.%d+%.%d+$")
    if not a then
        return ip
    end
    if is_private_octets(tonumber(a), tonumber(b)) then
        return ip
    end
    return M.HIDDEN_IP
end

function M.hide_text(s)
    if type(s) ~= "string" then
        return s
    end
    return (string_gsub(s, "%d+%.%d+%.%d+%.%d+", function(ip)
        return M.hide_ip(ip)
    end))
end

function M.hide_code(code)
    if type(code) ~= "string" or code == "" then
        return code
    end
    return (string_gsub(code, "%w", "x"))
end

function M.apply(s, enabled)
    if not enabled then
        return s
    end
    return M.hide_text(s)
end

function M.apply_code(code, enabled)
    if not enabled then
        return code
    end
    return M.hide_code(code)
end

return M
