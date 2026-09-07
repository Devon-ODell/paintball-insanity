--!strict
-- Shared presentation helpers; prices and progression always come from the server.
local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Theme = {}
Theme.config = Config.get("ui")
Theme.colors = {} :: { [string]: Color3 }
for name, rgb in pairs(Theme.config.palette) do
	Theme.colors[name] = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

--[[
	Text that scales with the screen it is on.

	Every size in ui.json is a pixel count, and a pixel count is not a size: 13px
	is comfortable at 900px tall, unreadable on a 4K monitor and oversized on a
	phone. Roblox reports real device pixels, so the whole scale has to move with
	the viewport.

	Sizes are multiplied by the viewport's height against a reference height and
	clamped, so the UI grows on a big screen without a 27-inch monitor getting
	billboard text. Labels register themselves and are re-scaled on resize --
	which happens on window changes and on a phone rotating.
]]
local scalable: { { object: GuiObject, base: number } } = {}

local function viewportHeight(): number
	local ok, height = pcall(function()
		local camera = game:GetService("Workspace").CurrentCamera
		return camera and camera.ViewportSize.Y or nil
	end)
	if ok and type(height) == "number" and height > 1 then
		return height
	end
	return Theme.config.referenceViewportPixels
end

function Theme.scale(): number
	local limits = Theme.config.textScaleLimits
	return math.clamp(viewportHeight() / Theme.config.referenceViewportPixels, limits[1], limits[2])
end

--- A pixel size in ui.json, converted to a size for this screen.
function Theme.px(base: number): number
	return math.max(1, math.round(base * Theme.scale()))
end

local function track(object: GuiObject, base: number)
	table.insert(scalable, { object = object, base = base })
end

--- Re-applies the scale to every label built so far. Cheap; called on resize.
function Theme.refreshScale()
	local factor = Theme.scale()
	for index = #scalable, 1, -1 do
		local entry = scalable[index]
		if entry.object.Parent == nil then
			-- The UI is torn down and rebuilt constantly; do not leak.
			table.remove(scalable, index)
		else
			(entry.object :: any).TextSize = math.max(1, math.round(entry.base * factor))
		end
	end
end

--- Watches the viewport so the UI follows a window resize or a phone rotating.
function Theme.bindViewport()
	local ok, camera = pcall(function()
		return game:GetService("Workspace").CurrentCamera
	end)
	if not ok or not camera then
		return
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(Theme.refreshScale)
end

--[[
	Fonts, resolved by name from ui.json.

	They were hardcoded in Luau, which breaks the project's own rule that
	presentation values live in Data. Resolution falls back to Gotham rather
	than erroring: a font name that stops existing should make the UI look
	slightly different, never make it fail to build.
]]
local FALLBACK: { [string]: Enum.Font } = {
	body = Enum.Font.GothamMedium,
	bold = Enum.Font.GothamBold,
	title = Enum.Font.GothamBlack,
	numeric = Enum.Font.GothamBold,
}

function Theme.font(role: string): Enum.Font
	local name = Theme.config.fonts and Theme.config.fonts[role]
	if type(name) == "string" then
		local resolved = (Enum.Font :: any)[name]
		if resolved then
			return resolved
		end
	end
	return FALLBACK[role] or Enum.Font.GothamMedium
end

function Theme.round(object: GuiObject, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.px(radius or Theme.config.cornerPixels))
	corner.Parent = object
end

function Theme.outline(object: GuiObject, color: Color3?)
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = color or Theme.colors.line
	stroke.Transparency = 0.3
	stroke.Parent = object
end

function Theme.frame(parent: Instance, name: string, size: UDim2, position: UDim2): Frame
	local object = Instance.new("Frame")
	object.Name, object.Size, object.Position = name, size, position
	object.BackgroundColor3, object.BorderSizePixel = Theme.colors.panel, 0
	object.Parent = parent
	return object
end

function Theme.text(parent: Instance, name: string, value: string, size: UDim2, position: UDim2, textSize: number?): TextLabel
	local object = Instance.new("TextLabel")
	object.Name, object.Text, object.Size, object.Position = name, value, size, position
	object.BackgroundTransparency = 1
	local base = textSize or Theme.config.bodyTextPixels
	object.TextColor3, object.TextSize = Theme.colors.ink, Theme.px(base)
	object.Font = Theme.font("body")
	track(object, base)
	object.TextXAlignment, object.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Center
	object.TextWrapped = true
	object.Parent = parent
	return object
end

function Theme.button(parent: Instance, value: string, size: UDim2, position: UDim2): TextButton
	local object = Instance.new("TextButton")
	object.Text, object.Size, object.Position = value, size, position
	object.BackgroundColor3, object.TextColor3 = Theme.colors.accent, Theme.colors.panel
	object.Font, object.TextSize = Theme.font("bold"), Theme.px(Theme.config.bodyTextPixels)
	object.BorderSizePixel, object.TextWrapped = 0, true
	track(object, Theme.config.bodyTextPixels)
	object.Parent = parent
	Theme.round(object)
	return object
end

function Theme.scroll(parent: Instance, size: UDim2, position: UDim2): ScrollingFrame
	local object = Instance.new("ScrollingFrame")
	object.Size, object.Position = size, position
	object.BackgroundTransparency, object.BorderSizePixel = 1, 0
	object.ScrollBarThickness, object.ScrollBarImageColor3 = Theme.px(Theme.config.scrollbarPixels) + 2, Theme.colors.accent
	object.AutomaticCanvasSize, object.ScrollingDirection = Enum.AutomaticSize.Y, Enum.ScrollingDirection.Y
	object.CanvasSize = UDim2.new()
	object.Parent = parent
	return object
end

function Theme.list(parent: Instance, spacing: number): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.Padding, layout.SortOrder = UDim.new(0, spacing), Enum.SortOrder.LayoutOrder
	layout.Parent = parent
	return layout
end

function Theme.number(value: number): string
	local digits = tostring(math.floor(value))
	local formatted = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return formatted
end

return Theme
