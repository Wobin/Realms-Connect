--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-04
--]]

local M = {}

M.DESTROY = "destroy"
M.ABANDON = "abandon"
M.NONE = "none"

function M.disposal(opts)
    opts = opts or {}

    if opts.browser == nil or opts.owner_client == nil then
        return M.NONE
    end

    if opts.exit_game == true then
        return M.ABANDON
    end

    if opts.api_present ~= true then
        return M.ABANDON
    end

    if opts.live_client == nil or opts.live_client ~= opts.owner_client then
        return M.ABANDON
    end

    return M.DESTROY
end

return M
