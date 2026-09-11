--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-11
--]]

local type = type
local tostring = tostring

local M = {}

function M.key(ref)
    if type(ref) ~= "table" or type(ref.id) ~= "string" then
        return nil
    end
    return tostring(ref.platform) .. ":" .. ref.id
end

return M
