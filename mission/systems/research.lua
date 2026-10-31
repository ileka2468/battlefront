-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - R&D BLUEPRINTS & TECH PROGRESSION
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

BF.Research = BF.Research or {}

local function log(msg) BF.Log(msg) end

function BF.Research.CanFieldAirframe(side, airframe)
    local cfg = BF.Config
    local key = cfg.airframeBlueprint[airframe]
    if not key then
        return cfg.stockCampaignAirframes[airframe] == true
    end
    local coal = BF.State.coalitions[side]
    local offered = cfg.blueprints[side] and cfg.blueprints[side][key]
    return offered ~= nil and coal ~= nil and coal.unlockedBlueprints[key] == true
end

function BF.PurchaseBlueprint(side, planeKey, source)
    local coal = BF.State.coalitions[side]
    local bpConfig = BF.Config.blueprints[side] and BF.Config.blueprints[side][planeKey]
    if not coal or not bpConfig then return false, "unknown_blueprint" end
    local director = source == "director"

    if coal.unlockedBlueprints[planeKey] then
        if not director then
            local msg = string.format("R&D NOTICE: %s Blueprint is ALREADY researched and active. No funds spent. Treasury: %s.",
                bpConfig.name, BF.FormatMoney(coal.treasury))
            BF.Broadcast(msg, side, 8)
        end
        return false, "already_purchased"
    end

    if coal.treasury < bpConfig.cost then
        if not director then
            local msg = string.format("R&D REJECTED: Insufficient War Chest for %s!\nRequired: %s | Current Treasury: %s\nNo funds spent. Capture and hold enemy industrial centers to fund R&D.",
                bpConfig.name, BF.FormatMoney(bpConfig.cost), BF.FormatMoney(coal.treasury))
            BF.Broadcast(msg, side, 12)
        end
        return false, "insufficient_funds"
    end
    if director and coal.treasury - bpConfig.cost < BF.Config.autonomousResearchReserve then
        return false, "reserved_funds"
    end

    -- Queue the new ledger before updating slot flags or announcing success.
    local before = coal.treasury
    coal.treasury = before - bpConfig.cost
    coal.unlockedBlueprints[planeKey] = true
    local queued, err = BF.SaveState()
    if not queued then
        coal.treasury = before
        coal.unlockedBlueprints[planeKey] = nil
        log("R&D ledger queue failed: " .. tostring(err))
        BF.Broadcast("R&D FAILED: Could not update the campaign ledger. No funds spent.", side, 12)
        return false, "ledger_unavailable"
    end
    coal.lastBlueprintPurchase = { key = planeKey, cost = bpConfig.cost, before = before,
        after = coal.treasury, source = director and "director" or "f10" }

    -- Unblock the aircraft slot in SimpleSlotBlock
    local flagName = bpConfig.flag or bpConfig.unitName
    if flagName then
        trigger.action.setUserFlag(flagName, 0)
    end
    if BF.Aircraft and BF.Aircraft.ApplyResearchLocks then
        BF.Aircraft.ApplyResearchLocks(side, planeKey)
    end

    local unlockMsg = string.format("STRATEGIC R&D COMPLETE (%s)\n%s Blueprint Unlocked by %s. Paid: %s.\nTreasury: %s -> %s\nAvailable for campaign flights and matching mission slots.",
        coal.name, bpConfig.name, director and "AI Director" or "F10",
        BF.FormatMoney(bpConfig.cost), BF.FormatMoney(before), BF.FormatMoney(coal.treasury))
    BF.Broadcast(unlockMsg, side, 16)
    log(unlockMsg:gsub("\n", " | "))
    return true, coal.treasury
end

BF.Research.PurchaseBlueprint = BF.PurchaseBlueprint
