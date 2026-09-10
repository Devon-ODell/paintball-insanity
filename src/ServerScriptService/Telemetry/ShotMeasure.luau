--!strict
--[[
	ShotMeasure -- turns one fired shot into a telemetry record.

	This is where the aim trainer actually lives. Given where the player aimed
	and where the perfect solution was, it separates the error into its
	components: how far off the angle was, how much of the miss was lead, and how
	much was drop. Those are three different problems with three different drills
	and no other trainer distinguishes them well.

	Pure. The live server and the sim both call it, so a drill score and a match
	score are measured by the same ruler -- which is the only reason the
	post-match prescription can point at a drill and mean it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)

local ShotMeasure = {}

export type Candidate = {
	id: string,
	position: Vector3,
	velocity: Vector3,
	--- When this target first became visible to the shooter, or nil if it is not.
	visibleSince: number?,
}

export type Input = {
	t: number,
	origin: Vector3,
	direction: Vector3,
	spec: Ballistics.Spec,
	stance: Types.Stance,
	--- Aim direction on the previous shot, for the flick measurement.
	previousDirection: Vector3?,
	candidates: { Candidate },
	--- Chest offset used to aim at a target's centre of mass.
	aimHeight: number,
	--[[
		Where the crosshair actually pointed at a given time, if the caller
		keeps that history. Supplying it is what turns crosshair placement from
		an inference into a measurement -- see `crosshairOffsetApproximated`.
	]]
	aimAt: ((number) -> Vector3?)?,
}

--[[
	Picks the target the shot was aimed at.

	Smallest angle between the shot and the target's centre of mass, and only
	within a generous cone -- a shot fired at nothing should measure nothing
	rather than being attributed to whichever bot happened to be closest to the
	crosshair across the map.
]]
local MAX_ATTRIBUTION_DEG = 25

function ShotMeasure.attribute(input: Input): (Candidate?, number)
	local best: Candidate? = nil
	local bestAngle = MAX_ATTRIBUTION_DEG
	for _, candidate in ipairs(input.candidates) do
		local aimPoint = candidate.position + Vector3.new(0, input.aimHeight, 0)
		local toTarget = aimPoint - input.origin
		if toTarget.Magnitude < 1e-6 then
			continue
		end
		local angle = Ballistics.angularErrorDeg(input.direction, toTarget)
		if angle < bestAngle then
			bestAngle = angle
			best = candidate
		end
	end
	return best, bestAngle
end

export type Measurement = {
	targetId: string?,
	distance: number,
	angularErrorDeg: number,
	leadErrorM: number?,
	holdoverErrorM: number?,
	targetLateralSpeed: number,
	timeToAcquireMs: number?,
	targetVisibleMsBeforeShot: number?,
	crosshairOffsetDegAtReveal: number?,
	--[[
		True when the offset above came from the previous shot's direction
		rather than from where the crosshair really was at reveal.

		It carries a lot: on a drill whose angles are sixty degrees apart, the
		approximation reports roughly the swing between shots no matter how well
		the player was parked. Anything that reports a crosshair-placement
		rating to a player, or prescribes a drill from one, should say so or
		decline to score it.
	]]
	crosshairOffsetApproximated: boolean?,
	priorAimSwingDeg: number?,
}

--[[
	Measures a shot against the perfect solution for its attributed target.

	Returns nil when the shot cannot be attributed to any target -- spray at a
	wall is not evidence about anything, and counting it would drag every score
	toward the mean.
]]
function ShotMeasure.measure(input: Input): Measurement?
	local target = ShotMeasure.attribute(input)
	if not target then
		return nil
	end

	local aimPoint = (target :: Candidate).position + Vector3.new(0, input.aimHeight, 0)
	local distance = (aimPoint - input.origin).Magnitude

	local perfect = Ballistics.solveLead(
		input.spec,
		input.origin,
		aimPoint,
		(target :: Candidate).velocity
	)
	if not perfect then
		return nil
	end

	local idealDirection = ((perfect :: Vector3) - input.origin).Unit
	local angularError = Ballistics.angularErrorDeg(input.direction, idealDirection)

	-- Project the actual shot out to the same range as the ideal aim point, so
	-- lead and holdover errors are measured in metres at the target's distance.
	local perfectRange = ((perfect :: Vector3) - input.origin).Magnitude
	local actualAimPoint = input.origin + input.direction.Unit * perfectRange

	local velocity = (target :: Candidate).velocity
	local toTarget = aimPoint - input.origin
	local losUnit = if toTarget.Magnitude > 1e-6 then toTarget.Unit else Vector3.new(0, 0, 1)
	local lateral = velocity - losUnit * velocity:Dot(losUnit)

	local leadError = Ballistics.signedLeadError(input.origin, actualAimPoint, perfect :: Vector3, velocity)
	local holdoverError = Ballistics.signedHoldoverError(actualAimPoint, perfect :: Vector3)

	local visibleMs: number? = nil
	if (target :: Candidate).visibleSince then
		visibleMs = (input.t - ((target :: Candidate).visibleSince :: number)) * 1000
	end

	local swing: number? = nil
	if input.previousDirection then
		swing = Ballistics.angularErrorDeg(input.direction, input.previousDirection :: Vector3)
	end

	--[[
		Crosshair placement: how far off was the crosshair at the moment the
		target became visible?

		Answered from real aim history where the caller keeps it, which is the
		only spelling that measures the question being asked. The previous
		shot's direction is the fallback, and it is a poor one -- it reports
		roughly the swing between two shots, so a player parked exactly on a
		known reveal angle still reads as far off if their last shot went
		somewhere else. Flagged, rather than quietly presented as the same
		number, because the post-match prescription reads it.
	]]
	local crosshairOffset: number? = nil
	local crosshairApproximated: boolean? = nil
	if visibleMs then
		local revealAim: Vector3? = nil
		if input.aimAt then
			local revealAt = input.t - (visibleMs :: number) / 1000
			revealAim = (input.aimAt :: (number) -> Vector3?)(revealAt)
		end
		if revealAim then
			crosshairOffset = Ballistics.angularErrorDeg(revealAim :: Vector3, toTarget)
			crosshairApproximated = false
		elseif input.previousDirection then
			crosshairOffset = Ballistics.angularErrorDeg(input.previousDirection :: Vector3, toTarget)
			crosshairApproximated = true
		end
	end

	return {
		targetId = (target :: Candidate).id,
		distance = distance,
		angularErrorDeg = angularError,
		leadErrorM = leadError,
		holdoverErrorM = holdoverError,
		targetLateralSpeed = lateral.Magnitude,
		timeToAcquireMs = visibleMs,
		targetVisibleMsBeforeShot = visibleMs,
		crosshairOffsetDegAtReveal = crosshairOffset,
		crosshairOffsetApproximated = crosshairApproximated,
		priorAimSwingDeg = swing,
	}
end

return ShotMeasure
