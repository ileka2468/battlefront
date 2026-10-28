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

