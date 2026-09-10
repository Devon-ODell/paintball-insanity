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
local Settlement = require(Server.Match.Settlement)
local Endless = require(Server.Match.Endless)
local Squad = require(Server.Match.Squad)
local FlagArena = require(Server.Match.FlagArena)
local FlagMatch = require(Server.Match.FlagMatch)
local MatchProgress = require(Server.Match.MatchProgress)
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

local function updateVisibility(world: any, bots: { any }, playerPosition: Vector3, visibleSince: any, t: number)
	local eye = playerPosition + Vector3.new(0, Config.require("match", "player.eyeHeightMetres"), 0)
	for _, bot in ipairs(bots) do
		if not bot.alive then
			visibleSince[bot.id] = nil
			continue
		end
		local aimPoint = bot.position + Vector3.new(0, Config.require("ballistics", "hitbox.chestHeightMetres"), 0)
		if MapGeometry.hasLineOfSight(world, eye, aimPoint) then
			if visibleSince[bot.id] == nil then
				visibleSince[bot.id] = t
			end
		else
			visibleSince[bot.id] = nil
		end
	end
end

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

	local isCTF = mode == "captureTheFlag"
	if isCTF and not FlagMatch.canStart(mapName, handle.data) then return nil end
	local mapData = if isCTF then FlagArena.prepare(Config.map(mapName)) else Config.map(mapName)
	local world = MapGeometry.build(mapData, Config.get("maps_index"))
	if mapWorlds[player] then mapWorlds[player]:Destroy() end
	local mapRoot = WorldBuilder.build(mapName, Workspace, mapData)
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
	--[[
		Horde is the third schedule, and the only one that is not finished when
		the match starts.

		The gauntlet lays out five rounds and the Shoothouse lays out its
		stages; horde lays out the first wave and appends the next one every
		time a wave is cleared. That is what "endless" means here, and it is the
		only structural difference between this mode and the other two -- the
		firing, hit validation, lag compensation, telemetry and respawn below
		this line are the same engine serving all three.

		What ends a run is the ordinary round time limit, which already exists:
		clear the wave inside it or the match ends at the depth you reached.
		There is no new failure state, no health and no respawn limit, because
		the mode does not need one -- "it does not have an end, only a depth you
		stopped at" is the round clock, said out loud.
	]]
	local isHorde = mode == "horde"
	local ctf = if isCTF then FlagMatch.new(mapData, world, mapRoot) else nil
	if ctf then ctf.schedule[1].tier = tier end
	local schedule: { any } = if ctf then ctf.schedule elseif isHorde
		then { Endless.round(1) }
		elseif isCourse then Course.schedule(mapName, tier, 1)
		else RoundSchedule.all(tier)
	--- No pause between stages: the Shoothouse clock never stops, so the stage
	--- announcement is the client's job and the field moves up immediately.
	--- Horde carries its own per-wave value, because a breather is a pause and
	--- every other wave runs straight into the next.
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

	--[[
		Reinforcements.

		A horde wave can total twenty-eight while only twelve stand on the field
		at once: the rest arrive as replacements, one for each bot taken out, so
		depth is felt as pressure that never lets up rather than as a crowd
		standing in the open. Twelve is also what every difficulty number in
		this project was measured against, and reinforcing keeps that true at
		wave forty.

		Zero for the gauntlet and the Shoothouse, which field their whole round
		at once.
	]]
	local squadAssignments: { any } = {}
	local reinforcementsLeft = 0
	local fielded = 0

	--- One bot onto the field. Placement and construction live in Match/Squad;
	--- the roster stays here because the loop reads it from a dozen places.
	local function spawnBot(round: any, ordinal: number, spawnSlot: number?)
		local bot, avatar = Squad.spawn({
			world = world,
			root = root,
			names = names,
			botFolder = botFolder,
			anchorById = anchorById,
			coordinator = coordinator,
			assignments = squadAssignments,
			vecOf = vecOf,
		}, round, ordinal, spawnSlot)
		table.insert(bots, bot)
		botsById[bot.id] = bot
		avatars[bot.id] = avatar
	end

	local function replaceFlagBot(slot: number)
		local old = bots[slot]
		if avatars[old.id] then avatars[old.id]:destroy() end
		avatars[old.id], botsById[old.id] = nil, nil
		fielded += 1
		spawnBot(currentRound, fielded, slot)
		bots[slot] = table.remove(bots)
	end

	local function buildSquad(round: any)
		clearSquad()
		coordinator = SquadCoordinator.new(round.tier, world, root:fork(round.index * 7 + 1))
		squadAssignments = coordinator:assign(round.botCount)
		reinforcementsLeft = round.reinforcements or 0
		fielded = 0
		for _ = 1, round.botCount do
			fielded += 1
			spawnBot(round, fielded)
		end
	end

	--[[
		Sends the next replacement in, if this wave still has any.

		Called wherever a bot stops being alive, so paint and a shove both feed
		it -- a mode where the melee quietly stopped the wave advancing would be
		a strange thing to debug.
	]]
	local function reinforce(round: any)
		if reinforcementsLeft <= 0 then
			return
		end
		reinforcementsLeft -= 1
		fielded += 1
		spawnBot(round, fielded)
	end

	local projectiles = ProjectileSim.new(world, ballisticsData)
	projectiles.onFire = function(projectile)
		if projectile.team ~= "player" then
			Remotes.event("MarkerFired"):FireClient(player, {
				origin = projectile.origin,
				direction = projectile.velocity.Unit,
				spec = projectile.spec,
				--- Who fired. The range sends this same remote for the player's
				--- own shots, and only the squad's should sound like a threat.
				source = "squad",
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

		--[[
			Which way the caller is looking at you.

			`Chatter.bearingWord` was written, commented and never called from
			anywhere, so `context.bearing` fell through to its "front" default
			every single time -- and five authored callouts interpolate it.
			Every contact in this game was reported as "Contact! front!"
			regardless of where the player actually was, and "I'm rotating
			front." is not even English.

			Measured from the SPEAKER's facing, because that is how a callout
			works: a bot saying "left" means you are on its left, which tells
			you something about where it is pointed. Coarse on purpose -- a
			squad calling exact degrees is a wallhack, as that function's own
			comment says.
		]]
		local speaker = Squad.named(bots, context.speaker)
		if speaker and context.bearing == nil then
			local ground = playerGroundPosition(player)
			if ground then
				context.bearing = Chatter.bearingFrom(speaker.facing, (ground :: Vector3) - speaker.position)
			end
		end

		local line = chatter:say(kind, context)
		if line then
			--[[
				Where the voice is coming from, so a callout is a direction and
				not just a subtitle.

				Looked up by name rather than threaded through every ctx.chatter
				call site -- the bots already say who is speaking, and this is
				the one place that has the roster. People shouting on a
				paintball field give their position away, and the audio scales
				that down hard (audio.json rangeScale) so it stays a
				close-quarters tell rather than a map of the whole squad.
			]]
			local voice = speaker or Squad.named(bots, line.speaker)
			if voice then
				line.at = voice.position + Vector3.new(0, hitbox.chestHeightMetres, 0)
			end
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
			state.timeLimit = if ctf then math.huge else RoundSchedule.timeLimitSeconds()
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
			mode = mode or "gauntlet",
			stage = if currentRound.stage then currentRound.stage.displayName else nil,
			stageIndex = if currentRound.stage then currentRound.stage.index else nil,
			stageCount = if isCourse then Course.stageCount(mapName) else nil,
			wave = currentRound.wave,
			par = if isCourse then Course.parSeconds(mapName) else nil,
			ctf = if ctf then ctf:snapshot() else nil,
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

		--[[
			Horde writes the next wave only once the last one is cleared.

			The schedule is the mode, so an endless mode is a schedule that is
			never finished. Appending here rather than precomputing a few
			hundred waves keeps "endless" true instead of true-looking, and
			means the wave the player is about to fight is composed against the
			depth they actually reached.
		]]
		if isHorde then
			table.insert(schedule, Endless.round(currentRound.index + 1))
		end

		-- Likewise: they concede a stage, not each wave of it.
		local lastWave = currentRound.stage ~= nil and currentRound.wave == currentRound.stage.waves
		if not isCourse or currentRound.isFinal or lastWave then
			say("roundWon", { force = true })
		end
		clearSquad()
		projectiles:clear()
		--[[
			A horde wave carries its own pause: twenty-two seconds on a
			breather, none at all otherwise. Every fifth wave being the only
			time you are not being shot at is what makes the breather worth
			reaching, and it is the only structure a run has.
		]]
		local pause = currentRound.intermissionSeconds or intermissionSeconds
		intermissionUntil = t + pause
		local nextRound = schedule[roundIndex + 1]
		Remotes.event("MatchStateChanged"):FireClient(player, {
			phase = "intermission",
			map = mapName,
			round = currentRound.index,
			--- A horde run has no round count to show, only the depth so far.
			roundCount = if isHorde then nil else #schedule,
			nextBotCount = if nextRound then nextRound.botCount else nil,
			seconds = pause,
			--- The line the squad gets at five, ten, twenty and so on.
			notice = if isHorde and nextRound and nextRound.endless
				then nextRound.endless.milestone
				else nil,
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
		reinforce(currentRound)
		local avatar = avatars[bot.id]
		if avatar then avatar:splatter(bot.position + Vector3.new(0, hitbox.chestHeightMetres, 0), paintColour) end
		Remotes.event("BotEliminated"):FireClient(player, {
			botId = bot.id,
			name = bot.name,
			distance = (bot.position - origin).Magnitude,
			remaining = aliveBots(),
			headshot = false,
			melee = true,
			at = bot.position + Vector3.new(0, hitbox.chestHeightMetres, 0),
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
		local respawnDelay = if ctf then ctf.rules.cfg.respawn.playerSeconds elseif currentRound.stage
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
		local respawnAt = Squad.respawnPoint({
			world = world,
			vecOf = vecOf,
		} :: any, currentRound, bots)
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
		if alive == 0 and not ctf then
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
		if not ground and not ctf then return end
		local playerPosition = ground or ctf.lastPosition
		local velocity = playerVelocity(player)
		spread:step(dt, t, velocity)
		local playerAlive = ground ~= nil and not respawning and t >= invulnerableUntil

		local player_ = {
			position = playerPosition,
			velocity = velocity,
			alive = playerAlive,
			stance = "standing" :: Types.Stance,
		}

		updateVisibility(world, bots, playerPosition, visibleSince, t)

		local moraleMultiplier = SquadCoordinator.moraleErrorMultiplier(alive)
		local targets: { any } = {}
		for index, bot in ipairs(bots) do
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
				navigate = if ctf then ctf:navigator(bot, index, bots, t) else nil,
				playerLoudness = if ctf and ctf.rules.flags.enemy.carrier == "player" then ctf.rules:carrierModifiers("player").loudness else nil,
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
					reinforce(currentRound)
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
						-- Where it happened, so the client can put the sound
						-- there. Metres, like everything else on this wire.
						at = event.position,
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
		if ctf then
			ctf:step(dt, ground, ground ~= nil and not respawning and t >= invulnerableUntil, bots, replaceFlagBot, function(snapshot)
				Remotes.event("MatchStateChanged"):FireClient(player, { phase = "live", ctf = snapshot })
			end)
			if ctf.rules.finished then finish(ctf.rules.winner == "player") end
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
		--[[
			Two ways to be paid, and the choice between them lives in Settlement
			now -- it is the one part of this function with a single
			responsibility and no engine surface, and this closure did not need a
			second copy of the payout rules inside it.
		]]
		local breakdown, courseOutcome = Settlement.payout(handle, {
			isCourse = isCourse,
			isHorde = isHorde,
			mapName = mapName,
			markerName = markerName,
			reports = reports,
			schedule = schedule,
			deaths = deaths,
			shots = shots,
			hits = hits,
			longestStreak = outcome.longestStreak,
			liveSeconds = totalLiveElapsed,
			cleared = cleared,
		})

		if ctf then breakdown = ctf:breakdown(deaths, shots, hits) end
		local summary = Prescription.summarise(shotLog, outcome, tier, breakdown.total)
		summary.mode = mode or "gauntlet"
		summary.ctf = if ctf then ctf.rules:summary() else nil
		summary.headshots = headshots

		--[[
			Leaderboard submission. A time means all five rounds cleared in one
			match, timed by the server's own round clock -- so it is gated on
			breakdown.cleared, not on the player having survived, and the
			elimination count is checked against what the schedule should have
			produced. Leaderboard.validate does the refusing; this only supplies
			numbers the server counted itself.
		]]
		if breakdown.cleared and not ctf then
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
					mode = mode or "gauntlet",
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
		MatchProgress.record(handle, player, summary, breakdown, mapName, tier, deaths, not isCourse and not isHorde and not ctf, MatchService.grantChapterGear)

		if not quiet then
			Remotes.event("MatchSummary"):FireClient(player, {
				summary = summary,
				breakdown = breakdown,
				rounds = reports,
				headshots = headshots,
				mode = mode or "gauntlet",
				course = courseOutcome,
				ctf = summary.ctf,
			})
		end

		if connection then
			(connection :: RBXScriptConnection):Disconnect()
		end
		fireConnection:Disconnect()
		reloadConnection:Disconnect()
		swingConnection:Disconnect()
		active[player] = nil
		if ctf then ctf:destroy(); clearSquad(); projectiles:clear() end

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
	beginRound(if ctf then 1 else RoundSchedule.startIndex(), true)
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
