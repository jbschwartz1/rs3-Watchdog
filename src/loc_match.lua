local Matcher = require("src/matcher")

-- Shared by Loc Watch and Loc Highlight to decide which Locs a node means and whether each one is up
-- https://developer.runescape.com/rs/game/entity/locentity.html
-- https://developer.runescape.com/rs/game/config/loctype.html
local LocMatch = {}

LocMatch.MODE_SEARCH = "search"
LocMatch.MODE_OBJECT = "object"
LocMatch.DEFAULT_SCAN_RANGE = 16
LocMatch.TILE = 512

---@class Watchdog.LocMatch.Spec
---@field object table|nil  # captured object with its name and tile
---@field matcher table|nil
---@field configId number|nil
---@field option string|nil
---@field radius number
---@field scanRange number

function LocMatch.StripTags(text)
    if type(text) ~= "string" then
        return text
    end
    return (text:gsub("<[^>]*>", ""))
end

function LocMatch.PlainCoord(coordGrid)
    if coordGrid == nil then
        return nil
    end
    return { x = coordGrid.x, z = coordGrid.z, level = coordGrid.level or 0 }
end

function LocMatch.Distance(a, b)
    return math.max(math.abs(a.x - b.x), math.abs(a.z - b.z))
end

-- Display name plus own and parent config names so a MultiLoc child still matches by its parent
function LocMatch.NamesOf(entity)
    local names = {}
    local function add(name)
        if type(name) == "string" and name ~= "" then
            names[#names + 1] = name
        end
    end
    add(LocMatch.StripTags(entity.displayName))
    if entity.config ~= nil then
        add(entity.config.name)
        add(entity.config.configName)
    end
    if entity.parentConfig ~= nil then
        add(entity.parentConfig.name)
        add(entity.parentConfig.configName)
    end
    return names
end

local function configHasOption(config, needle)
    if config == nil or config.opNames == nil then
        return false
    end
    for _, op in pairs(config.opNames) do
        if type(op) == "string" and op:lower():find(needle, 1, true) then
            return true
        end
    end
    return false
end

function LocMatch.HasOption(entity, option)
    local needle = option:lower()
    return configHasOption(entity.config, needle) or configHasOption(entity.parentConfig, needle)
end

local function validObject(object)
    if type(object) ~= "table" or type(object.coordGrid) ~= "table" then
        return nil
    end
    if object.coordGrid.x == nil or object.coordGrid.z == nil then
        return nil
    end
    return object
end

local function validMatcher(matcher)
    if type(matcher) ~= "table" or type(matcher.needle) ~= "string" or matcher.needle == "" then
        return nil
    end
    return matcher
end

-- Returns nil when nothing is set so an empty node never matches the whole scene
-- Inputs left over from the other mode are ignored
---@return Watchdog.LocMatch.Spec|nil
function LocMatch.SpecOf(node)
    local spec = {
        radius = math.max(0, math.floor(tonumber(node.GetControl("radius")) or 0)),
        scanRange = math.max(1, math.floor(tonumber(node.GetControl("scanRange")) or LocMatch.DEFAULT_SCAN_RANGE)),
    }
    if node.mode ~= LocMatch.MODE_SEARCH then
        spec.object = validObject(node.GetControl("object"))
    end
    if node.mode ~= LocMatch.MODE_OBJECT then
        spec.matcher = validMatcher(node.GetControl("nameMatch"))
        local id = tonumber(node.GetControl("watchId"))
        if id ~= nil and id > 0 then
            spec.configId = math.floor(id)
        end
        local option = node.GetControl("option")
        if type(option) == "string" and option ~= "" then
            spec.option = option
        end
    end
    if spec.object == nil and spec.matcher == nil and spec.configId == nil and spec.option == nil then
        return nil
    end
    return spec
end

-- ctx:In asserts on pins the current mode does not have so those read as nil
function LocMatch.HandleFromCtx(ctx)
    return {
        mode = ctx.mode,
        GetControl = function(name)
            local ok, value = pcall(ctx.In, ctx, name)
            if ok then
                return value
            end
            return nil
        end,
    }
end

-- Changes whenever the spec does
function LocMatch.Key(spec)
    local parts = { tostring(spec.option), tostring(spec.configId), tostring(spec.radius), tostring(spec.scanRange) }
    if spec.matcher ~= nil then
        parts[#parts + 1] = spec.matcher.mode .. ":" .. spec.matcher.needle
    end
    if spec.object ~= nil then
        local c = spec.object.coordGrid
        parts[#parts + 1] = string.format("%d,%d,%d %s", c.level or 0, c.x, c.z, tostring(spec.object.name))
    end
    return table.concat(parts, "|")
end

-- True when the Loc belongs to the spec in any of its states
-- With a Name or LocType id set the Option only decides up or depleted so stumps and locked doors still match
function LocMatch.Identity(spec, entity)
    if spec.object ~= nil then
        return true
    end
    if spec.configId ~= nil and entity.configID ~= spec.configId and entity.parentConfigID ~= spec.configId then
        return false
    end
    if spec.matcher ~= nil then
        local hit = false
        for _, name in ipairs(LocMatch.NamesOf(entity)) do
            if Matcher.Test(spec.matcher, name) then
                hit = true
                break
            end
        end
        if not hit then
            return false
        end
    end
    local optionOnly = spec.matcher == nil and spec.configId == nil
    if optionOnly and spec.option ~= nil and not LocMatch.HasOption(entity, spec.option) then
        return false
    end
    return true
end

-- Depleted means hidden or swapped for another Loc or missing the Option
function LocMatch.Standing(spec, entity)
    if entity.isHidden == true then
        return false
    end
    if entity.config == nil and entity.isMultiLoc == true then
        return false
    end
    local name = LocMatch.StripTags(entity.displayName) or ""
    if spec.object ~= nil then
        local wanted = LocMatch.StripTags(spec.object.name)
        if type(wanted) ~= "string" or wanted == "" then
            return true
        end
        return name:lower() == wanted:lower()
    end
    -- An unlocked door can be renamed to Door so only the Option counts
    if spec.option ~= nil then
        return LocMatch.HasOption(entity, spec.option)
    end
    -- A parent id counts any visible child as up and a child id counts only that child
    local idMatches = entity.configID == spec.configId or entity.parentConfigID == spec.configId
    if spec.configId ~= nil and spec.matcher == nil and not idMatches then
        return false
    end
    if spec.matcher ~= nil then
        local configName = entity.config ~= nil and entity.config.configName or ""
        if not Matcher.Test(spec.matcher, name) and not Matcher.Test(spec.matcher, configName) then
            return false
        end
    end
    return true
end

-- Tile and shape so a tree swapped for a stump keeps its key but decor on the same tile does not
function LocMatch.TileKey(entity)
    local c = entity.coordGrid
    if c == nil then
        return nil
    end
    return string.format("%d,%d,%d#%s", c.level or 0, c.x, c.z, tostring(entity.shapeType))
end

-- nil while logged out or loading
function LocMatch.PlayerCoord()
    if not Player.IsAvailable() then
        return nil
    end
    local player = Player.GetEntity()
    if player == nil then
        return nil
    end
    return player.coordGrid
end

-- Ground height is only available inside the loaded area
-- https://developer.runescape.com/rs/game/world.html#World.World.GetGroundHeight
function LocMatch.IsLoaded(coord)
    local half = LocMatch.TILE // 2
    local _, available = World.GetGroundHeight(coord.level or 0,
        coord.x * LocMatch.TILE + half, coord.z * LocMatch.TILE + half)
    return available == true
end

-- On the same level and loaded and in search mode also inside Range
function LocMatch.Visible(spec, coord, player)
    if player == nil or coord == nil or (player.level or 0) ~= (coord.level or 0) then
        return false
    end
    if spec.object == nil and LocMatch.Distance(player, coord) > spec.scanRange then
        return false
    end
    return LocMatch.IsLoaded(coord)
end

-- Matching Locs plus whatever now sits on a tracked tile with the same shape
-- A var swap or a tree turning into a stump changes the name but it is still the same object
---@param tracked table<string, table>  # keyed by tile key
function LocMatch.Collect(spec, tracked, playerCg)
    local player = LocMatch.PlainCoord(playerCg)
    local center, radius = player, spec.scanRange
    if spec.object ~= nil then
        center, radius = spec.object.coordGrid, spec.radius
    end
    local level = center.level or 0
    -- https://developer.runescape.com/rs/game/list/loclist.html
    local list = LocList.Filter({
        coordGrid = playerCg,
        range = LocMatch.Distance(player, center) + radius,
        sameLevel = false,
        func = function(entity)
            local c = entity.coordGrid
            if (c.level or 0) ~= level or LocMatch.Distance(center, c) > radius then
                return false
            end
            return LocMatch.Identity(spec, entity)
        end,
    }) or {}
    local seen = {}
    for _, entity in ipairs(list) do
        seen[LocMatch.TileKey(entity)] = true
    end
    local missing, reach = {}, 0
    for key, tile in pairs(tracked) do
        if not seen[key] then
            missing[key] = true
            reach = math.max(reach, LocMatch.Distance(player, tile.coord))
        end
    end
    if next(missing) == nil then
        return list
    end
    local followed = LocList.Filter({
        coordGrid = playerCg,
        range = reach,
        sameLevel = false,
        func = function(entity)
            return missing[LocMatch.TileKey(entity)] == true
        end,
    }) or {}
    for _, entity in ipairs(followed) do
        list[#list + 1] = entity
    end
    return list
end

return LocMatch
