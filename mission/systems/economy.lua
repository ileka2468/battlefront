-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - ECONOMY & INDUSTRIAL UPGRADES
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

BF.Economy = BF.Economy or {}

local SIDE_RED  = BF.SIDE_RED or 1
local SIDE_BLUE = BF.SIDE_BLUE or 2

local function log(msg) BF.Log(msg) end

function BF.Economy.addFunds(side, amount, reason)
    local coal = BF.State.coalitions[side]
    if not coal then return end
    coal.treasury = coal.treasury + amount
    if reason then
        BF.Log(string.format("ECONOMY: Added %s to %s for %s. New Treasury: %s",
            BF.FormatMoney(amount), coal.name, reason, BF.FormatMoney(coal.treasury)))
    end
end

function BF.Economy.deductFunds(side, amount, reason)
    local coal = BF.State.coalitions[side]
    if not coal then return false end
    if coal.treasury < amount then return false end
    coal.treasury = coal.treasury - amount
    if reason then
        BF.Log(string.format("ECONOMY: Deducted %s from %s for %s. Remaining: %s",
            BF.FormatMoney(amount), coal.name, reason, BF.FormatMoney(coal.treasury)))
    end
    return true
end

function BF.UpgradeSector(side, secName)
    local sec = BF.State.sectors[secName]
    local coal = BF.State.coalitions[side]
    if not sec or not coal then return end

    if sec.side ~= side then
        BF.Broadcast(string.format("UPGRADE REJECTED: %s is not under %s control!", secName, coal.name), side, 6)
        return
    end

    local currentLvl = sec.level or 1
    if currentLvl >= 3 then
        BF.Broadcast(string.format("NOTICE: %s is already at MAXIMUM EXPANSION (Level 3 Super-Complex)!", secName), side, 8)
        return
    end

    local nextLvl = currentLvl + 1
    local cost = BF.Config.upgradeCosts[nextLvl] or 100

    if coal.treasury < cost then
        local msg = string.format("INDUSTRIAL UPGRADE REJECTED: Insufficient treasury for %s!\nRequired: %s | Current Treasury: %s\nCapture facilities or splash enemy bogeys to accumulate capital.",
            secName, BF.FormatMoney(cost), BF.FormatMoney(coal.treasury))
        BF.Broadcast(msg, side, 10)
        return
    end

    coal.treasury = coal.treasury - cost
    sec.level = nextLvl
    sec.income = math.floor((sec.baseIncome or 2) * (BF.Config.upgradeMultipliers[nextLvl] or 1.0))
    sec.captureBounty = math.floor((sec.baseBounty or 110) * (1 + (nextLvl - 1) * 0.75))

    local upgradeMsg = string.format("FACILITY UPGRADE COMPLETE (%s)\n%s expanded to LEVEL %d!\nRevenue boosted to +$%dM/5min (%s/hr)!\nRemaining War Chest: %s",
        coal.name, secName, nextLvl, sec.income, BF.FormatMoney(sec.income * 12), BF.FormatMoney(coal.treasury))
    BF.Broadcast(upgradeMsg, side, 14)

    BF.RenderSectorMarkers(secName)
    BF.SaveState()
end



function BF.EconomyTick()
    for secName, sec in pairs(BF.State.sectors) do
        local coal = BF.State.coalitions[sec.side]
        if coal and (sec.status == "DEFENDED" or sec.status == "FORTIFIED" or sec.status == "HOLDING") then
            local mult = BF.Config.passiveIncomeMultiplier or 1.0
            coal.treasury = coal.treasury + math.max(1, math.floor(sec.income * mult))
        end
    end

    for side, coal in pairs(BF.State.coalitions) do
        local msg = string.format("[%s DEFENSE TREASURY UPDATE]\nAvailable Capital: %s\nIndustrial Facilities Operational across Quadrants.",
            coal.name, BF.FormatMoney(coal.treasury))
        BF.Broadcast(msg, side, 8)
    end

    BF.SaveState()
    return timer.getTime() + BF.Config.economyInterval
end

-- ------------------------------------------------------------------------------
-- 9. EVENT HANDLER (Damage, Kills, Splashes)
-- ------------------------------------------------------------------------------
local EventHandler = {}


BF.Economy.UpgradeSector = BF.UpgradeSector
BF.Economy.Tick = BF.EconomyTick

if BF.Events and BF.Events.on then
    BF.Events.on("unit.killed", function(data)
        if data and data.killerSide and data.bounty and data.bounty > 0 then
            BF.Economy.addFunds(data.killerSide, data.bounty, data.reason or "Combat Splash Bounty")
        end
    end)
    BF.Events.on("sector.captured", function(data)
        if data and data.cappingSide and data.bounty and data.bounty > 0 then
            BF.Economy.addFunds(data.cappingSide, data.bounty, string.format("Capture of %s", data.sectorName))
        end
    end)
end
