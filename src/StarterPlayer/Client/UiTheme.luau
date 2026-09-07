--!strict
-- Shared presentation helpers; prices and progression always come from the server.
local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Theme = {}
Theme.config = Config.get("ui")
Theme.colors = {} :: { [string]: Color3 }
for name, rgb in pairs(Theme.config.palette) do
	Theme.colors[name] = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

function Theme.round(object: GuiObject, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or Theme.config.cornerPixels)
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
	object.TextColor3, object.TextSize = Theme.colors.ink, textSize or Theme.config.bodyTextPixels
	object.Font = Enum.Font.GothamMedium
	object.TextXAlignment, object.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Center
	object.TextWrapped = true
	object.Parent = parent
	return object
end

function Theme.button(parent: Instance, value: string, size: UDim2, position: UDim2): TextButton
	local object = Instance.new("TextButton")
	object.Text, object.Size, object.Position = value, size, position
	object.BackgroundColor3, object.TextColor3 = Theme.colors.accent, Theme.colors.panel
	object.Font, object.TextSize = Enum.Font.GothamBold, Theme.config.bodyTextPixels
	object.BorderSizePixel, object.TextWrapped = 0, true
	object.Parent = parent
	Theme.round(object)
	return object
end

function Theme.scroll(parent: Instance, size: UDim2, position: UDim2): ScrollingFrame
	local object = Instance.new("ScrollingFrame")
	object.Size, object.Position = size, position
	object.BackgroundTransparency, object.BorderSizePixel = 1, 0
	object.ScrollBarThickness, object.ScrollBarImageColor3 = Theme.config.scrollbarPixels, Theme.colors.accent
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
