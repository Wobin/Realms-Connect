local M = {}

M.HOLD = "hold"
M.FIRE = "fire"

M.REASON_SETTLED = "settled"
M.REASON_EXPIRED = "expired"
M.REASON_GATHERING = "gathering"

function M.decide(opts)
    opts = opts or {}

    if opts.status ~= "gathering" then
        return M.FIRE, M.REASON_SETTLED
    end

    if opts.expired == true then
        return M.FIRE, M.REASON_EXPIRED
    end

    return M.HOLD, M.REASON_GATHERING
end

return M
