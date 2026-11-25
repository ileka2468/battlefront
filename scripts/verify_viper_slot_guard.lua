-- Lua 5.1 fixture for the dedicated GUI hook. No private data or network calls.
local path = arg[1] or "server/BattlefrontViperSlotGuard.lua"
local configPath = "C:/DCS_configs/DCS.server1/Scripts/BattlefrontViperPilot.ucid"
local approved = string.rep("a", 32)
local unknown = string.rep("b", 32)
local state = {mission = "C:\\DCS_configs\\DCS.server1\\Missions\\Battlefront_Caucasus.miz",
    ucid = approved, config = approved .. "\n", side = 2, slot = "1404", opened = 0,
    closed = 0, forceCount = 0}

local callbacks
local fixture = {
    type = type, pcall = pcall, tonumber = tonumber,
    DCS = {
        UNIT_NAME = 1, UNIT_GROUPNAME = 2,
        getMissionFilename = function()
            if state.filenameError then error("fixture filename API failed") end
            return state.mission
        end,
        getUnitProperty = function(id, attr)
            assert(type(id) == "number" and (attr == 1 or attr == 2))
            if id == state.aliasId and attr == state.aliasAttr then return "BLUE_VIPER_DEMO_1" end
        end,
        setUserCallbacks = function(value)
            assert(callbacks == nil)
            callbacks = value
        end,
    },
    io = {open = function(file, mode)
        assert(file == configPath and mode == "rb")
        state.opened = state.opened + 1
        if state.openError then error("fixture open error") end
        if not state.config then return nil end
        return {
            read = function(_, count)
                assert(count == 34)
                if state.readError then error("fixture read error") end
                return state.config:sub(1, count)
            end,
            close = function()
                state.closed = state.closed + 1
                if state.closeError then error("fixture close error") end
                if state.closeFailure then return nil, "fixture close failure" end
                if state.closeVoid then return end
                return true
            end,
        }
    end},
    net = {
        get_player_info = function(id, attr)
            assert(id == 77 and (attr == "ucid" or attr == "slot" or attr == "side"))
            if state.identityError and attr == "ucid" then error("fixture identity API failed") end
            return state[attr]
        end,
        force_player_slot = function(id, side, slot)
            assert(id == 77 and side == 0 and slot == "")
            state.forceCount = state.forceCount + 1
            assert(state.forceCount <= 2, "post-slot guard re-entered the force callback")
            callbacks.onPlayerChangeSlot(id) -- re-entrant callback should not try again
        end,
    },
}

local chunk = assert(loadfile(path))
setfenv(chunk, fixture)
chunk()
assert(type(callbacks.onPlayerTryChangeSlot) == "function")
assert(type(callbacks.onPlayerChangeSlot) == "function")

local function change(side, slot) return callbacks.onPlayerTryChangeSlot(77, side, slot) end
local downstream = 0
local function chain(side, slot)
    local decision = change(side, slot)
    if decision ~= nil then return decision end
    downstream = downstream + 1
    return false -- representative later stock policy
end

assert(change(2, 1404) == nil and change("2", "1404") == nil)
assert(chain(2, "1404") == false and downstream == 1, "approved pilot bypassed later policy")
assert(change(1, "1404") == false and change(0, "1404") == false)
state.ucid = unknown
assert(chain(2, "1404_1") == false and downstream == 1)
assert(change(2, "1404-1") == false and change(2, "01404") == false)
local priorOpens = state.opened
assert(change(1, "1402") == nil and change(2, "1405") == nil and change(0, "") == nil)
state.mission = "/DCS/Missions/Other_Campaign.miz"
assert(change(2, "1404") == nil and state.opened == priorOpens)
state.aliasId, state.aliasAttr = 2030, 2
assert(change(2, "2030") == false, "renamed mission escaped exact group reservation")
state.aliasId, state.aliasAttr = 2031, 1
assert(change(2, "2031") == false, "renamed group escaped exact unit reservation")
state.mission, state.aliasId = nil, nil
assert(change(2, "1404") == false and change(2, "1405") == nil)
state.filenameError = true
assert(change(2, "1404") == false)
state.filenameError = false
state.mission = "Battlefront_Caucasus.miz"
state.ucid = approved

for _, malformed in ipairs({"", approved, approved .. "\r\n", approved .. "\n\n",
        approved .. "\nX", approved .. "1\n", approved:sub(2) .. "\n", string.rep("z", 32) .. "\n"}) do
    state.config = malformed
    assert(change(2, "1404") == false)
end
state.config = nil
assert(change(2, "1404") == false)
state.config = approved:upper() .. "\n"
assert(change(2, "1404") == nil, "hex casing changed the identity")
state.config = approved .. "\n"
state.closeVoid = true
assert(change(2, "1404") == nil, "native void/no-error close was rejected")
state.closeVoid = false
for _, failure in ipairs({"openError", "readError", "closeError", "closeFailure", "identityError"}) do
    state[failure] = true
    assert(change(2, "1404") == false)
    state[failure] = false
end
state.ucid = nil
assert(change(2, "1404") == false)

callbacks.onPlayerChangeSlot(77)
assert(state.forceCount == 1)
state.ucid, state.side = approved, 1
callbacks.onPlayerChangeSlot(77)
assert(state.forceCount == 2)
state.ucid, state.side = approved, 2
callbacks.onPlayerChangeSlot(77)
state.slot, state.ucid = "1402", unknown
callbacks.onPlayerChangeSlot(77)
state.slot = ""
callbacks.onPlayerChangeSlot(77)
assert(state.forceCount == 2 and state.closed > 0)
print("PASS: fixed campaign Viper authorization, downstream callback preservation, deterministic fail-closed file/native checks, and exact-seat backstop")
