-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - HIGH-PERFORMANCE SERVER CULLING ENGINE
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

BF.Culling = BF.Culling or {}

local SIDE_RED  = BF.SIDE_RED or 1
local SIDE_BLUE = BF.SIDE_BLUE or 2

function BF.ProcessServerCulling()
    local CULL_DISTANCE = 45000 -- 45 km proximity threshold
    local activePlayers = {}

    -- Gather positions of all active aircraft (players on both sides)
    for _, side in ipairs({SIDE_BLUE, SIDE_RED}) do
        local players = coalition.getPlayers(side) or {}
        for _, u in ipairs(players) do
            if u and u:isExist() then
                table.insert(activePlayers, u:getPoint())
            end
        end
    end

    for secName, sec in pairs(BF.State.sectors) do
        if sec.status == "DEFENDED" and sec.groupName then
            local grp = Group.getByName(sec.groupName)
            if grp and grp:isExist() then
                local ctrl = grp:getController()
                if ctrl then
                    local minDistance = 999999
                    for _, ppos in ipairs(activePlayers) do
                        local d = math.sqrt((ppos.x - sec.pos.x)^2 + (ppos.z - sec.pos.z)^2)
                        if d < minDistance then
                            minDistance = d
                        end
                    end

                    if minDistance > CULL_DISTANCE then
                        -- NO PLAYERS NEARBY: CULL TO DORMANT (Save CPU)
                        if not sec.isCulled then
                            sec.isCulled = true
                            pcall(function()
                                ctrl:setOption(AI.Option.Ground.val.ALARM_STATE, AI.Option.Ground.val.ALARM_STATE.GREEN)
                                ctrl:setOption(AI.Option.Air.val.ROE, AI.Option.Air.val.ROE.WEAPON_HOLD)
                            end)
                        end
                    else
                        -- PLAYERS APPROACHING WITHIN 45KM: WAKE UP
                        if sec.isCulled or sec.isCulled == nil then
                            sec.isCulled = false
                            pcall(function()
                                ctrl:setOption(AI.Option.Ground.val.ALARM_STATE, AI.Option.Ground.val.ALARM_STATE.AUTO)
                                ctrl:setOption(AI.Option.Air.val.ROE, AI.Option.Air.val.ROE.WEAPON_FREE)
                            end)
                        end
                    end
                end
            end
        end
    end

    return timer.getTime() + 10 -- re-cull every 10 seconds
end

-- ------------------------------------------------------------------------------
-- 7B. R&D BLUEPRINTS & CAMPAIGN STATE PERSISTENCE
-- ------------------------------------------------------------------------------
local STATE_FILE = "C:/DCS_configs/DCS.server1/Scripts/battlefront_campaign_state.lua"



BF.Culling.Process = BF.ProcessServerCulling
