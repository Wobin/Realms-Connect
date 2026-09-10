--[[
    Name: Realms Connect
    Author: Wobin
    Date: 2026-09-04
--]]

local type = type
local pairs = pairs
local ipairs = ipairs
local string_format = string.format
local bit = rawget(_G, "bit") or require("bit")
local bxor = bit.bxor

local M = {}

M.WIDTH = 6

local FNV_OFFSET = 2166136261
local FNV_PRIME = 16777619
local WRAP = 4294967296
local MASK = 16777216

function M.hash(id)
    if type(id) ~= "string" or id == "" then
        return nil
    end

    local h = FNV_OFFSET
    for i = 1, #id do
        h = bxor(h, id:byte(i))
        h = h * FNV_PRIME % WRAP
    end

    return string_format("%06x", h % MASK)
end

function M.index(ids)
    local out = {}

    if type(ids) ~= "table" then
        return out
    end

    for i = 1, #ids do
        local h = M.hash(ids[i])
        if h then
            out[h] = ids[i]
        end
    end

    for key in pairs(ids) do
        local h = M.hash(key)
        if h then
            out[h] = key
        end
    end

    return out
end

function M.resolve(hash, index)
    if type(hash) ~= "string" or type(index) ~= "table" then
        return nil
    end

    return index[hash]
end

function M.hash_all(ids)
    local out = {}

    if type(ids) ~= "table" then
        return out
    end

    for _, id in ipairs(ids) do
        local h = M.hash(id)
        if h then
            out[#out + 1] = h
        end
    end

    return out
end

return M
