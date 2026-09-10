--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-02
--]]

local type = type
local tostring = tostring

local UIWidget = require("scripts/managers/ui/ui_widget")
local UIFontSettings = require("scripts/managers/ui/ui_font_settings")
local UISoundEvents = require("scripts/settings/ui/ui_sound_events")

local M = {}

local VIEW_CLASS = "RealmsPreparationView"
local VIEW_NAME = "realms_preparation_view"

M.VIEW_NAME = VIEW_NAME

local PANEL_INSET = 20
local TAB_WIDTH = 168
local TAB_HEIGHT = 32
local TAB_GAP = 8
local RESERVED = 192
local ACTION_BUTTON_NODE = "action_button"
local ACTION_BUTTON_GAP = 12
local ACTION_BUTTON_FALLBACK = 96

local TAB_Y = PANEL_INSET
local CODE_Y = TAB_Y + TAB_HEIGHT + 12
local CODE_HEIGHT = 26
local NOTICE_Y = CODE_Y + CODE_HEIGHT + 4
local NOTICE_HEIGHT = 66
local BROADCAST_Y = NOTICE_Y + NOTICE_HEIGHT + 8
local BROADCAST_HEIGHT = 34
local CONTENT_WIDTH = 360

local WIDGET_NAMES = {
    "rc_tab_mission",
    "rc_tab_requests",
    "rc_own_code",
    "rc_notice",
    "rc_broadcast",
}

M.RESERVED = RESERVED
M.ACTION_BUTTON_GAP = ACTION_BUTTON_GAP
M.ACTION_BUTTON_FALLBACK = ACTION_BUTTON_FALLBACK

function M.action_button_reserve(view)
    local node = view and view._ui_scenegraph and view._ui_scenegraph[ACTION_BUTTON_NODE]

    if type(node) ~= "table" or type(node.size) ~= "table" then
        return ACTION_BUTTON_FALLBACK
    end

    local height = node.size[2]
    if type(height) ~= "number" then
        return ACTION_BUTTON_FALLBACK
    end

    local margin = 0
    local position = node.local_position or node.position
    if type(position) == "table" and type(position[2]) == "number" then
        margin = position[2]
        if margin < 0 then
            margin = -margin
        end
    end

    return height + margin + ACTION_BUTTON_GAP
end
M.PANEL_INSET = PANEL_INSET
M.CONTENT_WIDTH = CONTENT_WIDTH
M.NOTICE_HEIGHT = NOTICE_HEIGHT

M.LAYOUT = {
    { name = "rc_tab_mission", y = TAB_Y, height = TAB_HEIGHT, row = 1 },
    { name = "rc_tab_requests", y = TAB_Y, height = TAB_HEIGHT, row = 1 },
    { name = "rc_own_code", y = CODE_Y, height = CODE_HEIGHT, row = 2 },
    { name = "rc_notice", y = NOTICE_Y, height = NOTICE_HEIGHT, row = 3 },
    { name = "rc_broadcast", y = BROADCAST_Y, height = BROADCAST_HEIGHT, row = 4 },
}

local function rgba(c)
    return { c[1], c[2], c[3], c[4] }
end

function M.button_widget(name, style_module, log, x, y, width, height, font)
    local bg = style_module.color("control_background", log)
    local bg_on = style_module.color("control_background_selected", log)
    local frame = style_module.color("control_frame", log)
    local frame_on = style_module.color("control_frame_hover", log)
    local body = style_module.color("body_text", log)
    local header = style_module.color("header_text", log)

    return UIWidget.create_definition({
        {
            content_id = "hotspot",
            pass_type = "hotspot",
            content = { on_hover_sound = UISoundEvents.default_mouse_hover },
            style = { offset = { x, y, 9 }, size = { width, height } },
        },
        {
            pass_type = "rect",
            style_id = "background",
            style = {
                color = rgba(bg),
                offset = { x, y, 10 },
                size = { width, height },
            },
            change_function = function(content, style)
                local target = (content.selected or content.hotspot.is_hover) and bg_on or bg
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
                offset = { x, y, 11 },
                size = { width, height },
            },
            change_function = function(content, style)
                local target = (content.selected or content.hotspot.is_hover) and frame_on or frame
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
                font_size = font or 20,
                font_type = "proxima_nova_bold",
                text_horizontal_alignment = "center",
                text_vertical_alignment = "center",
                text_color = rgba(body),
                offset = { x, y, 12 },
                size = { width, height },
            },
            change_function = function(content, style)
                local colour = style.text_color
                if not colour then
                    return
                end
                local target = content.hotspot.disabled and body or
                    ((content.selected or content.hotspot.is_hover) and header or body)
                for i = 1, 4 do
                    colour[i] = target[i]
                end
            end,
        },
    }, "info_panel", { text = "", selected = false, hotspot = {} })
end

function M.text_widget(style_module, log, colour_name, x, y, width, height, font_name, wrap)
    local colour = style_module.color(colour_name, log)
    local style = table.clone(UIFontSettings[font_name])

    style.text_horizontal_alignment = "left"
    style.text_vertical_alignment = "top"
    style.text_color = rgba(colour)
    style.offset = { x, y, 10 }
    style.size = { width, height }
    style.word_wrap = wrap == true

    return UIWidget.create_definition({
        {
            content_id = "hotspot",
            pass_type = "hotspot",
            content = { on_hover_sound = UISoundEvents.default_mouse_hover },
            style = { offset = { x, y, 9 }, size = { width, height } },
        },
        {
            pass_type = "text",
            style_id = "text",
            value_id = "text",
            value = "",
            style = style,
        },
    }, "info_panel", { text = "", hotspot = {} })
end

function M.install(deps)
    local mod = deps.mod
    local panel_module = deps.panel_module
    local patch = deps.patch
    local style_module = deps.style_module
    local make_panel = deps.make_panel
    local log = deps.log
    local localize = deps.localize
    local mission_row_count = deps.mission_row_count or function() return 1 end
    local present_content
    local set_scrollbar_hidden
    local realms_present_mission_rows

    local rc_wrappers = setmetatable({}, { __mode = "k" })

    local function ensure_class_patch()
        if realms_present_mission_rows then
            return
        end

        local class = rawget(_G, VIEW_CLASS)
        if type(class) ~= "table" or type(class._present_mission_rows) ~= "function" then
            return
        end

        if rc_wrappers[class._present_mission_rows] then
            return
        end

        local original = class._present_mission_rows
        realms_present_mission_rows = original

        local wrapper = function(self, force)
            if self._rc_panel and self._info_grid
                and (self._rc_tab == patch.TAB_REQUESTS or self._rc_empty_mission_signature) then
                return
            end
            return original(self, force)
        end

        rc_wrappers[wrapper] = true
        class._present_mission_rows = wrapper

        log("lobby: took over _present_mission_rows so Realms' periodic refresh cannot overwrite the requests tab")
    end

    local function definitions_for(view)
        return {
            rc_tab_mission = M.button_widget("rc_tab_mission", style_module, log,
                PANEL_INSET, TAB_Y, TAB_WIDTH, TAB_HEIGHT),
            rc_tab_requests = M.button_widget("rc_tab_requests", style_module, log,
                PANEL_INSET + TAB_WIDTH + TAB_GAP, TAB_Y, TAB_WIDTH, TAB_HEIGHT),
            rc_own_code = M.text_widget(style_module, log, "body_text",
                PANEL_INSET, CODE_Y, CONTENT_WIDTH, CODE_HEIGHT, "header_4"),
            rc_notice = M.text_widget(style_module, log, "secondary_text",
                PANEL_INSET, NOTICE_Y, CONTENT_WIDTH, NOTICE_HEIGHT, "body_small", true),
            rc_broadcast = M.button_widget("rc_broadcast", style_module, log,
                PANEL_INSET, BROADCAST_Y, CONTENT_WIDTH, BROADCAST_HEIGHT, 20),
        }
    end

    local function ensure_grid_geometry(self)
        local grid = self._info_grid

        if not grid or self._rc_grid_adjusted == grid then
            return
        end

        if type(grid.update_grid_height) ~= "function" or type(grid.set_pivot_offset) ~= "function" then
            self._rc_grid_adjusted = grid
            return
        end

        local settings = grid._menu_settings
        if type(settings) ~= "table" or type(settings.grid_size) ~= "table" then
            self._rc_grid_adjusted = grid
            return
        end

        settings.grid_size = { settings.grid_size[1], settings.grid_size[2] }
        if type(settings.mask_size) == "table" then
            settings.mask_size = { settings.mask_size[1], settings.mask_size[2] }
        end

        local original = self._rc_grid_original_height
        if not original then
            original = settings.grid_size[2]
            self._rc_grid_original_height = original
        end

        local height = original - RESERVED - M.action_button_reserve(self)
        if height < 120 then
            height = 120
        end

        grid:update_grid_height(height, height)

        if self._rc_panel and type(self._rc_panel.set_max_rows) == "function" then
            local fits = math.floor(height / patch.ROW_HEIGHT)
            if fits < 1 then
                fits = 1
            end
            self._rc_panel.set_max_rows(fits)
        end

        local offset = grid._pivot_offset
        if type(offset) == "table" then
            local base = self._rc_grid_original_pivot
            if not base then
                base = offset[2]
                self._rc_grid_original_pivot = base
            end
            grid:set_pivot_offset(offset[1], base + RESERVED)
        end

        self._rc_grid_adjusted = grid

        log("lobby: the mission grid was shortened to " .. tostring(height) ..
            " and moved down " .. tostring(RESERVED) .. " to make room for the tabs")
    end

    local function ensure_widgets(self)
        if self._rc_panel and self._widgets_by_name.rc_tab_requests
            and self._rc_drawn_into == self._widgets then
            return
        end

        self._rc_drawn_into = self._widgets
        self._rc_panel = self._rc_panel or make_panel()
        self._rc_tab = self._rc_tab or patch.TAB_MISSION
        self._rc_signature = nil
        self._rc_blueprints = nil

        local definitions = definitions_for(self)

        for i = 1, #WIDGET_NAMES do
            local name = WIDGET_NAMES[i]
            local widget = self:_create_widget(name, definitions[name])
            self._widgets[#self._widgets + 1] = widget
        end

        local widgets = self._widgets_by_name

        widgets.rc_tab_mission.content.hotspot.pressed_callback = function()
            self._rc_tab = patch.TAB_MISSION
            self._rc_signature = nil
            self._rc_empty_mission_signature = nil
            self._mission_rows_signature = nil
            self._rc_relayout = true
        end

        widgets.rc_tab_requests.content.hotspot.pressed_callback = function()
            self._rc_tab = patch.TAB_REQUESTS
            self._rc_signature = nil
            self._rc_empty_mission_signature = nil
            self._mission_rows_signature = nil
            self._rc_relayout = true
        end

        widgets.rc_broadcast.content.hotspot.pressed_callback = function()
            self._rc_panel.toggle_broadcast()
        end

        widgets.rc_own_code.content.hotspot.pressed_callback = function()
            self._rc_panel.copy_code()
        end

        widgets.rc_notice.content.hotspot.pressed_callback = function()
            self._rc_panel.copy_address()
        end

        log("lobby: the Realms Connect tab was added to the lobby panel")
    end

    mod:hook_safe(VIEW_CLASS, "on_enter", ensure_widgets)

    mod:hook_safe(VIEW_CLASS, "on_exit", function(self)
        if self._rc_panel then
            self._rc_panel.reset()
        end
        set_scrollbar_hidden(self, false)
        self._rc_panel = nil
        self._rc_blueprints = nil
    end)

    set_scrollbar_hidden = function(self, hidden)
        local grid = self._info_grid
        if not grid or type(grid.grid_scrollbar) ~= "function" then
            return
        end

        local widget = grid:grid_scrollbar()
        if type(widget) ~= "table" then
            return
        end

        if self._rc_scrollbar_was == nil then
            self._rc_scrollbar_was = widget.visible ~= false
        end

        if hidden then
            widget.visible = false
        else
            widget.visible = self._rc_scrollbar_was
        end
    end

    local OUR_WIDGET_TYPES = {
        realms_connect_request = true,
        realms_connect_message = true,
    }

    local function grid_holds_our_content(self, expected)
        local grid = self._info_grid
        if not grid or type(grid.widgets) ~= "function" then
            return true
        end

        local ok, widgets = pcall(grid.widgets, grid)
        if not ok or type(widgets) ~= "table" then
            return true
        end

        if type(expected) == "number" and #widgets ~= expected then
            return false
        end

        for i = 1, #widgets do
            local widget = widgets[i]
            local kind = widget and widget.type
            if kind == nil and widget and widget.content and widget.content.element then
                kind = widget.content.element.widget_type
            end
            if kind ~= nil and not OUR_WIDGET_TYPES[kind] then
                return false
            end
        end

        return true
    end

    M.grid_holds_our_content = grid_holds_our_content

    local function blueprints_for(self)
        if not self._rc_blueprints then
            self._rc_blueprints = {
                realms_connect_request = patch.request_blueprint(style_module, log),
                realms_connect_message = patch.message_blueprint(style_module, log),
            }
        end
        return self._rc_blueprints
    end

    present_content = function(self, force)
        if not self._rc_panel or not self._info_grid then
            return
        end

        if self._rc_tab ~= patch.TAB_REQUESTS then
            self._rc_signature = nil
            set_scrollbar_hidden(self, false)

            if mission_row_count() == 0 then
                local layout = patch.message_layout(localize("lobby_mission_no_details"))
                local signature = patch.layout_signature(layout)

                if not force and signature == self._rc_empty_mission_signature then
                    return
                end

                self._rc_empty_mission_signature = signature
                self._mission_rows_signature = nil
                self._info_grid:present_grid_layout(layout, blueprints_for(self))
                self._info_grid:set_handle_grid_navigation(true)
                return
            end

            if self._rc_empty_mission_signature then
                self._rc_empty_mission_signature = nil
                self._mission_rows_signature = nil
                force = true
            end

            if realms_present_mission_rows then
                realms_present_mission_rows(self, force)
            else
                self:_present_mission_rows(force)
            end
            return
        end

        self._rc_empty_mission_signature = nil
        set_scrollbar_hidden(self, true)

        local state = self._rc_panel.state()
        local layout

        if #state.rows > 0 then
            layout = patch.rows_to_layout(state.rows, {
                accept = localize("lobby_accept"),
                deny = localize("lobby_deny"),
            }, function(nonce)
                self._rc_panel.accept(nonce)
                self._rc_signature = nil
                self._rc_relayout = true
            end, function(nonce)
                self._rc_panel.decline(nonce)
                self._rc_signature = nil
                self._rc_relayout = true
            end)
        else
            layout = patch.message_layout(state.empty_text or "")
        end

        local signature = patch.layout_signature(layout)
        if not force and signature == self._rc_signature
            and grid_holds_our_content(self, #layout) then
            return
        end
        self._rc_signature = signature
        self._mission_rows_signature = nil

        self._info_grid:present_grid_layout(layout, blueprints_for(self))
        self._info_grid:set_handle_grid_navigation(true)
    end

    local function refresh_countdowns(self, rows)
        local grid = self._info_grid
        if not grid or type(grid.widgets) ~= "function" or #rows == 0 then
            return
        end

        local widgets = grid:widgets()
        if type(widgets) ~= "table" then
            return
        end

        local by_nonce = {}
        for i = 1, #rows do
            by_nonce[rows[i].nonce] = rows[i].countdown or ""
        end

        for i = 1, #widgets do
            local content = widgets[i].content
            local element = content and content.element
            local countdown = element and element.nonce and by_nonce[element.nonce]

            if countdown then
                content.countdown = countdown
            end
        end
    end

    local function tick(self)
        if self.closing_view then
            return
        end

        ensure_class_patch()
        ensure_widgets(self)
        ensure_grid_geometry(self)

        local panel = self._rc_panel
        if not panel then
            return
        end

        local state = panel.state()
        local widgets = self._widgets_by_name

        local mission_tab = widgets.rc_tab_mission
        local requests_tab = widgets.rc_tab_requests

        mission_tab.content.text = localize("lobby_tab_mission")
        mission_tab.content.selected = self._rc_tab == patch.TAB_MISSION

        local label = state.tab_label
        if state.badge > 0 then
            label = label .. " (" .. tostring(state.badge) .. ")"
        end
        requests_tab.content.text = label
        requests_tab.content.selected = self._rc_tab == patch.TAB_REQUESTS

        local code = widgets.rc_own_code
        code.visible = state.hosting
        code.content.text = state.own_code_line or ""
        code.content.hotspot.disabled = not state.own_code_copyable

        local notice = widgets.rc_notice
        local notice_text = state.notice or ""

        if state.overflow and state.overflow > 0 then
            notice_text = localize("lobby_more_waiting") .. " " .. tostring(state.overflow)
        end

        notice.content.text = notice_text

        local broadcast = widgets.rc_broadcast
        broadcast.visible = state.broadcast_available
        broadcast.content.text = state.broadcast_label or ""
        broadcast.content.selected = state.broadcast_active
        broadcast.content.hotspot.disabled = not state.broadcast_available

        local forced = self._rc_relayout == true
        self._rc_relayout = nil
        present_content(self, forced)

        if self._rc_tab == patch.TAB_REQUESTS then
            refresh_countdowns(self, state.rows)
        end
    end

    mod:hook_safe(VIEW_CLASS, "update", tick)

    log("lobby: the Realms lobby patch is installed, its widgets appear once the lobby opens")

    return { view_name = VIEW_NAME, tick = tick }
end

return M
