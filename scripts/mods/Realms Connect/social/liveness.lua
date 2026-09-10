--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-09
--]]

local type = type
local pcall = pcall
local rawget = rawget
local tostring = tostring

local M = {}

local IN_GAME = "in_game"
local PLATFORM_ONLINE = "platform_online"

M.IN_GAME = IN_GAME
M.PLATFORM_ONLINE = PLATFORM_ONLINE

local function platform_social_of(player)
    if type(player) ~= "table" then
        return nil
    end
    local ps = rawget(player, "_platform_social")
    if type(ps) ~= "table" then
        return nil
    end
    return ps
end

local function platform_status(ps)
    if type(ps.online_status) ~= "function" then
        return nil
    end
    local ok, status = pcall(ps.online_status, ps)
    if ok and status == PLATFORM_ONLINE then
        return PLATFORM_ONLINE
    end
    return nil
end

local function xbox_in_game(ps)
    local data = rawget(ps, "_friend_data")
    if type(data) ~= "table" then
        return false
    end
    return data.title_online == true
end

function M.new(deps)
    deps = deps or {}
    local friends = deps.friends
    if friends == nil then
        friends = rawget(_G, "Friends")
    end
    local app_id = deps.app_id or function()
        local steam = rawget(_G, "Steam")
        if type(steam) == "table" and type(steam.app_id) == "function" then
            local ok, id = pcall(steam.app_id)
            if ok then
                return id
            end
        end
        return nil
    end

    local l = {}

    local function steam_in_game(ps)
        if type(friends) ~= "table" or type(friends.playing_game) ~= "function" then
            return false
        end
        if type(ps.id) ~= "function" then
            return false
        end
        local ok_id, id = pcall(ps.id, ps)
        if not ok_id or id == nil then
            return false
        end
        local ok_game, game = pcall(friends.playing_game, id)
        if not ok_game or type(game) ~= "table" then
            return false
        end
        local mine = app_id()
        if mine == nil then
            return false
        end
        return tostring(game.app_id) == tostring(mine)
    end

    function l.of(player)
        local ps = platform_social_of(player)
        if not ps then
            return nil
        end

        local platform = rawget(player, "_platform")
        if type(platform) ~= "string" or platform == "" then
            platform = nil
            if type(ps.platform) == "function" then
                local ok, value = pcall(ps.platform, ps)
                platform = ok and value or nil
            end
        end

        if platform == "xbox" then
            if xbox_in_game(ps) then
                return IN_GAME
            end
        elseif steam_in_game(ps) then
            return IN_GAME
        end

        return platform_status(ps)
    end

    return l
end

return M
