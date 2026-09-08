--!strict
-- The HUD reports the shared simulation and server results; it grants nothing.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local Config = require(ReplicatedStorage.Shared.Config)
local Theme = require(script.Parent.UiTheme)
local Navigation = require(script.Parent.UiNavigation)
local C = Theme.colors
local cfg = Theme.config
local Hud = {}
local aimGui: ScreenGui
local gui: ScreenGui
local safe: Frame
local crosshair: Frame
local holdoverTick: Frame
local hitMarker: Frame
local roundLabel: TextLabel
local clockLabel: TextLabel
--- What the clock and range labels currently read, so a per-frame update that
--- would not change anything does not touch the instance at all. setHopper has
--- always done this; these two had not.
local clockText = ""
local rangeText = ""
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
local lastCrosshairPixels = -1

local function centered(label: TextLabel)
	label.TextXAlignment = Enum.TextXAlignment.Center
end

function Hud.build()
	--[[
		Make a rebuild actually rebuild.

		Two things survived it. The previous ScreenGuis stayed parented -- and
		both are ResetOnSpawn = false, so a second build stacked a frozen HUD
		permanently over the live one. And three readouts skip the write when
		the value has not changed, so those caches described widgets that no
		longer existed and left the fresh ones on their placeholder text and
		their 6px ring until the underlying value happened to move.

		build is called once per session today, so neither was reachable. Both
		are two lines, and a check now asserts a rebuild comes back clean.
	]]
	if gui then
		gui:Destroy()
	end
	if aimGui then
		aimGui:Destroy()
	end
	lastHopper, rangeText, lastCrosshairPixels = "", "", -1
	gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn = "LiveRoundHud", false
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	aimGui = Instance.new("ScreenGui")
	aimGui.Name, aimGui.ResetOnSpawn = "LiveRoundAim", false
	aimGui.ScreenInsets = Enum.ScreenInsets.None
	aimGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	safe = Theme.frame(gui, "Readouts", UDim2.fromScale(0.94, 0.94), UDim2.fromScale(0.03, 0.03))
	safe.BackgroundTransparency = 1
	local matchCard = Theme.frame(safe, "MatchCard", UDim2.new(0.64, 0, 0, 108), UDim2.new())
	matchCard.BackgroundTransparency = 0.15
	Theme.round(matchCard); Theme.outline(matchCard)
	local cardLimit = Instance.new("UISizeConstraint")
	cardLimit.MaxSize = Vector2.new(350, 108)
	cardLimit.Parent = matchCard
	roundLabel = Theme.text(matchCard, "Round", "THE LANDING", UDim2.new(1, -24, 0, 22), UDim2.fromOffset(12, 9), cfg.smallTextPixels)
	roundLabel.TextColor3, roundLabel.Font = C.accent, Theme.font("bold")
	--[[
		The Shoothouse clock, right-aligned on the same row as the stage. Blank
		and invisible in every other mode -- a running timer on an untimed match
		would be telling the player something that is not true.
	]]
	clockLabel = Theme.text(matchCard, "Clock", "", UDim2.new(0, 104, 0, 22), UDim2.new(1, -116, 0, 9), cfg.smallTextPixels)
	clockLabel.TextXAlignment = Enum.TextXAlignment.Right
	clockLabel.Font = Theme.font("mono")
	clockLabel.Visible = false
	remainingLabel = Theme.text(matchCard, "Remaining", "Welcome to the field", UDim2.new(1, -24, 0, 28), UDim2.fromOffset(12, 31), 19)
	remainingLabel.Font = Theme.font("bold")
	deathsLabel = Theme.text(matchCard, "Eliminations", "Clean run", UDim2.new(1, -24, 0, 20), UDim2.fromOffset(12, 61), cfg.smallTextPixels)
	phaseLabel = Theme.text(matchCard, "Phase", "", UDim2.new(1, -24, 0, 22), UDim2.fromOffset(12, 81), 11)
	phaseLabel.TextColor3 = C.muted
	currencyLabel = Theme.text(safe, "Currency", "", UDim2.new(0.36, -8, 0, 32), UDim2.new(0.64, 8, 0, 4), cfg.bodyTextPixels)
	currencyLabel.TextXAlignment, currencyLabel.TextColor3 = Enum.TextXAlignment.Right, C.gold
	currencyLabel.TextStrokeTransparency = 0.5
	bannerLabel = Theme.text(safe, "Banner", "", UDim2.new(1, -8, 0, 66), UDim2.new(0, 4, 0.24, 0), cfg.titleTextPixels)
	centered(bannerLabel)
	bannerLabel.Font, bannerLabel.TextColor3 = Theme.font("bold"), C.gold
	bannerLabel.TextStrokeTransparency = 0.4

	crosshair = Theme.frame(aimGui, "SpreadRing", UDim2.fromOffset(6, 6), UDim2.fromScale(0.5, 0.5))
	crosshair.AnchorPoint, crosshair.BackgroundTransparency = Vector2.new(0.5, 0.5), 1
	Theme.round(crosshair, cfg.crosshairMaximumRadiusPixels)
	Theme.outline(crosshair, C.ink)
	local dot = Theme.frame(crosshair, "AimPoint", UDim2.fromOffset(3, 3), UDim2.fromScale(0.5, 0.5))
	dot.AnchorPoint, dot.BackgroundColor3 = Vector2.new(0.5, 0.5), C.ink
	Theme.round(dot)
	holdoverTick = Theme.frame(aimGui, "Holdover", UDim2.fromOffset(14, 2), UDim2.fromScale(0.5, 0.5))
	holdoverTick.AnchorPoint, holdoverTick.BackgroundColor3 = Vector2.new(0.5, 0.5), C.gold
	holdoverTick.Visible = false
	hitMarker = Theme.frame(aimGui, "HitMarker", UDim2.fromOffset(28, 28), UDim2.fromScale(0.5, 0.5))
	hitMarker.AnchorPoint, hitMarker.BackgroundTransparency, hitMarker.Visible = Vector2.new(0.5, 0.5), 1, false
	for _, rotation in ipairs({ 45, -45 }) do
		local line = Theme.frame(hitMarker, "Stroke", UDim2.fromOffset(24, 2), UDim2.fromScale(0.5, 0.5))
		line.AnchorPoint, line.Rotation, line.BackgroundColor3 = Vector2.new(0.5, 0.5), rotation, C.ink
	end
	rangeLabel = Theme.text(aimGui, "Range", "", UDim2.new(1, -32, 0, 24), UDim2.new(0, 16, 0.5, 42), cfg.smallTextPixels)
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
	hopperLabel.Font = Theme.font("bold")
	local track = Theme.frame(hopperCard, "Capacity", UDim2.new(1, -24, 0, 4), UDim2.new(0, 12, 1, -12))
	track.BackgroundColor3 = C.line
	hopperFill = Theme.frame(track, "Fill", UDim2.fromScale(1, 1), UDim2.new())
	hopperFill.BackgroundColor3 = C.accent
	camoLabel = Theme.text(safe, "CamoProgress", "Headshots unlock reactive camos", UDim2.new(0.5, -6, 0, 68), UDim2.new(0.5, 6, 1, -106), cfg.smallTextPixels)
	camoLabel.TextColor3, camoLabel.TextXAlignment = C.gold, Enum.TextXAlignment.Right
	camoLabel.TextStrokeTransparency = 0.5
	chatterLabel = Theme.text(safe, "Chatter", "", UDim2.new(1, -8, 0, 56), UDim2.new(0, 4, 1, -170), cfg.bodyTextPixels)
	chatterLabel.TextColor3, chatterLabel.TextStrokeTransparency = C.ink, 0.35
	controls = Theme.text(safe, "Controls", "", UDim2.new(1, 0, 0, 44), UDim2.new(0, 0, 1, -44), 11)
	controls.TextColor3, controls.TextStrokeTransparency = C.muted, 0.4
	local function resize()
		controls.Text = if game:GetService("UserInputService").PreferredInput == Enum.PreferredInput.Gamepad then "R2 fire · X reload · L3 sprint · B crouch · R1 slide · D-pad lean"
			elseif safe.AbsoluteSize.X < cfg.compactViewportPixels then "R reload  ·  Shift sprint  ·  Ctrl crouch"
			else "WASD move  ·  Mouse fire  ·  R reload  ·  Shift sprint  ·  Ctrl crouch  ·  C slide  ·  Q/E lean"
	end
	safe:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize)
	game:GetService("UserInputService"):GetPropertyChangedSignal("PreferredInput"):Connect(resize)
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
	--[[
		The last per-frame writer that was not cached; setHopper and setRange
		both already are.

		The crosshair is sized in OFFSET, which is whole pixels -- so a spread
		change too small to move it a pixel cannot be seen, and rounding first
		is what makes the comparison meaningful rather than a float that almost
		never repeats. While the player holds an angle and spread has decayed to
		base, this is the same two numbers sixty times a second.
	]]
	local pixels = math.round(radius * 2)
	if pixels == lastCrosshairPixels then
		return
	end
	lastCrosshairPixels = pixels
	crosshair.Size = UDim2.fromOffset(pixels, pixels)
end

function Hud.setRange(distanceMetres: number?, spec: Ballistics.Spec, fieldOfViewDeg: number, viewportHeight: number)
	if not combatVisible or not distanceMetres or distanceMetres <= 0 then
		if rangeText ~= "" then
			rangeText, rangeLabel.Text = "", ""
		end
		holdoverTick.Visible = false
		return
	end
	local drop = Ballistics.dropAt(spec, distanceMetres)
	local flight = Ballistics.timeOfFlight(spec, distanceMetres)
	local offset = math.deg(math.atan2(drop, distanceMetres)) * viewportHeight / fieldOfViewDeg
	-- Extremely distant scenery must not put a teaching tick offscreen.
	holdoverTick.Visible = offset < viewportHeight / 2
	holdoverTick.Position = UDim2.new(0.5, 0, 0.5, offset)
	--[[
		Written only when it differs, the same way setHopper does it. This runs
		every frame, and the readout is rounded to whole metres and whole
		milliseconds -- so while the player holds an angle it is the same string
		sixty times a second, built and assigned each time.
	]]
	local text = string.format("%.0f m  ·  %.2f m drop  ·  %.0f ms flight", distanceMetres, drop, flight * 1000)
	if text ~= rangeText then
		rangeText, rangeLabel.Text = text, text
	end
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
	markerLabel.Text = if remaining == 0 and not reloading then "EMPTY · RELOAD" else currentMarker
end

function Hud.setRound(round: number, roundCount: number, _botCount: number)
	roundLabel.Text = string.format("ROUND %d / %d", round, roundCount)
end

--- A course reads as a place on the field, not as a round number: "STAGE 3/4 ·
--- THEIR HALF" tells the player where they are, "ROUND 6 / 8" does not.
function Hud.setStage(name: string, index: number, count: number)
	roundLabel.Text = string.format("STAGE %d / %d · %s", index, count, string.upper(name))
end

--[[
	The clock, in m:ss.

	Client-side and cosmetic: the server counts the time that decides the medal,
	and this only has to agree with it closely enough to be worth watching. It
	turns amber once the run is past gold and red once it is past silver, so a
	player learns what par feels like without reading a number off a table.
]]
function Hud.setClock(seconds: number?, par: { [string]: number }?, precise: boolean?)
	if seconds == nil then
		clockLabel.Visible = false
		clockText = ""
		return
	end
	clockLabel.Visible = true
	--[[
		Tenths while running, hundredths when the run is over.

		This is called every frame from RenderStepped. At hundredths the last
		digit changes faster than anyone can read it, and formatting it built a
		string per frame for the privilege; at tenths the text changes ten times a
		second and the label is only written when it actually differs. The final
		time still gets its hundredth, because that is the number being judged.
	]]
	local text = if precise
		then string.format("%d:%05.2f", math.floor(seconds / 60), seconds % 60)
		else string.format("%d:%04.1f", math.floor(seconds / 60), seconds % 60)
	if text ~= clockText then
		clockText = text
		clockLabel.Text = text
	end
	-- Gold while the run is still on gold pace, then accent, then warning. The
	-- colour is the medal you are currently earning.
	local colour = C.gold
	if par then
		if seconds > (par.bronze or math.huge) then
			colour = C.muted
		elseif seconds > (par.silver or math.huge) then
			colour = C.warning
		elseif seconds > (par.gold or math.huge) then
			colour = C.accent
		end
	end
	clockLabel.TextColor3 = colour
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
		phaseLabel.Text = "Use counter prompts · talk to the crew"
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
	title.Font, title.TextColor3 = Theme.font("bold"), C.accent
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
	local payout = section("Payout", 0, 9)
	payout.AutomaticSize = Enum.AutomaticSize.Y
	Theme.list(payout, 8)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop, padding.PaddingBottom = UDim.new(0, 10), UDim.new(0, 10)
	padding.PaddingLeft, padding.PaddingRight = UDim.new(0, 12), UDim.new(0, 12)
	padding.Parent = payout
	Theme.text(payout, "Total", Theme.number(breakdown.total or 0) .. " FF EARNED", UDim2.new(1, 0, 0, 0), UDim2.new(), 20).TextColor3 = C.gold
	Theme.text(payout, "Multiplier", string.format("Payout multiplier ×%.2f · progress kept", breakdown.deathPenalty or 1), UDim2.new(1, 0, 0, 0), UDim2.new(), cfg.smallTextPixels)
	for index, name in ipairs({ "Total", "Multiplier" }) do
		local label = payout:FindFirstChild(name) :: TextLabel
		label.AutomaticSize, label.LayoutOrder = Enum.AutomaticSize.Y, index
	end
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
	Navigation.bind(layer, again, nil)
end

return Hud
