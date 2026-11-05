-- Fixed-path, read-only projection of the running Battlefront campaign.
-- This file is appended to the verified campaign bundle, so it reads the same
-- mission environment as the campaign engine. It does not grant file access.
do
    if not Battlefront or not Battlefront.State or not _G.BF_CAMPAIGN_RUNNING then
        env.warning("BATTLEFRONT COMPANION: campaign export not scheduled; engine missing")
        return
    end
    if _G.BF_COMPANION_EXPORT_STARTED then return end
    _G.BF_COMPANION_EXPORT_STARTED = true
    local BF = Battlefront
    local reported, missingPublisher = false, false
    local function q(s)
        return '"' .. tostring(s or ''):gsub('[%z\1-\31\\"]', function(c)
            return string.format('\\u%04x', string.byte(c))
        end) .. '"'
    end
    local function exportCampaign(tt)
        local counts, incomes, sectors, finance = {0,0},{0,0},{},{}
        for name,s in pairs(BF.State.sectors) do
            sectors[#sectors+1] = {id=s.id, row=string.format(
                '{"id":%d,"name":%s,"side":%d,"status":%s,"level":%d,"x":%.1f,"z":%.1f}',
                s.id,q(name),s.side,q(s.status),s.level or 1,s.pos.x,s.pos.z)}
            if counts[s.side] ~= nil then
                counts[s.side] = counts[s.side] + 1
                if s.status == "DEFENDED" or s.status == "FORTIFIED" or s.status == "HOLDING" then
                    incomes[s.side] = incomes[s.side] + s.income
                end
            end
        end
        assert(#sectors == 21, "expected 21 playable campaign sectors")
        table.sort(sectors,function(a,b) return a.id<b.id end)
        for i,value in ipairs(sectors) do sectors[i]=value.row end
        local interval = BF.Config.economyInterval or 300
        for side=1,2 do
            local coal = BF.State.coalitions[side]
            local receipt = coal.lastBlueprintPurchase
            local purchase = receipt and string.format(',"last_blueprint_purchase":{"key":%s,"cost":%.2f,"before":%.2f,"after":%.2f,"source":%s}',
                q(receipt.key),receipt.cost,receipt.before,receipt.after,q(receipt.source or 'f10')) or ''
            local blueprints = {}
            for key,bp in pairs(BF.Config.blueprints[side] or {}) do
                blueprints[#blueprints+1] = string.format('{"key":%s,"name":%s,"cost":%.2f,"unlocked":%s}',
                    q(key),q(bp.name),bp.cost,coal.unlockedBlueprints[key] and 'true' or 'false')
            end
            table.sort(blueprints)
            finance[side] = string.format('"%d":{"treasury":%.2f,"controlled_sectors":%d,"hourly_income":%.2f,"blueprints":[%s]%s}',
                side,coal.treasury,counts[side],incomes[side]*3600/interval,table.concat(blueprints,','),purchase)
        end
        BF.CampaignExportPayload = string.format(
            '{"sim_time":%.3f,"campaign":{"mission":"Battlefront Caucasus","total_objectives":21,"coalitions":{%s},"sectors":[%s]}}',
            tt,table.concat(finance,','),table.concat(sectors,','))
        if type(BF.PublishFixedSnapshots) == 'function' then
            BF.PublishFixedSnapshots()
        elseif not missingPublisher then
            env.warning('BATTLEFRONT COMPANION: fixed snapshot publisher was not initialized')
            missingPublisher = true
        end
    end
    timer.scheduleFunction(function(_, tt)
        local ok, err = pcall(exportCampaign,tt)
        if not ok and not reported then
            env.warning("BATTLEFRONT COMPANION: snapshot export failed: " .. tostring(err))
            reported=true
        end
        return tt+2
    end,nil,timer.getTime()+4)
end
