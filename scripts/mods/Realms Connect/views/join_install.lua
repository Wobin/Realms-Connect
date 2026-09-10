--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-08
--]]

local type = type
local pairs = pairs
local table_concat = table.concat

local UIWidget = require("scripts/managers/ui/ui_widget")
local UIFontSettings = require("scripts/managers/ui/ui_font_settings")
local UISoundEvents = require("scripts/settings/ui/ui_sound_events")
local ok_scenegraph, UIScenegraph = pcall(require, "scripts/managers/ui/ui_scenegraph")
if not ok_scenegraph then
    UIScenegraph = nil
end

local M = {}

local VIEW_CLASS = "RealmsJoinView"
local VIEW_NAME = "realms_join_view"

M.VIEW_NAME = VIEW_NAME

local ANCHOR = "panel"
local REALMS_PANEL_HEIGHT = 480
local SECTION_GAP = 16

local SECTION_X = 0
local SECTION_Y = REALMS_PANEL_HEIGHT + SECTION_GAP
local SECTION_W = 720
local SECTION_H = 340
local INSET = 32

local TITLE_Y = SECTION_Y + 16
local LABEL_Y = SECTION_Y + 54
local INPUT_Y = SECTION_Y + 82
local INPUT_W = 330
local CONNECT_GAP = 12
local CONNECT_X = SECTION_X + INSET + INPUT_W + CONNECT_GAP
local CONNECT_W = 150
local SKIP_GAP = 10
local SKIP_X = CONNECT_X + CONNECT_W + SKIP_GAP
local SKIP_BTN_W = SECTION_W - INSET * 2 - INPUT_W - CONNECT_GAP - CONNECT_W - SKIP_GAP

local CONTENT_W = SECTION_W - INSET * 2

local CARD_PAD = 12
local CARD_X = SECTION_X + INSET - CARD_PAD
local CARD_Y = SECTION_Y + 44
local CARD_W = CONTENT_W + CARD_PAD * 2
local CARD_H = 196

local CARD_POSITION_Y = SECTION_Y + 54
local CARD_NAME_Y = SECTION_Y + 84
local CARD_DETAIL_Y = SECTION_Y + 118
local CARD_PW_LABEL_Y = SECTION_Y + 150
local CARD_ROW_Y = SECTION_Y + 176
local CARD_ROW_H = 48

local SCAN_Y = SECTION_Y + 250
local RESULTS_Y = SECTION_Y + 292

local SCREEN_HEIGHT = 1080
local BLOCK_HEIGHT = REALMS_PANEL_HEIGHT + SECTION_GAP + SECTION_H
local PANEL_LIFT = -((SCREEN_HEIGHT - REALMS_PANEL_HEIGHT) / 2 - (SCREEN_HEIGHT - BLOCK_HEIGHT) / 2)

M.PANEL_LIFT = PANEL_LIFT
M.SECTION_H = SECTION_H
M.SECTION_GAP = SECTION_GAP
M.REALMS_PANEL_HEIGHT = REALMS_PANEL_HEIGHT
M.SCREEN_HEIGHT = SCREEN_HEIGHT

local WIDGET_NAMES = {
    "rc_section",
    "rc_title",
    "rc_code_label",
    "rc_code_input",
    "rc_connect",
    "rc_card_frame",
    "rc_card_position",
    "rc_card_name",
    "rc_card_detail",
    "rc_card_pw_label",
    "rc_card_password",
    "rc_card_connect",
    "rc_card_skip",
    "rc_scan",
    "rc_results",
}

M.WIDGET_NAMES = WIDGET_NAMES

M.INPUT_ROW = {
    inset = INSET,
    content_width = CONTENT_W,
    input = { x = SECTION_X + INSET, w = INPUT_W },
    connect = { x = CONNECT_X, w = CONNECT_W },
    skip = { x = SKIP_X, w = SKIP_BTN_W },
}

M.CARD = {
    x = CARD_X,
    y = CARD_Y,
    w = CARD_W,
    h = CARD_H,
    position_y = CARD_POSITION_Y,
    name_y = CARD_NAME_Y,
    detail_y = CARD_DETAIL_Y,
    password_label_y = CARD_PW_LABEL_Y,
    row_y = CARD_ROW_Y,
    row_h = CARD_ROW_H,
    scan_y = SCAN_Y,
    results_y = RESULTS_Y,
    section_bottom = SECTION_Y + SECTION_H,
}

local function rgba(c)
    return { c[1], c[2], c[3], c[4] }
end

function M.text_definition(style_module, log, colour_name, font, x, y, w, h, wrap)
    local colour = style_module.color(colour_name, log)
    local style = table.clone(UIFontSettings[font])

    style.text_horizontal_alignment = "left"
    style.text_vertical_alignment = "top"
    style.text_color = rgba(colour)
    style.offset = { x, y, 12 }
    style.size = { w, h }
    style.word_wrap = wrap == true

    return UIWidget.create_definition({
        {
            pass_type = "text",
            style_id = "text",
            value_id = "text",
            value = "",
            style = style,
        },
    }, ANCHOR, { text = "" }, { w, h })
end

function M.button_definition(style_module, log, x, y, w, h)
    local bg = style_module.color("control_background", log)
    local bg_on = style_module.color("control_background_selected", log)
    local frame = style_module.color("control_frame", log)
    local frame_on = style_module.color("control_frame_hover", log)
    local body = style_module.color("body_text", log)
    local header = style_module.color("header_text", log)
    local dim = style_module.color("secondary_text", log)

    return UIWidget.create_definition({
        {
            content_id = "hotspot",
            pass_type = "hotspot",
            content = { on_hover_sound = UISoundEvents.default_mouse_hover },
            style = { offset = { x, y, 11 }, size = { w, h } },
        },
        {
            pass_type = "rect",
            style_id = "background",
            style = { color = rgba(bg), offset = { x, y, 12 }, size = { w, h } },
            change_function = function(content, style)
                local target = content.hotspot.is_hover and not content.hotspot.disabled and bg_on or bg
                for i = 1, 4 do
                    style.color[i] = target[i]
                end
            end,
        },
        {
            pass_type = "texture",
            value = "content/ui/materials/frames/frame_tile_2px",
            style_id = "frame",
            style = {
                scale_to_material = true,
                color = rgba(frame),
                offset = { x, y, 13 },
                size = { w, h },
            },
            change_function = function(content, style)
                local target = content.hotspot.is_hover and not content.hotspot.disabled and frame_on or frame
                for i = 1, 4 do
                    style.color[i] = target[i]
                end
            end,
        },
        {
            pass_type = "text",
            style_id = "text",
            value_id = "text",
            value = "",
            style = {
                font_size = 20,
                font_type = "proxima_nova_bold",
                text_horizontal_alignment = "center",
                text_vertical_alignment = "center",
                text_color = rgba(body),
                offset = { x, y, 14 },
                size = { w, h },
            },
            change_function = function(content, style)
                local colour = style.text_color
                if not colour then
                    return
                end
                local target = body
                if content.hotspot.disabled then
                    target = dim
                elseif content.hotspot.is_hover then
                    target = header
                end
                for i = 1, 4 do
                    colour[i] = target[i]
                end
            end,
        },
    }, ANCHOR, { text = "", hotspot = {} }, { w, h })
end

local function frame_definition(style_module, log, bg_name, frame_name, x, y, w, h, z)
    local bg = style_module.color(bg_name, log)
    local frame = style_module.color(frame_name, log)

    return UIWidget.create_definition({
        {
            pass_type = "rect",
            style_id = "background",
            style = { color = rgba(bg), offset = { x, y, z }, size = { w, h } },
        },
        {
            pass_type = "texture",
            value = "content/ui/materials/frames/frame_tile_2px",
            style_id = "frame",
            style = {
                scale_to_material = true,
                color = rgba(frame),
                offset = { x, y, z + 1 },
                size = { w, h },
            },
        },
    }, ANCHOR, nil, { w, h })
end

function M.section_definition(style_module, log)
    return frame_definition(style_module, log, "panel_background", "panel_frame",
        SECTION_X, SECTION_Y, SECTION_W, SECTION_H, 10)
end

function M.card_definition(style_module, log)
    return frame_definition(style_module, log, "control_background", "control_frame",
        CARD_X, CARD_Y, CARD_W, CARD_H, 11)
end

function M.install(deps)
    local mod = deps.mod
    local style_module = deps.style_module
    local make_panel = deps.make_panel
    local localize = deps.localize
    local log = deps.log
    local on_opened = deps.on_opened or function() end
    local text_input_utils = deps.text_input_utils

    local function notify(text)
        local event = Managers and Managers.event
        if event and type(event.trigger) == "function" then
            event:trigger("event_add_notification_message", "alert", { text = tostring(text) })
        end
        log("join: refused a connect - " .. tostring(text))
    end

    local function detached_style(source)
        local style = {}

        for key, value in pairs(source) do
            if type(value) == "table" then
                local copy = {}
                for i = 1, #value do
                    copy[i] = value[i]
                end
                for k, v in pairs(value) do
                    if type(k) ~= "number" then
                        copy[k] = v
                    end
                end
                style[key] = copy
            else
                style[key] = value
            end
        end

        return style
    end

    local function input_definition(x, y, w, placeholder_key, title_key)
        local source = text_input_utils.clone_simple_input_field()
        local passes = {}

        for i = 1, #source do
            local pass = {}
            for key, value in pairs(source[i]) do
                pass[key] = value
            end

            if type(source[i].style) == "table" then
                local style = detached_style(source[i].style)

                if pass.style_id == "background" then
                    style.color = style_module.color("control_background", log)
                elseif pass.style_id == "baseline" then
                    style.color = style_module.color("control_frame", log)
                elseif pass.style_id == "focused" then
                    style.color = style_module.color("control_frame_hover", log)
                elseif pass.style_id == "display_text" then
                    style.text_color = style_module.color("body_text", log)
                elseif pass.style_id == "input_caret" then
                    style.color = style_module.color("header_text", log)
                elseif pass.style_id == "selection" then
                    style.color = style_module.color("control_background_selected", log)
                elseif pass.style_id == "active_placeholder" or pass.style_id == "limit_text" then
                    style.text_color = style_module.color("secondary_text", log)
                end

                local offset = style.offset or { 0, 0, 0 }
                style.offset = {
                    (offset[1] or 0) + x,
                    (offset[2] or 0) + y,
                    (offset[3] or 0) + 13,
                }

                pass.style = style
            elseif pass.pass_type == "hotspot" then
                pass.style = {
                    offset = { x, y, 12 },
                    size = { w, 48 },
                }
            end

            passes[i] = pass
        end

        return UIWidget.create_definition(passes, ANCHOR, {
            input_text = "",
            placeholder_text = localize(placeholder_key),
            virtual_keyboard_title = localize(title_key),
        }, { w, 48 })
    end

    local function ensure_panel_lift(self)
        local node = self._ui_scenegraph and self._ui_scenegraph[ANCHOR]

        if not node or self._rc_lifted == node then
            return
        end

        self._rc_lifted = node

        if type(node.local_position) == "table" then
            node.local_position[2] = node.local_position[2] + PANEL_LIFT
        end
        if type(node.position) == "table" and node.position ~= node.local_position then
            node.position[2] = node.position[2] + PANEL_LIFT
        end

        local scenegraph = self._ui_scenegraph
        if UIScenegraph and type(UIScenegraph.update_scenegraph) == "function" then
            UIScenegraph.update_scenegraph(scenegraph, self._render_scale or 1)
        end

        log("join: lifted the join panel and our section by " .. tostring(-PANEL_LIFT) ..
            " so the pair sits centred rather than hanging off the bottom")
    end

    local function card_password(self)
        local field = self._widgets_by_name and self._widgets_by_name.rc_card_password
        local text = field and field.content and field.content.input_text
        return type(text) == "string" and text or ""
    end

    local function clear_card_password(self)
        local field = self._widgets_by_name and self._widgets_by_name.rc_card_password
        if field and field.content then
            field.content.input_text = ""
            field.content.is_writing = false
        end
    end

    local function ensure_widgets(self)
        if self._rc_panel and self._widgets_by_name.rc_section
            and self._rc_drawn_into == self._widgets then
            return
        end

        self._rc_drawn_into = self._widgets
        self._rc_panel = self._rc_panel or make_panel()

        local definitions = {
            rc_section = M.section_definition(style_module, log),
            rc_title = M.text_definition(style_module, log, "header_text", "header_3",
                SECTION_X + INSET, TITLE_Y, CONTENT_W, 30),
            rc_code_label = M.text_definition(style_module, log, "header_text", "header_4",
                SECTION_X + INSET, LABEL_Y, CONTENT_W, 24),
            rc_code_input = input_definition(SECTION_X + INSET, INPUT_Y, INPUT_W,
                "join_view_code_placeholder", "join_panel_code_label"),
            rc_connect = M.button_definition(style_module, log,
                CONNECT_X, INPUT_Y, CONNECT_W, 48),
            rc_card_frame = M.card_definition(style_module, log),
            rc_card_position = M.text_definition(style_module, log, "secondary_text", "body_small",
                SECTION_X + INSET, CARD_POSITION_Y, CONTENT_W, 24),
            rc_card_name = M.text_definition(style_module, log, "header_text", "header_4",
                SECTION_X + INSET, CARD_NAME_Y, CONTENT_W, 30),
            rc_card_detail = M.text_definition(style_module, log, "body_text", "body_small",
                SECTION_X + INSET, CARD_DETAIL_Y, CONTENT_W, 28),
            rc_card_pw_label = M.text_definition(style_module, log, "secondary_text", "body_small",
                SECTION_X + INSET, CARD_PW_LABEL_Y, CONTENT_W, 22),
            rc_card_password = input_definition(SECTION_X + INSET, CARD_ROW_Y, INPUT_W,
                "join_view_password_placeholder", "join_panel_password_label"),
            rc_card_connect = M.button_definition(style_module, log,
                CONNECT_X, CARD_ROW_Y, CONNECT_W, CARD_ROW_H),
            rc_card_skip = M.button_definition(style_module, log,
                SKIP_X, CARD_ROW_Y, SKIP_BTN_W, CARD_ROW_H),
            rc_scan = M.button_definition(style_module, log,
                SECTION_X + INSET, SCAN_Y, CONTENT_W, 34),
            rc_results = M.text_definition(style_module, log, "secondary_text", "body_small",
                SECTION_X + INSET, RESULTS_Y, CONTENT_W, 40, true),
        }

        for i = 1, #WIDGET_NAMES do
            local name = WIDGET_NAMES[i]
            local widget = self:_create_widget(name, definitions[name])
            self._widgets[#self._widgets + 1] = widget
        end

        local widgets = self._widgets_by_name

        widgets.rc_title.content.text = localize("join_panel_title")
        widgets.rc_code_label.content.text = localize("join_panel_code_label")
        widgets.rc_card_pw_label.content.text = localize("join_panel_password_label")
        widgets.rc_connect.content.text = localize("join_card_look_up")
        widgets.rc_card_connect.content.text = localize("join_view_connect")

        widgets.rc_connect.content.hotspot.pressed_callback = function()
            local code = widgets.rc_code_input.content.input_text or ""
            local ok, reason = self._rc_panel.look_up(code)
            if not ok and reason then
                notify(reason)
            end
        end

        widgets.rc_card_connect.content.hotspot.pressed_callback = function()
            local ok, reason = self._rc_panel.join_card(card_password(self))
            if not ok and reason then
                notify(reason)
            end
        end

        widgets.rc_card_skip.content.hotspot.pressed_callback = function()
            if self._rc_card_source == "code" then
                self._rc_panel.clear_card()
                widgets.rc_code_input.content.input_text = ""
            else
                self._rc_panel.skip_lobby()
            end
            clear_card_password(self)
        end

        widgets.rc_scan.content.hotspot.pressed_callback = function()
            self._rc_panel.scan()
            clear_card_password(self)
        end

        log("join: the Realms Connect section was added to the join view")
    end

    mod:hook_safe(VIEW_CLASS, "on_enter", function(self)
        ensure_widgets(self)
        on_opened()
    end)

    mod:hook_safe(VIEW_CLASS, "on_exit", function(self)
        if self._rc_panel then
            self._rc_panel.cancel_scan()
            self._rc_panel.clear_card()
            self._rc_panel.reset()
        end
        self._rc_panel = nil
        self._rc_card_key = nil
        self._rc_card_source = nil
    end)

    local function show_code_row(widgets, state)
        widgets.rc_code_label.visible = true
        widgets.rc_code_input.visible = true
        widgets.rc_connect.visible = true
        widgets.rc_code_input.content.hotspot.disabled = false
        widgets.rc_connect.content.hotspot.disabled = not state.connect_enabled

        widgets.rc_card_frame.visible = false
        widgets.rc_card_position.visible = false
        widgets.rc_card_name.visible = false
        widgets.rc_card_detail.visible = false
        widgets.rc_card_pw_label.visible = false
        widgets.rc_card_password.visible = false
        widgets.rc_card_connect.visible = false
        widgets.rc_card_skip.visible = false

        widgets.rc_card_password.content.hotspot.disabled = true
        widgets.rc_card_password.content.is_writing = false
        widgets.rc_card_connect.content.hotspot.disabled = true
        widgets.rc_card_skip.content.hotspot.disabled = true

        widgets.rc_card_position.content.text = ""
        widgets.rc_card_name.content.text = ""
        widgets.rc_card_detail.content.text = ""
    end

    local function show_card(self, widgets, state)
        local card = state.card

        widgets.rc_code_label.visible = false
        widgets.rc_code_input.visible = false
        widgets.rc_connect.visible = false
        widgets.rc_code_input.content.hotspot.disabled = true
        widgets.rc_code_input.content.is_writing = false
        widgets.rc_connect.content.hotspot.disabled = true

        widgets.rc_card_frame.visible = true
        widgets.rc_card_position.visible = true
        widgets.rc_card_name.visible = true
        widgets.rc_card_detail.visible = true
        widgets.rc_card_pw_label.visible = card.locked
        widgets.rc_card_password.visible = card.locked
        widgets.rc_card_connect.visible = true

        widgets.rc_card_position.content.text = card.position or ""
        widgets.rc_card_name.content.text = card.name or ""
        widgets.rc_card_detail.content.text = card.detail or ""

        widgets.rc_card_password.content.hotspot.disabled = not card.locked
        if not card.locked then
            widgets.rc_card_password.content.is_writing = false
        end

        widgets.rc_card_connect.content.hotspot.disabled = not state.connect_enabled

        local back = card.source == "code"
        widgets.rc_card_skip.visible = back or card.can_skip
        widgets.rc_card_skip.content.text = back and localize("join_card_back")
            or localize("join_card_skip")
        widgets.rc_card_skip.content.hotspot.disabled = not (back or card.can_skip)

        self._rc_card_source = card.source

        if self._rc_card_key ~= card.account_id then
            self._rc_card_key = card.account_id
            clear_card_password(self)
        end
    end

    local function tick(self)
        if self.closing_view then
            return
        end

        ensure_panel_lift(self)
        ensure_widgets(self)

        local panel = self._rc_panel
        if not panel then
            return
        end

        local widgets = self._widgets_by_name
        local code = widgets.rc_code_input.content.input_text or ""
        local state = panel.state(code)

        widgets.rc_scan.content.text = state.scan_label
        widgets.rc_scan.content.hotspot.disabled = state.scan_running

        if state.mode == "card" and state.card then
            show_card(self, widgets, state)
            widgets.rc_results.content.text = ""
        else
            show_code_row(widgets, state)
            self._rc_card_key = nil
            self._rc_card_source = nil

            if state.no_hosting then
                widgets.rc_results.content.text = localize("scan_none_hosting")
            else
                widgets.rc_results.content.text = table_concat(state.scan_lines, "\n")
            end
        end

        local error_widget = widgets.error_text
        if error_widget and state.busy then
            error_widget.content.text = state.status
        elseif error_widget and state.status and state.status ~= "" then
            local existing = error_widget.content.text or ""
            if existing == "" or self._rc_last_status == existing then
                error_widget.content.text = state.status
                self._rc_last_status = state.status
            end
        end
    end

    mod:hook_safe(VIEW_CLASS, "update", tick)

    log("join: the Realms join-view patch is installed, its section appears once that view opens")

    return { view_name = VIEW_NAME, tick = tick }
end

return M
