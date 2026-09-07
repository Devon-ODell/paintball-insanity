--!strict
--[[
	AimModel -- how a bot decides where to point.

	Pure. Given a tier's parameters and a deterministic generator, it returns a
	direction. No wallhacks, no perfect aim, no damage multipliers: every knob
	here is something a human could match, which is the design constraint that
	makes the game's telemetry mean anything.

	The load-bearing parameter is `leadSolutionAccuracy`. It blends between two
	answers: aiming straight AT the target (what a rec player does) and the exact
	Ballistics.solveLead answer (what a pro does). Because the blend runs on the
	aim POINT, a low accuracy under-leads AND under-compensates for drop at the
	same time -- which is exactly how a bad player misses, and exactly the skill
	the player themselves is being taught.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local Rng = require(ReplicatedStorage.Shared.Rng)

local AimModel = {}

export type Tier = {
	reactionTimeMs: number,
	reactionJitterMs: number,
	aimErrorDeg: number,
	leadSolutionAccuracy: number,
	leadJitter: number,
	timeToSettleMs: number,
	crosshairPrePlacement: number,
	peekDiscipline: number,
}

--- How much wider the cone is at the instant of acquisition, before the bot has
--- settled. Settling is the bot's version of the player's stop-to-shoot rule.
local UNSETTLED_ERROR_MULTIPLIER = 3.0

--- Rotates a unit direction by yaw then pitch, both in degrees. Built from an
--- explicit basis rather than CFrame.Angles so the result is identical in the
--- headless sim and in the engine.
function AimModel.rotate(direction: Vector3, yawDeg: number, pitchDeg: number): Vector3
	local forward = direction.Unit
	local worldUp = Vector3.new(0, 1, 0)
	local right = forward:Cross(worldUp)
	if right.Magnitude < 1e-6 then
		right = Vector3.new(1, 0, 0)
	end
	right = right.Unit
	local up = right:Cross(forward).Unit

	local yaw = math.rad(yawDeg)
	local pitch = math.rad(pitchDeg)
	local rotated = forward * (math.cos(yaw) * math.cos(pitch))
		+ right * (math.sin(yaw) * math.cos(pitch))
		+ up * math.sin(pitch)
	return rotated.Unit
end

--- Fraction of full aim error still present `elapsed` seconds after acquiring.
--- 1.0 once settled, up to UNSETTLED_ERROR_MULTIPLIER at the moment of contact.
function AimModel.settleFactor(tier: Tier, elapsedSeconds: number): number
	local settle = tier.timeToSettleMs / 1000
	if settle <= 0 then
		return 1
	end
	local progress = math.clamp(elapsedSeconds / settle, 0, 1)
	return UNSETTLED_ERROR_MULTIPLIER + (1 - UNSETTLED_ERROR_MULTIPLIER) * progress
end

--- The reaction delay this bot will take on this contact, in seconds. Jitter is
--- symmetric and clamped at zero so no tier can ever react instantly.
function AimModel.reactionDelay(tier: Tier, rng: Rng.Generator): number
	local jitter = rng:nextGaussian() * (tier.reactionJitterMs / 3)
	return math.max(0, (tier.reactionTimeMs + jitter) / 1000)
end

export type SolveParams = {
	spec: Ballistics.Spec,
	origin: Vector3,
	targetPosition: Vector3,
	targetVelocity: Vector3,
	tier: Tier,
	rng: Rng.Generator,
	elapsedSinceAcquire: number,
	--- Multiplier on aim error from the squad's morale state. 1.0 when cocky.
	moraleErrorMultiplier: number?,
}

export type Solution = {
	direction: Vector3,
	--- Where the bot believes it should shoot, before random error.
	intendedAimPoint: Vector3,
	--- The exact answer, for telemetry and for tests.
	perfectAimPoint: Vector3,
	--- Fraction of the correct lead this bot actually applied, after jitter.
	appliedLeadFraction: number,
}

--[[
	Produces the direction the bot fires in.

	Returns nil when there is no ballistic solution at all -- the target is
	further than the marker can throw paint. A bot in that situation must not
	fire, and the controller relies on that nil rather than on a range constant.
]]
function AimModel.solve(params: SolveParams): Solution?
	local tier = params.tier
	local spec = params.spec

	local perfect = Ballistics.solveLead(spec, params.origin, params.targetPosition, params.targetVelocity)
	if not perfect then
		return nil
	end

	-- The naive answer: point straight at the body, no lead, no holdover.
	local naive = params.targetPosition

	local jitter = params.rng:nextGaussian() * tier.leadJitter
	local fraction = math.clamp(tier.leadSolutionAccuracy + jitter, 0, 1.35)

	local intended = naive:Lerp(perfect :: Vector3, fraction)

	local toIntended = intended - params.origin
	if toIntended.Magnitude < 1e-6 then
		return nil
	end

	local sigma = tier.aimErrorDeg
		* AimModel.settleFactor(tier, params.elapsedSinceAcquire)
		* (params.moraleErrorMultiplier or 1)

	local yaw = params.rng:nextGaussian() * sigma
	local pitch = params.rng:nextGaussian() * sigma

	return {
		direction = AimModel.rotate(toIntended.Unit, yaw, pitch),
		intendedAimPoint = intended,
		perfectAimPoint = perfect :: Vector3,
		appliedLeadFraction = fraction,
	}
end

--[[
	Where a bot rests its crosshair while it is waiting for a target.

	`crosshairPrePlacement` is how much of the way from "wherever it happened to
	be looking" to "the exact spot the enemy will appear" the bot pre-aims. A rec
	bot stares at the floor; a pro bot holds the angle. It costs the player time
	on the draw, which is the same currency the Peek drill trains.
]]
function AimModel.prePlacement(
	tier: Tier,
	currentFacing: Vector3,
	origin: Vector3,
	watchPoint: Vector3
): Vector3
	local ideal = watchPoint - origin
	if ideal.Magnitude < 1e-6 then
		return currentFacing
	end
	local blended = currentFacing.Unit:Lerp(ideal.Unit, math.clamp(tier.crosshairPrePlacement, 0, 1))
	if blended.Magnitude < 1e-6 then
		return currentFacing
	end
	return blended.Unit
end

--[[
	Whether this bot is willing to expose itself right now.

	`peekDiscipline` is the probability it waits for a reason rather than
	standing in the open. Low discipline is why rec bots feed themselves to the
	player one at a time, and it is the only thing that makes a 1v6 survivable
	at the bottom tier.
]]
function AimModel.willExpose(tier: Tier, rng: Rng.Generator, hasReason: boolean): boolean
	if hasReason then
		return true
	end
	return rng:nextNumber() > tier.peekDiscipline
end

return AimModel
