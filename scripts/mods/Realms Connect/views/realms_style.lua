--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-02
--]]

local type = type
local pcall = pcall
local get_mod = get_mod

local M = {}

local STYLE_PATH = "Realms/scripts/mods/Realms/views/realms_view_style"

local FALLBACK = {
    panel_background = { 236, 30, 47, 62 },
    panel_frame = { 210, 85, 119, 143 },
    row_background = { 232, 40, 62, 80 },
    row_frame = { 180, 82, 116, 140 },
    header_text = { 255, 189, 205, 216 },
    body_text = { 255, 218, 226, 232 },
    secondary_text = { 255, 164, 184, 198 },
    control_background = { 255, 31, 58, 77 },
    control_background_selected = { 255, 47, 87, 113 },
    control_frame = { 255, 91, 137, 165 },
    control_frame_hover = { 255, 143, 186, 210 },
}

local resolved
local reported

function M.reset()
    resolved = nil
    reported = false
end

local function realms_style(log)
    if resolved ~= nil then
        return resolved or nil
    end

    local realms = get_mod("Realms")
    if not realms or type(realms.io_dofile) ~= "function" then
        resolved = false
        if log and not reported then
            reported = true
            log("style: Realms is not loaded, falling back to a copy of its palette")
        end
        return nil
    end

    local ok, loaded = pcall(realms.io_dofile, realms, STYLE_PATH)
    if not ok or type(loaded) ~= "table" or type(loaded.color) ~= "function" then
        resolved = false
        if log and not reported then
            reported = true
            log("style: Realms' view style could not be read (" .. tostring(loaded) ..
                "), falling back to a copy of its palette")
        end
        return nil
    end

    resolved = loaded
    return resolved
end

local function copy(rgba)
    return { rgba[1], rgba[2], rgba[3], rgba[4] }
end

function M.color(name, log)
    local style = realms_style(log)

    if style then
        local ok, value = pcall(style.color, name)
        if ok and type(value) == "table" and #value == 4 then
            return value
        end
        if log and not reported then
            reported = true
            log("style: Realms has no colour named '" .. tostring(name) ..
                "', falling back to a copy of its palette")
        end
    end

    local fallback = FALLBACK[name] or FALLBACK.body_text
    return copy(fallback)
end

function M.button_pass_template(log)
    local style = realms_style(log)

    if style and type(style.button_pass_template) == "function" then
        local ok, template = pcall(style.button_pass_template)
        if ok and type(template) == "table" and #template > 0 then
            return template
        end
    end

    return nil
end

function M.create_panel(scenegraph_id, log)
    local style = realms_style(log)

    if style and type(style.create_panel) == "function" then
        local ok, definition = pcall(style.create_panel, scenegraph_id)
        if ok and type(definition) == "table" then
            return definition
        end
    end

    return nil
end

function M.using_realms_palette()
    return resolved ~= nil and resolved ~= false
end

return M
