--!strict
--[[
	ProjectileSim -- the authoritative flight of every paintball in the game.

	The client fires a cosmetic tracer immediately; this is what actually decides
	whether anything was hit. It is pure with respect to Roblox -- it takes a
	MapGeometry world and a list of target snapshots -- so the live server and
	the headless sim run the same code and cannot disagree.

	Targets are vertical capsules. A paintball hits when the swept segment comes
	within (target radius + ball radius) of the capsule axis. That is generous
	compared to a per-limb hitbox and it is the correct call for paintball: a
	ball that grazes your shoulder marks you, and the game is about prediction,
	not about pixel-perfect torso clipping.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local MapGeometry = require(ReplicatedStorage.Shared.MapGeometry)

local ProjectileSim = {}
ProjectileSim.__index = ProjectileSim

export type Target = {
	id: string,
	team: string,
	--- Ground position; the capsule runs from here up by `height`.
	position: Vector3,
	velocity: Vector3,
	radius: number,
	height: number,
	alive: boolean,
}

export type Projectile = {
	id: number,
	ownerId: string,
	team: string,
	position: Vector3,
	velocity: Vector3,
	spec: Ballistics.Spec,
	bornAt: number,
	distanceTravelled: number,
	origin: Vector3,
	meta: any,
}

export type HitEvent = {
	projectile: Projectile,
	kind: "target" | "world" | "expired",
	targetId: string?,
	position: Vector3,
	t: number,
	distance: number,
}

export type Sim = typeof(setmetatable(
	{} :: {
		world: MapGeometry.World,
		options: any,
		projectiles: { Projectile },
		nextId: number,
		ballRadius: number,
		onFire: ((Projectile) -> ())?,
	},
	ProjectileSim
))

function ProjectileSim.new(world: MapGeometry.World, ballisticsData: any): Sim
	return setmetatable({
		world = world,
		options = {
			fixedStep = ballisticsData.simulation.fixedStep,
			maxFlightTime = ballisticsData.simulation.maxFlightTime,
			maxRange = ballisticsData.simulation.maxRangeMetres,
		},
		projectiles = {},
		nextId = 1,
		ballRadius = ballisticsData.simulation.projectileRadiusMetres,
	}, ProjectileSim) :: any
end

export type FireParams = {
	origin: Vector3,
	direction: Vector3,
	spec: Ballistics.Spec,
	ownerId: string,
	team: string,
	t: number,
	meta: any?,
}

function ProjectileSim.fire(self: Sim, params: FireParams): Projectile
	local projectile: Projectile = {
		id = self.nextId,
		ownerId = params.ownerId,
		team = params.team,
		position = params.origin,
		velocity = params.direction.Unit * params.spec.muzzleVelocity,
		spec = params.spec,
		bornAt = params.t,
		distanceTravelled = 0,
		origin = params.origin,
		meta = params.meta,
	}
	self.nextId += 1
	table.insert(self.projectiles, projectile)
	if self.onFire then self.onFire(projectile) end
	return projectile
end

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

--[[
	Closest approach between segment P(s)=p0+s*(p1-p0) and segment
	Q(u)=q0+u*(q1-q0), both clamped to [0,1]. Returns the distance and s.

	Standard clamped-parameter solution. The degenerate cases matter here: a
	standing target's capsule axis is never degenerate, but a projectile step
	can be when dt is tiny, so both are guarded.
]]
local function segmentSegmentDistance(p0: Vector3, p1: Vector3, q0: Vector3, q1: Vector3): (number, number)
	local d1 = p1 - p0
	local d2 = q1 - q0
	local r = p0 - q0
	local a = d1:Dot(d1)
	local e = d2:Dot(d2)
	local f = d2:Dot(r)

	local s, u
	if a <= 1e-12 and e <= 1e-12 then
		return r.Magnitude, 0
	end
	if a <= 1e-12 then
		s = 0
		u = math.clamp(f / e, 0, 1)
	else
		local c = d1:Dot(r)
		if e <= 1e-12 then
			u = 0
			s = math.clamp(-c / a, 0, 1)
		else
			local b = d1:Dot(d2)
			local denom = a * e - b * b
			if denom > 1e-12 then
				s = math.clamp((b * f - c * e) / denom, 0, 1)
			else
				-- Parallel: any s works; take the start.
				s = 0
			end
			u = (b * s + f) / e
			if u < 0 then
				u = 0
				s = math.clamp(-c / a, 0, 1)
			elseif u > 1 then
				u = 1
				s = math.clamp((b - c) / a, 0, 1)
			end
		end
	end

	local closestP = p0 + d1 * s
	local closestQ = q0 + d2 * u
	return (closestP - closestQ).Magnitude, s
end

ProjectileSim.segmentSegmentDistance = segmentSegmentDistance

--------------------------------------------------------------------------------
-- Stepping
--------------------------------------------------------------------------------

--[[
	Advances every live projectile by dt and returns everything that resolved
	this step. Targets are the snapshots to test against; the caller supplies
	them already rewound for lag compensation where that applies.

	Resolution order inside a step is strictly earliest-first along the segment,
	so a ball that would clip a bunker before reaching a bot hits the bunker.
]]
function ProjectileSim.step(self: Sim, dt: number, t: number, targets: { Target }): { HitEvent }
	local events: { HitEvent } = {}
	local survivors: { Projectile } = {}

	for _, projectile in ipairs(self.projectiles) do
		local from = projectile.position
		local newPos, newVel = Ballistics.step(from, projectile.velocity, dt, projectile.spec)
		local stepLength = (newPos - from).Magnitude

		local bestS = math.huge
		local bestEvent: HitEvent? = nil

		for _, target in ipairs(targets) do
			if not target.alive or target.team == projectile.team or target.id == projectile.ownerId then
				continue
			end
			local axisBottom = target.position
			local axisTop = target.position + Vector3.new(0, target.height, 0)
			local distance, s = segmentSegmentDistance(from, newPos, axisBottom, axisTop)
			if distance <= target.radius + self.ballRadius and s < bestS then
				bestS = s
				bestEvent = {
					projectile = projectile,
					kind = "target",
					targetId = target.id,
					position = from:Lerp(newPos, s),
					t = t + dt * s,
					distance = projectile.distanceTravelled + stepLength * s,
				}
			end
		end

		local worldHit = MapGeometry.cast(self.world, from, newPos, { ignoreConcealment = true })
		if worldHit then
			local s = if stepLength > 1e-9 then worldHit.distance / stepLength else 0
			if s < bestS then
				bestS = s
				bestEvent = {
					projectile = projectile,
					kind = "world",
					targetId = nil,
					position = worldHit.position,
					t = t + dt * s,
					distance = projectile.distanceTravelled + worldHit.distance,
				}
			end
		end

		if bestEvent then
			table.insert(events, bestEvent :: HitEvent)
			continue
		end

		projectile.position = newPos
		projectile.velocity = newVel
		projectile.distanceTravelled += stepLength

		local age = t + dt - projectile.bornAt
		if age >= self.options.maxFlightTime or projectile.distanceTravelled >= self.options.maxRange then
			table.insert(events, {
				projectile = projectile,
				kind = "expired",
				targetId = nil,
				position = newPos,
				t = t + dt,
				distance = projectile.distanceTravelled,
			})
			continue
		end

		table.insert(survivors, projectile)
	end

	self.projectiles = survivors
	return events
end

function ProjectileSim.liveCount(self: Sim): number
	return #self.projectiles
end

function ProjectileSim.clear(self: Sim)
	self.projectiles = {}
end

return ProjectileSim
