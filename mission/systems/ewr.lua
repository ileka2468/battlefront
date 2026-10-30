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

