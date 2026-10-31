-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - CONTENTION EWR & DATALINK SYSTEM
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

BF.EWR = BF.EWR or {
    interval = 20,
    maxDistanceNM = 120,
    radarMaxRangeGround = 120000,
    radarMaxRangeAwacs  = 350000,
    stealthModifier = 0.25,
    tickCount = 0,
}

local SIDE_RED  = BF.SIDE_RED or 1
local SIDE_BLUE = BF.SIDE_BLUE or 2
local SIDE_ALL  = BF.SIDE_ALL or -1

local function log(msg) BF.Log(msg) end

local dropCounter = 9000

function BF.SpawnInitialBaselineEWR()
    log("BATTLEFRONT: Spawning Baseline Tier 1 EWR Stations near rear bases...")

    local ewrStations = {
        -- BLUFOR Home Base EWR (Sochi-Adler & Senaki-Kolkhi)
        { side = SIDE_BLUE, country = country.id.USA,    name = "BLUFOR_BASE_EWR_SOCHI",  type = "1L13 EWR", x = -163000, z = 460000, label = "BLUFOR Coast EWR [Sochi]" },
        { side = SIDE_BLUE, country = country.id.USA,    name = "BLUFOR_BASE_EWR_SENAKI", type = "1L13 EWR", x = -281000, z = 648000, label = "BLUFOR South EWR [Senaki]" },
        -- REDFOR Home Base EWR (Krymsk & Maykop)
        { side = SIDE_RED,  country = country.id.RUSSIA, name = "REDFOR_BASE_EWR_KRYMSK", type = "55G6 EWR", x = -10000,  z = 290000, label = "REDFOR North EWR [Krymsk]" },
        { side = SIDE_RED,  country = country.id.RUSSIA, name = "REDFOR_BASE_EWR_MAYKOP", type = "55G6 EWR", x = -24000,  z = 468000, label = "REDFOR East EWR [Maykop]" },
    }

    for _, st in ipairs(ewrStations) do
        dropCounter = dropCounter + 10
        local gname = string.format("GRP_%s_%d", st.name, dropCounter)
        local escType = (st.side == SIDE_BLUE) and "M2A2 Bradley" or "BMP-3"
        local groupData = {
            ["visible"] = true,
            ["tasks"] = {},
            ["uncontrolled"] = false,
            ["route"] = { ["points"] = { [1] = { ["alt"] = 0, ["type"] = "Turning Point", ["action"] = "Off Road", ["speed"] = 0, ["x"] = st.x, ["y"] = st.z } } },
            ["groupId"] = dropCounter,
            ["name"] = gname,
            ["units"] = {
                [1] = { ["type"] = st.type,  ["unitId"] = dropCounter + 1, ["name"] = gname .. "_RADAR", ["x"] = st.x,      ["y"] = st.z,      ["heading"] = 0, ["skill"] = "High", ["playerCanDrive"] = false },
                [2] = { ["type"] = escType,  ["unitId"] = dropCounter + 2, ["name"] = gname .. "_ESCORT", ["x"] = st.x + 40, ["y"] = st.z + 40, ["heading"] = 0, ["skill"] = "High", ["playerCanDrive"] = false },
            }
        }
        local ok, err = pcall(function()
            coalition.addGroup(st.country, Group.Category.GROUND, groupData)
            trigger.action.textToAll(st.side, 7000 + dropCounter, {x = st.x, y = 0, z = st.z}, {0.3, 0.8, 1.0, 0.9}, {0,0,0,0}, 16, true, "📡 " .. st.label)
        end)
        if ok then
            table.insert(BF.State.radarStations, { side = st.side, unitName = gname .. "_RADAR", isAwacs = false, label = st.label })
            log("BATTLEFRONT: Successfully spawned & registered baseline EWR: " .. gname .. "_RADAR (" .. st.label .. ")")
        else
            log("BATTLEFRONT ERROR: Failed to addGroup for baseline EWR: " .. tostring(err))
        end
    end
end



function BF.EWR.GetActiveRadars(side)
    local active = {}
    local groundCount = 0
    local awacsCount = 0

    for _, r in ipairs(BF.State.radarStations) do
        if r.side == side then
            local u = Unit.getByName(r.unitName)
            if u and u:isExist() and u:getLife() > 0 then
                local p = nil
                pcall(function() p = u:getPoint() end)
                if p then
                    table.insert(active, {
                        unitName = r.unitName,
                        isAwacs = r.isAwacs,
                        label = r.label,
                        pos = p,
                    })
                    if r.isAwacs then
                        awacsCount = awacsCount + 1
                    else
                        groundCount = groundCount + 1
                    end
                end
            end
        end
    end
    return active, groundCount, awacsCount
end

-- Check if an enemy airborne target is detected by any friendly radar (with LoS and stealth check)
function BF.EWR.IsTargetDetected(targetUnit, friendlyRadars)
    if not targetUnit or not targetUnit:isExist() or targetUnit:getLife() <= 0 then return false end
    local tpos = nil
    pcall(function() tpos = targetUnit:getPoint() end)
    if not tpos or tpos.y < 35 then return false end -- Filter out parked/grounded aircraft

    local ttype = targetUnit:getTypeName()
    local stealthFactor = 1.0
    if ttype == "F-22A" or ttype == "F-117-NightHawk" or ttype == "Su-57" then
        stealthFactor = BF.EWR.stealthModifier
    end

    for _, r in ipairs(friendlyRadars) do
        local dx = tpos.x - r.pos.x
        local dz = tpos.z - r.pos.z
        local dy = tpos.y - r.pos.y
        local dist = math.sqrt(dx^2 + dz^2 + dy^2)

        local maxRange = (r.isAwacs and BF.EWR.radarMaxRangeAwacs or BF.EWR.radarMaxRangeGround) * stealthFactor
        if dist <= maxRange then
            -- Line of Sight Terrain Check
            local origin = { x = r.pos.x, y = r.pos.y + (r.isAwacs and 0 or 20), z = r.pos.z }
            local hasLoS = true
            pcall(function()
                hasLoS = land.isVisible(origin, tpos)
            end)
            if hasLoS then
                return true
            end
        end
    end

    return false
end

-- Format target altitude with thousands comma separator
local function formatAltitude(altMeters)
    local altFt = math.floor(altMeters * 3.28084 + 0.5)
    if altFt >= 1000 then
        return string.format("%d,%03d ft", math.floor(altFt / 1000), math.floor(altFt % 1000))
    else
        return string.format("%d ft", altFt)
    end
end

-- Calculate target aspect relative to line-of-sight to player
local function calculateAspect(brg, targetHdg)
    local losToPlayer = (brg + 180) % 360
    local diff = (losToPlayer - targetHdg) % 360
    if diff > 180 then diff = diff - 360 end

    if math.abs(diff) <= 35 then
        return "Hot"
    elseif math.abs(diff) >= 145 then
        return "Cold"
    elseif diff > 0 then
        return (diff >= 75 and diff <= 105) and "Beam Right" or "Flank Right"
    else
        return (diff <= -75 and diff >= -105) and "Beam Left" or "Flank Left"
    end
end

-- Clean target type name for neat table formatting
local function cleanTypeName(rawType)
    if not rawType then return "Bandit" end
    if rawType == "F-117-NightHawk" then return "F-117A" end
    if rawType == "FA-18C_hornet" then return "FA-18C_hornet" end
    if rawType == "A-10C_2" then return "A-10C" end
    if rawType == "F-16C_50" then return "F-16C" end
    if rawType == "Su-25T" then return "Su-25T" end
    if rawType == "Ka-50_3" then return "Ka-50" end
    if rawType == "Mi-24P" then return "Mi-24P" end
    if rawType == "AH-64D_BLK_II" then return "AH-64D" end
    if rawType:len() > 14 then
        return rawType:sub(1, 14)
    end
    return rawType
end

-- Generate and send the Contention EWR Picture Report to all players of a coalition
function BF.EWR.SendPictureReportForSide(side)
    local friendlyRadars, groundCount, awacsCount = BF.EWR.GetActiveRadars(side)
    local enemySide = (side == SIDE_BLUE) and SIDE_RED or SIDE_BLUE
    local myPlayers = coalition.getPlayers(side) or {}

    if #myPlayers == 0 then return end

    -- Scan all enemy airborne units
    local detectedEnemies = {}
    local seenUnits = {}
    local enemyPlayers = coalition.getPlayers(enemySide) or {}

    for _, enemyUnit in ipairs(enemyPlayers) do
        if enemyUnit and enemyUnit:isExist() and not seenUnits[enemyUnit:getName()] then
            seenUnits[enemyUnit:getName()] = true
            if BF.EWR.IsTargetDetected(enemyUnit, friendlyRadars) then
                table.insert(detectedEnemies, enemyUnit)
            end
        end
    end

    -- Also check AI flights if any exist on enemy side
    local enemyGroups = coalition.getGroups(enemySide, Group.Category.AIRPLANE) or {}
    for _, grp in ipairs(enemyGroups) do
        for _, u in ipairs(grp:getUnits()) do
            if u and u:isExist() and not seenUnits[u:getName()] then
                seenUnits[u:getName()] = true
                if BF.EWR.IsTargetDetected(u, friendlyRadars) then
                    table.insert(detectedEnemies, u)
                end
            end
        end
    end

    -- For each human player in our coalition, build customized report relative to their aircraft
    for _, playerUnit in ipairs(myPlayers) do
        if playerUnit and playerUnit:isExist() then
            local ppos = nil
            pcall(function() ppos = playerUnit:getPoint() end)

            if ppos then
                local contacts = {}

                for _, bogey in ipairs(detectedEnemies) do
                    if bogey and bogey:isExist() then
                        local bpos = nil
                        local vel = nil
                        pcall(function()
                            bpos = bogey:getPoint()
                            vel = bogey:getVelocity()
                        end)

                        if bpos and vel then
                            local spdKts = math.floor(math.sqrt(vel.x^2 + vel.z^2) * 1.94384 + 0.5)

                            -- Filter out ground/taxiing vehicles (MTI Doppler radar filter)
                            if spdKts >= 30 or bpos.y > 100 then
                                local dx = bpos.x - ppos.x
                                local dz = bpos.z - ppos.z
                                local distM = math.sqrt(dx^2 + dz^2)
                                local distNM = distM * 0.000539957

                                -- Bearing from player to bogey
                                local brg = math.deg(math.atan2(dz, dx))
                                if brg < 0 then brg = brg + 360 end
                                brg = math.floor(brg + 0.5)
                                if brg == 0 then brg = 360 end

                                -- Bogey Heading
                                local hdg = math.deg(math.atan2(vel.z, vel.x))
                                if hdg < 0 then hdg = hdg + 360 end
                                hdg = math.floor(hdg + 0.5)
                                if hdg == 0 then hdg = 360 end

                                local aspect = calculateAspect(brg, hdg)
                                local altStr = formatAltitude(bpos.y)
                                local rawType = bogey:getTypeName()
                                local typeStr = cleanTypeName(rawType)

                                table.insert(contacts, {
                                    type = typeStr,
                                    brg = brg,
                                    rng = distNM,
                                    alt = altStr,
                                    spd = spdKts,
                                    hdg = hdg,
                                    aspect = aspect,
                                })
                            end
                        end
                    end
                end

                -- Sort by closest range first
                table.sort(contacts, function(a, b) return a.rng < b.rng end)

                -- Build the Battlefront EWR table
                local lines = {}
                table.insert(lines, "Battlefront EWR | Picture Report\n")

                if #friendlyRadars == 0 then
                    table.insert(lines, "⚠ RADAR NETWORK OFFLINE: All friendly EWR radar stations & AWACS destroyed! Deploy mobile EWR via map mark: -drop ewr")
                elseif #contacts == 0 then
                    table.insert(lines, string.format("[Network: %d Ground Radars | %d AWACS Online]\nPicture Clean. No hostile airborne contacts detected.", groundCount, awacsCount))
                else
                    table.insert(lines, string.format("%-14s %-3s   %-8s  %-9s  %-9s   %-3s   %s", "TYPE", "BRG", "RNG", "ALT", "SPD", "HDG", "Aspect"))
                    -- Limit to closest 7 contacts to avoid VR / HUD clutter
                    local maxShow = math.min(#contacts, 7)
                    for i = 1, maxShow do
                        local c = contacts[i]
                        table.insert(lines, string.format("%-14s %03d   %5.1f NM  %9s  %4d Knts   %03d   %s",
                            c.type, c.brg, c.rng, c.alt, c.spd, c.hdg, c.aspect))
                    end
                    if #contacts > 7 then
                        table.insert(lines, string.format("\n... and %d additional distant contacts tracked.", #contacts - 7))
                    end
                end

                local reportText = table.concat(lines, "\n")
                local grp = nil
                pcall(function() grp = playerUnit:getGroup() end)
                if grp and grp.getID then
                    trigger.action.outTextForGroup(grp:getID(), reportText, 18, true)
                else
                    trigger.action.outTextForCoalition(side, reportText, 18, true)
                end
            end
        end
    end
end

-- 20-Second Automatic Picture Report Loop
function BF.EWR.Loop()
    local bRadars, bG, bA = BF.EWR.GetActiveRadars(SIDE_BLUE)
    local rRadars, rG, rA = BF.EWR.GetActiveRadars(SIDE_RED)

    BF.EWR.tickCount = (BF.EWR.tickCount or 0) + 1
    if BF.EWR.tickCount % 3 == 1 then
        log(string.format("BATTLEFRONT EWR TICK #%d: BLUFOR Radars [%d ground, %d AWACS] | REDFOR Radars [%d ground, %d AWACS]",
            BF.EWR.tickCount, bG, bA, rG, rA))
    end

    for _, side in ipairs({SIDE_BLUE, SIDE_RED}) do
        if not BF.State.coalitionEwrDisabled[side] then
            pcall(function()
                BF.EWR.SendPictureReportForSide(side)
            end)
        end
    end

    return timer.getTime() + BF.EWR.interval -- Refresh every 20 seconds
end

-- ------------------------------------------------------------------------------
-- 10. INITIALIZATION
-- ------------------------------------------------------------------------------

