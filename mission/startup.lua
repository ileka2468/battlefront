-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - MAIN STARTUP & LIFECYCLE
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

BF.Startup = BF.Startup or {}

function BF.Startup.Init()
    if _G.BF_CAMPAIGN_RUNNING then
        BF.Log("BATTLEFRONT CAMPAIGN ALREADY RUNNING - Skipping duplicate init.")
        return
    end
    _G.BF_CAMPAIGN_RUNNING = true

    BF.Log("=== BATTLEFRONT AIR WAR CAMPAIGN INITIALIZING (MODULAR ARCHITECTURE) ===")

    -- 1. Load Persistent Campaign State from Disk
    BF.LoadState()

    -- 2. Apply client slot restrictions after loading the current research ledger.
    BF.Aircraft.InitSlots()

    -- 3. Register Event Handlers & Core Timers
    if BF.Combat and BF.Combat.EventHandler then
        world.addEventHandler(BF.Combat.EventHandler)
    end
    if BF.Commands and BF.Commands.MapMarkers and BF.Commands.MapMarkers.Handler then
        world.addEventHandler(BF.Commands.MapMarkers.Handler)
    end

    timer.scheduleFunction(BF.Sectors.ProcessLoop, nil, timer.getTime() + 2)
    timer.scheduleFunction(BF.Culling.Process, nil, timer.getTime() + 10)
    timer.scheduleFunction(BF.Economy.Tick, nil, timer.getTime() + BF.Config.economyInterval)
    timer.scheduleFunction(BF.EWR.Loop, nil, timer.getTime() + 10)
    if BF.AIDirector and BF.AIDirector.Start then
        timer.scheduleFunction(BF.AIDirector.Start, nil, timer.getTime() + 5)
    end

    -- 4. Draw Tactical Frontlines & Quadrant Boundaries
    BF.Sectors.DrawFrontlineAndQuadrants()

    -- 5. Spawn Baseline EWR Radar Stations
    BF.SpawnInitialBaselineEWR()

    -- 6. Test Ranges disabled for live campaign immersion
    -- BF.TestRanges.Spawn()
    -- timer.scheduleFunction(BF.TestRanges.RefreshSmoke, nil, timer.getTime() + 240)

    -- 7. Register Coalition F10 Radio Menus
    BF.Commands.F10.RegisterMenus()

    -- 8. Broadcast Launch Announcement
    BF.Broadcast("=== THEATER OF OPERATIONS: CAUCASUS ACTIVE ===", nil, 10)
    BF.Broadcast("Battlefront Campaign Active: 21 Objectives online. Datalink provided by Home Base EWR. Dedicated Weapons Test Ranges online (Check F10 Menu or Orange/Red Smoke). Use F10 Map Marks (-drop ewr, -call awacs, -drop shorad) for tactical air support.", nil, 16)

    BF.Log("=== BATTLEFRONT CAMPAIGN INITIALIZED SUCCESSFULLY ===")
    BF.SaveState()

    if BF.Events and BF.Events.emit then
        BF.Events.emit("campaign.started", { timestamp = timer.getTime() })
    end
end

-- Safely invoke startup
local ok, err = pcall(BF.Startup.Init)
if not ok then
    BF.Log("=== BATTLEFRONT CAMPAIGN ENGINE INIT ERROR: " .. tostring(err))
end
