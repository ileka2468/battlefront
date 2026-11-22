-- Real campaign functions with simulated model time and no human pilots.
local BF = Battlefront
local D = BF.AIDirector
local red, blue = BF.SIDE_RED, BF.SIDE_BLUE
local R, B = BF.State.coalitions[red], BF.State.coalitions[blue]
local compile = loadstring or load
local flags, messages, logs = {}, {}, {}
BF.Log = function(msg) logs[#logs + 1] = msg end
BF.Broadcast = function(msg, side) messages[#messages + 1] = { text = msg, side = side } end
BF.FormatMoney = function(amount) return ('$%gM'):format(amount) end
trigger = { action = { setUserFlag = function(key, value) flags[key] = value end } }
coalition = { getPlayers = function() error('Research must not inspect human slots or flight time') end }

if not BF.Config.autonomousResearchOrder then
    -- Reproduce the previous behavior on the same Lua VM and wallet.
    R.treasury = 750
    D.EvaluateResearch(red)
    local ok, reason = BF.PurchaseBlueprint(red, 'Su-34')
    assert(not ok and reason == 'flight_required' and not R.unlockedBlueprints['Su-34'] and R.treasury == 750)
    print('BASELINE: Director disabled; funded RED Su-34 ($750M balance) stays locked with no human stock flight')
    os.exit(1)
end

BF.Aircraft.InitSlots()
assert(R.treasury == 200 and B.treasury == 200 and not next(R.unlockedBlueprints) and not next(B.unlockedBlueprints))
assert(flags.RED_SU34_1 == 100 and flags.BLUE_A4E_1 == 100 and flags.RED_SU25T_1 == 0)
local time, scheduled, processed = 5000, nil, 0
timer = {
    getTime = function() return time end,
    scheduleFunction = function(fn, _, when) scheduled = { fn = fn, when = when } end,
}
D.SelectTargetSector = function() return nil end
D.SpawnFlight = function() processed = processed + 1 end
D.Start()
assert(scheduled.fn == D.Loop and scheduled.when == 5010)
local function at(delta)
    time = 5000 + delta
    local due = D.Loop()
    assert(due == time + 8, 'fixture should also reach the ordinary campaign spawn path')
end
at(599)
at(600)
assert(R.treasury == 200 and B.treasury == 200 and not next(R.unlockedBlueprints) and not next(B.unlockedBlueprints))
print('OPENING: $200M each; stock aircraft only; neither side can afford a scheduled purchase')

BF.Economy.addFunds(blue, 150, 'fixture industrial revenue')
BF.Economy.addFunds(red, 549, 'fixture combat and sector revenue')
at(1199)
assert(B.treasury == 350 and not B.unlockedBlueprints['A-4E-C'])
at(1200)
assert(B.treasury == 100 and R.treasury == 749 and not R.unlockedBlueprints['Su-34'])
assert(B.unlockedBlueprints['A-4E-C'] and flags.BLUE_A4E_1 == 0 and flags.RED_SU34_1 == 100)
local blueReceipt = B.lastBlueprintPurchase
assert(blueReceipt.source == 'director' and blueReceipt.key == 'A-4E-C' and
    blueReceipt.cost == 250 and blueReceipt.before == 350 and blueReceipt.after == 100)
assert(messages[#messages].side == blue and messages[#messages].text:find('by AI Director', 1, true))
assert(messages[#messages].text:find('Treasury: $350M -> $100M', 1, true))

BF.Economy.addFunds(red, 1, 'fixture industrial revenue')
BF.Economy.addFunds(blue, 500, 'fixture industrial revenue')
at(1201)
assert(not R.unlockedBlueprints['Su-34'] and R.treasury == 750)
at(1800)
assert(R.treasury == 100 and R.unlockedBlueprints['Su-34'] and flags.RED_SU34_1 == 0)
assert(B.treasury == 600 and not B.unlockedBlueprints['UH-60L'] and B.lastBlueprintPurchase == blueReceipt)
assert(D.ResolveTemplate(red, 'STRIKE').type == 'Su-34' and D.ResolveTemplate(red, 'SEAD').type == 'Su-34')
assert(not BF.Research.CanFieldAirframe(blue, 'Su-34'))
local redReceipt = R.lastBlueprintPurchase
assert(redReceipt.source == 'director' and redReceipt.key == 'Su-34' and
    redReceipt.cost == 650 and redReceipt.before == 750 and redReceipt.after == 100)
assert(messages[#messages].side == red and messages[#messages].text:find('Treasury: $750M -> $100M', 1, true))
print('AUTONOMOUS: no clients queried; BLUE A-4E-C $350M -> $100M, RED Su-34 $750M -> $100M; one purchase per coalition/10 minutes; reserve and order enforced')

local saved = assert(compile(BF.PendingSavePayload))()
assert(saved.coalitions[red].treasury == 100 and saved.coalitions[red].unlocked['Su-34'])
assert(saved.coalitions[blue].treasury == 600 and saved.coalitions[blue].unlocked['A-4E-C'])
assert(saved.coalitions[red].stock_flight_seconds == 0)
saved.coalitions[red].stock_flight_seconds = 321
local realDofile = dofile
dofile = function() return saved end
BF.LoadState()
dofile = realDofile
assert(BF.PersistentStateLoaded and R.stockFlightSeconds == 321 and R.unlockedBlueprints['Su-34'])
assert(R.treasury == 100 and R.unlockedBlueprints['Su-34'] and B.treasury == 600)

BF.Economy.addFunds(red, 700, 'fixture combat revenue')
local realSave = BF.SaveState
BF.SaveState = function() return false, 'fixture ledger queue failure' end
at(2400)
assert(R.lastBlueprintPurchase == redReceipt and R.treasury == 800 and not R.unlockedBlueprints['Su-30SM'])
assert(flags.RED_SU30_1 == 100 and messages[#messages].text:find('No funds spent.', 1, true))
BF.SaveState = realSave
at(2401)
assert(R.treasury == 800 and not R.unlockedBlueprints['Su-30SM'])
at(3000)
assert(R.treasury == 100 and R.unlockedBlueprints['Su-30SM'] and flags.RED_SU30_1 == 0)
assert(R.lastBlueprintPurchase.key == 'Su-30SM' and R.lastBlueprintPurchase.source == 'director' and processed >= 8)
print('LEDGER: old saves still load; queued purchases survive reload; rejected write left balance/unlocks/receipt intact and retried at the next interval')
