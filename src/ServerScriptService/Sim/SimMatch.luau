--!strict
--[[
	SimMatch -- a whole match, headless, deterministic.

	A match is FIVE rounds and the enemy team grows each one: two bots in round
	1, the full six by round 5, with better players arriving for the last two.
	Round state is rebuilt every round; match state -- the shot log, the death
	count, the streak, the squad's names -- is threaded through, because that is
	what the payout is charged against.

	BUILD_PLAN Phase 3 requires this to exist BEFORE the bots, and it is the only
	honest way to know whether anything in this project works: you cannot watch
	the game play, so the game has to be able to play itself and file a report.

	Determinism contract: same map, same seed, same policy, same output. Every
	source of randomness routes through Shared/Rng, every step is a fixed dt, and
	nothing consults a wall clock. If a change breaks that, SimSpec fails.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local MapGeometry = require(ReplicatedStorage.Shared.MapGeometry)
local Rng = require(ReplicatedStorage.Shared.Rng)
local Spread = require(ReplicatedStorage.Shared.Spread)
local MarkerState = require(ReplicatedStorage.Shared.MarkerState)
local Log = require(ReplicatedStorage.Shared.Log)

local Server = script.Parent.Parent
local ProjectileSim = require(Server.Ballistics.ProjectileSim)
local BotController = require(Server.Bots.BotController)
local SquadCoordinator = require(Server.Bots.SquadCoordinator)
local Chatter = require(Server.Bots.Chatter)
local ShotLog = require(Server.Telemetry.ShotLog)
local ShotMeasure = require(Server.Telemetry.ShotMeasure)
local Prescription = require(Server.Telemetry.Prescription)
local Payout = require(Server.Economy.Payout)
local RoundSchedule = require(Server.Match.RoundSchedule)
local Policies = require(script.Parent.Policies)

local SimMatch = {}

export type Options = {
	map: string,
	seed: number,
	policy: string | Policies.Policy,
	--- The tier the player selected. Rounds 4 and 5 escalate above it.
	tier: Types.BotTier?,
	marker: string?,
	--- Per-round time limit override, for fast specs.
	maxSeconds: number?,
	captureLog: boolean?,
	--- Run a single round instead of the full five. Tuning aid.
	singleRound: number?,
}

export type RoundReport = {
	index: number,
	tier: Types.BotTier,
	botCount: number,
	cleared: boolean,
	deaths: number,
	eliminations: number,
	durationSeconds: number,
	shots: number,
	hits: number,
}

export type Result = {
	map: string,
	seed: number,
	policy: string,
	tier: Types.BotTier,
	marker: string,
	outcome: Types.MatchOutcome,
	rounds: { RoundReport },
	breakdown: Payout.MatchBreakdown,
	summary: Types.SessionSummary,
	telemetry: any,
	chatter: { any },
	botLog: { string }?,
	engagementDistances: { number },
}

--------------------------------------------------------------------------------

local function vecOf(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

--- Furthest respawn from the living bots, so a respawn is never a free trade.
local function chooseRespawn(world: MapGeometry.World, bots: { any }, minDistance: number): Vector3
	local best, bestScore = vecOf(world.playerSpawn.position), -math.huge
	for _, entry in ipairs(world.playerRespawns) do
		local position = vecOf(entry.position)
		local nearest = math.huge
		for _, bot in ipairs(bots) do
			if bot.alive then
				nearest = math.min(nearest, (bot.position - position).Magnitude)
			end
		end
		if nearest == math.huge then
			nearest = minDistance * 2
		end
		if nearest > bestScore then
			bestScore, best = nearest, position
		end
	end
	return best
end

--------------------------------------------------------------------------------

export type RoundContext = {
	map: string,
	world: MapGeometry.World,
	spec: Ballistics.Spec,
	markerData: any,
	matchData: any,
	ballisticsData: any,
	round: RoundSchedule.Round,
	log: any,
	policy: Policies.Policy,
	playerRng: any,
	spread: any,
	squadRng: any,
	botRngs: { any },
	chatter: any,
	say: (string, any) -> (),
	timeLimit: number,
	engagementDistances: { number },
	--- Deaths so far this MATCH, so the round can report its own contribution.
	deathsBefore: number,
}

--[[
	Runs one round to a clear or to the clock.

	Everything the player learns here -- angles, sightlines, where the anchors
	are -- carries into the next round, which is the point of the escalation.
	Nothing mechanical does: the bots are fresh, the hopper is full, and the
	round starts from the map's own spawns.
]]
local function runRound(ctx: RoundContext): RoundReport
	ctx.spread:reset()
	local world = ctx.world
	local matchData = ctx.matchData
	local hitbox = ctx.ballisticsData.hitbox
	local markerData = ctx.markerData
	local spec = ctx.spec
	local round = ctx.round
	local log = ctx.log
	local playerCfg = matchData.player

	local coordinator = SquadCoordinator.new(round.tier, world, ctx.squadRng)
	local names = ctx.chatter:squadNames()
	local assignments = coordinator:assign(round.botCount)

	local bots: { any } = {}
	for i = 1, round.botCount do
		local spawn = world.botSpawns[((i - 1) % #world.botSpawns) + 1]
		local position = vecOf(spawn.position)
		local facing = vecOf(spawn.lookAt) - position
		if facing.Magnitude < 1e-6 then
			facing = Vector3.new(0, 0, -1)
		end
		bots[i] = BotController.new({
			id = `r{round.index}_bot{i}`,
			name = names[i],
			tier = round.tier,
			role = assignments[i].role,
			anchorId = assignments[i].anchorId,
			position = position,
			facing = facing.Unit,
			world = world,
			coordinator = coordinator,
			rng = ctx.botRngs[i],
		})
		local anchor = coordinator:anchorById(assignments[i].anchorId)
		if anchor then
			BotController.pathTo(bots[i], vecOf(anchor.position))
			BotController.setState(bots[i], "repositioning", 0, "moving to opening anchor")
		end
	end

	local projectiles = ProjectileSim.new(world, ctx.ballisticsData)

	local player = {
		position = vecOf(world.playerSpawn.position),
		velocity = Vector3.new(0, 0, 0),
		alive = true,
		stance = "standing" :: Types.Stance,
		aim = Vector3.new(0, 0, 1),
		--[[
			The hopper is the SAME state machine the live server runs.

			It used to be three fields and an inline block here, which is two
			implementations of one rule -- and the rule that decides how often the
			player can shoot is the rule every balance number in
			docs/PUBLISH_READINESS.md rests on. A gear stat or a variant that
			changed reloading live would have left this copy on the old behaviour
			and quietly invalidated the difficulty tuning without failing a test.
		]]
		marker = MarkerState.new(markerData),
		respawnAt = nil :: number?,
		invulnerableUntil = 0,
		previousAim = nil :: Vector3?,
	}
	do
		local look = vecOf(world.playerSpawn.lookAt) - player.position
		player.aim = if look.Magnitude > 1e-6 then look.Unit else Vector3.new(0, 0, 1)
	end

	local visibleSince: { [string]: number? } = {}
	local deaths, eliminations, hits, shots = 0, 0, 0, 0

	local dt = 1 / matchData.server.tickRateHz
	local t = 0
	local cleared = false

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
		context.round = round.index
		ctx.say(kind, context)
	end

	say(if round.index == 1 then "matchStart" else "roundStart", { force = true })

	--------------------------------------------------------------------------

	while t < ctx.timeLimit do
		local alive = aliveBots()
		if alive == 0 then
			cleared = true
			break
		end

		local moraleMultiplier = SquadCoordinator.moraleErrorMultiplier(alive)

		if not player.alive and player.respawnAt and t >= player.respawnAt then
			player.position = chooseRespawn(world, bots, matchData.respawn.spawnAwayFromBotsMetres)
			player.alive = true
			player.respawnAt = nil
			player.invulnerableUntil = t + matchData.respawn.invulnerabilitySeconds
			player.marker = MarkerState.new(markerData)
			table.clear(visibleSince)
		end

		-- What can the player see? Bots the player cannot see are never handed
		-- to a policy, so no policy can cheat.
		local visible: { any } = {}
		local eye = player.position + Vector3.new(0, playerCfg.eyeHeightMetres, 0)
		for _, bot in ipairs(bots) do
			if not bot.alive or not player.alive then
				visibleSince[bot.id] = nil
				continue
			end
			local aimPoint = bot.position + Vector3.new(0, hitbox.chestHeightMetres, 0)
			if MapGeometry.hasLineOfSight(world, eye, aimPoint) then
				if visibleSince[bot.id] == nil then
					visibleSince[bot.id] = t
				end
				table.insert(visible, bot)
			else
				visibleSince[bot.id] = nil
			end
		end

		if player.alive then
			local muzzle = player.position + Vector3.new(0, hitbox.chestHeightMetres, 0)
			local intent = ctx.policy.decide({
				t = t,
				position = player.position,
				velocity = player.velocity,
				muzzle = muzzle,
				aimHeight = hitbox.chestHeightMetres,
				spec = spec,
				visible = visible,
				rng = ctx.playerRng,
				world = world,
			})

			if intent.aim then
				player.aim = (intent.aim :: Vector3).Unit
			end

			if intent.move and (intent.move :: Vector3).Magnitude > 1e-6 then
				local direction = Vector3.new((intent.move :: Vector3).X, 0, (intent.move :: Vector3).Z).Unit
				local speed = if intent.sprint
					then playerCfg.sprintSpeedMps
					elseif intent.crouch then playerCfg.crouchSpeedMps
					else playerCfg.walkSpeedMps
				local proposed = player.position + direction * speed * dt
				local probe = Vector3.new(0, 1.0, 0)
				if MapGeometry.cast(world, player.position + probe, proposed + probe, { ignoreConcealment = true }) == nil then
					player.position = proposed
					player.velocity = direction * speed
				else
					player.velocity = Vector3.new(0, 0, 0)
				end
				player.stance = if intent.sprint then "sprinting" else "moving"
			else
				player.velocity = Vector3.new(0, 0, 0)
				player.stance = if intent.crouch then "crouching" else "standing"
			end

			player.stance = ctx.spread:stance(player.velocity, intent.crouch)
			ctx.spread:step(dt, t, player.velocity)

			if intent.fire then
				-- Exactly what MatchService.onFire does: an empty hopper starts a
				-- reload, and MarkerState decides whether a trigger pull produces
				-- a ball. Rate of fire, reload lockout and refill all live there.
				if player.marker.ammo <= 0 then
					player.marker:reload(t)
				end
				if player.marker:fire(t) then
					local candidates: { ShotMeasure.Candidate } = {}
					for _, bot in ipairs(visible) do
						table.insert(candidates, {
							id = bot.id,
							position = bot.position,
							velocity = bot.velocity,
							visibleSince = visibleSince[bot.id],
						})
					end

					local measurement = ShotMeasure.measure({
						t = t,
						origin = muzzle,
						direction = player.aim,
						spec = spec,
						stance = player.stance,
						previousDirection = player.previousAim,
						candidates = candidates,
						aimHeight = hitbox.chestHeightMetres,
					})

					projectiles:fire({
						origin = muzzle,
						direction = ctx.spread:fire(player.aim, t, player.stance),
						spec = spec,
						ownerId = "player",
						team = "player",
						t = t,
						meta = { measurement = measurement, stance = player.stance },
					})

					player.previousAim = player.aim
					shots += 1
				end
			end
		else
			ctx.spread:step(dt, t, Vector3.zero)
		end

		local botTargets: { any } = {}
		for _, bot in ipairs(bots) do
			bot:tick(dt, {
				t = t,
				dt = dt,
				squad = bots,
				player = player,
				projectiles = projectiles,
				moraleErrorMultiplier = moraleMultiplier,
				aliveCount = alive,
				chatter = say,
			})
			table.insert(botTargets, BotController.asTarget(bot))
		end

		if player.alive then
			coordinator:updateCrossfire(bots, player.position, t)
		end

		local targets = table.clone(botTargets)
		table.insert(targets, {
			id = "player",
			team = "player",
			position = player.position,
			velocity = player.velocity,
			radius = hitbox.bodyWidthMetres * 0.5,
			height = hitbox.bodyHeightMetres,
			alive = player.alive and t >= player.invulnerableUntil,
		})

		for _, event in ipairs(projectiles:step(dt, t, targets)) do
			local projectile = event.projectile
			if projectile.team == "player" then
				local measurement = projectile.meta and projectile.meta.measurement
				local hitBot = false
				if event.kind == "target" then
					for _, bot in ipairs(bots) do
						if bot.id == event.targetId and bot.alive then
							hitBot = true
							break
						end
					end
				end
				if hitBot then
					hits += 1
					eliminations += 1
					table.insert(ctx.engagementDistances, event.distance)
					for _, bot in ipairs(bots) do
						if bot.id == event.targetId then
							bot:eliminate(event.t)
							say("botEliminated", {})
						end
					end
				end
				if measurement then
					log:record({
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
			elseif event.kind == "target" and event.targetId == "player" and player.alive then
				player.alive = false
				player.respawnAt = event.t + matchData.respawnDelaySeconds
				deaths += 1
				log:recordDeath(event.t)
				projectiles:clear()
				say("playerEliminated", {})
			end
		end

		t += dt
	end

	if cleared then
		say(if round.isFinal then "squadWipe" else "roundWon", { force = true })
	end

	return {
		index = round.index,
		tier = round.tier,
		botCount = round.botCount,
		cleared = cleared,
		deaths = deaths,
		eliminations = eliminations,
		durationSeconds = t,
		shots = shots,
		hits = hits,
	}
end

--------------------------------------------------------------------------------

function SimMatch.run(options: Options): Result
	local mapName = options.map
	local seed = options.seed
	local baseTier: Types.BotTier = options.tier or "rec"
	local markerName = options.marker or "mechanical"

	local matchData = Config.get("match")
	local ballisticsData = Config.get("ballistics")
	local markerData = Config.require("markers", "markers." .. markerName)

	local world = MapGeometry.build(Config.map(mapName), Config.get("maps_index"))
	local spec = Ballistics.specFromMarker(markerData, ballisticsData)

	-- Independent streams so that adding a projectile does not shift bot aim.
	local root = Rng.new(seed)
	local chatterRng = root:fork(2)
	local playerRng = root:fork(3)
	local spread = Spread.new(markerData, matchData.player, root:fork(500))

	local botLog: { string }? = if options.captureLog then {} else nil
	local previousLevel = Log.getLevel()
	if botLog then
		Log.setLevel("verbose")
		Log.setSink(function(_, scope, message)
			table.insert(botLog :: { string }, `[{scope}] {message}`)
		end)
	end

	local chatter = Chatter.new(baseTier, chatterRng)
	local chatterLines: { any } = {}
	local function say(kind: string, context: any)
		local line = chatter:say(kind, context)
		if line then
			table.insert(chatterLines, line)
		end
	end

	local policy: Policies.Policy = if type(options.policy) == "string"
		then Policies.byName(options.policy :: string)
		else options.policy :: Policies.Policy

	-- One shot log for the whole match: the telemetry is about the player's
	-- session, not about any single round.
	local log = ShotLog.new(mapName, markerName, baseTier)
	local engagementDistances: { number } = {}

	local schedule: { RoundSchedule.Round }
	if options.singleRound then
		schedule = { RoundSchedule.get(options.singleRound :: number, baseTier) }
	else
		schedule = RoundSchedule.all(baseTier)
	end

	local timeLimit = options.maxSeconds or RoundSchedule.timeLimitSeconds()

	local reports: { RoundReport } = {}
	local deaths, eliminations, hits, shots, duration = 0, 0, 0, 0, 0

	for _, round in ipairs(schedule) do
		local botRngs: { any } = {}
		for i = 1, round.botCount do
			botRngs[i] = root:fork(round.index * 1000 + i)
		end

		local report = runRound({
			map = mapName,
			world = world,
			spec = spec,
			markerData = markerData,
			matchData = matchData,
			ballisticsData = ballisticsData,
			round = round,
			log = log,
			policy = policy,
			playerRng = playerRng,
			spread = spread,
			squadRng = root:fork(round.index * 7 + 1),
			botRngs = botRngs,
			chatter = chatter,
			say = say,
			timeLimit = timeLimit,
			engagementDistances = engagementDistances,
			deathsBefore = deaths,
		})

		table.insert(reports, report)
		deaths += report.deaths
		eliminations += report.eliminations
		hits += report.hits
		shots += report.shots
		duration += report.durationSeconds

		--[[
			A round the player could not finish ends the match. Respawns are
			unlimited, so failing a round means the clock beat them -- and
			letting them walk into the next, larger round after that would be
			handing out the escalation for free.
		]]
		if not report.cleared then
			break
		end
	end

	local allCleared = #reports == #schedule
	for _, report in ipairs(reports) do
		if not report.cleared then
			allCleared = false
		end
	end

	if allCleared and deaths == 0 then
		say("flawlessWipe", { t = duration, aliveCount = 0, force = true })
	end

	local outcome: Types.MatchOutcome = {
		cleared = allCleared,
		deaths = deaths,
		eliminations = eliminations,
		durationSeconds = duration,
		shots = shots,
		hits = hits,
		longestStreak = log:longestStreak(),
	}

	local roundResults: { Payout.RoundResult } = {}
	for i, report in ipairs(reports) do
		roundResults[i] = {
			index = report.index,
			tier = report.tier,
			payoutMultiplier = schedule[i].payoutMultiplier,
			cleared = report.cleared,
		}
	end

	local breakdown = Payout.computeMatch({
		expectedRounds = #schedule,
		map = mapName,
		marker = markerName,
		rounds = roundResults,
		deaths = deaths,
		shots = shots,
		hits = hits,
		longestStreak = outcome.longestStreak,
	})

	if botLog then
		Log.setSink(nil)
		Log.setLevel(if previousLevel <= 10 then "verbose" else "info")
	end

	return {
		map = mapName,
		seed = seed,
		policy = policy.name,
		tier = baseTier,
		marker = markerName,
		outcome = outcome,
		rounds = reports,
		breakdown = breakdown,
		summary = Prescription.summarise(log, outcome, baseTier, breakdown.total),
		telemetry = log:toTable(),
		chatter = chatterLines,
		botLog = botLog,
		engagementDistances = engagementDistances,
	}
end

return SimMatch
