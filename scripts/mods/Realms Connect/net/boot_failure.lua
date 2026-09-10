--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-04
--]]

local type = type
local pcall = pcall

local M = {}

M.GENERIC = "Realms reported the client boot failed"
M.PROTOCOL_MISMATCH = "realms_protocol_mismatch"
M.PROTOCOL_MISMATCH_KEY = "join_realms_version_mismatch"

local FALLBACK_MISMATCH =
    "You and the host are running different versions of Realms, so Realms refused the connection."

local function usable(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

local function disconnection_info(session_boot)
    if type(session_boot) ~= "table" or type(session_boot.event_object) ~= "function" then
        return nil
    end

    local got_object, event_object = pcall(session_boot.event_object, session_boot)
    if not got_object or type(event_object) ~= "table"
        or type(event_object.disconnection_info) ~= "function" then
        return nil
    end

    local got_info, info = pcall(event_object.disconnection_info, event_object)
    if not got_info or type(info) ~= "table" then
        return nil
    end

    return info
end

function M.reason(session_boot, localize)
    local info = disconnection_info(session_boot)
    if not info then
        return M.GENERIC
    end

    local reason = usable(info.reason)
    local details = usable(info.error_details)

    if reason == M.PROTOCOL_MISMATCH then
        if type(localize) == "function" then
            local said, text = pcall(localize, M.PROTOCOL_MISMATCH_KEY)
            if said then
                local usable_text = usable(text)
                if usable_text then
                    return usable_text
                end
            end
        end
        return FALLBACK_MISMATCH
    end

    if reason then
        if details then
            return reason .. " - " .. details
        end
        return reason
    end

    if details then
        return details
    end

    return M.GENERIC
end

return M
