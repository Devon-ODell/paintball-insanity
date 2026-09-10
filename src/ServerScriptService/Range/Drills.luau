--!strict
--[[
	Drills -- deterministic target schedules for the Range.

	A drill is a seeded list of target appearances. Generating the whole schedule
	up front rather than spawning reactively is what makes a drill score
	reproducible: the same seed presents the same targets in the same order, so
	two runs differ only by how the player shot at them.

	All timing, distance and speed data comes from Data/range.json.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Rng = require(ReplicatedStorage.Shared.Rng)

local Drills = {}

export type Target = {
	id: string,
	spawnAt: number,
	expiresAt: number,
	--- Position at spawn, in metres, relative to the firing line.
	position: Vector3,
	velocity: Vector3,
	radius: number,
	--- The known angle this target will appear at, for the Peek drill.
	announcedBearingDeg: number?,
}

export type Schedule = {
	drill: string,
	fundamental: string,
	durationSeconds: number,
	targets: { Target },
}

--[[
	A target position in FIRING-LINE LOCAL space.

	The convention is Roblox's own object space: -Z is forward, +X is the
	shooter's right, +Y is up. That is exactly what `CFrame.lookAt` produces, so
	`Drills.worldFrame() * position` is the whole local-to-world transform and
	there is nowhere else for the two spaces to drift apart.

	Getting this wrong is not a cosmetic error. The live Range once used these
	numbers as world coordinates while standing the player at z=-40 facing +Z,
	which put the 50 m holdover target ten metres BEHIND the shooter and the
	far strafe lane outside the floor entirely -- and a scripted shooter that
	solves against the same wrong numbers cannot see it.
]]
local function bearingPosition(bearingDeg: number, distance: number, height: number): Vector3
	local a = math.rad(bearingDeg)
	return Vector3.new(math.sin(a) * distance, height, -math.cos(a) * distance)
end

Drills.bearingPosition = bearingPosition

export type Frame = {
	origin: Vector3,
	--- Unit vector the shooter faces, horizontal.
	forward: Vector3,
	--- Unit vector to the shooter's right, horizontal.
	right: Vector3,
}

--[[
	The one local-to-world boundary.

	Anything that places a drill target in the running world -- geometry, the
	projectile sim, shot measurement -- goes through this. Pure consumers
	(SimDrill, the specs) work in local space with the shooter at the origin,
	where a target's distance from the muzzle is just its magnitude.

	Spelled out as basis vectors rather than `CFrame.lookAt` on purpose. This is
	the transform that decides whether a target is in front of the player at
	all, and the headless harness's CFrame is not the engine's -- Lune's
	`lookAt` returns an identity rotation for this very firing line. A
	transform whose correctness cannot be checked by the gates is a transform
	that will be wrong again. Basis vectors are the same arithmetic everywhere.

	`right = forward x up` reproduces Roblox's own object space, where the
	identity CFrame looks down -Z with +X to the right -- so a positive
	`bearingDeg` is to the shooter's right, which is what the Peek cue promises.
]]
function Drills.worldFrame(): Frame
	local line = Config.require("range", "firingLine")
	local origin = Vector3.new(line.position[1], line.position[2], line.position[3])
	local toward = Vector3.new(line.lookAt[1], line.lookAt[2], line.lookAt[3])
	local flat = Vector3.new(toward.X - origin.X, 0, toward.Z - origin.Z)
	if flat.Magnitude < 1e-6 then
		error("range firingLine.lookAt is the firing line itself; there is no forward", 2)
	end
	local forward = flat.Unit
	return {
		origin = origin,
		forward = forward,
		right = forward:Cross(Vector3.new(0, 1, 0)),
	}
end

--- A firing-line-local position in world metres.
function Drills.toWorld(frame: Frame, position: Vector3): Vector3
	return frame.origin
		+ frame.right * position.X
		+ Vector3.new(0, position.Y, 0)
		- frame.forward * position.Z
end

--- A firing-line-local direction or velocity in world axes. No translation.
function Drills.rotateToWorld(frame: Frame, direction: Vector3): Vector3
	return frame.right * direction.X
		+ Vector3.new(0, direction.Y, 0)
		- frame.forward * direction.Z
end

--------------------------------------------------------------------------------

local function popup(cfg: any, rng: Rng.Generator, chestHeight: number): { Target }
	local targets: { Target } = {}
	local t = cfg.spawnIntervalSeconds.min
	local index = 0
	while t < cfg.durationSeconds do
		index += 1
		local bearing = rng:nextRange(-cfg.bearingSpreadDeg / 2, cfg.bearingSpreadDeg / 2)
		local distance = rng:nextRange(cfg.distanceMetres.min, cfg.distanceMetres.max)
		table.insert(targets, {
			id = `popup{index}`,
			spawnAt = t,
			expiresAt = t + cfg.targetLifetimeSeconds,
			position = bearingPosition(bearing, distance, chestHeight),
			velocity = Vector3.zero,
			radius = 0.35,
		})
		t += rng:nextRange(cfg.spawnIntervalSeconds.min, cfg.spawnIntervalSeconds.max)
	end
	return targets
end

local function strafe(cfg: any, rng: Rng.Generator, chestHeight: number): { Target }
	local targets: { Target } = {}
	local t = 0
	local index = 0
	for _, wave in ipairs(cfg.waves) do
		local waveEnd = t + wave.seconds
		while t < waveEnd do
			index += 1
			-- Alternate direction so the player cannot pre-lead one way.
			local direction = if rng:nextNumber() < 0.5 then 1 else -1
			local crossing = cfg.trackWidthMetres / wave.lateralSpeedMps
			table.insert(targets, {
				id = `strafe{index}`,
				spawnAt = t,
				expiresAt = t + crossing,
				position = bearingPosition(0, wave.distanceMetres, chestHeight)
					+ Vector3.new(-direction * cfg.trackWidthMetres / 2, 0, 0),
				velocity = Vector3.new(direction * wave.lateralSpeedMps, 0, 0),
				radius = 0.35,
			})
			t += crossing
		end
		t = waveEnd
	end
	return targets
end

--[[
	Switch -- three targets alive, always.

	`simultaneousTargets` is the drill's whole premise: the player is choosing
	which of a fixed set to shoot next, and the cost being measured is the swing
	between them. It used to be authored as three LANES that each accumulated a
	new target every 3.35 s and expired none of them until the drill ended, so a
	player who fired nothing faced 54 targets at 59 s and a player who hit
	everything got replacements unrelated to what they had just eliminated.

	One lane, one live target: each target expires exactly when its lane's
	replacement appears. The population is therefore bounded at
	`simultaneousTargets` by construction, deterministically, and the live Range
	needs no reactive spawner to agree with the pure schedule.
]]
local function switch(cfg: any, rng: Rng.Generator, chestHeight: number): { Target }
	local targets: { Target } = {}
	local index = 0
	local dwell = cfg.respawnDelaySeconds + 3.0
	for lane = 1, cfg.simultaneousTargets do
		local t = 0
		while t < cfg.durationSeconds do
			index += 1
			local base = (lane - 1) * cfg.minSeparationDeg - cfg.minSeparationDeg
			local bearing = base + rng:nextRange(-6, 6)
			local distance = rng:nextRange(cfg.distanceMetres.min, cfg.distanceMetres.max)
			table.insert(targets, {
				id = `switch{index}`,
				spawnAt = t,
				expiresAt = math.min(t + dwell, cfg.durationSeconds),
				position = bearingPosition(bearing, distance, chestHeight),
				velocity = Vector3.zero,
				radius = 0.35,
			})
			t += dwell
		end
	end
	table.sort(targets, function(a, b)
		return a.spawnAt < b.spawnAt
	end)
	return targets
end

local function holdover(cfg: any, _: Rng.Generator, chestHeight: number): { Target }
	local targets: { Target } = {}
	local index = 0
	local perRound = cfg.durationSeconds / (#cfg.staticDistancesMetres * cfg.roundsPerDistance)
	local t = 0
	for _, distance in ipairs(cfg.staticDistancesMetres) do
		for _ = 1, cfg.roundsPerDistance do
			index += 1
			table.insert(targets, {
				id = `holdover{index}`,
				spawnAt = t,
				expiresAt = t + perRound,
				position = bearingPosition(0, distance, chestHeight),
				velocity = Vector3.zero,
				radius = cfg.targetRadiusMetres,
			})
			t += perRound
		end
	end
	return targets
end

local function peek(cfg: any, rng: Rng.Generator, chestHeight: number): { Target }
	local targets: { Target } = {}
	local index = 0
	local t = 0
	-- A small set of KNOWN angles. The whole drill is about having the crosshair
	-- already there, so the angles must be learnable.
	local angles = {}
	for i = 1, cfg.knownAngleCount do
		angles[i] = -30 + (i - 1) * (60 / math.max(1, cfg.knownAngleCount - 1))
	end
	while t < cfg.durationSeconds do
		index += 1
		local bearing = angles[rng:nextInt(1, #angles)]
		local distance = rng:nextRange(cfg.distanceMetres.min, cfg.distanceMetres.max)
		local delay = rng:nextRange(cfg.revealDelaySeconds.min, cfg.revealDelaySeconds.max)
		t += delay
		table.insert(targets, {
			id = `peek{index}`,
			spawnAt = t,
			expiresAt = t + cfg.targetLifetimeSeconds,
			position = bearingPosition(bearing, distance, chestHeight),
			velocity = Vector3.zero,
			radius = 0.35,
			announcedBearingDeg = bearing,
		})
		t += cfg.targetLifetimeSeconds
	end
	return targets
end

local GENERATORS: { [string]: (any, Rng.Generator, number) -> { Target } } = {
	popup = popup,
	strafe = strafe,
	switch = switch,
	holdover = holdover,
	peek = peek,
}

--- Builds the full schedule for a drill. Same seed, same schedule, always.
function Drills.schedule(drillId: string, seed: number): Schedule
	local cfg = Config.require("range", "drills." .. drillId)
	local generator = GENERATORS[drillId]
	if not generator then
		error(`unknown drill '{drillId}'`, 2)
	end
	local chestHeight = Config.require("ballistics", "hitbox.chestHeightMetres")
	--[[
		Nothing appears after the whistle.

		Peek in particular could schedule a reveal past `durationSeconds`
		because it advances its clock by the reveal delay before placing the
		target. A target that spawns after the drill is over can never be
		engaged, so counting it as a missed opportunity is a lie about the
		player; and one whose lifetime runs past the end kept the live Range
		waiting. Both are clamped here, once, for every generator.
	]]
	local raw = generator(cfg, Rng.new(seed), chestHeight)
	local targets: { Target } = {}
	for _, target in ipairs(raw) do
		if target.spawnAt < cfg.durationSeconds then
			target.expiresAt = math.min(target.expiresAt, cfg.durationSeconds)
			table.insert(targets, target)
		end
	end
	return {
		drill = drillId,
		fundamental = cfg.fundamental,
		durationSeconds = cfg.durationSeconds,
		targets = targets,
	}
end

--- Targets live at time `t`, with their positions advanced by their velocity.
function Drills.activeAt(schedule: Schedule, t: number): { Target }
	local out: { Target } = {}
	for _, target in ipairs(schedule.targets) do
		if t >= target.spawnAt and t < target.expiresAt then
			table.insert(out, {
				id = target.id,
				spawnAt = target.spawnAt,
				expiresAt = target.expiresAt,
				position = target.position + target.velocity * (t - target.spawnAt),
				velocity = target.velocity,
				radius = target.radius,
				announcedBearingDeg = target.announcedBearingDeg,
			})
		end
	end
	return out
end

function Drills.list(): { string }
	return Config.require("range", "drillOrder")
end

return Drills
