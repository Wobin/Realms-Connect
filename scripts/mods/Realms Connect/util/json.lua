local table_concat = table.concat
local table_sort = table.sort
local string_format = string.format
local string_gsub = string.gsub
local math_floor = math.floor
local math_huge = math.huge
local type = type
local pairs = pairs
local tostring = tostring
local getmetatable = getmetatable
local setmetatable = setmetatable

local M = {}

M.array_mt = {}

function M.as_array(t)
    t = t or {}
    return setmetatable(t, M.array_mt)
end

local ESCAPES = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function escape_char(c)
    local e = ESCAPES[c]
    if e then
        return e
    end
    return string_format("\\u%04x", c:byte())
end

local function encode_string(s)
    return '"' .. string_gsub(s, '[%z\1-\31\\"]', escape_char) .. '"'
end

local function encode_number(n)
    if n ~= n or n == math_huge or n == -math_huge then
        return nil, "cannot encode nan or inf"
    end
    if n == math_floor(n) then
        return string_format("%d", n)
    end
    return string_format("%.14g", n)
end

local encode_value

local function encode_table(t, seen)
    if seen[t] then
        return nil, "cycle detected"
    end
    seen[t] = true

    local n = #t

    if n > 0 or getmetatable(t) == M.array_mt then
        local out = {}
        for i = 1, n do
            local v, err = encode_value(t[i], seen)
            if not v then
                seen[t] = nil
                return nil, err
            end
            out[i] = v
        end
        seen[t] = nil
        return "[" .. table_concat(out, ",") .. "]"
    end

    local keys = {}
    for k in pairs(t) do
        local kt = type(k)
        if kt ~= "string" and kt ~= "number" then
            seen[t] = nil
            return nil, "unsupported key type: " .. kt
        end
        keys[#keys + 1] = k
    end

    table_sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    local out = {}
    for i = 1, #keys do
        local k = keys[i]
        local v, err = encode_value(t[k], seen)
        if not v then
            seen[t] = nil
            return nil, err
        end
        out[i] = encode_string(tostring(k)) .. ":" .. v
    end

    seen[t] = nil
    return "{" .. table_concat(out, ",") .. "}"
end

encode_value = function(v, seen)
    local t = type(v)
    if t == "string" then
        return encode_string(v)
    end
    if t == "number" then
        return encode_number(v)
    end
    if t == "boolean" then
        return v and "true" or "false"
    end
    if t == "table" then
        return encode_table(v, seen)
    end
    return nil, "unsupported type: " .. t
end

function M.encode(value)
    return encode_value(value, {})
end

function M.strip_null(t, seen)
    seen = seen or {}
    if seen[t] then
        return
    end
    seen[t] = true

    local n = #t
    if n > 0 then
        local out = {}
        local out_n = 0
        for i = 1, n do
            local v = t[i]
            if type(v) ~= "userdata" then
                if type(v) == "table" then
                    M.strip_null(v, seen)
                end
                out_n = out_n + 1
                out[out_n] = v
            end
        end
        for i = 1, n do
            t[i] = out[i]
        end
        return
    end

    for k, v in pairs(t) do
        if type(v) == "userdata" then
            t[k] = nil
        elseif type(v) == "table" then
            M.strip_null(v, seen)
        end
    end
end

return M
