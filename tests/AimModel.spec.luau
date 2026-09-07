--!nolint
--[[
	Phase 4 acceptance for the aim model: the error distribution must match its
	configured sigma, and `leadSolutionAccuracy` must actually mean what the
	design table says it means -- 0 shoots where you are, 1 shoots where you
	will be. That single parameter carries most of the felt difficulty, so it
	gets tested against the simulation rather than against itself.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local AimModel = require(Server.Bots.AimModel)
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local Rng = require(ReplicatedStorage.Shared.Rng)
local BotsData = require(ReplicatedStorage.Data.bots)
local Markers = require(ReplicatedStorage.Data.markers)
local BallisticsData = require(ReplicatedStorage.Data.ballistics)

local SPEC = Ballistics.specFromMarker(Markers.markers.mechanical, BallisticsData)
local SIM = { fixedStep = 1 / 480, maxFlightTime = 5, maxRange = 200 }

local function tierOf(name: string)
	return BotsData.tiers[name]
end

--- Fires the solved direction and returns the closest approach to the target.
local function closestApproach(origin: Vector3, dir: Vector3, targetStart: Vector3, targetVel: Vector3): number
	local closest = math.huge
	Ballistics.integrate(origin, dir, SPEC, SIM, function(seg)
		local now = targetStart + targetVel * seg.tEnd
		local d = (seg.to - now).Magnitude
		if d < closest then
			closest = d
		end
		return seg.tEnd > 2.5
	end)
	return closest
end

return function()
	describe("rotate", function()
		it("is identity at zero", function()
			local d = Vector3.new(0, 0, -1)
			expect(Ballistics.angularErrorDeg(AimModel.rotate(d, 0, 0), d)).to.be.near(0, 1e-6)
		end)

		it("rotates by exactly the requested angle", function()
			local d = Vector3.new(0, 0, -1)
			expect(Ballistics.angularErrorDeg(AimModel.rotate(d, 12, 0), d)).to.be.near(12, 1e-4)
			expect(Ballistics.angularErrorDeg(AimModel.rotate(d, 0, -7), d)).to.be.near(7, 1e-4)
		end)

		it("survives a straight-up direction without producing NaN", function()
			local up = Vector3.new(0, 1, 0)
			local r = AimModel.rotate(up, 20, 10)
			expect(r.Magnitude).to.be.near(1, 1e-5)
		end)
	end)

	describe("settling", function()
		it("starts wide and narrows to exactly the configured sigma", function()
			local tier = tierOf("semipro")
			expect(AimModel.settleFactor(tier, 0)).to.be.near(3.0, 1e-9)
			expect(AimModel.settleFactor(tier, tier.timeToSettleMs / 1000)).to.be.near(1.0, 1e-9)
			expect(AimModel.settleFactor(tier, 99)).to.be.near(1.0, 1e-9)
		end)

		it("narrows monotonically", function()
			local tier = tierOf("pro")
			local previous = math.huge
			for i = 0, 10 do
				local f = AimModel.settleFactor(tier, i * 0.03)
				expect(f <= previous).to.equal(true)
				previous = f
			end
		end)
	end)

	describe("reaction time", function()
		it("never reacts instantly", function()
			local rng = Rng.new(11)
			for _ = 1, 500 do
				expect(AimModel.reactionDelay(tierOf("pro"), rng) >= 0).to.equal(true)
			end
		end)

		it("averages the configured reaction time across tiers", function()
			for _, name in ipairs(BotsData.tierOrder) do
				local tier = tierOf(name)
				local rng = Rng.new(99)
				local sum = 0
				local n = 3000
				for _ = 1, n do
					sum += AimModel.reactionDelay(tier, rng)
				end
				local meanMs = (sum / n) * 1000
				-- Clamping at zero biases the mean up very slightly; 4% covers it.
				expect(meanMs).to.be.near(tier.reactionTimeMs, tier.reactionTimeMs * 0.04)
			end
		end)

		it("gets faster with every tier", function()
			local previous = math.huge
			for _, name in ipairs(BotsData.tierOrder) do
				local t = tierOf(name).reactionTimeMs
				expect(t < previous).to.equal(true)
				previous = t
			end
		end)
	end)

	describe("aim error distribution", function()
		--[[
			BUILD_PLAN Phase 4: "Unit test asserts bot aim error distribution
			matches its configured sigma."
		]]
		it("matches the configured sigma once settled", function()
			for _, name in ipairs(BotsData.tierOrder) do
				local tier = tierOf(name)
				local rng = Rng.new(4242)
				local origin = Vector3.new(0, 1.5, 0)
				local target = Vector3.new(0, 1.5, -25)

				local sumSq, n = 0, 4000
				for _ = 1, n do
					local solution = AimModel.solve({
						spec = SPEC,
						origin = origin,
						targetPosition = target,
						targetVelocity = Vector3.new(0, 0, 0),
						tier = tier,
						rng = rng,
						elapsedSinceAcquire = 10, -- fully settled
					})
					local ideal = (solution :: any).intendedAimPoint - origin
					local err = Ballistics.angularErrorDeg((solution :: any).direction, ideal)
					sumSq += err * err
				end
				-- Two independent axes at sigma each give a Rayleigh distribution
				-- whose RMS magnitude is sigma * sqrt(2).
				local rms = math.sqrt(sumSq / n)
				expect(rms).to.be.near(tier.aimErrorDeg * math.sqrt(2), tier.aimErrorDeg * 0.12)
			end
		end)

		it("is wider before the bot has settled", function()
			local tier = tierOf("semipro")
			local function rms(elapsed: number): number
				local rng = Rng.new(777)
				local origin = Vector3.new(0, 1.5, 0)
				local target = Vector3.new(0, 1.5, -25)
				local sumSq, n = 0, 2000
				for _ = 1, n do
					local s = AimModel.solve({
						spec = SPEC, origin = origin, targetPosition = target,
						targetVelocity = Vector3.new(0, 0, 0), tier = tier, rng = rng,
						elapsedSinceAcquire = elapsed,
					})
					local e = Ballistics.angularErrorDeg((s :: any).direction, (s :: any).intendedAimPoint - origin)
					sumSq += e * e
				end
				return math.sqrt(sumSq / n)
			end
			expect(rms(0) > rms(10) * 2.5).to.equal(true)
		end)

		it("widens with morale collapse but never past the configured cap", function()
			local tier = tierOf("pro")
			local penalties = BotsData.morale.aimErrorPenaltyByState
			expect(penalties.broken > penalties.cocky).to.equal(true)
			expect(penalties.broken <= 1.25).to.equal(true)
			-- A broken pro must still out-aim a fresh rec bot, or morale would
			-- flatten the tier curve the whole game rests on.
			expect(tier.aimErrorDeg * penalties.broken < tierOf("rec").aimErrorDeg).to.equal(true)
		end)
	end)

	describe("lead solution accuracy", function()
		local origin = Vector3.new(0, 1.5, 0)
		local target = Vector3.new(0, 1.5, -35)
		local velocity = Vector3.new(6, 0, 0)

		--- Solves with random error switched off by using a zero-sigma tier.
		local function solveWithAccuracy(accuracy: number)
			return AimModel.solve({
				spec = SPEC,
				origin = origin,
				targetPosition = target,
				targetVelocity = velocity,
				tier = {
					reactionTimeMs = 200, reactionJitterMs = 0,
					aimErrorDeg = 0, leadSolutionAccuracy = accuracy, leadJitter = 0,
					timeToSettleMs = 100, crosshairPrePlacement = 1, peekDiscipline = 1,
				},
				rng = Rng.new(1),
				elapsedSinceAcquire = 10,
			})
		end

		it("shoots where the target IS at accuracy 0", function()
			local s = solveWithAccuracy(0)
			expect(((s :: any).intendedAimPoint - target).Magnitude).to.be.near(0, 1e-6)
			-- And therefore misses behind a crossing target by roughly a full lead.
			local miss = closestApproach(origin, (s :: any).direction, target, velocity)
			expect(miss > 1.5).to.equal(true)
		end)

		it("shoots where the target WILL BE at accuracy 1", function()
			local s = solveWithAccuracy(1)
			local miss = closestApproach(origin, (s :: any).direction, target, velocity)
			expect(miss).to.be.within(0, 0.2)
		end)

		it("interpolates monotonically between the two", function()
			local previous = math.huge
			for _, a in ipairs({ 0, 0.25, 0.5, 0.75, 1.0 }) do
				local s = solveWithAccuracy(a)
				local miss = closestApproach(origin, (s :: any).direction, target, velocity)
				expect(miss < previous).to.equal(true)
				previous = miss
			end
		end)

		it("makes each configured tier strictly deadlier than the last", function()
			local previous = math.huge
			for _, name in ipairs(BotsData.tierOrder) do
				local s = solveWithAccuracy(tierOf(name).leadSolutionAccuracy)
				local miss = closestApproach(origin, (s :: any).direction, target, velocity)
				expect(miss < previous).to.equal(true)
				previous = miss
			end
		end)

		it("refuses to solve past the marker's reach rather than guessing", function()
			local s = AimModel.solve({
				spec = SPEC, origin = origin,
				targetPosition = Vector3.new(0, 1.5, -4000),
				targetVelocity = Vector3.new(0, 0, 0),
				tier = tierOf("pro"), rng = Rng.new(3), elapsedSinceAcquire = 10,
			})
			expect(s).to.equal(nil)
		end)
	end)

	describe("crosshair pre-placement", function()
		it("does nothing at 0 and snaps to the angle at 1", function()
			local origin = Vector3.new(0, 1.5, 0)
			local watch = Vector3.new(0, 1.5, -20)
			local facing = Vector3.new(1, 0, 0)
			local none = AimModel.prePlacement({ crosshairPrePlacement = 0 } :: any, facing, origin, watch)
			local full = AimModel.prePlacement({ crosshairPrePlacement = 1 } :: any, facing, origin, watch)
			expect(Ballistics.angularErrorDeg(none, facing)).to.be.near(0, 1e-4)
			expect(Ballistics.angularErrorDeg(full, watch - origin)).to.be.near(0, 1e-4)
		end)

		it("closes more of the angle at every tier", function()
			local origin = Vector3.new(0, 1.5, 0)
			local watch = Vector3.new(0, 1.5, -20)
			local facing = Vector3.new(1, 0, 0)
			local previous = math.huge
			for _, name in ipairs(BotsData.tierOrder) do
				local d = AimModel.prePlacement(tierOf(name), facing, origin, watch)
				local offset = Ballistics.angularErrorDeg(d, watch - origin)
				expect(offset < previous).to.equal(true)
				previous = offset
			end
		end)
	end)

	describe("peek discipline", function()
		it("always exposes when there is a reason", function()
			local rng = Rng.new(5)
			for _ = 1, 100 do
				expect(AimModel.willExpose(tierOf("pro"), rng, true)).to.equal(true)
			end
		end)

		it("exposes carelessly at low discipline and rarely at high", function()
			local function rate(name: string): number
				local rng = Rng.new(8080)
				local n, hits = 4000, 0
				for _ = 1, n do
					if AimModel.willExpose(tierOf(name), rng, false) then
						hits += 1
					end
				end
				return hits / n
			end
			expect(rate("rec")).to.be.near(1 - tierOf("rec").peekDiscipline, 0.05)
			expect(rate("pro")).to.be.near(1 - tierOf("pro").peekDiscipline, 0.05)
			expect(rate("rec") > rate("pro")).to.equal(true)
		end)
	end)
end
