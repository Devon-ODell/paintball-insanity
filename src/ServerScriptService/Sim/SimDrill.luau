--!strict
--[[
	SimDrill -- runs a Range drill headless against a scripted policy.

	Phase 7 acceptance needs two things: a drill score reproducible under the sim
	harness, and drill scores that correlate with the matching match-telemetry
	axis. Both require the drill to be runnable without a player, which is what
	this is.

	It reuses ShotMeasure, so a drill shot is measured by exactly the same code
	as a match shot. That is the whole point -- otherwise the ratings would not
	be comparable and the prescription loop would be a lie.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local Rng = require(ReplicatedStorage.Shared.Rng)
local AimModel = require(script.Parent.Parent.Bots.AimModel)

local Server = script.Parent.Parent
local Drills = require(Server.Range.Drills)
local DrillScoring = require(Server.Range.DrillScoring)

local SimDrill = {}

export type Options = {
	drill: string,
	seed: number,
	--- How much of the correct lead solution the simulated player applies.
	leadAccuracy: number?,
	--- Angular error, 1 sigma, in degrees.
	sigmaDeg: number?,
	reactionSeconds: number?,
	--- Degrees the crosshair sits away from a target at the moment it appears.
	crosshairOffsetDeg: number?,
	marker: string?,
}

--[[
	Runs the drill.

	The simulated player fires once per target, after its reaction time, with the
	configured lead accuracy and angular error. Firing once per target rather
	than spraying is what keeps the measurement about aim rather than about rate
	of fire -- the drills grade prediction, not trigger discipline.
]]
function SimDrill.run(options: Options): DrillScoring.Result
	local ballisticsData = Config.get("ballistics")
	local markerData = Config.require("markers", "markers." .. (options.marker or "mechanical"))
	local spec = Ballistics.specFromMarker(markerData, ballisticsData)
	local hitbox = ballisticsData.hitbox

	local leadAccuracy = options.leadAccuracy or 1
	local sigma = options.sigmaDeg or 0
	local reaction = options.reactionSeconds or 0.25
	local crosshairOffset = options.crosshairOffsetDeg or 0

	local schedule = Drills.schedule(options.drill, options.seed)
	local rng = Rng.new(options.seed * 7919 + 13)
	local origin = Vector3.new(0, hitbox.chestHeightMetres, 0)

	local events: { DrillScoring.ShotEvent } = {}
	--- Mirrors the live Range: the swing between eliminations, measured from
	--- the start of the drill for the first one.
	local lastEliminationAt: number? = nil

	for _, target in ipairs(schedule.targets) do
		local fireAt = target.spawnAt + reaction
		if fireAt >= target.expiresAt then
			-- Too slow: the target came and went. That is a miss, and it must
			-- still be recorded or slow play would score the same as no play.
			-- It is not a trigger pull, so it is not a shot.
			table.insert(events, {
				t = target.expiresAt,
				hit = false,
				kind = "expired",
				targetId = target.id,
				timeToAcquireMs = (target.expiresAt - target.spawnAt) * 1000,
			})
			continue
		end

		local position = target.position + target.velocity * (fireAt - target.spawnAt)
		local perfect = Ballistics.solveLead(spec, origin, position, target.velocity)
		if not perfect then
			continue
		end

		local intended = position:Lerp(perfect :: Vector3, leadAccuracy)
		local direction = (intended - origin).Unit
		if sigma > 0 then
			direction = AimModel.rotate(direction, rng:nextGaussian() * sigma, rng:nextGaussian() * sigma)
		end

		local range = ((perfect :: Vector3) - origin).Magnitude
		local actualAimPoint = origin + direction * range

		local leadError = Ballistics.signedLeadError(origin, actualAimPoint, perfect :: Vector3, target.velocity)
		local holdoverError = Ballistics.signedHoldoverError(actualAimPoint, perfect :: Vector3)
		local angularError = Ballistics.angularErrorDeg(direction, ((perfect :: Vector3) - origin).Unit)

		-- Did the ball actually mark the target? Measured against the closest
		-- approach of the real flight, not against the aim error.
		local closest = math.huge
		Ballistics.integrate(origin, direction, spec, {
			fixedStep = 1 / 240,
			maxFlightTime = 3,
			maxRange = 150,
		}, function(seg)
			local now = target.position + target.velocity * ((fireAt - target.spawnAt) + seg.tEnd)
			local d = (seg.to - now).Magnitude
			if d < closest then
				closest = d
			end
			return seg.tEnd > 2
		end)

		local hit = closest <= target.radius
		local sinceLastElimination: number? = nil
		if hit then
			sinceLastElimination = (fireAt - (lastEliminationAt or 0)) * 1000
			lastEliminationAt = fireAt
		end

		table.insert(events, {
			t = fireAt,
			hit = hit,
			kind = "shot",
			targetId = target.id,
			timeToAcquireMs = reaction * 1000,
			timeBetweenEliminationsMs = sinceLastElimination,
			angularErrorDeg = angularError,
			leadErrorM = leadError,
			holdoverErrorM = holdoverError,
			crosshairOffsetDegAtReveal = crosshairOffset,
		})
	end

	return DrillScoring.score(options.drill, events)
end

return SimDrill
