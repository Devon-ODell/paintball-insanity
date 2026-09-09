--!strict
--[[
	MatchService -- the live binding of everything the sim already runs headless.

	This is the only file that knows a match involves a real Roblox player. It
	builds the map, spawns six BotControllers with visible avatars, steps them on
	Heartbeat, resolves the authoritative projectile simulation, records
	telemetry, and pays out at the end.

	The important property is that the DECISIONS are not made here. Bot
	behaviour, ballistics, hit resolution, telemetry and payout all live in
	modules the headless harness exercises. This file is plumbing, and it is
	deliberately thin, because it is the one part of the project that cannot be
	verified without Studio.

	Server-authoritative throughout: the client sends "I pulled the trigger and I
	think my muzzle was here", and the server decides everything after that.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)
local GearStats = require(ReplicatedStorage.Shared.GearStats)
local Units = require(ReplicatedStorage.Shared.Units)
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local MapGeometry = require(ReplicatedStorage.Shared.MapGeometry)
local Rng = require(ReplicatedStorage.Shared.Rng)
local MarkerState = require(ReplicatedStorage.Shared.MarkerState)
local Melee = require(ReplicatedStorage.Shared.Melee)
local Dev = require(ReplicatedStorage.Shared.Dev)
local Spread = require(ReplicatedStorage.Shared.Spread)
local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Net.Remotes)

local Server = script.Parent.Parent
local ProjectileSim = require(Server.Ballistics.ProjectileSim)
local LagCompensation = require(Server.Ballistics.LagCompensation)
local BotController = require(Server.Bots.BotController)
local SquadCoordinator = require(Server.Bots.SquadCoordinator)
local Chatter = require(Server.Bots.Chatter)
local Course = require(Server.Match.Course)
local CourseProgress = require(Server.Progression.CourseProgress)
local ShotLog = require(Server.Telemetry.ShotLog)
local ShotMeasure = require(Server.Telemetry.ShotMeasure)
local Prescription = require(Server.Telemetry.Prescription)
local Payout = require(Server.Economy.Payout)
local Profile = require(Server.Economy.Profile)
local SeasonPass = require(Server.Progression.SeasonPass)
local WorldBuilder = require(script.Parent.WorldBuilder)
local BotAvatar = require(script.Parent.BotAvatar)
local RoundState = require(script.Parent.RoundState)
local RoundSchedule = require(script.Parent.RoundSchedule)
local Leaderboard = require(script.Parent.Parent.Leaderboard.Leaderboard)
local Campaign = require(script.Parent.Parent.Progression.Campaign)
local FieldDetails = require(script.Parent.FieldDetails)
local Shop = require(Server.Economy.Shop)
local CamoRules = require(ReplicatedStorage.Shared.Camos)
local Camos = require(Server.Progression.Camos)

local log = Log.scope("LiveRound.Match")

local MatchService = {}

export type Match = {
	player: Player,
	map: string,
	tier: Types.BotTier,
	marker: string,
	stop: () -> (),
}

--- Fired when a match finishes, so the hub can walk the player back out into
--- the woods. Set by the bootstrap; nil in the sim.
MatchService.onMatchEnded = nil :: ((Player, string) -> ())?

local active: { [Player]: any } = {}
local latency: { [Player]: number } = {}
local mapWorlds: { [Player]: Folder } = {}
local venues: { [Player]: any } = {}
MatchService.onReturnToField = nil :: ((Player) -> ())?

local function vecOf(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

--------------------------------------------------------------------------------

--[[
	Where the server believes the player is, in metres.

	Hit resolution and telemetry use this server position. The client's
	claimed origin is prediction metadata and never positions a live shot.
]]
local function playerGroundPosition(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	local rootPart = root :: BasePart
	-- HumanoidRootPart sits at hip height; the sim works from the feet.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local feet = rootPart.Position - Vector3.new(0, rootPart.Size.Y / 2 + (if humanoid then humanoid.HipHeight else 1.5), 0)
	return Units.vectorToMetres(feet)
end

local function playerVelocity(player: Player): Vector3
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return Vector3.zero
	end
	return Units.vectorToMetres((root :: BasePart).AssemblyLinearVelocity)
end

--------------------------------------------------------------------------------

function MatchService.start(player: Player, mapName: string, tier: Types.BotTier, seed: number?, mode: string?): Match?
	if active[player] then
		log.warn(`{player.Name} already has a match running`)
		return nil
	end

	local handle = Profile.load(player.UserId)
	if not handle or player.Parent ~= Players then
		log.warn(`no profile session for {player.Name}; refusing to start`)
		return nil
	end

	if not Profile.hasUnlocked(handle, mapName) then
		log.warn(`{player.Name} has not unlocked {mapName}`)
		return nil
	end

	local matchData = Config.get("match")
	local ballisticsData = Config.get("ballistics")
	local hitbox = ballisticsData.hitbox
	local meleeRules = Melee.rules()
	local markerName = handle.data.loadout.marker
	local markerData = Config.require("markers", "markers." .. markerName)
	local spec = Ballistics.specFromMarker(markerData, ballisticsData)
	local paintPalette = Config.get("venue").paintColors
	local paintRgb = paintPalette[handle.data.loadout.paintColor] or paintPalette.yellow
	local paintColour = Color3.fromRGB(paintRgb[1], paintRgb[2], paintRgb[3])

	local world = MapGeometry.build(Config.map(mapName), Config.get("maps_index"))
	if mapWorlds[player] then mapWorlds[player]:Destroy() end
	local mapRoot = WorldBuilder.build(mapName, Workspace)
	mapWorlds[player] = mapRoot
	local venue = FieldDetails.build(mapName, mapRoot)
	venues[player] = venue

	local rootSeed = seed or math.floor(os.clock() * 1000) % 2147483647
	local root = Rng.new(rootSeed)
	local chatter = Chatter.new(tier, root:fork(2))
	local names = chatter:squadNames()

	local botFolder = Instance.new("Folder")
	botFolder.Name = "Bots"
	botFolder.Parent = mapRoot

	--[[
		A match is five rounds and the enemy team grows each one. Round-scoped
		state -- the squad, its coordinator, the avatars on the field -- is
		rebuilt by buildSquad below; match-scoped state (the shot log, deaths,
		shots, the round reports the payout is computed from) lives out here and
		persists across all five.
	]]
	--[[
		The match plan.

		Gauntlet is five rounds off RoundSchedule. The Shoothouse is one course
		FLATTENED INTO THE SAME SHAPE: each stage's cover refills `waves` times,
		so a four-stage course becomes eight rounds, each carrying the anchors
		its defenders hold and the checkpoint the player respawns on.

		Expressing the mode as a schedule rather than as a second match loop is
		the whole point -- firing, hit validation, lag compensation, telemetry
		and respawn below this line are one engine serving both, so a fix to the
		gauntlet is a fix to the course and neither can drift from the other.
	]]
	local isCourse = mode == "shoothouse"
	if isCourse and not Course.hasCourse(mapName) then
		log.warn(`{mapName} has no Shoothouse course; running the gauntlet instead`)
		isCourse = false
	end
	local schedule: { any } = if isCourse
		then Course.schedule(mapName, tier, 1)
		else RoundSchedule.all(tier)
	--- No pause between stages: the Shoothouse clock never stops, so the stage
	--- announcement is the client's job and the field moves up immediately.
	local intermissionSeconds = if isCourse then 0 else RoundSchedule.intermissionSeconds()
	local roundIndex = 0
	local currentRound: RoundSchedule.Round = schedule[1]
	local coordinator = SquadCoordinator.new(tier, world, root:fork(1))
	local bots: { any } = {}
	local botsById: { [string]: any } = {}
	local avatars: { [string]: any } = {}
	local reports: { any } = {}
	local roundDeaths, roundElims, roundShots, roundHits = 0, 0, 0, 0

	local function clearSquad()
		for _, avatar in pairs(avatars) do
			avatar:destroy()
		end
		table.clear(avatars)
		table.clear(bots)
		table.clear(botsById)
	end

	--- Anchors by id, so a course stage can name the cover its defenders hold.
	local anchorById: { [string]: any } = {}
	for _, anchor in ipairs(world.anchors) do
		anchorById[anchor.id] = anchor
	end

	local function buildSquad(round: any)
		clearSquad()
		coordinator = SquadCoordinator.new(round.tier, world, root:fork(round.index * 7 + 1))
		local assignments = coordinator:assign(round.botCount)

		for i = 1, round.botCount do
			--[[
				Dropped onto whatever actually holds the point up. The map data
				is authored to put everyone on the ground, but a Y typo used to
				produce a bot standing in mid-air and nothing in the pipeline
				could tell -- this makes the worst case "on the roof of the thing
				underneath you" instead of "in the sky".
			]]
			local position: Vector3, facing: Vector3
			if round.stage then
				--[[
					A course stage's defenders start ON the cover they hold --
					that is what makes the stage a band of the map rather than a
					wave that walks in from the back -- and they start looking
					down the approach the player has to come up.
				]]
				local ids = round.stage.anchorIds
				local anchor = anchorById[ids[((i - 1) % #ids) + 1]]
				position = MapGeometry.groundPoint(world, vecOf(anchor.position))
				facing = round.stage.checkpoint.position - position
			else
				--[[
					The squad can outnumber the authored spawns -- Speedball has
					six and fields twelve, because adding more measurably broke
					the field (see its _botSpawns note). Reused spawns are fanned
					onto a small ring instead of stacking bodies at one point:
					deterministic, a metre and a half out, and settled onto
					whatever holds the point up like every other spawn.
				]]
				local slot = ((i - 1) % #world.botSpawns) + 1
				local reuse = math.floor((i - 1) / #world.botSpawns)
				local spawn = world.botSpawns[slot]
				local at = vecOf(spawn.position)
				if reuse > 0 then
					local angle = (i * 2.399963) + reuse
					at += Vector3.new(math.cos(angle), 0, math.sin(angle)) * (1.5 * reuse)
				end
				position = MapGeometry.groundPoint(world, at)
				facing = vecOf(spawn.lookAt) - position
			end
			facing = Vector3.new(facing.X, 0, facing.Z)
			if facing.Magnitude < 1e-6 then
				facing = Vector3.new(0, 0, -1)
			end
			local bot = BotController.new({
				id = `r{round.index}_bot{i}`,
				name = names[i],
				tier = round.tier,
				role = assignments[i].role,
				anchorId = assignments[i].anchorId,
				position = position,
				facing = facing.Unit,
				world = world,
				coordinator = coordinator,
				rng = root:fork(round.index * 1000 + i),
			})
			bots[i] = bot
			botsById[bot.id] = bot
			-- Kit tracks tier, so a squad's difficulty is readable on sight.
			avatars[bot.id] = BotAvatar.new(bot.id, bot.name, botFolder, round.tier)
			avatars[bot.id]:setPosition(bot.position, bot.facing)

			local anchor = coordinator:anchorById(assignments[i].anchorId)
			if anchor then
				BotController.pathTo(bot, vecOf(anchor.position))
				BotController.setState(bot, "repositioning", 0, "moving to opening anchor")
			end
		end
	end

	local projectiles = ProjectileSim.new(world, ballisticsData)
	projectiles.onFire = function(projectile)
		if projectile.team ~= "player" then
			Remotes.event("MarkerFired"):FireClient(player, {
				origin = projectile.origin,
				direction = projectile.velocity.Unit,
				spec = projectile.spec,
			})
		end
	end
	local lagComp = LagCompensation.new(ballisticsData)
	local shotLog = ShotLog.new(mapName, markerName, tier)
	local state = RoundState.new()

	local visibleSince: { [string]: number? } = {}
	local previousAim: Vector3? = nil
	local deaths, eliminations, hits, shots = 0, 0, 0, 0
	local headshots = 0
	local totalLiveElapsed = 0
	local markerState = MarkerState.new(markerData)
	local respawning = false
	--- Last time the invulnerability override told the player it had eaten a
	--- hit. Only read when that dev flag is on.
	local lastDevNoticeAt = -math.huge
	local spread = Spread.new(markerData, matchData.player, root:fork(500))
	local invulnerableUntil = 0
	local t = 0
	local connection: RBXScriptConnection? = nil
	local finished = false

	local function spawnPlayer(at: Vector3)
		player:LoadCharacterAsync()
		if finished or player.Parent ~= Players then return end
		local character = player.Character
		if not character then error("Character failed to load") end
		local root_ = character:WaitForChild("HumanoidRootPart", 10) :: BasePart
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid
		if not root_ or not humanoid then error("Character rig failed to load") end
		local spawn = Units.vectorToStuds(at) + Vector3.new(0, root_.Size.Y / 2 + humanoid.HipHeight, 0)
		local toward = vecOf(world.playerSpawn.lookAt) - vecOf(world.playerSpawn.position)
		root_.CFrame = CFrame.lookAt(spawn, spawn + Vector3.new(toward.X, 0, toward.Z))
		root_.AssemblyLinearVelocity = Vector3.zero
	end

	local function aliveBots(): number
		local n = 0
		for _, bot in ipairs(bots) do
			if bot.alive then
				n += 1
			end
		end
		return n
	end

	local function say(kind: string, context: any)
		context = context or {}
		context.t = t
		context.aliveCount = aliveBots()
		local line = chatter:say(kind, context)
		if line then
			Remotes.event("ChatterLine"):FireClient(player, line)
		end
	end

	local finish
	local beginRound
	local closeRound
	local intermissionUntil: number? = nil

	--[[
		Starts a round. Round 1 opens the match; every round after it follows an
		intermission during which the field is empty and the squad talks about
		what just happened to them.
	]]
	function beginRound(index: number, warmup: boolean?)
		spread:reset()
		markerState = MarkerState.new(markerData)
		roundIndex = index
		currentRound = schedule[index]
		roundDeaths, roundElims, roundShots, roundHits = 0, 0, 0, 0
		table.clear(visibleSince)
		projectiles:clear()
		buildSquad(currentRound)
		if warmup then
			state.timeLimit = RoundSchedule.timeLimitSeconds()
			state.roundIndex += 1
		else
			state:beginRound(RoundSchedule.timeLimitSeconds())
		end

		Remotes.event("MatchStateChanged"):FireClient(player, {
			phase = if warmup then "warmup" else "live",
			map = mapName,
			tier = currentRound.tier,
			marker = markerName,
			round = currentRound.index,
			roundCount = #schedule,
			botCount = currentRound.botCount,
			-- The course HUD wants the stage, not the round: "Their Half, 3 of
			-- 4" reads as a place on the field, "round 6 of 8" does not.
			mode = if isCourse then "shoothouse" else "gauntlet",
			stage = if currentRound.stage then currentRound.stage.displayName else nil,
			stageIndex = if currentRound.stage then currentRound.stage.index else nil,
			stageCount = if isCourse then Course.stageCount(mapName) else nil,
			wave = currentRound.wave,
			par = if isCourse then Course.parSeconds(mapName) else nil,
		})
		--[[
			A course is eight round-waves but only four STAGES, and the squad
			announcing itself eight times a run reads as a stuck record. On a
			course they speak when the field moves up; in a gauntlet every round
			is its own arrival, which is what these lines were written for.
		]]
		local speaks = not isCourse or currentRound.wave == 1
		if speaks then
			say(if index == 1 then "matchStart" else "roundStart", { force = true })
		end
	end

	--[[
		Ends a round.

		A round the player could not finish ends the MATCH. Respawns are
		unlimited, so failing a round means the clock beat them, and walking them
		into the next, larger round after that would hand out the escalation for
		free.
	]]
	function closeRound(cleared: boolean)
		table.insert(reports, {
			index = currentRound.index,
			tier = currentRound.tier,
			botCount = currentRound.botCount,
			payoutMultiplier = currentRound.payoutMultiplier,
			cleared = cleared,
			deaths = roundDeaths,
			eliminations = roundElims,
			shots = roundShots,
			hits = roundHits,
		})

		if not cleared then
			finish(false)
			return
		end

		if currentRound.isFinal then
			finish(true)
			return
		end

		-- Likewise: they concede a stage, not each wave of it.
		local lastWave = currentRound.stage ~= nil and currentRound.wave == currentRound.stage.waves
		if not isCourse or currentRound.isFinal or lastWave then
			say("roundWon", { force = true })
		end
		clearSquad()
		projectiles:clear()
		intermissionUntil = t + intermissionSeconds
		Remotes.event("MatchStateChanged"):FireClient(player, {
			phase = "intermission",
			map = mapName,
			round = currentRound.index,
			roundCount = #schedule,
			nextBotCount = schedule[roundIndex + 1].botCount,
			seconds = intermissionSeconds,
		})
	end

	--------------------------------------------------------------------------
	-- Firing, driven by the client's intent and decided by the server
	--------------------------------------------------------------------------

	local function onFire(payload: any)
		if finished or respawning or intermissionUntil ~= nil or not RoundState.shotsCount(state) then
			return
		end
		local request = Remotes.validateFireRequest(payload)
		if not request then
			log.warn(`{player.Name} sent a malformed fire request`)
			return
		end

		local ground = playerGroundPosition(player)
		if not ground then
			return
		end
		local muzzle = (ground :: Vector3) + Vector3.new(0, hitbox.chestHeightMetres, 0)

		-- Client origin is prediction metadata only. Always fire from the server's
		-- own muzzle; replication lag must not discard a legitimate trigger pull.

		if markerState.ammo <= 0 then
			markerState:reload(t)
		end
		if not markerState:fire(t) then
			return
		end

		local velocity = playerVelocity(player)
		local stance = spread:stance(velocity, request.stance == "crouching") :: Types.Stance
		local shotDirection = spread:fire(request.direction, t, stance)

		local candidates: { ShotMeasure.Candidate } = {}
		for _, bot in ipairs(bots) do
			if bot.alive then
				table.insert(candidates, {
					id = bot.id,
					position = bot.position,
					velocity = bot.velocity,
					visibleSince = visibleSince[bot.id],
				})
			end
		end

		local measurement = ShotMeasure.measure({
			t = t,
			origin = muzzle,
			direction = request.direction,
			spec = spec,
			stance = stance,
			previousDirection = previousAim,
			candidates = candidates,
			aimHeight = hitbox.chestHeightMetres,
		})

		projectiles:fire({
			origin = muzzle,
			direction = shotDirection,
			spec = spec,
			ownerId = "player",
			team = "player",
			t = t,
			meta = { measurement = measurement, stance = stance },
		})

		previousAim = request.direction
		shots += 1
		roundShots += 1
	end

	local fireConnection = Remotes.event("FireMarker").OnServerEvent:Connect(function(firingPlayer, payload)
		if firingPlayer == player then
			onFire(payload)
		end
	end)

	local reloadConnection = Remotes.event("RequestReload").OnServerEvent:Connect(function(reloadingPlayer)
		if reloadingPlayer == player and not finished and not respawning and intermissionUntil == nil and RoundState.shotsCount(state) then
			markerState:reload(t)
		end
	end)

	--------------------------------------------------------------------------
	-- The butt of the marker
	--------------------------------------------------------------------------

	local swingReadyAt = -math.huge

	--[[
		The player shoves somebody.

		The client says one thing -- which way it was facing -- and the server
		decides everything that matters: where the player actually stood, who was
		inside reach, and whether the cooldown had elapsed. A swing therefore
		cannot be spammed off a modified client any faster than it can be swung
		here, and it can never name its own victim.

		It costs nothing and it counts as an elimination, so two things are
		deliberately NOT done: no shot is logged, and no headshot is recorded.
		A shove is not aim, so letting it into the shot log would flatter the
		accuracy the coach reads back, and letting it into the headshot counter
		would make contact range a way to grind camos without ever hitting a
		head. Payout still pays for the body, which is correct -- you did take
		them out.
	]]
	local function onSwing(payload: any)
		if finished or respawning or intermissionUntil ~= nil or not RoundState.shotsCount(state) then
			return
		end
		local request = Remotes.validateSwingRequest(payload)
		if not request then
			log.warn(`{player.Name} sent a malformed swing request`)
			return
		end
		if t < swingReadyAt then
			return
		end
		swingReadyAt = t + meleeRules.cooldownSeconds

		local ground = playerGroundPosition(player)
		if not ground then
			return
		end
		local origin = (ground :: Vector3) + Vector3.new(0, hitbox.chestHeightMetres, 0)
		local bot = Melee.pick(origin, request.direction, bots :: any, meleeRules) :: any
		if not bot then
			return
		end

		eliminations += 1
		roundElims += 1
		bot:eliminate(t)
		local avatar = avatars[bot.id]
		if avatar then avatar:splatter(bot.position + Vector3.new(0, hitbox.chestHeightMetres, 0), paintColour) end
		Remotes.event("BotEliminated"):FireClient(player, {
			botId = bot.id,
			name = bot.name,
			distance = (bot.position - origin).Magnitude,
			remaining = aliveBots(),
			headshot = false,
			melee = true,
		})
		say("botEliminated", {})
	end

	local swingConnection = Remotes.event("SwingMarker").OnServerEvent:Connect(function(swingingPlayer, payload)
		if swingingPlayer == player then
			onSwing(payload)
		end
	end)

	--[[
		The player is out.

		Extracted so a shove can end a life the same way paint does. It used to
		live inline in the projectile branch, so the only way to take a player
		out was to hit them with a ball.

		`impact` is where the mark lands, for the client splatter. A shove has no
		ball, so it passes the swinging bot's own position.
	]]
	local function eliminatePlayer(impact: Vector3)
		if respawning or t < invulnerableUntil then
			return
		end
		--[[
			The dev override, refused here and only here.

			Every way a life can end -- a body shot, a headshot, a shove --
			arrives at this function, so one guard covers all of them and there
			is no second set of hit rules to keep in step. The hit still
			happened: the bots still call it, paint still lands, the round
			carries on. You simply are not taken out.

			It is deliberately not "health". This game has no health bar, one
			mark ends a round, and giving a dev flag a hit-point pool would mean
			shipping rules nobody plays. SimMatch never reads this, or every
			balance number in the project would start describing a player who
			cannot die -- and Leaderboard already quarantines dev runs onto
			their own keys, so nothing recorded under it can reach a real board.
		]]
		if Dev.flag("invulnerable") then
			-- Throttled: standing in a pro squad's crossfire is a hit every few
			-- frames, and a remote per hit would be the dev flag generating more
			-- traffic than the match.
			if t - lastDevNoticeAt > 2 then
				lastDevNoticeAt = t
				Remotes.event("MatchStateChanged"):FireClient(player, {
					phase = state.phase,
					notice = "DEV: hit ignored",
					noticeSeconds = 1.2,
				})
			end
			return
		end
		respawning = true
		deaths += 1
		roundDeaths += 1
		shotLog:recordDeath(t)
		projectiles:clear()
		-- Decided before invulnerability is timed off it, or a course
		-- respawn would come back 0.5 s before its own grace window.
		local respawnDelay = if currentRound.stage
			then Config.require("course", "timing.respawnDelaySeconds")
			else matchData.respawnDelaySeconds
		invulnerableUntil = t + respawnDelay + matchData.respawn.invulnerabilitySeconds
		Remotes.event("PlayerEliminated"):FireClient(player, {
			deaths = deaths,
			impact = Units.vectorToStuds(impact),
		})
		say("playerEliminated", {})

		-- Respawn is free and unlimited. It costs payout, not progress --
		-- and on a course it costs ten seconds instead, charged once at
		-- the end by Course.finalSeconds.
		local respawnAt: Vector3
		if currentRound.stage then
			--[[
				A course sends you back to the checkpoint you reached, not
				to the start and not to whichever spawn is furthest from
				the squad. Losing your progress up the field is what the
				ten seconds is instead of.
			]]
			respawnAt = MapGeometry.groundPoint(world, currentRound.stage.checkpoint.position)
		else
			respawnAt = MapGeometry.groundPoint(world, vecOf(world.playerRespawns[1].position))
			local best = -math.huge
			for _, entry in ipairs(world.playerRespawns) do
				local candidate = MapGeometry.groundPoint(world, vecOf(entry.position))
				local nearest = math.huge
				for _, bot in ipairs(bots) do
					if bot.alive then
						nearest = math.min(nearest, (bot.position - candidate).Magnitude)
					end
				end
				if nearest > best then
					best, respawnAt = nearest, candidate
				end
			end
		end
		task.delay(respawnDelay, function()
			if not finished then
				spawnPlayer(respawnAt)
				respawning = false
				invulnerableUntil = t + matchData.respawn.invulnerabilitySeconds
			end
		end)
	end

	--------------------------------------------------------------------------
	-- The loop
	--------------------------------------------------------------------------

	local function step(dt: number)
		if finished then
			return
		end
		t += dt

		--[[
			Between rounds: the field is empty, the next (larger) squad walks on.
			Checked BEFORE the round clock advances -- a round won with two
			seconds left on the limit must not have its intermission counted
			against the next round's clock.
		]]
		if intermissionUntil then
			if t < (intermissionUntil :: number) then
				return
			end
			intermissionUntil = nil
			beginRound(roundIndex + 1)
			return
		end

		if state.phase == "live" then totalLiveElapsed += dt end
		local keepGoing = state:step(dt)
		local alive = aliveBots()
		if alive == 0 then
			closeRound(true)
			return
		end
		if not keepGoing then
			closeRound(false)
			return
		end

		if not RoundState.shotsCount(state) then
			return
		end
		markerState:update(t)

		local ground = playerGroundPosition(player)
		if not ground then
			return
		end
		local playerPosition = ground :: Vector3
		local velocity = playerVelocity(player)
		spread:step(dt, t, velocity)
		local playerAlive = not respawning and t >= invulnerableUntil

		local player_ = {
			position = playerPosition,
			velocity = velocity,
			alive = playerAlive,
			stance = "standing" :: Types.Stance,
		}

		-- What the player can see, for the telemetry's acquisition timing.
		local eye = playerPosition + Vector3.new(0, matchData.player.eyeHeightMetres, 0)
		for _, bot in ipairs(bots) do
			if not bot.alive then
				visibleSince[bot.id] = nil
				continue
			end
			local aimPoint = bot.position + Vector3.new(0, hitbox.chestHeightMetres, 0)
			if MapGeometry.hasLineOfSight(world, eye, aimPoint) then
				if visibleSince[bot.id] == nil then
					visibleSince[bot.id] = t
				end
			else
				visibleSince[bot.id] = nil
			end
		end

		local moraleMultiplier = SquadCoordinator.moraleErrorMultiplier(alive)
		local targets: { any } = {}
		for _, bot in ipairs(bots) do
			bot:tick(dt, {
				t = t,
				dt = dt,
				squad = bots,
				player = player_,
				projectiles = projectiles,
				moraleErrorMultiplier = moraleMultiplier,
				aliveCount = alive,
				chatter = say,
				meleeRules = meleeRules,
				meleePlayer = function(swinger: any)
					eliminatePlayer(swinger.position)
				end,
			})
			local avatar = avatars[bot.id]
			if avatar and bot.alive then
				avatar:setSwing(BotController.swingProgress(bot, t))
				avatar:setPosition(bot.position, bot.facing, dt)
			end
			table.insert(targets, BotController.asTarget(bot))
		end

		coordinator:updateCrossfire(bots, playerPosition, t)

		table.insert(targets, {
			id = "player",
			team = "player",
			position = playerPosition,
			velocity = velocity,
			radius = hitbox.bodyWidthMetres * 0.5,
			height = hitbox.bodyHeightMetres,
			alive = playerAlive,
		})
		lagComp:capture(t, targets)

		for _, event in ipairs(projectiles:step(dt, t, targets)) do
			local projectile = event.projectile
			if projectile.team == "player" then
				local measurement = projectile.meta and projectile.meta.measurement
				local bot = if event.kind == "target" and event.targetId then botsById[event.targetId] else nil
				-- A burst may resolve several paintballs against one snapshot. Only
				-- the first can eliminate that bot or increment persistent camo progress.
				local hitBot = bot ~= nil and bot.alive == true
				local headshot = hitBot and CamoRules.classifyHeadshot(event.position, bot.position, projectile.velocity)
				local camoProgress: any = nil
				if hitBot then
					hits += 1
					eliminations += 1
					roundHits += 1
					roundElims += 1
					bot:eliminate(event.t)
					if headshot then
						headshots += 1
						camoProgress = Camos.recordHeadshot(handle)
						if camoProgress and #camoProgress.unlockedCamos > 0 then
							Remotes.event("LoadoutChanged"):FireClient(player, handle.data.loadout)
						end
					end
					local avatar = avatars[bot.id]
					if avatar then avatar:splatter(event.position, paintColour) end
					Remotes.event("BotEliminated"):FireClient(player, {
						botId = bot.id,
						name = bot.name,
						distance = event.distance,
						remaining = aliveBots(),
						headshot = headshot,
					})
					say("botEliminated", {})
				end
				if measurement and RoundState.shotsCount(state) then
					shotLog:record({
						t = projectile.bornAt,
						stance = projectile.meta.stance,
						distance = measurement.distance,
						hit = hitBot,
						eliminated = hitBot,
						targetId = if hitBot then event.targetId else measurement.targetId,
						angularErrorDeg = measurement.angularErrorDeg,
						leadErrorM = measurement.leadErrorM,
						holdoverErrorM = measurement.holdoverErrorM,
						targetLateralSpeed = measurement.targetLateralSpeed,
						timeToAcquireMs = measurement.timeToAcquireMs,
						targetVisibleMsBeforeShot = measurement.targetVisibleMsBeforeShot,
						crosshairOffsetDegAtReveal = measurement.crosshairOffsetDegAtReveal,
						priorAimSwingDeg = measurement.priorAimSwingDeg,
					})
				end
				Remotes.event("ShotResolved"):FireClient(player, {
					shotId = projectile.id,
					hit = hitBot,
					headshot = headshot,
					camoProgress = camoProgress,
					targetId = event.targetId,
					impact = Units.vectorToStuds(event.position),
					holdoverErrorM = measurement and measurement.holdoverErrorM,
					leadErrorM = measurement and measurement.leadErrorM,
				})
			elseif event.kind == "target" and event.targetId == "player" then
				eliminatePlayer(event.position)
			end
		end
	end

	--------------------------------------------------------------------------

	function finish(cleared: boolean, quiet: boolean?)
		if finished then
			return
		end
		finished = true
		state:finish()

		if cleared then
			say("squadWipe", { force = true })
			if deaths == 0 then
				say("flawlessWipe", { force = true })
			end
		end

		local outcome: Types.MatchOutcome = {
			cleared = cleared,
			deaths = deaths,
			eliminations = eliminations,
			durationSeconds = totalLiveElapsed,
			shots = shots,
			hits = hits,
			longestStreak = shotLog:longestStreak(),
		}

		--[[
			Payout is computed here, from numbers the server counted itself,
			across all five rounds. Each round earns its own share only if it was
			cleared; the match-level terms -- deaths, accuracy, streak, flawless
			-- are then applied once to the sum. Deaths accumulating across the
			whole match and being charged at the end is what stops the escalating
			early rounds becoming free practice.
		]]
		local roundResults: { Payout.RoundResult } = {}
		for i, report in ipairs(reports) do
			roundResults[i] = {
				index = report.index,
				tier = report.tier,
				payoutMultiplier = report.payoutMultiplier,
				cleared = report.cleared,
			}
		end

		--[[
			Two ways to be paid.

			A gauntlet is paid per round, then charged once for the whole match's
			deaths. A course is paid per MEDAL: the clock already carries the
			deaths at ten seconds each, and charging the economy's exponential
			penalty on top would price one mistake twice. CourseProgress writes
			the record and hands back what the run was worth.
		]]
		local breakdown: any
		local courseOutcome: any = nil
		if isCourse then
			courseOutcome = CourseProgress.record(handle, {
				mapName = mapName,
				liveSeconds = totalLiveElapsed,
				deaths = deaths,
				cleared = cleared,
				playerCount = 1,
			})
			local roundsCleared = 0
			for _, report in ipairs(reports) do
				if report.cleared then
					roundsCleared += 1
				end
			end
			breakdown = {
				total = if courseOutcome then courseOutcome.payout else 0,
				cleared = cleared,
				roundsCleared = roundsCleared,
				roundsPlayed = #reports,
				course = courseOutcome,
			}
		else
			breakdown = Payout.computeMatch({
				expectedRounds = #schedule,
				map = mapName,
				marker = markerName,
				rounds = roundResults,
				deaths = deaths,
				shots = shots,
				hits = hits,
				longestStreak = outcome.longestStreak,
			})
		end

		local summary = Prescription.summarise(shotLog, outcome, tier, breakdown.total)
		summary.headshots = headshots

		--[[
			Leaderboard submission. A time means all five rounds cleared in one
			match, timed by the server's own round clock -- so it is gated on
			breakdown.cleared, not on the player having survived, and the
			elimination count is checked against what the schedule should have
			produced. Leaderboard.validate does the refusing; this only supplies
			numbers the server counted itself.
		]]
		if breakdown.cleared then
			local expected = 0
			for _, round in ipairs(schedule) do
				expected += round.botCount
			end
			task.spawn(function()
				local wrote, why = Leaderboard.submit({
					userId = player.UserId,
					displayName = player.DisplayName,
					map = mapName,
					tier = tier,
					marker = markerName,
					-- Its own board. A course is 28 defenders and a gauntlet is
					-- 40 over five rounds; ranked together the course time would
					-- erase the gauntlet best on the same field.
					mode = if isCourse then "shoothouse" else "gauntlet",
					-- A course is ranked on the time it is JUDGED on, which is the
					-- clock plus ten seconds a death. Submitting the raw clock
					-- would put a six-death run above a clean one.
					seconds = if courseOutcome then courseOutcome.seconds else outcome.durationSeconds,
					deaths = deaths,
					eliminations = eliminations,
					roundsCleared = breakdown.roundsCleared,
					roundsPlayed = breakdown.roundsPlayed,
				}, expected)
				if wrote then
					Remotes.event("LeaderboardUpdated"):FireClient(player, {
						map = mapName,
						seconds = outcome.durationSeconds,
						personalBest = true,
					})
					if handle:isActive() then
						handle.data.bestTimes = handle.data.bestTimes or {}
						handle.data.bestTimes[mapName] = outcome.durationSeconds
					end
				elseif why and why ~= "not a personal best" then
					log.warn(`leaderboard refused {player.Name}'s {mapName} run: {why}`)
				end
			end)
		end

		if breakdown.total > 0 and handle:isActive() then
			Profile.credit(handle, breakdown.total, `match {mapName}/{tier}`)
			Remotes.event("CurrencyChanged"):FireClient(player, handle.data.currency)
		end
		if handle:isActive() then
			Profile.recordMatch(handle, summary)

			--[[
				Season marks, off the same summary the payout used. Awarded from
				eliminations and the clear, never from time on the field -- see
				Shared/Season. Granting immediately after means a player who
				crosses a tier sees the reward on the results screen rather than
				on next join.
			]]
			SeasonPass.award(handle, summary)
			local seasonRewards = SeasonPass.grantDue(handle)
			if #seasonRewards > 0 then
				Remotes.event("LoadoutChanged"):FireClient(player, handle.data.loadout)
			end

			--[[
				Record the clear against the campaign, then see which chapters
				that just finished. Written server-side off numbers the server
				counted -- a chapter is never completed because a client said so.
			]]
			-- A course clear is emphatically NOT a gauntlet clear: the campaign
			-- chapters gate on five rounds against a squad, not on a timed run.
			if breakdown.cleared and not isCourse then
				handle.data.gauntletClears = handle.data.gauntletClears or {}
				local byTier = handle.data.gauntletClears[mapName] or {}
				local previous = byTier[tier]
				if previous == nil or deaths < previous then
					byTier[tier] = deaths
				end
				handle.data.gauntletClears[mapName] = byTier
			end

			local record = Campaign.recordFromProfile(handle.data)
			local finished = Campaign.newlyCompleted(record)
			if #finished > 0 then
				handle.data.chaptersCompleted = handle.data.chaptersCompleted or {}
				for _, chapter in ipairs(finished) do
					table.insert(handle.data.chaptersCompleted, chapter.id)
					if chapter.rewards.currency and chapter.rewards.currency > 0 then
						Profile.credit(handle, chapter.rewards.currency, `chapter {chapter.id}`)
					end
					--[[
						Chapter gear is how the unbuyable items reach the player.
						Nothing here is for sale at any price.
					]]
					for _, id in ipairs(chapter.rewards.gear or {}) do
						MatchService.grantChapterGear(handle, id)
					end
					log.info(`{player.Name} completed chapter {chapter.id}`)
				end
				Remotes.event("CurrencyChanged"):FireClient(player, handle.data.currency)
				Remotes.event("CampaignUpdated"):FireClient(
					player,
					Campaign.card(Campaign.recordFromProfile(handle.data))
				)
			end
		end

		if not quiet then
			Remotes.event("MatchSummary"):FireClient(player, {
				summary = summary,
				breakdown = breakdown,
				rounds = reports,
				headshots = headshots,
				mode = if isCourse then "shoothouse" else "gauntlet",
				course = courseOutcome,
			})
		end

		if connection then
			(connection :: RBXScriptConnection):Disconnect()
		end
		fireConnection:Disconnect()
		reloadConnection:Disconnect()
		swingConnection:Disconnect()
		active[player] = nil

		state:close()
		log.info(`match over for {player.Name}: cleared={cleared} deaths={deaths} payout={breakdown.total}`)

		if not quiet and MatchService.onMatchEnded then
			(MatchService.onMatchEnded :: any)(player, mapName)
		end
	end

	venue.visit = function()
		if respawning or player.Parent ~= Players then return false end
		finish(false, true)
		projectiles:clear()
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not rootPart or not humanoid then return false end
		local at = Units.vectorToStuds(venue.spawn) + Vector3.new(0, rootPart.Size.Y / 2 + humanoid.HipHeight, 0)
		rootPart.CFrame = CFrame.lookAt(at, Units.vectorToStuds(venue.lookAt))
		rootPart.AssemblyLinearVelocity = Vector3.zero
		Remotes.event("MatchStateChanged"):FireClient(player, { phase = "shop", map = mapName, tier = tier })
		return true
	end
	local function near(part: BasePart): boolean
		local rootPart = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		return rootPart ~= nil and (rootPart.Position - part.Position).Magnitude <= Units.metresToStuds(Config.get("venue").interactionRadiusMetres)
	end
	venue.exit.Interact.Triggered:Connect(function(visitor)
		if visitor == player and near(venue.exit) then venue.visit() end
	end)
	venue.counter.Interact.Triggered:Connect(function(visitor)
		if visitor == player and MatchService.canShop(player) then
			Remotes.event("ShopOpened"):FireClient(player, MatchService.shopData(player))
		end
	end)
	venue.enter.Interact.Triggered:Connect(function(visitor)
		if visitor == player and not active[player] and near(venue.enter) and MatchService.onReturnToField then
			MatchService.onReturnToField(player)
		end
	end)

	state:onPhase(function(phase)
		Remotes.event("MatchStateChanged"):FireClient(player, {
			phase = phase,
			map = mapName,
			tier = tier,
			marker = markerName,
		})
	end)

	Remotes.event("LoadoutChanged"):FireClient(player, handle.data.loadout)
	Remotes.event("CurrencyChanged"):FireClient(player, handle.data.currency)

	local match: Match = {
		player = player,
		map = mapName,
		tier = tier,
		marker = markerName,
		stop = function()
			finish(false)
		end,
	}
	active[player] = match
	spawnPlayer(MapGeometry.groundPoint(world, vecOf(world.playerSpawn.position)))
	if finished then return nil end

	-- Round 1 of five. Each subsequent round is started by closeRound after its
	-- intermission; the squad grows every time.
	beginRound(RoundSchedule.startIndex(), true)
	local accumulator = 0
	local fixedStep = ballisticsData.simulation.fixedStep
	--[[
		Bounded catch-up.

		This loop used to run as many fixed steps as the elapsed time asked for.
		One long frame -- an asset load, a breakpoint, a client hitching on a
		weak machine -- would ask for sixty steps of twelve bots and every
		projectile inside a single frame; that takes longer than a frame, which
		makes the next dt larger, which asks for more steps. A single hitch
		becomes a freeze.

		So the steps are capped and the surplus is DROPPED, not carried:
		carrying it is the same spiral written differently. A stall costs
		simulated time, which the player experiences as a moment of slow motion,
		instead of costing the server. It is logged the first time in a match so
		a real performance problem cannot hide behind the cap.
	]]
	local maxSteps = ballisticsData.simulation.maxStepsPerFrame
	local warnedAboutCatchUp = false
	connection = RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		local steps = 0
		while accumulator >= fixedStep and not finished do
			accumulator -= fixedStep
			step(fixedStep)
			steps += 1
			if steps >= maxSteps then
				if accumulator >= fixedStep and not warnedAboutCatchUp then
					warnedAboutCatchUp = true
					log.warn(`simulation fell {string.format("%.0f", accumulator * 1000)} ms behind and dropped the surplus`)
				end
				accumulator = 0
				break
			end
		end
	end)
	return match
end

function MatchService.visitShop(player: Player): boolean
	local venue = venues[player]
	return venue ~= nil and venue.visit ~= nil and venue.visit()
end

function MatchService.canShop(player: Player): boolean
	if active[player] then return false end
	local venue = venues[player]
	local rootPart = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	return venue ~= nil and rootPart ~= nil
		and (rootPart.Position - venue.counter.Position).Magnitude <= Units.metresToStuds(Config.get("venue").interactionRadiusMetres)
end

function MatchService.shopData(player: Player): any
	if not MatchService.canShop(player) then return { ok = false, reason = "Walk up to the supply counter." } end
	local handle = Profile.load(player.UserId)
	if not handle then return { ok = false, reason = "Field pass unavailable." } end
	return { ok = true, balance = handle.data.currency, freeMode = require(ReplicatedStorage.Shared.CommerceCatalog).isFree(), catalogue = Shop.catalogueFor(handle) }
end

function MatchService.isActive(player: Player): boolean
	return active[player] ~= nil
end

--[[
	Whoever is currently on a field, if anyone.

	Every map is built at the WORLD ORIGIN, and Hub.park is global. Two matches
	running at once would stack two maps on top of each other and leave whoever
	stayed behind standing in a parked hub. That was unreachable while the place
	was MaxPlayers = 1; it is reachable now, so the server refuses a second
	concurrent match rather than building the collision.

	This is the guard, not co-op. Two players sharing ONE course is a separate
	and much larger change -- the simulation identifies the player as a single
	entity (`id = "player"`), so a shared match means two player capsules through
	ProjectileSim, SquadCoordinator and ShotLog. See docs/PROGRESS.md.
]]
function MatchService.currentHost(): Player?
	for player in pairs(active) do
		return player
	end
	return nil
end

--[[
	Grants a chapter's gear reward into the right ownership list.

	Looks the item up across every category rather than the caller naming one,
	because a chapter reward is authored as a bare id and having to also declare
	its category is the kind of duplication that goes stale.
]]
function MatchService.grantChapterGear(handle: any, id: string)
	local fields: { [string]: string } = {
		jerseys = "ownedJerseys", pads = "ownedPads", helmets = "ownedHelmets",
		shoulders = "ownedShoulders", pods = "ownedPods",
	}
	for category, field in pairs(fields) do
		if GearStats.item(category, id) then
			handle.data[field] = handle.data[field] or {}
			if not table.find(handle.data[field], id) then
				table.insert(handle.data[field], id)
			end
			return
		end
	end
	if Config.get("markers").markers[id] then
		if not table.find(handle.data.ownedMarkers, id) then
			table.insert(handle.data.ownedMarkers, id)
		end
		return
	end
	log.warn(`chapter reward '{id}' matches no known item`)
end

function MatchService.stop(player: Player)
	local match = active[player]
	if match then
		match.stop()
	end
end

--- Diagnostic latency only. Release projectiles resolve against current server
--- targets; history is captured but rewind is not integrated.
function MatchService.bindLatencyReporting()
	Remotes.event("ReportLatency").OnServerEvent:Connect(function(player, value)
		if type(value) == "number" and value == value and value >= 0 then
			latency[player] = math.min(value, 1)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		latency[player] = nil
		venues[player] = nil
		if mapWorlds[player] then
			mapWorlds[player]:Destroy()
			mapWorlds[player] = nil
		end
		MatchService.stop(player)
	end)
end

return MatchService
