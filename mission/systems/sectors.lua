-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - SECTOR CAPTURE & FRONTLINE ENGINE
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

BF.Sectors = BF.Sectors or {}

local SIDE_RED  = BF.SIDE_RED or 1
local SIDE_BLUE = BF.SIDE_BLUE or 2
local SIDE_ALL  = BF.SIDE_ALL or -1

local function log(msg) BF.Log(msg) end

function BF.DrawFrontlineAndQuadrants()
    log("BATTLEFRONT: Drawing 4-Quadrant Map Layout...")

    local RED_COLOR     = {1.0, 0.15, 0.15, 0.85}
    local BLUE_COLOR    = {0.15, 0.55, 1.0, 0.85}
    local FRONT_COLOR   = {1.0, 0.85, 0.1, 1.0}
    local BORDER_COLOR  = {0.7, 0.7, 0.7, 0.6}
    local TEXT_COLOR_R  = {1.0, 0.3, 0.3, 0.95}
    local TEXT_COLOR_B  = {0.3, 0.7, 1.0, 0.95}

    local z_west  = 260000
    local z_mid   = 580000
    local z_east  = 900000
    local x_north = 50000
    local x_front = -165000
    local x_south = -350000

    -- A. THREE-LAYER ACTIVE FRONTLINE
    pcall(function() trigger.action.lineToAll(SIDE_ALL, 5001, {x = x_front, y = 0, z = z_west}, {x = x_front, y = 0, z = z_east}, FRONT_COLOR, 1, true, "ACTIVE CONTESTED FRONTLINE") end)
    pcall(function() trigger.action.lineToAll(SIDE_ALL, 5002, {x = x_front + 12000, y = 0, z = z_west}, {x = x_front + 12000, y = 0, z = z_east}, RED_COLOR, 2, true, "REDFOR FORWARD DEFENSE") end)
    pcall(function() trigger.action.lineToAll(SIDE_ALL, 5003, {x = x_front - 12000, y = 0, z = z_west}, {x = x_front - 12000, y = 0, z = z_east}, BLUE_COLOR, 2, true, "BLUFOR FORWARD DEFENSE") end)

    -- B. QUADRANT CENTER MERIDIAN
    pcall(function() trigger.action.lineToAll(SIDE_ALL, 5010, {x = x_front, y = 0, z = z_mid}, {x = x_north, y = 0, z = z_mid}, RED_COLOR, 2, true, "NORTH QUADRANT BOUNDARY") end)
    pcall(function() trigger.action.lineToAll(SIDE_ALL, 5011, {x = x_front, y = 0, z = z_mid}, {x = x_south, y = 0, z = z_mid}, BLUE_COLOR, 2, true, "SOUTH QUADRANT BOUNDARY") end)

    -- C. THEATER PERIMETERS
    pcall(function() trigger.action.lineToAll(SIDE_ALL, 5020, {x = x_south, y = 0, z = z_west}, {x = x_north, y = 0, z = z_west}, BORDER_COLOR, 1, true, "WESTERN THEATER BOUNDARY") end)
    pcall(function() trigger.action.lineToAll(SIDE_ALL, 5021, {x = x_south, y = 0, z = z_east}, {x = x_north, y = 0, z = z_east}, BORDER_COLOR, 1, true, "EASTERN THEATER BOUNDARY") end)
    pcall(function() trigger.action.lineToAll(SIDE_ALL, 5022, {x = x_north, y = 0, z = z_west}, {x = x_north, y = 0, z = z_east}, RED_COLOR, 1, true, "REDFOR REAR PERIMETER") end)
    pcall(function() trigger.action.lineToAll(SIDE_ALL, 5023, {x = x_south, y = 0, z = z_west}, {x = x_south, y = 0, z = z_east}, BLUE_COLOR, 1, true, "BLUFOR REAR PERIMETER") end)

    -- D. QUADRANT CALLOUT LABELS ON F10 MAP
    pcall(function() trigger.action.textToAll(SIDE_ALL, 6001, {x = -60000, y = 0, z = 420000}, TEXT_COLOR_R, {0,0,0,0}, 22, true, "◀ QUADRANT 1: NORTH-WEST (REDFOR) ▶\n[KRYMSK / NOVOROSSIYSK SECTOR]") end)
    pcall(function() trigger.action.textToAll(SIDE_ALL, 6002, {x = -60000, y = 0, z = 740000}, TEXT_COLOR_R, {0,0,0,0}, 22, true, "◀ QUADRANT 2: NORTH-EAST (REDFOR) ▶\n[MAYKOP / NALCHIK AEROSPACE & C2]") end)
    pcall(function() trigger.action.textToAll(SIDE_ALL, 6003, {x = -260000, y = 0, z = 420000}, TEXT_COLOR_B, {0,0,0,0}, 22, true, "◀ QUADRANT 3: SOUTH-WEST (BLUFOR) ▶\n[SOCHI / GUDAUTA EXPEDITIONARY]") end)
    pcall(function() trigger.action.textToAll(SIDE_ALL, 6004, {x = -260000, y = 0, z = 740000}, TEXT_COLOR_B, {0,0,0,0}, 22, true, "◀ QUADRANT 4: SOUTH-EAST (BLUFOR) ▶\n[POTI / KUTAISI STEALTH & SILICON HUB]") end)
    pcall(function() trigger.action.textToAll(SIDE_ALL, 6005, {x = x_front - 2500, y = 0, z = 500000}, FRONT_COLOR, {0,0,0,0}, 20, true, "══════════ ACTIVE CONTESTED FRONTLINE ══════════") end)

    -- E. INITIALIZE ALL SECTOR RINGS & POINT DEFENSES
    for name, sec in pairs(BF.State.sectors) do
        BF.RenderSectorMarkers(name)
        BF.SpawnSectorPointDefense(name, sec.side)
    end
end

-- ------------------------------------------------------------------------------
-- 5B. DEDICATED WEAPONS & AVIONICS TEST RANGES (Air Drones + Ground Targets)
-- ------------------------------------------------------------------------------


function BF.RenderSectorMarkers(secName)
    local sec = BF.State.sectors[secName]
    if not sec then return end

    pcall(function() trigger.action.removeMark(sec.markInnerId) end)
    pcall(function() trigger.action.removeMark(sec.markOuterId) end)

    -- Inner Compound Color
    local innerColor = {0.15, 0.55, 1.0, 0.85} -- Blue
    if sec.side == SIDE_RED then
        innerColor = {1.0, 0.2, 0.2, 0.85}     -- Red
    end
    if sec.status == "NEUTRAL" or sec.status == "HOLDING" then
        innerColor = {1.0, 0.75, 0.0, 0.9}     -- Contested Amber / Yellow
        outerColor = {1.0, 0.75, 0.0, 0.5}     -- Amber Tripwire Ring
    end

    if sec.underAttack then
        innerColor = {1.0, 0.95, 0.0, 1.0} -- Vibrant Combat Yellow
        outerColor = {1.0, 0.95, 0.0, 0.7}
    end
    local ownerText = (sec.status == "NEUTRAL") and "CONTESTED / UNFORTIFIED" or ((sec.side == SIDE_BLUE) and "BLUFOR" or "REDFOR")
    local infoText = string.format("%s [Lvl %d]\n[%s]\nOwner: %s | Status: %s | +$%dM/5m",
        secName, sec.level or 1, sec.category, ownerText, sec.status, sec.income)

    -- Draw Inner Target Facility Ring (3 km)
    pcall(function()
        trigger.action.circleToAll(SIDE_ALL, sec.markInnerId, {x = sec.pos.x, y = 0, z = sec.pos.z}, 3000, innerColor, {0,0,0,0}, 1, true, infoText)
    end)

    -- Draw Outer Tactical Maneuver Ring (18 km Early-Warning Tripwire)
    pcall(function()
        local ringLabel = (sec.status == "NEUTRAL") and (secName .. " (18km Early-Warning Tripwire AO)") or (secName .. " (18km Air Combat Zone)")
        trigger.action.circleToAll(SIDE_ALL, sec.markOuterId, {x = sec.pos.x, y = 0, z = sec.pos.z}, BF.Config.holdRadius, outerColor, {0,0,0,0}, 2, true, ringLabel)
    end)
end

-- ------------------------------------------------------------------------------
-- 6. COMBAT ALERTS & CLEARANCE DEPOSIT
-- ------------------------------------------------------------------------------
function BF.OnSectorUnderAttack(secName)
    local sec = BF.State.sectors[secName]
    if not sec then return end

    local now = timer.getTime()
    sec.lastAttackTime = now

    if not sec.underAttack then
        sec.underAttack = true
        local defSide = sec.side
        local defName = (defSide == SIDE_BLUE) and "ALLIED" or "RED COMMAND"

        local alertMsg = string.format("⚠ TACTICAL ALERT: %s [%s] is UNDER ATTACK! Ground defenses engaged! CAS / CAP scramble requested!",
            secName, defName)
        BF.Broadcast(alertMsg, defSide, 14)

        BF.RenderSectorMarkers(secName)
    end
end

function BF.CheckSectorDefensesCleared(secName, atkSide)
    local sec = BF.State.sectors[secName]
    if not sec or sec.status == "NEUTRAL" or sec.status == "CLEARED" then return end

    -- Check if all defenders are dead
    local aliveCount = 0
    for uname, _ in pairs(sec.defenders) do
        local u = Unit.getByName(uname)
        if u and u:isExist() and u:getLife() > 1 then
            aliveCount = aliveCount + 1
        end
    end

    if aliveCount == 0 then
        -- DEFENSES CLEARED! IMMEDIATE TREASURY DEPOSIT
        sec.status = "NEUTRAL"
        sec.clearedSide = atkSide
        sec.underAttack = false
        sec.lastTripwireAlertTime = 0

        local coal = BF.State.coalitions[atkSide]
        if coal then
            coal.treasury = coal.treasury + sec.captureBounty
            local depositMsg = string.format("★ STRATEGIC SUCCESS (%s): %s defenses NEUTRALIZED!\nTreasury Bounty: +%s (Balance: %s)!\nSector is OPEN! Deliver garrison troops or logistics cargo to LZ to FORTIFY!",
                coal.name, secName, BF.FormatMoney(sec.captureBounty), BF.FormatMoney(coal.treasury))
            BF.Broadcast(depositMsg, atkSide, 16)
        end

        local defSide = sec.side
        local loseMsg = string.format("CRITICAL ALERT (%s): %s point defenses have FALLEN!\nSector is vulnerable! Rush counter-logistics or assault troops to LZ to RE-GARRISON and save the base!",
            (defSide == SIDE_BLUE) and "BLUFOR" or "REDFOR", secName)
        BF.Broadcast(loseMsg, defSide, 16)

        BF.RenderSectorMarkers(secName)
        BF.SaveState()
    end
end

-- ------------------------------------------------------------------------------
-- 7. THE PHYSICAL LOGISTICS CAPTURE & EARLY-WARNING TRIPWIRE ENGINE
-- ------------------------------------------------------------------------------
function BF.ProcessSectorsAndLogistics()
    local now = timer.getTime()

    for secName, sec in pairs(BF.State.sectors) do
        -- Check Alert Timeout
        if sec.underAttack and (now - sec.lastAttackTime > BF.Config.combatAlertTimeout) then
            sec.underAttack = false
            BF.RenderSectorMarkers(secName)
        end

        -- Process Neutral Sectors (The Logistics Race)
        if sec.status == "NEUTRAL" then
            local atkSide = sec.clearedSide
            local defSide = (atkSide == SIDE_BLUE) and SIDE_RED or SIDE_BLUE

            local hostileInBubble = false
            local friendlyInBubble = false
            local CAPTURE_LZ_RADIUS = 3000 -- 3 km delivery / touchdown radius
            local TRIPWIRE_RADIUS = BF.Config.holdRadius or 18000

            -- Check human players and AI logistics helicopters for physical touchdown or tripwire breach
            for _, side in ipairs({SIDE_BLUE, SIDE_RED}) do
                local candidates = {}
                for _, u in ipairs(coalition.getPlayers(side) or {}) do
                    table.insert(candidates, u)
                end
                if Group and Group.Category and Group.Category.HELICOPTER then
                    for _, grp in ipairs(coalition.getGroups(side, Group.Category.HELICOPTER) or {}) do
                        if grp and grp:isExist() then
                            for _, u in ipairs(grp:getUnits() or {}) do
                                table.insert(candidates, u)
                            end
                        end
                    end
                end
                for _, u in ipairs(candidates) do
                    if u and u:isExist() then
                        local pos = u:getPoint()
                        local dist = math.sqrt((pos.x - sec.pos.x)^2 + (pos.z - sec.pos.z)^2)

                        if dist <= TRIPWIRE_RADIUS then
                            if side == defSide and u:inAir() then
                                hostileInBubble = true
                            elseif side == atkSide then
                                friendlyInBubble = true
                            end
                        end

                        -- Physical Touchdown at Objective LZ (within 3 km)
                        if dist <= CAPTURE_LZ_RADIUS then
                            local altAGL = pos.y - land.getHeight({x = pos.x, y = pos.z})
                            local vel = u:getVelocity()
                            local speed = math.sqrt(vel.x^2 + vel.y^2 + vel.z^2)
                            local pilotLabel = (u.getPlayerName and u:getPlayerName()) or (u.getName and u:getName()) or "Tactical Logistics"

                            -- Landed or low-speed tactical touchdown
                            if (not u:inAir()) or (altAGL < 45 and speed < 40) then
                                if side == atkSide then
                                    -- ATTACKER CAPTURE & FORTIFICATION!
                                    sec.status = "DEFENDED"
                                    sec.side = atkSide
                                    sec.underAttack = false

                                    local teamName = (atkSide == SIDE_BLUE) and "BLUFOR" or "REDFOR"
                                    local fortMsg = string.format("🛡 SECTOR CAPTURED & FORTIFIED (%s): %s has been secured by %s!\nFresh SHORAD, AAA & MANPADS garrison deployed to LZ! Production fully online!",
                                        teamName, secName, pilotLabel)
                                    BF.Broadcast(fortMsg, nil, 16)

                                    BF.SpawnSectorPointDefense(secName, atkSide)
                                    BF.RenderSectorMarkers(secName)
                                    BF.SaveState()
                                    break
                                elseif side == defSide then
                                    -- DEFENDER SAVES THE BASE!
                                    sec.status = "DEFENDED"
                                    sec.side = defSide
                                    sec.underAttack = false

                                    local teamName = (defSide == SIDE_BLUE) and "BLUFOR" or "REDFOR"
                                    local saveMsg = string.format("★ BASE SAVED (%s): %s counter-logistics touched down at %s!\nGarrison re-established! Enemy capture thwarted!",
                                        teamName, pilotLabel, secName)
                                    BF.Broadcast(saveMsg, nil, 16)

                                    BF.SpawnSectorPointDefense(secName, defSide)
                                    BF.RenderSectorMarkers(secName)
                                    BF.SaveState()
                                    break
                                end
                            end
                        end
                    end
                end
            end

            -- Broadcast Tripwire Alert if hostiles enter contested sector
            if hostileInBubble and friendlyInBubble then
                if (now - (sec.lastTripwireAlertTime or 0)) > 45 then
                    sec.lastTripwireAlertTime = now
                    local alertMsg = string.format("⚠ TRIPWIRE ALERT: Hostile fighters entered %s airspace! Inbound logistics mask in terrain! Friendly CAP vector to intercept!", secName)
                    BF.Broadcast(alertMsg, atkSide, 10)
                end
            end
        end
    end

    -- Process Hero Slot Cooldowns
    for side, coal in pairs(BF.State.coalitions) do
        for slotUnitName, cooldown in pairs(coal.heroCooldowns) do
            if cooldown > 0 then
                coal.heroCooldowns[slotUnitName] = math.max(0, cooldown - 5)
                if coal.heroCooldowns[slotUnitName] == 0 then
                    trigger.action.setUserFlag(slotUnitName, 0)
                    BF.Broadcast(string.format("COMMAND (%s): Replacement airframe (%s) delivered to flight line. Ready for sortie!", coal.name, slotUnitName), side, 10)
                end
            end
        end
    end

    return now + 5 -- re-check every 5 seconds
end

-- ------------------------------------------------------------------------------
-- 7B. HIGH-PERFORMANCE SERVER CULLING ENGINE (AI SLEEP / WAKE)
-- ------------------------------------------------------------------------------


BF.Sectors.RenderSectorMarkers = BF.RenderSectorMarkers
BF.Sectors.DrawFrontlineAndQuadrants = BF.DrawFrontlineAndQuadrants
BF.Sectors.ProcessLoop = BF.ProcessSectorsAndLogistics
