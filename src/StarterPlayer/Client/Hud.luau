--!strict
-- The HUD reports the shared simulation and server results; it grants nothing.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local Config = require(ReplicatedStorage.Shared.Config)
local Theme = require(script.Parent.UiTheme)
local C = Theme.colors
local cfg = Theme.config
local Hud = {}
local gui: ScreenGui
local safe: Frame
local crosshair: Frame
local holdoverTick: Frame
local hitMarker: Frame
local roundLabel: TextLabel
local bannerLabel: TextLabel
local rangeLabel: TextLabel
local hopperLabel: TextLabel
local hopperFill: Frame
local markerLabel: TextLabel
local remainingLabel: TextLabel
local deathsLabel: TextLabel
local chatterLabel: TextLabel
local phaseLabel: TextLabel
local currencyLabel: TextLabel
local camoLabel: TextLabel
local controls: TextLabel
local combatVisible = true
local bannerGeneration, chatterGeneration, hitGeneration = 0, 0, 0
local currentMarker = ""
local lastHopper = ""

local function centered(label: TextLabel)
	label.TextXAlignment = Enum.TextXAlignment.Center
end

function Hud.build()
	gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.IgnoreGuiInset = "LiveRoundHud", false, true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	safe = Theme.frame(gui, "Readouts", UDim2.new(1, -32, 1, -76), UDim2.fromOffset(16, 56))
	safe.BackgroundTransparency = 1
	local matchCard = Theme.frame(safe, "MatchCard", UDim2.new(0.64, 0, 0, 108), UDim2.new())
	matchCard.BackgroundTransparency = 0.15
	Theme.round(matchCard); Theme.outline(matchCard)
	local cardLimit = Instance.new("UISizeConstraint")
	cardLimit.MaxSize = Vector2.new(350, 108)
	cardLimit.Parent = matchCard
	roundLabel = Theme.text(matchCard, "Round", "THE LANDING", UDim2.new(1, -24, 0, 22), UDim2.fromOffset(12, 9), cfg.smallTextPixels)
	roundLabel.TextColor3, roundLabel.Font = C.accent, Enum.Font.GothamBold
	remainingLabel = Theme.text(matchCard, "Remaining", "Welcome to the field", UDim2.new(1, -24, 0, 28), UDim2.fromOffset(12, 31), 19)
	remainingLabel.Font = Enum.Font.GothamBold
	deathsLabel = Theme.text(matchCard, "Eliminations", "Clean run", UDim2.new(1, -24, 0, 20), UDim2.fromOffset(12, 61), cfg.smallTextPixels)
	phaseLabel = Theme.text(matchCard, "Phase", "", UDim2.new(1, -24, 0, 22), UDim2.fromOffset(12, 81), 11)
	phaseLabel.TextColor3 = C.muted
	currencyLabel = Theme.text(safe, "Currency", "", UDim2.new(0.36, -8, 0, 32), UDim2.new(0.64, 8, 0, 4), cfg.bodyTextPixels)
	currencyLabel.TextXAlignment, currencyLabel.TextColor3 = Enum.TextXAlignment.Right, C.gold
	currencyLabel.TextStrokeTransparency = 0.5
	bannerLabel = Theme.text(safe, "Banner", "", UDim2.new(1, -8, 0, 66), UDim2.new(0, 4, 0.24, 0), cfg.titleTextPixels)
	centered(bannerLabel)
	bannerLabel.Font, bannerLabel.TextColor3 = Enum.Font.GothamBold, C.gold
	bannerLabel.TextStrokeTransparency = 0.4

	crosshair = Theme.frame(gui, "SpreadRing", UDim2.fromOffset(6, 6), UDim2.fromScale(0.5, 0.5))
	crosshair.AnchorPoint, crosshair.BackgroundTransparency = Vector2.new(0.5, 0.5), 1
	Theme.round(crosshair, cfg.crosshairMaximumRadiusPixels)
	Theme.outline(crosshair, C.ink)
	local dot = Theme.frame(crosshair, "AimPoint", UDim2.fromOffset(3, 3), UDim2.fromScale(0.5, 0.5))
	dot.AnchorPoint, dot.BackgroundColor3 = Vector2.new(0.5, 0.5), C.ink
	Theme.round(dot)
	holdoverTick = Theme.frame(gui, "Holdover", UDim2.fromOffset(14, 2), UDim2.fromScale(0.5, 0.5))
	holdoverTick.AnchorPoint, holdoverTick.BackgroundColor3 = Vector2.new(0.5, 0.5), C.gold
	holdoverTick.Visible = false
	hitMarker = Theme.frame(gui, "HitMarker", UDim2.fromOffset(28, 28), UDim2.fromScale(0.5, 0.5))
	hitMarker.AnchorPoint, hitMarker.BackgroundTransparency, hitMarker.Visible = Vector2.new(0.5, 0.5), 1, false
	for _, rotation in ipairs({ 45, -45 }) do
		local line = Theme.frame(hitMarker, "Stroke", UDim2.fromOffset(24, 2), UDim2.fromScale(0.5, 0.5))
		line.AnchorPoint, line.Rotation, line.BackgroundColor3 = Vector2.new(0.5, 0.5), rotation, C.ink
	end
	rangeLabel = Theme.text(gui, "Range", "", UDim2.new(1, -32, 0, 24), UDim2.new(0, 16, 0.5, 42), cfg.smallTextPixels)
	centered(rangeLabel)
	rangeLabel.TextColor3, rangeLabel.TextStrokeTransparency = C.muted, 0.4

	local hopperCard = Theme.frame(safe, "HopperCard", UDim2.new(0.5, -6, 0, 80), UDim2.new(0, 0, 1, -106))
	hopperCard.BackgroundTransparency = 0.1
	Theme.round(hopperCard)
	local hopperLimit = Instance.new("UISizeConstraint")
	hopperLimit.MaxSize = Vector2.new(300, 80)
	hopperLimit.Parent = hopperCard
	markerLabel = Theme.text(hopperCard, "Marker", "", UDim2.new(1, -24, 0, 18), UDim2.fromOffset(12, 7), 11)
	markerLabel.TextColor3 = C.muted
	hopperLabel = Theme.text(hopperCard, "Hopper", "", UDim2.new(1, -24, 0, 33), UDim2.fromOffset(12, 25), cfg.titleTextPixels)
	hopperLabel.Font = Enum.Font.GothamBold
	local track = Theme.frame(hopperCard, "Capacity", UDim2.new(1, -24, 0, 4), UDim2.new(0, 12, 1, -12))
	track.BackgroundColor3 = C.line
	hopperFill = Theme.frame(track, "Fill", UDim2.fromScale(1, 1), UDim2.new())
	hopperFill.BackgroundColor3 = C.accent
	camoLabel = Theme.text(safe, "CamoProgress", "Headshots unlock reactive camos", UDim2.new(0.5, -6, 0, 68), UDim2.new(0.5, 6, 1, -106), cfg.smallTextPixels)
	camoLabel.TextColor3, camoLabel.TextXAlignment = C.gold, Enum.TextXAlignment.Right
	camoLabel.TextStrokeTransparency = 0.5
	chatterLabel = Theme.text(safe, "Chatter", "", UDim2.new(1, -8, 0, 56), UDim2.new(0, 4, 1, -170), cfg.bodyTextPixels)
	chatterLabel.TextColor3, chatterLabel.TextStrokeTransparency = C.ink, 0.35
	controls = Theme.text(safe, "Controls", "", UDim2.new(1, 0, 0, 22), UDim2.new(0, 0, 1, -22), 11)
	controls.TextColor3, controls.TextStrokeTransparency = C.muted, 0.4
	local function resize()
		controls.Text = if safe.AbsoluteSize.X < cfg.compactViewportPixels then "R reload  ·  Shift sprint  ·  Ctrl crouch"
			else "WASD move  ·  Mouse fire  ·  R reload  ·  Shift sprint  ·  Ctrl crouch  ·  C slide  ·  Q/E lean"
	end
	safe:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize)
	resize()
	if ReplicatedStorage:FindFirstChild("DemoMode") then
		local demo = Theme.text(safe, "Demo", "LOCAL DEMO\nProgress resets on exit", UDim2.new(0.36, -8, 0, 40), UDim2.new(0.64, 8, 0, 38), 11)
		demo.TextXAlignment, demo.TextColor3 = Enum.TextXAlignment.Right, C.muted
	end
end

function Hud.setMarker(id: string)
	currentMarker = Config.get("markers").markers[id].displayName
	markerLabel.Text = currentMarker
end

function Hud.setSpread(spreadDeg: number, fieldOfViewDeg: number, viewportHeight: number)
	local radius = math.clamp(spreadDeg * viewportHeight / fieldOfViewDeg, cfg.crosshairMinimumRadiusPixels, cfg.crosshairMaximumRadiusPixels)
	crosshair.Size = UDim2.fromOffset(radius * 2, radius * 2)
end

function Hud.setRange(distanceMetres: number?, spec: Ballistics.Spec, fieldOfViewDeg: number, viewportHeight: number)
	if not combatVisible or not distanceMetres or distanceMetres <= 0 then
		rangeLabel.Text, holdoverTick.Visible = "", false
		return
	end
	local drop = Ballistics.dropAt(spec, distanceMetres)
	local flight = Ballistics.timeOfFlight(spec, distanceMetres)
	local offset = math.deg(math.atan2(drop, distanceMetres)) * viewportHeight / fieldOfViewDeg
	-- Extremely distant scenery must not put a teaching tick offscreen.
	holdoverTick.Visible = offset < viewportHeight / 2
	holdoverTick.Position = UDim2.new(0.5, 0, 0.5, offset)
	rangeLabel.Text = string.format("%.0f m  ·  %.2f m drop  ·  %.0f ms flight", distanceMetres, drop, flight * 1000)
end

function Hud.setHopper(remaining: number, capacity: number, reloading: boolean)
	local text = if reloading then "RELOADING" else string.format("%d / %d", remaining, capacity)
	if text == lastHopper then return end
	lastHopper = text
	hopperLabel.Text = text
	local low = reloading or remaining <= capacity * cfg.lowHopperFraction
	hopperLabel.TextColor3 = if low then C.warning else C.ink
	hopperFill.BackgroundColor3 = if low then C.warning else C.accent
	hopperFill.Size = UDim2.fromScale(math.clamp(remaining / math.max(1, capacity), 0, 1), 1)
	markerLabel.Text = if remaining == 0 and not reloading then "EMPTY · R TO RELOAD" else currentMarker
end

function Hud.setRound(round: number, roundCount: number, _botCount: number)
	roundLabel.Text = string.format("ROUND %d / %d", round, roundCount)
end

function Hud.showBanner(text: string, seconds: number?)
	bannerGeneration += 1
	local generation = bannerGeneration
	bannerLabel.Text = text
	task.delay(seconds or cfg.bannerSeconds, function()
		if generation == bannerGeneration then bannerLabel.Text = "" end
	end)
end

function Hud.setRemaining(remaining: number, total: number)
	remainingLabel.Text = string.format("%d / %d still in", remaining, total)
end

function Hud.setDeaths(deaths: number, penaltyMultiplier: number)
	deathsLabel.Text = if deaths == 0 then "Clean run · full payout" else string.format("%d outs · payout ×%.2f", deaths, penaltyMultiplier)
	deathsLabel.TextColor3 = if deaths == 0 then C.accent else C.warning
end

function Hud.setCurrency(balance: number)
	currencyLabel.Text = Theme.number(balance) .. " FF"
end

function Hud.setCamoProgress(progress: any)
	if not progress then return end
	local nextUnlock = progress.nextUnlock
	camoLabel.Text = if nextUnlock then string.format("%s\n%d / %d headshots", nextUnlock.displayName, progress.headshots, nextUnlock.requiredHeadshots)
		else string.format("All camos earned\n%d headshots", progress.headshots)
	if progress.unlockedCamos and #progress.unlockedCamos > 0 then
		Hud.showBanner("REACTIVE CAMO UNLOCKED\nChoose your finish at Field Supply", cfg.headshotBannerSeconds)
	end
end

function Hud.hideSummary()
	local panel = gui:FindFirstChild("Summary")
	if panel then panel:Destroy() end
end

function Hud.isSummaryOpen(): boolean
	return gui:FindFirstChild("Summary") ~= nil
end

function Hud.setPhase(phase: string)
	combatVisible = phase == "live" or phase == "warmup"
	crosshair.Visible = combatVisible
	if not combatVisible then holdoverTick.Visible = false; rangeLabel.Text = "" end
	if phase == "warmup" then
		roundLabel.Text, phaseLabel.Text = "WARMUP", "Get set · paint does not count yet"
	elseif phase == "live" then
		phaseLabel.Text = "One hit is out · make it count"
	elseif phase == "intermission" then
		phaseLabel.Text = "Field resetting · next round loading"
	elseif phase == "shop" or phase == "hub" then
		roundLabel.Text, remainingLabel.Text, deathsLabel.Text = "THE LANDING", "Find your next field", "Progress stays with you"
		phaseLabel.Text = "F at counters · talk to the crew"
	elseif phase == "summary" then
		phaseLabel.Text = "Match complete"
	else phaseLabel.Text = "" end
end

function Hud.flashHit(headshot: boolean?)
	hitGeneration += 1
	local generation = hitGeneration
	for _, line in ipairs(hitMarker:GetChildren()) do
		if line:IsA("Frame") then line.BackgroundColor3 = if headshot then C.gold else C.ink end
	end
	hitMarker.Visible = true
	task.delay(cfg.hitFlashSeconds, function()
		if generation == hitGeneration then hitMarker.Visible = false end
	end)
end

function Hud.showChatter(line: { speaker: string, text: string })
	chatterGeneration += 1
	local generation = chatterGeneration
	chatterLabel.Text = `{line.speaker}: {line.text}`
	task.delay(cfg.chatterSeconds, function()
		if generation == chatterGeneration then chatterLabel.Text = "" end
	end)
end

function Hud.showSummary(summary: any, breakdown: any, onPlayAgain: (() -> any)?, onShop: (() -> any)?)
	Hud.hideSummary()
	local layer = Theme.frame(gui, "Summary", UDim2.fromScale(1, 1), UDim2.new())
	layer.BackgroundColor3, layer.BackgroundTransparency = C.black, 0.3
	local panel = Theme.frame(layer, "Report", UDim2.new(1, -32, 1, -100), UDim2.new(0.5, 0, 0.5, 20))
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	Theme.round(panel); Theme.outline(panel)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(cfg.summary.maxWidthPixels, cfg.summary.maxHeightPixels)
	limit.Parent = panel
	local title = Theme.text(panel, "Title", if summary.cleared then "FIELD CLEARED" else "MATCH REPORT", UDim2.new(1, -36, 0, 38), UDim2.fromOffset(18, 12), cfg.titleTextPixels)
	title.Font, title.TextColor3 = Enum.Font.GothamBold, C.accent
	local marker = Config.get("markers").markers[summary.marker]
	local subtitle = Theme.text(panel, "Subtitle", (summary.map or "Field") .. " · " .. (marker and marker.displayName or summary.marker), UDim2.new(1, -36, 0, 32), UDim2.fromOffset(18, 49), cfg.smallTextPixels)
	subtitle.TextColor3 = C.muted
	local content = Theme.scroll(panel, UDim2.new(1, -36, 1, -162), UDim2.fromOffset(18, 87))
	Theme.list(content, 10)
	local function section(name: string, height: number, index: number): Frame
		local row = Theme.frame(content, name, UDim2.new(1, -8, 0, height), UDim2.new())
		row.LayoutOrder, row.BackgroundColor3 = index, C.card
		Theme.round(row)
		return row
	end
	local stats = section("Stats", 76, 1)
	Theme.text(stats, "Totals", string.format("%d tags · %d headshots · %d outs\n%.0f%% hits · %d / %d rounds cleared", summary.eliminations or 0, summary.headshots or 0, summary.deaths or 0, (summary.hitRate or 0) * 100, breakdown.roundsCleared or 0, breakdown.roundsPlayed or 0), UDim2.new(1, -24, 1, -16), UDim2.fromOffset(12, 8), cfg.bodyTextPixels)
	local order = { "reactivity", "flicking", "targetSwitching", "tracking", "crosshairPlacement", "leadAndDrop" }
	local pretty = { reactivity = "Reactivity", flicking = "Flicking", targetSwitching = "Target switching", tracking = "Tracking", crosshairPlacement = "Crosshair placement", leadAndDrop = "Lead & drop" }
	for i, name in ipairs(order) do
		local entry = summary.scores and summary.scores[name]
		local score = math.clamp(entry and entry.score or 0, 0, 100)
		local color = if summary.weakest == name then C.gold else C.accent
		local row = section(name, 66, i + 1)
		Theme.text(row, "Label", pretty[name], UDim2.new(0.7, -12, 0, 25), UDim2.fromOffset(12, 7), cfg.bodyTextPixels)
		local value = Theme.text(row, "Score", if entry and entry.confident then tostring(math.floor(score + 0.5)) else "—", UDim2.new(0.3, -12, 0, 25), UDim2.new(0.7, 0, 0, 7), cfg.bodyTextPixels)
		value.TextXAlignment, value.TextColor3 = Enum.TextXAlignment.Right, color
		local track = Theme.frame(row, "Track", UDim2.new(1, -24, 0, 4), UDim2.fromOffset(12, 35))
		track.BackgroundColor3 = C.line
		local fill = Theme.frame(track, "Fill", UDim2.fromScale(score / 100, 1), UDim2.new())
		fill.BackgroundColor3 = color
		local hint = Theme.text(row, "Hint", if not entry or not entry.confident then "Keep playing to measure this skill" elseif summary.weakest == name then "Your next focus" else "Measured from this match", UDim2.new(1, -24, 0, 19), UDim2.fromOffset(12, 42), 11)
		hint.TextColor3 = C.muted
	end
	if summary.prescription then
		local prescription = section("NextSession", 104, 8)
		local text = Theme.text(prescription, "Prescription", summary.prescription.line .. "\nRange drill: " .. summary.prescription.drill, UDim2.new(1, -24, 1, -16), UDim2.fromOffset(12, 8), cfg.smallTextPixels)
		text.TextColor3 = C.gold
	end
	local payout = section("Payout", 76, 9)
	Theme.text(payout, "Total", Theme.number(breakdown.total or 0) .. " FF EARNED", UDim2.new(1, -24, 0, 32), UDim2.fromOffset(12, 7), 20).TextColor3 = C.gold
	Theme.text(payout, "Multiplier", string.format("Payout multiplier ×%.2f · progress kept", breakdown.deathPenalty or 1), UDim2.new(1, -24, 0, 25), UDim2.fromOffset(12, 42), cfg.smallTextPixels)
	local status = Theme.text(panel, "Status", "", UDim2.new(1, -36, 0, 20), UDim2.new(0, 18, 1, -72), 11)
	status.TextColor3 = C.warning
	local busy = false
	local function act(callback: (() -> any)?)
		if busy or not callback then return end
		busy = true
		status.Text = "Loading…"
		local ok, result = pcall(callback)
		if not layer.Parent then return end
		if ok and (result == nil or (type(result) == "table" and result.ok)) then
			layer:Destroy()
		else
			status.Text = if ok and type(result) == "table" then result.reason or "Please try again." else "Connection interrupted. Please try again."
			busy = false
		end
	end
	if onShop then
		local shop = Theme.button(panel, "Field supply", UDim2.new(0.5, -24, 0, 38), UDim2.new(0, 18, 1, -48))
		shop.BackgroundColor3, shop.TextColor3, shop.Modal = C.card, C.ink, true
		shop.Activated:Connect(function() act(onShop) end)
	end
	local again = Theme.button(panel, "Play again", UDim2.new(0.5, -24, 0, 38), UDim2.new(0.5, 6, 1, -48))
	again.Modal = true
	again.Activated:Connect(function() act(onPlayAgain) end)
end

return Hud
