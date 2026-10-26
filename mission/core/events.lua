-- ==============================================================================
-- BATTLEFRONT AIR WAR CAMPAIGN - CENTRAL EVENT BUS
-- ==============================================================================
Battlefront = Battlefront or {}
local BF = Battlefront

BF.Events = BF.Events or {
    listeners = {}
}

--- Subscribe to an event
-- @param eventName string: The event identifier (e.g., "sector.cleared", "unit.killed")
-- @param handler function: Callback function to receive event data payload
function BF.Events.on(eventName, handler)
    if not BF.Events.listeners[eventName] then
        BF.Events.listeners[eventName] = {}
    end
    table.insert(BF.Events.listeners[eventName], handler)
end

--- Emit an event to all registered subscribers
-- @param eventName string: The event identifier
-- @param data table: Event context payload
function BF.Events.emit(eventName, data)
    data = data or {}
    local handlers = BF.Events.listeners[eventName]
    if handlers then
        for _, handler in ipairs(handlers) do
            local ok, err = pcall(handler, data)
            if not ok then
                BF.Log(string.format("EVENT BUS ERROR [%s]: %s", eventName, tostring(err)))
            end
        end
    end
end

--- Clear all listeners (useful for mission reload/testing)
function BF.Events.clear()
    BF.Events.listeners = {}
end
