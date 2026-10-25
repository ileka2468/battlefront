-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - CORE INITIALIZATION & LOGGING
-- ==============================================================================
_G.Battlefront = _G.Battlefront or {}
local BF = _G.Battlefront

-- Global alias for convenience across modules
_G.BF = Battlefront

-- Coalition side constants
BF.SIDE_NEUTRAL = 0
BF.SIDE_RED     = 1
BF.SIDE_BLUE    = 2
BF.SIDE_ALL     = -1

-- Unified Logging
function BF.Log(msg)
    local timestamp = timer and timer.getTime() or 0
    env.info(string.format("[BATTLEFRONT T+%.1f] %s", timestamp, tostring(msg)))
end

-- Global Broadcast
function BF.Broadcast(msg, side, duration)
    local dur = duration or 12
    if not trigger or not trigger.action then return end
    if not side or side == BF.SIDE_ALL then
        trigger.action.outText(tostring(msg), dur)
    else
        trigger.action.outTextForCoalition(side, tostring(msg), dur)
    end
end

-- Currency Formatter ($M)
function BF.FormatMoney(amount)
    return string.format("$%.1fM", tonumber(amount) or 0)
end
