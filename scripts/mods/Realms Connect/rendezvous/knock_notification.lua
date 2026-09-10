--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-04
--]]

local type = type
local tostring = tostring

local M = {}

local ACCEPT_ALIAS = "notification_option_a"
local DECLINE_ALIAS = "notification_option_b"
local TEMPLATE = "matchmaking"

M.ACCEPT_ALIAS = ACCEPT_ALIAS
M.DECLINE_ALIAS = DECLINE_ALIAS
M.TEMPLATE = TEMPLATE

function M.should_suppress(opts)
    opts = opts or {}
    return opts.view_active == true or opts.party_invite_active == true
end

function M.party_invite_state(handler)
    if type(handler) ~= "table" then
        return false, false
    end
    return handler._active_invite ~= nil, true
end

local function noop() end

local function text_of(localize, key)
    local value = localize and localize(key)
    if type(value) ~= "string" then
        return key
    end
    return value
end

local function literal(value)
    return (tostring(value):gsub("%%", "%%%%"))
end

function M.new(deps)
    deps = deps or {}

    local pending = deps.pending or function() return nil end
    local accept = deps.accept or noop
    local decline = deps.decline or noop
    local suppressed = deps.suppressed or function() return false end
    local localize = deps.localize
    local input_text = deps.input_text or function() return "" end
    local pressed = deps.pressed or function() return false end
    local echo = deps.echo or noop
    local log = deps.log or noop

    local events = deps.events or {}
    local events_add = events.add or noop
    local events_remove = events.remove or noop
    local events_progress = events.progress or noop

    local n = {}
    local active
    local settled

    local function dismiss()
        if not active then
            return
        end
        if active.notification_id ~= nil then
            events_remove(active.notification_id)
        end
        active = nil
    end

    local function settle(verb, answer)
        if not active then
            return
        end

        local nonce = active.nonce
        local ok, err = answer(nonce)

        if ok == false then
            log("knock notification: " .. verb .. " " .. tostring(nonce) ..
                " failed, leaving the knock answerable: " .. tostring(err))
            return
        end

        settled = nonce
        dismiss()
    end

    local function seconds_of(request)
        local left = request and request.seconds_left
        if type(left) == "number" and left > 0 then
            return left
        end
        return nil
    end

    local function show(request)
        local accept_glyph = literal(input_text(ACCEPT_ALIAS))
        local decline_glyph = literal(input_text(DECLINE_ALIAS))
        local name = literal(request.name)

        local body = text_of(localize, "knock_notification_body")
            :gsub("{name}", name)
            :gsub("{relationship}", literal(request.relationship))

        local hint = text_of(localize, "knock_notification_accept")
            :gsub("{accept}", accept_glyph)
            :gsub("{decline}", decline_glyph)

        active = { nonce = request.nonce, total = seconds_of(request) }

        events_add(TEMPLATE, {
            texts = {
                text_of(localize, "accept_prompt_title"),
                body,
                hint,
            },
        }, function(notification_id)
            if active then
                active.notification_id = notification_id
            else
                events_remove(notification_id)
            end
        end)

        echo(text_of(localize, "knock_notification_echo")
            :gsub("{name}", name)
            :gsub("{accept}", accept_glyph)
            :gsub("{decline}", decline_glyph))
    end

    function n.update()
        local request = pending()
        local nonce = type(request) == "table" and request.nonce or nil

        if nonce == nil then
            settled = nil
            dismiss()
            return
        end

        if nonce ~= settled then
            settled = nil
        end

        if suppressed() or nonce == settled then
            dismiss()
            return
        end

        if active and active.nonce ~= nonce then
            dismiss()
        end

        if not active then
            show(request)
            return
        end

        if pressed(ACCEPT_ALIAS) then
            settle("accepting", accept)
            return
        end

        if pressed(DECLINE_ALIAS) then
            settle("refusing", decline)
            return
        end

        if active.notification_id ~= nil and active.total then
            local left = seconds_of(request) or 0
            local fraction = left / active.total
            if fraction < 0 then
                fraction = 0
            elseif fraction > 1 then
                fraction = 1
            end
            events_progress(active.notification_id, fraction)
        end
    end

    function n.clear()
        dismiss()
        settled = nil
    end

    function n.active_nonce()
        return active and active.nonce or nil
    end

    return n
end

return M
