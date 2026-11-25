-- Uses the real consumer with a synthetic Mission Scripting API and in-memory file system.
local realOS, realIO = os, io
local source = arg[1] or 'server/BattlefrontDelivery.lua'
local handle = realIO.open(source, 'rb')
if not handle then
    print('BASELINE: warehouse delivery consumer absent; no bridge to mutate or verify virtual stock')
    realOS.exit(1)
end
local script = assert(handle:read('*a')); assert(handle:close())
local overlayPath = 'C:/DCS_server/CoreMods/aircraft/AircraftWeaponPack/aim120_family.lua'
local fakeOverlay = '-- exact fixture data; no game missile parameters\n'
local function fingerprint(data)
    local h1, h2 = 0, 0
    for i = 1, #data do
        h1 = (h1 * 33 + data:byte(i)) % 2147483647
        h2 = (h2 * 257 + data:byte(i)) % 2147483629
    end
    return string.format('%d, %d, %d', #data, h1, h2)
end
local stanza = 'local overlayBytes, overlayHash1, overlayHash2 = '
local fixtureSource, count = script:gsub(stanza .. '0, 0, 0', stanza .. fingerprint(fakeOverlay))
assert(count == 1, 'only the configured BF3 consumer has a Viper overlay gate')
local consumer = assert(loadstring(fixtureSource, '@' .. source))
local unconfigured = assert(loadstring(script, '@' .. source))

local dir = 'C:/DCS_configs/DCS.server1/Scripts/BattlefrontDelivery/'
local request = dir .. 'battlefront_delivery.request'
local receipt = dir .. 'battlefront_delivery.receipt'
local guard = dir .. 'battlefront_delivery.applying'
local capabilityPath = dir .. 'battlefront_delivery.capability'
local capability = 'BF3 VIPER_D_READY\n'
local resource = 'weapons.missiles.AIM_120'
local id, other = string.rep('a', 32), string.rep('b', 32)
local function order(orderId) return 'BF3 ' .. orderId .. ' AIM-120D\n' end
local function result(state, before, after, reason)
    return string.format('BF3 %s %s %d %d %s\n', id, state, before, after, reason)
end
local allowed = {[request]=true, [receipt]=true, [guard]=true, [receipt..'.tmp']=true, [guard..'.tmp']=true,
    [capabilityPath]=true, [capabilityPath..'.tmp']=true}

local function fixture(overrides)
    local f = {files={[request]=order(id)}, reads=0, writes=0, calls=0, stock=0, marked=true,
        pilot=true, airborne=false, speed=0, airdrome=26, warehouseID='26', faction='2', inRange=true,
        missionCountry=2, missionSide='blue', aircraft='F-16C_50', unitCoalition=2,
        overlay=fakeOverlay, overlayReads=0, capabilityWrites=0, capabilityRemovals=0,
        map=true, inventory=true, windows=true, warnings=0}
    for k,v in pairs(overrides or {}) do f[k]=v end
    local time, scheduled = 5, nil

    local function operationOK(path)
        if f.closeError and path==overlayPath then return nil, 'close failed' end
        if f.voidOperations then return nil end
        return true
    end

    local function boot()
        io = {open=function(path, mode)
            if path==overlayPath then
                assert(mode=='rb', 'overlay is read-only')
                f.overlayReads=f.overlayReads+1
                local data = f.overlay
                if f.changeOverlayAtApply and f.files[guard] then data = 'M' .. data:sub(2) end
                if not data then return nil, 'no overlay', 2 end
                return {read=function(_,bytes)
                    assert(bytes==#fakeOverlay+1, 'overlay read is bounded')
                    return data:sub(1,bytes)
                end, close=function()return operationOK(path) end}
            end
            assert(allowed[path], 'consumer tried to use an additional path')
            if mode=='rb' then
                f.reads=f.reads+1
                if f.denyRead==path then return nil,'permission denied',13 end
                local data=f.files[path]
                if not data then
                    if f.opaqueNativeError then return nil, ('can\'t open "' .. path .. '" for \'rb\'') end
                    if f.noMissingDetail then return nil end
                    return nil,'no such file',2
                end
                return {read=function(_,bytes)assert(bytes==129); return data:sub(1,bytes) end,
                    close=function()return operationOK(path) end}
            end
            assert(mode=='wb' and (path==receipt..'.tmp' or path==guard..'.tmp' or path==capabilityPath..'.tmp'))
            if f.denyGuard and path==guard..'.tmp' or f.denyTerminalOpen and f.calls>0 and path==receipt..'.tmp' then
                return nil,'staging refused',13
            end
            if path==capabilityPath..'.tmp' then
                if f.denyCapability then return nil, 'capability publication refused', 13 end
                f.capabilityWrites=f.capabilityWrites+1
            else
                f.writes=f.writes+1
            end
            local pending
            return {write=function(_,data)pending=data;return operationOK(path) end,
                flush=function()return operationOK(path) end,close=function()f.files[path]=pending;return operationOK(path) end}
        end}
        os = {rename=function(from,to)
            assert(allowed[from] and allowed[to] and from==to..'.tmp')
            if f.windows and f.files[to] or f.denyTerminalRename and f.calls>0 and to==receipt then return nil end
            f.files[to], f.files[from] = f.files[from], nil
            return operationOK(to)
        end, remove=function(path)
            if path==capabilityPath then
                assert(f.files[path]==capability, 'unrelated capability content must not be withdrawn')
                f.capabilityRemovals=f.capabilityRemovals+1
            else
                assert(path==receipt and f.files[guard], 'non-receipt or unguarded delete')
            end
            f.files[path]=nil;return operationOK(path)
        end}
        lfs = {dir=function(path)
            assert(path==dir, 'unexpected directory listing')
            if f.denyDirectory then error('listing denied') end
            local keys={'.','..'}
            for entry in pairs(f.files) do
                assert(allowed[entry])
                keys[#keys+1]=entry:sub(#dir+1)
            end
            local i=0
            return function() i=i+1; return keys[i] end
        end}
        env = {mission={theatre='Caucasus',coalition={[f.missionSide]={country={{id=f.missionCountry,plane={group={{
            groupId=1401,name='BLUE_F16C_1',units={{unitId=1402,name='BLUE_F16C_1',type=f.aircraft,skill='Client'}},
            route={points={{airdromeId=f.airdrome}}}}}}}}}}}, warning=function() f.warnings=f.warnings+1 end}
        timer = {getTime=function()return time-5 end,scheduleFunction=function(callback,arg,when)
            assert(arg==nil and when==time);scheduled=callback
        end}
        trigger = {misc={getZone=function(zone)
            assert(zone=='BATTLEFRONT_DELIVERY_BARRIER_V3')
            return f.marked and {} or nil
        end}}
        local warehouse = {getItemCount=function(_, key)assert(key==resource);return f.stock end,
            getInventory=function()
                if not f.inventory then return {} end
                if f.stock==0 then return {weapon={}} end
                return {weapon={[resource]=f.inventoryCount or f.stock}}
            end,
            addItem=function(_,key,count)
                assert(key==resource and count==1 and f.stock==0)
                assert(f.files[capabilityPath]==capability)
                assert(f.files[guard]=='BF3 '..id..' APPLYING\n')
                assert(f.files[receipt]==result('APPLYING',0,-1,'prewrite'))
                f.calls=f.calls+1
                if f.noEffect then return nil end
                f.stock=f.nativeAfter or 1
                if f.nativeError then error('synthetic native exception after change') end
                if f.nativeFalse then return false end
            end}
        Airbase = {getByName=function(baseName)
            assert(baseName=='Mineralnye Vody')
            return {getID=function()return f.warehouseID end,getCoalition=function()return f.faction end,
                getPoint=function()return {x=10,z=20} end,getWarehouse=function()return warehouse end}
        end}
        Unit = {getByName=function(name)
            assert(name=='BLUE_F16C_1')
            return {isExist=function()return true end,getPlayerName=function()return f.pilot and 'Fixture pilot' or nil end,
                getGroup=function()return {getName=function()return 'BLUE_F16C_1' end} end,
                getTypeName=function()return 'F-16C_50' end,getCoalition=function()return f.unitCoalition end,
                inAir=function()return f.airborne end,getVelocity=function()return {x=f.speed,y=0,z=0} end,
                getPoint=function()return {x=f.inRange and 200 or 50000,z=20} end}
        end}
        Warehouse = {getResourceMap=function()return f.map and {[resource]={1,2,3,4}} or {} end}
        if f.unconfigured then unconfigured() else consumer() end
        assert(not BattlefrontDelivery and not Battlefront, 'consumer exposed a callable global')
        assert(type(scheduled)=='function')
        -- Exercise captured capabilities after ordinary simulator sanitizers.
        io, os, lfs = nil, nil, nil
    end
    function f.tick()
        assert(scheduled(nil,time)==time+1)
        time=time+1
    end
    f.boot=boot
    boot()
    return f
end

local f
for _, mission in ipairs({{marked=false}, {airdrome=12}, {missionSide='red'}, {missionCountry=0}, {aircraft='MiG-29A'}}) do
    f=fixture(mission)
    f.tick(); assert(f.reads==0 and f.writes==0 and f.stock==0 and f.overlayReads==0 and f.capabilityWrites==0)
end
f=fixture()
for _, malformed in ipairs({order(string.rep('A',32)), 'BF3 '..id..' AIM-120C\n', 'BF3 '..id..' AIM-260\n',
    'BF1 '..id..' R-73\n', 'BF2 '..id..' AIM-120C\n', order(id)..'more', order(id):gsub('\n','\r\n'), string.rep('z',129)}) do
    f.files[request]=malformed
    f.tick(); assert(f.writes==0 and f.calls==0)
end
f=fixture()
f.files[guard]='BF2 '..id..' APPLYING\n'
f.tick(); assert(f.writes==0 and f.calls==0 and not f.files[receipt])
f=fixture()
f.files[receipt]='BF2 '..id..' READY 0 1 verified\n'
f.tick(); assert(f.writes==0 and f.calls==0 and not f.files[guard])
print('SCOPE: only the marked USA BLUE F-16C at base 26 can consume BF3 AIM-120D; old protocol, other variants, and ordinary campaign do nothing')

for _, config in ipairs({{unconfigured=true}, {overlay=false}, {overlay=fakeOverlay..'\n'},
    {overlay='X'..fakeOverlay:sub(2)}, {denyCapability=true}}) do
    f=fixture(config)
    f.tick()
    assert(not f.files[capabilityPath] and not f.files[guard] and not f.files[receipt] and f.calls==0)
end
f=fixture({pilot=false})
f.tick(); assert(f.capabilityWrites==1 and f.files[capabilityPath]==capability)
f.tick(); assert(f.capabilityWrites==1 and f.files[capabilityPath]==capability)
f.tick(); assert(f.capabilityWrites==2 and f.files[capabilityPath]==capability)
f.overlay='X'..fakeOverlay:sub(2)
f.tick(); assert(not f.files[capabilityPath] and f.calls==0 and not f.files[guard])
f=fixture({changeOverlayAtApply=true})
f.tick(); assert(f.calls==0 and f.files[receipt]==result('REVIEW',0,-1,'write_uncertain'))
print('CAPABILITY: exact overlay size and both fingerprints, finite native alias, 2-second heartbeat; wrong profile and changed profile cannot mutate')

f=fixture({voidOperations=true})
f.tick(); assert(f.files[capabilityPath]==capability and f.files[receipt]==result('READY',0,1,'verified') and f.calls==1)
f.tick(); f.tick(); assert(f.capabilityWrites==2 and not f.files[capabilityPath..'.tmp'])
f=fixture({closeError=true})
f.tick(); assert(not f.files[capabilityPath] and not f.files[guard] and f.calls==0)
f=fixture({voidOperations=true,noMissingDetail=true})
f.tick(); assert(f.files[capabilityPath]==capability and f.files[receipt]==result('READY',0,1,'verified') and f.calls==1)
f=fixture({voidOperations=true,opaqueNativeError=true})
f.tick(); assert(f.files[capabilityPath]==capability and f.files[receipt]==result('READY',0,1,'verified') and f.calls==1)
f=fixture({noMissingDetail=true,denyDirectory=true})
f.tick(); assert(not f.files[capabilityPath] and not f.files[guard] and f.calls==0)
f=fixture({noMissingDetail=true,denyRead=guard})
f.tick(); assert(f.files[capabilityPath]==capability and not f.files[guard] and f.calls==0)
print('IO CONTRACT: void SSE calls require exact disk read-back and positive fixed-directory absence; I/O errors fail closed')

f=fixture({pilot=false})
f.tick(); assert(f.writes==0 and not f.files[receipt])
f.pilot,f.airborne=true,true
f.tick(); assert(f.writes==0)
f.airborne,f.speed=false,2
f.tick(); assert(f.writes==0)
f.speed,f.inRange=0,false
f.tick(); assert(f.writes==0)
f.inRange=true
f.tick(); assert(f.calls==1 and f.stock==1 and f.files[receipt]==result('READY',0,1,'verified'))
assert(f.files[request]==order(id) and f.files[guard]=='BF3 '..id..' APPLYING\n')
f.stock=0; f.boot(); f.tick(); assert(f.calls==1 and f.stock==0)
f.files[request]=order(other)
f.tick(); assert(f.calls==1 and f.files[receipt]==result('READY',0,1,'verified'))
print('READY: parked occupied fixture, marker persisted before side effect, exact stock 0 -> 1 verified; replay or second ID did not apply')

for _, case in ipairs({
    {{stock=2},'stock_not_zero',2,2},
    {{stock=math.huge},'stock_unavailable',-1,-1},
    {{map=false},'stock_unavailable',-1,-1},
    {{inventory=false},'stock_unavailable',-1,-1},
    {{warehouseID=99},'invalid_setup',-1,-1},
    {{faction=1},'invalid_setup',-1,-1},
    {{unitCoalition=1},'invalid_setup',-1,-1}
}) do
    f=fixture(case[1]); f.tick()
    assert(f.calls==0 and not f.files[guard] and f.files[receipt]==result('REJECTED',case[3],case[4],case[2]))
end
f=fixture({denyGuard=true}); f.tick(); assert(f.calls==0 and not f.files[receipt])
f=fixture({denyRead=guard}); f.tick(); assert(f.calls==0 and not f.files[receipt])
print('REJECTED: wrong base/side, unavailable or existing stock were known no-write; unavailable files or unpersisted marker cannot mutate')

for _, case in ipairs({
    {{noEffect=true},0},{{nativeError=true},1},{{nativeFalse=true},1},{{nativeAfter=2},2},{{inventoryCount=7},-1}
}) do
    f=fixture(case[1]); f.tick()
    assert(f.calls==1 and f.files[receipt]==result('REVIEW',0,case[2],'write_uncertain'))
    f.stock=0; f.boot(); f.tick(); assert(f.calls==1)
end
for _, failure in ipairs({'denyTerminalOpen','denyTerminalRename'}) do
    f=fixture({[failure]=true}); f.tick()
    assert(f.calls==1 and f.stock==1 and f.files[guard])
    f[failure]=false; f.stock=0; f.boot(); f.tick()
    assert(f.calls==1 and f.files[receipt]==result('REVIEW',0,-1,'interrupted'))
end
f=fixture()
f.files[receipt]=result('APPLYING',0,-1,'prewrite')
f.tick()
assert(f.calls==0 and f.files[guard] and f.files[receipt]==result('REVIEW',0,-1,'interrupted'))
print('REVIEW: API disagreement or interrupted receipt publishing fails closed across process restarts, even when the warehouse resets to zero')
io,os=realIO,realOS
