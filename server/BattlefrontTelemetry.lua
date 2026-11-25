-- DCS Saved Games/Scripts/Hooks. Mission sandbox stays intact: only the GUI
-- hook writes a local snapshot. No sockets, remote commands, or player names.
local callbacks = {}
local nextSample, sequence = 0, 0
local reportedError = false
local projectionWritten = false
local epoch = os.time()
local base = lfs.writedir() .. "Logs\\BattlefrontTelemetry"
local previousGrid = io.open(base .. "Grid.json", "rb")
if previousGrid then previousGrid:close(); projectionWritten = true end
local query = [=[
    if not coalition or not timer or not env or not env.mission then return '' end
    local function q(s)
        return '"' .. tostring(s or ''):gsub('[%z\1-\31\\"]', function(c)
            return string.format('\\u%04x', string.byte(c))
        end) .. '"'
    end
    if not _G.BF_WebWeaponObserver then
        local observer = { active = {}, index = 0, count = 0 }
        function observer:onEvent(event)
            if event.id ~= world.event.S_EVENT_SHOT or not event.weapon then return end
            pcall(function()
                local weapon = event.weapon
                if weapon:getDesc().category ~= Weapon.Category.MISSILE or self.count >= 160 then return end
                local shooter = event.initiator
                local side = shooter and shooter:getCoalition() or 0
                self.index = self.index + 1
                self.count = self.count + 1
                self.active[self.index] = {weapon=weapon, side=side, born=timer.getTime()}
            end)
        end
        world.addEventHandler(observer)
        _G.BF_WebWeaponObserver = observer
    end
    local aircraft = {}
    for side = 1, 2 do
        for _, category in ipairs({Group.Category.AIRPLANE, Group.Category.HELICOPTER}) do
            for _, group in ipairs(coalition.getGroups(side, category) or {}) do
                if group:isExist() then
                    for _, u in ipairs(group:getUnits() or {}) do
                        if #aircraft < 256 and u:isExist() and u:isActive() then
                            local ok, row = pcall(function()
                                local p, o, v = u:getPoint(), u:getPosition(), u:getVelocity()
                                local heading = math.deg(math.atan2(o.x.z, o.x.x)) % 360
                                local pitch = math.deg(math.asin(math.max(-1, math.min(1, o.x.y))))
                                local roll = math.deg(math.atan2(-o.z.y, o.y.y))
                                local speed = math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z) * 1.943844
                                return string.format('{"id":%s,"callsign":%s,"type":%s,"category":%s,"side":%d,"x":%.2f,"z":%.2f,"alt":%.2f,"heading":%.2f,"pitch":%.2f,"roll":%.2f,"speed_kts":%.2f,"on_ground":%s}',
                                    q(side .. ':' .. u:getName()), q((u:getTypeName() or 'Aircraft') .. ' #' .. u:getID()), q(u:getTypeName()),
                                    q(category == Group.Category.HELICOPTER and 'helicopter' or 'airplane'),
                                    side, p.x, p.z, p.y, heading, pitch, roll, speed, u:inAir() and 'false' or 'true')
                            end)
                            if ok then aircraft[#aircraft+1] = row end
                        end
                    end
                end
            end
        end
    end
    local missiles, observer = {}, _G.BF_WebWeaponObserver
    for id, entry in pairs(observer.active) do
        local ok, row = pcall(function()
            local w = entry.weapon
            if not w:isExist() or timer.getTime()-entry.born > 180 then return end
            local p, o, v = w:getPoint(), w:getPosition(), w:getVelocity()
            return string.format('{"id":"M-%d","type":%s,"side":%d,"x":%.2f,"z":%.2f,"alt":%.2f,"heading":%.2f,"pitch":%.2f,"speed_kts":%.2f}',
                id,q(w:getTypeName()),entry.side,p.x,p.z,p.y,
                math.deg(math.atan2(o.x.z,o.x.x)) % 360,
                math.deg(math.asin(math.max(-1,math.min(1,o.x.y)))),
                math.sqrt(v.x*v.x+v.y*v.y+v.z*v.z)*1.943844)
        end)
        if ok and row then missiles[#missiles+1] = row
        else observer.active[id] = nil; observer.count = observer.count - 1 end
    end
    return string.format('"theater":%s,"sim_time":%.3f,"units":[%s],"missiles":[%s]',
        q(env.mission.theatre), timer.getTime(), table.concat(aircraft, ','), table.concat(missiles, ','))
]=]
local projection = [=[
    if not coord or not env or not env.mission or env.mission.theatre ~= "Caucasus" then return "" end
    local points = {}
    for row = 0, 6 do for col = 0, 8 do
        local x = -390 + 780*col/8
        local z = -260 + 520*row/6
        local lat, lon = coord.LOtoLL({x=-165000-z*1000, y=0, z=540000+x*1000})
        points[#points+1] = string.format("[%.9f,%.9f]", lat,lon)
    end end
    return '{"cols":9,"rows":7,"width":780,"height":520,"points":[' .. table.concat(points,',') .. ']}'
]=]

function callbacks.onSimulationFrame()
    if not DCS.isServer() then return end
    local now = DCS.getRealTime()
    if now < nextSample then return end
    nextSample = now + 0.20
    local mission = tostring(DCS.getMissionFilename() or ""):gsub("\\","/"):match("([^/]+)$") or ""
    local name = mission:lower():gsub("%.miz$","")
    local campaign = name == 'battlefront_caucasus' or tostring(DCS.getMissionName() or ""):lower() == 'battlefront_caucasus'
    local recording = name == 'caucasus_delivery_demo'
    local missionField = recording and ',"mission":"Battlefront Delivery Demo"'
        or (campaign and ',"mission":"Battlefront Caucasus"' or '')
    local result, ok = net.dostring_in("scripting", query)
    if not ok or not result or result == '' then
        if not reportedError and DCS.getModelTime() > 3 then
            net.log('BATTLEFRONT TELEMETRY: scripting snapshot unavailable: ' .. tostring(result))
            reportedError = true
        end
        return
    end
    local target = base .. tostring(sequence % 2) .. '.json'
    local pending = base .. '.tmp'
    local f = io.open(pending, 'wb')
    if not f then return end
    f:write(string.format('{"version":1,"session":%d,"seq":%d,%s%s}', epoch, sequence, result,
        missionField))
    f:close()
    -- Windows/Wine rename cannot replace an existing file. Alternate slots so
    -- the reader always has one complete previous frame during replacement.
    os.remove(target)
    if os.rename(pending, target) then sequence = sequence + 1 end
    if sequence == 1 then net.log('BATTLEFRONT TELEMETRY: first aircraft snapshot written') end
    -- The native terrain interface is not ready during mission loading.
    if not projectionWritten and DCS.getModelTime() > 5 then
        local grid, success = net.dostring_in("scripting", projection)
        if success and grid and #grid > 100 then
            local file = io.open(base .. "Grid.json", "wb")
            if file then file:write(grid); file:close(); projectionWritten = true end
        end
    end
end

function callbacks.onMissionLoadEnd()
    nextSample = 0
    reportedError = false
end

DCS.setUserCallbacks(callbacks)
net.log('BATTLEFRONT TELEMETRY: read-only aircraft export hook registered')
