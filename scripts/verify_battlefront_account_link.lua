-- Lua 5.1 fixture for the dedicated GUI hook. Does not touch DCS or a real spool.
local path = arg[1] or "server/BattlefrontAccountLink.lua"
local directory = "C:/DCS_configs/DCS.server1/Scripts/BattlefrontAccountLink/"
local prefix = "-bf-link "
local first = "BATTLEFRONT2"
local second = "ALLYCODE2345"
local playerA, playerB = 77, 78
local redUcid, blueUcid = string.rep("A1", 16), string.rep("b2", 16)
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

local function codeFor(n)
    local chars = {}
    for i = 1, 3 do
        local idx = n % 32 + 1
        chars[i] = alphabet:sub(idx, idx)
        n = math.floor(n / 32)
    end
    return "POSITIONX" .. table.concat(chars)
end

local function loadHook()
    local hook
    local s = { now = 10, server = true, mp = true, track = false,
        mission = "C:\\DCS_configs\\DCS.server1\\Missions\\Battlefront_Caucasus.miz",
        pilot = { [playerA] = {id = playerA, side = 1, slot = "1407", ucid = redUcid},
                  [playerB] = {id = playerB, side = "2", slot = "dynamic_spawn_1", ucid = blueUcid} },
        files = {}, renameCount = 0, openCount = 0, dirCount = 0, nativeCalls = 0,
        readClosed = 0, writeClosed = 0, dirClosed = 0 }
    local env = { type = type, pcall = pcall, pairs = pairs, table = table, string = string, math = math }
    env.DCS = {
        isServer = function() return s.server end,
        isMultiplayer = function() return s.mp end,
        isTrackPlaying = function() return s.track end,
        getMissionFilename = function() return s.mission end,
        getRealTime = function() return s.now end,
        setUserCallbacks = function(value) assert(hook == nil); hook = value end,
    }
    env.net = {
        get_player_info = function(id, key)
            assert(key == nil, "player identity and coalition must come from the same snapshot")
            s.nativeCalls = s.nativeCalls + 1
            if s.playerError then error("native identity unavailable") end
            return s.pilot[id]
        end,
        send_chat = function() error("chat must not leak that the command was sent") end,
        send_chat_to = function() error("hook should neither log nor echo command input") end,
    }
    env.lfs = {
        writedir = function() return "C:\\DCS_configs\\DCS.server1\\" end,
        dir = function(dir)
            assert(dir == directory); s.dirCount = s.dirCount + 1
            if s.listError then error("private spool unavailable") end
            local names, i = {".", ".."}, 0
            for name in pairs(s.files) do names[#names + 1] = name:sub(#dir + 1) end
            table.sort(names)
            local d = { close = function() s.dirClosed = s.dirClosed + 1 end }
            return function(h)
                assert(h == d)
                i = i + 1
                return names[i]
            end, d
        end,
        mkdir = function() error("the hook must not create a directory") end,
    }
    env.io = { open = function(file, mode)
        assert(file:sub(1, #directory) == directory and file:match("[A-Z2-7]+%.pair%.tmp$"))
        s.openCount = s.openCount + 1
        if s.openError then return nil, "fixture permission denied" end
        if mode == "wb" then
            assert(s.files[file] == nil, "do not clobber any existing temporary file")
            s.files[file] = ""
            return {
                write = function(_, line)
                    if s.writeError then return nil, "fixture write error" end
                    s.files[file] = s.truncate and line:sub(1, -3) or line
                    if not s.voidFileCalls then return true end
                end,
                flush = function()
                    if s.flushError then return nil, "fixture flush error" end
                    if not s.voidFileCalls then return true end
                end,
                close = function()
                    s.writeClosed = s.writeClosed + 1
                    if s.closeError then return nil, "fixture close error" end
                    if not s.voidFileCalls then return true end
                end,
            }
        end
        assert(mode == "rb" and s.files[file] ~= nil)
        return {
            read = function(_, n) return s.files[file]:sub(1, n) end,
            close = function()
                s.readClosed = s.readClosed + 1
                if not s.voidFileCalls then return true end
            end,
        }
    end }
    env.os = {
        rename = function(source, destination)
            assert(source == destination .. ".tmp" and s.files[destination] == nil)
            s.renameCount = s.renameCount + 1
            if s.renameError then return nil, "fixture rename error" end
            s.files[destination] = assert(s.files[source]); s.files[source] = nil
            if not s.voidFileCalls then return true end
        end,
        remove = function(temp)
            assert(temp:match("%.pair%.tmp$"), "must never remove a ready proof")
            s.files[temp] = nil
            return true
        end,
    }
    local chunk = assert(loadfile(path))
    setfenv(chunk, env); chunk()
    assert(type(hook.onPlayerTrySendChat) == "function" and type(hook.onSimulationFrame) == "function")
    return s, hook
end

local function send(hook, command, id, route)
    assert(hook.onPlayerTrySendChat(id or playerA, command, route) == "", "reserved commands must be dropped")
end
local function ready(s, code) return s.files[directory .. code .. ".pair"] end
local function count(s)
    local n = 0
    for _ in pairs(s.files) do n = n + 1 end
    return n
end

local s, hook = loadHook()
assert(hook.onPlayerTrySendChat(playerA, "regular chat", true) == nil)
assert(hook.onPlayerTrySendChat(playerA, "hello -bf-link " .. first, true) == nil)
assert(hook.onPlayerTrySendChat(playerA, false) == nil)
for _, invalid in ipairs({"-bf-link", " -bf-link " .. first, "-bf-linker", prefix .. first .. " ",
    prefix .. first:sub(1, -2), prefix .. first .. "A", prefix .. "BATTLEFRON08", prefix .. "../artifact1",
    "-bf-link\t" .. first, "-bf-link  " .. first, prefix .. first .. "\n"}) do
    send(hook, invalid)
end
assert(s.nativeCalls == 0 and s.openCount == 0 and s.dirCount == 0)
send(hook, "-bF-LiNk " .. first:lower(), playerA, true)
send(hook, prefix .. second, playerB, false)
assert(s.openCount == 0 and s.dirCount == 0 and count(s) == 0, "never perform I/O in the chat callback")
hook.onSimulationFrame()
assert(ready(s, first) == "BFPAIR1 " .. first .. " " .. redUcid:lower() .. " 1\n")
assert(ready(s, second) == "BFPAIR1 " .. second .. " " .. blueUcid .. " 2\n")
assert(s.renameCount == 2 and s.readClosed == 2 and s.writeClosed == 2 and count(s) == 2)
print("PASS: normal chat chains; reserved chat is suppressed; exact proof for native Red and Blue; atomic publication")

s, hook = loadHook()
for _, key in ipairs({"server", "mp", "track", "mission", "now"}) do
    local old = s[key]
    s[key] = ({server = false, mp = false, track = true, mission = "Other_Battlefront_Caucasus.miz", now = -1})[key]
    send(hook, prefix .. first); hook.onSimulationFrame(); assert(count(s) == 0)
    s[key] = old
end
s.playerError = true
send(hook, prefix .. first); s.playerError = false
local pilot = s.pilot[playerA]
for _, fake in ipairs({{id = 76, slot = "1407", side = 1, ucid = redUcid},
    {id = playerA, slot = "1407", side = 0, ucid = redUcid},
    {id = playerA, slot = "", side = 1, ucid = redUcid},
    {id = playerA, slot = "  ", side = 1, ucid = redUcid},
    {id = playerA, slot = 0, side = 1, ucid = redUcid},
    {id = playerA, slot = "1407", side = "blue", ucid = redUcid},
    {id = playerA, slot = "1407", side = 1, ucid = redUcid:sub(1, -2)},
    {id = playerA, slot = "1407", side = 1, ucid = string.rep("z", 32)}}) do
    s.pilot[playerA] = fake
    send(hook, prefix .. first); hook.onSimulationFrame(); assert(count(s) == 0)
end
s.pilot[playerA] = pilot
send(hook, prefix .. first, 123); hook.onSimulationFrame(); assert(count(s) == 0 and s.dirCount == 0)
print("PASS: fail closed outside Battlefront multiplayer, on a replay, for spectator, empty slot and invalid native UCID")

s, hook = loadHook()
send(hook, prefix .. first)
send(hook, prefix .. first, playerB)
send(hook, prefix .. second)
hook.onSimulationFrame()
assert(count(s) == 1 and ready(s, first):match(" 1\n$") and not ready(s, second))
s.now = 16
send(hook, prefix .. first, playerB)
hook.onSimulationFrame()
assert(count(s) == 1 and s.renameCount == 1 and s.dirClosed == 1 and ready(s, first):match(" 1\n$"))
s.now = 22
s.files[directory .. second:lower() .. ".PAIR"] = "preexisting data"
send(hook, prefix .. second, playerB)
hook.onSimulationFrame()
assert(count(s) == 2 and s.renameCount == 1, "case-insensitive target collision must not publish")
s.now = 28
send(hook, prefix .. codeFor(0))
hook.onMissionLoadBegin(); hook.onSimulationFrame()
assert(count(s) == 2, "game transition must discard queued requests")
s.now = 35
send(hook, prefix .. codeFor(0))
s.now = 56; hook.onSimulationFrame()
assert(count(s) == 2, "stale queued proof must be discarded")
s.now = 60
send(hook, prefix .. codeFor(0)); s.mission = "Other.miz"; hook.onSimulationFrame()
s.mission = "Battlefront_Caucasus.miz"; hook.onSimulationFrame()
assert(count(s) == 2 and s.renameCount == 1, "wrong current mission must clear queued requests")
print("PASS: duplicate or preexisting code not replaced; per-pilot delay; mission change and stale queue fail closed")

for _, failure in ipairs({"listError", "openError", "writeError", "flushError", "closeError", "truncate", "renameError"}) do
    s, hook = loadHook(); s[failure] = true
    send(hook, prefix .. first); hook.onSimulationFrame()
    assert(count(s) == 0, "I/O failure must leave no published proof or scratch: " .. failure)
    if failure == "writeError" or failure == "flushError" then assert(s.writeClosed == 1) end
end
s, hook = loadHook(); s.voidFileCalls = true
send(hook, prefix .. first); hook.onSimulationFrame()
assert(ready(s, first) == "BFPAIR1 " .. first .. " " .. redUcid:lower() .. " 1\n")
print("PASS: blocked spool or partial write/flush/close/rename cannot expose a proof; verified void file API success")

s, hook = loadHook()
for n = 1, 100 do
    local id = 100 + n
    s.pilot[id] = {id = id, side = 2, slot = 300 + n, ucid = string.format("%032x", n)}
end
for n = 1, 20 do send(hook, prefix .. codeFor(n), 100 + n) end
for _ = 1, 7 do hook.onSimulationFrame() end
assert(count(s) == 12, "global burst must be bounded")
s, hook = loadHook()
for n = 1, 40 do
    local id = 100 + n
    s.pilot[id] = {id = id, side = 2, slot = 300 + n, ucid = string.format("%032x", n)}
    s.now = 10 + n * 0.25
    send(hook, prefix .. codeFor(n), id)
end
hook.onSimulationFrame(); assert(count(s) == 2, "disk budget per frame")
for _ = 1, 20 do hook.onSimulationFrame() end
assert(count(s) == 32 and ready(s, codeFor(32)) and not ready(s, codeFor(33)), "queue cap must be hard")
s, hook = loadHook()
for n = 1, 128 do s.files[directory .. codeFor(n) .. ".pair"] = "old" end
send(hook, prefix .. first); hook.onSimulationFrame()
assert(count(s) == 128 and s.dirClosed == 1 and s.openCount == 0, "on-disk cap must be hard")
print("PASS: global burst, 32 in-memory, 128 on-disk, and two publications per frame are bounded")
