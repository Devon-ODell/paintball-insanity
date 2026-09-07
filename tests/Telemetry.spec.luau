--!nolint
--[[
	Phase 3 acceptance: aggregation against hand-computed fixtures, and the
	deliberately-bad-policy check -- a player who never leads must show high
	lead error and NORMAL angular error. If those two ever blur together the
	prescriptions become noise and the product stops working.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local ShotLog = require(Server.Telemetry.ShotLog)
local Aggregate = require(Server.Telemetry.Aggregate)
local Prescription = require(Server.Telemetry.Prescription)

local function baseShot(overrides: any): any
	local shot = {
		t = 0,
		stance = "standing",
		distance = 25,
		hit = false,
		eliminated = false,
		angularErrorDeg = 1.0,
		targetLateralSpeed = 0,
	}
	for k, v in pairs(overrides) do
		shot[k] = v
	end
	return shot
end

return function()
	describe("ShotLog", function()
		it("assigns sequential shot ids", function()
			local log = ShotLog.new("speedball", "mechanical", "rec")
			for _ = 1, 3 do
				log:record(baseShot({}))
			end
			expect(log.shots[1].shotId).to.equal(1)
			expect(log.shots[3].shotId).to.equal(3)
		end)

		it("derives shooterMoving from stance", function()
			local log = ShotLog.new("speedball", "mechanical", "rec")
			expect(log:record(baseShot({ stance = "sprinting" })).shooterMoving).to.equal(true)
			expect(log:record(baseShot({ stance = "crouching" })).shooterMoving).to.equal(false)
		end)

		it("measures the gap between eliminations", function()
			local log = ShotLog.new("speedball", "mechanical", "rec")
			log:record(baseShot({ t = 10, hit = true, eliminated = true, targetId = "b1" }))
			log:record(baseShot({ t = 12.5, hit = true, eliminated = true, targetId = "b2" }))
			expect(log.eliminations[1].msSincePreviousElimination).to.equal(nil)
			expect(log.eliminations[2].msSincePreviousElimination).to.be.near(2500, 1e-6)
		end)

		it("tracks the longest streak and breaks it on death", function()
			local log = ShotLog.new("speedball", "mechanical", "rec")
			log:record(baseShot({ t = 1, hit = true, eliminated = true, targetId = "b1" }))
			log:record(baseShot({ t = 2, hit = true, eliminated = true, targetId = "b2" }))
			log:record(baseShot({ t = 3, hit = true, eliminated = true, targetId = "b3" }))
			log:recordDeath(4)
			log:record(baseShot({ t = 5, hit = true, eliminated = true, targetId = "b4" }))
			expect(log:longestStreak()).to.equal(3)
		end)

		it("does not credit a switch across a respawn", function()
			local log = ShotLog.new("speedball", "mechanical", "rec")
			log:record(baseShot({ t = 1, hit = true, eliminated = true, targetId = "b1" }))
			log:recordDeath(2)
			log:record(baseShot({ t = 3, hit = true, eliminated = true, targetId = "b2" }))
			expect(log.eliminations[2].msSincePreviousElimination).to.equal(nil)
		end)
	end)

	describe("bucketing", function()
		it("counts a long swing as a flick and a short one as not", function()
			local log = ShotLog.new("speedball", "mechanical", "rec")
			log:record(baseShot({ priorAimSwingDeg = 40, angularErrorDeg = 3 }))
			log:record(baseShot({ priorAimSwingDeg = 4, angularErrorDeg = 9 }))
			local b = Aggregate.bucket(log)
			expect(#b.flicking).to.equal(1)
			expect(b.flicking[1]).to.equal(3)
		end)

		it("only counts crossing targets inside tracking range as tracking", function()
			local log = ShotLog.new("speedball", "mechanical", "rec")
			log:record(baseShot({ targetLateralSpeed = 5, distance = 20 })) -- yes
			log:record(baseShot({ targetLateralSpeed = 5, distance = 60 })) -- too far
			log:record(baseShot({ targetLateralSpeed = 0.5, distance = 20 })) -- not crossing
			expect(#Aggregate.bucket(log).tracking).to.equal(1)
		end)

		it("ignores an elimination gap longer than the switch window", function()
			local log = ShotLog.new("speedball", "mechanical", "rec")
			log:record(baseShot({ t = 0, hit = true, eliminated = true, targetId = "b1" }))
			log:record(baseShot({ t = 30, hit = true, eliminated = true, targetId = "b2" }))
			expect(#Aggregate.bucket(log).targetSwitching).to.equal(0)
		end)

		it("only counts lead error beyond the minimum distance", function()
			local log = ShotLog.new("speedball", "mechanical", "rec")
			log:record(baseShot({ distance = 10, leadErrorM = -1.0 }))
			log:record(baseShot({ distance = 30, leadErrorM = -1.0 }))
			expect(#Aggregate.bucket(log).leadSigned).to.equal(1)
		end)
	end)

	describe("scoring", function()
		it("scores a raw mean of exactly `scale` at 100/e", function()
			-- Hand-computed fixture: score = 100 * exp(-(scale/scale)^shape) = 36.788
			local log = ShotLog.new("speedball", "mechanical", "rec")
			for _ = 1, 8 do
				log:record(baseShot({ timeToAcquireMs = 620 }))
			end
			local scores = Aggregate.score(log)
			expect(scores.reactivity.score).to.be.near(36.7879441, 1e-4)
			expect(scores.reactivity.confident).to.equal(true)
		end)

		it("scores a perfect measurement at 100", function()
			local log = ShotLog.new("speedball", "mechanical", "rec")
			for _ = 1, 8 do
				log:record(baseShot({ timeToAcquireMs = 0 }))
			end
			expect(Aggregate.score(log).reactivity.score).to.equal(100)
		end)

		it("refuses confidence below the minimum sample count", function()
			local log = ShotLog.new("speedball", "mechanical", "rec")
			log:record(baseShot({ timeToAcquireMs = 300 }))
			local scores = Aggregate.score(log)
			expect(scores.reactivity.samples).to.equal(1)
			expect(scores.reactivity.confident).to.equal(false)
		end)

		it("never nominates an unconfident axis as the weakest", function()
			local log = ShotLog.new("speedball", "mechanical", "rec")
			-- One catastrophic tracking sample, plenty of mediocre reactivity ones.
			log:record(baseShot({ targetLateralSpeed = 5, distance = 20, angularErrorDeg = 40 }))
			for _ = 1, 10 do
				log:record(baseShot({ timeToAcquireMs = 900 }))
			end
			expect(Aggregate.weakest(Aggregate.score(log))).to.equal("reactivity")
		end)
	end)

	describe("lead diagnosis", function()
		it("calls a consistent negative bias under-leading", function()
			local log = ShotLog.new("woods", "mechanical", "rec")
			for _ = 1, 10 do
				log:record(baseShot({ distance = 40, leadErrorM = -1.2, targetLateralSpeed = 6 }))
			end
			local bias, verdict = Aggregate.leadDiagnosis(log)
			expect(verdict).to.equal("under")
			expect(bias).to.be.near(-1.2, 1e-6)
		end)

		it("calls a consistent positive bias over-leading", function()
			local log = ShotLog.new("woods", "mechanical", "rec")
			for _ = 1, 10 do
				log:record(baseShot({ distance = 40, leadErrorM = 0.9, targetLateralSpeed = 6 }))
			end
			expect(select(2, Aggregate.leadDiagnosis(log))).to.equal("over")
		end)

		it("calls a symmetric spread a drop problem, not a lead problem", function()
			local log = ShotLog.new("woods", "mechanical", "rec")
			for i = 1, 10 do
				log:record(baseShot({
					distance = 40,
					leadErrorM = if i % 2 == 0 then 1.4 else -1.4,
					targetLateralSpeed = 6,
				}))
			end
			expect(select(2, Aggregate.leadDiagnosis(log))).to.equal("spread")
		end)
	end)

	describe("the never-leads policy", function()
		--[[
			BUILD_PLAN Phase 3 acceptance, stated directly: a player who aims
			dead at the target must show HIGH lead error and NORMAL angular
			error. If a change ever couples these, the whole diagnosis collapses
			into "you missed" and the game loses its reason to exist.
		]]
		local function policyLog(leadsCorrectly: boolean)
			local log = ShotLog.new("woods", "mechanical", "rec")
			for _ = 1, 20 do
				log:record(baseShot({
					distance = 40,
					targetLateralSpeed = 6,
					-- Aiming straight at the body: small angular error, huge lead error.
					angularErrorDeg = 1.1,
					leadErrorM = if leadsCorrectly then 0.05 else -2.4,
					holdoverErrorM = 0.05,
				}))
			end
			return log
		end

		it("separates a lead failure from an aim failure", function()
			local bad = Aggregate.score(policyLog(false))
			local good = Aggregate.score(policyLog(true))

			-- Lead score collapses...
			expect(bad.leadAndDrop.score < 20).to.equal(true)
			expect(good.leadAndDrop.score > 90).to.equal(true)

			-- ...while the pure-aim axis is unchanged between the two policies.
			expect(bad.tracking.rawMean).to.be.near(good.tracking.rawMean, 1e-9)
		end)

		it("prescribes the strafe drill and names the direction of the error", function()
			local log = policyLog(false)
			local result = Prescription.forSession(log, Aggregate.score(log))
			expect(result).to.be.ok()
			expect((result :: any).drill).to.equal("strafe")
			expect((result :: any).fundamental).to.equal("leadAndDrop")
			expect((result :: any).line:find("under%-lead") ~= nil).to.equal(true)
			expect((result :: any).line:find("2.40") ~= nil).to.equal(true)
		end)

		it("prescribes holdover, not strafe, when the error has no direction", function()
			local log = ShotLog.new("woods", "mechanical", "rec")
			for i = 1, 20 do
				log:record(baseShot({
					distance = 40,
					targetLateralSpeed = 6,
					angularErrorDeg = 1.1,
					leadErrorM = if i % 2 == 0 then 2.4 else -2.4,
					holdoverErrorM = 1.5,
				}))
			end
			local result = Prescription.forSession(log, Aggregate.score(log))
			expect((result :: any).drill).to.equal("holdover")
		end)
	end)

	describe("summary", function()
		it("reports hit rate and carries the payout through untouched", function()
			local log = ShotLog.new("speedball", "mechanical", "rec")
			for _ = 1, 10 do
				log:record(baseShot({ timeToAcquireMs = 400 }))
			end
			local summary = Prescription.summarise(log, {
				cleared = true,
				deaths = 2,
				eliminations = 6,
				durationSeconds = 180,
				shots = 40,
				hits = 10,
				longestStreak = 3,
			}, "rec", 512)
			expect(summary.hitRate).to.be.near(0.25, 1e-9)
			expect(summary.payout).to.equal(512)
			expect(summary.cleared).to.equal(true)
		end)
	end)
end
