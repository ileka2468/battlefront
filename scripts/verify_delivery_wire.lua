-- Isolated cross-runtime fixture: use real temporary files and stub only native DCS APIs.
assert(_VERSION == 'Lua 5.1', 'This fixture requires Lua 5.1')
local source, scratch = assert(arg[1]), assert(arg[2])
local realIO, realOS = io, os
local production = 'C:/DCS_configs/DCS.server1/Scripts/BattlefrontDelivery/'
local request, receipt, guard = 'battlefront_delivery.request', 'battlefront_delivery.receipt', 'battlefront_delivery.applying'
local capabilityPath, capability = 'battlefront_delivery.capability', 'BF3 VIPER_D_READY\n'
local overlay, overlayFixture = 'C:/DCS_server/CoreMods/aircraft/AircraftWeaponPack/aim120_family.lua', 'fixture-overlay.lua'
local readable = {[request]=true, [receipt]=true, [guard]=true, [capabilityPath]=true}
local staging = {[receipt..'.tmp']=receipt, [guard..'.tmp']=guard, [capabilityPath..'.tmp']=capabilityPath}
local readableAndStaging = setmetatable({}, { __index = function(_, name) return readable[name] or staging[name] end })
local sku = 'weapons.missiles.AIM_120'
local fakeOverlay = '-- exact fixture data; no game missile parameters\n'
local overlayFile = assert(realIO.open(scratch .. '/' .. overlayFixture, 'wb'))
assert(overlayFile:write(fakeOverlay)); assert(overlayFile:close())
local h1, h2 = 0, 0
for i=1,#fakeOverlay do
    h1 = (h1*33+fakeOverlay:byte(i))%2147483647
    h2 = (h2*257+fakeOverlay:byte(i))%2147483629
end
local handle = assert(realIO.open(source, 'rb'))
local script = assert(handle:read('*a')); assert(handle:close())
local stanza = 'local overlayBytes, overlayHash1, overlayHash2 = '
local approved, count = script:gsub(stanza .. '0, 0, 0', stanza .. string.format('%d, %d, %d', #fakeOverlay, h1, h2))
assert(count==1)
local function remap(path, allowed)
    local name = path:sub(#production+1)
    assert(path:sub(1,#production) == production and allowed[name], 'Unexpected simulator file operation')
    return scratch .. '/' .. name, name
end
local function read(name)
    assert(readable[name], 'Unexpected fixture read')
    local file = assert(realIO.open(scratch .. '/' .. name, 'rb'))
    local data = file:read('*a')
    assert(file:close())
    return data
end
local wireRequest = read(request)
local id = assert(wireRequest:match('^BF3 ([0-9a-f]+) AIM%-120D\n$'))
assert(#id == 32)
local applying = 'BF3 ' .. id .. ' APPLYING\n'
local ready = 'BF3 ' .. id .. ' READY 0 1 verified\n'
local stock, writes = 0, 0
local warehouse = {
    getItemCount=function(_,resource) assert(resource==sku); return stock end,
    getInventory=function() return {weapon=stock==0 and {} or {[sku]=stock}} end,
    addItem=function(_,resource,quantity)
        assert(resource==sku and quantity==1 and stock==0 and writes==0)
        assert(read(capabilityPath)==capability)
        assert(read(guard)==applying)
        assert(read(receipt)=='BF3 '..id..' APPLYING 0 -1 prewrite\n')
        assert(read(request)==wireRequest)
        stock, writes = stock+1, writes+1
    end
}
local function boot()
    local callback
    local scope = {
        type=type, tonumber=tonumber, pairs=pairs, pcall=pcall, math=math, string=string,
        io={open=function(path,mode)
            assert(mode=='rb' or mode=='wb')
            if path==overlay then
                assert(mode=='rb')
                return realIO.open(scratch .. '/' .. overlayFixture,mode)
            end
            local filename = remap(path,mode=='rb' and readableAndStaging or staging)
            return realIO.open(filename,mode)
        end},
        os={
            rename=function(from,to)
                local origin, name = remap(from,staging)
                local target, dest = remap(to,readable)
                assert(staging[name]==dest)
                return realOS.rename(origin,target)
            end,
            remove=function(path)
                local target, name = remap(path,readable)
                assert((name==receipt and read(guard)==applying)
                    or (name==capabilityPath and read(capabilityPath)==capability))
                return realOS.remove(target)
            end,
        },
        env={mission={theatre='Caucasus',coalition={blue={country={{id=2,plane={group={{
            groupId=1401,name='BLUE_F16C_1',units={{unitId=1402,name='BLUE_F16C_1',type='F-16C_50',skill='Client'}},
            route={points={{airdromeId=26}}}}}}}}}}}, warning=function(message) error(message) end},
        timer={getTime=function() return 0 end,scheduleFunction=function(fn,payload,at)
            assert(payload==nil and at==5)
            callback=fn
        end},
        trigger={misc={getZone=function(name) assert(name=='BATTLEFRONT_DELIVERY_BARRIER_V3'); return {} end}},
        Unit={getByName=function(name)
            assert(name=='BLUE_F16C_1')
            return {
                isExist=function() return true end, getPlayerName=function() return 'Fixture pilot' end,
                getGroup=function() return {getName=function() return name end} end,
                getTypeName=function() return 'F-16C_50' end, getCoalition=function() return 2 end,
                inAir=function() return false end, getVelocity=function() return {x=0,y=0,z=0} end,
                getPoint=function() return {x=20,z=30} end,
            }
        end},
        Airbase={getByName=function(name)
            assert(name=='Mineralnye Vody')
            return {getID=function() return 26 end,getCoalition=function() return 2 end,
                    getPoint=function() return {x=20,z=30} end,getWarehouse=function() return warehouse end}
        end},
        Warehouse={getResourceMap=function() return {[sku]={1,2,3,4}} end},
    }
    local consumer = assert(loadstring(approved, '@' .. source))
    setfenv(consumer,scope)()
    assert(type(callback)=='function' and not scope.BattlefrontDelivery)
    scope.io, scope.os = nil, nil -- exercise the same captured functions after sanitization
    return callback
end

local tick = boot()
assert(tick(nil,5)==6)
assert(stock==1 and writes==1 and read(receipt)==ready and read(capabilityPath)==capability)
assert(tick(nil,6)==7)
assert(stock==1 and writes==1 and read(receipt)==ready)

stock=0 -- simulate a fresh native warehouse; the real on-disk journal survives
tick=boot()
assert(tick(nil,5)==6)
assert(stock==0 and writes==1 and read(request)==wireRequest and read(receipt)==ready)
print('WIRE: Lua 5.1 verified stock 0 -> 1 and one native call; duplicate tick/restart did not apply again')
