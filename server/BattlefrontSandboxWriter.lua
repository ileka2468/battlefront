-- BEGIN BATTLEFRONT FIXED SNAPSHOT WRITER
-- Insert before the stock sanitizer in the dedicated server's MissionScripting.lua.
-- Keep I/O private to a timer callback. Nothing is added to the mission API.
do
    local function install()
    local open, remove, rename = io.open, os.remove, os.rename
    local stateFile = 'C:/DCS_configs/DCS.server1/Scripts/battlefront_campaign_state.lua'
    local frameBase = 'C:/DCS_configs/DCS.server1/Logs/BattlefrontCampaign'
    local existing = open(stateFile, 'rb')
    local mustLoad = existing ~= nil
    if existing then existing:close() end
    local lastSave, lastFrame, seq = nil, nil, 0
    local signatureMatches = false
    local warned = false

    local function campaignSignature()
        local m = env and env.mission
        if not m or m.theatre ~= 'Caucasus' then return false end
        local red = m.coalition and m.coalition.red
        for _, country in pairs(red and red.country or {}) do
            for _, group in pairs(country.plane and country.plane.group or {}) do
                if country.id == 0 and group.groupId == 1401 and group.name == 'RED_SU25T_1' then
                    local unit = group.units and group.units[1]
                    if unit and unit.unitId == 1402 and unit.type == 'Su-25T' and unit.skill == 'Client' then
                        return true
                    end
                end
            end
        end
        return false
    end

    -- This file is loaded as Lua data at startup. Accept only the canonical
    -- literal table grammar, never write caller-controlled code or a filename.
    local function validSave(data)
        if type(data) ~= 'string' or #data > 32768 or data:sub(-1) ~= '\n' then return false end
        local lines, sides, names = {}, {}, {}
        for line in data:gmatch('([^\n]*)\n') do lines[#lines + 1] = line end
        if #lines ~= 30 or lines[1] ~= '-- Battlefront Campaign Persistent State' or lines[2] ~= 'return {'
            or lines[3] ~= '  coalitions = {' or lines[6] ~= '  },' or lines[7] ~= '  sectors = {'
            or lines[29] ~= '  }' or lines[30] ~= '}' then return false end
        for i = 4, 5 do
            local side, money, seconds, entries = lines[i]:match('^    %[(%d)%] = { treasury = (%-?%d+%.%d%d), stock_flight_seconds = (%d+), unlocked = { (.*)} },$')
            if seconds and (#seconds > 5 or tonumber(seconds) > 86400) then return false end
            if not side then
                side, money, entries = lines[i]:match('^    %[(%d)%] = { treasury = (%-?%d+%.%d%d), unlocked = { (.*)} },$')
            end
            if (side ~= '1' and side ~= '2') or not tonumber(money) or sides[side] then return false end
            if entries:gsub('%["[%w_ %-]+"%] = true, ', '') ~= '' then return false end
            sides[side] = true
        end
        for i = 8, 28 do
            local name = lines[i]:match(
                [=[^    %["([%w ._/%-()'&]+)"%] = { side = [012], level = [123], status = "[A-Z_]+", holdTimer = %d+, holdingSide = [012] },$]=])
            if not name or names[name] then return false end
            names[name] = true
        end
        return true
    end

    local function stage(path, payload)
        local tmp = path .. '.tmp'
        local f = open(tmp, 'wb')
        if not f then return nil end
        local ok = f:write(payload)
        local closed = f:close()
        return ok and closed and tmp or nil
    end

    local function persistSave(data)
        local tmp = stage(stateFile,data)
        if not tmp then return false end
        local backup = stateFile .. '.previous'
        remove(backup)
        local hadPrior = rename(stateFile, backup)
        if rename(tmp, stateFile) then return true end
        if hadPrior then rename(backup, stateFile) end
        return false
    end

    local function publish()
        local bf = Battlefront
        if type(bf) ~= 'table' or not _G.BF_CAMPAIGN_RUNNING then return end
        if not signatureMatches then signatureMatches = campaignSignature() end
        if not signatureMatches then
            if not warned then env.warning('BATTLEFRONT STATE: mission signature did not match'); warned = true end
            return
        end
        local save = bf.PendingSavePayload
        if save ~= lastSave and (bf.PersistentStateLoaded or not mustLoad) and validSave(save) and persistSave(save) then
            if not lastSave then env.info('BATTLEFRONT STATE: sandboxed campaign save persisted') end
            lastSave = save
        end
        local frame = bf.CampaignExportPayload
        if type(frame) == 'string' and frame ~= lastFrame and #frame < 32768
            and frame:match('^{"sim_time":%d+%.%d+,"campaign":{"mission":"Battlefront Caucasus",') then
            local path = frameBase .. tostring(seq % 2) .. '.json'
            local tmp = stage(path, frame)
            if tmp then
                remove(path) -- alternate files; the other complete frame stays readable on Wine.
                if rename(tmp, path) then
                    if seq == 0 then env.info('BATTLEFRONT COMPANION: first campaign snapshot published through sandbox writer') end
                    lastFrame, seq = frame, seq + 1
                end
            end
        end
    end
    Battlefront = Battlefront or {}
    Battlefront.PublishFixedSnapshots = publish
    end
    -- A missing or changed DCS timer API must never prevent sanitization below.
    local ok, err = pcall(install)
    if not ok and env and env.warning then env.warning('BATTLEFRONT STATE: writer not installed: ' .. tostring(err)) end
end
-- END BATTLEFRONT FIXED SNAPSHOT WRITER
