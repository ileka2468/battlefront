-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - CONFIGURATION & BALANCING
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

BF.Config = {
    -- Starting treasury balance ($M)
    startingBudget = 200,

    -- Tactical Support Deployment Fees ($M)
    dropCosts = {
        ["ewr"]    = 25,   -- $25M (1L13 / 55G6 Mobile Long-Range Radar)
        ["awacs"]  = 100,  -- $100M (E-3A / A-50 High-Altitude Sortie Allocation)
        ["shorad"] = 50,   -- $50M (Avenger / Tunguska Air Defense Battery)
    },

    -- High-Value Asset (HVA) Replacement Penalties ($M)
    heroReplacementCosts = {
        ["F-22A"]           = 150,
        ["F-23A"]           = 150,
        ["Su-57"]           = 150,
        ["J-20A"]           = 150,
        ["MiG-31BM"]        = 90,
        ["MiG-31K"]         = 90,
        ["F-14B"]           = 80,
        ["F-14BU"]          = 85,
        ["FA-18C_hornet"]   = 40,
        ["JF-17"]           = 60,
        ["F-117-NightHawk"] = 90,
        ["Su-34"]           = 90,
        ["Hercules"]        = 50,
        ["UH-60L"]          = 20,
        ["A-4E-C"]          = 15,
        ["Su-35S"]          = 50,
        ["Su-30SM"]         = 45,
        ["Su-33"]           = 40,
        ["MiG-29S"]         = 25,
        ["F-15C"]           = 25,
        ["F-16C_50"]        = 40,
        ["Su-25T"]          = 20,
    },

    -- Hero Procurement Delivery Cooldown (Seconds)
    heroCooldownSeconds = 240, -- 4 Minutes

    -- Economic Income Payout Interval (Seconds)
    economyInterval = 300, -- 5 Minutes

    -- Facility Industrial Upgrade System
    upgradeCosts = {
        [2] = 100, -- $100M to upgrade from Level 1 -> Level 2
        [3] = 200, -- $200M to upgrade from Level 2 -> Level 3
    },
    upgradeMultipliers = {
        [1] = 1.0, -- Level 1 Baseline ($1.5M - $2.5M/5m)
        [2] = 2.5, -- Level 2 Industrial Expansion ($4.0M - $6.0M/5m)
        [3] = 5.0, -- Level 3 Strategic Super-Complex ($8.0M - $12.0M/5m)
    },

    -- Tactical Maneuvering Bubble (Meters)
    holdRadius = 18000, -- 18 km radius (36 km wide air combat maneuvering zone)
    lzRadius = 3000,    -- 3 km physical capture touchdown zone

    -- Fortification Timer (Seconds to hold before automatic heavy defenses spawn)
    fortifyDuration = 900, -- 15 Minutes

    -- Engagement Combat Alert Radius (Meters)
    combatAlertRadius = 18000, -- 18 km early-warning tripwire
    combatAlertTimeout = 60,

    -- Bounties ($M)
    airKillBounty = 20,
    groundKillBounty = 5,

    -- Server Proximity Culling (Meters)
    cullDistance = 45000, -- 45 km AI radar and raycast sleep distance

    -- Director research spends the same coalition treasury as F10. Campaign
    -- play can progress with no pilots connected, but no advanced aircraft are free.
    allowAutonomousResearch = true,
    autonomousResearchInterval = 600, -- Simulation seconds, including the opening interval
    autonomousResearchReserve = 100,  -- Minimum $M left after an automatic purchase (F10 is not limited)
    autonomousResearchOrder = {
        [BF.SIDE_BLUE] = { "A-4E-C", "F-117A", "F-22A", "UH-60L" },
        [BF.SIDE_RED] = { "Su-34", "Su-30SM", "Su-35S", "Su-57", "J-20A" },
    },
    -- An AI sortie may fly only a stock campaign type or an explicitly purchased blueprint.
    stockCampaignAirframes = {
        ["F-15C"] = true, ["F-16C_50"] = true, ["FA-18C_hornet"] = true,
        ["F-14B"] = true, ["A-10A"] = true, ["A-10C"] = true,
        ["AH-64D_BLK_II"] = true, ["UH-1H"] = true,
        ["Su-27"] = true, ["Su-33"] = true, ["MiG-29S"] = true,
        ["Su-25T"] = true, ["JF-17"] = true, ["Ka-50_3"] = true,
        ["Mi-24P"] = true, ["Mi-8MT"] = true
    },
    airframeBlueprint = {
        ["F-22A"] = "F-22A", ["F-23A"] = "F-23A", ["F-14BU"] = "F-14BU",
        ["F-117-NightHawk"] = "F-117A", ["A-4E-C"] = "A-4E-C",
        ["UH-60L"] = "UH-60L", ["Hercules"] = "C-130", ["C-130"] = "C-130",
        ["Su-34"] = "Su-34", ["Su-30SM"] = "Su-30SM", ["Su-35S"] = "Su-35S",
        ["Su-57"] = "Su-57", ["J-20A"] = "J-20A",
        ["MiG-31BM"] = "MiG-31BM", ["MiG-31K"] = "MiG-31K"
    },
    -- R&D Blueprints Catalog ($M)
    blueprints = {
        [BF.SIDE_BLUE] = {
            ["A-4E-C"] = { name = "A-4E-C Skyhawk", cost = 250,
                desc = "Light strike aircraft", flag = "BLUE_A4E_1" },
            ["UH-60L"] = { name = "UH-60L Black Hawk", cost = 350,
                desc = "Utility and logistics helicopter", flag = "BLUE_UH60_1" },
            ["F-23A"] = { name = "F-23A", cost = 1700,
                desc = "Advanced fighter", flag = "BLUE_F23A_1" },
            ["F-14BU"] = { name = "F-14BU", cost = 900,
                desc = "Upgraded fleet fighter", flag = "BLUE_F14BU_1" },
            ["F-117A"] = {
                name = "F-117A Nighthawk",
                cost = 800,
                desc = "Precision Tactical Stealth Bomber (Laser-Guided Deep Bunker Strike)",
                flag = "BLUE_HERO_2"
            },
            ["F-22A"] = {
                name = "F-22A Raptor",
                cost = 1500,
                desc = "5th-Gen Air Dominance (APG-77 AESA Radar, Stealth, Thrust Vectoring)",
                flag = "BLUE_HERO_1"
            },
            ["C-130"] = {
                name = "C-130 Hercules",
                cost = 350,
                desc = "Strategic Tactical Airlifter (Rapid Sector Garrison Drops & Fuel Logistics)",
                flag = "BLUE_HERC_1"
            }
        },
        [BF.SIDE_RED] = {
            ["C-130"] = { name = "C-130 Hercules", cost = 350,
                desc = "Strategic transport", flag = "RED_HERC_1" },
            ["MiG-31BM"] = { name = "MiG-31BM", cost = 900,
                desc = "Advanced interceptor", flag = "RED_MIG31_1" },
            ["MiG-31K"] = { name = "MiG-31K", cost = 1000,
                desc = "Advanced strike aircraft", flag = "RED_MIG31K_1" },
            ["Su-34"] = {
                name = "Su-34 Fullback",
                cost = 650,
                desc = "Supersonic Heavy Strike Fighter (Leninets Radar, KAB-500Kr Guided Bombs, Khibiny ECM)",
                flag = "RED_SU34_1"
            },
            ["Su-30SM"] = {
                name = "Su-30SM Flanker",
                cost = 700,
                desc = "Two-Seat Multi-Role Fighter (Bars Radar, Heavy Air-to-Ground & BVR)",
                flag = "RED_SU30_1"
            },
            ["Su-35S"] = {
                name = "Su-35S Flanker-E",
                cost = 850,
                desc = "4.5++ Gen Air Dominance Fighter (Irbis-E PESA, Super-Maneuverable)",
                flag = "RED_SU35_1"
            },
            ["Su-57"] = {
                name = "Su-57 Felon",
                cost = 1500,
                desc = "5th-Gen Stealth Multi-Role (3D Thrust Vectoring, Internal R-77M/R-74M2)",
                flag = "RED_SU57_1"
            },
            ["J-20A"] = {
                name = "J-20A Mighty Dragon",
                cost = 1600,
                desc = "5th-Gen Heavy Stealth Interceptor (Long-Range PL-15 AAM, AESA)",
                flag = "RED_J20A_1"
            }
        }
    }
}
