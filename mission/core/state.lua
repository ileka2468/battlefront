-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - CAMPAIGN STATE & PERSISTENCE
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

local SIDE_RED  = BF.SIDE_RED or 1
local SIDE_BLUE = BF.SIDE_BLUE or 2

BF.State = {
    coalitions = {
        [SIDE_BLUE] = {
            name = "BLUFOR",
            treasury = BF.Config.startingBudget,
            stockFlightSeconds = 0,
            heroCooldowns = {},
            unlockedBlueprints = {},
        },
        [SIDE_RED] = {
            name = "REDFOR",
            treasury = BF.Config.startingBudget,
            stockFlightSeconds = 0,
            heroCooldowns = {},
            unlockedBlueprints = {},
        }
    },

    activeAwacs = {
        [SIDE_BLUE] = {},
        [SIDE_RED]  = {},
    },
    tacticalEwr = {},
    radarStations = {},
    coalitionEwrDisabled = {
        [SIDE_BLUE] = false,
        [SIDE_RED]  = false,
    },
    testRangeGroups = {},

    -- Target Catalog (Primary, Secondary, and Strategic Facilities across 4 Quadrants)
    sectors = {
        -- ======================================================================
        -- QUADRANT 1: NORTH-WEST (REDFOR)
        -- ======================================================================
        ["Krasnodar Silicon Fab"] = {
            id = 101,
            quadrant = "NW",
            side = SIDE_RED,
            originalSide = SIDE_RED,
            pos = { x = -12000, z = 370000 },
            category = "Secondary - Silicon Fab",
            desc = "Advanced Microelectronics & Radar Processor Foundry",
            income = 8,
            captureBounty = 135,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2101,
            markInnerId = 3101,
            defenders = {},
        },
        ["Novorossiysk Oil Refinery"] = {
            id = 102,
            quadrant = "NW",
            side = SIDE_RED,
            originalSide = SIDE_RED,
            pos = { x = -25000, z = 320000 },
            category = "Secondary - Oil Refinery",
            desc = "Black Sea Deepwater Crude & Jet Fuel Facility",
            income = 6,
            captureBounty = 120,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2102,
            markInnerId = 3102,
            defenders = {},
        },
        ["Krymsk Airfield Base"] = {
            id = 103,
            quadrant = "NW",
            side = SIDE_RED,
            originalSide = SIDE_RED,
            pos = { x = -7500, z = 294000 },
            category = "Primary - Airfield",
            desc = "Major Frontline Fighter Wing & Interceptor Base",
            income = 10,
            captureBounty = 150,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2103,
            markInnerId = 3103,
            defenders = {},
        },
        ["Anapa Marine Fuel Terminal"] = {
            id = 104,
            quadrant = "NW",
            side = SIDE_RED,
            originalSide = SIDE_RED,
            pos = { x = -6000, z = 240000 },
            category = "Secondary - Industrial Terminal",
            desc = "Black Sea Coastal Tanker Staging & Pumping Pier",
            income = 6,
            captureBounty = 105,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2104,
            markInnerId = 3104,
            defenders = {},
        },
        ["Slavyansk Chemical & Propellant Plant"] = {
            id = 105,
            quadrant = "NW",
            side = SIDE_RED,
            originalSide = SIDE_RED,
            pos = { x = 12000, z = 315000 },
            category = "Secondary - Factory",
            desc = "Solid-Rocket Motor & High-Explosive Synthesis Facility",
            income = 8,
            captureBounty = 120,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2105,
            markInnerId = 3105,
            defenders = {},
        },

        ["Armavir Metallurgy Complex"] = {
            id = 106,
            quadrant = "NW",
            side = SIDE_RED,
            originalSide = SIDE_RED,
            pos = { x = -35000, z = 520000 },
            category = "Secondary - Metallurgy",
            desc = "Titanium Smelting & Airframe Superalloy Works",
            income = 6,
            captureBounty = 120,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2106,
            markInnerId = 3106,
            defenders = {},
        },
        ["Maykop Aerospace Center"] = {
            id = 107,
            quadrant = "NW",
            side = SIDE_RED,
            originalSide = SIDE_RED,
            pos = { x = -20000, z = 475000 },
            category = "Secondary - Aerospace R&D",
            desc = "Propulsion Engineering & Turbofan Test Facility",
            income = 8,
            captureBounty = 120,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2107,
            markInnerId = 3107,
            defenders = {},
        },

        -- ======================================================================
        -- QUADRANT 2: NORTH-EAST (REDFOR)
        -- ======================================================================
        ["Nalchik C2 Fortress"] = {
            id = 108,
            quadrant = "NE",
            side = SIDE_RED,
            originalSide = SIDE_RED,
            pos = { x = -125487, z = 759560 },
            category = "Primary - Command Center",
            desc = "Deep Underground Integrated Defense Command",
            income = 10,
            captureBounty = 135,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2108,
            markInnerId = 3108,
            defenders = {},
        },
        ["Mineralnye Vody Forward FARP"] = {
            id = 109,
            quadrant = "NE",
            side = SIDE_RED,
            originalSide = SIDE_RED,
            pos = { x = -52089, z = 707418 },
            category = "Primary - FARP",
            desc = "Forward Arming & Refueling Point for Attack Helos & CAS",
            income = 8,
            captureBounty = 120,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2109,
            markInnerId = 3109,
            defenders = {},
        },
        ["Mozdok Strategic Bomber Hub"] = {
            id = 110,
            quadrant = "NE",
            side = SIDE_RED,
            originalSide = SIDE_RED,
            pos = { x = -83329, z = 835634 },
            category = "Primary - Stronghold",
            desc = "Hardened Staging Base & Cruise Missile Depot",
            income = 12,
            captureBounty = 150,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2110,
            markInnerId = 3110,
            defenders = {},
        },

        -- ======================================================================
        -- QUADRANT 3: SOUTH-WEST (BLUFOR)
        -- ======================================================================
        ["Sochi Strategic Harbor"] = {
            id = 111,
            quadrant = "SW",
            side = SIDE_BLUE,
            originalSide = SIDE_BLUE,
            pos = { x = -150000, z = 445000 },
            category = "Primary - Stronghold",
            desc = "Naval Fleet Fuel & Coastal Logistics Pier",
            income = 8,
            captureBounty = 120,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2111,
            markInnerId = 3111,
            defenders = {},
        },
        ["Sukhumi Munitions Plant"] = {
            id = 112,
            quadrant = "SW",
            side = SIDE_BLUE,
            originalSide = SIDE_BLUE,
            pos = { x = -221381, z = 565908 },
            category = "Secondary - Munitions",
            desc = "Precision Guided Bomb & Cruise Missile Assembly",
            income = 6,
            captureBounty = 120,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2112,
            markInnerId = 3112,
            defenders = {},
        },
        ["Gudauta Forward Staging Strip"] = {
            id = 113,
            quadrant = "SW",
            side = SIDE_BLUE,
            originalSide = SIDE_BLUE,
            pos = { x = -195650, z = 515898 },
            category = "Primary - FARP/Airfield",
            desc = "Forward Arming & Interceptor Scramble Base",
            income = 10,
            captureBounty = 135,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2113,
            markInnerId = 3113,
            defenders = {},
        },
        ["Gagra Coastal Defense Outpost"] = {
            id = 114,
            quadrant = "SW",
            side = SIDE_BLUE,
            originalSide = SIDE_BLUE,
            pos = { x = -180000, z = 490000 },
            category = "Secondary - Outpost",
            desc = "Coastal Radar Station & Forward Observation Outpost",
            income = 4,
            captureBounty = 90,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2114,
            markInnerId = 3114,
            defenders = {},
        },
        ["Adler High-Tech Sensor Lab"] = {
            id = 115,
            quadrant = "SW",
            side = SIDE_BLUE,
            originalSide = SIDE_BLUE,
            pos = { x = -165163, z = 460901 },
            category = "Secondary - Industrial",
            desc = "AESA Radar Integration & Electro-Optical Testing",
            income = 8,
            captureBounty = 120,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2115,
            markInnerId = 3115,
            defenders = {},
        },

        -- ======================================================================
        -- QUADRANT 4: SOUTH-EAST (BLUFOR)
        -- ======================================================================
        ["Poti Deepwater Refinery"] = {
            id = 116,
            quadrant = "SE",
            side = SIDE_BLUE,
            originalSide = SIDE_BLUE,
            pos = { x = -278500, z = 629000 },
            category = "Secondary - Oil Refinery",
            desc = "Strategic Hydrocarbon Processing & Storage",
            income = 8,
            captureBounty = 135,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2116,
            markInnerId = 3116,
            defenders = {},
        },
        ["Kutaisi Silicon & Avionics Fab"] = {
            id = 117,
            quadrant = "SE",
            side = SIDE_BLUE,
            originalSide = SIDE_BLUE,
            pos = { x = -284582, z = 685029 },
            category = "Secondary - Silicon Fab",
            desc = "High-Purity Silicon & Datalink Module Facility",
            income = 8,
            captureBounty = 135,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2117,
            markInnerId = 3117,
            defenders = {},
        },
        ["Batumi Metallurgy Drydocks"] = {
            id = 118,
            quadrant = "SE",
            side = SIDE_BLUE,
            originalSide = SIDE_BLUE,
            pos = { x = -354000, z = 621000 },
            category = "Secondary - Metallurgy",
            desc = "Heavy Armor Plating & Hull Metallurgy Plant",
            income = 6,
            captureBounty = 105,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2118,
            markInnerId = 3118,
            defenders = {},
        },
        ["Kobuleti Stealth Skunkworks"] = {
            id = 119,
            quadrant = "SE",
            side = SIDE_BLUE,
            originalSide = SIDE_BLUE,
            pos = { x = -317604, z = 636704 },
            category = "Secondary - Aerospace R&D",
            desc = "RAM Coatings & Low-Observable Composite Lab",
            income = 8,
            captureBounty = 120,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2119,
            markInnerId = 3119,
            defenders = {},
        },
        ["Tskhaltubo Joint C2 Complex"] = {
            id = 120,
            quadrant = "SE",
            side = SIDE_BLUE,
            originalSide = SIDE_BLUE,
            pos = { x = -270000, z = 680000 },
            category = "Primary - Command Center",
            desc = "Allied Air Operations Hardened Headquarters",
            income = 10,
            captureBounty = 135,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2120,
            markInnerId = 3120,
            defenders = {},
        },
        ["Senaki-Kolkhi Airbase"] = {
            id = 121,
            quadrant = "SE",
            side = SIDE_BLUE,
            originalSide = SIDE_BLUE,
            pos = { x = -281903, z = 648379 },
            category = "Primary - Airfield",
            desc = "Major Allied Tactical Fighter Wing Main Base",
            income = 10,
            captureBounty = 150,
            status = "DEFENDED",
            holdTimer = BF.Config.fortifyDuration,
            holdingSide = 0,
            underAttack = false,
            lastAttackTime = 0,
            markOuterId = 2121,
            markInnerId = 3121,
            defenders = {},
        }
    }
}

for sName, sData in pairs(BF.State.sectors) do
    sData.name = sName
end

local STATE_FILE = "C:/DCS_configs/DCS.server1/Scripts/battlefront_campaign_state.lua"

function BF.SaveState()
    return pcall(function()
        local out = {}
        local function append(line) out[#out + 1] = line end
        append("-- Battlefront Campaign Persistent State\n")
        append("return {\n")
        append("  coalitions = {\n")
        for side, coal in pairs(BF.State.coalitions) do
            append(string.format("    [%d] = { treasury = %.2f, stock_flight_seconds = %d, unlocked = { ",
                side, coal.treasury, math.floor(coal.stockFlightSeconds or 0)))
            for k, v in pairs(coal.unlockedBlueprints) do
                if v then append(string.format("[%q] = true, ", k)) end
            end
            append("} },\n")
        end
        append("  },\n")
        append("  sectors = {\n")
        for sname, sec in pairs(BF.State.sectors) do
            append(string.format("    [%q] = { side = %d, level = %d, status = %q, holdTimer = %d, holdingSide = %d },\n",
                sname, sec.side, sec.level or 1,
                sec.status, sec.holdTimer or 0, sec.holdingSide or 0))
        end
        append("  }\n")
        append("}\n")
        -- The trusted server hook validates and persists this fixed-format data.
        BF.PendingSavePayload = table.concat(out)
    end)
end

function BF.LoadState()
    BF.PersistentStateLoaded = false
    pcall(function()
        local state = dofile(STATE_FILE)
        if state and state.coalitions then
            for side, savedCoal in pairs(state.coalitions) do
                if BF.State.coalitions[side] then
                    local coal = BF.State.coalitions[side]
                    coal.treasury = savedCoal.treasury or coal.treasury
                    -- Retain the old field for save compatibility; it no longer gates research.
                    coal.stockFlightSeconds = math.max(0, math.min(600,
                        math.floor(tonumber(savedCoal.stock_flight_seconds) or 0)))
                    coal.unlockedBlueprints = savedCoal.unlocked or {}
                end
            end
            BF.Log("BATTLEFRONT: Loaded coalition treasuries and blueprints from persistent state.")
        end
        if state and state.sectors then
            for sname, savedSec in pairs(state.sectors) do
                if BF.State.sectors[sname] then
                    BF.State.sectors[sname].side = savedSec.side or BF.State.sectors[sname].side
                    BF.State.sectors[sname].level = savedSec.level or 1
                    local lvl = BF.State.sectors[sname].level
                    local baseInc = BF.State.sectors[sname].baseIncome or 2
                    BF.State.sectors[sname].income = math.floor(baseInc * (BF.Config.upgradeMultipliers[lvl] or 1.0))
                    local baseBty = BF.State.sectors[sname].baseBounty or 110
                    BF.State.sectors[sname].captureBounty = math.floor(baseBty * (1 + (lvl - 1) * 0.75))
                    BF.State.sectors[sname].status = savedSec.status or BF.State.sectors[sname].status
                    BF.State.sectors[sname].holdTimer = savedSec.holdTimer or BF.State.sectors[sname].holdTimer
                    BF.State.sectors[sname].holdingSide = savedSec.holdingSide or BF.State.sectors[sname].holdingSide
                end
            end
            BF.Log("BATTLEFRONT: Loaded sector control and status from persistent state.")
        end
        BF.PersistentStateLoaded = type(state.coalitions) == "table" and type(state.sectors) == "table"
    end)
end
