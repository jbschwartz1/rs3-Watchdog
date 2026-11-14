local Theme = require("src/ui/theme")

-- Draws a Loc footprint on screen as an outline or fill or pulse or 3D box
-- Geometry is in fine units and project turns a point into screen space
-- https://developer.runescape.com/rs/game/screenconvert.html
-- https://developer.runescape.com/rs/ui/decorative_components/canvas.html
local LocDraw = {}

LocDraw.TILE = 512

LocDraw.STYLES = {
    { value = "outline", label = "Outline" },
    { value = "fill",    label = "Fill" },
    { value = "box",     label = "3D box" },
    { value = "pulse",   label = "Pulse" },
}

LocDraw.PULSE_PERIOD = 1.2 -- seconds per breath
LocDraw.PULSE_MIN = 0.15 -- fill opacity at the bottom of a breath
LocDraw.PULSE_MAX = 0.65 -- fill opacity at the top of a breath
LocDraw.LINE_MIN = 0.25 -- line opacity at the bottom of a breath with Pulse on
LocDraw.FILL_ALPHA = 0.3

-- Position in the breath from 0 to 1 at t seconds
function LocDraw.Breath(t)
    return 0.5 + 0.5 * math.sin(t / LocDraw.PULSE_PERIOD * 2 * math.pi)
end

-- Fill opacity of the Pulse style at t seconds
function LocDraw.PulseAlpha(t)
    return LocDraw.PULSE_MIN + (LocDraw.PULSE_MAX - LocDraw.PULSE_MIN) * LocDraw.Breath(t)
end

-- Width and length are already rotated so they are used as given
-- https://developer.runescape.com/rs/game/entity/locentity.html
function LocDraw.Footprint(entity)
    local c = entity.coordGrid
    if c == nil then
        return nil
    end
    local width = math.max(1, tonumber(entity.width) or 1)
    local length = math.max(1, tonumber(entity.length) or 1)
    return {
        level = c.level or 0,
        x0 = c.x * LocDraw.TILE,
        z0 = c.z * LocDraw.TILE,
        x1 = (c.x + width) * LocDraw.TILE,
        z1 = (c.z + length) * LocDraw.TILE,
    }
end

-- Returns nil when off screen or when the client rejects the point so one bad corner does not stop the frame
function LocDraw.DefaultProject(level, x, z, height)
    local ok, point = pcall(function()
        return ScreenConvert.CoordFineToScreen(CoordFine.new(level, math.floor(x), math.floor(z)), math.floor(height))
    end)
    if not ok or point == nil or type(point.x) ~= "number" or type(point.y) ~= "number" then
        return nil
    end
    return { x = point.x, y = point.y }
end

-- The four projected corners at a height or nil when any corner is off screen
function LocDraw.Ring(footprint, height, project)
    local corners = {
        { footprint.x0, footprint.z0 }, { footprint.x1, footprint.z0 },
        { footprint.x1, footprint.z1 }, { footprint.x0, footprint.z1 },
    }
    local points = {}
    for _, corner in ipairs(corners) do
        local point = project(footprint.level, corner[1], corner[2], height)
        if point == nil then
            return nil
        end
        points[#points + 1] = point
    end
    return points
end

function LocDraw.Vec4(color, alphaScale)
    local alpha = (color.a or 255) / 255 * (alphaScale or 1)
    return Vector4.new((color.r or 0) / 255, (color.g or 0) / 255, (color.b or 0) / 255, alpha)
end

local function drawRing(canvas, points, width, colour)
    for i = 1, #points do
        local a = points[i]
        local b = points[i % #points + 1]
        canvas:AddLine(a.x, a.y, b.x, b.y, width, colour)
    end
end

---@class Watchdog.LocDraw.Look
---@field style "outline"|"fill"|"box"|"pulse"
---@field color table  # r g b a from 0 to 255
---@field heightTiles number  # box height in tiles
---@field elapsed number  # seconds since shown and drives the pulse
---@field pulse boolean  # Pulse toggle makes the lines breathe

-- Draws one footprint and returns where its label goes or nil when off screen
function LocDraw.DrawFootprint(canvas, footprint, look, project)
    project = project or LocDraw.DefaultProject
    local ground = LocDraw.Ring(footprint, 0, project)
    if ground == nil then
        return nil
    end
    local width = 2
    local lineAlpha = 1
    if look.pulse then
        local breath = LocDraw.Breath(look.elapsed)
        lineAlpha = LocDraw.LINE_MIN + (1 - LocDraw.LINE_MIN) * breath
        width = width + breath * 1.5
    end
    local lineColour = LocDraw.Vec4(look.color, lineAlpha)

    if look.style == "fill" or look.style == "pulse" then
        local fillAlpha = LocDraw.FILL_ALPHA
        if look.style == "pulse" then
            fillAlpha = LocDraw.PulseAlpha(look.elapsed)
        end
        local fill = LocDraw.Vec4(look.color, fillAlpha)
        pcall(function()
            canvas:AddTriangle(ground[1].x, ground[1].y, ground[2].x, ground[2].y, ground[3].x, ground[3].y, fill)
            canvas:AddTriangle(ground[1].x, ground[1].y, ground[3].x, ground[3].y, ground[4].x, ground[4].y, fill)
        end)
    end
    drawRing(canvas, ground, width, lineColour)

    local labelHeight = LocDraw.TILE / 2
    if look.style == "box" then
        local boxHeight = math.max(0, tonumber(look.heightTiles) or 2) * LocDraw.TILE
        local top = LocDraw.Ring(footprint, boxHeight, project)
        if top ~= nil then
            drawRing(canvas, top, width, lineColour)
            for i = 1, 4 do
                canvas:AddLine(ground[i].x, ground[i].y, top[i].x, top[i].y, width, lineColour)
            end
        end
        labelHeight = labelHeight + boxHeight
    end
    local centreX = (footprint.x0 + footprint.x1) / 2
    local centreZ = (footprint.z0 + footprint.z1) / 2
    return project(footprint.level, centreX, centreZ, labelHeight) or ground[1]
end

function LocDraw.Text(canvas, at, text, color)
    if text == nil or text == "" then
        return
    end
    local font = Theme.Font(12)
    if font == nil then
        return
    end
    local width = Theme.TextWidth(12, text) or #text * 7
    pcall(function()
        canvas:AddText(at.x - width / 2, at.y - 14, text, font, LocDraw.Vec4(color))
    end)
end

return LocDraw
