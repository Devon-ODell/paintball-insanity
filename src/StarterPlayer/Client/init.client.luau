--!strict
--[[
	Client bootstrap.

	The client renders and predicts. The server decides. Everything below either
	draws something or sends an intent; nothing here reports a result.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local Units = require(ReplicatedStorage.Shared.Units)
local MarkerState = require(ReplicatedStorage.Shared.MarkerState)
local Spread = require(ReplicatedStorage.Shared.Spread)
local Rng = require(ReplicatedStorage.Shared.Rng)
local tracerRng = Rng.new(12345)
local Remotes = require(ReplicatedStorage.Net.Remotes)

local Input = require(script.Input)
local Tracers = require(script.Tracers)
local Hud = require(script.Hud)
local ShopUi = require(script.ShopUi)
local DialogueUi = require(script.DialogueUi)
local Theme = require(script.UiTheme)
local ViewMarker = require(script.ViewMarker)

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
while not camera do
	workspace:GetPropertyChangedSignal("CurrentCamera"):Wait()
	camera = workspace.CurrentCamera
end

local matchData = Config.get("match")
local ballisticsData = Config.get("ballistics")
local playerCfg = matchData.player
local uiCfg = Config.get("ui")

local loadout = { marker = "mechanical", paintColor = "yellow", camo = "factory", markerSkin = "stock" }
local markerData = Config.require("markers", "markers." .. loadout.marker)
local spec = Ballistics.specFromMarker(markerData, ballisticsData)

local markerState = MarkerState.new(markerData)
local phase = "hub"
local respawning = false
local sustainedSpread = 0
local deaths = 0
local remaining = matchData.squadSize
local roundBotCount = matchData.squadSize
local currentRoundIndex, currentRoundCount = 1, 5
--[[
	Shoothouse state.

	The clock is a DISPLAY. The server counts the time that decides the medal --
	it has to, since it also decides what a death costs -- and this only has to
	agree closely enough to be worth watching. It runs while a stage is live and
	stops the moment the summary lands.
]]
local courseMode = false
local courseStageIndex: number? = nil
local courseElapsed = 0
local coursePar: { [string]: number }? = nil
local phaseRevision = 0
local readoutElapsed = uiCfg.hudReadoutIntervalSeconds

--[[
	Every panel sizes its text against the viewport, so the scale has to be
	bound before anything is built and re-applied when the window changes --
	which includes a phone rotating.
]]
Theme.bindViewport()

Hud.build()
Input.bind()
Tracers.bind()
ViewMarker.equip(loadout.marker)
Hud.setMarker(loadout.marker)
Hud.setPhase(phase)

local function syncPointer()
	Input.setPointerFree(ShopUi.isOpen() or DialogueUi.isOpen() or Hud.isSummaryOpen())
end

DialogueUi.setOnClose(syncPointer)

--------------------------------------------------------------------------------
-- First person
--------------------------------------------------------------------------------

player.CameraMode = Enum.CameraMode.LockFirstPerson
camera.FieldOfView = playerCfg.fieldOfViewDeg

--------------------------------------------------------------------------------
-- Spread, predicted locally so the crosshair is honest about the server's rules
--------------------------------------------------------------------------------

local function currentSpread(): number
	return Spread.angle(markerData, sustainedSpread, Input.stance(), Input.sprintRecovery(os.clock()))
end

--------------------------------------------------------------------------------
-- Range readout for the holdover ladder
--------------------------------------------------------------------------------

local rangeParams = RaycastParams.new()
rangeParams.FilterType = Enum.RaycastFilterType.Exclude
rangeParams.IgnoreWater = true

local function lookedAtRange(): number?
	local character = player.Character
	if character then
		rangeParams.FilterDescendantsInstances = { character, camera }
	end
	local result = workspace:Raycast(camera.CFrame.Position, camera.CFrame.LookVector * uiCfg.rangeRayStuds, rangeParams)
	if not result then
		return nil
	end
	return Units.studsToMetres((result.Position - camera.CFrame.Position).Magnitude)
end

--------------------------------------------------------------------------------
-- Firing
--------------------------------------------------------------------------------

local function muzzleMetres(): Vector3
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return Units.vectorToMetres(camera.CFrame.Position)
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local feet = (root :: BasePart).Position - Vector3.new(0, (root :: BasePart).Size.Y / 2 + (if humanoid then humanoid.HipHeight else 1.5), 0)
	return Units.vectorToMetres(feet) + Vector3.new(0, ballisticsData.hitbox.chestHeightMetres, 0)
end

local function requestReload()
	if phase == "live" and not respawning and markerState:reload(os.clock()) then
		Remotes.event("RequestReload"):FireServer()
	end
end

local function tryFire()
	if phase ~= "live" or respawning or Input.isPointerFree() then
		return
	end
	local now = os.clock()
	markerState:update(now)
	if markerState.ammo <= 0 then
		requestReload()
		return
	end
	if not markerState:fire(now) then
		return
	end
	ViewMarker.fire()

	local origin = muzzleMetres()
	local direction = camera.CFrame.LookVector

	--[[
		The local tracer flies immediately for feel. The server runs its own
		authoritative flight from its own view of where the player is; if the two
		disagree, the server wins and this tracer was simply wrong. Spread is sampled independently for this immediate cosmetic tracer.
		Only the server result determines a hit.
	]]
	Tracers.fire(origin, Spread.sample(direction, currentSpread(), tracerRng), spec)

	Remotes.event("FireMarker"):FireServer({
		origin = Units.vectorToStuds(origin),
		direction = direction,
		clientTime = now,
		stance = Input.stance(),
	})

	sustainedSpread = math.min(
		markerData.sustainedSpreadDeg,
		sustainedSpread + markerData.spreadGrowthPerShotDeg
	)
end

--------------------------------------------------------------------------------
-- Server results
--------------------------------------------------------------------------------

Remotes.event("MarkerFired").OnClientEvent:Connect(function(payload)
	Tracers.fire(payload.origin, payload.direction, payload.spec)
end)

Remotes.event("ShotResolved").OnClientEvent:Connect(function(result)
	if result.hit then
		Hud.flashHit(result.headshot == true)
		if result.headshot then
			if result.camoProgress then
				Hud.setCamoProgress(result.camoProgress)
				ViewMarker.setCamo(result.camoProgress.equippedCamo)
			end
			ViewMarker.reactHeadshot()
		end
	end
	if result.impact then
		Tracers.resolve(result.impact)
	end
end)

Remotes.event("BotEliminated").OnClientEvent:Connect(function(payload)
	remaining = payload.remaining
	Hud.setRemaining(remaining, roundBotCount)
end)

Remotes.event("PlayerEliminated").OnClientEvent:Connect(function(payload)
	respawning = true
	deaths = payload.deaths
	-- Mirror of the server's curve, for display only. The server computes the
	-- real payout and this number never leaves the client.
	local cfg = Config.require("economy", "deathPenalty")
	local multiplier = cfg.floor + (1 - cfg.floor) * math.exp(-cfg.decay * deaths)
	Hud.setDeaths(deaths, multiplier)
end)

Remotes.event("ChatterLine").OnClientEvent:Connect(function(line)
	Hud.showChatter(line)
end)

Remotes.event("MatchSummary").OnClientEvent:Connect(function(payload)
	Input.setPointerFree(true)
	--[[
		The run is over, so the clock stops and is replaced by the server's own
		figure -- which includes the ten seconds a death that the display clock
		deliberately never showed, because charging it live would make the timer
		jump backwards out from under the player.
	]]
	courseMode = false
	if payload.course then
		local run = payload.course
		-- The run is over, so this one gets its hundredth: it is the number the
		-- medal was decided on.
		Hud.setClock(run.seconds, coursePar, true)
		--[[
			A time on its own says nothing. What a player wants at the end of a
			timed run is the medal and whether they beat themselves, so the banner
			carries the record it just broke -- or the one it did not.
		]]
		local headline = if run.medal then string.upper(run.medal) else "NO MEDAL"
		local against = if run.isRecord
			then (if run.previousBest then string.format("  ·  BEST, was %.1fs", run.previousBest) else "  ·  FIRST CLEAR")
			elseif run.previousBest then string.format("  ·  best %.1fs", run.previousBest)
			else ""
		Hud.showBanner(string.format("%s  ·  %.1fs%s", headline, run.seconds, against), 6)
	else
		Hud.setClock(nil, nil)
	end
	Hud.showSummary(payload.summary, payload.breakdown, function()
		return Remotes.fn("RequestMatchStart"):InvokeServer({
			map = payload.summary.map,
			tier = payload.summary.tier,
		})
	end, function()
		return Remotes.fn("RequestShopVisit"):InvokeServer()
	end)
end)

Remotes.event("CurrencyChanged").OnClientEvent:Connect(Hud.setCurrency)
Remotes.event("ShopOpened").OnClientEvent:Connect(function(snapshot)
	if not snapshot or not snapshot.ok then return end
	DialogueUi.close()
	ShopUi.open(snapshot, syncPointer)
	syncPointer()
end)

local function applyLoadout(newLoadout: any)
	local markerChanged = loadout.marker ~= newLoadout.marker
	loadout = newLoadout
	ViewMarker.equip(loadout.marker, loadout.camo)
	ViewMarker.setSkin(loadout.markerSkin)
	Hud.setMarker(loadout.marker)
	markerData = Config.require("markers", "markers." .. loadout.marker)
	spec = Ballistics.specFromMarker(markerData, ballisticsData)
	-- Earning an auto-equipped camo mid-round must not refill the local hopper.
	if markerChanged then markerState = MarkerState.new(markerData) end
	local palette = Config.get("venue").paintColors
	local rgb = palette[loadout.paintColor] or palette.yellow
	Tracers.setPaintColour(Color3.fromRGB(rgb[1], rgb[2], rgb[3]))
end

Remotes.event("LoadoutChanged").OnClientEvent:Connect(applyLoadout)

Remotes.event("MatchStateChanged").OnClientEvent:Connect(function(payload)
	local previousPhase = phase
	phaseRevision += 1
	phase = payload.phase
	Hud.setPhase(phase)
	if phase == "warmup" or phase == "shop" or phase == "hub" then
		ShopUi.close()
		Hud.hideSummary()
		DialogueUi.close()
		syncPointer()
	end
	if phase == "live" then
		ShopUi.close()
		DialogueUi.close()
		syncPointer()
	end
	if phase == "warmup" then
		respawning = false
		sustainedSpread = 0
		deaths = 0
		courseMode = payload.mode == "shoothouse"
		courseStageIndex, courseElapsed = nil, 0
		coursePar = payload.par
		Hud.setClock(if courseMode then 0 else nil, coursePar)
		roundBotCount = payload.botCount or roundBotCount
		remaining = roundBotCount
		currentRoundIndex, currentRoundCount = payload.round or 1, payload.roundCount or currentRoundCount
		markerState = MarkerState.new(markerData)
		Hud.setDeaths(0, 1)
		Hud.setRemaining(remaining, roundBotCount)
	elseif phase == "live" and (payload.round or previousPhase == "warmup") then
		--[[
			A new round of five. The enemy team is bigger than last round and the
			hopper is full again; deaths are NOT reset, because they accumulate
			across the whole match and are charged against it once at the end.
		]]
		respawning = false
		sustainedSpread = 0
		roundBotCount = payload.botCount or roundBotCount
		remaining = roundBotCount
		currentRoundIndex, currentRoundCount = payload.round or currentRoundIndex, payload.roundCount or currentRoundCount
		markerState = MarkerState.new(markerData)
		--[[
			A course reports where you are on the field, not which round you are
			on. Stage four of a Shoothouse is "THE BACK CORNERS", and the run-up
			to it is the only thing the player is actually thinking about.
		]]
		if payload.mode == "shoothouse" and payload.stage then
			courseMode = true
			coursePar = payload.par or coursePar
			if payload.stageIndex ~= courseStageIndex then
				courseStageIndex = payload.stageIndex
				Hud.showBanner(string.upper(payload.stage), 2)
			end
			Hud.setStage(payload.stage, payload.stageIndex or 1, payload.stageCount or 1)
		else
			Hud.setRound(currentRoundIndex, currentRoundCount, roundBotCount)
			Hud.showBanner(string.format("ROUND %d", currentRoundIndex), 2)
		end
		Hud.setRemaining(remaining, roundBotCount)
	elseif phase == "intermission" then
		-- The course clock never stops, so it has no intermission to announce.
		if not courseMode then
			Hud.showBanner(
				string.format("ROUND %d CLEAR  ·  %d INCOMING", payload.round, payload.nextBotCount or 0),
				payload.seconds or 5
			)
		end
	end
end)

--------------------------------------------------------------------------------
-- Latency reporting, so the server can lag-compensate
--------------------------------------------------------------------------------

task.spawn(function()
	while true do
		task.wait(uiCfg.latencyReportSeconds)
		local ping = player:GetNetworkPing()
		Remotes.event("ReportLatency"):FireServer(ping)
	end
end)

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------

player.CharacterAdded:Connect(function()
	respawning = false
end)

RunService.RenderStepped:Connect(function(dt)
	local activeCamera = workspace.CurrentCamera
	if activeCamera and activeCamera ~= camera then
		camera = activeCamera
		camera.FieldOfView = playerCfg.fieldOfViewDeg
	end
	Input.tick(dt)
	-- The Shoothouse clock advances only while a stage is actually live, which
	-- is what "the clock does not stop between stages" means in practice: there
	-- is no intermission for it to stop for.
	if courseMode and phase == "live" then
		courseElapsed += dt
		Hud.setClock(courseElapsed, coursePar)
	end
	ViewMarker.step(camera, phase == "live" or phase == "warmup")
	markerState:update(os.clock())
	sustainedSpread = math.max(0, sustainedSpread - markerData.spreadDecayPerSecondDeg * dt)

	if Input.state().firing then
		if markerData.autoFire then
			tryFire()
		end
	end
	if Input.consumeReload() then
		requestReload()
	end

	local viewport = camera.ViewportSize.Y
	Hud.setSpread(currentSpread(), camera.FieldOfView, viewport)
	-- Range physics and formatted readouts do not need to run at frame rate.
	-- Aim, marker motion and spread remain smooth on RenderStepped.
	readoutElapsed += dt
	if readoutElapsed >= uiCfg.hudReadoutIntervalSeconds then
		readoutElapsed = 0
		Hud.setRange(if phase == "live" or phase == "warmup" then lookedAtRange() else nil, spec, camera.FieldOfView, viewport)
	end
	Hud.setHopper(markerState.ammo, markerData.hopperCapacity, markerState.reloadUntil ~= nil)
end)

-- Pump markers fire once per click; they do not repeat while held.
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2) and not markerData.autoFire then
		tryFire()
	end
end)

--------------------------------------------------------------------------------
-- Conversations
--------------------------------------------------------------------------------

--[[
	The server owns the dialogue tree, the gating and every action. The client
	draws a node and reports which option was picked, so no amount of client
	tampering can talk its way into an unlocked chapter.
]]
Remotes.event("DialogueOpened").OnClientEvent:Connect(function(node)
	if not node then
		DialogueUi.close()
		syncPointer()
		return
	end
	DialogueUi.show(node, function(index)
		Remotes.event("DialogueChoice"):FireServer(index)
	end)
	syncPointer()
end)

Remotes.event("CampaignUpdated").OnClientEvent:Connect(function(card)
	if card and card.title then
		Hud.showBanner(card.title, 3)
	end
end)

-- Load after listeners exist, so join-time events cannot strand the HUD on a
-- default loadout. Arrive in the hub; field gates deliberately start matches.
task.spawn(function()
	local requestedRevision = phaseRevision
	local ok, result = pcall(function()
		return Remotes.fn("RequestSessionState"):InvokeServer()
	end)
	if not ok or not result or not result.ok then
		Input.setPointerFree(true)
		Hud.showChatter({ speaker = "Field", text = "Could not load your kit. Rejoin the field to try again." })
		warn("LiveRound session loading failed", result)
		return
	end
	if result.loadout then applyLoadout(result.loadout) end
	if result.balance then Hud.setCurrency(result.balance) end
	if result.camoProgress then Hud.setCamoProgress(result.camoProgress) end
	if phaseRevision == requestedRevision then
		phase = result.phase or "hub"
		Hud.setPhase(phase)
	end
	syncPointer()
end)
