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
}

function BotController.new(config: Config): Bot
	local tierData = Config.require("bots", "tiers." .. config.tier)
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

		_acquiredAt = nil,
		_fireAt = nil,
		_lastShotAt = -math.huge,
		_burstRemaining = 0,
		_restUntil = -math.huge,
		_hopper = markerData.hopperCapacity,
		_reloadUntil = nil,
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

function BotController.eye(self: Bot): Vector3
	return self.position + Vector3.new(0, self._eyeHeight, 0)
end

function BotController.muzzle(self: Bot): Vector3
	return self.position + Vector3.new(0, self._aimHeight, 0)
end

function BotController.asTarget(self: Bot): any
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
		The barrel tag.

		`match.json` has declared `hitRules.surrenderBarrelTagRangeMetres` since
		the rules were written -- "inside this range a bot offers a barrel tag
		instead of shooting; it is a paintball courtesy and it reads as comedy
		rather than mercy" -- and nothing has ever implemented it.

		At contact range a player does not get shot, they get touched out with
		the barrel. That is the real rule on a real field, and mechanically it is
		the right way round: it makes closing the last few metres COST something
		rather than being the safe play. probe-trading currently says rushing
		beats holding an angle on three fields, which is the inverse of the
		premise this whole game is built on, and a bot that cannot punish
		somebody walking into its barrel is part of why.

		No paint leaves the marker, so nothing here can be dodged, blocked by
		cover that is already this close, or reflected in hit rate. The bot says
		so out loud, because the line is the point.
	]]
	local tagRange = ctx.barrelTagRangeMetres or 0
	if tagRange > 0 and ctx.tagPlayer then
		local reach = (aimAt - BotController.muzzle(self)).Magnitude
		if reach <= tagRange then
			self._lastShotAt = t
			ctx.chatter("barrelTag", { speaker = self.name })
			ctx.tagPlayer(self)
			return true
		end
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
	if not sees and not repositioning and t >= self._repositionReadyAt then
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
	if self.state == "repositioning" then
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
