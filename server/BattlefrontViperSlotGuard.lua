-- Server GUI hook for the one reserved campaign slot. The companion credential
-- is independent; this hook uses only the identity authenticated by DCS net.
local missionName = "battlefront_caucasus.miz"
local slotName = "BLUE_VIPER_DEMO_1"
local slotUnitId = 1404
local pilotFile = "C:/DCS_configs/DCS.server1/Scripts/BattlefrontViperPilot.ucid"

local function protectedCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function slotId(value)
    if type(value) == "number" then
        if value > 0 and value % 1 == 0 then return value end
        return nil
    end
    if type(value) ~= "string" then return nil end
    -- DCS documents the underscore seat separator; existing server hooks also
    -- receive a hyphen separator. This Viper is authored as a single-seater.
    return tonumber(value:match("^(%d+)$") or value:match("^(%d+)[_%-]%d+$"))
end

local function reservedSlot(value)
    local id = slotId(value)
    if not id then return false end
    if id == slotUnitId then
        local filename = protectedCall(DCS.getMissionFilename)
        if type(filename) ~= "string" or filename == "" then return true end
        local basename = filename:gsub("\\", "/"):match("([^/]+)$")
        if not basename or basename:lower() == missionName then return true end
    end
    -- Exact mission-authored names also protect the slot in a renamed mission
    -- or if a future build changes unit IDs. All other groups are untouched.
    return (DCS.UNIT_NAME ~= nil and protectedCall(DCS.getUnitProperty, id, DCS.UNIT_NAME) == slotName)
        or (DCS.UNIT_GROUPNAME ~= nil and protectedCall(DCS.getUnitProperty, id, DCS.UNIT_GROUPNAME) == slotName)
end

local function readApprovedPilot()
    -- Read at most 34 bytes so extra data, CRLF, and missing LF all fail closed.
    local file = io.open(pilotFile, "rb")
    if not file then return nil end
    local readOk, value = pcall(file.read, file, 34)
    local closeOk, closed, closeError = pcall(file.close, file)
    if not closeOk or closed == false or closeError ~= nil or not readOk
        or type(value) ~= "string" or #value ~= 33 then
        return nil
    end
    return value:match("^(%x+)\n$")
end

local function isApproved(playerId, side)
    if side ~= 2 and side ~= "2" then return false end
    local expected = protectedCall(readApprovedPilot)
    if not expected then return false end
    local actual = protectedCall(net.get_player_info, playerId, "ucid")
    return type(actual) == "string" and actual:lower() == expected:lower()
end

local guard = {}
local clearingSeat = false
function guard.onPlayerTryChangeSlot(playerId, side, slot)
    if reservedSlot(slot) and not isApproved(playerId, side) then
        return false
    end
    -- A nil result leaves downstream DCS callbacks free to apply their rules.
end

function guard.onPlayerChangeSlot(playerId)
    -- Backstop if another server hook forcibly assigned the reserved slot or
    -- returned a terminating allow before the try-change guard ran.
    if clearingSeat then return end
    local slot = protectedCall(net.get_player_info, playerId, "slot")
    if reservedSlot(slot) then
        local side = protectedCall(net.get_player_info, playerId, "side")
        if not isApproved(playerId, side) then
            clearingSeat = true
            protectedCall(net.force_player_slot, playerId, 0, "")
            clearingSeat = false
        end
    end
end

DCS.setUserCallbacks(guard)
