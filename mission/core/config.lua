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

}
