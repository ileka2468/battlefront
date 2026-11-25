-- Fixed loader for the dedicated Battlefront Caucasus campaign.
-- Never executes a command read from a file, mission, or network request.
local callbacks = {}
local initialized = false
local target = 'battlefront_caucasus.miz'
local inject = [[a_do_script("dofile('C:/DCS_configs/DCS.server1/Scripts/battlefront_campaign_engine.lua')")]]

function callbacks.onMissionLoadEnd()
    initialized = false
end

function callbacks.onSimulationFrame()
    if initialized then return end
    local file = tostring(DCS.getMissionFilename() or ''):gsub('\\', '/')
    local name = file:match('([^/]+)$')
    if not name or name:lower() ~= target then return end
    initialized = true
    local ok, result, accepted = pcall(net.dostring_in, 'mission', inject)
    if net.log then
        if ok and accepted ~= false then
            net.log('BATTLEFRONT FIXED LOADER: campaign engine injected')
        else
            net.log('BATTLEFRONT FIXED LOADER: campaign engine not accepted (' .. tostring(result) .. ')')
        end
    end
end

DCS.setUserCallbacks(callbacks)
