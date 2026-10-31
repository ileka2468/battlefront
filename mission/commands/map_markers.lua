-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - F10 MAP MARKER TACTICAL SUPPORT
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

BF.Commands = BF.Commands or {}
BF.Commands.MapMarkers = BF.Commands.MapMarkers or {}

local SIDE_RED  = BF.SIDE_RED or 1
local SIDE_BLUE = BF.SIDE_BLUE or 2
local SIDE_ALL  = BF.SIDE_ALL or -1

local dropCounter = 9000

local function log(msg) BF.Log(msg) end

function BF.ProcessMapMarkerCommand(event)
    if not event or not event.text or not event.pos then return end

    local rawText = event.text:lower()
    -- Trim whitespace
    rawText = rawText:gsub("^%s+", ""):gsub("%s+$", "")
    if not rawText:match("^[-%+]") then return end -- must start with - or +

    local px = event.pos.x
    local pz = event.pos.z

    -- Determine Coalition Safely
    local side = nil
    if event.initiator and event.initiator.getCoalition then
        side = event.initiator:getCoalition()
    elseif event.coalition and event.coalition > 0 then
        side = event.coalition
    else
        side = (px > -165000) and SIDE_RED or SIDE_BLUE
    end

    local coal = BF.State.coalitions[side]
    if not coal then return end

    local playerName = (event.initiator and event.initiator.getPlayerName) and event.initiator:getPlayerName() or "Tactical Pilot"

    -- --------------------------------------------------------------------------
    -- COMMAND: -drop ewr / -call ewr / -ewr
    -- --------------------------------------------------------------------------
    if rawText:match("ewr") then
        local cost = BF.Config.cargoCosts["ewr"] or 75
        if coal.treasury < cost then
            local msg = string.format("❌ CARGO DROP REJECTED: Insufficient War Chest for Tactical EWR Radar!\nCost: %s | Available Balance: %s",
                BF.FormatMoney(cost), BF.FormatMoney(coal.treasury))
            BF.Broadcast(msg, side, 12)
            pcall(function() trigger.action.removeMark(event.idx) end)
            return
        end

        coal.treasury = coal.treasury - cost
        dropCounter = dropCounter + 1
        local gname = string.format("TACTICAL_EWR_%d_%d", side, dropCounter)
        local radarType = (side == SIDE_BLUE) and "1L13 EWR" or "55G6 EWR"
        local escortType = (side == SIDE_BLUE) and "Soldier stinger" or "SA-18 Igla-S manpad"
        local countryId = (side == SIDE_BLUE) and country.id.USA or country.id.RUSSIA

        local groupData = {
            ["visible"] = true,
            ["tasks"] = {},
            ["uncontrolled"] = false,
            ["route"] = { ["points"] = { [1] = { ["alt"] = 0, ["type"] = "Turning Point", ["action"] = "Off Road", ["speed"] = 0, ["x"] = px, ["y"] = pz } } },
            ["groupId"] = dropCounter,
            ["name"] = gname,
            ["units"] = {
                [1] = { ["type"] = radarType,  ["unitId"] = dropCounter + 1, ["name"] = gname .. "_RADAR", ["x"] = px,      ["y"] = pz,      ["heading"] = 0, ["skill"] = "High", ["playerCanDrive"] = false },
                [2] = { ["type"] = escortType, ["unitId"] = dropCounter + 2, ["name"] = gname .. "_DEF",   ["x"] = px + 30, ["y"] = pz - 20, ["heading"] = 0, ["skill"] = "High", ["playerCanDrive"] = false },
            }
        }

        pcall(function()
            coalition.addGroup(countryId, Group.Category.GROUND, groupData)
            trigger.action.removeMark(event.idx)
            trigger.action.circleToAll(side, 8000 + dropCounter, {x = px, y = 0, z = pz}, 2500, {0.2, 0.8, 1.0, 0.8}, {0,0,0,0}, 1, true, "📡 Mobile Tactical EWR (Operational Datalink)")
            table.insert(BF.State.radarStations, { side = side, unitName = gname .. "_RADAR", isAwacs = false, label = "Mobile EWR" })
        end)

        local confirmMsg = string.format("📡 [%s CARGO AIRDROP DELIVERED]\n%s called in a Mobile Tactical EWR Radar at grid! (%s deducted).\nDatalink coverage established in sector. Treasury: %s",
            coal.name, playerName, BF.FormatMoney(cost), BF.FormatMoney(coal.treasury))
        BF.Broadcast(confirmMsg, side, 14)
        log(confirmMsg)
        BF.SaveState()
        return
    end

    -- --------------------------------------------------------------------------
    -- COMMAND: -call awacs / -drop awacs / -awacs
    -- --------------------------------------------------------------------------
    if rawText:match("awacs") then
        -- 1. Check R&D Blueprint Prerequisite
        if not coal.unlockedBlueprints["AWACS"] then
            local msg = string.format("❌ AWACS REQUEST DENIED: Airborne Datalink Program NOT researched!\nAllocate %s in the F10 R&D Menu to unlock theater AWACS capability.",
                BF.FormatMoney(BF.Config.blueprints[side]["AWACS"].cost))
            BF.Broadcast(msg, side, 14)
            pcall(function() trigger.action.removeMark(event.idx) end)
            return
        end

        -- 2. Check Sector / Distance Overlap (Ensure no existing AWACS within 60 km)
        for _, aw in pairs(BF.State.activeAwacs[side]) do
            local dist = math.sqrt((px - aw.x)^2 + (pz - aw.z)^2)
            if dist < 60000 then
                local msg = string.format("⚠ AWACS ALREADY ACTIVE in this quadrant!\n%s is currently orbiting within %d km of requested coordinates.",
                    aw.callsign, math.floor(dist / 1000))
                BF.Broadcast(msg, side, 12)
                pcall(function() trigger.action.removeMark(event.idx) end)
                return
            end
        end

        -- 3. Check Sortie Cost
        local cost = BF.Config.cargoCosts["awacs"] or 200
        if coal.treasury < cost then
            local msg = string.format("❌ AWACS SORTIE REJECTED: Insufficient treasury!\nCost: %s | Balance: %s",
                BF.FormatMoney(cost), BF.FormatMoney(coal.treasury))
            BF.Broadcast(msg, side, 12)
            pcall(function() trigger.action.removeMark(event.idx) end)
            return
        end

        coal.treasury = coal.treasury - cost
        dropCounter = dropCounter + 10
        local gname = string.format("AWACS_SORTIE_%d_%d", side, dropCounter)
        local uname = gname .. "_AIR"
        local awacsPlane = (side == SIDE_BLUE) and "E-3A" or "A-50"
        local callsignName = (side == SIDE_BLUE) and "Magic" or "Overlord"
        local freq = (side == SIDE_BLUE) and 251000000 or 250000000
        local countryId = (side == SIDE_BLUE) and country.id.USA or country.id.RUSSIA

        local groupData = {
            ["visible"] = true,
            ["tasks"] = {},
            ["uncontrolled"] = false,
            ["route"] = {
                ["points"] = {
                    [1] = {
                        ["alt"] = 9144, -- 30,000 ft (FL300)
                        ["type"] = "Turning Point",
                        ["action"] = "Turning Point",
                        ["speed"] = 220,
                        ["x"] = px,
                        ["y"] = pz,
                        ["task"] = {
                            ["id"] = "ComboTask",
                            ["params"] = {
                                ["tasks"] = {
                                    [1] = { ["id"] = "AWACS", ["enabled"] = true, ["auto"] = true, ["params"] = {} },
                                    [2] = { ["id"] = "Orbit", ["enabled"] = true, ["auto"] = false, ["params"] = { ["pattern"] = "Race-Track", ["altitude"] = 9144, ["speed"] = 220 } },
                                },
                            },
                        },
                    },
                    [2] = {
                        ["alt"] = 9144,
                        ["type"] = "Turning Point",
                        ["action"] = "Turning Point",
                        ["speed"] = 220,
                        ["x"] = px + 25000,
                        ["y"] = pz,
                    }
                }
            },
            ["groupId"] = dropCounter,
            ["name"] = gname,
            ["units"] = {
                [1] = {
                    ["type"] = awacsPlane,
                    ["unitId"] = dropCounter + 1,
                    ["name"] = uname,
                    ["x"] = px,
                    ["y"] = pz,
                    ["alt"] = 9144,
                    ["speed"] = 220,
                    ["heading"] = 0,
                    ["skill"] = "High",
                    ["communication"] = true,
                    ["frequency"] = freq,
                    ["callsign"] = { ["1"] = 1, ["2"] = 1, ["3"] = 1, ["name"] = callsignName .. "11" },
                }
            }
        }

        pcall(function()
            coalition.addGroup(countryId, Group.Category.AIRPLANE, groupData)
            trigger.action.removeMark(event.idx)
            trigger.action.circleToAll(side, 8500 + dropCounter, {x = px, y = 0, z = pz}, 15000, {0.3, 0.9, 0.2, 0.7}, {0,0,0,0}, 2, true, "📡 " .. callsignName .. " (AWACS Orbit FL300 - " .. tostring(freq/1000000) .. " MHz)")
        end)

        table.insert(BF.State.activeAwacs[side], { name = uname, x = px, z = pz, callsign = callsignName })
        table.insert(BF.State.radarStations, { side = side, unitName = uname, isAwacs = true, label = callsignName .. " (AWACS)" })

        local confirmMsg = string.format("★★★ AIRBORNE EARLY WARNING DEPLOYED (%s) ★★★\n%s called in %s (AWACS) on station at FL300 over coordinates!\nFrequency: %.1f MHz AM | Full 360° Airborne Datalink Synchronized!\nTreasury: %s",
            coal.name, playerName, callsignName, freq / 1000000, BF.FormatMoney(coal.treasury))
        BF.Broadcast(confirmMsg, side, 16)
        log(confirmMsg)
        BF.SaveState()
        return
    end

    -- --------------------------------------------------------------------------
    -- COMMAND: -drop shorad / -drop pd / -shorad
    -- --------------------------------------------------------------------------
    if rawText:match("shorad") or rawText:match("pd") then
        local cost = BF.Config.cargoCosts["shorad"] or 125
        if coal.treasury < cost then
            local msg = string.format("❌ POINT DEFENSE DROP REJECTED: Insufficient funds!\nCost: %s | Balance: %s",
                BF.FormatMoney(cost), BF.FormatMoney(coal.treasury))
            BF.Broadcast(msg, side, 12)
            pcall(function() trigger.action.removeMark(event.idx) end)
            return
        end

        coal.treasury = coal.treasury - cost
        dropCounter = dropCounter + 10
        local gname = string.format("TACTICAL_SHORAD_%d_%d", side, dropCounter)
        local shorad = (side == SIDE_BLUE) and "M1097 Avenger" or "2S6 Tunguska"
        local manpad = (side == SIDE_BLUE) and "Soldier stinger" or "SA-18 Igla-S manpad"
        local countryId = (side == SIDE_BLUE) and country.id.USA or country.id.RUSSIA

        local groupData = {
            ["visible"] = true,
            ["tasks"] = {},
            ["uncontrolled"] = false,
            ["route"] = { ["points"] = { [1] = { ["alt"] = 0, ["type"] = "Turning Point", ["action"] = "Off Road", ["speed"] = 0, ["x"] = px, ["y"] = pz } } },
            ["groupId"] = dropCounter,
            ["name"] = gname,
            ["units"] = {
                [1] = { ["type"] = shorad, ["unitId"] = dropCounter + 1, ["name"] = gname .. "_SHORAD", ["x"] = px,      ["y"] = pz,      ["heading"] = 0, ["skill"] = "High", ["playerCanDrive"] = false },
                [2] = { ["type"] = manpad, ["unitId"] = dropCounter + 2, ["name"] = gname .. "_MANPAD", ["x"] = px + 25, ["y"] = pz + 20, ["heading"] = 0, ["skill"] = "High", ["playerCanDrive"] = false },
            }
        }

        pcall(function()
            coalition.addGroup(countryId, Group.Category.GROUND, groupData)
            trigger.action.removeMark(event.idx)
            trigger.action.circleToAll(side, 8800 + dropCounter, {x = px, y = 0, z = pz}, 1500, {0.9, 0.6, 0.2, 0.8}, {0,0,0,0}, 1, true, "🛡 Forward Point Defense (Avenger/Tunguska)")
        end)

        local confirmMsg = string.format("🛡 [%s POINT DEFENSE AIRDROP DEPLOYED]\n%s called in Tactical SHORAD & MANPADS team! (%s deducted).\nAir defense established. Treasury: %s",
            coal.name, playerName, BF.FormatMoney(cost), BF.FormatMoney(coal.treasury))
        BF.Broadcast(confirmMsg, side, 14)
        log(confirmMsg)
        BF.SaveState()
        return
    end

    -- --------------------------------------------------------------------------
    -- RESTRICTION ENFORCEMENT: Strategic SAMs (Reserved for CTLD Helos & C-130)
    -- --------------------------------------------------------------------------
    if rawText:match("sam") or rawText:match("patriot") or rawText:match("s300") or rawText:match("hawk") or rawText:match("buk") then
        pcall(function() trigger.action.removeMark(event.idx) end)
        local blockMsg = string.format("❌ CTLD LOGISTICS RESTRICTION (%s):\nHeavy Strategic SAM Batteries (Patriot/S-300) CANNOT be airdropped by tactical fighters!\nMajor air defense networks must be deployed via CTLD transport helicopters (UH-60, Mi-8, Chinook) or C-130 logistics flights.", playerName)
        BF.Broadcast(blockMsg, side, 14)
        return
    end

    -- --------------------------------------------------------------------------
    -- RESTRICTION ENFORCEMENT: Automated AI Bombers Prohibited
    -- --------------------------------------------------------------------------
    if rawText:match("bomber") or rawText:match("strike") or rawText:match("b52") or rawText:match("tu95") or rawText:match("tu22") then
        pcall(function() trigger.action.removeMark(event.idx) end)
        local blockMsg = string.format("❌ SERVER RESTRICTION (%s):\nAutomated AI strategic bombers are DISABLED on this theater!\nAll high-stakes strike sorties must be human-flown in F-117A Nighthawk or Su-34 airframes.", playerName)
        BF.Broadcast(blockMsg, side, 14)
        return
    end
end

-- ------------------------------------------------------------------------------
-- MAP MARKER EVENT HANDLER
-- ------------------------------------------------------------------------------
local MarkHandler = {}
function MarkHandler:onEvent(event)
    if not event then return end
    if event.id == world.event.S_EVENT_MARK_ADDED or event.id == world.event.S_EVENT_MARK_CHANGE then
        pcall(function() BF.ProcessMapMarkerCommand(event) end)
    end
end

BF.Commands.MapMarkers.Handler = MarkHandler
BF.Commands.MapMarkers.ProcessCommand = BF.ProcessMapMarkerCommand

