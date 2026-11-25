-- Dedicated DCS GUI hook. Install in the server's Saved Games/Scripts/Hooks.
-- Pre-create Scripts/BattlefrontAccountLink as a private spool for this one
-- hook writer and the trusted local consumer. Do not serve it over HTTP.
local MISSION = "battlefront_caucasus.miz"
local MAX_PENDING, MAX_DISK, MAX_PLAYERS = 32, 128, 256
local MAX_QUEUE_AGE, PER_PILOT_DELAY = 20, 5
local RATE, BURST = 4, 12
local pending, queuedCodes, pilotNext = {}, {}, {}
local pilotCount, tokens, lastRefill = 0, BURST, nil

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
end

local function currentTime()
    local t = call(DCS.getRealTime)
    if type(t) == "number" and t >= 0 and t < math.huge then return t end
end

local function isCampaignServer()
    if call(DCS.isServer) ~= true or call(DCS.isMultiplayer) ~= true then return false end
    if call(DCS.isTrackPlaying) == true then return false end
    local path = call(DCS.getMissionFilename)
    if type(path) ~= "string" then return false end
    local name = path:gsub("\\", "/"):match("([^/]+)$")
    return name ~= nil and name:lower() == MISSION
end

local function isOccupied(slot)
    -- The stock GUI can report string slots (including dynamic/multicrew IDs)
    -- or a positive numeric slot. Empty slot and spectator are separate checks.
    if type(slot) == "number" then return slot > 0 and slot % 1 == 0 end
    return type(slot) == "string" and #slot <= 255 and slot ~= "0" and slot:match("%S") ~= nil
end

local function nativePlayer(playerId)
    if type(playerId) ~= "number" or playerId <= 0 or playerId % 1 ~= 0 then return nil end
    local info = call(net and net.get_player_info, playerId)
    if type(info) ~= "table" or info.id ~= playerId or not isOccupied(info.slot) then return nil end
    local side = info.side
    if side == "1" then side = 1 end
    if side == "2" then side = 2 end
    if side ~= 1 and side ~= 2 then return nil end
    local ucid = info.ucid
    if type(ucid) ~= "string" or #ucid ~= 32 or not ucid:match("^[0-9A-Fa-f]+$") then return nil end
    return ucid:lower(), side
end

local function allow(ucid, t)
    if lastRefill and t < lastRefill then return false end
    if lastRefill then tokens = math.min(BURST, tokens + (t - lastRefill) * RATE) end
    lastRefill = t
    if tokens < 1 or (pilotNext[ucid] and pilotNext[ucid] > t) then return false end
    if not pilotNext[ucid] and pilotCount >= MAX_PLAYERS then
        for pilot, nextTime in pairs(pilotNext) do
            if nextTime <= t then
                pilotNext[pilot] = nil
                pilotCount = pilotCount - 1
            end
        end
        if pilotCount >= MAX_PLAYERS then return false end
    end
    if not pilotNext[ucid] then pilotCount = pilotCount + 1 end
    pilotNext[ucid] = t + PER_PILOT_DELAY
    tokens = tokens - 1
    return true
end

local function spoolDirectory()
    local base = call(lfs and lfs.writedir)
    if type(base) ~= "string" or base == "" then return nil end
    return base:gsub("\\", "/"):gsub("/*$", "") .. "/Scripts/BattlefrontAccountLink/"
end

local function canPublish(directory, name, temporary)
    -- A bounded successful listing proves absence. A permission error or unknown
    -- directory state must not be interpreted as an absent destination.
    local count = 0
    local wanted, scratch = name:upper(), temporary:upper()
    local iterator, handle = lfs.dir(directory)
    for entry in iterator, handle do
        if type(entry) ~= "string" then
            if handle then pcall(function() handle:close() end) end
            return false
        end
        if entry ~= "." and entry ~= ".." then
            count = count + 1
            local normalized = entry:upper()
            if count >= MAX_DISK or normalized == wanted or normalized == scratch then
                if handle then pcall(function() handle:close() end) end
                return false
            end
        end
    end
    return true
end

local function fileMethod(fn, ...)
    local ok, value, why = pcall(fn, ...)
    -- DCS may wrap a successful file method as void. Exact readback below
    -- ensures that a silent write or flush failure still cannot publish.
    return ok and value ~= false and (value ~= nil or why == nil)
end

local function publish(directory, item)
    local name = item.code .. ".pair"
    local temporary = name .. ".tmp"
    if not canPublish(directory, name, temporary) then return end
    local tmp, final = directory .. temporary, directory .. name
    local line = string.format("BFPAIR1 %s %s %d\n", item.code, item.ucid, item.side)
    local f = call(io.open, tmp, "wb")
    if not f then return end
    local wrote = fileMethod(f.write, f, line)
    local flushed = wrote and fileMethod(f.flush, f)
    local closed = fileMethod(f.close, f)
    local checked = false
    if flushed and closed then
        local verify = call(io.open, tmp, "rb")
        if verify then
            local bytes = call(verify.read, verify, #line + 1)
            checked = fileMethod(verify.close, verify) and bytes == line
        end
    end
    -- The spool grants write access only to this single DCS writer and the
    -- consumer; the consumer may claim/remove .pair, never publish one here.
    -- Rename stays in the same directory: the consumer sees only complete lines.
    if checked then fileMethod(os.rename, tmp, final) end
    -- Only remove our temporary name. A failed rename must not erase a .pair.
    call(os.remove, tmp)
end

local hooks = {}
function hooks.onPlayerTrySendChat(playerId, message)
    if type(message) ~= "string" or not message:match("^%s*%-[Bb][Ff]%-[Ll][Ii][Nn][Kk]") then return end
    -- Handle every reserved-prefix attempt before broadcast. Only the exact
    -- command form is accepted; do not send the input back to chat or logging.
    if #message == 21 then
        local code = message:match("^%-[Bb][Ff]%-[Ll][Ii][Nn][Kk] ([A-Za-z2-7]+)$")
        if code and #code == 12 and #pending < MAX_PENDING and isCampaignServer() then
            code = code:upper()
            local t = currentTime()
            if t and not queuedCodes[code] then
                local ucid, side = nativePlayer(playerId)
                if ucid and allow(ucid, t) then
                    queuedCodes[code] = true
                    pending[#pending + 1] = {code = code, ucid = ucid, side = side, time = t}
                end
            end
        end
    end
    return "" -- Eagle Dynamics Sim_ControlAPI: empty string drops the message.
end

local function clearQueue()
    pending, queuedCodes = {}, {}
end

function hooks.onMissionLoadBegin() clearQueue() end
function hooks.onSimulationStop() clearQueue() end

function hooks.onSimulationFrame()
    if #pending == 0 then return end
    if not isCampaignServer() then clearQueue(); return end
    local t = currentTime()
    if not t then return end
    local directory = spoolDirectory()
    if not directory then return end
    -- Small fixed work per frame; no disk I/O in the network chat callback.
    for _ = 1, 2 do
        if #pending == 0 then return end
        local item = table.remove(pending, 1)
        queuedCodes[item.code] = nil
        if t >= item.time and t - item.time <= MAX_QUEUE_AGE then pcall(publish, directory, item) end
    end
end

DCS.setUserCallbacks(hooks)
