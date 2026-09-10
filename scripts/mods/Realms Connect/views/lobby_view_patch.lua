--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-04
--]]

local type = type
local tostring = tostring
local table_concat = table.concat

local UIWidget = require("scripts/managers/ui/ui_widget")
local UIFontSettings = require("scripts/managers/ui/ui_font_settings")
local UISoundEvents = require("scripts/settings/ui/ui_sound_events")

local M = {}

local TAB_MISSION = "mission"
local TAB_REQUESTS = "requests"

local ROW_WIDTH = 344
local ROW_HEIGHT = 120
local ROW_INSET = 10
local ROW_BOTTOM_PAD = 4
local ROW_BUTTON_WIDTH = 157
local ROW_BUTTON_HEIGHT = 28
local ROW_BUTTON_GAP = 10
local ROW_NAME_Y = 8
local ROW_DETAIL_Y = 38
local ROW_COUNTDOWN_Y = 62

local TAB_HEIGHT = 30
local TAB_WIDTH = 168

M.TAB_MISSION = TAB_MISSION
M.TAB_REQUESTS = TAB_REQUESTS

local function text_style(font, color, size)
    local style = table.clone(UIFontSettings[font])
    style.text_horizontal_alignment = "left"
    style.text_vertical_alignment = "top"
    style.text_color = color
    style.offset = { ROW_INSET, 0, 2 }
    style.size = size
    return style
end

function M.request_blueprint(style_module, log)
    local body = style_module.color("body_text", log)
    local secondary = style_module.color("secondary_text", log)
    local row_bg = style_module.color("row_background", log)
    local row_frame = style_module.color("row_frame", log)
    local control_bg = style_module.color("control_background", log)
    local control_frame = style_module.color("control_frame", log)
    local control_hover = style_module.color("control_frame_hover", log)

    local function button_passes(id, label_id, x)
        return {
            {
                content_id = id,
                pass_type = "hotspot",
                content = { on_hover_sound = UISoundEvents.default_mouse_hover },
                style = {
                    offset = { x, ROW_HEIGHT - ROW_BOTTOM_PAD - ROW_BUTTON_HEIGHT, 1 },
                    size = { ROW_BUTTON_WIDTH, ROW_BUTTON_HEIGHT },
                },
            },
            {
                pass_type = "rect",
                style_id = id .. "_bg",
                style = {
                    color = { control_bg[1], control_bg[2], control_bg[3], control_bg[4] },
                    offset = { x, ROW_HEIGHT - ROW_BOTTOM_PAD - ROW_BUTTON_HEIGHT, 2 },
                    size = { ROW_BUTTON_WIDTH, ROW_BUTTON_HEIGHT },
                },
            },
            {
                pass_type = "texture",
                value = "content/ui/materials/frames/frame_tile_2px",
                style_id = id .. "_frame",
                style = {
                    scale_to_material = true,
                    color = { control_frame[1], control_frame[2], control_frame[3], control_frame[4] },
                    offset = { x, ROW_HEIGHT - ROW_BOTTOM_PAD - ROW_BUTTON_HEIGHT, 3 },
                    size = { ROW_BUTTON_WIDTH, ROW_BUTTON_HEIGHT },
                },
                change_function = function(content, style)
                    local hotspot = content[id]
                    local colour = style.color
                    if not hotspot or not colour then
                        return
                    end
                    local target = hotspot.is_hover and control_hover or control_frame
                    for i = 1, 4 do
                        colour[i] = target[i]
                    end
                end,
            },
            {
                pass_type = "text",
                style_id = label_id,
                value_id = label_id,
                value = "",
                style = {
                    font_size = 18,
                    font_type = "proxima_nova_bold",
                    text_horizontal_alignment = "center",
                    text_vertical_alignment = "center",
                    text_color = { body[1], body[2], body[3], body[4] },
                    offset = { x, ROW_HEIGHT - ROW_BOTTOM_PAD - ROW_BUTTON_HEIGHT, 4 },
                    size = { ROW_BUTTON_WIDTH, ROW_BUTTON_HEIGHT },
                },
            },
        }
    end

    local passes = {
        {
            pass_type = "rect",
            style_id = "background",
            style = {
                color = { row_bg[1], row_bg[2], row_bg[3], row_bg[4] },
                offset = { 0, 0, 0 },
                size = { ROW_WIDTH, ROW_HEIGHT - 6 },
            },
        },
        {
            pass_type = "texture",
            value = "content/ui/materials/frames/frame_tile_2px",
            style_id = "frame",
            style = {
                scale_to_material = true,
                color = { row_frame[1], row_frame[2], row_frame[3], row_frame[4] },
                offset = { 0, 0, 1 },
                size = { ROW_WIDTH, ROW_HEIGHT - 6 },
            },
        },
        {
            pass_type = "text",
            style_id = "name",
            value_id = "name",
            value = "",
            style = text_style("header_4", { body[1], body[2], body[3], body[4] },
                { ROW_WIDTH - ROW_INSET * 2, 24 }),
        },
        {
            pass_type = "text",
            style_id = "detail",
            value_id = "detail",
            value = "",
            style = text_style("body_small", { secondary[1], secondary[2], secondary[3], secondary[4] },
                { ROW_WIDTH - ROW_INSET * 2, 20 }),
        },
        {
            pass_type = "text",
            style_id = "countdown",
            value_id = "countdown",
            value = "",
            style = text_style("body_small", { body[1], body[2], body[3], body[4] },
                { ROW_WIDTH - ROW_INSET * 2, 20 }),
        },
    }

    passes[3].style.offset = { ROW_INSET, ROW_NAME_Y, 2 }
    passes[4].style.offset = { ROW_INSET, ROW_DETAIL_Y, 2 }
    passes[5].style.offset = { ROW_INSET, ROW_COUNTDOWN_Y, 2 }

    local accept = button_passes("accept_hotspot", "accept_text", ROW_INSET)
    local deny = button_passes("deny_hotspot", "deny_text", ROW_INSET + ROW_BUTTON_WIDTH + ROW_BUTTON_GAP)

    for i = 1, #accept do
        passes[#passes + 1] = accept[i]
    end
    for i = 1, #deny do
        passes[#passes + 1] = deny[i]
    end

    return {
        pass_template = passes,
        size = { ROW_WIDTH, ROW_HEIGHT },
        init = function(_, widget, element)
            local content = widget.content
            content.element = element
            content.name = element.name
            content.detail = element.detail
            content.countdown = element.countdown or ""
            content.accept_text = element.accept_text
            content.deny_text = element.deny_text
            content.accept_hotspot.pressed_callback = element.on_accept
            content.deny_hotspot.pressed_callback = element.on_deny
        end,
    }
end

function M.rows_to_layout(rows, labels, on_accept, on_deny)
    local layout = {}

    for i = 1, #rows do
        local row = rows[i]
        local nonce = row.nonce
        local detail = row.relationship or ""
        if row.compatibility and row.compatibility ~= "" then
            if detail ~= "" then
                detail = detail .. "   " .. row.compatibility
            else
                detail = row.compatibility
            end
        end

        layout[#layout + 1] = {
            key = "rc_request:" .. tostring(nonce),
            widget_type = "realms_connect_request",
            nonce = nonce,
            name = row.name,
            detail = detail,
            countdown = row.countdown,
            accept_text = labels.accept,
            deny_text = labels.deny,
            on_accept = function() on_accept(nonce) end,
            on_deny = function() on_deny(nonce) end,
        }
    end

    return layout
end

function M.message_layout(text)
    return {
        {
            key = "rc_message",
            widget_type = "realms_connect_message",
            text = text,
        },
    }
end

function M.message_blueprint(style_module, log)
    local secondary = style_module.color("secondary_text", log)

    return {
        pass_template = {
            {
                pass_type = "text",
                style_id = "text",
                value_id = "text",
                value = "",
                style = {
                    font_size = 20,
                    font_type = "proxima_nova_medium",
                    text_horizontal_alignment = "left",
                    text_vertical_alignment = "top",
                    word_wrap = true,
                    text_color = { secondary[1], secondary[2], secondary[3], secondary[4] },
                    offset = { ROW_INSET, 4, 2 },
                    size = { ROW_WIDTH - ROW_INSET * 2, 96 },
                },
            },
        },
        size = { ROW_WIDTH, 104 },
        init = function(_, widget, element)
            widget.content.element = element
            widget.content.text = element.text
        end,
    }
end

function M.layout_signature(layout)
    local parts = {}

    for i = 1, #layout do
        local entry = layout[i]
        parts[#parts + 1] = tostring(entry.key) .. "|" .. tostring(entry.name or entry.text) ..
            "|" .. tostring(entry.relationship or "") .. "|" .. tostring(entry.compatibility or "")
    end

    return table_concat(parts, "\n")
end

M.TAB_HEIGHT = TAB_HEIGHT
M.TAB_WIDTH = TAB_WIDTH
M.ROW_WIDTH = ROW_WIDTH
M.ROW_HEIGHT = ROW_HEIGHT
M.ROW_INSET = ROW_INSET
M.ROW_DETAIL_Y = ROW_DETAIL_Y
M.ROW_COUNTDOWN_Y = ROW_COUNTDOWN_Y

return M
