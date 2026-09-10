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
local Loadout = require(ReplicatedStorage.Shared.Loadout)
local MarkerState = require(ReplicatedStorage.Shared.MarkerState)
local Spread = require(ReplicatedStorage.Shared.Spread)
local Melee = require(ReplicatedStorage.Shared.Melee)
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
local Audio = require(script.Audio)
local Music = require(script.Music)
local AudioMix = require(script.AudioMix)
local FoliageWind = require(script.FoliageWind)

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

--[[
	The resolved kit: reload time, pod budget and movement speeds.

	Neutral until the server sends one, which is what every caller had before
	gear reached anything. `GearStats.resolve` was written, priced, advertised in
	the shop and had no production caller at all.
]]
local kit = Loadout.neutral(markerData)
local markerState = MarkerState.new(markerData, kit)
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
FoliageWind.start()
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
	if phase ~= "live" or respawning then
		return
	end
	if markerState:reload(os.clock()) then
		Audio.play("reloadStart")
		Remotes.event("RequestReload"):FireServer()
	elseif markerState:isDry() then
		--- Out of paint for this round. Reloads are finite now, so "nothing
		--- happened" needs to be a sentence rather than a dead key.
		Audio.play("dryFire")
		Hud.showBanner("OUT OF PAINT · FINISH THE ROUND", 2)
	end
end

--[[
	The shove.

	Local cooldown is presentation only -- it stops the animation restarting on
	a mashed key. The rule is enforced on the server, which decides from its own
	view of the field whether anything was in reach, so nothing here can be sped
	up by editing this file.
]]
local swingReadyAt = -math.huge

local function trySwing()
	if phase ~= "live" or respawning or Input.isPointerFree() then
		return
	end
	local now = os.clock()
	if now < swingReadyAt then
		return
	end
	swingReadyAt = now + Melee.rules().cooldownSeconds
	ViewMarker.swing()
	Audio.play("swing")
	Remotes.event("SwingMarker"):FireServer({
		direction = camera.CFrame.LookVector,
		clientTime = now,
	})
end

local function tryFire()
	if phase ~= "live" or respawning or Input.isPointerFree() then
		return
	end
	-- You cannot pull the trigger with the marker turned sideways.
	if ViewMarker.isSwinging() then
		return
	end
	local now = os.clock()
	markerState:update(now)
	if markerState.ammo <= 0 then
		Audio.play("dryFire")
		requestReload()
		return
	end
	if not markerState:fire(now) then
		return
	end
	ViewMarker.fire()
	Audio.play("fire")

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

--[[
	One remote, two meanings, and only one of them is a tracer to draw.

	MatchService fires this for the SQUAD's shots, which the client has never
	seen and must render. The Range fires it for the player's OWN accepted shot,
	which `tryFire` already drew a predicted tracer for -- drawing it again would
	put two balls in the air for one trigger pull. So a self event is an
	acknowledgement: it reconciles the predicted hopper against the count the
	server actually charged, and draws nothing.

	It also carries no `spec`, which is what used to make this handler throw on
	every accepted Range shot -- `Tracers.fire` indexes `spec.muzzleVelocity`.
	Rendering is gated on the spec being present rather than on the source
	string, so a future sender that forgets one cannot resurrect the crash.
]]
Remotes.event("MarkerFired").OnClientEvent:Connect(function(payload)
	if payload.source == "self" then
		if type(payload.ammo) == "number" then
			markerState.ammo = math.clamp(payload.ammo, 0, markerState.capacity)
		end
		return
	end
	if payload.spec then
		Tracers.fire(payload.origin, payload.direction, payload.spec)
	end
	--[[
		The squad, made audible.

		This payload has carried the origin of every enemy shot since the
		tracers were built; it just was not being listened to. A squad you
		cannot hear is a squad you can only find by looking, and "which
		direction did that come from" is the question this whole game is built
		around asking.
	]]
	if payload.source == "squad" then
		Audio.playAt("enemyFire", payload.origin)
	end
end)

Remotes.event("ShotResolved").OnClientEvent:Connect(function(result)
	if result.hit then
		Hud.flashHit(result.headshot == true)
		Audio.play(if result.headshot == true then "headshot" else "hit")
		-- The confirmation is in your ears; the paint landed over there.
		if result.impact then
			Audio.playAt("paintImpact", Units.vectorToMetres(result.impact))
		end
		if result.headshot then
			if result.camoProgress then
				Hud.setCamoProgress(result.camoProgress)
				ViewMarker.setCamo(result.camoProgress.equippedCamo)
			end
			ViewMarker.reactHeadshot()
		end
	end
	if result.impact and phase == "live" and not respawning then
		Tracers.resolve(result.impact)
	end
end)

local flagSnapshot: any = nil

local function applyFlags(snapshot: any)
	if not flagSnapshot or snapshot.sprintMultiplier ~= flagSnapshot.sprintMultiplier then Input.setCarrierMultiplier(snapshot.sprintMultiplier) end
	flagSnapshot = snapshot
	Hud.setFlags(snapshot)
	for _, event in ipairs(snapshot.events or {}) do
		if event.kind == "captured" then
			Hud.showBanner(if event.actor == "player" then "FLAG CAPTURED!" else "SQUAD CAPTURE", 2)
		elseif event.kind == "flagTaken" then
			Hud.showBanner(if event.flag == "enemy" then "YOU HAVE THEIR FLAG" else "YOUR FLAG IS TAKEN", 2)
		elseif (event.kind == "flagRecovered" or event.kind == "flagReturned") and event.flag == "player" then
			Hud.showBanner("YOUR FLAG IS HOME", 2)
		end
	end
end

Remotes.event("BotEliminated").OnClientEvent:Connect(function(payload)
	remaining = payload.remaining
	if not flagSnapshot then Hud.setRemaining(remaining, roundBotCount) end
	--[[
		A shove gets its hit marker here rather than from ShotResolved, because
		it never fires a shot to resolve. Without this the one attack that
		happens at arm's length was the only one with no confirmation on screen
		-- the counter simply dropped and the player had to infer it.
	]]
	if payload.at then
		Audio.playAt("botEliminated", payload.at)
	else
		Audio.play("botEliminated")
	end
	if payload.melee == true then
		Hud.flashHit(false)
	end
end)

Remotes.event("PlayerEliminated").OnClientEvent:Connect(function(payload)
	respawning = true
	Tracers.clear()
	Audio.play("playerEliminated")
	-- The one moment the player most needs to hear what happened.
	Music.duck()
	deaths = payload.deaths
	-- Mirror of the server's curve, for display only. The server computes the
	-- real payout and this number never leaves the client.
	local cfg = Config.require("economy", "deathPenalty")
	local multiplier = cfg.floor + (1 - cfg.floor) * math.exp(-cfg.decay * deaths)
	Hud.setDeaths(deaths, multiplier)
end)

Remotes.event("ChatterLine").OnClientEvent:Connect(function(line)
	Hud.showChatter(line)
	-- A voice with a direction. Lines from a bot the server could not place --
	-- a squad-wide announcement, or a speaker already out -- stay silent rather
	-- than being flattened into the middle of the player's head.
	if line.at then
		Audio.playAt("chatter", line.at)
	end
end)

Remotes.event("MatchSummary").OnClientEvent:Connect(function(payload)
	Tracers.clear()
	flagSnapshot = nil
	Input.setCarrierMultiplier(1)
	--[[
		Clear the match's voices FIRST, then start the results cue.

		These were the other way round, and `Audio.clear` destroys the folder
		every voice is parented to and empties the pools -- including the
		`matchCleared` sound started two lines above it. The one cue that says
		you won was silenced by the cleanup on the same frame it began, every
		single time. Nothing errored and no sound id was wrong, so a validity
		check could never have found it.

		Voices are pooled under SoundService, which outlives the match; a run
		that ends is the natural place to hand them back.
	]]
	Audio.clear()
	if payload.summary and payload.summary.cleared then
		Audio.play("matchCleared")
	end
	Music.setContext(Config.get("audio").music.context.results)
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
			mode = payload.mode or payload.summary.mode,
		})
	end, function()
		return Remotes.fn("RequestShopVisit"):InvokeServer()
	end)
end)

--[[
	The drill result, which nothing used to listen to.

	`DrillScore` has been sent since the Range went live and had no consumer at
	all, so a minute of measured practice produced a one-line banner with a hit
	count. The rating is the number that matters: it is on the same curve the
	match report uses, which is what makes a drill score and a match score the
	same kind of claim.

	`Run it again` re-enters the same drill rather than returning to the hub and
	walking back to the gate, because the reason to read this panel is to decide
	whether to repeat it.
]]
Remotes.event("DrillScore").OnClientEvent:Connect(function(result)
	if type(result) ~= "table" then return end
	Hud.showDrillResult(result, function()
		return Remotes.fn("RequestRangeDrill"):InvokeServer(result.drill)
	end, nil)
end)

--- The Range gate offers all five drills instead of starting the first one.
Remotes.event("DrillCatalogue").OnClientEvent:Connect(function(catalogue)
	if type(catalogue) ~= "table" then return end
	Hud.showDrillPicker(catalogue, function(drillId)
		return Remotes.fn("RequestRangeDrill"):InvokeServer(drillId)
	end, nil)
	syncPointer()
end)

--- Peek announces its bearing before the reveal; the drill grades whether the
--- crosshair was already there.
Remotes.event("DrillCue").OnClientEvent:Connect(function(cue)
	if type(cue) ~= "table" then return end
	Hud.showDrillCue(cue.bearingDeg, cue.distanceMetres)
end)

Remotes.event("CurrencyChanged").OnClientEvent:Connect(Hud.setCurrency)
Remotes.event("Notice").OnClientEvent:Connect(function(payload)
	if type(payload) == "table" and type(payload.text) == "string" then
		Hud.showBanner(payload.text, payload.seconds)
	end
end)
Remotes.event("ShopOpened").OnClientEvent:Connect(function(snapshot)
	if not snapshot or not snapshot.ok then return end
	DialogueUi.close()
	ShopUi.open(snapshot, syncPointer)
	syncPointer()
end)

local function applyLoadout(newLoadout: any, resolvedKit: any)
	local markerChanged = loadout.marker ~= newLoadout.marker
	loadout = newLoadout
	ViewMarker.equip(loadout.marker, loadout.camo)
	ViewMarker.setSkin(loadout.markerSkin)
	Hud.setMarker(loadout.marker)
	markerData = Config.require("markers", "markers." .. loadout.marker)
	spec = Ballistics.specFromMarker(markerData, ballisticsData)
	--[[
		What the kit does, resolved by the SERVER and applied here.

		Resolved server-side rather than recomputed from the loadout, so the
		client predicts against the same numbers the authority will validate --
		and so there is one place to audit against the monetization rule rather
		than two implementations that can drift.
	]]
	if resolvedKit then
		kit = resolvedKit
		Input.setSpeeds(kit)
	end
	-- Earning an auto-equipped camo mid-round must not refill the local hopper.
	if markerChanged or phase ~= "live" then markerState = MarkerState.new(markerData, kit) end
	local palette = Config.get("venue").paintColors
	local rgb = palette[loadout.paintColor] or palette.yellow
	Tracers.setPaintColour(Color3.fromRGB(rgb[1], rgb[2], rgb[3]))
end

Remotes.event("LoadoutChanged").OnClientEvent:Connect(applyLoadout)

Remotes.event("MatchStateChanged").OnClientEvent:Connect(function(payload)
	-- Range entry transports its loadout and unlimited-refill snapshot together.
	if payload.loadout and payload.kit then applyLoadout(payload.loadout, payload.kit) end
	if payload.ctf and payload.phase == phase and not payload.mode and not payload.round then
		applyFlags(payload.ctf)
		return
	end
	local previousPhase = phase
	phaseRevision += 1
	phase = payload.phase
	if phase ~= previousPhase then Tracers.clear() end
	Hud.setPhase(phase)
	if phase == "hub" or phase == "shop" or phase == "summary" or phase == "done" or (phase == "warmup" and previousPhase ~= "warmup") then
		flagSnapshot = nil
		Input.setCarrierMultiplier(1)
	end

	--[[
		The server's own words to the player.

		Five places send a `notice` -- a drill's name as it starts, its score as
		it ends, a refused drill, a Horde gate that is not open yet -- and the
		client read none of them, so every one was sent and dropped. The Range in
		particular finished a run and told the player nothing at all.

		Shown before the phase branches below, because a notice that arrives with
		a phase change is about the change.
	]]
	if type(payload.notice) == "string" and payload.notice ~= "" then
		Hud.showBanner(payload.notice, payload.noticeSeconds)
	end
	--[[
		The track follows the phase, through the mapping in audio.json rather
		than a branch here -- "the hub and the shop share a track" is a tuning
		decision, and check-audio can only verify it if it lives in the data.
		setContext is idempotent, so re-announcing a phase every round is free;
		restarting the music once a round would be a stutter nobody asked for.
	]]
	Music.setContext(Config.get("audio").music.context[phase])
	if phase == "warmup" or phase == "shop" or phase == "hub" then
		ShopUi.close()
		--[[
			The results panel survives the walk home.

			Bootstrap physically returns the player to The Landing 2.5 s after
			the summary arrives, and entering `hub` used to destroy the panel
			unconditionally -- so the six fundamental scores, the diagnosis, the
			payout breakdown and the replay buttons vanished two and a half
			seconds after appearing, without anybody dismissing them. That panel
			IS the teaching loop; the match exists to produce it.

			Joining the server and walking out of the barn still clear it, which
			is right. Only the post-match return asks to keep it.
		]]
		if not payload.keepResults then
			Hud.hideSummary()
		end
		DialogueUi.close()
		syncPointer()
	end
	if phase == "live" then
		ShopUi.close()
		DialogueUi.close()
		syncPointer()
		if previousPhase ~= "live" then
			Audio.play("roundStart")
		end
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
		markerState = MarkerState.new(markerData, kit)
		Hud.setDeaths(0, 1)
		if not flagSnapshot then Hud.setRemaining(remaining, roundBotCount) end
	elseif phase == "live" and payload.mode == "range" then
		--[[
			Entering a drill. The Range has no warmup and no round, so this is
			the only place its local state gets cleared; without it a drill
			inherited the hopper, spread and out count of whatever ran before.
		]]
		respawning = false
		sustainedSpread = 0
		deaths = 0
		courseMode = false
		courseStageIndex, courseElapsed = nil, 0
		coursePar = nil
		flagSnapshot = nil
		markerState = MarkerState.new(markerData, kit)
		Hud.setClock(nil)
		Hud.setDrill(payload.drillName or "Drill", payload.fundamental)
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
		markerState = MarkerState.new(markerData, kit)
		--[[
			A course reports where you are on the field, not which round you are
			on. Stage four of a Shoothouse is "THE BACK CORNERS", and the run-up
			to it is the only thing the player is actually thinking about.
		]]
		if flagSnapshot or payload.ctf then
			Hud.showBanner("CAPTURE THE FLAG", 2)
		elseif payload.mode == "horde" then
			--- A depth, not a fraction whose denominator grows to meet its
			--- numerator every wave.
			Hud.setWave(currentRoundIndex, roundBotCount, payload.isBoss, payload.isBreather)
			Hud.showBanner(
				if payload.isBoss then string.format("WAVE %d  ·  FIELD MARSHAL", currentRoundIndex)
				else string.format("WAVE %d", currentRoundIndex), 2
			)
		elseif payload.mode == "shoothouse" and payload.stage then
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
		if not flagSnapshot then Hud.setRemaining(remaining, roundBotCount) end
	elseif phase == "intermission" then
		-- The course clock never stops, so it has no intermission to announce.
		if not courseMode then
			Hud.showBanner(
				string.format("ROUND %d CLEAR  ·  %d INCOMING", payload.round, payload.nextBotCount or 0),
				payload.seconds or 5
			)
		end
	end
	if payload.ctf then applyFlags(payload.ctf)
	elseif flagSnapshot and (phase == "warmup" or phase == "live") then Hud.setFlags(flagSnapshot) end
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
-- Aim reporting, so crosshair placement can be measured rather than inferred
--------------------------------------------------------------------------------

--[[
	Where the crosshair is, streamed while there is something to aim at.

	Crosshair placement is the one fundamental the shot cannot reveal: it asks
	where the player was ALREADY looking at the instant the target appeared,
	which is a moment nobody pulled a trigger at. The server used to answer it
	with the direction of the previous shot -- so on Peek, whose three known
	angles are sixty degrees apart, a player parked perfectly on the reveal
	angle read as sixty degrees off, and the coach prescribed a drill for a
	weakness they did not have.

	Only while `live` or `warmup`: outside a field or the firing line there is
	no measurement to feed, and a hub that streams aim is a wire that costs
	something for nothing.
]]
task.spawn(function()
	while true do
		task.wait(uiCfg.aimReportSeconds)
		if (phase == "live" or phase == "warmup") and not respawning then
			Remotes.event("ReportAim"):FireServer(camera.CFrame.LookVector)
		end
	end
end)

--------------------------------------------------------------------------------
-- Stance, so the server's muzzle and cone match what the player can see
--------------------------------------------------------------------------------

--[[
	Crouch and lean, sent when they CHANGE.

	Crouch used to ride on the fire request, which made it something a client
	could assert one shot at a time -- claim a crouch while standing still and
	collect the tighter cone without ever crouching. Lean was never sent at all,
	so the camera moved half a metre around a corner while the authoritative
	muzzle stayed in the middle of the body: the player saw a clear shot and the
	ball hit the wall.

	On change rather than on a timer, because a stance is something you are IN,
	and a player crouched behind cover for a minute should not be spending a
	packet a frame to say so.
]]
task.spawn(function()
	local lastCrouch, lastLean = false, 0
	while true do
		task.wait(uiCfg.aimReportSeconds)
		local inputState = Input.state()
		local crouching = inputState.crouching == true or inputState.sliding == true
		local lean = inputState.lean or 0
		if crouching ~= lastCrouch or lean ~= lastLean then
			lastCrouch, lastLean = crouching, lean
			Remotes.event("ReportStance"):FireServer(crouching, lean)
		end
	end
end)

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------

player.CharacterAdded:Connect(function()
	respawning = false
end)

-- CameraOffset is consumed by Roblox's camera; marker/HUD placement consumes
-- the resulting camera. Explicit priorities prevent a one-frame lag/jitter.
RunService:BindToRenderStep("LR_Input", Enum.RenderPriority.Camera.Value - 1, Input.tick)
RunService:BindToRenderStep("LR_Presentation", Enum.RenderPriority.Camera.Value + 1, function(dt)
	local activeCamera = workspace.CurrentCamera
	if activeCamera and activeCamera ~= camera then
		camera = activeCamera
		camera.FieldOfView = playerCfg.fieldOfViewDeg
	end
	-- The Shoothouse clock advances only while a stage is actually live, which
	-- is what "the clock does not stop between stages" means in practice: there
	-- is no intermission for it to stop for.
	if courseMode and phase == "live" then
		courseElapsed += dt
		Hud.setClock(courseElapsed, coursePar)
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local velocity = if root and root:IsA("BasePart") then root.AssemblyLinearVelocity else Vector3.zero
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	--- The ear rides the camera, so 3D audio is heard from where the player is
	--- looking. Roblox replaces the camera on respawn; this is what stops the
	--- game quietly losing its hearing after the first death.
	AudioMix.follow(camera)
	Music.step(dt)
	local wasReloading = markerState.reloadUntil ~= nil
	ViewMarker.step(camera, not respawning and (phase == "live" or phase == "warmup"), dt,
		Input.state(), speed, markerState.reloadUntil, markerState.reloadSeconds)
	markerState:update(os.clock())
	-- The pod comes off the hopper. Read from the state machine rather than a
	-- timer of its own, so the sound cannot drift from the animation.
	if wasReloading and markerState.reloadUntil == nil then
		Audio.play("reloadEnd")
	end
	sustainedSpread = math.max(0, sustainedSpread - markerData.spreadDecayPerSecondDeg * dt)

	if Input.state().firing then
		if markerData.autoFire then
			tryFire()
		end
	end
	if Input.consumeReload() then
		requestReload()
	end
	if Input.consumeSwing() then
		trySwing()
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
	--- The kit's capacity, not the bare marker's: a force-fed hopper carries more.
	Hud.setHopper(markerState.ammo, markerState.capacity, markerState.reloadUntil ~= nil, markerState.pods)
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
	if result.loadout and phaseRevision == requestedRevision then applyLoadout(result.loadout, result.kit) end
	if result.balance then Hud.setCurrency(result.balance) end
	if result.camoProgress then Hud.setCamoProgress(result.camoProgress) end
	if phaseRevision == requestedRevision then
		phase = result.phase or "hub"
		Hud.setPhase(phase)
	if phase == "hub" or phase == "shop" or phase == "summary" or phase == "done" or (phase == "warmup" and previousPhase ~= "warmup") then
		flagSnapshot = nil
		Input.setCarrierMultiplier(1)
	end
	end
	syncPointer()
end)
