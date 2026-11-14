local Util = require("src/util")
local LocMatch = require("src/loc_match")

-- Watches trees and caches and doors and reports what happens to them
-- Scans on ServerLogic because a MultiLoc var swap raises no LocAdded
-- https://developer.runescape.com/rs/core/events.html#serverlogic
local LocWatch = {}

---@class Watchdog.Payload.LocWatch
---@field kind "Changed"|"Appeared"|"Found"|"Gone"
---@field key string  # tile key
---@field fields table  # this scan's snapshot or standing false for Gone
---@field previous table  # last scan's snapshot and empty for Appeared and Found
---@field changed string[]  # changed field names in FIELDS order
---@field coord table  # plain x z level
---@field entity any  # LocEntity and nil for Gone
---@field up number  # tracked Locs that are up after this scan
---@field total number  # tracked Locs after this scan

LocWatch.FIELDS = {
    "standing", "isHidden", "displayName", "configName", "configID", "parentConfigID",
    "shapeType", "rotationType", "animID",
}

-- Scan state per graph and node id
local states = setmetatable({}, { __mode = "k" })

function LocWatch.ResetAll()
    for graph in pairs(states) do
        states[graph] = nil
    end
end

local function newState()
    return { tiles = {}, seeded = false, queue = {}, tick = 0 }
end

local function nodeState(graph, nodeId)
    local byNode = states[graph]
    if byNode == nil then
        byNode = {}
        states[graph] = byNode
    end
    if byNode[nodeId] == nil then
        byNode[nodeId] = newState()
    end
    return byNode[nodeId]
end

-- Plain copy of the compared fields that is safe to keep after the entity is gone
function LocWatch.Fields(spec, entity)
    local fields = {
        standing = LocMatch.Standing(spec, entity),
        isHidden = entity.isHidden == true,
        displayName = LocMatch.StripTags(entity.displayName),
        configID = entity.configID,
        parentConfigID = entity.parentConfigID,
        shapeType = entity.shapeType,
        rotationType = entity.rotationType,
    }
    if entity.config ~= nil then
        fields.configName = entity.config.configName
    end
    if entity.currentAnimation ~= nil then
        fields.animID = entity.currentAnimation.id
    end
    return fields
end

-- Turns "isHidden configID" into a set of field names and empty means every field
function LocWatch.ParseFields(text)
    if type(text) ~= "string" then
        return nil
    end
    local set = nil
    for word in text:gmatch("[%w_]+") do
        for _, field in ipairs(LocWatch.FIELDS) do
            if field:lower() == word:lower() then
                set = set or {}
                set[field] = true
            end
        end
    end
    return set
end

function LocWatch.Counts(state)
    local up, total = 0, 0
    for _, tile in pairs(state.tiles) do
        total = total + 1
        if tile.fields.standing then
            up = up + 1
        end
    end
    return up, total
end

-- A Loc only appears on a tile you could already see so walking or teleporting into view is not a spawn
-- In object mode the captured tile must have been loaded on the previous scan
local function wasVisible(state, spec, coord)
    if not LocMatch.Visible(spec, coord, state.lastPlayer) then
        return false
    end
    return spec.object == nil or state.objectLoaded == true
end

local function changedFields(old, new, watched)
    local changed = {}
    for _, field in ipairs(LocWatch.FIELDS) do
        if old[field] ~= new[field] and (watched == nil or watched[field]) then
            changed[#changed + 1] = field
        end
    end
    return changed
end

-- Compares this scan with the tracked tiles and returns the events sorted by tile
function LocWatch.Step(state, spec, entities, player, watched)
    local events = {}
    local seen = {}
    for _, entity in ipairs(entities) do
        local key = LocMatch.TileKey(entity)
        if key ~= nil and not seen[key] then
            seen[key] = true
            local fields = LocWatch.Fields(spec, entity)
            local coord = LocMatch.PlainCoord(entity.coordGrid)
            local old = state.tiles[key]
            if old == nil then
                -- Found means first seen by this watch and Appeared means it spawned in view
                local kind = "Found"
                if state.seeded and wasVisible(state, spec, coord) then
                    kind = "Appeared"
                end
                events[#events + 1] = { kind = kind, key = key, fields = fields, previous = {},
                    changed = {}, coord = coord, entity = entity }
            else
                local changed = changedFields(old.fields, fields, watched)
                if #changed > 0 then
                    events[#events + 1] = { kind = "Changed", key = key, fields = fields, previous = old.fields,
                        changed = changed, coord = coord, entity = entity }
                end
            end
            state.tiles[key] = { fields = fields, coord = coord }
        end
    end
    for key, old in pairs(state.tiles) do
        if not seen[key] then
            -- Out of view or out of Range is not a removal so the tile is dropped quietly
            if LocMatch.Visible(spec, old.coord, player) then
                events[#events + 1] = { kind = "Gone", key = key, fields = { standing = false },
                    previous = old.fields, changed = {}, coord = old.coord }
            end
            state.tiles[key] = nil
        end
    end
    state.seeded = true
    state.lastPlayer = player
    state.objectLoaded = spec.object ~= nil and LocMatch.Visible(spec, spec.object.coordGrid, player)

    table.sort(events, function(a, b)
        return a.key < b.key
    end)
    local up, total = LocWatch.Counts(state)
    for _, event in ipairs(events) do
        event.up = up
        event.total = total
    end
    return events
end

local function every(node)
    return math.max(1, math.floor(tonumber(node.GetControl("interval")) or 1))
end

local function scan(_, node, graph)
    if Util.PlayerIsRestricted() then
        return false
    end
    local state = nodeState(graph, node.id)
    local spec = LocMatch.SpecOf(node)
    if spec == nil then
        states[graph][node.id] = newState()
        return false
    end
    state.tick = state.tick + 1
    if state.tick < every(node) then
        return table.remove(state.queue, 1) or false
    end
    state.tick = 0

    local playerCg = LocMatch.PlayerCoord()
    if playerCg == nil then
        -- Logged out or loading so keep everything as it was
        return false
    end
    local seedKey = LocMatch.Key(spec) .. "|" .. tostring(node.GetControl("fields"))
    if state.seedKey ~= seedKey then
        state = newState()
        state.seedKey = seedKey
        states[graph][node.id] = state
    end

    local entities = LocMatch.Collect(spec, state.tiles, playerCg)
    local watched = LocWatch.ParseFields(node.GetControl("fields"))
    for _, event in ipairs(LocWatch.Step(state, spec, entities, LocMatch.PlainCoord(playerCg), watched)) do
        state.queue[#state.queue + 1] = event
    end
    return table.remove(state.queue, 1) or false
end

-- One event fires per ServerLogic tick and the rest drain on Logic
-- https://developer.runescape.com/rs/core/events.html#logic
local function drain(_, node, graph)
    local byNode = states[graph]
    if byNode == nil or byNode[node.id] == nil then
        return false
    end
    return table.remove(byNode[node.id].queue, 1) or false
end

local function searchPins()
    return {
        { name = "nameMatch", kind = "data", direction = "in", dataType = "matcher", label = "Name",
          default = { needle = "", mode = "substring" } },
        { name = "watchId", kind = "data", direction = "in", dataType = "number", label = "LocType id", default = 0 },
        { name = "option", kind = "data", direction = "in", dataType = "string", label = "Option", default = "" },
        { name = "scanRange", kind = "data", direction = "in", dataType = "number", label = "Range",
          default = LocMatch.DEFAULT_SCAN_RANGE },
    }
end

local function objectPins()
    return {
        { name = "object", kind = "data", direction = "in", dataType = "object_marker.object", label = "Object" },
        { name = "radius", kind = "data", direction = "in", dataType = "number", label = "Radius", default = 0 },
    }
end

local function sharedPins()
    return {
        { name = "fields", kind = "data", direction = "in", dataType = "string", label = "Fields", default = "" },
        { name = "interval", kind = "data", direction = "in", dataType = "number", label = "Every (ticks)", default = 1 },
        { name = "Changed", kind = "exec", direction = "out" },
        { name = "Appeared", kind = "exec", direction = "out" },
        { name = "Found", kind = "exec", direction = "out" },
        { name = "Gone", kind = "exec", direction = "out" },
        { name = "Down", kind = "exec", direction = "out" },
        { name = "Up", kind = "exec", direction = "out" },
        { name = "changed", kind = "data", direction = "out", dataType = "string" },
        { name = "name", kind = "data", direction = "out", dataType = "string" },
        { name = "wasName", kind = "data", direction = "out", dataType = "string", label = "was name" },
        { name = "configName", kind = "data", direction = "out", dataType = "string", label = "config name" },
        { name = "configId", kind = "data", direction = "out", dataType = "number", label = "config id" },
        { name = "wasConfigId", kind = "data", direction = "out", dataType = "number", label = "was config id" },
        { name = "hidden", kind = "data", direction = "out", dataType = "bool" },
        { name = "standing", kind = "data", direction = "out", dataType = "bool", label = "up" },
        { name = "wasStanding", kind = "data", direction = "out", dataType = "bool", label = "was up" },
        { name = "upCount", kind = "data", direction = "out", dataType = "number", label = "up count" },
        { name = "total", kind = "data", direction = "out", dataType = "number" },
        { name = "animId", kind = "data", direction = "out", dataType = "number", label = "anim id" },
        { name = "coordGrid", kind = "data", direction = "out", dataType = "coordgrid", label = "tile" },
        { name = "entity", kind = "data", direction = "out", dataType = "any" },
    }
end

local function withShared(pins)
    for _, pin in ipairs(sharedPins()) do
        pins[#pins + 1] = pin
    end
    return pins
end

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function LocWatch.Register(registry, runtime)
    registry:RegisterNodeType("trigger.loc_watch", {
        category = "trigger",
        displayName = "Loc Watch",
        description = "A tree, cache, door... changed, appeared or went. Found = first seen, Down = depleted / felled, Up = back.",
        defaultMode = LocMatch.MODE_SEARCH,
        modes = {
            { key = LocMatch.MODE_SEARCH, label = "Search (name / id)", pins = withShared(searchPins()) },
            { key = LocMatch.MODE_OBJECT, label = "Captured object", pins = withShared(objectPins()) },
        },
        run = function(ctx)
            local payload = ctx.payload
            local now, was = payload.fields, payload.previous
            ctx:Out("changed", table.concat(payload.changed, ","))
            ctx:Out("name", now.displayName or was.displayName)
            ctx:Out("wasName", was.displayName)
            ctx:Out("configName", now.configName or was.configName)
            ctx:Out("configId", now.configID)
            ctx:Out("wasConfigId", was.configID)
            ctx:Out("hidden", now.isHidden == true)
            ctx:Out("standing", now.standing == true)
            ctx:Out("wasStanding", was.standing == true)
            ctx:Out("upCount", payload.up)
            ctx:Out("total", payload.total)
            ctx:Out("animId", now.animID)
            ctx:Out("coordGrid", payload.coord)
            ctx:Out("entity", payload.entity)
            if payload.kind == "Found" then
                -- Already there when we first looked so it is not a change and fires no Up
                ctx:Fire("Found")
                return
            end
            ctx:Fire(payload.kind)
            if payload.kind == "Appeared" then
                ctx:Fire("Found")
            end
            if was.standing == true and now.standing ~= true then
                ctx:Fire("Down")
            end
            if now.standing == true and was.standing ~= true then
                ctx:Fire("Up")
            end
        end,
    })

    runtime:BindTrigger("trigger.loc_watch", {
        { event = "ServerLogic", filter = scan },
        { event = "Logic", filter = drain },
    })
end

return LocWatch
