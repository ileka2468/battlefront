-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - F10 RADIO COMMAND MENUS
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

BF.Commands = BF.Commands or {}
BF.Commands.F10 = BF.Commands.F10 or {}

local SIDE_RED  = BF.SIDE_RED or 1
local SIDE_BLUE = BF.SIDE_BLUE or 2

-- Multiplayer radio captions must stay printable ASCII. Static labels are
-- plain text; keep future configurable blueprint and sector names safe too.
local function radioCaption(text)
    return (text:gsub("[^ -~]+", "?"))
end

function BF.Commands.F10.RegisterMenus()

    -- Weapons test ranges disabled for authentic Contention frontline combat
    -- (Prevents dummy target tanks and drones from spawning in the Black Sea)

    -- F10 Radio Menus (Treasury, R&D Department & Intelligence)
    pcall(function()
        for _, side in ipairs({SIDE_BLUE, SIDE_RED}) do
            local coal = BF.State.coalitions[side]

            -- 1. Treasury & Status Command
            missionCommands.addCommandForCoalition(side, "Treasury & Fleet Readiness", nil, function()
                local c = BF.State.coalitions[side]
                local msg = string.format("=== [%s WAR COUNCIL REPORT] ===\nTreasury: %s\nUnlocked Blueprints:\n",
                    c.name, BF.FormatMoney(c.treasury))
                local anyBP = false
                for k, v in pairs(c.unlockedBlueprints) do
                    if v then msg = msg .. string.format(" - %s (ACTIVE)\n", k); anyBP = true end
                end
                if not anyBP then msg = msg .. " - None (Tier 1 Standard Airframes Only)\n" end

                msg = msg .. "Active Aircraft Cooldowns:\n"
                local anyCD = false
                for k, v in pairs(c.heroCooldowns) do
                    if v > 0 then msg = msg .. string.format(" - %s: %ds delivery remaining\n", k, v); anyCD = true end
                end
                if not anyCD then msg = msg .. " - All operational airframes ready on flight line.\n" end
                BF.Broadcast(msg, side, 16)
            end)

            -- 1B. Facility Industrial Upgrades Submenu
            local upgMenu = missionCommands.addSubMenuForCoalition(side, "Facility Industrial Upgrades", nil)
            missionCommands.addCommandForCoalition(side, "View Upgrade Status", upgMenu, function()
                local c = BF.State.coalitions[side]
                local msg = string.format("=== [%s INDUSTRIAL FACILITY STATUS] ===\nTreasury: %s\n\n", c.name, BF.FormatMoney(c.treasury))
                for sname, sec in pairs(BF.State.sectors) do
                    if sec.side == side then
                        local lvl = sec.level or 1
                        local nxtText = (lvl < 3) and string.format(" [Next: Lvl %d ($%dM)]", lvl + 1, BF.Config.upgradeCosts[lvl + 1]) or " [MAX]"
                        msg = msg .. string.format(" - %s: Level %d ($%dM/5m)%s\n", sname, lvl, sec.income, nxtText)
                    end
                end
                BF.Broadcast(msg, side, 18)
            end)

            for sname, sec in pairs(BF.State.sectors) do
                local sRef = sname
                missionCommands.addCommandForCoalition(side, radioCaption(string.format("Upgrade %s", sRef)), upgMenu, function()
                    BF.UpgradeSector(side, sRef)
                end)
            end

            -- 2. R&D Tech Tree Submenu
            local rdMenu = missionCommands.addSubMenuForCoalition(side, "R&D Department (Blueprints)", nil)

            missionCommands.addCommandForCoalition(side, "View Blueprint Catalog", rdMenu, function()
                local c = BF.State.coalitions[side]
                local bpList = BF.Config.blueprints[side] or {}
                local msg = string.format("=== [%s ADVANCED R&D CATALOG] ===\nAvailable Capital: %s\n\n",
                    c.name, BF.FormatMoney(c.treasury))
                for planeKey, bp in pairs(bpList) do
                    local status
                    if c.unlockedBlueprints[planeKey] then
                        status = "RESEARCHED & UNLOCKED"
                    elseif c.treasury >= bp.cost then
                        status = string.format("READY TO PURCHASE (Cost: %s)", BF.FormatMoney(bp.cost))
                    else
                        status = string.format("LOCKED (Cost: %s)", BF.FormatMoney(bp.cost))
                    end
                    msg = msg .. string.format("%s\n   Status: %s\n   Role: %s\n\n", bp.name, status, bp.desc)
                end
                msg = msg .. "F10 purchases use the listed price. Director purchases use the same coalition treasury."
                BF.Broadcast(msg, side, 20)
            end)

            local bpList = BF.Config.blueprints[side] or {}
            for planeKey, bp in pairs(bpList) do
                local cmdTitle = radioCaption(string.format("Unlock %s (%s)", planeKey, BF.FormatMoney(bp.cost)))
                missionCommands.addCommandForCoalition(side, cmdTitle, rdMenu, function()
                    BF.PurchaseBlueprint(side, planeKey, "f10")
                end)
            end

            -- 3. Battlefront EWR Picture Report Submenu
            local ewrMenu = missionCommands.addSubMenuForCoalition(side, "Battlefront EWR & Picture", nil)
            missionCommands.addCommandForCoalition(side, "Request Picture Report (Now)", ewrMenu, function()
                BF.EWR.SendPictureReportForSide(side)
            end)
            missionCommands.addCommandForCoalition(side, "Toggle 20s Auto-Picture Reports", ewrMenu, function()
                BF.State.coalitionEwrDisabled[side] = not BF.State.coalitionEwrDisabled[side]
                local st = BF.State.coalitionEwrDisabled[side] and "DISABLED" or "ENABLED (Every 20s)"
                BF.Broadcast(string.format("Battlefront EWR Auto-Reports are now %s.", st), side, 8)
            end)

            -- 4. Weapons & Avionics Test Range Submenu
            local rangeMenu = missionCommands.addSubMenuForCoalition(side, "Weapons Test Range", nil)
            missionCommands.addCommandForCoalition(side, "Range Coordinates & Visual Markers", rangeMenu, function()
                local msg = (side == SIDE_BLUE) and
                    "=== BLUFOR WEAPONS & AVIONICS TEST RANGE ===\n" ..
                    "- Location: 10 km North of Sukhumi (Grid: x = -230000, z = 490000)\n" ..
                    "- Marker: Orange Smoke + F10 Map Circle #7001\n" ..
                    "- Ground Park: 8x Stationary Red Armor & Trucks (T-72, BMP-2, BTR-80, Ural)\n" ..
                    "- Air Drones: 2x Gun-Only Hostile Jets in Racetrack Orbit (MiG-29S @ 2500m, Su-27 @ 4500m)\n" ..
                    "- Systems Note: Drones will NOT fire missiles. Perfect for radar/TWS lock, gun pipper, and Maverick/bomb tests."
                    or
                    "=== REDFOR WEAPONS & AVIONICS TEST RANGE ===\n" ..
                    "- Location: South of Armavir / West of Nalchik (Grid: x = -90000, z = 490000)\n" ..
                    "- Marker: Red Smoke + F10 Map Circle #7002\n" ..
                    "- Ground Park: 8x Stationary Blue Armor & Trucks (M1A2, M2 Bradley, M113, Hummer)\n" ..
                    "- Air Drones: 2x Gun-Only Hostile Jets in Racetrack Orbit (F-15C @ 2500m, F-16C @ 4500m)\n" ..
                    "- Systems Note: Drones will NOT fire missiles. Perfect for radar/EO lock, gun pipper, and Vikhr/Kh-25/bomb tests."
                BF.Broadcast(msg, side, 20)
            end)
            missionCommands.addCommandForCoalition(side, "Respawn Test Range Targets & Smoke", rangeMenu, function()
                BF.SpawnWeaponsTestRanges()
                BF.Broadcast("Weapons Test Range targets, drones, and smoke markers have been respawned!", side, 10)
            end)
        end
    end)

end
