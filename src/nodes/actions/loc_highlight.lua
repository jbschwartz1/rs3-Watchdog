local LocMatch = require("src/loc_match")
local LocDraw = require("src/loc_draw")

-- Draws Locs on screen
-- Search mode highlights every match around you and rescans while shown so it follows depletion
-- Depleted ones use Depleted color and are skipped while that colour is fully transparent
-- Entity mode keeps every entity it was shown with until Hide is fired with that entity
local LocHighlight = {}

LocHighlight.RESCAN_SECONDS = 0.6

-- Returns a function that lists the matching entities and whether each one is up
-- Tiles from the last scan are followed so a stump is still drawn as depleted
function LocHighlight.SearchSource(spec)
    local tracked = {}
    return function()
        local playerCg = LocMatch.PlayerCoord()
        if playerCg == nil then
            return {}
        end
        local items = {}
        local nextTracked = {}
        for _, entity in ipairs(LocMatch.Collect(spec, tracked, playerCg)) do
            local key = LocMatch.TileKey(entity)
            if key ~= nil and nextTracked[key] == nil then
                nextTracked[key] = { coord = LocMatch.PlainCoord(entity.coordGrid) }
                items[#items + 1] = { entity = entity, up = LocMatch.Standing(spec, entity) }
            end
        end
        tracked = nextTracked
        return items
    end
end

local function isTransparent(color)
    return type(color) ~= "table" or color.a == 0
end

-- Effect handle where update rescans and reports if it is alive and draw paints the last scan
function LocHighlight.BuildHandle(settings, source)
    local handle = { kind = "loc_highlight", state = {}, alive = true }
    local elapsed = 0
    local sinceScan = math.huge
    local items = {}

    function handle.update(dt)
        elapsed = elapsed + (tonumber(dt) or 0)
        sinceScan = sinceScan + (tonumber(dt) or 0)
        if sinceScan >= LocHighlight.RESCAN_SECONDS then
            sinceScan = 0
            items = source()
        end
        handle.alive = settings.hold <= 0 or elapsed < settings.hold
        return handle.alive
    end

    function handle.draw(canvas)
        for _, item in ipairs(items) do
            local color = settings.color
            if not item.up then
                color = settings.depletedColor
            end
            if not isTransparent(color) and item.entity.isValid ~= false then
                local look = {
                    style = settings.style,
                    color = color,
                    heightTiles = settings.heightTiles,
                    pulse = settings.pulse,
                    elapsed = elapsed,
                }
                local at = LocDraw.DrawFootprint(canvas, LocDraw.Footprint(item.entity), look)
                if settings.label and at ~= nil then
                    LocDraw.Text(canvas, at, LocMatch.StripTags(item.entity.displayName), color)
                end
            end
        end
    end

    -- Up and depleted counts from the last scan
    function handle.counts()
        local up, depleted = 0, 0
        for _, item in ipairs(items) do
            if item.up then
                up = up + 1
            else
                depleted = depleted + 1
            end
        end
        return up, depleted
    end

    return handle
end

local function sameColor(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a
end

local function sameSettings(a, b)
    return a.target == b.target
        and a.style == b.style
        and sameColor(a.color, b.color)
        and sameColor(a.depletedColor, b.depletedColor)
        and a.heightTiles == b.heightTiles
        and a.pulse == b.pulse
        and a.label == b.label
        and a.hold == b.hold
end

-- Lists the shown entities in tile order so Show and Hide only edit the set
-- Entities the game removed are dropped here so a Gone Loc needs no Hide
local function entitySource(state)
    return function()
        local keys = {}
        for key in pairs(state.entities) do
            keys[#keys + 1] = key
        end
        table.sort(keys)
        local items = {}
        for _, key in ipairs(keys) do
            local entity = state.entities[key]
            if entity.isValid == false then
                state.entities[key] = nil
            else
                items[#items + 1] = { entity = entity, up = entity.isHidden ~= true }
            end
        end
        return items
    end
end

local function dismiss(runtime, state)
    if state.handle ~= nil then
        runtime.effects:Dismiss(state.handle)
        state.handle = nil
    end
end

-- Show adds the wired entity and Hide removes it
-- Hide without an entity does nothing because Gone has no entity and must not clear the others
-- A stump is on the same tile as its tree so it replaces it
local function runEntity(ctx, state, runtime, settings)
    local entity = ctx:In("entity")
    local key = nil
    if entity ~= nil then
        key = LocMatch.TileKey(entity)
    end
    if ctx.exec == "hide" then
        if key == nil or state.entities == nil then
            return
        end
        state.entities[key] = nil
        if next(state.entities) == nil then
            dismiss(runtime, state)
        end
        return
    end
    if key == nil then
        return
    end
    local running = state.handle ~= nil and state.handle.alive
    if not running or state.entities == nil then
        -- A highlight that ran out its Hold starts over
        state.entities = {}
    end
    state.entities[key] = entity
    settings.target = "entity"
    if running and sameSettings(state.settings, settings) then
        return
    end
    dismiss(runtime, state)
    state.handle = LocHighlight.BuildHandle(settings, entitySource(state))
    state.settings = settings
    runtime.effects:PushStack(state, state.handle, 1)
end

local function readSettings(ctx)
    return {
        style = ctx:In("style"),
        color = ctx:In("color"),
        depletedColor = ctx:In("depletedColor"),
        heightTiles = ctx:In("heightTiles"),
        pulse = ctx:In("pulse") == true,
        label = ctx:In("showLabel") ~= false,
        hold = tonumber(ctx:In("hold")) or 0,
    }
end

local function lookPins()
    return {
        { name = "style", kind = "data", direction = "in", dataType = "loc_highlight.style", label = "Style",
          default = "outline" },
        { name = "color", kind = "data", direction = "in", dataType = "color", label = "Color",
          default = { r = 0, g = 255, b = 255, a = 255 } },
        { name = "depletedColor", kind = "data", direction = "in", dataType = "color", label = "Depleted color",
          default = { r = 235, g = 90, b = 80, a = 0 } },
        { name = "heightTiles", kind = "data", direction = "in", dataType = "number", label = "Box height", default = 2 },
        { name = "pulse", kind = "data", direction = "in", dataType = "bool", label = "Pulse", default = false },
        { name = "showLabel", kind = "data", direction = "in", dataType = "bool", label = "Label", default = true },
        { name = "hold", kind = "data", direction = "in", dataType = "number", label = "Hold (s)", default = 0 },
    }
end

local function modePins(inputs)
    local pins = {
        { name = "show", kind = "exec", direction = "in", label = "Show" },
        { name = "hide", kind = "exec", direction = "in", label = "Hide" },
    }
    for _, pin in ipairs(inputs) do
        pins[#pins + 1] = pin
    end
    for _, pin in ipairs(lookPins()) do
        pins[#pins + 1] = pin
    end
    return pins
end

---@param registry LibNodeGraph.Registry
---@param runtime Watchdog.Runtime
function LocHighlight.Register(registry, runtime)
    pcall(function()
        local Controls = require("src/ui/controls")
        Controls.Register("loc_highlight.style", { widget = "enum", choices = LocDraw.STYLES })
    end)

    registry:RegisterNodeType("action.loc_highlight", {
        category = "action",
        displayName = "Loc Highlight",
        description = "Outline / fill / 3D-box objects on screen. Depleted ones in a second colour.",
        defaultMode = LocMatch.MODE_SEARCH,
        modes = {
            { key = LocMatch.MODE_SEARCH, label = "Search (name / id)", pins = modePins({
                { name = "nameMatch", kind = "data", direction = "in", dataType = "matcher", label = "Name",
                  default = { needle = "", mode = "substring" } },
                { name = "option", kind = "data", direction = "in", dataType = "string", label = "Option", default = "" },
                { name = "watchId", kind = "data", direction = "in", dataType = "number", label = "LocType id",
                  default = 0 },
                { name = "scanRange", kind = "data", direction = "in", dataType = "number", label = "Range",
                  default = LocMatch.DEFAULT_SCAN_RANGE },
            }) },
            { key = "entity", label = "Wired entity", pins = modePins({
                { name = "entity", kind = "data", direction = "in", dataType = "any", label = "Entity" },
            }) },
        },
        run = function(ctx)
            ctx.state = ctx.state or {}
            local state = ctx.state
            if ctx.mode == "entity" then
                runEntity(ctx, state, runtime, readSettings(ctx))
                return
            end
            if ctx.exec == "hide" then
                dismiss(runtime, state)
                return
            end

            local settings = readSettings(ctx)
            local spec = LocMatch.SpecOf(LocMatch.HandleFromCtx(ctx))
            if spec ~= nil then
                settings.target = LocMatch.Key(spec)
            end

            -- Showing again with the same settings keeps the running highlight so a Client Tick can drive Show
            if state.handle ~= nil and state.handle.alive and sameSettings(state.settings, settings) then
                return
            end
            dismiss(runtime, state)
            if settings.target == nil then
                -- Nothing chosen so never outline the whole scene
                return
            end
            state.handle = LocHighlight.BuildHandle(settings, LocHighlight.SearchSource(spec))
            state.settings = settings
            runtime.effects:PushStack(state, state.handle, 1)
        end,
    })
end

return LocHighlight
