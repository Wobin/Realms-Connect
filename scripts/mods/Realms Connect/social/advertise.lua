--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-11
--]]

local type = type

local M = {}

local MODE_OFF = "off"
local MODE_FRIENDS = "friends"
local MODE_OPEN = "open"

local ACTION_HOLD = "hold"
local ACTION_RETRACT = "retract"
local ACTION_PUBLISH = "publish"

M.ACTION_HOLD = ACTION_HOLD
M.ACTION_RETRACT = ACTION_RETRACT
M.ACTION_PUBLISH = ACTION_PUBLISH

local DECISION_ALLOW = "allow"
local DECISION_PROMPT = "prompt"
local DECISION_REFUSE = "refuse"

M.DECISION_ALLOW = DECISION_ALLOW
M.DECISION_PROMPT = DECISION_PROMPT
M.DECISION_REFUSE = DECISION_REFUSE

local function noop() end
local function false_fn() return false end

local function trimmed(text)
    return text:match("^%s*(.-)%s*$")
end

local function split_codes(text)
    local out = {}
    if type(text) ~= "string" then
        return out
    end
    for piece in text:gmatch("[^,]+") do
        local clean = trimmed(piece)
        if clean ~= "" then
            out[#out + 1] = clean
        end
    end
    return out
end

local function refs_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    return a.platform == b.platform and a.id == b.id
end

function M.new(deps)
    deps = deps or {}
    local resolver = deps.resolver
    local advertise_mode = deps.advertise_mode or noop
    local saved_codes = deps.saved_codes or noop
    local auto_accept_friends = deps.auto_accept_friends or noop
    local auto_accept_in_mission = deps.auto_accept_in_mission or noop
    local in_mission = deps.in_mission or false_fn
    local is_friend = deps.is_friend or false_fn
    local is_party = deps.is_party or false_fn
    local is_remembered = deps.is_remembered or false_fn

    local a = {}

    function a.saved_refs()
        local out = {}
        if type(resolver) ~= "table" or type(resolver.cached) ~= "function" then
            return out
        end
        local codes = split_codes(saved_codes())
        for i = 1, #codes do
            local ref = resolver.cached(codes[i])
            if ref then
                out[#out + 1] = ref
            end
        end
        return out
    end

    local function saved_contains(ref)
        local refs = a.saved_refs()
        for i = 1, #refs do
            if refs_equal(refs[i], ref) then
                return true
            end
        end
        return false
    end

    function a.is_known_friend(ref)
        return saved_contains(ref) or is_friend(ref) == true or is_party(ref) == true
            or is_remembered(ref) == true
    end

    function a.decide(ref)
        local mode = advertise_mode()

        if mode == MODE_OFF then
            return DECISION_REFUSE
        end

        local known = a.is_known_friend(ref)

        if mode == MODE_FRIENDS then
            if not known then
                return DECISION_REFUSE
            end
        elseif mode ~= MODE_OPEN then
            return DECISION_REFUSE
        end

        if in_mission() == true then
            if known and auto_accept_in_mission() then
                return DECISION_ALLOW
            end

            return DECISION_REFUSE
        end

        if not known or not auto_accept_friends() then
            return DECISION_PROMPT
        end

        return DECISION_ALLOW
    end

    function a.accepting_in_mission()
        return in_mission() ~= true or auto_accept_in_mission() == true
    end

    function a.beacon_action(is_hosting, responder_state, join_owns_channel)
        if join_owns_channel or responder_state ~= "idle" then
            return ACTION_HOLD
        end
        if is_hosting ~= true then
            return ACTION_RETRACT
        end
        if advertise_mode() == MODE_OFF then
            return ACTION_RETRACT
        end
        return ACTION_PUBLISH
    end

    return a
end

return M
