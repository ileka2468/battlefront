-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - AIRCRAFT SLOTS & COOLDOWN ENGINE
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

BF.Aircraft = BF.Aircraft or {}

BF.Aircraft.SlotFlags = {
    "BLUE_F23A_1", "BLUE_F23A_2", "BLUE_F23A_GUNS_1",
    "BLUE_F22A_1", "BLUE_HERO_1", "BLUE_F14BU_1", "BLUE_FA18C_1", "BLUE_FA18C_2",
    "BLUE_F117_1", "BLUE_HERO_2",
    "BLUE_F15C_1", "BLUE_CAP_1", "BLUE_F15C_GUNS_1",
    "BLUE_F16C_1", "BLUE_A4E_1", "BLUE_HERC_1",
    "BLUE_UH60_1", "BLUE_AH64_1", "BLUE_UH1H_1",
    
    "RED_SU57_1", "RED_SU57_2", "RED_SU57_GUNS_1",
    "RED_J20A_1", "RED_J20A_2",
    "RED_MIG31_1", "RED_MIG31K_1",
    "RED_JF17_1",
    "RED_SU35_1", "RED_SU30_1", "RED_SU33_1", "RED_SU34_1",
    "RED_MIG29_1", "RED_HERO_1", "RED_MIG29_GUNS_1",
    "RED_SU25T_1", "RED_HERC_1",
    "RED_KA50_1", "RED_MI24_1", "RED_MI8_1"
}

local slotResearch = {
    [BF.SIDE_BLUE] = {
        ["F-23A"] = {"BLUE_F23A_1", "BLUE_F23A_2", "BLUE_F23A_GUNS_1"},
        ["F-22A"] = {"BLUE_F22A_1", "BLUE_HERO_1"},
        ["F-14BU"] = {"BLUE_F14BU_1"},
        ["F-117A"] = {"BLUE_F117_1", "BLUE_HERO_2"},
        ["A-4E-C"] = {"BLUE_A4E_1"}, ["UH-60L"] = {"BLUE_UH60_1"},
        ["C-130"] = {"BLUE_HERC_1"},
    },
    [BF.SIDE_RED] = {
        ["Su-57"] = {"RED_SU57_1", "RED_SU57_2", "RED_SU57_GUNS_1"},
        ["J-20A"] = {"RED_J20A_1", "RED_J20A_2"},
        ["MiG-31BM"] = {"RED_MIG31_1"}, ["MiG-31K"] = {"RED_MIG31K_1"},
        ["Su-35S"] = {"RED_SU35_1"}, ["Su-30SM"] = {"RED_SU30_1"},
        ["Su-34"] = {"RED_SU34_1"}, ["C-130"] = {"RED_HERC_1"},
    },
}

function BF.Aircraft.ApplyResearchLocks(onlySide, onlyKey)
    for side, blueprints in pairs(slotResearch) do
        if not onlySide or side == onlySide then
            local coal = BF.State.coalitions[side]
            for key, flags in pairs(blueprints) do
                if not onlyKey or key == onlyKey then
                    local unlocked = coal and coal.unlockedBlueprints[key] == true
                    for _, flag in ipairs(flags) do
                        trigger.action.setUserFlag(flag, unlocked and 0 or 100)
                    end
                end
            end
        end
    end
end

function BF.Aircraft.InitSlots()
    trigger.action.setUserFlag("SSB", 100)
    for _, sname in ipairs(BF.Aircraft.SlotFlags) do
        trigger.action.setUserFlag(sname, 0)
    end
    BF.Aircraft.ApplyResearchLocks()
    BF.Log("AIRCRAFT: Research locks applied; unpurchased restricted airframes locked.")
end

--- Handle aircraft loss and trigger replacement cooldowns
function BF.Aircraft.HandleLoss(side, unitName, typeName)
    local coal = BF.State.coalitions[side]
    if not coal then return end

    local cost = BF.Config.heroReplacementCosts[typeName]
    if cost then
        coal.heroCooldowns[typeName] = BF.Config.heroCooldownSeconds
        trigger.action.setUserFlag(unitName, 100) -- Block slot via SSB

        BF.Broadcast(string.format("⚠ FLEET CASUALTY: %s %s shot down! Factory retooling delay: %ds",
            coal.name, typeName, BF.Config.heroCooldownSeconds), side, 10)
        BF.Log(string.format("AIRCRAFT: %s lost %s (%s). Cooldown started: %ds",
            coal.name, typeName, unitName, BF.Config.heroCooldownSeconds))
    end
end
