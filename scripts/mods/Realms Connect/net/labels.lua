--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-04
--]]

local type = type
local pcall = pcall

local M = {}

local DEFAULT_CIRCUMSTANCE = "default"

local function noop() end

local function called(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, ...)
    if not ok then
        return nil
    end
    return value
end

local function usable(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

function M.new(deps)
    deps = deps or {}

    local idhash = deps.idhash
    local mission_templates = deps.mission_templates
    local circumstance_templates = deps.circumstance_templates
    local circumstance_index = deps.circumstance_index
    local localize_key = deps.localize_key or noop
    local parse_havoc = deps.parse_havoc

    local l = {}

    function l.mission_label(mission_id)
        if not usable(mission_id) then
            return nil
        end

        local templates = called(mission_templates)
        local template = type(templates) == "table" and templates[mission_id] or nil
        if type(template) ~= "table" then
            return nil
        end

        return usable(called(localize_key, template.mission_name))
    end

    function l.circumstance_label(hash)
        if not usable(hash) then
            return hash
        end

        local index = called(circumstance_index)
        local id
        if idhash and type(idhash.resolve) == "function" then
            id = called(idhash.resolve, hash, index)
        end

        if not usable(id) then
            return hash
        end

        local templates = called(circumstance_templates)
        local template = type(templates) == "table" and templates[id] or nil
        local ui = type(template) == "table" and template.ui or nil
        if type(ui) ~= "table" then
            return id
        end

        return usable(called(localize_key, ui.display_name)) or id
    end

    function l.circumstance_labels(main_hash, modifier_hashes)
        local out = {}

        if type(main_hash) == "string" then
            out[#out + 1] = l.circumstance_label(main_hash)
        end

        if type(modifier_hashes) == "table" then
            for i = 1, #modifier_hashes do
                out[#out + 1] = l.circumstance_label(modifier_hashes[i])
            end
        end

        return out
    end

    function l.host_circumstances(data)
        if type(data) ~= "table" then
            return nil, {}
        end

        local main = usable(data.circumstance_name)
        if main == DEFAULT_CIRCUMSTANCE then
            main = nil
        end

        local extras = {}

        if type(data.havoc_data) == "string" and type(parse_havoc) == "function" then
            local parsed = called(parse_havoc, data.havoc_data)
            local listed = type(parsed) == "table" and parsed.circumstances or nil

            if type(listed) == "table" then
                for i = 1, #listed do
                    local id = usable(listed[i])
                    if id and id ~= DEFAULT_CIRCUMSTANCE and id ~= main then
                        extras[#extras + 1] = id
                    end
                end
            end
        end

        return main, extras
    end

    return l
end

return M
