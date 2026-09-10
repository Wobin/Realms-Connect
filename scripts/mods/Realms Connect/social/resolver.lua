--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-01
--]]

local type = type
local tostring = tostring
local pcall = pcall

local M = {}

local function noop() end

function M.new(deps)
    deps = deps or {}
    local social_fn = deps.social or noop
    local log = deps.log or noop

    local r = {}

    local cache = {}
    local pending = {}

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

    local function settle(code_text, ok, ref, reason)
        local waiters = pending[code_text]
        pending[code_text] = nil
        if not waiters then
            return
        end
        for i = 1, #waiters do
            waiters[i](ok, ref, reason)
        end
    end

    function r.cached(code_text)
        local entry = cache[code_text]
        if entry and entry.ok then
            return entry.ref
        end
        return nil
    end

    function r.resolve(code_text, callback)
        callback = callback or noop

        local entry = cache[code_text]
        if entry then
            callback(entry.ok, entry.ref, entry.reason)
            return
        end

        local waiters = pending[code_text]
        if waiters then
            waiters[#waiters + 1] = callback
            return
        end
        pending[code_text] = { callback }

        local social = social_fn()
        if type(social) ~= "table" or type(social.get_player_info_by_fatshark_id) ~= "function" then
            settle(code_text, false, nil, "the social service is not available yet")
            return
        end

        local ok, promise = pcall(social.get_player_info_by_fatshark_id, social, code_text)
        if not ok or type(promise) ~= "table" or type(promise.next) ~= "function" then
            settle(code_text, false, nil, "could not start the friend code lookup")
            return
        end

        promise:next(function(player_info)
            if not player_info then
                local reason = "no player has that friend code"
                cache[code_text] = { ok = false, reason = reason }
                settle(code_text, false, nil, reason)
                return
            end

            local ok2, account_id = pcall(player_info.account_id, player_info)
            if not ok2 or type(account_id) ~= "string" or account_id == "" then
                settle(code_text, false, nil, "friend code resolved but the account id was unreadable")
                return
            end

            local ref = { id = account_id, info = player_info }
            cache[code_text] = { ok = true, ref = ref }
            log("resolver: resolved a friend code to an account")
            settle(code_text, true, ref)
        end, function(err)
            settle(code_text, false, nil, "friend code lookup failed - " .. describe_rejection(err))
        end)
    end

    return r
end

return M
