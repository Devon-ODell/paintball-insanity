--!strict
-- Each menu owns focus and its Back action for exactly its visible lifetime.
local GuiService = game:GetService("GuiService")
local InputService = game:GetService("UserInputService")
local Actions = game:GetService("ContextActionService")
local Navigation = {}

function Navigation.refresh(root: GuiObject, preferred: GuiObject?)
	local items: { GuiObject } = {}
	for _, child in ipairs(root:GetDescendants()) do
		if child:IsA("GuiButton") or child:IsA("ScrollingFrame") then
			child.Selectable = true
			child.SelectionOrder = #items + 1
			table.insert(items, child)
		end
	end
	for index, item in ipairs(items) do
		local previous = items[(index - 2) % #items + 1]
		local following = items[index % #items + 1]
		item.NextSelectionUp, item.NextSelectionLeft = previous, previous
		item.NextSelectionDown, item.NextSelectionRight = following, following
	end
	local selected = GuiService.SelectedObject
	if InputService.PreferredInput == Enum.PreferredInput.Gamepad
		and (not selected or not selected:IsDescendantOf(root)) then
		GuiService.SelectedObject = preferred or items[1]
	end
end

function Navigation.bind(root: GuiObject, preferred: GuiObject?, back: (() -> ())?)
	local action = "LR_MenuBack_" .. root.Name
	Navigation.refresh(root, preferred)
	local changed = InputService:GetPropertyChangedSignal("PreferredInput"):Connect(function()
		Navigation.refresh(root, preferred)
	end)
	if back then
		Actions:BindActionAtPriority(action, function(_, state)
			if state == Enum.UserInputState.Begin then back() end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.ButtonB)
	end
	root.Destroying:Connect(function()
		changed:Disconnect()
		if back then Actions:UnbindAction(action) end
		local selected = GuiService.SelectedObject
		if selected and selected:IsDescendantOf(root) then GuiService.SelectedObject = nil end
	end)
end

return Navigation
