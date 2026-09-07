--!nolint
--[[
	Phase 1 acceptance.

	Two things must hold or nothing downstream matters:
	  1. The cheap closed forms agree with the authoritative numeric integration.
	  2. solveLead, fed back into that integration, actually hits a moving target.

	The second is the only honest way to know the solver is right: test it
	against the simulation it is approximating, not against hand-copied numbers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Ballistics = require(Shared.Ballistics)
local BallisticsData = require(ReplicatedStorage.Data.ballistics)
local Markers = require(ReplicatedStorage.Data.markers)

local function specFor(name: string): Ballistics.Spec
	return Ballistics.specFromMarker(Markers.markers[name], BallisticsData)
end

local SIM = {
	fixedStep = 1 / 480, -- finer than gameplay so the spec measures the math, not the step
	maxFlightTime = 6,
	maxRange = 200,
}

--- Fires along `direction` and returns the state at the instant the ball's
--- horizontal travel reaches `horizontalMetres`, interpolated inside the step
--- so the measurement is not quantised by the integrator's step length.
local function flightToRange(spec: Ballistics.Spec, origin: Vector3, direction: Vector3, horizontalMetres: number)
	local captured = nil
	local function flatOf(p: Vector3): number
		return Vector3.new(p.X - origin.X, 0, p.Z - origin.Z).Magnitude
	end
	Ballistics.integrate(origin, direction, spec, SIM, function(seg)
		local flatTo = flatOf(seg.to)
		if flatTo >= horizontalMetres then
			local flatFrom = flatOf(seg.from)
			local span = flatTo - flatFrom
			local alpha = if span > 1e-9 then (horizontalMetres - flatFrom) / span else 0
			captured = {
				position = seg.from:Lerp(seg.to, alpha),
				time = seg.tStart + (seg.tEnd - seg.tStart) * alpha,
			}
			return true
		end
		return false
	end)
	return captured
end

return function()
	describe("closed forms", function()
		it("inverts distance and time exactly", function()
			local spec = specFor("mechanical")
			for _, d in ipairs({ 1, 10, 25, 40, 50, 80 }) do
				local t = Ballistics.timeOfFlight(spec, d)
				expect(Ballistics.distanceAfter(spec, t)).to.be.near(d, 1e-6)
			end
		end)

		it("bleeds speed at the configured rate", function()
			local spec = specFor("mechanical")
			-- One drag length must leave exactly 1/e of muzzle velocity.
			local oneDragLength = 1 / spec.dragK
			expect(Ballistics.speedAfter(spec, oneDragLength))
				.to.be.near(spec.muzzleVelocity / math.exp(1), 1e-6)
		end)

		it("degenerates to constant velocity when drag is zero", function()
			local spec = { muzzleVelocity = 100, dragK = 0, gravity = 9.81 }
			expect(Ballistics.timeOfFlight(spec, 50)).to.be.near(0.5, 1e-9)
			expect(Ballistics.distanceAfter(spec, 0.5)).to.be.near(50, 1e-9)
		end)
	end)

	describe("drop", function()
		local spec = specFor("mechanical")
		local targets = BallisticsData._designTargets

		it("is negligible at 10 m", function()
			local drop = Ballistics.dropAt(spec, 10)
			expect(drop).to.be.near(targets.dropAt10mMetres, 0.002)
			-- "Negligible" has to mean something: less than a hand's width.
			expect(drop).to.be.within(0, 0.10)
		end)

		it("is visible holdover at 40 m", function()
			local drop = Ballistics.dropAt(spec, 40)
			expect(drop).to.be.near(targets.dropAt40mMetres, 0.01)
			-- Between a third and a whole body height: you must aim over them,
			-- but not off the top of the screen.
			expect(drop).to.be.within(0.5, 1.1)
		end)

		it("grows monotonically with distance", function()
			local previous = -1
			for d = 5, 60, 5 do
				local drop = Ballistics.dropAt(spec, d)
				expect(drop > previous).to.equal(true)
				previous = drop
			end
		end)

		it("matches the numeric integration at 10, 25 and 50 m", function()
			-- Fire dead flat, measure where the ball actually is, compare to the
			-- closed form. This is the check that the approximation is honest.
			local origin = Vector3.new(0, 0, 0)
			local flat = Vector3.new(0, 0, -1)
			for _, d in ipairs({ 10, 25, 50 }) do
				local hit = flightToRange(spec, origin, flat, d)
				expect(hit).to.be.ok()
				local simulatedDrop = -(hit :: any).position.Y
				local closedForm = Ballistics.dropAt(spec, d)
				-- The damped closed form should track RK4 to within 2%. If this
				-- ever loosens, the HUD holdover readout is lying to the player.
				expect(simulatedDrop).to.be.near(closedForm, closedForm * 0.02 + 0.005)
			end
		end)
	end)

	describe("lead", function()
		local spec = specFor("mechanical")
		local targets = BallisticsData._designTargets
		local bodyWidth = BallisticsData.hitbox.bodyWidthMetres

		it("requires the designed lead against a sprinter at 40 m", function()
			local lead = Ballistics.leadAt(spec, 40, targets.sprintSpeedMps)
			local bodyWidths = lead / bodyWidth
			expect(bodyWidths).to.be.near(targets.leadAt40mBodyWidths, 0.05)
		end)

		it("is small at 10 m", function()
			local lead = Ballistics.leadAt(spec, 10, targets.sprintSpeedMps)
			expect(lead / bodyWidth).to.be.within(0, 1.2)
		end)

		it("scales with target speed", function()
			expect(Ballistics.leadAt(spec, 30, 8)).to.be.near(Ballistics.leadAt(spec, 30, 4) * 2, 1e-9)
		end)
	end)

	describe("aimDirection", function()
		it("puts the ball on a static target at every gameplay distance", function()
			local spec = specFor("mechanical")
			local origin = Vector3.new(0, 1.5, 0)
			for _, d in ipairs({ 5, 10, 20, 30, 40, 55, 70 }) do
				local target = Vector3.new(0, 1.3, -d)
				local dir = Ballistics.aimDirection(spec, origin, target)
				expect(dir).to.be.ok()
				local hit = flightToRange(spec, origin, dir :: Vector3, d)
				expect(hit).to.be.ok()
				local miss = ((hit :: any).position - target).Magnitude
				-- Must land inside a paintball's width of the aim point.
				expect(miss).to.be.within(0, 0.12)
			end
		end)

		it("refuses targets past the marker's reach instead of guessing", function()
			local spec = specFor("mechanical")
			local dir = Ballistics.aimDirection(spec, Vector3.new(0, 0, 0), Vector3.new(0, 0, -5000))
			expect(dir).to.equal(nil)
		end)
	end)

	describe("solveLead", function()
		--[[
			The acceptance test named in BUILD_PLAN Phase 1: feed the solver's
			answer back into the simulation and confirm it intercepts.
		]]
		local function interceptMiss(markerName: string, distance: number, targetVel: Vector3): number
			local spec = specFor(markerName)
			local origin = Vector3.new(0, 1.5, 0)
			local targetStart = Vector3.new(0, 1.3, -distance)

			local aimPoint = Ballistics.solveLead(spec, origin, targetStart, targetVel)
			assert(aimPoint, "solver returned no solution")

			local dir = ((aimPoint :: Vector3) - origin).Unit

			-- Fly the ball and the target forward together; report closest approach.
			local closest = math.huge
			Ballistics.integrate(origin, dir, spec, SIM, function(seg)
				local targetNow = targetStart + targetVel * seg.tEnd
				local d = (seg.to - targetNow).Magnitude
				if d < closest then
					closest = d
				end
				return seg.tEnd > 3
			end)
			return closest
		end

		it("intercepts a target crossing at 6 m/s from 10 to 55 m", function()
			for _, d in ipairs({ 10, 20, 30, 40, 55 }) do
				local miss = interceptMiss("mechanical", d, Vector3.new(6, 0, 0))
				expect(miss).to.be.within(0, 0.15)
			end
		end)

		it("intercepts a target closing and crossing at once", function()
			local miss = interceptMiss("mechanical", 35, Vector3.new(4.5, 0, 4.5))
			expect(miss).to.be.within(0, 0.15)
		end)

		it("intercepts a target retreating", function()
			local miss = interceptMiss("mechanical", 25, Vector3.new(2, 0, -5))
			expect(miss).to.be.within(0, 0.15)
		end)

		it("holds for every marker archetype", function()
			for _, name in ipairs(Markers.order) do
				local miss = interceptMiss(name, 35, Vector3.new(6, 0, 0))
				expect(miss).to.be.within(0, 0.2)
			end
		end)

		it("agrees with aimDirection when the target is standing still", function()
			local spec = specFor("mechanical")
			local origin = Vector3.new(0, 1.5, 0)
			local target = Vector3.new(0, 1.3, -30)
			local aimPoint = Ballistics.solveLead(spec, origin, target, Vector3.new(0, 0, 0))
			local dir = Ballistics.aimDirection(spec, origin, target)
			expect(aimPoint).to.be.ok()
			local leadDir = ((aimPoint :: Vector3) - origin).Unit
			expect(Ballistics.angularErrorDeg(leadDir, dir :: Vector3)).to.be.within(0, 0.01)
		end)
	end)

	describe("marker sidegrade invariants", function()
		it("makes the pump flatter and the electronic loopier", function()
			local pump = specFor("pump")
			local elec = specFor("electronic")
			expect(Ballistics.dropAt(pump, 40) < Ballistics.dropAt(elec, 40)).to.equal(true)
		end)

		it("never lets a marker remove the need to lead", function()
			-- Every marker must require meaningful lead at range, or it would be
			-- an accuracy upgrade rather than a sidegrade.
			for _, name in ipairs(Markers.order) do
				local lead = Ballistics.leadAt(specFor(name), 40, 6)
				expect(lead).to.be.within(1.0, 5.0)
			end
		end)
	end)

	describe("error measurement", function()
		it("reports zero angular error for identical directions", function()
			expect(Ballistics.angularErrorDeg(Vector3.new(0, 0, -1), Vector3.new(0, 0, -2))).to.be.near(0, 1e-6)
		end)

		it("reports 90 degrees for perpendicular directions", function()
			expect(Ballistics.angularErrorDeg(Vector3.new(1, 0, 0), Vector3.new(0, 0, -1))).to.be.near(90, 1e-4)
		end)

		it("signs lead error positive when the player over-leads", function()
			local shooter = Vector3.new(0, 0, 0)
			local ideal = Vector3.new(2, 0, -30)
			local over = Vector3.new(3, 0, -30)
			local under = Vector3.new(1, 0, -30)
			local vel = Vector3.new(6, 0, 0)
			expect((Ballistics.signedLeadError(shooter, over, ideal, vel) :: number) > 0).to.equal(true)
			expect((Ballistics.signedLeadError(shooter, under, ideal, vel) :: number) < 0).to.equal(true)
		end)

		it("declines to report lead error against a non-crossing target", function()
			local shooter = Vector3.new(0, 0, 0)
			local ideal = Vector3.new(0, 0, -30)
			-- Moving straight down the line of sight: no lead is possible.
			expect(Ballistics.signedLeadError(shooter, ideal, ideal, Vector3.new(0, 0, 6))).to.equal(nil)
			-- Standing still: likewise.
			expect(Ballistics.signedLeadError(shooter, ideal, ideal, Vector3.new(0, 0, 0))).to.equal(nil)
		end)
	end)
end
