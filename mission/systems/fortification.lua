-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - SECTOR FORTIFICATION & DEFENDERS
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

BF.Fortification = BF.Fortification or {}

local SIDE_RED  = BF.SIDE_RED or 1
local SIDE_BLUE = BF.SIDE_BLUE or 2

local function log(msg) BF.Log(msg) end

-- ------------------------------------------------------------------------------
-- 4. POINT DEFENSE SPAWNING (SHORAD, AAA, MANPADS & ARMOR)
-- ------------------------------------------------------------------------------
local spawnCounter = 1000

function BF.SpawnSectorPointDefense(secName, side)
    local sec = BF.State.sectors[secName]
    if not sec then return end

    local countryId = (side == SIDE_BLUE) and country.id.USA or country.id.RUSSIA
    local px = sec.pos.x
    local pz = sec.pos.z

    spawnCounter = spawnCounter + 1
    local gname = string.format("GARRISON_%s_%d", secName:gsub("%s+", "_"), spawnCounter)

    -- Composition: 1 SHORAD, 1 AAA, 1 MANPADS, 1 Armor
    local units = {}
    if side == SIDE_BLUE then
        units = {
            { type = "M1097 Avenger", name = gname .. "_SHORAD", dx = 120, dz = 60 },
            { type = "Vulcan",        name = gname .. "_AAA",    dx = -90, dz = -80 },
            { type = "Soldier stinger", name = gname .. "_MANPAD", dx = 40, dz = -50 },
            { type = "M2A2 Bradley",  name = gname .. "_ARMOR",  dx = -40, dz = 70 },
        }
    else
        units = {
            { type = "2S6 Tunguska",  name = gname .. "_SHORAD", dx = 120, dz = 60 },
            { type = "ZSU-23-4 Shilka", name = gname .. "_AAA",  dx = -90, dz = -80 },
            { type = "SA-18 Igla-S manpad", name = gname .. "_MANPAD", dx = 40, dz = -50 },
            { type = "BMP-3",         name = gname .. "_ARMOR",  dx = -40, dz = 70 },
        }
    end

    local dcsUnits = {}
    sec.defenders = {}

    for idx, u in ipairs(units) do
        spawnCounter = spawnCounter + 1
        table.insert(dcsUnits, {
            ["type"] = u.type,
            ["unitId"] = spawnCounter,
            ["name"] = u.name,
            ["x"] = px + u.dx,
            ["y"] = pz + u.dz,
            ["heading"] = 0,
            ["skill"] = "High",
            ["playerCanDrive"] = false,
        })
        sec.defenders[u.name] = true
    end
    sec.groupName = gname
    sec.isCulled = false

    local groupData = {
        ["visible"] = true,
        ["tasks"] = {},
        ["uncontrolled"] = false,
        ["route"] = {
            ["points"] = {
                [1] = {
                    ["alt"] = 0,
                    ["type"] = "Turning Point",
                    ["action"] = "Off Road",
                    ["speed"] = 0,
                    ["x"] = px,
                    ["y"] = pz,
                }
            }
        },
        ["groupId"] = spawnCounter,
        ["name"] = gname,
        ["units"] = dcsUnits,
    }

    pcall(function()
        coalition.addGroup(countryId, Group.Category.GROUND, groupData)
        log(string.format("BATTLEFRONT: Spawned point defense garrison for %s (Side: %d)", secName, side))
    end)
end

-- ------------------------------------------------------------------------------
-- 4B. BASELINE EWR & FIGHTER CARGO DROP ENGINE (F10 Map Marker Codes)
-- ------------------------------------------------------------------------------


BF.Fortification.SpawnSectorDefenders = BF.SpawnSectorPointDefense
BF.SpawnSectorDefenders = BF.SpawnSectorPointDefense
