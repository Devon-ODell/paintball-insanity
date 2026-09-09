--!strict
--[[
	Ballistics -- pure projectile math. No Roblox services, no Instances, no
	global state. Everything here is unit-testable and everything here runs
	identically on the server, on the client predictor, and in the headless sim.

	UNITS: metres and seconds, everywhere. The Roblox layer converts at the
	boundary via Units.luau. Do not introduce studs into this file.

	DRAG MODEL: quadratic drag, a = -k * |v| * v. Along a straight path that
	integrates to v(s) = v0 * e^(-k*s), which gives closed forms for time of
	flight and its inverse. k has units 1/m; 1/k is the distance over which the
	ball loses 1/e of its speed. The closed forms are what the lead solver and
	the HUD use because they are cheap and stable; the authoritative flight is
	integrated numerically by `integrate`. BallisticsSpec asserts the two agree.
]]

export type Spec = {
	muzzleVelocity: number, -- m/s
	dragK: number, -- 1/m
	gravity: number, -- m/s^2, positive
}

export type State = {
	position: Vector3,
	velocity: Vector3,
	elapsed: number,
	distance: number,
}

local Config = require(script.Parent.Config)

local Ballistics = {}

--[[
	How many passes the lead/aim solver takes.

	Read from Data/ballistics.json rather than written here. Both call sites had
	a literal 4 in them and the data already declared `leadSolver.iterations: 4`
	-- two places to change one tuning number, which is the second-opinion
	pattern this project keeps finding. Same value, so nothing moves.
]]
local function solverIterations(): number
	return Config.require("ballistics", "leadSolver.iterations")
end

local EPSILON = 1e-9

--------------------------------------------------------------------------------
-- Closed forms
--------------------------------------------------------------------------------

--- Speed remaining after travelling `s` metres of path.
function Ballistics.speedAfter(spec: Spec, s: number): number
	return spec.muzzleVelocity * math.exp(-spec.dragK * s)
end

--- Seconds to travel `s` metres of path.
--- Degenerates gracefully to s/v0 as dragK approaches zero.
function Ballistics.timeOfFlight(spec: Spec, s: number): number
	if s <= 0 then
		return 0
	end
	local k = spec.dragK
	if k < EPSILON then
		return s / spec.muzzleVelocity
	end
	return (math.exp(k * s) - 1) / (k * spec.muzzleVelocity)
end

--- Path distance covered in `t` seconds. Inverse of timeOfFlight.
function Ballistics.distanceAfter(spec: Spec, t: number): number
	if t <= 0 then
		return 0
	end
	local k = spec.dragK
	if k < EPSILON then
		return t * spec.muzzleVelocity
	end
	return math.log(1 + k * spec.muzzleVelocity * t) / k
end

--[[
	Gravitational drop, in metres, over a shot of `s` metres. This is the number
	the player is learning to feel, so it has to be right.

	Naive `0.5*g*t^2` over-predicts badly at range, because drag damps the
	vertical fall as well as the forward flight. Treating the vertical axis as
	linearly damped at rate b = k * (average path speed) gives

	    drop = (g/b) * (t - (1 - e^(-b*t)) / b)

	and since b*t collapses to exactly k*s, that reduces to the form below with
	u = k*s. It agrees with the RK4 integration to under 1% at every distance
	the game uses, where the naive form is off by 20% at 50 m.
]]
function Ballistics.dropAt(spec: Spec, s: number): number
	local t = Ballistics.timeOfFlight(spec, s)
	local u = spec.dragK * s
	if u < 1e-6 then
		return 0.5 * spec.gravity * t * t
	end
	return (spec.gravity * t * t / u) * (1 - (1 - math.exp(-u)) / u)
end

--- Lateral lead, in metres, required against a target crossing at
--- `lateralSpeed` m/s at `s` metres. The other number the player is learning.
function Ballistics.leadAt(spec: Spec, s: number, lateralSpeed: number): number
	return lateralSpeed * Ballistics.timeOfFlight(spec, s)
end

--------------------------------------------------------------------------------
-- Aiming
--------------------------------------------------------------------------------

--[[
	Launch direction that puts the ball through `target` from `origin`.

	Solves superelevation by fixed-point iteration: guess a time of flight,
	raise the aim point by the drop over that time, re-measure, repeat. Four
	iterations converges to well under a centimetre at every distance the game
	uses. Returns a unit direction plus the time of flight it solved for.

	Returns nil when the target is beyond the marker's reach -- the iteration
	diverges rather than returning a wrong answer, and callers must handle it.
]]
function Ballistics.aimDirection(
	spec: Spec,
	origin: Vector3,
	target: Vector3,
	iterations: number?
): (Vector3?, number)
	local iters = iterations or solverIterations()
	local aim = target
	local tof = 0
	for _ = 1, iters do
		local delta = aim - origin
		local s = delta.Magnitude
		if s < EPSILON then
			return nil, 0
		end
		-- Beyond this the exponential blows up and there is no solution.
		if spec.dragK > EPSILON and spec.dragK * s >= 30 then
			return nil, math.huge
		end
		tof = Ballistics.timeOfFlight(spec, s)
		aim = target + Vector3.new(0, Ballistics.dropAt(spec, s), 0)
	end
	local dir = aim - origin
	if dir.Magnitude < EPSILON then
		return nil, 0
	end
	return dir.Unit, tof
end

--[[
	solveLead -- where to put the crosshair on a target that is moving.

	Fixed-point iteration on time of flight against the target's projected
	position under constant velocity. This is the function the bots call, scaled
	by their tier's `leadSolutionAccuracy`; the player has to run it in their head.

	Returns the world-space aim point (already including gravity holdover) and
	the time of flight. Returns nil if no interception exists.
]]
function Ballistics.solveLead(
	spec: Spec,
	shooterPos: Vector3,
	targetPos: Vector3,
	targetVelocity: Vector3,
	iterations: number?
): (Vector3?, number)
	local iters = iterations or solverIterations()
	local t = (targetPos - shooterPos).Magnitude / spec.muzzleVelocity
	for _ = 1, iters do
		local predicted = targetPos + targetVelocity * t
		local s = (predicted - shooterPos).Magnitude
		if spec.dragK > EPSILON and spec.dragK * s >= 30 then
			return nil, math.huge
		end
		t = Ballistics.timeOfFlight(spec, s)
	end
	local intercept = targetPos + targetVelocity * t
	local dir, tof = Ballistics.aimDirection(spec, shooterPos, intercept, iters)
	if not dir then
		return nil, math.huge
	end
	-- The aim POINT is the intercept lifted by holdover, which is what
	-- aimDirection solved for; reconstruct it from the direction it returned.
	local range = (intercept - shooterPos).Magnitude
	return shooterPos + (dir :: Vector3) * range, tof
end

--------------------------------------------------------------------------------
-- Authoritative integration
--------------------------------------------------------------------------------

local function acceleration(velocity: Vector3, spec: Spec): Vector3
	local speed = velocity.Magnitude
	local drag = -spec.dragK * speed * velocity
	return drag + Vector3.new(0, -spec.gravity, 0)
end

--- One RK4 step of the true equations of motion. This is the authoritative
--- flight; the closed forms above are the cheap approximation of it.
function Ballistics.step(position: Vector3, velocity: Vector3, dt: number, spec: Spec): (Vector3, Vector3)
	local k1v = acceleration(velocity, spec)
	local k1p = velocity

	local v2 = velocity + k1v * (dt * 0.5)
	local k2v = acceleration(v2, spec)
	local k2p = v2

	local v3 = velocity + k2v * (dt * 0.5)
	local k3v = acceleration(v3, spec)
	local k3p = v3

	local v4 = velocity + k3v * dt
	local k4v = acceleration(v4, spec)
	local k4p = v4

	local newPos = position + (k1p + 2 * k2p + 2 * k3p + k4p) * (dt / 6)
	local newVel = velocity + (k1v + 2 * k2v + 2 * k3v + k4v) * (dt / 6)
	return newPos, newVel
end

export type Segment = {
	from: Vector3,
	to: Vector3,
	tStart: number,
	tEnd: number,
	speed: number,
}

--[[
	integrate -- runs a full flight and hands each swept segment to `onSegment`.

	The caller does the raycasting; this module stays free of Roblox. Return
	true from onSegment to stop the flight (something was hit).

	Returns the final state and whether the flight was stopped early.
]]
function Ballistics.integrate(
	origin: Vector3,
	direction: Vector3,
	spec: Spec,
	options: {
		fixedStep: number,
		maxFlightTime: number,
		maxRange: number,
	},
	onSegment: ((Segment) -> boolean)?
): (State, boolean)
	local pos = origin
	local vel = direction.Unit * spec.muzzleVelocity
	local elapsed = 0
	local travelled = 0
	local dt = options.fixedStep

	while elapsed < options.maxFlightTime and travelled < options.maxRange do
		local nextPos, nextVel = Ballistics.step(pos, vel, dt, spec)
		local segLength = (nextPos - pos).Magnitude
		if onSegment then
			local stop = onSegment({
				from = pos,
				to = nextPos,
				tStart = elapsed,
				tEnd = elapsed + dt,
				speed = vel.Magnitude,
			})
			if stop then
				return {
					position = nextPos,
					velocity = nextVel,
					elapsed = elapsed + dt,
					distance = travelled + segLength,
				}, true
			end
		end
		pos, vel = nextPos, nextVel
		travelled += segLength
		elapsed += dt
	end

	return { position = pos, velocity = vel, elapsed = elapsed, distance = travelled }, false
end

--------------------------------------------------------------------------------
-- Error measurement (feeds Telemetry)
--------------------------------------------------------------------------------

--- Angle in degrees between where the player aimed and the perfect solution.
function Ballistics.angularErrorDeg(aimDirection: Vector3, idealDirection: Vector3): number
	local a = aimDirection.Unit
	local b = idealDirection.Unit
	local dot = math.clamp(a:Dot(b), -1, 1)
	return math.deg(math.acos(dot))
end

--[[
	Signed lead error in metres, measured along the target's direction of travel.

	Positive means the player led TOO FAR (shot ahead of the target), negative
	means they under-led (shot behind). Separating this from angular error is the
	whole point of the telemetry: under-leading and simply missing are different
	problems with different drills.

	Returns nil when the target is not actually crossing, because lead error is
	meaningless against a target moving straight at you.
]]
function Ballistics.signedLeadError(
	shooterPos: Vector3,
	aimPoint: Vector3,
	idealAimPoint: Vector3,
	targetVelocity: Vector3
): number?
	local speed = targetVelocity.Magnitude
	if speed < 0.25 then
		return nil
	end
	local travelAxis = targetVelocity.Unit
	local toShooter = (shooterPos - idealAimPoint)
	if toShooter.Magnitude < EPSILON then
		return nil
	end
	-- Only the component of travel across the line of sight produces lead.
	local losUnit = toShooter.Unit
	local crossing = travelAxis - losUnit * travelAxis:Dot(losUnit)
	if crossing.Magnitude < 0.05 then
		return nil
	end
	return (aimPoint - idealAimPoint):Dot(crossing.Unit)
end

--- Signed vertical error in metres. Positive means the shot was aimed high.
function Ballistics.signedHoldoverError(aimPoint: Vector3, idealAimPoint: Vector3): number
	return aimPoint.Y - idealAimPoint.Y
end

--------------------------------------------------------------------------------
-- Spec construction
--------------------------------------------------------------------------------

--- Builds a Spec from a marker entry plus the global ballistics data. Kept here
--- so the shape of Data/markers.json is interpreted in exactly one place.
function Ballistics.specFromMarker(marker: any, ballisticsData: any, velocityMultiplier: number?): Spec
	return {
		muzzleVelocity = marker.muzzleVelocity * (velocityMultiplier or 1),
		dragK = marker.dragK or ballisticsData.defaultDragK,
		gravity = ballisticsData.gravity,
	}
end

return Ballistics
