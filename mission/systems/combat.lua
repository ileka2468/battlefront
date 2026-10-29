-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - COMBAT EVENT HANDLER & BOUNTIES
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

BF.Combat = BF.Combat or {}

local SIDE_RED  = BF.SIDE_RED or 1
local SIDE_BLUE = BF.SIDE_BLUE or 2

local function log(msg) BF.Log(msg) end

local EventHandler = {}

function EventHandler:onEvent(event)
    if not event then return end

    -- Hit on Ground Unit near facility
    if event.id == world.event.S_EVENT_HIT or event.id == world.event.S_EVENT_SHOOTING_START then
        if event.target and event.target.getPoint then
            local pos = event.target:getPoint()
            for secName, sec in pairs(BF.State.sectors) do
                local dist = math.sqrt((pos.x - sec.pos.x)^2 + (pos.z - sec.pos.z)^2)
                if dist <= BF.Config.combatAlertRadius then
                    BF.OnSectorUnderAttack(secName)
                end
            end
        end
    end

    -- Unit Killed (Check if facility defenses cleared)
    if event.id == world.event.S_EVENT_KILL then
        local atkSide = event.initiator and event.initiator.getCoalition and event.initiator:getCoalition() or 0

        -- Ground unit kill -> check clearance
        if event.target and event.target.getName then
            local tname = event.target:getName()
            for secName, sec in pairs(BF.State.sectors) do
                if sec.defenders[tname] then
                    sec.defenders[tname] = nil
                    BF.CheckSectorDefensesCleared(secName, atkSide)
                end
            end
        end

        -- Air-to-Air Splash Bounty
        if event.target and event.target.getDesc then
            local desc = event.target:getDesc()
            if desc.category == Unit.Category.AIRPLANE and atkSide > 0 then
                local coal = BF.State.coalitions[atkSide]
                if coal then
                    coal.treasury = coal.treasury + BF.Config.airKillBounty
                    BF.Broadcast(string.format("AIR COMBAT BOUNTY: Hostile aircraft splashed! +%s credited to %s treasury.",
                        BF.FormatMoney(BF.Config.airKillBounty), coal.name), atkSide, 6)
                end
            end
        end
    end

    -- Map Marker Command System (Fighter Cargo Drops & AWACS Datalink)
    if event.id == world.event.S_EVENT_MARK_CHANGE or event.id == world.event.S_EVENT_MARK_ADD then
        BF.ProcessMapMarkerCommand(event)
    end

    -- Aircraft Crash / Pilot Ejection / Death
    if event.id == world.event.S_EVENT_CRASH or event.id == world.event.S_EVENT_PILOT_DEAD or event.id == world.event.S_EVENT_EJECTION then
        if event.initiator and event.initiator.getName then
            local unitName = event.initiator:getName()
            local unitType = event.initiator:getTypeName()
            local unitSide = event.initiator:getCoalition()

            if string.find(unitName, "HERO") then
                local coal = BF.State.coalitions[unitSide]
                if coal then
                    local cost = BF.Config.heroReplacementCosts[unitType] or 190
                    if coal.treasury >= cost then
                        coal.treasury = coal.treasury - cost
                        coal.heroCooldowns[unitName] = BF.Config.heroCooldownSeconds
                        trigger.action.setUserFlag(unitName, 100) -- Lock slot in SSB during delivery

                        local msg = string.format("COMMAND (%s): %s (%s) lost in combat.\nReplacement airframe procured from assembly line (%s deducted).\nDelivery to flight line in %d minutes. Treasury: %s",
                            coal.name, unitName, unitType, BF.FormatMoney(cost), math.floor(BF.Config.heroCooldownSeconds / 60), BF.FormatMoney(coal.treasury))
                        BF.Broadcast(msg, unitSide, 14)
                    else
                        trigger.action.setUserFlag(unitName, 100)
                        local msg = string.format("CRITICAL (%s): %s (%s) lost in combat.\nProcurement HALTED: Insufficient capital (%s required, Balance: %s).\nCapture and hold industrial facilities to restore treasury.",
                            coal.name, unitName, unitType, BF.FormatMoney(cost), BF.FormatMoney(coal.treasury))
                        BF.Broadcast(msg, unitSide, 16)
                    end
                end
            end
        end
    end
end

BF.Combat.EventHandler = EventHandler
