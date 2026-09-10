--!strict
--[[
	BotController -- one enemy, tick-driven.

	States: holding, reacting, engaging, repositioning, out.

	Every transition logs through the LiveRound.Bots logger at verbose, per
	CLAUDE.md, so a sim run can be read back as a story rather than a number.

	The controller is pure with respect to Roblox: it moves a Vector3 and asks
	a ProjectileSim to fire. The live server binds that to a character model;
	the sim harness binds it to nothing at all. Same code, same decisions.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local MapGeometry = require(ReplicatedStorage.Shared.MapGeometry)
local Rng = require(ReplicatedStorage.Shared.Rng)
local Log = require(ReplicatedStorage.Shared.Log)
local Melee = require(ReplicatedStorage.Shared.Melee)
local AimModel = require(script.Parent.AimModel)

local BotController = {}
BotController.__index = BotController

local log = Log.scope("LiveRound.Bots")

export type State = "holding" | "reacting" | "engaging" | "repositioning" | "out"

export type Bot = typeof(setmetatable(
	{} :: {
		id: string,
		name: string,
		tier: Types.BotTier,
		role: Types.BotRole,
		anchorId: string,
		position: Vector3,
		velocity: Vector3,
		facing: Vector3,
		alive: boolean,
		--- Marshal id when this bot is a horde boss; nil for everyone else.
		boss: string?,
		state: State,
		hasLineOfSight: boolean,

		tierData: any,
		markerData: any,
		spec: Ballistics.Spec,
		world: MapGeometry.World,
		coordinator: any,
		rng: Rng.Generator,

		_eyeHeight: number,
		_aimHeight: number,
		_radius: number,
		_height: number,

		_acquiredAt: number?,
		_fireAt: number?,
		_lastShotAt: number,
		_burstRemaining: number,
		_restUntil: number,
		_hopper: number,
		_reloadUntil: number?,
		_swingLandsAt: number?,
		_swingStartedAt: number?,
		_path: { number }?,
		_pathIndex: number,
		_repositionReadyAt: number,
		_lastSeenAt: number?,
		_watchPoint: Vector3?,
	},
	BotController
))

export type Config = {
	id: string,
	name: string,
	tier: Types.BotTier,
	role: Types.BotRole,
	anchorId: string,
	position: Vector3,
	facing: Vector3,
	world: MapGeometry.World,
	coordinator: any,
	rng: Rng.Generator,
	--[[
		Tier parameters, when the caller has its own.

		Horde hands a veterancy-adjusted copy so that a wave-30 rec bot reacts
		faster than a wave-1 one without a second tier table existing anywhere.
		Absent for every other mode, which reads the shared tier data as before
		-- and Endless.applyVeterancy returns a COPY precisely so that wave 30
		cannot permanently ruin wave 1.
	]]
	tierData: any?,
	--[[
		A field marshal, for horde's boss waves.

		The whole boss rule is that paint on the body does not count and only
		the hopper does -- `bosses.json` says so, and it says why: there is no
		health anywhere in this game and giving a boss three thousand of it
		would have made a bullet sponge out of an aim trainer. So a boss is
		still one hit. It is a very small hit, at range, on someone better than
		you, with an escort.

		That needs no new hit model at all, which is the nice part: a boss
		simply presents a different TARGET. The body stops being one.
	]]
	boss: string?,
}

function BotController.new(config: Config): Bot
	local tierData = config.tierData or Config.require("bots", "tiers." .. config.tier)
	local markerData = Config.require("markers", "markers." .. tierData.marker)
	local ballisticsData = Config.get("ballistics")
	local hitbox = ballisticsData.hitbox

	local bot = setmetatable({
		id = config.id,
		name = config.name,
		tier = config.tier,
		role = config.role,
		anchorId = config.anchorId,
		position = config.position,
		velocity = Vector3.new(0, 0, 0),
		facing = config.facing.Unit,
		alive = true,
		state = "holding" :: State,
		hasLineOfSight = false,

		tierData = tierData,
		markerData = markerData,
		spec = Ballistics.specFromMarker(markerData, ballisticsData),
		world = config.world,
		coordinator = config.coordinator,
		rng = config.rng,

		_eyeHeight = hitbox.headTopMetres * 0.94,
		_aimHeight = hitbox.chestHeightMetres,
		_radius = hitbox.bodyWidthMetres * 0.5,
		_height = hitbox.bodyHeightMetres,

		boss = config.boss,
		_acquiredAt = nil,
		_fireAt = nil,
		_lastShotAt = -math.huge,
		_burstRemaining = 0,
		_restUntil = -math.huge,
		_hopper = markerData.hopperCapacity,
		_reloadUntil = nil,
		_swingLandsAt = nil,
		_swingStartedAt = nil,
		_path = nil,
		_pathIndex = 1,
		_repositionReadyAt = 0,
		_lastSeenAt = nil,
		_watchPoint = nil,
	}, BotController) :: any

	-- Pre-placement: a pro bot is already looking at the lane before the round
	-- starts. A rec bot is looking at whatever it was looking at.
	for _, entry in ipairs(config.world.prePlacement) do
		if entry.anchorId == config.anchorId then
			bot._watchPoint = Vector3.new(entry.watch[1], entry.watch[2], entry.watch[3])
			break
		end
	end

	return bot
end

--------------------------------------------------------------------------------
-- Geometry helpers
--------------------------------------------------------------------------------

--[[
	How far through a swing this bot is, or nil.

	Exists so the avatar can show the shove instead of the bot appearing to
	stand still and eliminate somebody by telepathy. The commit delay is the
	player's only warning, and a warning nobody can see is not one -- so the
	animation runs on the same clock as the rule, past contact and through the
	follow-through.
]]
function BotController.swingProgress(self: Bot, t: number): number?
	local started = self._swingStartedAt
	if started == nil then
		return nil
	end
	local progress = (t - started) / Melee.rules().swingSeconds
	if progress >= 1 then
		self._swingStartedAt = nil
		return nil
	end
	return math.max(progress, 0)
end

function BotController.eye(self: Bot): Vector3
	return self.position + Vector3.new(0, self._eyeHeight, 0)
end

function BotController.muzzle(self: Bot): Vector3
	return self.position + Vector3.new(0, self._aimHeight, 0)
end

function BotController.asTarget(self: Bot): any
	if self.boss then
		--[[
			The hopper, and nothing else.

			A short capsule centred on the hopper's height instead of the
			body-length one every other bot presents, so a body shot on a
			marshal misses because there is nothing there to hit. `bodyAbsorbs`
			in bosses.json is this, expressed as data.

			`hopperRadiusMetres` is read as a radius, which is what it is
			called; the prose beside it says "about eighteen centimetres
			across", which would make it a diameter. Taken as named -- the more
			forgiving reading -- and flagged rather than silently halved.
		]]
		local common = Config.require("bosses", "common")
		local radius = common.hopperRadiusMetres
		return {
			id = self.id,
			team = "bots",
			position = self.position + Vector3.new(0, common.hopperHeightMetres - radius, 0),
			velocity = self.velocity,
			radius = radius,
			height = radius * 2,
			alive = self.alive,
		}
	end
	return {
		id = self.id,
		team = "bots",
		position = self.position,
		velocity = self.velocity,
		radius = self._radius,
		height = self._height,
		alive = self.alive,
	}
end

--[[
	Vision test. Three gates, all of which a human also has: range, field of
	view, and an unobstructed line. Concealment counts here -- brush blocks
	sight even though it does not block paint, which is the entire lesson of
	the Woods map.
]]
function BotController.canSee(self: Bot, targetPosition: Vector3): boolean
	local aimPoint = targetPosition + Vector3.new(0, self._aimHeight, 0)
	local eye = BotController.eye(self)
	local delta = aimPoint - eye
	local distance = delta.Magnitude
	if distance > self.tierData.visionRangeMetres then
		return false
	end
	local halfCone = math.rad(self.tierData.visionConeDeg * 0.5)
	if delta.Unit:Dot(self.facing) < math.cos(halfCone) then
		return false
	end
	return MapGeometry.hasLineOfSight(self.world, eye, aimPoint)
end

--- Did the bot hear that? Loud markers carry; the pump barely does.
function BotController.canHear(self: Bot, sourcePosition: Vector3, loudness: number): boolean
	local radius = self.tierData.hearingRadiusMetres * loudness
	return (sourcePosition - self.position).Magnitude <= radius
end

--------------------------------------------------------------------------------
-- Movement
--------------------------------------------------------------------------------

local function setState(self: Bot, state: State, t: number, reason: string)
	if self.state == state then
		return
	end
	log.verbose(`{self.id} ({self.tier}/{self.role}) {self.state} -> {state} @ {string.format("%.2f", t)}: {reason}`)
	self.state = state
end

BotController.setState = setState

function BotController.pathTo(self: Bot, destination: Vector3)
	local from = MapGeometry.nearestNavNode(self.world, self.position)
	local to = MapGeometry.nearestNavNode(self.world, destination)
	self._path = MapGeometry.findPath(self.world, from, to)
	self._pathIndex = 1
end

local function advanceAlongPath(self: Bot, dt: number, speed: number)
	local path = self._path
	if not path or self._pathIndex > #path then
		self.velocity = Vector3.new(0, 0, 0)
		self._path = nil
		return
	end

	local goal = self.world.navNodes[path[self._pathIndex]]
	local delta = goal - self.position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local distance = flat.Magnitude

	if distance < 0.6 then
		self._pathIndex += 1
		if self._pathIndex > #path then
			self._path = nil
			self.velocity = Vector3.new(0, 0, 0)
		end
		-- Nav nodes carry height; step to the node's level so tower decks work.
		self.position = Vector3.new(self.position.X, goal.Y, self.position.Z)
		return
	end

	local step = math.min(speed * dt, distance)
	local direction = flat.Unit
	self.position += direction * step
	self.velocity = direction * speed
	-- Bots look where they are going unless they are shooting at something.
	if self.state == "repositioning" then
		self.facing = direction
	end
end

--------------------------------------------------------------------------------
-- Firing
--------------------------------------------------------------------------------

local function fireInterval(self: Bot): number
	return 60 / self.markerData.roundsPerMinute
end

local function tryFire(self: Bot, t: number, ctx: any, aimAt: Vector3, aimVelocity: Vector3): boolean
	if self._reloadUntil and t < self._reloadUntil then
		return false
	end
	if self._reloadUntil and t >= self._reloadUntil then
		self._reloadUntil = nil
		self._hopper = self.markerData.hopperCapacity
	end
	if self._hopper <= 0 then
		self._reloadUntil = t + self.markerData.reloadSeconds
		ctx.chatter("reloading", { speaker = self.name })
		return false
	end
	if t < self._restUntil then
		return false
	end
	if t - self._lastShotAt < fireInterval(self) then
		return false
	end

	--[[
		The butt of the marker.

		There is no knife in a paintball game and there is not going to be one. At
		contact range you turn the marker around and shove somebody with the tank,
		and that is what this is -- one shove, out for the round, exactly like a
		mark.

		It replaces the barrel tag, which lived in match.json unimplemented since
		the rules were written and, once built, asked the bot to decline a shot at
		four metres. That reads as the squad refusing to play. A shove is the same
		distance rule pointed the right way round: it makes closing the last two
		metres cost something instead of being the safe play.

		The swing is COMMITTED rather than instant. Melee.contactDelay is the whole
		fairness of the mechanic: the bot stops, says something, and the butt
		arrives a moment later, so a player who is paying attention can still back
		out of it. Nothing here fires paint, so no cover, hit rate or spread number
		moves -- a shove is decided by geometry alone, in Melee, where the live
		server and the simulation both read it.
	]]
	local rules = ctx.meleeRules
	local toTarget = aimAt - self.position
	--- Tested against the bearing to the target rather than the bot's current
	--- facing: somebody who has walked into contact range is turned towards,
	--- not swung past because the bot was still pre-placed on a watch angle.
	--- The bot commits to that bearing here, and the landing check uses it.
	if rules and ctx.meleePlayer and Melee.reaches(self.position, toTarget, aimAt, rules) then
		self._lastShotAt = t
		self._swingLandsAt = t + Melee.contactDelay(rules)
		self._swingStartedAt = t
		self.velocity = Vector3.new(0, 0, 0)
		local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
		if flat.Magnitude > 1e-3 then
			self.facing = flat.Unit
		end
		ctx.chatter("melee", { speaker = self.name })
		return true
	end

	local solution = AimModel.solve({
		spec = self.spec,
		origin = BotController.muzzle(self),
		targetPosition = aimAt,
		targetVelocity = aimVelocity,
		tier = self.tierData,
		rng = self.rng,
		elapsedSinceAcquire = t - (self._acquiredAt or t),
		moraleErrorMultiplier = ctx.moraleErrorMultiplier,
	})
	if not solution then
		return false
	end

	self.facing = (solution :: any).direction
	ctx.projectiles:fire({
		origin = BotController.muzzle(self),
		direction = (solution :: any).direction,
		spec = self.spec,
		ownerId = self.id,
		team = "bots",
		t = t,
		meta = { botId = self.id, tier = self.tier },
	})

	self._lastShotAt = t
	self._hopper -= 1
	self._burstRemaining -= 1
	if self._burstRemaining <= 0 then
		self._burstRemaining = self.rng:nextInt(self.tierData.burstLengthMin, self.tierData.burstLengthMax)
		self._restUntil = t + self.tierData.burstRestMs / 1000
	end
	return true
end

--------------------------------------------------------------------------------
-- Where to go next
--------------------------------------------------------------------------------

local function anchorPosition(anchor: any): Vector3
	return Vector3.new(anchor.position[1], anchor.position[2], anchor.position[3])
end

--[[
	Picks the anchor this bot should move to.

	This is where the squad stops being six turrets and starts being a squad.
	Roles differ in one number -- `advanceChance` -- and in the range band they
	want to fight at. Anchors sit back and hold their lane; flankers close to
	knife range; pressure works the middle.

	When a contact is known, candidate anchors are scored on two things: how well
	they sit inside the role's preferred range band, and how much bearing
	separation they add against the angles teammates already hold. That second
	term is the crossfire: it is what punishes a player for holding one angle too
	long, and it is why Speedball teaches that trading is death.
]]
function BotController.chooseDestination(self: Bot, contact: any, ctx: any, t: number): (Vector3?, string?, string?)
	local roleCfg = Config.require("bots", "squad.roles." .. self.role)
	local squadCfg = Config.require("bots", "squad")

	-- No contact: drift between anchors of this role, slowly, to stay unpredictable.
	if not contact then
		if self.rng:nextNumber() >= self.tierData.repositionChance * ctx.dt then
			return nil, nil, nil
		end
		local candidates = self.coordinator:anchorsForRole(self.role)
		if #candidates == 0 then
			return nil, nil, nil
		end
		local pick = candidates[self.rng:nextInt(1, #candidates)]
		return anchorPosition(pick), pick.id, `patrolling to {pick.id}`
	end

	-- Contact known. Does this role advance on it?
	if self.rng:nextNumber() >= roleCfg.advanceChance then
		return nil, nil, nil
	end

	local band = roleCfg.preferredRangeMetres
	local target = contact.position

	-- Bearings teammates already hold on the target, for the crossfire term.
	local held: { number } = {}
	for _, other in ipairs(ctx.squad or {}) do
		if other.alive and other.id ~= self.id and other.hasLineOfSight then
			table.insert(held, MapGeometry.bearingDeg(target, other.position))
		end
	end

	local best: any, bestScore = nil, -math.huge
	for _, anchor in ipairs(self.world.anchors) do
		local position = anchorPosition(anchor)
		local range = (position - target).Magnitude

		-- Score the range band: 1 inside it, falling off outside.
		local rangeScore: number
		if range >= band[1] and range <= band[2] then
			rangeScore = 1
		else
			local miss = if range < band[1] then band[1] - range else range - band[2]
			rangeScore = math.max(0, 1 - miss / 25)
		end
		if rangeScore <= 0 then
			continue
		end

		-- Crossfire: reward the angle furthest from what teammates already cover.
		local bearing = MapGeometry.bearingDeg(target, position)
		local separation = 180
		for _, other in ipairs(held) do
			local diff = math.abs(((bearing - other + 180) % 360) - 180)
			separation = math.min(separation, diff)
		end
		local crossfireScore = math.min(1, separation / squadCfg.crossfireMinSeparationDeg)

		-- Coordination level decides how much the squad plays angles at all.
		-- Rec bots essentially ignore the crossfire term and just walk forward.
		local coordination = self.tierData.coordinationLevel
		local score = rangeScore
			+ coordination * squadCfg.crossfireRewardWeight * crossfireScore
			+ self.rng:nextNumber() * 0.25

		-- Mild preference for anchors this bot's role is meant to use.
		if table.find(anchor.roles, self.role) then
			score += 0.35
		end

		if score > bestScore then
			bestScore, best = score, anchor
		end
	end

	if not best then
		return nil, nil, nil
	end
	if best.id == self.anchorId then
		return nil, nil, nil
	end
	return anchorPosition(best), best.id, `advancing to {best.id} on contact`
end

--------------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------------

export type TickContext = {
	t: number,
	dt: number,
	squad: { any },
	player: any,
	projectiles: any,
	moraleErrorMultiplier: number,
	chatter: (kind: string, context: any) -> (),
	aliveCount: number,
	--- Contact-range rules, and what to call when the butt lands. Absent in any
	--- caller that does not model a shovable player.
	navigate: ((any, number) -> ())?,
	playerLoudness: number?,
	meleeRules: Melee.Rules?,
	meleePlayer: ((swinger: any) -> ())?,
}

--[[
	One fixed step of bot behaviour.

	Order matters: sense, then share, then decide, then move, then shoot. A bot
	that shoots before sensing would be shooting at last tick's world, which is
	a subtle way to make bots feel like they cheat.
]]
function BotController.tick(self: Bot, dt: number, ctx: TickContext)
	if not self.alive then
		return
	end

	local movement = Config.require("bots", "movement")
	local t = ctx.t
	local player = ctx.player

	--[[
		0. Finish a swing already in flight.

		Once the butt is moving the bot is not steering it, so it neither senses
		nor shoots until the swing resolves. That pause is deliberate: it is the
		window the player has to step out of reach, and a bot that could cancel
		a committed swing to shoot instead would be getting the mechanic for
		free.
	]]
	if self._swingLandsAt then
		self.velocity = Vector3.new(0, 0, 0)
		if t < self._swingLandsAt then
			return
		end
		self._swingLandsAt = nil
		local rules = ctx.meleeRules
		if rules and ctx.meleePlayer and player.alive
			and Melee.reaches(self.position, self.facing, player.position, rules) then
			ctx.meleePlayer(self)
		end
		return
	end

	-- 1. Sense.
	local sees = player.alive and BotController.canSee(self, player.position)
	self.hasLineOfSight = sees
	if sees then
		self._lastSeenAt = t
		self.coordinator:reportContact(self.id, player.position, player.velocity, t)
		if self._acquiredAt == nil then
			self._acquiredAt = t
			self._fireAt = t + AimModel.reactionDelay(self.tierData, self.rng)
			setState(self, "reacting", t, "acquired the player")
			ctx.chatter("contact", { speaker = self.name })
		end
	elseif self._acquiredAt ~= nil and (t - (self._lastSeenAt or t)) > 1.5 then
		self._acquiredAt = nil
		self._fireAt = nil
		setState(self, "holding", t, "lost the player")
		ctx.chatter("lostContact", { speaker = self.name })
	end

	if not sees and player.alive and ctx.playerLoudness and player.velocity.Magnitude > 0
		and BotController.canHear(self, player.position, ctx.playerLoudness) then
		self.coordinator:reportContact(self.id, player.position, player.velocity, t)
	end

	-- 2. Act on shared contact even without eyes, but only to reposition --
	--    never to shoot. A bot must see a target to shoot at it.
	local contact = self.coordinator:contactFor(self.id, t)

	-- 3. Decide.
	if self.state == "reacting" and self._fireAt and t >= self._fireAt and sees then
		setState(self, "engaging", t, "reaction time elapsed")
	end

	if self.state == "engaging" and not sees then
		setState(self, "holding", t, "no line of sight")
	end

	local repositioning = self.state == "repositioning"
	if not ctx.navigate and not sees and not repositioning and t >= self._repositionReadyAt then
		local hasReason = contact ~= nil
		if AimModel.willExpose(self.tierData, self.rng, hasReason) then
			local destination, anchorId, reason = BotController.chooseDestination(self, contact, ctx, t)
			if destination and anchorId then
				self.anchorId = anchorId :: string
				BotController.pathTo(self, destination :: Vector3)
				self._repositionReadyAt = t + movement.repositionCooldownSeconds
				setState(self, "repositioning", t, reason or `moving to {anchorId}`)
				if self.role == "flanker" and contact then
					ctx.chatter("flanking", { speaker = self.name })
				end
			end
		end
	end

	-- 4. Move.
	if ctx.navigate then
		ctx.navigate(self, dt)
	elseif self.state == "repositioning" then
		local advancing = contact ~= nil
		local speed = if advancing then movement.sprintSpeedMps else movement.walkSpeedMps
		advanceAlongPath(self, dt, speed)
		if self._path == nil then
			setState(self, "holding", t, "reached anchor")
		end
	else
		self.velocity = Vector3.new(0, 0, 0)
		-- Holding bots pre-place on their watch angle. This is the parameter
		-- that costs the player time on every peek.
		if self.state == "holding" and self._watchPoint then
			self.facing = AimModel.prePlacement(
				self.tierData,
				self.facing,
				BotController.eye(self),
				self._watchPoint :: Vector3
			)
		end
	end

	-- 5. Shoot. Only ever at something this bot can currently see.
	if self.state == "engaging" and sees then
		-- Stop-to-shoot applies to bots too.
		if self.velocity.Magnitude > 0.1 then
			return
		end
		tryFire(self, t, ctx, player.position + Vector3.new(0, self._aimHeight, 0), player.velocity)
	end
end

function BotController.eliminate(self: Bot, t: number)
	self.alive = false
	self.velocity = Vector3.new(0, 0, 0)
	setState(self, "out", t, "hit -- out for the round")
end

return BotController
