-- Execute the actual launch guard and scheduler with DCS census fixtures.
local BF, red, blue = Battlefront, Battlefront.SIDE_RED, Battlefront.SIDE_BLUE
local D, plane, helo = BF.AIDirector, Group.Category.AIRPLANE, Group.Category.HELICOPTER
Unit = {Category={AIRPLANE=plane,HELICOPTER=helo,GROUND_UNIT=2}}
local groups, players, byName = {[red]={[plane]={},[helo]={}},[blue]={[plane]={},[helo]={}}},
    {[red]={},[blue]={}}, {}
local calls, logs, now, unavailable = {}, {}, 100, nil
local function unit(id, category, active, exists)
    return {getID=function()return id end, getDesc=function()return {category=category} end,
        isActive=function()return active~=false end, isExist=function()return exists~=false end}
end
local function group(side, category, name, roster, exists)
    local g = {isExist=function()return exists~=false end, getUnits=function()return roster end,
        getController=function()return nil end, getSize=function()return #roster end}
    groups[side][category][#groups[side][category]+1] = g
    byName[name] = g
    return g
end
Group.getByName = function(name) return byName[name] end
coalition = {
    getGroups=function(side,cat) if side==unavailable then error("native census unavailable") end; return groups[side][cat] end,
    getPlayers=function(side)return players[side] end,
    addGroup=function(countryId,cat,data)
        local side = countryId==country.id.USA and blue or red
        calls[#calls+1] = {side=side,name=data.name}
        local units={}
        for _, u in ipairs(data.units) do units[#units+1]=unit(tostring(u.unitId),cat) end
        return group(side,cat,data.name,units)
    end,
}
timer = {getTime=function()return now end}
trigger = {action={outText=function() end}}
BF.Log = function(message) logs[#logs+1]=message end
D.SelectTargetSector = function() return nil end

local redUnits={}
for i=1,8 do redUnits[i]=unit(tostring(i),plane) end
redUnits[9]=unit(99,plane,false) -- Late activation, not an active airframe.
redUnits[10]=unit(98,plane,true,false) -- Dead object.
group(red,plane,"untracked wing",redUnits)
group(red,helo,"untracked helo",{unit(9,helo)})
group(red,plane,"stale dead group",{unit(96,plane)},false)
players[red]={unit(1,plane),unit(10,plane,false),unit(97,Unit.Category.GROUND_UNIT)}

if not D.GetActiveAircraftCount then
    assert(D.SpawnFlight(red,'CAP',nil,'NW',1) == nil and #calls==1)
    print('BASELINE: native flight launch adds a two-ship even when RED already has ten active airframes')
    os.exit(1)
end
if not D.GetActiveAircraftCount(red) then
    print('BASELINE: active aircraft with a native string ID makes the census unavailable and stalls launches')
    os.exit(1)
end
assert(D.GetActiveAircraftCount(red)==10 and D.GetActiveAircraftCount(blue)==0)
local counter=D.groupCounter
local ok, why=D.SpawnFlight(red,'CAP',nil,'NW',1)
assert(not ok and why=='aircraft_cap' and #calls==0 and counter==D.groupCounter)
players[red]={redUnits[1]} -- nine still cannot add a flight of two.
ok,why=D.SpawnFlight(red,'CAP',nil,'NW',1)
assert(not ok and why=='aircraft_cap' and #calls==0)
unavailable=red
ok,why=D.SpawnFlight(red,'CAP',nil,'NW',1)
assert(not ok and why=='aircraft_count_unavailable' and #calls==0)
assert(D.Loop()==now+8 and #calls==1 and calls[1].side==blue and D.GetActiveAircraftCount(blue)==2)
assert(table.concat(logs,'\n'):find('aircraft census unavailable; launch deferred: ',1,true))
print('CAP: numeric/string unit IDs normalized; 10 active including orphan fixed-wing, helicopter and occupied client; no double count; denied before native launch at nine/ten and on census failure')

unavailable=nil
for i=1,4 do now=now+10; assert(D.Loop()==now+8) end
assert(#calls==5 and D.GetActiveAircraftCount(blue)==10)
local roles={}
for _, f in pairs(D.activeGroups[blue]) do roles[f.role]=(roles[f.role] or 0)+1 end
assert(roles.CAP==3 and roles.SEAD==1 and roles.STRIKE==1)
now=now+1000
assert(D.Loop()==now+15 and #calls==5 and D.GetActiveAircraftCount(blue)==10)
print('SCHEDULER: blocked RED did not starve BLUE; BLUE reached exactly 10 with three CAP pairs, one SEAD pair and one STRIKE pair; full sides waited')

-- A native addGroup may refuse a particular support flight. A later role must still get a turn.
for name, f in pairs(D.activeGroups[blue]) do
    if f.role=='SEAD' or f.role=='STRIKE' then
        local roster=byName[name]:getUnits()
        for i=#roster,1,-1 do roster[i]=nil end
    end
end
now=now+10
D.roleCooldowns[blue].ESCORT, D.roleCooldowns[blue].LOGISTICS = now+500, now+500
D.Loop() -- cleanup puts both support roles on cooldown; no flight is added.
assert(#calls==5)
local add=coalition.addGroup
coalition.addGroup=function(countryId,cat,data)
    if data.task=='SEAD' then return nil end
    return add(countryId,cat,data)
end
now=now+121
assert(D.Loop()==now+8 and #calls==6 and D.GetActiveAircraftCount(blue)==8)
assert(not roles.LOGISTICS)
print('SCHEDULER: failed native SEAD launch did not prevent trying the next support role')
