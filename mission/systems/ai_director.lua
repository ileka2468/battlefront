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

