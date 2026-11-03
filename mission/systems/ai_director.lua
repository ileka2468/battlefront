-- ==============================================================================
-- BATTLEFRONT AIR WAR: 15 v 15 AUTONOMOUS AI CAMPAIGN DIRECTOR (30 COMBAT AIRCRAFT)
-- ==============================================================================
-- Coordinates a persistent, dynamic 15 v 15 air war between BLUFOR and REDFOR.
-- Features:
--   1. Dynamic Tech Tree & Research Rules: Starts with Tier 1 baseline aircraft
--      (F-15C, F-16C, Su-27, MiG-29S, A-10A, Su-25T). Upgrades to advanced
--      airframes (F-22A, F-23A, F-117A, Su-57, J-20A, Su-35S, Su-34) ONLY
--      when unlocked via coalition R&D research.
--   2. Multi-Quadrant 15 v 15 Fleet Distribution:
--      Maintains 6 Fighters (3x 2-ship CAP flights), 4 Bombers (2x 2-ship Strikes),
--      2 Escorts (1x 2-ship), 2 SEAD jets (1x 2-ship), and 1 Logistics helo per side.
--      Spreads the air war evenly across NW, NE, SW, SE, and the Central Frontline!
--   3. Precision Bombing & Strike Execution:
--      Guarantees dive-bombing passes with unguided iron bombs (Mk-82s, OFAB-250)
--      and level precision drops for stealth penetrators (F-117A GBU-27).
-- ==============================================================================

Battlefront = Battlefront or {}
local BF = Battlefront

BF.AIDirector = BF.AIDirector or {}
local Director = BF.AIDirector

local SIDE_RED = BF.SIDE_RED or 1
local SIDE_BLUE = BF.SIDE_BLUE or 2

local COUNTRY_BLUE = country.id.USA
local COUNTRY_RED = country.id.RUSSIA

Director.initialized = false
Director.activeGroups = { [1] = {}, [2] = {} }
Director.slotCooldowns = { [1] = {}, [2] = {} }
Director.roleCooldowns = { [1] = {}, [2] = {} }
Director.groupCounter = 5000
Director.researchReadyAt = {}

Director.config = {
    respawnCooldown = 90,        -- 90s replacement scramble
    capOrbitAltitude = 6500,     -- FL210
    strikeIngressSpeed = 240,    -- ~470 kts
    heloIngressSpeed = 65,       -- ~130 kts
}

local function log(msg)
    if BF.Log then BF.Log(msg) else env.info(msg) end
end

-- ------------------------------------------------------------------------------
-- 1. QUADRANT STAGING BASES & PATROL ANCHORS (Contention Multi-Front Doctrine)
-- ------------------------------------------------------------------------------
Director.QUADRANT_STAGING = {
    -- Quadrant 1: North-West (REDFOR Coastal & Kuban Foothills)
    ["NW"] = {
        [SIDE_RED]  = { x = -7349,   z = 293712, heading = 3.14, name = "Krymsk Airbase" },
        [SIDE_BLUE] = { x = -60000,  z = 310000, heading = 0.8,  name = "NW Offshore Ingress" }
    },
    -- Quadrant 2: North-East (REDFOR Central Plains & Mountain Approaches)
    ["NE"] = {
        [SIDE_RED]  = { x = -52089,  z = 707418, heading = 3.8,  name = "Mineralnye Vody Airbase" },
        [SIDE_BLUE] = { x = -160000, z = 720000, heading = 0.8,  name = "NE Mountain Pass Ingress" }
    },
    -- Quadrant 3: South-West (BLUFOR Coastal & Abkhazia Pass)
    ["SW"] = {
        [SIDE_BLUE] = { x = -165163, z = 460901, heading = 5.5,  name = "Sochi-Adler Airbase" },
        [SIDE_RED]  = { x = -110000, z = 410000, heading = 2.4,  name = "SW Coastal Ridge Ingress" }
    },
    -- Quadrant 4: South-East (BLUFOR Central Georgia & Valley Approaches)
    ["SE"] = {
        [SIDE_BLUE] = { x = -281903, z = 648379, heading = 0.8,  name = "Senaki-Kolkhi Airbase" },
        [SIDE_RED]  = { x = -190000, z = 670000, heading = 3.9,  name = "SE Roki Pass Ingress" }
    },
    -- Central Contested Frontline Meridian
    ["CENTER"] = {
        [SIDE_RED]  = { x = -27625,  z = 457047, heading = 3.14, name = "Maykop Airbase" },
        [SIDE_BLUE] = { x = -195650, z = 515898, heading = 0.8,  name = "Gudauta Airbase" }
    }
}

-- Forward combat patrol anchors (positioned across the contested frontline)
Director.QUADRANT_PATROLS = {
    ["NW"] = {
        [SIDE_RED]  = { x = -135000, z = 400000, name = "NW Forward Patrol (Kuban/Coast)" },
        [SIDE_BLUE] = { x = -195000, z = 400000, name = "SW Forward Patrol (Sochi/Gudauta)" }
    },
    ["NE"] = {
        [SIDE_RED]  = { x = -135000, z = 740000, name = "NE Forward Patrol (MinVody/Nalchik)" },
        [SIDE_BLUE] = { x = -195000, z = 740000, name = "SE Forward Patrol (Senaki/Kutaisi)" }
    },
    ["CENTER"] = {
        [SIDE_RED]  = { x = -145000, z = 580000, name = "Central Ridge Patrol (North)" },
        [SIDE_BLUE] = { x = -185000, z = 580000, name = "Central Ridge Patrol (South)" }
    }
}

function Director.GetStaging(side, quadrant)
    quadrant = quadrant or (side == SIDE_BLUE and "SW" or "NE")
    local quadData = Director.QUADRANT_STAGING[quadrant] or Director.QUADRANT_STAGING["SW"]
    return quadData[side] or { x = -200000, z = 500000, heading = 0.78 }
end

-- ------------------------------------------------------------------------------
-- 2. CAMPAIGN TECH TREE TEMPLATES & DYNAMIC BLUEPRINT RESOLUTION
-- ------------------------------------------------------------------------------

-- Baseline Tier 1 Roster (Unlocked at Minute 0)
local BASELINE_TEMPLATES = {
    [SIDE_BLUE] = {
        ["F-15C_CAP"] = {
            role = "CAP", type = "F-15C", count = 2, name = "BLUE_AI_CAP_F15", skill = "High",
            payload = { fuel = 6100, flare = 60, chaff = 60, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" }, -- AIM-120C
                    [3] = { ["CLSID"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}", ["clsid"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}" }, -- AIM-9M
                    [4] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" }, -- AIM-120C
                    [5] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" }, -- AIM-120C
                    [6] = { ["CLSID"] = "{E1F29B21-F291-4589-9FD8-3272EEC69506}", ["clsid"] = "{E1F29B21-F291-4589-9FD8-3272EEC69506}" }, -- 600-gal Centerline Fuel Tank
                    [7] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" }, -- AIM-120C
                    [8] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" }, -- AIM-120C
                    [9] = { ["CLSID"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}", ["clsid"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}" }, -- AIM-9M
                    [11] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" } -- AIM-120C
                } }
        },
        ["F-16C_ESCORT"] = {
            role = "ESCORT", type = "F-16C_50", count = 2, name = "BLUE_AI_ESCORT", skill = "Excellent",
            payload = { fuel = 3200, flare = 60, chaff = 60, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" }, -- AIM-120C Left Wingtip
                    [2] = { ["CLSID"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}", ["clsid"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}" }, -- AIM-9M Left Outboard
                    [3] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" }, -- AIM-120C Left Midboard
                    [4] = { ["CLSID"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}", ["clsid"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}" }, -- 370-gal Left Inboard Tank
                    [5] = { ["CLSID"] = "{6D21ECEA-F85B-4E8D-9D51-31DC9B8AA4EF}", ["clsid"] = "{6D21ECEA-F85B-4E8D-9D51-31DC9B8AA4EF}" }, -- 300-gal Centerline Tank
                    [6] = { ["CLSID"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}", ["clsid"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}" }, -- 370-gal Right Inboard Tank
                    [7] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" }, -- AIM-120C Right Midboard
                    [8] = { ["CLSID"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}", ["clsid"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}" }, -- AIM-9M Right Outboard
                    [9] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" }, -- AIM-120C Right Wingtip
                    [10] = { ["CLSID"] = "{AN_ASQ_213}", ["clsid"] = "{AN_ASQ_213}" }, -- HTS Pod
                    [11] = { ["CLSID"] = "{A111396E-D3E8-4b9c-8AC9-2432489304D5}", ["clsid"] = "{A111396E-D3E8-4b9c-8AC9-2432489304D5}" } -- LITENING TGP
                } }
        },
        ["A-10A_STRIKE"] = {
            role = "STRIKE", type = "A-10A", count = 2, name = "BLUE_AI_STRIKE_A10", skill = "High",
            payload = { fuel = 5000, flare = 120, chaff = 120, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{6D21ECEA-F85B-4E8D-9D51-31DC9B8AA4EF}", ["clsid"] = "{6D21ECEA-F85B-4E8D-9D51-31DC9B8AA4EF}" }, -- ALQ-131 ECM Pod
                    [2] = { ["CLSID"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}", ["clsid"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}" }, -- Mk-82
                    [3] = { ["CLSID"] = "{E6A6262A-CA08-4B3D-B030-E1A993B98452}", ["clsid"] = "{E6A6262A-CA08-4B3D-B030-E1A993B98452}" }, -- 2x AGM-65D Maverick
                    [4] = { ["CLSID"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}", ["clsid"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}" }, -- Mk-82
                    [5] = { ["CLSID"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}", ["clsid"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}" }, -- Mk-82
                    [7] = { ["CLSID"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}", ["clsid"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}" }, -- Mk-82
                    [8] = { ["CLSID"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}", ["clsid"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}" }, -- Mk-82
                    [9] = { ["CLSID"] = "{E6A6262A-CA08-4B3D-B030-E1A993B98453}", ["clsid"] = "{E6A6262A-CA08-4B3D-B030-E1A993B98453}" }, -- 2x AGM-65D Maverick
                    [10] = { ["CLSID"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}", ["clsid"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}" }, -- Mk-82
                    [11] = { ["CLSID"] = "{DB434044-F5D0-4F1F-9BA9-B73027E18DD3}", ["clsid"] = "{DB434044-F5D0-4F1F-9BA9-B73027E18DD3}" } -- 2x AIM-9M Sidewinder
                } }
        },
        ["A-10C_STRIKE"] = {
            role = "STRIKE", type = "A-10C", count = 2, name = "BLUE_AI_STRIKE_A10C", skill = "Excellent",
            payload = { fuel = 5000, flare = 120, chaff = 120, gun = 100,
                pylons = {
                    [1]  = { ["CLSID"] = "ALQ_184", ["clsid"] = "ALQ_184" }, -- ALQ-184 ECM Pod
                    [3]  = { ["CLSID"] = "{E6A6262A-CA08-4B3D-B030-E1A993B98452}", ["clsid"] = "{E6A6262A-CA08-4B3D-B030-E1A993B98452}" }, -- 2x AGM-65D Maverick
                    [4]  = { ["CLSID"] = "{5335D97A-35A5-4643-9D9B-026C75961E52}", ["clsid"] = "{5335D97A-35A5-4643-9D9B-026C75961E52}" }, -- CBU-97 SFW
                    [5]  = { ["CLSID"] = "{CBU-87}", ["clsid"] = "{CBU-87}" }, -- CBU-87
                    [7]  = { ["CLSID"] = "{CBU-87}", ["clsid"] = "{CBU-87}" }, -- CBU-87
                    [8]  = { ["CLSID"] = "{5335D97A-35A5-4643-9D9B-026C75961E52}", ["clsid"] = "{5335D97A-35A5-4643-9D9B-026C75961E52}" }, -- CBU-97 SFW
                    [9]  = { ["CLSID"] = "{E6A6262A-CA08-4B3D-B030-E1A993B98453}", ["clsid"] = "{E6A6262A-CA08-4B3D-B030-E1A993B98453}" }, -- 2x AGM-65D Maverick
                    [10] = { ["CLSID"] = "{A111396E-D3E8-4b9c-8AC9-2432489304D5}", ["clsid"] = "{A111396E-D3E8-4b9c-8AC9-2432489304D5}" }, -- LITENING AT TGP
                    [11] = { ["CLSID"] = "{DB434044-F5D0-4F1F-9BA9-B73027E18DD3}", ["clsid"] = "{DB434044-F5D0-4F1F-9BA9-B73027E18DD3}" }  -- 2x AIM-9M
                } }
        },
        ["FA-18C_STRIKE"] = {
            role = "STRIKE", type = "FA-18C_hornet", count = 2, name = "BLUE_AI_STRIKE_F18", skill = "High",
            payload = { fuel = 4900, flare = 60, chaff = 60, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}", ["clsid"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}" }, -- AIM-9X
                    [2] = { ["CLSID"] = "{BRU55_2*GBU-38}", ["clsid"] = "{BRU55_2*GBU-38}" },                                               -- 2x GBU-38
                    [3] = { ["CLSID"] = "{BRU33_2X_GBU-12}", ["clsid"] = "{BRU33_2X_GBU-12}" },                                             -- 2x GBU-12
                    [4] = { ["CLSID"] = "{AN_ASQ_228}", ["clsid"] = "{AN_ASQ_228}" },                                                       -- ATFLIR Pod
                    [5] = { ["CLSID"] = "{FPU_8A_FUEL_TANK}", ["clsid"] = "{FPU_8A_FUEL_TANK}" },                                           -- Centerline Fuel
                    [6] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" }, -- AIM-120C
                    [7] = { ["CLSID"] = "{BRU33_2X_GBU-12}", ["clsid"] = "{BRU33_2X_GBU-12}" },                                             -- 2x GBU-12
                    [8] = { ["CLSID"] = "{BRU55_2*GBU-38}", ["clsid"] = "{BRU55_2*GBU-38}" },                                               -- 2x GBU-38
                    [9] = { ["CLSID"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}", ["clsid"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}" }  -- AIM-9X
                } }
        },
        ["A-4E_STRIKE"] = {
            role = "STRIKE", type = "A-4E-C", count = 2, name = "BLUE_AI_STRIKE_A4", skill = "High",
            payload = { fuel = 2400, flare = 60, chaff = 60, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}", ["clsid"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}" },
                    [2] = { ["CLSID"] = "{Mk-82_TER_2_L}", ["clsid"] = "{Mk-82_TER_2_L}" },
                    [3] = { ["CLSID"] = "{Mk-82_MER_6_C}", ["clsid"] = "{Mk-82_MER_6_C}" },
                    [4] = { ["CLSID"] = "{Mk-82_TER_2_R}", ["clsid"] = "{Mk-82_TER_2_R}" },
                    [5] = { ["CLSID"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}", ["clsid"] = "{BCE4E030-38E9-423E-98ED-24BE3DA87C32}" }
                } }
        },
        ["F-16C_SEAD"] = {
            role = "SEAD", type = "F-16C_50", count = 2, name = "BLUE_AI_SEAD_F16", skill = "Excellent",
            payload = { fuel = 3200, flare = 60, chaff = 60, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" }, -- AIM-120C Left Wingtip
                    [2] = { ["CLSID"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}", ["clsid"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}" }, -- AIM-9M Left Outboard
                    [3] = { ["CLSID"] = "{B06DD79A-F21E-4EB9-BD9D-AB3844618C93}", ["clsid"] = "{B06DD79A-F21E-4EB9-BD9D-AB3844618C93}" }, -- AGM-88C HARM Left Midboard
                    [4] = { ["CLSID"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}", ["clsid"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}" }, -- 370-gal Left Inboard Tank
                    [5] = { ["CLSID"] = "{8A0BE8AE-58D4-4572-9263-3144C0D06364}", ["clsid"] = "{8A0BE8AE-58D4-4572-9263-3144C0D06364}" }, -- ALQ-184 ECM Pod Centerline
                    [6] = { ["CLSID"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}", ["clsid"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}" }, -- 370-gal Right Inboard Tank
                    [7] = { ["CLSID"] = "{B06DD79A-F21E-4EB9-BD9D-AB3844618C93}", ["clsid"] = "{B06DD79A-F21E-4EB9-BD9D-AB3844618C93}" }, -- AGM-88C HARM Right Midboard
                    [8] = { ["CLSID"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}", ["clsid"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}" }, -- AIM-9M Right Outboard
                    [9] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" }, -- AIM-120C Right Wingtip
                    [10] = { ["CLSID"] = "{AN_ASQ_213}", ["clsid"] = "{AN_ASQ_213}" }, -- HTS Pod
                    [11] = { ["CLSID"] = "{A111396E-D3E8-4b9c-8AC9-2432489304D5}", ["clsid"] = "{A111396E-D3E8-4b9c-8AC9-2432489304D5}" } -- LITENING TGP
                } }
        },
        ["FA-18C_SEAD"] = {
            role = "SEAD", type = "FA-18C_hornet", count = 2, name = "BLUE_AI_SEAD_F18", skill = "Excellent",
            payload = { fuel = 4900, flare = 60, chaff = 60, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}", ["clsid"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}" }, -- AIM-9X
                    [2] = { ["CLSID"] = "{B06DD79A-F21E-4EB9-BD9D-AB3844618C93}", ["clsid"] = "{B06DD79A-F21E-4EB9-BD9D-AB3844618C93}" }, -- AGM-88C HARM
                    [3] = { ["CLSID"] = "{B06DD79A-F21E-4EB9-BD9D-AB3844618C93}", ["clsid"] = "{B06DD79A-F21E-4EB9-BD9D-AB3844618C93}" }, -- AGM-88C HARM
                    [4] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" }, -- AIM-120C
                    [5] = { ["CLSID"] = "{FPU_8A_FUEL_TANK}", ["clsid"] = "{FPU_8A_FUEL_TANK}" },                                             -- Centerline Fuel
                    [6] = { ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", ["clsid"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" }, -- AIM-120C
                    [7] = { ["CLSID"] = "{B06DD79A-F21E-4EB9-BD9D-AB3844618C93}", ["clsid"] = "{B06DD79A-F21E-4EB9-BD9D-AB3844618C93}" }, -- AGM-88C HARM
                    [8] = { ["CLSID"] = "{B06DD79A-F21E-4EB9-BD9D-AB3844618C93}", ["clsid"] = "{B06DD79A-F21E-4EB9-BD9D-AB3844618C93}" }, -- AGM-88C HARM
                    [9] = { ["CLSID"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}", ["clsid"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}" }  -- AIM-9X
                } }
        },
        ["UH-1H_CARGO"] = {
            role = "LOGISTICS", type = "UH-1H", count = 2, name = "BLUE_AI_CARGO_HUEY", skill = "Good",
            category = Group.Category.HELICOPTER,
            payload = { fuel = 550, flare = 0, chaff = 0, gun = 0, pylons = {} }
        },
        ["UH-60L_CARGO"] = {
            role = "LOGISTICS", type = "UH-60L", count = 2, name = "BLUE_AI_CARGO", skill = "Good", category = Group.Category.HELICOPTER,
            payload = { fuel = 1400, flare = 60, chaff = 60,
                pylons = {
                    [1] = { ["CLSID"] = "{UH60_FUEL_TANK_230}", ["clsid"] = "{UH60_FUEL_TANK_230}" },
                    [3] = { ["CLSID"] = "{UH60_SEAT_GUNNER_L}", ["clsid"] = "{UH60_SEAT_GUNNER_L}" },
                    [4] = { ["CLSID"] = "{UH60_SEAT_CARGO_ALL}", ["clsid"] = "{UH60_SEAT_CARGO_ALL}" },
                    [5] = { ["CLSID"] = "{UH60_SEAT_GUNNER_R}", ["clsid"] = "{UH60_SEAT_GUNNER_R}" },
                    [7] = { ["CLSID"] = "{UH60_FUEL_TANK_230}", ["clsid"] = "{UH60_FUEL_TANK_230}" }
                } }
        }
    },
    [SIDE_RED] = {
        ["Su-27_CAP"] = {
            role = "CAP", type = "Su-27", count = 2, name = "RED_AI_CAP_SU27", skill = "High",
            payload = { fuel = 9400, flare = 96, chaff = 96, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" }, -- R-73 Left Wingtip
                    [2] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" }, -- R-73 Left Outboard
                    [3] = { ["CLSID"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}", ["clsid"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}" }, -- R-27ET Left Wing Inboard
                    [4] = { ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}", ["clsid"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}" }, -- R-27ER Left Nacelle
                    [5] = { ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}", ["clsid"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}" }, -- R-27ER Center Tandem Fwd
                    [6] = { ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}", ["clsid"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}" }, -- R-27ER Center Tandem Aft
                    [7] = { ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}", ["clsid"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}" }, -- R-27ER Right Nacelle
                    [8] = { ["CLSID"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}", ["clsid"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}" }, -- R-27ET Right Wing Inboard
                    [9] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" }, -- R-73 Right Outboard
                    [10] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" } -- R-73 Right Wingtip
                } }
        },
        ["Su-27_ESCORT"] = {
            role = "ESCORT", type = "Su-27", count = 2, name = "RED_AI_ESCORT_SU27", skill = "Excellent",
            payload = { fuel = 9400, flare = 96, chaff = 96, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" }, -- R-73 Left Wingtip
                    [2] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" }, -- R-73 Left Outboard
                    [3] = { ["CLSID"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}", ["clsid"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}" }, -- R-27ET Left Wing Inboard
                    [4] = { ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}", ["clsid"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}" }, -- R-27ER Left Nacelle
                    [5] = { ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}", ["clsid"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}" }, -- R-27ER Center Tandem Fwd
                    [6] = { ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}", ["clsid"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}" }, -- R-27ER Center Tandem Aft
                    [7] = { ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}", ["clsid"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}" }, -- R-27ER Right Nacelle
                    [8] = { ["CLSID"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}", ["clsid"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}" }, -- R-27ET Right Wing Inboard
                    [9] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" }, -- R-73 Right Outboard
                    [10] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" } -- R-73 Right Wingtip
                } }
        },
        ["MiG-29S_CAP"] = {
            role = "CAP", type = "MiG-29S", count = 2, name = "RED_AI_CAP_MIG29", skill = "High",
            payload = { fuel = 3500, flare = 60, chaff = 60, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" }, -- R-73 Outboard Left
                    [2] = { ["CLSID"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}", ["clsid"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}" }, -- R-77 Midboard Left
                    [3] = { ["CLSID"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}", ["clsid"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}" }, -- R-77 Inboard Left
                    [4] = { ["CLSID"] = "{2BEC576B-CDF5-4B7F-961F-B0FA4312B841}", ["clsid"] = "{2BEC576B-CDF5-4B7F-961F-B0FA4312B841}" }, -- 1500L Centerline Fuel Tank
                    [5] = { ["CLSID"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}", ["clsid"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}" }, -- R-77 Inboard Right
                    [6] = { ["CLSID"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}", ["clsid"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}" }, -- R-77 Midboard Right
                    [7] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" }  -- R-73 Outboard Right
                } }
        },
        ["Su-25T_STRIKE"] = {
            role = "STRIKE", type = "Su-25T", count = 2, name = "RED_AI_STRIKE_SU25T", skill = "High",
            payload = { fuel = 3800, flare = 128, chaff = 128, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82D}", ["clsid"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82D}" },
                    [2] = { ["CLSID"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}" },
                    [3] = { ["CLSID"] = "{79D73885-0801-45a9-917F-C90FE1CE3DFC}", ["clsid"] = "{79D73885-0801-45a9-917F-C90FE1CE3DFC}" },
                    [4] = { ["CLSID"] = "{F789E86A-EE2E-4E6B-B81E-D5E5F903B6ED}", ["clsid"] = "{F789E86A-EE2E-4E6B-B81E-D5E5F903B6ED}" },
                    [5] = { ["CLSID"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}", ["clsid"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}" },
                    [7] = { ["CLSID"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}", ["clsid"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}" },
                    [8] = { ["CLSID"] = "{F789E86A-EE2E-4E6B-B81E-D5E5F903B6ED}", ["clsid"] = "{F789E86A-EE2E-4E6B-B81E-D5E5F903B6ED}" },
                    [9] = { ["CLSID"] = "{79D73885-0801-45a9-917F-C90FE1CE3DFC}", ["clsid"] = "{79D73885-0801-45a9-917F-C90FE1CE3DFC}" },
                    [10] = { ["CLSID"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}" },
                    [11] = { ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82C}", ["clsid"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82C}" }
                } }
        },
        ["Su-25T_SEAD"] = {
            role = "SEAD", type = "Su-25T", count = 2, name = "RED_AI_SEAD", skill = "Excellent",
            payload = { fuel = 3800, flare = 128, chaff = 128, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82D}", ["clsid"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82D}" },
                    [2] = { ["CLSID"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}" },
                    [3] = { ["CLSID"] = "{79D73885-0801-45a9-917F-C90FE1CE3DFC}", ["clsid"] = "{79D73885-0801-45a9-917F-C90FE1CE3DFC}" },
                    [4] = { ["CLSID"] = "{752AF1D2-EBCC-4bd7-A1E7-2357F5601C70}", ["clsid"] = "{752AF1D2-EBCC-4bd7-A1E7-2357F5601C70}" },
                    [5] = { ["CLSID"] = "{B5CA9846-776E-4230-B4FD-8BCC9BFB1676}", ["clsid"] = "{B5CA9846-776E-4230-B4FD-8BCC9BFB1676}" },
                    [6] = { ["CLSID"] = "{0519A264-0AB6-11d6-9193-00A0249B6F00}", ["clsid"] = "{0519A264-0AB6-11d6-9193-00A0249B6F00}" },
                    [7] = { ["CLSID"] = "{B5CA9846-776E-4230-B4FD-8BCC9BFB1676}", ["clsid"] = "{B5CA9846-776E-4230-B4FD-8BCC9BFB1676}" },
                    [8] = { ["CLSID"] = "{752AF1D2-EBCC-4bd7-A1E7-2357F5601C70}", ["clsid"] = "{752AF1D2-EBCC-4bd7-A1E7-2357F5601C70}" },
                    [9] = { ["CLSID"] = "{79D73885-0801-45a9-917F-C90FE1CE3DFC}", ["clsid"] = "{79D73885-0801-45a9-917F-C90FE1CE3DFC}" },
                    [10] = { ["CLSID"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}" },
                    [11] = { ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82C}", ["clsid"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82C}" }
                } }
        },
        ["Su-34_STRIKE"] = {
            role = "STRIKE", type = "Su-34", count = 2, name = "RED_AI_STRIKE_SU34", skill = "High",
            payload = { fuel = 11400, flare = 120, chaff = 120, gun = 100,
                pylons = {
                    [1]  = { ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82F}", ["clsid"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82F}" }, -- ECM Pod Left Wingtip
                    [2]  = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" }, -- R-73 Left Outboard
                    [3]  = { ["CLSID"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}", ["clsid"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}" }, -- KAB-500Kr
                    [4]  = { ["CLSID"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}", ["clsid"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}" }, -- KAB-500Kr
                    [5]  = { ["CLSID"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}", ["clsid"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}" }, -- FAB-250
                    [6]  = { ["CLSID"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}", ["clsid"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}" }, -- FAB-250
                    [7]  = { ["CLSID"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}", ["clsid"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}" }, -- FAB-250
                    [8]  = { ["CLSID"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}", ["clsid"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}" }, -- FAB-250
                    [9]  = { ["CLSID"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}", ["clsid"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}" }, -- KAB-500Kr
                    [10] = { ["CLSID"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}", ["clsid"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}" }, -- KAB-500Kr
                    [11] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" }, -- R-73 Right Outboard
                    [12] = { ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82A}", ["clsid"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82A}" }  -- ECM Pod Right Wingtip
                } }
        },
        ["Su-34_SEAD"] = {
            role = "SEAD", type = "Su-34", count = 2, name = "RED_AI_SEAD_SU34", skill = "Excellent",
            payload = { fuel = 11400, flare = 120, chaff = 120, gun = 100,
                pylons = {
                    [1]  = { ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82F}", ["clsid"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82F}" }, -- ECM Pod Left Wingtip
                    [2]  = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" }, -- R-73 Left Outboard
                    [3]  = { ["CLSID"] = "{X-31P}", ["clsid"] = "{X-31P}" },                                                                   -- Kh-31P Supersonic ARM
                    [4]  = { ["CLSID"] = "{X-31P}", ["clsid"] = "{X-31P}" },                                                                   -- Kh-31P Supersonic ARM
                    [6]  = { ["CLSID"] = "{9B25D316-0434-4954-868F-D51DB1A38DF0}", ["clsid"] = "{9B25D316-0434-4954-868F-D51DB1A38DF0}" }, -- R-27R BVR
                    [7]  = { ["CLSID"] = "{9B25D316-0434-4954-868F-D51DB1A38DF0}", ["clsid"] = "{9B25D316-0434-4954-868F-D51DB1A38DF0}" }, -- R-27R BVR
                    [9]  = { ["CLSID"] = "{X-31P}", ["clsid"] = "{X-31P}" },                                                                   -- Kh-31P Supersonic ARM
                    [10] = { ["CLSID"] = "{X-31P}", ["clsid"] = "{X-31P}" },                                                                   -- Kh-31P Supersonic ARM
                    [11] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" }, -- R-73 Right Outboard
                    [12] = { ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82A}", ["clsid"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82A}" }  -- ECM Pod Right Wingtip
                } }
        },
        ["Mi-24P_CARGO"] = {
            role = "LOGISTICS", type = "Mi-24P", count = 2, name = "RED_AI_CARGO", skill = "High", category = Group.Category.HELICOPTER,
            payload = { fuel = 1800, flare = 60, chaff = 60, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{9M114_2_L}", ["clsid"] = "{9M114_2_L}" },
                    [2] = { ["CLSID"] = "{B_8V20A_CM}", ["clsid"] = "{B_8V20A_CM}" },
                    [3] = { ["CLSID"] = "{B_8V20A_CM}", ["clsid"] = "{B_8V20A_CM}" },
                    [4] = { ["CLSID"] = "{9M114_2_R}", ["clsid"] = "{9M114_2_R}" }
                } }
        }
    }
}

-- Advanced R&D Blueprints (Unlocked via research)
local RESEARCH_TEMPLATES = {
    [SIDE_BLUE] = {
        ["F-22A"] = {
            role = "CAP", type = "F-22A", count = 2, name = "BLUE_AI_STEALTH_F22", skill = "Excellent",
            payload = { fuel = 6100, flare = 120, chaff = 120, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{AIM9X-BLKII}", ["clsid"] = "{AIM9X-BLKII}" },
                    [11] = { ["CLSID"] = "{AIM9X-BLKII}", ["clsid"] = "{AIM9X-BLKII}" },
                    [3] = { ["CLSID"] = "{AIM-120D-3}", ["clsid"] = "{AIM-120D-3}" },
                    [4] = { ["CLSID"] = "{AIM-120D-3}", ["clsid"] = "{AIM-120D-3}" },
                    [5] = { ["CLSID"] = "{AIM-120D-3}", ["clsid"] = "{AIM-120D-3}" },
                    [7] = { ["CLSID"] = "{AIM-120D-3}", ["clsid"] = "{AIM-120D-3}" },
                    [8] = { ["CLSID"] = "{AIM-120D-3}", ["clsid"] = "{AIM-120D-3}" },
                    [9] = { ["CLSID"] = "{AIM-120D-3}", ["clsid"] = "{AIM-120D-3}" }
                } }
        },
        ["F-117A"] = {
            role = "STRIKE", type = "F-117-NightHawk", count = 2, name = "BLUE_AI_STEALTH_STRIKE", skill = "High",
            payload = { fuel = 5500, flare = 60, chaff = 60, gun = 0,
                pylons = {
                    [1] = { ["CLSID"] = "{EF0A9419-01D6-473B-99A3-BEBDB923B14D}", ["clsid"] = "{EF0A9419-01D6-473B-99A3-BEBDB923B14D}" },
                    [2] = { ["CLSID"] = "{EF0A9419-01D6-473B-99A3-BEBDB923B14D}", ["clsid"] = "{EF0A9419-01D6-473B-99A3-BEBDB923B14D}" }
                } }
        }
    },
    [SIDE_RED] = {
        ["Su-30SM"] = {
            role = "ESCORT", type = "Su-30SM", count = 2, name = "RED_AI_ESCORT_SU30", skill = "Excellent",
            payload = { fuel = 9400, flare = 96, chaff = 96, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}", ["clsid"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}" },
                    [2] = { ["CLSID"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}", ["clsid"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}" },
                    [3] = { ["CLSID"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}", ["clsid"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}" },
                    [4] = { ["CLSID"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}", ["clsid"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}" },
                    [5] = { ["CLSID"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}", ["clsid"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}" },
                    [6] = { ["CLSID"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}", ["clsid"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}" }
                } }
        },
        ["Su-34"] = {
            role = "STRIKE", type = "Su-34", count = 2, name = "RED_AI_STRIKE_SU34", skill = "High",
            payload = { fuel = 11400, flare = 120, chaff = 120, gun = 100,
                pylons = {
                    [1]  = { ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82F}", ["clsid"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82F}" }, -- L-175V Khibiny ECM Wingtip Left
                    [2]  = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" }, -- R-73 Self-Defense
                    [3]  = { ["CLSID"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}", ["clsid"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}" }, -- KAB-500Kr TV-Guided Bomb
                    [4]  = { ["CLSID"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}", ["clsid"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}" }, -- KAB-500Kr TV-Guided Bomb
                    [5]  = { ["CLSID"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}", ["clsid"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}" }, -- FAB-250 High Explosive Bomb
                    [6]  = { ["CLSID"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}", ["clsid"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}" }, -- FAB-250 High Explosive Bomb
                    [7]  = { ["CLSID"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}", ["clsid"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}" }, -- FAB-250 High Explosive Bomb
                    [8]  = { ["CLSID"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}", ["clsid"] = "{3C612111-C7AD-476E-8A8E-2485812F4E5C}" }, -- FAB-250 High Explosive Bomb
                    [9]  = { ["CLSID"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}", ["clsid"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}" }, -- KAB-500Kr TV-Guided Bomb
                    [10] = { ["CLSID"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}", ["clsid"] = "{FC56DF80-9B09-44C5-8976-DCFAFF219062}" }, -- KAB-500Kr TV-Guided Bomb
                    [11] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" }, -- R-73 Self-Defense
                    [12] = { ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82A}", ["clsid"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82A}" }  -- L-175V Khibiny ECM Wingtip Right
                } }
        },
        ["Su-35S"] = {
            role = "CAP", type = "Su-35S", count = 2, name = "RED_AI_CAP_SU35S", skill = "High",
            payload = { fuel = 11500, flare = 96, chaff = 96, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}", ["clsid"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}" },
                    [2] = { ["CLSID"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}", ["clsid"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}" },
                    [3] = { ["CLSID"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}", ["clsid"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}" },
                    [4] = { ["CLSID"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}", ["clsid"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}" },
                    [7] = { ["CLSID"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}", ["clsid"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}" },
                    [8] = { ["CLSID"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}", ["clsid"] = "{42F377FD-78DE-4841-8636-ECB8EB5F3255}" }
                } }
        },
        ["Su-57"] = {
            role = "CAP", type = "Su-57", count = 2, name = "RED_AI_STEALTH_SU57", skill = "Excellent",
            payload = { fuel = 10300, flare = 120, chaff = 120, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" },
                    [2] = { ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}", ["clsid"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" },
                    [3] = { ["CLSID"] = "{RVV-BD}", ["clsid"] = "{RVV-BD}" },
                    [4] = { ["CLSID"] = "{RVV-BD}", ["clsid"] = "{RVV-BD}" },
                    [5] = { ["CLSID"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}", ["clsid"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}" },
                    [6] = { ["CLSID"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}", ["clsid"] = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}" }
                } }
        },
        ["J-20A"] = {
            role = "CAP", type = "J-20A", count = 2, name = "RED_AI_STEALTH_J20A", skill = "Excellent",
            payload = { fuel = 11000, flare = 120, chaff = 120, gun = 100,
                pylons = {
                    [1] = { ["CLSID"] = "{J20A_PL-10E}", ["clsid"] = "{J20A_PL-10E}" },
                    [2] = { ["CLSID"] = "{J20A_PL-10E}", ["clsid"] = "{J20A_PL-10E}" },
                    [3] = { ["CLSID"] = "{J20A_PL15}", ["clsid"] = "{J20A_PL15}" },
                    [4] = { ["CLSID"] = "{J20A_PL15}", ["clsid"] = "{J20A_PL15}" },
                    [5] = { ["CLSID"] = "{J20A_PL15}", ["clsid"] = "{J20A_PL15}" },
                    [6] = { ["CLSID"] = "{J20A_PL15}", ["clsid"] = "{J20A_PL15}" },
                    [7] = { ["CLSID"] = "{J20A_PL15}", ["clsid"] = "{J20A_PL15}" },
                    [8] = { ["CLSID"] = "{J20A_PL15}", ["clsid"] = "{J20A_PL15}" }
                } }
        }
    }
}

-- Resolve whether an advanced aircraft is unlocked via research, or fallback to baseline
function Director.ResolveTemplate(side, role)
    local coal = BF.State and BF.State.coalitions and BF.State.coalitions[side]
    local unlocked = coal and coal.unlockedBlueprints or {}

    if side == SIDE_BLUE then
        if role == "CAP" then
            if unlocked["F-22A"] then
                return RESEARCH_TEMPLATES[SIDE_BLUE]["F-22A"]
            else
                return BASELINE_TEMPLATES[SIDE_BLUE]["F-15C_CAP"]
            end
        elseif role == "ESCORT" then
            return BASELINE_TEMPLATES[SIDE_BLUE]["F-16C_ESCORT"]
        elseif role == "STRIKE" then
            if unlocked["F-117A"] then
                return RESEARCH_TEMPLATES[SIDE_BLUE]["F-117A"]
            else
                local r = math.random(1, 10)
                if r <= 6 and unlocked["A-4E-C"] then
                    return BASELINE_TEMPLATES[SIDE_BLUE]["A-4E_STRIKE"]
                elseif r <= 8 then
                    return BASELINE_TEMPLATES[SIDE_BLUE]["A-10A_STRIKE"]
                else
                    return BASELINE_TEMPLATES[SIDE_BLUE]["FA-18C_STRIKE"]
                end
            end
        elseif role == "SEAD" then
            -- High-speed multirole SEAD parity (F-16C HARM / F/A-18C HARM)
            return (math.random(1, 2) == 1) and BASELINE_TEMPLATES[SIDE_BLUE]["FA-18C_SEAD"] or BASELINE_TEMPLATES[SIDE_BLUE]["F-16C_SEAD"]
        elseif role == "LOGISTICS" then
            local key = unlocked["UH-60L"] and "UH-60L_CARGO" or "UH-1H_CARGO"
            return BASELINE_TEMPLATES[SIDE_BLUE][key]
        end
    else -- SIDE_RED
        if role == "CAP" then
            if unlocked["J-20A"] then
                return RESEARCH_TEMPLATES[SIDE_RED]["J-20A"]
            elseif unlocked["Su-57"] then
                return RESEARCH_TEMPLATES[SIDE_RED]["Su-57"]
            elseif unlocked["Su-35S"] then
                return RESEARCH_TEMPLATES[SIDE_RED]["Su-35S"]
            else
                return (math.random(1, 2) == 1) and BASELINE_TEMPLATES[SIDE_RED]["Su-27_CAP"] or BASELINE_TEMPLATES[SIDE_RED]["MiG-29S_CAP"]
            end
        elseif role == "ESCORT" then
            if unlocked["Su-30SM"] then
                return RESEARCH_TEMPLATES[SIDE_RED]["Su-30SM"]
            else
                return BASELINE_TEMPLATES[SIDE_RED]["Su-27_ESCORT"]
            end
        elseif role == "STRIKE" then
            -- Tier 1 Baseline Strike: Su-25T armored ground attack; Su-34 unlocked only via R&D
            if unlocked["Su-34"] then
                return RESEARCH_TEMPLATES[SIDE_RED]["Su-34"]
            else
                return BASELINE_TEMPLATES[SIDE_RED]["Su-25T_STRIKE"]
            end
        elseif role == "SEAD" then
            -- Tier 1 Baseline SEAD: Su-25T tactical SEAD; Su-34 supersonic SEAD unlocked via R&D
            if unlocked["Su-34"] then
                return BASELINE_TEMPLATES[SIDE_RED]["Su-34_SEAD"]
            else
                return BASELINE_TEMPLATES[SIDE_RED]["Su-25T_SEAD"]
            end
        elseif role == "LOGISTICS" then
            return BASELINE_TEMPLATES[SIDE_RED]["Mi-24P_CARGO"]
        end
    end

    return BASELINE_TEMPLATES[side]["F-15C_CAP"] or BASELINE_TEMPLATES[side]["Su-27_CAP"]
end

-- ------------------------------------------------------------------------------
-- 3. AUTONOMOUS CAMPAIGN RESEARCH ENGINE (AI Purchases Blueprints)
-- ------------------------------------------------------------------------------
function Director.EvaluateResearch(side, now)
    local cfg = BF.Config
    if not cfg or cfg.allowAutonomousResearch ~= true then return false, "disabled" end
    local coal = BF.State and BF.State.coalitions and BF.State.coalitions[side]
    local researchQueue = cfg.autonomousResearchOrder[side]
    if not coal or not researchQueue then return false, "unknown_coalition" end

    local due = Director.researchReadyAt[side]
    if not due then
        Director.researchReadyAt[side] = now + cfg.autonomousResearchInterval
        return false, "not_due"
    end
    if now < due then return false, "not_due" end
    Director.researchReadyAt[side] = now + cfg.autonomousResearchInterval

    -- Save for the next priority instead of exhausting the budget on random cheaper upgrades.
    for _, bpKey in ipairs(researchQueue) do
        if cfg.blueprints[side][bpKey] and not coal.unlockedBlueprints[bpKey] then
            return BF.PurchaseBlueprint(side, bpKey, "director")
        end
    end
    return false, "complete"
end

-- ------------------------------------------------------------------------------
-- 4. TARGET SECTOR SELECTION (Distributed Multi-Front Doctrine)
-- ------------------------------------------------------------------------------
function Director.SelectTargetSector(role, side, preferredQuadrant)
    if not BF.State or not BF.State.sectors then return nil end

    local enemySide = (side == SIDE_BLUE) and SIDE_RED or SIDE_BLUE
    local targetQuad = preferredQuadrant

    -- Translate theater front to opposing enemy quadrant for offensive missions
    if role == "STRIKE" or role == "SEAD" then
        if preferredQuadrant == "NE" or preferredQuadrant == "SE" then
            targetQuad = (side == SIDE_BLUE) and "NE" or "SE"
        elseif preferredQuadrant == "NW" or preferredQuadrant == "SW" then
            targetQuad = (side == SIDE_BLUE) and "NW" or "SW"
        end
    end

    local candidates = {}

    for sName, sec in pairs(BF.State.sectors) do
        if not targetQuad or sec.quadrant == targetQuad then
            local score = 0
            if role == "LOGISTICS" then
                if sec.side == enemySide and sec.status == "HOLDING" then
                    score = 120
                elseif sec.side == side and (sec.underAttack or sec.status == "DEFENDED") then
                    score = 60
                end
            elseif role == "STRIKE" or role == "SEAD" then
                if sec.side == enemySide then
                    score = (sec.income or 2) * 10
                    if sName:find("Refinery") or sName:find("Fuel") then score = score + 40 end
                    if sName:find("Aerospace") or sName:find("Silicon") then score = score + 35 end
                    if sName:find("Munitions") or sName:find("Stronghold") then score = score + 30 end
                    if sec.underAttack then score = score + 25 end
                    table.insert(candidates, { name = sName, sec = sec, score = score })
                end
            else -- CAP / ESCORT
                score = 20
                if sec.underAttack then score = score + 100 end
                if sec.side == enemySide then score = score + 25 end
                table.insert(candidates, { name = sName, sec = sec, score = score })
            end
        end
    end

    table.sort(candidates, function(a, b) return a.score > b.score end)
    if candidates[1] then
        return candidates[1].sec
    end

    -- If no sector found in preferred quadrant, fallback to any valid enemy sector
    if targetQuad then
        return Director.SelectTargetSector(role, side, nil)
    end
    return nil
end

-- ------------------------------------------------------------------------------
-- 5. FLIGHT SPAWNING & WAYPOINT GENERATION
-- ------------------------------------------------------------------------------
function Director.SpawnFlight(side, role, targetSec, forceQuadrant, capSlot)
    local tmpl = Director.ResolveTemplate(side, role)
    if tmpl and not BF.Research.CanFieldAirframe(side, tmpl.type) then
        log("AI DIRECTOR: blocked unpurchased or unregistered airframe " .. tostring(tmpl.type))
        return false
    end
    if not tmpl then return end

    Director.groupCounter = Director.groupCounter + 1
    local grpId = Director.groupCounter
    local grpName = string.format("%s_%d", tmpl.name, grpId)

    local targetQuadrant = forceQuadrant or (targetSec and targetSec.quadrant) or (side == SIDE_BLUE and "SW" or "NE")
    local origin = Director.GetStaging(side, targetQuadrant)

    local cat = tmpl.category or Group.Category.AIRPLANE
    local countryId = (side == SIDE_BLUE) and COUNTRY_BLUE or COUNTRY_RED
    local sideName = (side == SIDE_BLUE) and "BLUFOR" or "REDFOR"

    local targetPos = (targetSec and targetSec.pos) or { x = origin.x + 40000, z = origin.z + 40000 }
    if assignedRole == "CAP" then
        local pQuad = (targetQuadrant == "CENTER") and "CENTER" or ((targetQuadrant == "NE" or targetQuadrant == "SE") and "NE" or "NW")
        if Director.QUADRANT_PATROLS[pQuad] and Director.QUADRANT_PATROLS[pQuad][side] then
            local pt = Director.QUADRANT_PATROLS[pQuad][side]
            targetPos = { x = pt.x, z = pt.z }
        end
    end

    local assignedRole = role or tmpl.role
    local isHelo = (cat == Group.Category.HELICOPTER)
    local isStrike = (assignedRole == "STRIKE" or assignedRole == "CAS")

    -- Anti-Conga-Line Tactical Lateral Dispersion:
    -- Spreads out flights across parallel combat lanes instead of flying in a single file line.
    local lateralSpread = ((grpId % 3) - 1) * 14000
    if assignedRole == "CAP" and capSlot then
        lateralSpread = (capSlot - 2) * 18000 -- Slot 1: -18km, Slot 2: 0, Slot 3: +18km
    end

    -- Tactical Flight Profiles:
    -- CAP: FL250 (7,500m) for maximum BVR missile kinematic envelope and radar line of sight.
    -- STRIKE / CAS: Low-level terrain-masking ingress (450m AGL / ~1,400 ft) to hide in pulse-Doppler ground clutter and avoid BVR radar locks!
    -- ESCORT: FL180 (5,500m) forward fighter sweep to sanitize the corridor.
    -- SEAD: FL150 (4,500m) optimal high-speed launch basket for AGM-88 HARM and Kh-58.
    -- HELO: 150m AGL for nap-of-the-earth transport.
    local alt = 7500
    local speed = 260
    if isHelo then
        alt = 150
        speed = Director.config.heloIngressSpeed or 65
    elseif isStrike then
        alt = 450 -- Low-level terrain masking ingress
        speed = 210
    elseif assignedRole == "SEAD" then
        alt = 4500
        speed = 240
    elseif assignedRole == "ESCORT" then
        alt = 5500
        speed = 250
    end

    -- Operational task doctrine
    local grpTaskStr = "CAP"
    if isHelo and assignedRole == "LOGISTICS" then
        grpTaskStr = "Transport"
    elseif assignedRole == "SEAD" then
        grpTaskStr = "SEAD"
    elseif isStrike then
        grpTaskStr = "Ground Attack"
    end

    -- Multi-Waypoint Tactical Route Building:
    local routePoints = {}
    local startX = origin.x + (isStrike and 0 or lateralSpread)
    local startZ = origin.z

    if isStrike then
        -- 4-Waypoint Tactical Ingress Route:
        -- WP1: Staging Base
        -- WP2: Ingress Initial Point (IP) with tactical flank offset (hugs coastline or valley)
        -- WP3: Target Area (pop-up attack on SAMs / ground targets)
        -- WP4: Safe Egress turn back to friendly lines
        local midX = (origin.x + targetPos.x) / 2
        local midZ = (origin.z + targetPos.z) / 2
        local flankSign = (side == SIDE_BLUE) and -1 or 1
        local ipX = midX + (flankSign * 16000)
        local ipZ = midZ

        table.insert(routePoints, {
            ["alt"] = alt, ["type"] = "Turning Point", ["action"] = "Turning Point",
            ["speed"] = speed, ["x"] = startX, ["y"] = startZ
        })
        table.insert(routePoints, {
            ["alt"] = alt, ["type"] = "Turning Point", ["action"] = "Turning Point",
            ["speed"] = speed, ["x"] = ipX, ["y"] = ipZ
        })

        local wpTargetTasks = {
            {
                ["id"] = "EngageTargetsInZone",
                ["enabled"] = true,
                ["auto"] = false,
                ["params"] = {
                    ["point"] = { ["x"] = targetPos.x, ["y"] = targetPos.z },
                    ["zoneRadius"] = 25000,
                    ["targetTypes"] = { "Air Defence", "Ground Units" },
                    ["priority"] = 0
                }
            }
        }
        local atkType = (tmpl.type == "F-117-NightHawk") and "Level" or "Dive"
        table.insert(wpTargetTasks, {
            ["id"] = "Bombing",
            ["enabled"] = true,
            ["auto"] = false,
            ["params"] = {
                ["point"] = { ["x"] = targetPos.x, ["y"] = targetPos.z },
                ["expend"] = "All",
                ["attackType"] = atkType,
                ["altitude"] = 750,
                ["altitudeEdited"] = true
            }
        })
        table.insert(routePoints, {
            ["alt"] = 750, ["type"] = "Turning Point", ["action"] = "Turning Point",
            ["speed"] = speed + 20, ["x"] = targetPos.x, ["y"] = targetPos.z,
            ["task"] = { ["id"] = "ComboTask", ["params"] = { ["tasks"] = wpTargetTasks } }
        })
        table.insert(routePoints, {
            ["alt"] = alt, ["type"] = "Turning Point", ["action"] = "Turning Point",
            ["speed"] = speed, ["x"] = ipX, ["y"] = ipZ,
            ["task"] = { ["id"] = "ComboTask", ["params"] = { ["tasks"] = {
                {
                    ["id"] = "Orbit", ["enabled"] = true, ["auto"] = false,
                    ["params"] = { ["pattern"] = "Circle", ["speed"] = speed, ["altitude"] = alt }
                }
            } } }
        })

    elseif assignedRole == "CAP" then
        -- 3-Waypoint CAP Station Racetrack Orbit:
        -- WP1: Staging Base with lateral spread
        -- WP2: Patrol Anchor Alpha (Entry point)
        -- WP3: Patrol Anchor Bravo (22km offset along front) with Race-Track Orbit!
        local capEntryX = targetPos.x + lateralSpread
        local capEntryZ = targetPos.z
        local capOrbitX = targetPos.x + lateralSpread + 22000
        local capOrbitZ = targetPos.z + 8000

        local wpCapTasks = {
            {
                ["id"] = "Orbit",
                ["enabled"] = true,
                ["auto"] = false,
                ["params"] = {
                    ["pattern"] = "Race-Track",
                    ["speed"] = speed,
                    ["altitude"] = alt
                }
            },
            {
                ["id"] = "EngageTargets",
                ["enabled"] = true,
                ["auto"] = false,
                ["params"] = {
                    ["targetTypes"] = { "Planes" },
                    ["maxDist"] = 75000, -- Constrained to defensive quadrant bubble (75 km / ~40 NM)
                    ["priority"] = 0
                }
            }
        }
        table.insert(routePoints, {
            ["alt"] = alt, ["type"] = "Turning Point", ["action"] = "Turning Point",
            ["speed"] = speed, ["x"] = startX, ["y"] = startZ
        })
        table.insert(routePoints, {
            ["alt"] = alt, ["type"] = "Turning Point", ["action"] = "Turning Point",
            ["speed"] = speed, ["x"] = capEntryX, ["y"] = capEntryZ
        })
        table.insert(routePoints, {
            ["alt"] = alt, ["type"] = "Turning Point", ["action"] = "Turning Point",
            ["speed"] = speed, ["x"] = capOrbitX, ["y"] = capOrbitZ,
            ["task"] = { ["id"] = "ComboTask", ["params"] = { ["tasks"] = wpCapTasks } }
        })

    else
        -- Escort, SEAD, Logistics:
        local engTasks = {}
        if assignedRole == "ESCORT" then
            table.insert(engTasks, {
                ["id"] = "EngageTargets", ["enabled"] = true, ["auto"] = false,
                ["params"] = { ["targetTypes"] = { "Planes" }, ["maxDist"] = 75000, ["priority"] = 0 }
            })
            table.insert(engTasks, {
                ["id"] = "Orbit", ["enabled"] = true, ["auto"] = false,
                ["params"] = { ["pattern"] = "Race-Track", ["speed"] = speed, ["altitude"] = alt }
            })
        elseif assignedRole == "SEAD" then
            table.insert(engTasks, {
                ["id"] = "EngageTargetsInZone", ["enabled"] = true, ["auto"] = false,
                ["params"] = { ["point"] = { ["x"] = targetPos.x, ["y"] = targetPos.z }, ["zoneRadius"] = 45000, ["targetTypes"] = { "Air Defence" }, ["priority"] = 0 }
            })
            table.insert(engTasks, {
                ["id"] = "Orbit", ["enabled"] = true, ["auto"] = false,
                ["params"] = { ["pattern"] = "Circle", ["speed"] = speed, ["altitude"] = alt }
            })
        else
            table.insert(engTasks, {
                ["id"] = "Orbit", ["enabled"] = true, ["auto"] = false,
                ["params"] = { ["pattern"] = "Circle", ["speed"] = speed, ["altitude"] = alt }
            })
        end

        table.insert(routePoints, {
            ["alt"] = alt, ["type"] = "Turning Point", ["action"] = "Turning Point",
            ["speed"] = speed, ["x"] = startX, ["y"] = startZ
        })
        table.insert(routePoints, {
            ["alt"] = alt, ["type"] = "Turning Point", ["action"] = "Turning Point",
            ["speed"] = speed, ["x"] = targetPos.x, ["y"] = targetPos.z,
            ["task"] = { ["id"] = "ComboTask", ["params"] = { ["tasks"] = engTasks } }
        })
    end

    local groupData = {
        ["visible"] = true,
        ["tasks"] = {},
        ["uncontrolled"] = false,
        ["task"] = grpTaskStr,
        ["groupId"] = grpId,
        ["name"] = grpName,
        ["route"] = {
            ["points"] = routePoints
        },
        ["units"] = {}
    }

    for uIdx = 1, tmpl.count do
        local uName = string.format("%s_U%d", grpName, uIdx)
        local offset = (uIdx - 1) * 60
        local uData = {
            ["type"] = tmpl.type,
            ["unitId"] = grpId * 10 + uIdx,
            ["name"] = uName,
            ["x"] = startX + offset,
            ["y"] = startZ + offset,
            ["alt"] = alt,
            ["speed"] = speed,
            ["heading"] = origin.heading or 0,
            ["skill"] = tmpl.skill or "High",
            ["playerCanDrive"] = false,
            ["payload"] = tmpl.payload or {}
        }
        table.insert(groupData.units, uData)
    end

    local ok, err = pcall(function()
        coalition.addGroup(countryId, cat, groupData)
        local grp = Group.getByName(grpName)
        if grp then
            local ctrl = grp:getController()
            if ctrl then
                ctrl:setOption(AI.Option.Air.id.ROE, AI.Option.Air.val.ROE.WEAPON_FREE)
                ctrl:setOption(AI.Option.Air.id.RADAR_USING, AI.Option.Air.val.RADAR_USING.FOR_CONTINUOUS_SEARCH)

                if assignedRole == "CAP" then
                    ctrl:setOption(AI.Option.Air.id.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.EVADE_FIRE)
                    ctrl:pushTask({
                        ["id"] = "EngageTargets",
                        ["enabled"] = true,
                        ["auto"] = false,
                        ["params"] = {
                            ["targetTypes"] = { "Planes" },
                            ["maxDist"] = 48000, -- Constrained to defensive quadrant bubble (48 km / ~26 NM)
                            ["priority"] = 0
                        }
                    })
                elseif assignedRole == "ESCORT" then
                    ctrl:setOption(AI.Option.Air.id.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.EVADE_FIRE)
                    ctrl:pushTask({
                        ["id"] = "EngageTargets",
                        ["enabled"] = true,
                        ["auto"] = false,
                        ["params"] = {
                            ["targetTypes"] = { "Planes" },
                            ["maxDist"] = 55000,
                            ["priority"] = 0
                        }
                    })
                elseif isStrike then
                    -- Strike planes: NO air combat hunting! Bypass threats, deploy ECM/chaff/flares, kill ground SAMs and armor!
                    ctrl:setOption(AI.Option.Air.id.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.BYPASS_AND_ESCAPE)
                    ctrl:setOption(AI.Option.Air.id.ECM_USING, AI.Option.Air.val.ECM_USING.USE_IF_ONLY_LOCK_BY_RADAR)

                    local tgtGName = targetSec and targetSec.groupName
                    local tgtGrp = tgtGName and Group.getByName(tgtGName)
                    local atkType = (tmpl.type == "F-117-NightHawk") and "Level" or "Dive"
                    if tgtGrp and tgtGrp:isExist() and tgtGrp:getSize() > 0 then
                        ctrl:pushTask({
                            ["id"] = "AttackGroup",
                            ["enabled"] = true,
                            ["auto"] = false,
                            ["params"] = {
                                ["groupId"] = tgtGrp:getID(),
                                ["expend"] = "All",
                                ["attackType"] = atkType
                            }
                        })
                    else
                        ctrl:pushTask({
                            ["id"] = "EngageTargetsInZone",
                            ["enabled"] = true,
                            ["auto"] = false,
                            ["params"] = {
                                ["point"] = { ["x"] = targetPos.x, ["y"] = targetPos.z },
                                ["zoneRadius"] = 25000,
                                ["targetTypes"] = { "Air Defence", "Ground Units" },
                                ["priority"] = 0
                            }
                        })
                    end
                elseif assignedRole == "SEAD" then
                    ctrl:setOption(AI.Option.Air.id.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.EVADE_FIRE)
                    ctrl:pushTask({
                        ["id"] = "EngageTargetsInZone",
                        ["enabled"] = true,
                        ["auto"] = false,
                        ["params"] = {
                            ["point"] = { ["x"] = targetPos.x, ["y"] = targetPos.z },
                            ["zoneRadius"] = 45000,
                            ["targetTypes"] = { "Air Defence" },
                            ["priority"] = 0
                        }
                    })
                end
            end

            Director.activeGroups[side][grpName] = {
                role = assignedRole,
                target = targetSec and targetSec.name or "Contested Sector",
                quadrant = targetQuadrant,
                capSlot = capSlot,
                spawnTime = timer.getTime()
            }
            local tgtName = targetSec and targetSec.name or "Contested Airspace"
            local logMsg = string.format("AI DIRECTOR: Scrambled [%s] %s (%s x%d) from %s -> %s [%s]",
                sideName, grpName, tmpl.type, tmpl.count, origin.name or "Staging", tgtName, targetQuadrant)
            log(logMsg)
            trigger.action.outText(string.format("TAC-COMM [%s]: %s (%d-ship %s) scrambled from %s -> %s [%s]",
                sideName, tmpl.name, tmpl.count, tmpl.type, origin.name or targetQuadrant, tgtName, targetQuadrant), 10)
        end
    end)
    if not ok then
        log(string.format("AI DIRECTOR SPAWN ERROR [%s] %s: %s", sideName, grpName, tostring(err)))
    end
end

-- ------------------------------------------------------------------------------
-- 6. AUTONOMOUS DIRECTOR LOOP (Guaranteed Multi-Quadrant Distribution)
-- ------------------------------------------------------------------------------
function Director.Loop()
    local now = timer.getTime()

    -- 1. Periodic Autonomous R&D; each coalition can make one purchase per interval.
    Director.EvaluateResearch(SIDE_BLUE, now)
    Director.EvaluateResearch(SIDE_RED, now)

    -- 2. Clean up destroyed or lost groups & apply Contention-style 3-minute scramble cooldowns
    for side = 1, 2 do
        for grpName, gData in pairs(Director.activeGroups[side]) do
            local grp = Group.getByName(grpName)
            if not grp or not grp:isExist() or grp:getSize() == 0 or (now - gData.spawnTime > 900) then
                -- Group was destroyed or mission timed out!
                if gData.role == "CAP" and gData.capSlot then
                    -- 3-Minute Scramble Cooldown (180s)
                    -- Simulates ramp preparation, taxi, takeoff roll, and scramble transit!
                    Director.slotCooldowns[side][gData.capSlot] = now + 180
                    local enemySide = (side == SIDE_BLUE) and SIDE_RED or SIDE_BLUE
                    local enemyName = (enemySide == SIDE_BLUE) and "BLUFOR" or "REDFOR"
                    local friendlyName = (side == SIDE_BLUE) and "BLUFOR" or "REDFOR"
                    local frontLabel = (gData.capSlot == 1 or gData.capSlot == 4) and "West Front" or ((gData.capSlot == 2 or gData.capSlot == 5) and "East Front" or "Central Ridge")
                    log(string.format("AI DIRECTOR: [%s] CAP (%s) lost! 3-minute scramble cooldown active. [%s] holds Air Superiority Window in %s!",
                        friendlyName, frontLabel, enemyName, frontLabel))
                    trigger.action.outText(string.format("TAC-COMM: [%s] CAP over %s destroyed! [%s] Air Superiority Window OPEN (3:00)!",
                        friendlyName, frontLabel, enemyName), 12)
                else
                    -- Strike / Support role cooldown (120s / 2 minutes turnaround)
                    Director.roleCooldowns[side][gData.role] = now + 120
                end
                Director.activeGroups[side][grpName] = nil
            end
        end
    end

    -- 3. Dedicated Fighter Dominance Across All Fronts (30 v 30 Fleet Architecture = 60 Active AI Aircraft):
    --    Each coalition maintains 6x 2-ship CAP flights (12 Fighters per side, 24 Fighters total):
    --    - Slot 1: West Front (NW for Red / SW for Blue)
    --    - Slot 2: East Front (NE for Red / SE for Blue - Mineralnye Vody vs Senaki-Kolkhi)
    --    - Slot 3: Central Contested Meridian Sweep (Maykop vs Gudauta)
    --    - Slot 4: Coastal Defense Intercept (Krymsk vs Sochi)
    --    - Slot 5: Eastern Mountain Barrier High Sweep (Mozdok vs Kutaisi)
    --    - Slot 6: Central Frontline Intercept
    local quadrantCapSlots = {
        [SIDE_RED] = {
            { quad = "NW", label = "NW Front (Krymsk)" },
            { quad = "NE", label = "NE Front (Mineralnye Vody)" },
            { quad = "CENTER", label = "Central Front Sweep" },
            { quad = "NW", label = "NW Coastal Intercept" },
            { quad = "NE", label = "NE High Sweep (Mozdok)" },
            { quad = "CENTER", label = "Central Ridge Intercept" }
        },
        [SIDE_BLUE] = {
            { quad = "SW", label = "SW Front (Sochi-Adler)" },
            { quad = "SE", label = "SE Front (Senaki-Kolkhi)" },
            { quad = "CENTER", label = "Central Front Sweep" },
            { quad = "SW", label = "SW Coastal Intercept" },
            { quad = "SE", label = "SE Valley High Sweep" },
            { quad = "CENTER", label = "Central Ridge Intercept" }
        }
    }

    -- Interleave CAP Spawning across slots and sides
    local capFilled = { [SIDE_RED] = 0, [SIDE_BLUE] = 0 }
    for slotIdx = 1, 6 do
        for _, side in ipairs({ SIDE_RED, SIDE_BLUE }) do
            local sDef = quadrantCapSlots[side][slotIdx]
            local slotFilled = false
            for _, gData in pairs(Director.activeGroups[side]) do
                if gData.role == "CAP" and gData.capSlot == slotIdx then
                    slotFilled = true
                    capFilled[side] = capFilled[side] + 1
                    break
                end
            end
            if not slotFilled then
                local cd = Director.slotCooldowns[side][slotIdx] or 0
                if now >= cd then
                    local targetSec = Director.SelectTargetSector("CAP", side, sDef.quad)
                    Director.SpawnFlight(side, "CAP", targetSec, sDef.quad, slotIdx)
                    return now + 8 -- Smooth 8-second pacing between individual scrambles
                end
                -- If slot is on cooldown (now < cd), NO REPLACEMENT SPAWNS!
                -- This guarantees a 3-minute opening where the opposing side holds air superiority!
            end
        end
    end

    -- AIR SUPERIORITY INITIAL BUFFER:
    -- At mission start, allow CAP fighters at least 60s to ingress and establish combat patrols
    if now < 60 then
        return now + 10
    end

    -- 4. Multi-Role Package Quotas & Air Superiority Window Exploitation:
    --    When enemy CAP in a quadrant is destroyed, SEAD and Strike immediately scramble
    --    to exploit the undefended airspace before the enemy's 3-minute cooldown expires!
    local supportQuotas = {
        { role = "SEAD", maxCount = 2 },      -- 2 flights x 2-ship = 4 SEAD jets per side
        { role = "STRIKE", maxCount = 4 },    -- 4 flights x 2-ship = 8 Strike jets per side (A-4E-C / Su-25T)
        { role = "ESCORT", maxCount = 2 },    -- 2 flights x 2-ship = 4 Escort fighters per side
        { role = "LOGISTICS", maxCount = 1 }  -- 1 flight x 2-ship = 2 Cargo helos per side
    }

    for _, sq in ipairs(supportQuotas) do
        local counts = {}
        for _, side in ipairs({ SIDE_RED, SIDE_BLUE }) do
            counts[side] = 0
            for _, gData in pairs(Director.activeGroups[side]) do
                if gData.role == sq.role then
                    counts[side] = counts[side] + 1
                end
            end
        end

        if counts[SIDE_RED] < sq.maxCount or counts[SIDE_BLUE] < sq.maxCount then
            local targetSide = (counts[SIDE_RED] <= counts[SIDE_BLUE]) and SIDE_RED or SIDE_BLUE
            if counts[targetSide] >= sq.maxCount then
                targetSide = (targetSide == SIDE_RED) and SIDE_BLUE or SIDE_RED
            end

            -- Check turnaround cooldown for this role (prevents endless wave spam):
            local rCd = Director.roleCooldowns[targetSide][sq.role] or 0
            if now >= rCd then
                -- Determine which front has the open Air Superiority Window:
                local enemySide = (targetSide == SIDE_BLUE) and SIDE_RED or SIDE_BLUE
                local enemyWestCap = false
                local enemyEastCap = false
                for _, egData in pairs(Director.activeGroups[enemySide]) do
                    if egData.role == "CAP" then
                        if egData.quadrant == "NW" or egData.quadrant == "SW" then
                            enemyWestCap = true
                        elseif egData.quadrant == "NE" or egData.quadrant == "SE" then
                            enemyEastCap = true
                        end
                    end
                end

                -- Prioritize pushing into the front where enemy CAP is down!
                local preferredFront = nil
                if not enemyWestCap then
                    preferredFront = (targetSide == SIDE_BLUE) and "SW" or "NW"
                elseif not enemyEastCap then
                    preferredFront = (targetSide == SIDE_BLUE) and "SE" or "NE"
                else
                    -- Both enemy CAPs active; alternate based on density
                    local activeQuadrants = {}
                    for _, gData in pairs(Director.activeGroups[targetSide]) do
                        if gData.quadrant then
                            activeQuadrants[gData.quadrant] = (activeQuadrants[gData.quadrant] or 0) + 1
                        end
                    end
                    local westCount = (activeQuadrants["NW"] or 0) + (activeQuadrants["SW"] or 0)
                    local eastCount = (activeQuadrants["NE"] or 0) + (activeQuadrants["SE"] or 0)
                    preferredFront = (westCount > eastCount)
                        and (targetSide == SIDE_BLUE and "SE" or "NE")
                        or  (targetSide == SIDE_BLUE and "SW" or "NW")
                end

                local targetSec = Director.SelectTargetSector(sq.role, targetSide, preferredFront)
                Director.SpawnFlight(targetSide, sq.role, targetSec, preferredFront)
                return now + 8
            end
        end
    end

    return now + 15
end

function Director.Start()
    if Director.initialized then return end
    Director.initialized = true
    local now = timer.getTime()
    local readyAt = now + BF.Config.autonomousResearchInterval
    Director.researchReadyAt[SIDE_BLUE] = readyAt
    Director.researchReadyAt[SIDE_RED] = readyAt
    log("=== BATTLEFRONT AIR WAR: AUTONOMOUS AI CAMPAIGN DIRECTOR STARTED ===")
    timer.scheduleFunction(Director.Loop, nil, now + 10)
end

_G.BF_AIDirector = Director
