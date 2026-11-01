-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - WEAPONS & AVIONICS TEST RANGES
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

BF.TestRanges = BF.TestRanges or {}

local SIDE_RED  = BF.SIDE_RED or 1
local SIDE_BLUE = BF.SIDE_BLUE or 2
local SIDE_ALL  = BF.SIDE_ALL or -1

local function log(msg) BF.Log(msg) end

function BF.SpawnWeaponsTestRanges()
    BF.State.testRangeGroups = BF.State.testRangeGroups or {}
    for _, gname in ipairs(BF.State.testRangeGroups) do
        pcall(function()
            local grp = Group.getByName(gname)
            if grp and grp:isExist() then
                grp:destroy()
            end
        end)
    end
    BF.State.testRangeGroups = {}
    log("BATTLEFRONT: Weapons Test Ranges disabled for active Contention campaign.")
    return
end

function BF.OldDisabled_SpawnWeaponsTestRanges()

    -- A. Stationary Red Ground Target Park (Unarmed Target Dummies)
    testCounter = testCounter + 1
    local bGroundGroupName = "TARGET_RANGE_BLUFOR_GROUND_" .. testCounter
    table.insert(BF.State.testRangeGroups, bGroundGroupName)
    local bTargets = {
        { type = "T-72B",           name = bGroundGroupName .. "_T72_1",  dx = -40, dz = -30 },
        { type = "T-72B",           name = bGroundGroupName .. "_T72_2",  dx = -20, dz = -30 },
        { type = "BMP-2",           name = bGroundGroupName .. "_BMP_1",  dx = 20,  dz = -30 },
        { type = "BMP-2",           name = bGroundGroupName .. "_BMP_2",  dx = 40,  dz = -30 },
        { type = "BTR-80",          name = bGroundGroupName .. "_BTR_1",  dx = -30, dz = 30 },
        { type = "BTR-80",          name = bGroundGroupName .. "_BTR_2",  dx = -10, dz = 30 },
        { type = "Ural-375",        name = bGroundGroupName .. "_TRUCK1", dx = 15,  dz = 30 },
        { type = "Ural-375",        name = bGroundGroupName .. "_TRUCK2", dx = 35,  dz = 30 },
    }
    local bDcsUnits = {}
    for idx, u in ipairs(bTargets) do
        testCounter = testCounter + 1
        table.insert(bDcsUnits, {
            ["type"] = u.type,
            ["unitId"] = testCounter,
            ["name"] = u.name,
            ["x"] = bRangeX + u.dx,
            ["y"] = bRangeZ + u.dz,
            ["heading"] = 0,
            ["skill"] = "Average",
            ["playerCanDrive"] = false,
        })
    end
    local bGroundGroupData = {
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
                    ["x"] = bRangeX,
                    ["y"] = bRangeZ,
                }
            }
        },
        ["groupId"] = testCounter + 10,
        ["name"] = bGroundGroupName,
        ["units"] = bDcsUnits,
    }
    pcall(function()
        coalition.addGroup(country.id.RUSSIA, Group.Category.GROUND, bGroundGroupData)
        local grp = Group.getByName(bGroundGroupName)
        if grp then
            local ctrl = grp:getController()
            if ctrl then
                ctrl:setOption(AI.Option.Ground.val.ROE, AI.Option.Ground.val.ROE.WEAPON_HOLD)
            end
        end
        trigger.action.circleToAll(SIDE_ALL, 7001, {x = bRangeX, y = 0, z = bRangeZ}, 2500, {1.0, 0.4, 0.1, 0.8}, {0,0,0,0}, 2, true, "🎯 BLUFOR WEAPONS TEST RANGE (Ground Armor & Drones)")
        trigger.action.smoke({x = bRangeX, y = land.getHeight({x=bRangeX, y=bRangeZ}) + 2, z = bRangeZ}, trigger.smokeColor.Orange)
    end)

    -- B. Airborne Target Drone 1 (Gun-Only Red MiG-29S in Race-Track Orbit at 2,500m)
    testCounter = testCounter + 20
    local bAirDroneGroupName1 = "TARGET_DRONE_RED_MIG29_" .. testCounter
    table.insert(BF.State.testRangeGroups, bAirDroneGroupName1)
    local bAirGroupData1 = {
        ["visible"] = true,
        ["tasks"] = {},
        ["uncontrolled"] = false,
        ["route"] = {
            ["points"] = {
                [1] = {
                    ["alt"] = 2500,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point",
                    ["speed"] = 180,
                    ["x"] = bRangeX,
                    ["y"] = bRangeZ,
                    ["task"] = {
                        ["id"] = "ComboTask",
                        ["params"] = {
                            ["tasks"] = {
                                [1] = { ["id"] = "Orbit", ["enabled"] = true, ["auto"] = false, ["params"] = { ["pattern"] = "Race-Track", ["altitude"] = 2500, ["speed"] = 180 } },
                            },
                        },
                    },
                },
                [2] = {
                    ["alt"] = 2500,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point",
                    ["speed"] = 180,
                    ["x"] = bRangeX + 15000,
                    ["y"] = bRangeZ,
                }
            }
        },
        ["groupId"] = testCounter,
        ["name"] = bAirDroneGroupName1,
        ["units"] = {
            [1] = {
                ["type"] = "MiG-29S",
                ["unitId"] = testCounter + 1,
                ["name"] = bAirDroneGroupName1 .. "_U1",
                ["x"] = bRangeX,
                ["y"] = bRangeZ,
                ["alt"] = 2500,
                ["speed"] = 180,
                ["heading"] = 0,
                ["skill"] = "Average",
                ["communication"] = true,
                ["payload"] = {
                    ["pylons"] = {},
                    ["fuel"] = 3500,
                    ["flare"] = 60,
                    ["chaff"] = 60,
                    ["gun"] = 100,
                },
            }
        }
    }
    pcall(function()
        coalition.addGroup(country.id.RUSSIA, Group.Category.AIRPLANE, bAirGroupData1)
        local grp = Group.getByName(bAirDroneGroupName1)
        if grp then
            local ctrl = grp:getController()
            if ctrl then
                ctrl:setOption(AI.Option.Air.val.ROE, AI.Option.Air.val.ROE.WEAPON_HOLD)
                ctrl:setOption(AI.Option.Air.val.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.NO_REACTION)
            end
        end
    end)

    -- C. Airborne Target Drone 2 (Gun-Only Red Su-27 in Race-Track Orbit at 4,500m)
    testCounter = testCounter + 20
    local bAirDroneGroupName2 = "TARGET_DRONE_RED_SU27_" .. testCounter
    table.insert(BF.State.testRangeGroups, bAirDroneGroupName2)
    local bAirGroupData2 = {
        ["visible"] = true,
        ["tasks"] = {},
        ["uncontrolled"] = false,
        ["route"] = {
            ["points"] = {
                [1] = {
                    ["alt"] = 4500,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point",
                    ["speed"] = 200,
                    ["x"] = bRangeX + 2000,
                    ["y"] = bRangeZ + 2000,
                    ["task"] = {
                        ["id"] = "ComboTask",
                        ["params"] = {
                            ["tasks"] = {
                                [1] = { ["id"] = "Orbit", ["enabled"] = true, ["auto"] = false, ["params"] = { ["pattern"] = "Race-Track", ["altitude"] = 4500, ["speed"] = 200 } },
                            },
                        },
                    },
                },
                [2] = {
                    ["alt"] = 4500,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point",
                    ["speed"] = 200,
                    ["x"] = bRangeX + 17000,
                    ["y"] = bRangeZ + 2000,
                }
            }
        },
        ["groupId"] = testCounter,
        ["name"] = bAirDroneGroupName2,
        ["units"] = {
            [1] = {
                ["type"] = "Su-27",
                ["unitId"] = testCounter + 1,
                ["name"] = bAirDroneGroupName2 .. "_U1",
                ["x"] = bRangeX + 2000,
                ["y"] = bRangeZ + 2000,
                ["alt"] = 4500,
                ["speed"] = 200,
                ["heading"] = 0,
                ["skill"] = "Average",
                ["communication"] = true,
                ["payload"] = {
                    ["pylons"] = {},
                    ["fuel"] = 5500,
                    ["flare"] = 60,
                    ["chaff"] = 60,
                    ["gun"] = 100,
                },
            }
        }
    }
    pcall(function()
        coalition.addGroup(country.id.RUSSIA, Group.Category.AIRPLANE, bAirGroupData2)
        local grp = Group.getByName(bAirDroneGroupName2)
        if grp then
            local ctrl = grp:getController()
            if ctrl then
                ctrl:setOption(AI.Option.Air.val.ROE, AI.Option.Air.val.ROE.WEAPON_HOLD)
                ctrl:setOption(AI.Option.Air.val.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.NO_REACTION)
            end
        end
    end)


    -- 2. REDFOR WEAPONS TEST RANGE (Near Kuban/Krasnodar plains)
    -- Position: x = -90000, z = 490000 (~30 km South of REDFOR Air Spawn)
    local rRangeX = -90000
    local rRangeZ = 490000

    -- A. Stationary Blue Ground Target Park (Unarmed Target Dummies)
    testCounter = testCounter + 30
    local rGroundGroupName = "TARGET_RANGE_REDFOR_GROUND_" .. testCounter
    table.insert(BF.State.testRangeGroups, rGroundGroupName)
    local rTargets = {
        { type = "M-1 Abrams",      name = rGroundGroupName .. "_M1A2_1",  dx = -40, dz = -30 },
        { type = "M-1 Abrams",      name = rGroundGroupName .. "_M1A2_2",  dx = -20, dz = -30 },
        { type = "M-2 Bradley",     name = rGroundGroupName .. "_M2A2_1",  dx = 20,  dz = -30 },
        { type = "M-2 Bradley",     name = rGroundGroupName .. "_M2A2_2",  dx = 40,  dz = -30 },
        { type = "M113",            name = rGroundGroupName .. "_M113_1",  dx = -30, dz = 30 },
        { type = "M113",            name = rGroundGroupName .. "_M113_2",  dx = -10, dz = 30 },
        { type = "Hummer",          name = rGroundGroupName .. "_HMMWV1", dx = 15,  dz = 30 },
        { type = "Hummer",          name = rGroundGroupName .. "_HMMWV2", dx = 35,  dz = 30 },
    }
    local rDcsUnits = {}
    for idx, u in ipairs(rTargets) do
        testCounter = testCounter + 1
        table.insert(rDcsUnits, {
            ["type"] = u.type,
            ["unitId"] = testCounter,
            ["name"] = u.name,
            ["x"] = rRangeX + u.dx,
            ["y"] = rRangeZ + u.dz,
            ["heading"] = 0,
            ["skill"] = "Average",
            ["playerCanDrive"] = false,
        })
    end
    local rGroundGroupData = {
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
                    ["x"] = rRangeX,
                    ["y"] = rRangeZ,
                }
            }
        },
        ["groupId"] = testCounter + 10,
        ["name"] = rGroundGroupName,
        ["units"] = rDcsUnits,
    }
    pcall(function()
        coalition.addGroup(country.id.USA, Group.Category.GROUND, rGroundGroupData)
        local grp = Group.getByName(rGroundGroupName)
        if grp then
            local ctrl = grp:getController()
            if ctrl then
                ctrl:setOption(AI.Option.Ground.val.ROE, AI.Option.Ground.val.ROE.WEAPON_HOLD)
            end
        end
        trigger.action.circleToAll(SIDE_ALL, 7002, {x = rRangeX, y = 0, z = rRangeZ}, 2500, {0.2, 0.6, 1.0, 0.8}, {0,0,0,0}, 2, true, "🎯 REDFOR WEAPONS TEST RANGE (Ground Armor & Drones)")
        trigger.action.smoke({x = rRangeX, y = land.getHeight({x=rRangeX, y=rRangeZ}) + 2, z = rRangeZ}, trigger.smokeColor.Red)
    end)

    -- B. Airborne Target Drone 1 (Gun-Only Blue F-15C in Race-Track Orbit at 2,500m)
    testCounter = testCounter + 20
    local rAirDroneGroupName1 = "TARGET_DRONE_BLUE_F15C_" .. testCounter
    table.insert(BF.State.testRangeGroups, rAirDroneGroupName1)
    local rAirGroupData1 = {
        ["visible"] = true,
        ["tasks"] = {},
        ["uncontrolled"] = false,
        ["route"] = {
            ["points"] = {
                [1] = {
                    ["alt"] = 2500,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point",
                    ["speed"] = 180,
                    ["x"] = rRangeX,
                    ["y"] = rRangeZ,
                    ["task"] = {
                        ["id"] = "ComboTask",
                        ["params"] = {
                            ["tasks"] = {
                                [1] = { ["id"] = "Orbit", ["enabled"] = true, ["auto"] = false, ["params"] = { ["pattern"] = "Race-Track", ["altitude"] = 2500, ["speed"] = 180 } },
                            },
                        },
                    },
                },
                [2] = {
                    ["alt"] = 2500,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point",
                    ["speed"] = 180,
                    ["x"] = rRangeX + 15000,
                    ["y"] = rRangeZ,
                }
            }
        },
        ["groupId"] = testCounter,
        ["name"] = rAirDroneGroupName1,
        ["units"] = {
            [1] = {
                ["type"] = "F-15C",
                ["unitId"] = testCounter + 1,
                ["name"] = rAirDroneGroupName1 .. "_U1",
                ["x"] = rRangeX,
                ["y"] = rRangeZ,
                ["alt"] = 2500,
                ["speed"] = 180,
                ["heading"] = 3.14159,
                ["skill"] = "Average",
                ["communication"] = true,
                ["payload"] = {
                    ["pylons"] = {},
                    ["fuel"] = 6100,
                    ["flare"] = 60,
                    ["chaff"] = 60,
                    ["gun"] = 100,
                },
            }
        }
    }
    pcall(function()
        coalition.addGroup(country.id.USA, Group.Category.AIRPLANE, rAirGroupData1)
        local grp = Group.getByName(rAirDroneGroupName1)
        if grp then
            local ctrl = grp:getController()
            if ctrl then
                ctrl:setOption(AI.Option.Air.val.ROE, AI.Option.Air.val.ROE.WEAPON_HOLD)
                ctrl:setOption(AI.Option.Air.val.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.NO_REACTION)
            end
        end
    end)

    -- C. Airborne Target Drone 2 (Gun-Only Blue F-16C in Race-Track Orbit at 4,500m)
    testCounter = testCounter + 20
    local rAirDroneGroupName2 = "TARGET_DRONE_BLUE_F16C_" .. testCounter
    table.insert(BF.State.testRangeGroups, rAirDroneGroupName2)
    local rAirGroupData2 = {
        ["visible"] = true,
        ["tasks"] = {},
        ["uncontrolled"] = false,
        ["route"] = {
            ["points"] = {
                [1] = {
                    ["alt"] = 4500,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point",
                    ["speed"] = 200,
                    ["x"] = rRangeX + 2000,
                    ["y"] = rRangeZ + 2000,
                    ["task"] = {
                        ["id"] = "ComboTask",
                        ["params"] = {
                            ["tasks"] = {
                                [1] = { ["id"] = "Orbit", ["enabled"] = true, ["auto"] = false, ["params"] = { ["pattern"] = "Race-Track", ["altitude"] = 4500, ["speed"] = 200 } },
                            },
                        },
                    },
                },
                [2] = {
                    ["alt"] = 4500,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point",
                    ["speed"] = 200,
                    ["x"] = rRangeX + 17000,
                    ["y"] = rRangeZ + 2000,
                }
            }
        },
        ["groupId"] = testCounter,
        ["name"] = rAirDroneGroupName2,
        ["units"] = {
            [1] = {
                ["type"] = "F-16C_50",
                ["unitId"] = testCounter + 1,
                ["name"] = rAirDroneGroupName2 .. "_U1",
                ["x"] = rRangeX + 2000,
                ["y"] = rRangeZ + 2000,
                ["alt"] = 4500,
                ["speed"] = 200,
                ["heading"] = 3.14159,
                ["skill"] = "Average",
                ["communication"] = true,
                ["payload"] = {
                    ["pylons"] = {},
                    ["fuel"] = 3200,
                    ["flare"] = 60,
                    ["chaff"] = 60,
                    ["gun"] = 100,
                },
            }
        }
    }
    pcall(function()
        coalition.addGroup(country.id.USA, Group.Category.AIRPLANE, rAirGroupData2)
        local grp = Group.getByName(rAirDroneGroupName2)
        if grp then
            local ctrl = grp:getController()
            if ctrl then
                ctrl:setOption(AI.Option.Air.val.ROE, AI.Option.Air.val.ROE.WEAPON_HOLD)
                ctrl:setOption(AI.Option.Air.val.REACTION_ON_THREAT, AI.Option.Air.val.REACTION_ON_THREAT.NO_REACTION)
            end
        end
    end)

    log("BATTLEFRONT: Weapons Test Ranges spawned successfully with orange/red smoke and map markers.")
end

-- Refresh smoke markers on weapons test ranges every 4 minutes
function BF.RefreshRangeSmoke()
    pcall(function()
        local bRangeX, bRangeZ = -230000, 490000
        local rRangeX, rRangeZ = -90000, 490000
        trigger.action.smoke({x = bRangeX, y = land.getHeight({x = bRangeX, y = bRangeZ}) + 2, z = bRangeZ}, trigger.smokeColor.Orange)
        trigger.action.smoke({x = rRangeX, y = land.getHeight({x = rRangeX, y = rRangeZ}) + 2, z = rRangeZ}, trigger.smokeColor.Red)
    end)
    return timer.getTime() + 240
end



BF.TestRanges.Spawn = BF.SpawnWeaponsTestRanges
BF.TestRanges.RefreshSmoke = BF.RefreshRangeSmoke
