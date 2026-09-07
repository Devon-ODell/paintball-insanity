--!strict
-- Conversations keep their text and choices readable in a scrollable panel.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Net.Remotes)
local Theme = require(script.Parent.UiTheme)
local DialogueUi = {}
local gui: ScreenGui? = nil
local onChoose: ((number) -> ())? = nil
local onClose: (() -> ())? = nil
local keyConnection: RBXScriptConnection? = nil

function DialogueUi.setOnClose(callback: () -> ())
	onClose = callback
end

function DialogueUi.close()
	if keyConnection then keyConnection:Disconnect(); keyConnection = nil end
	if gui then gui:Destroy(); gui = nil end
	onChoose = nil
	if onClose then onClose() end
end

function DialogueUi.isOpen(): boolean
	return gui ~= nil
end

function DialogueUi.show(node: any, choose: (number) -> ())
	DialogueUi.close()
	onChoose = choose
	local screen = Instance.new("ScreenGui")
	screen.Name, screen.ResetOnSpawn, screen.DisplayOrder = "LiveRoundDialogue", false, 30
	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = screen
	local panel = Theme.frame(screen, "Conversation", UDim2.new(1, -24, 0.58, 0), UDim2.new(0.5, 0, 1, -12))
	panel.AnchorPoint, panel.BackgroundTransparency = Vector2.new(0.5, 1), 0.04
	Theme.round(panel); Theme.outline(panel)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(850, 430)
	limit.Parent = panel
	local speaker = Theme.text(panel, "Speaker", node.speaker or "Field crew", UDim2.new(1, -120, 0, 38), UDim2.fromOffset(16, 10), Theme.config.titleTextPixels)
	speaker.Font, speaker.TextColor3 = Enum.Font.GothamBold, Theme.colors.gold
	local close = Theme.button(panel, "Leave", UDim2.fromOffset(76, 34), UDim2.new(1, -92, 0, 12))
	close.Modal = true
	local function stepAway()
		Remotes.event("DialogueChoice"):FireServer(0)
		DialogueUi.close()
	end
	close.Activated:Connect(stepAway)
	local scroll = Theme.scroll(panel, UDim2.new(1, -32, 1, -66), UDim2.fromOffset(16, 56))
	Theme.list(scroll, 8)
	local body = Theme.text(scroll, "Dialogue", table.concat(node.lines or {}, "\n\n"), UDim2.new(1, -8, 0, 0), UDim2.new(), Theme.config.bodyTextPixels)
	body.AutomaticSize, body.TextYAlignment, body.LayoutOrder = Enum.AutomaticSize.Y, Enum.TextYAlignment.Top, 0
	local options = node.options or {}
	local busy = false
	local buttons: { TextButton } = {}
	local function pick(index: number)
		if busy or not onChoose then return end
		busy = true
		for _, button in ipairs(buttons) do button.Active = false end
		onChoose(index)
	end
	for index, option in ipairs(options) do
		local button = Theme.button(scroll, `{index}.  {option.text}`, UDim2.new(1, -8, 0, 46), UDim2.new())
		button.LayoutOrder, button.AutomaticSize = index, Enum.AutomaticSize.Y
		button.BackgroundColor3, button.TextColor3 = Theme.colors.card, Theme.colors.ink
		local padding = Instance.new("UIPadding")
		padding.PaddingLeft, padding.PaddingRight = UDim.new(0, 12), UDim.new(0, 12)
		padding.PaddingTop, padding.PaddingBottom = UDim.new(0, 10), UDim.new(0, 10)
		padding.Parent = button
		table.insert(buttons, button)
		button.Activated:Connect(function() pick(index) end)
	end
	if #options == 0 then
		local hint = Theme.text(scroll, "Hint", "Select Leave, or press E to step away.", UDim2.new(1, -8, 0, 36), UDim2.new(), Theme.config.smallTextPixels)
		hint.LayoutOrder, hint.TextColor3 = 1, Theme.colors.muted
	end
	keyConnection = UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not gui then return end
		if input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.ButtonB then stepAway(); return end
		local digits = { [Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3, [Enum.KeyCode.Four] = 4, [Enum.KeyCode.Five] = 5 }
		local index = digits[input.KeyCode]
		if index and options[index] then pick(index) end
	end)
end

return DialogueUi
