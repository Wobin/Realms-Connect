--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-01
--]]

local type = type
local pcall = pcall
local tostring = tostring

local M = {}

local function noop() end

function M.local_player_safe(player_manager, connection_fn)
    if type(player_manager) ~= "table" then
        return nil
    end

    if type(player_manager.local_player_safe) == "function" then
        local ok, player = pcall(player_manager.local_player_safe, player_manager, 1)
        if ok then
            return player
        end
        return nil
    end

    local connection_manager = connection_fn and connection_fn()
    if type(connection_manager) ~= "table"
        or type(connection_manager.is_initialized) ~= "function"
        or not connection_manager:is_initialized() then
        return nil
    end

    if type(player_manager.local_player) ~= "function" then
        return nil
    end

    local ok, player = pcall(player_manager.local_player, player_manager, 1)
    if ok then
        return player
    end
    return nil
end

function M.new(deps)
    deps = deps or {}
    local player_fn = deps.player or noop
    local connection_fn = deps.connection or noop
    local social_fn = deps.social or noop
    local log = deps.log or noop
    local local_player_safe = M.local_player_safe

    local i = {}

    local function describe_rejection(err)
        if type(err) == "table" then
            if type(err.aborted) == "boolean" then
                return "the request was aborted"
            end
            if type(err.message) == "string" then
                return err.message
            end
            return "the backend rejected the request"
        end
        return tostring(err)
    end

    local cached_account_id

    local cached_friend_code
    local friend_code_pending = false
    local friend_code_failed = false
    local friend_code_reason = "not fetched yet"

    function i.account_id()
        if cached_account_id then
            return cached_account_id
        end

        local player_manager = player_fn()
        if type(player_manager) ~= "table" then
            return nil, "Managers.player is not available yet"
        end

        local player = local_player_safe(player_manager, connection_fn)
        if type(player) ~= "table" then
            return nil, "there is no local player yet"
        end

        if type(player.account_id) ~= "function" then
            return nil, "the local player has no account_id"
        end

        local ok2, account_id = pcall(player.account_id, player)
        if not ok2 or type(account_id) ~= "string" or account_id == "" then
            return nil, "could not read the local account id"
        end

        cached_account_id = account_id
        log("identity: resolved the local account id")
        return cached_account_id
    end

    function i.friend_code()
        if cached_friend_code then
            return cached_friend_code
        end
        if friend_code_pending or friend_code_failed then
            return nil, friend_code_reason
        end

        local social = social_fn()
        if type(social) ~= "table" or type(social.get_fatshark_id) ~= "function" then
            friend_code_reason = "the social service is not available yet"
            return nil, friend_code_reason
        end

        local ok, promise = pcall(social.get_fatshark_id, social)
        if not ok or type(promise) ~= "table" or type(promise.next) ~= "function" then
            friend_code_reason = "could not start the friend code lookup"
            return nil, friend_code_reason
        end

        friend_code_pending = true
        friend_code_reason = "resolving your friend code"

        promise:next(function(value)
            friend_code_pending = false
            if type(value) ~= "string" or value == "" then
                friend_code_failed = true
                friend_code_reason = "the backend returned no friend code"
                return
            end
            cached_friend_code = value
            log("identity: resolved the local friend code")
        end, function(err)
            friend_code_pending = false
            friend_code_failed = true
            friend_code_reason = "friend code lookup failed - " .. describe_rejection(err)
        end)

        if cached_friend_code then
            return cached_friend_code
        end
        return nil, friend_code_reason
    end

    function i.friend_code_status()
        if cached_friend_code then
            return cached_friend_code
        end
        return nil, friend_code_reason
    end

    return i
end

return M
