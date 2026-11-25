-- BEGIN BATTLEFRONT FIXED DELIVERY CONSUMER
-- Insert this block before the stock MissionScripting.lua sanitizers.
-- The mission receives no file capability, callable consumer, or command interface.
do
    local function install()
        local open, rename, remove = io.open, os.rename, os.remove
        local schedule, modelTime = timer.scheduleFunction, timer.getTime
        local baseByName, unitByName = Airbase.getByName, Unit.getByName
        local getZone = trigger.misc.getZone
        local resourceMap = Warehouse and Warehouse.getResourceMap
        local listDeliveryDirectory = lfs and lfs.dir
        local directory = 'C:/DCS_configs/DCS.server1/Scripts/BattlefrontDelivery/'
        local requestPath = directory .. 'battlefront_delivery.request'
        local receiptPath = directory .. 'battlefront_delivery.receipt'
        local guardPath = directory .. 'battlefront_delivery.applying'
        local capabilityPath = directory .. 'battlefront_delivery.capability'
        local receiptTemp = directory .. 'battlefront_delivery.receipt.tmp'
        local guardTemp = directory .. 'battlefront_delivery.applying.tmp'
        local capabilityTemp = directory .. 'battlefront_delivery.capability.tmp'
        local capability = 'BF3 VIPER_D_READY\n'
        local overlay = 'C:/DCS_server/CoreMods/aircraft/AircraftWeaponPack/aim120_family.lua'
        -- The staging script pins the approved copied game data. The default is disabled.
        local overlayBytes, overlayHash1, overlayHash2 = 0, 0, 0
        local zone = 'BATTLEFRONT_DELIVERY_BARRIER_V3'
        local name = 'BLUE_F16C_1'
        local baseName, baseID, blue = 'Mineralnye Vody', 26, 2
        -- This private overlay replaces the game B slot with the virtual D. Do not treat stock B as D.
        local resource = 'weapons.missiles.AIM_120'
        local statuses = {APPLYING=true, READY=true, REJECTED=true, REVIEW=true}
        local warned = false
        local nextCapability = 0

        -- The mission SSE can wrap a successful file method as a void call.
        -- An explicit false or nil-with-error is still a failure. Exact read-
        -- back below remains mandatory; a void result alone proves nothing.
        local function fileCallOK(value, reason)
            return value ~= false and (value ~= nil or reason == nil)
        end

        -- Wine SSE can also discard errno for a failed open. A nil result by
        -- itself cannot be treated as absence of a durable guard. Only a
        -- successful, bounded listing of our one private directory can prove
        -- that this exact name isn't present. No listing is exported.
        local function provenAbsent(path)
            if type(listDeliveryDirectory) ~= 'function' or path:sub(1, #directory) ~= directory then return false end
            local wanted = path:sub(#directory + 1)
            if not wanted:match('^battlefront_delivery%.[a-z%.]+$') then return false end
            local ok, absent = pcall(function()
                local count = 0
                for entry in listDeliveryDirectory(directory) do
                    count = count + 1
                    if count > 32 or type(entry) ~= 'string' or entry == wanted then return false end
                end
                return true
            end)
            return ok and absent
        end

        local function read(path)
            local f, why, errno = open(path, 'rb')
            if not f then
                local reportedMissing = type(why) == 'string' and
                    (why:find('No such file or directory', 1, true) or why:find('The system cannot find the file specified', 1, true))
                local opaqueSSE = why == nil or why == ('can\'t open "' .. path .. '" for \'rb\'')
                local absent = errno == 2 or (errno == nil and (reportedMissing or (opaqueSSE and provenAbsent(path))))
                return nil, absent and 'missing' or 'unavailable'
            end
            local data = f:read(129)
            local closed = fileCallOK(f:close())
            if not closed or type(data) ~= 'string' or #data >= 129 then return nil, 'unavailable' end
            return data, 'present'
        end

        -- On Wine, rename may not replace an existing receipt. Only a terminal
        -- receipt may replace APPLYING, while the separate permanent guard stays intact.
        -- The short-lived capability can be refreshed independently of those journals.
        local function publish(path, tmp, data, replace)
            local f = open(tmp, 'wb')
            if not f then return false end
            local wrote = fileCallOK(f:write(data))
            local flushed = wrote and fileCallOK(f:flush())
            local closed = fileCallOK(f:close())
            if not flushed or not closed then return false end
            local function commit()
                if not fileCallOK(rename(tmp, path)) then return false end
                local _, tempState = read(tmp)
                -- If rename returned void and left the temp intact, reading
                -- identical prior bytes does not prove a fresh journal write.
                return tempState == 'missing' and read(path) == data
            end
            if commit() then return true end
            return replace and fileCallOK(remove(path)) and commit() or false
        end

        local function matchesOverlay()
            if overlayBytes < 1 or overlayBytes > 1048576 then return false end
            local f = open(overlay, 'rb')
            if not f then return false end
            local data = f:read(overlayBytes + 1)
            local closed = fileCallOK(f:close())
            if not closed or type(data) ~= 'string' or #data ~= overlayBytes then return false end
            local h1, h2 = 0, 0
            for i = 1, #data do
                local b = data:byte(i)
                h1 = (h1 * 33 + b) % 2147483647
                h2 = (h2 * 257 + b) % 2147483629
            end
            return h1 == overlayHash1 and h2 == overlayHash2
        end

        local function withdrawCapability()
            nextCapability = 0
            if read(capabilityPath) == capability then remove(capabilityPath) end
        end

        local function parseRequest(data)
            local id = data and data:match('^BF3 ([0-9a-f]+) AIM%-120D\n$')
            if id and #id == 32 then return id end
        end

        local function parseGuard(data)
            local id = data and data:match('^BF3 ([0-9a-f]+) APPLYING\n$')
            if id and #id == 32 then return id end
        end

        local function parseReceipt(data)
            if not data then return end
            local id, status, before, after = data:match('^BF3 ([0-9a-f]+) ([A-Z]+) (-?%d+) (-?%d+) [a-z][a-z0-9_]*\n$')
            if id and #id == 32 and statuses[status] and #before <= 10 and #after <= 10 then
                return id, status
            end
        end

        local function reply(id, state, before, after, reason, replace)
            local data = string.format('BF3 %s %s %d %d %s\n', id, state, before, after, reason)
            return publish(receiptPath, receiptTemp, data, replace)
        end

        local function signature()
            local mission = env.mission
            if type(mission) ~= 'table' or mission.theatre ~= 'Caucasus' or not getZone(zone) then return false end
            local side = mission.coalition and mission.coalition.blue
            for _, country in pairs(side and side.country or {}) do
                if tonumber(country.id) == 2 then
                    for _, group in pairs(country.plane and country.plane.group or {}) do
                        if group.name == name and tonumber(group.groupId) == 1401 then
                            local unit = group.units and group.units[1]
                            local point = group.route and group.route.points and group.route.points[1]
                            return unit and #group.units == 1 and unit.name == name and tonumber(unit.unitId) == 1402
                                and unit.type == 'F-16C_50' and unit.skill == 'Client'
                                and point and tonumber(point.airdromeId) == baseID
                        end
                    end
                end
            end
            return false
        end

        local function number(value)
            return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
        end

        local function stock(warehouse)
            local count = warehouse:getItemCount(resource)
            local inventory = warehouse:getInventory()
            local items = type(inventory) == 'table' and inventory.weapon
            if type(items) ~= 'table' or not number(count)
                or count < 0 or count >= 1000000000 or count ~= math.floor(count) then return nil end
            local listed = items[resource]
            if listed ~= count and not (listed == nil and count == 0) then return nil end
            return count
        end

        local function nativeWarehouse()
            local base = baseByName(baseName)
            if not base or tonumber(base:getID()) ~= baseID or tonumber(base:getCoalition()) ~= blue then
                return nil, 'invalid_setup'
            end
            local map = resourceMap and resourceMap()
            if type(map) ~= 'table' or type(map[resource]) ~= 'table' then return nil, 'stock_unavailable' end
            local warehouse = base:getWarehouse()
            if not warehouse then return nil, 'stock_unavailable' end
            return warehouse, nil, base
        end

        local function setup()
            local unit = unitByName(name)
            if not unit or not unit:isExist() then return nil, 'wait' end
            local pilot = unit:getPlayerName()
            if type(pilot) ~= 'string' or pilot == '' then return nil, 'wait' end
            local group = unit:getGroup()
            if not group or group:getName() ~= name or unit:getTypeName() ~= 'F-16C_50'
                or tonumber(unit:getCoalition()) ~= blue then return nil, 'invalid_setup' end
            if unit:inAir() ~= false then return nil, 'wait' end
            local velocity = unit:getVelocity()
            if not velocity or not number(velocity.x) or not number(velocity.y) or not number(velocity.z)
                or velocity.x^2 + velocity.y^2 + velocity.z^2 > 1 then return nil, 'wait' end
            local warehouse, reason, base = nativeWarehouse()
            if not warehouse then return nil, reason end
            local ap, bp = unit:getPoint(), base:getPoint()
            if not ap or not bp or not number(ap.x) or not number(ap.z) or not number(bp.x) or not number(bp.z)
                or (ap.x-bp.x)^2 + (ap.z-bp.z)^2 > 4000^2 then return nil, 'wait' end
            return warehouse
        end

        local function process(now)
            if not signature() or overlayBytes == 0 then return end
            if not matchesOverlay() then
                withdrawCapability()
                return
            end
            local stockKnown, eligible = pcall(function()
                local warehouse = nativeWarehouse()
                return warehouse and stock(warehouse) ~= nil
            end)
            local capabilityReady = false
            if stockKnown and eligible then
                if now >= nextCapability or read(capabilityPath) ~= capability then
                    capabilityReady = publish(capabilityPath, capabilityTemp, capability, true)
                    if capabilityReady then nextCapability = now + 2 end
                else
                    capabilityReady = true
                end
            else
                withdrawCapability()
            end
            local request = read(requestPath)
            local id = parseRequest(request)
            if not id then return end
            local guard, guardState = read(guardPath)
            local receipt, receiptState = read(receiptPath)
            local guardedID = parseGuard(guard)
            local receiptID, state = parseReceipt(receipt)
            if (guardState ~= 'missing' and guardedID ~= id)
                or (receiptState ~= 'missing' and receiptID ~= id) then return end
            if state and state ~= 'APPLYING' then return end
            local marker = 'BF3 ' .. id .. ' APPLYING\n'
            if guardedID or state == 'APPLYING' then
                -- Missing terminal evidence after a process restart is never permission to apply again.
                if not guardedID and not publish(guardPath, guardTemp, marker, false) then return end
                reply(id, 'REVIEW', 0, -1, 'interrupted', receiptState == 'present')
                return
            end

            local valid, warehouse, reason = pcall(setup)
            if not valid then return reply(id, 'REJECTED', -1, -1, 'invalid_setup') end
            if not warehouse then
                if reason ~= 'wait' then reply(id, 'REJECTED', -1, -1, reason) end
                return
            end
            local known, before = pcall(stock, warehouse)
            if not known or before == nil then return reply(id, 'REJECTED', -1, -1, 'stock_unavailable') end
            if before ~= 0 then return reply(id, 'REJECTED', before, before, 'stock_not_zero') end
            if not capabilityReady then return end

            if not publish(guardPath, guardTemp, marker, false) then return end
            if not reply(id, 'APPLYING', 0, -1, 'prewrite') then return end
            local fresh, recheck = pcall(stock, warehouse)
            if read(requestPath) ~= request or not fresh or recheck ~= 0 or not matchesOverlay() then
                return reply(id, 'REVIEW', 0, -1, 'write_uncertain', true)
            end

            local applied, result = pcall(function() return warehouse:addItem(resource, 1) end)
            local verified, after = pcall(stock, warehouse)
            if applied and result ~= false and verified and after == 1 then
                reply(id, 'READY', 0, 1, 'verified', true)
            else
                reply(id, 'REVIEW', 0, verified and after or -1, 'write_uncertain', true)
            end
        end

        local function tick(_, now)
            local ok = pcall(process, now)
            if not ok and not warned then
                warned = true
                if env and env.warning then env.warning('BATTLEFRONT DELIVERY: unexpected error; armed writes will not be repeated') end
            end
            return now + 1
        end

        schedule(tick, nil, modelTime() + 5)
    end

    local ok = pcall(install)
    if not ok and env and env.warning then env.warning('BATTLEFRONT DELIVERY: consumer not installed') end
end
-- END BATTLEFRONT FIXED DELIVERY CONSUMER
