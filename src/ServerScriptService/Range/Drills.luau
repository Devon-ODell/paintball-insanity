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

local function bearingPosition(bearingDeg: number, distance: number, height: number): Vector3
	local a = math.rad(bearingDeg)
	return Vector3.new(math.sin(a) * distance, height, -math.cos(a) * distance)
end

Drills.bearingPosition = bearingPosition

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

local function switch(cfg: any, rng: Rng.Generator, chestHeight: number): { Target }
	local targets: { Target } = {}
	local index = 0
	-- Three targets live at once; each is replaced shortly after its lifetime.
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
				expiresAt = cfg.durationSeconds,
				position = bearingPosition(bearing, distance, chestHeight),
				velocity = Vector3.zero,
				radius = 0.35,
			})
			t += cfg.respawnDelaySeconds + 3.0
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
	return {
		drill = drillId,
		fundamental = cfg.fundamental,
		durationSeconds = cfg.durationSeconds,
		targets = generator(cfg, Rng.new(seed), chestHeight),
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
