--!strict
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GearStats = require(ReplicatedStorage.Shared.GearStats)
local Remotes = require(ReplicatedStorage.Net.Remotes)
local Config = require(ReplicatedStorage.Shared.Config)
local Theme = require(script.Parent.UiTheme)
local ShopUi = {}
local gui: ScreenGui? = nil
local closed: (() -> ())? = nil
local keyConnection: RBXScriptConnection? = nil
local selected = "markers"
local names = {
	markers = "Markers", barrels = "Barrels", hoppers = "Hoppers", tanks = "Air tanks",
	jerseys = "Jerseys", pads = "Pads", helmets = "Helmets", shoulders = "Shoulder rigs",
	masks = "Masks", markerSkins = "Marker finishes", pods = "Pods", paintColors = "Paint colours",
	consumables = "Field kit", camos = "Headshot camos", offers = "Collection",
}

function ShopUi.isOpen(): boolean
	return gui ~= nil
end

function ShopUi.close()
	if keyConnection then keyConnection:Disconnect(); keyConnection = nil end
	if gui then gui:Destroy(); gui = nil end
	if closed then local fn = closed; closed = nil; fn() end
end

local function detailFor(category: string, entry: any): (string, string)
	if category == "markers" then
		local data = Config.get("markers").markers[entry.id]
		return data.blurb, string.format("%d paintballs  ·  %.1fs reload  ·  %d balls/min", data.hopperCapacity, data.reloadSeconds, data.roundsPerMinute)
	elseif category == "camos" then
		local required = entry.requiredHeadshots or 0
		return entry.description or entry.blurb or "Reactive paintwork. Earn it with confirmed headshots.",
			if entry.owned then "Earned on the field" else string.format("%d / %d headshots", math.min(entry.headshots or 0, required), required)
	elseif category == "offers" then
		return entry.description or "Cosmetic collection.", "Cosmetic only"
	elseif table.find(GearStats.CATEGORIES, category) then
		local data = GearStats.item(category, entry.id)
		return (data and data.blurb) or "Field gear.", "Movement and noise tradeoffs"
	elseif category == "consumables" then
		return entry.blurb or "Field kit.", string.format("In your kit: %d  ·  %s", entry.held or 0, entry.source or "Field supply")
	elseif category == "paintColors" then
		return "Make your mark. Changes paintballs and splatters to your chosen colour.", "Cosmetic only"
	elseif category == "barrels" then
		return "Bore and porting change your sound signature.", "Noise tradeoff"
	elseif category == "hoppers" or category == "tanks" then
		return "Find the feed and air setup that suits your rhythm.", "Capacity, feed rate and reload tradeoffs"
	end
	return entry.description or "Personalise your field setup.", "Cosmetic only"
end

function ShopUi.open(initialSnapshot: any, onClose: () -> ())
	ShopUi.close()
	local snapshot = initialSnapshot
	local categories = table.clone(snapshot.categories or Config.get("venue").categories)
	if snapshot.catalogue.camos and table.find(categories, "markers") and not table.find(categories, "camos") then
		table.insert(categories, "camos")
	end
	if snapshot.catalogue.offers and #snapshot.catalogue.offers > 0 and not table.find(categories, "offers") then
		table.insert(categories, "offers")
	end
	if not table.find(categories, selected) then selected = categories[1] or "markers" end
	closed = onClose
	local screen = Instance.new("ScreenGui")
	screen.Name, screen.ResetOnSpawn = "PitStopShop", false
	screen.DisplayOrder = 20
	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = screen
	local shade = Theme.frame(screen, "Shade", UDim2.fromScale(1, 1), UDim2.new())
	shade.BackgroundColor3, shade.BackgroundTransparency = Theme.colors.black, 0.35
	local panel = Theme.frame(screen, "Counter", UDim2.new(1, -24, 1, -24), UDim2.fromScale(0.5, 0.5))
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	Theme.round(panel); Theme.outline(panel)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(Theme.config.shop.maxWidthPixels, Theme.config.shop.maxHeightPixels)
	limit.Parent = panel
	local title = Theme.text(panel, "Title", snapshot.bayName or "FIELD SUPPLY", UDim2.new(1, -120, 0, 32), UDim2.fromOffset(18, 14), Theme.config.titleTextPixels)
	title.Font = Theme.font("bold")
	local balance = Theme.text(panel, "Balance", "", UDim2.new(1, -36, 0, 22), UDim2.fromOffset(18, 48), Theme.config.smallTextPixels)
	balance.TextColor3 = Theme.colors.gold
	local close = Theme.button(panel, "Close", UDim2.fromOffset(78, 34), UDim2.new(1, -96, 0, 16))
	close.Modal = true
	close.Activated:Connect(ShopUi.close)
	local tabs = Theme.scroll(panel, UDim2.new(1, -36, 0, 46), UDim2.fromOffset(18, 78))
	tabs.AutomaticCanvasSize, tabs.ScrollingDirection = Enum.AutomaticSize.X, Enum.ScrollingDirection.X
	local tabLayout = Theme.list(tabs, 8)
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	local list = Theme.scroll(panel, UDim2.new(1, -36, 1, -212), UDim2.fromOffset(18, 130))
	local status = Theme.text(panel, "Status", "Choose your setup, then head to the field.", UDim2.new(1, -36, 0, 52), UDim2.new(0, 18, 1, -68), Theme.config.smallTextPixels)
	status.TextColor3 = Theme.colors.muted
	local busy = false
	local tabButtons: { [string]: TextButton } = {}
	local render: () -> ()
	local function transact(category: string, entry: any)
		if busy then return end
		busy = true
		status.Text = "Updating your kit…"
		local success, result = pcall(function()
			if category == "offers" then
				-- Free claims never invoke a Roblox purchase prompt. Future paid
				-- offers use Roblox's own confirmation and personalized price.
				return Remotes.fn("RequestCommerce"):InvokeServer({ action = if entry.free then "claim" else "prompt", id = entry.id })
			end
			local action = if entry.owned then "RequestEquip" else "RequestPurchase"
			local response = Remotes.fn(action):InvokeServer(category, entry.id)
			if response and response.ok and not entry.owned and category ~= "consumables" then
				response = Remotes.fn("RequestEquip"):InvokeServer(category, entry.id)
			end
			return response
		end)
		if gui ~= screen then return end
		status.Text = if success and result and result.ok then
			(if category == "offers" then (if entry.free then entry.displayName .. " added to your collection." else "Confirm the current price in the Roblox window.")
			elseif category == "consumables" then entry.displayName .. " added to your kit." else entry.displayName .. " equipped.")
			else (if success and result then result.reason or "Please try again." else "Connection interrupted. Try again.")
		local ok, fresh = pcall(function() return Remotes.fn("RequestShopCatalogue"):InvokeServer() end)
		if gui == screen and ok and fresh and fresh.ok then snapshot = fresh; render() end
		busy = false
	end
	render = function()
		list:ClearAllChildren()
		Theme.list(list, 10)
		balance.Text = Theme.number(snapshot.balance or 0) .. " FF  ·  " .. (if snapshot.freeMode then "All supply is free while we build" else "Field funds earned by playing")
		for category, tab in pairs(tabButtons) do
			tab.BackgroundColor3 = if selected == category then Theme.colors.accent else Theme.colors.card
			tab.TextColor3 = if selected == category then Theme.colors.panel else Theme.colors.ink
		end
		local entries = snapshot.catalogue[selected] or {}
		for i, entry in ipairs(entries) do
			local category = selected
			local row = Theme.frame(list, entry.id, UDim2.new(1, -8, 0, Theme.config.shop.cardHeightPixels), UDim2.new())
			row.LayoutOrder, row.BackgroundColor3 = i, Theme.colors.card
			Theme.round(row)
			local name = Theme.text(row, "Name", entry.displayName, UDim2.new(1, -28, 0, 30), UDim2.fromOffset(14, 10), 18)
			name.Font = Theme.font("bold")
			local detail, stats = detailFor(category, entry)
			local description = Theme.text(row, "Description", detail, UDim2.new(1, -28, 0, 53), UDim2.fromOffset(14, 42), Theme.config.smallTextPixels)
			description.TextColor3, description.TextYAlignment = Theme.colors.muted, Enum.TextYAlignment.Top
			local statLine = Theme.text(row, "Details", stats, UDim2.new(1, -28, 0, 32), UDim2.fromOffset(14, 98), Theme.config.smallTextPixels)
			statLine.TextColor3 = Theme.colors.gold
			local earned = category == "camos" or (entry.cost == nil and category ~= "offers")
			local price = if category == "offers" then (if entry.free then "FREE" else "Roblox purchase")
				elseif earned then "EARNED" elseif entry.cost == 0 then "FREE" else Theme.number(entry.cost) .. " FF"
			local priceLabel = Theme.text(row, "Price", price, UDim2.new(0.5, -20, 0, 36), UDim2.new(0, 14, 1, -46), Theme.config.smallTextPixels)
			priceLabel.TextColor3 = Theme.colors.accent
			local disabled = entry.equipped == true or (earned and not entry.owned) or (category == "offers" and entry.owned)
				or (category ~= "camos" and entry.purchasable == false)
			local actionText = if entry.equipped then "Equipped" elseif category == "offers" then
				(if entry.owned then "Collected" elseif entry.free then "Claim free" else "See price")
				elseif entry.owned then "Equip" elseif earned then "Earn on field" elseif entry.cost == 0 then "Claim free" else "Buy"
			local action = Theme.button(row, actionText, UDim2.new(0.5, -18, 0, 36), UDim2.new(0.5, 4, 1, -46))
			action.Active, action.AutoButtonColor = not disabled, not disabled
			if disabled then action.BackgroundColor3, action.TextColor3 = Theme.colors.panel, Theme.colors.muted end
			action.Activated:Connect(function() if not disabled then transact(category, entry) end end)
		end
		if #entries == 0 then Theme.text(list, "Empty", "Nothing at this counter yet.", UDim2.new(1, -16, 0, 50), UDim2.new()) end
	end
	for i, category in ipairs(categories) do
		local tab = Theme.button(tabs, names[category] or category, UDim2.fromOffset(132, 34), UDim2.new())
		tab.LayoutOrder = i
		tabButtons[category] = tab
		tab.Activated:Connect(function()
			if busy then return end
			selected = category
			list.CanvasPosition = Vector2.zero
			render()
		end)
	end
	keyConnection = UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.ButtonB then ShopUi.close() end
	end)
	render()
end

return ShopUi
