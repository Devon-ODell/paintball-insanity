--!nolint
--[[
	Phase 7 acceptance: every drill produces a score reproducible under the sim
	harness, and drill ratings move with the same underlying skill that the match
	telemetry measures. The second property is the one that makes the
	play-diagnose-drill-play loop real rather than decorative.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local Drills = require(Server.Range.Drills)
local DrillScoring = require(Server.Range.DrillScoring)
local SimDrill = require(Server.Sim.SimDrill)
local Config = require(ReplicatedStorage.Shared.Config)

return function()
	describe("schedules", function()
		it("builds every drill in the configured order", function()
			for _, drillId in ipairs(Drills.list()) do
				local schedule = Drills.schedule(drillId, 1)
				expect(#schedule.targets > 0).to.equal(true)
				expect(schedule.fundamental).to.be.a("string")
			end
		end)

		it("is identical for the same seed", function()
			for _, drillId in ipairs(Drills.list()) do
				local a = Drills.schedule(drillId, 42)
				local b = Drills.schedule(drillId, 42)
				expect(#a.targets).to.equal(#b.targets)
				for i, target in ipairs(a.targets) do
					expect(target.spawnAt).to.be.near(b.targets[i].spawnAt, 1e-12)
					expect((target.position - b.targets[i].position).Magnitude).to.be.near(0, 1e-12)
				end
			end
		end)

		it("differs between seeds where the drill is randomised", function()
			local a = Drills.schedule("popup", 1)
			local b = Drills.schedule("popup", 2)
			local same = #a.targets == #b.targets
			if same then
				local identical = true
				for i, target in ipairs(a.targets) do
					if (target.position - b.targets[i].position).Magnitude > 1e-9 then
						identical = false
						break
					end
				end
				expect(identical).to.equal(false)
			end
		end)

		it("only surfaces targets that are currently alive", function()
			local schedule = Drills.schedule("popup", 3)
			local first = schedule.targets[1]
			expect(#Drills.activeAt(schedule, first.spawnAt - 0.01)).to.equal(0)
			expect(#Drills.activeAt(schedule, first.spawnAt + 0.01) > 0).to.equal(true)
		end)

		it("moves strafe targets across the track", function()
			local schedule = Drills.schedule("strafe", 5)
			local target = schedule.targets[1]
			local early = Drills.activeAt(schedule, target.spawnAt + 0.1)[1]
			local late = Drills.activeAt(schedule, target.spawnAt + 1.0)[1]
			expect(math.abs(late.position.X - early.position.X) > 1).to.equal(true)
		end)

		it("places holdover targets at the configured distances", function()
			local schedule = Drills.schedule("holdover", 1)
			local distances = Config.require("range", "drills.holdover.staticDistancesMetres")
			local seen: { [number]: boolean } = {}
			for _, target in ipairs(schedule.targets) do
				seen[math.floor(target.position.Magnitude + 0.5)] = true
			end
			for _, d in ipairs(distances) do
				local found = false
				for value in pairs(seen) do
					if math.abs(value - d) <= 2 then
						found = true
					end
				end
				expect(found).to.equal(true)
			end
		end)

		it("announces the peek angles, because they are meant to be learnable", function()
			local schedule = Drills.schedule("peek", 9)
			for _, target in ipairs(schedule.targets) do
				expect(target.announcedBearingDeg).to.be.a("number")
			end
		end)

		it("rejects an unknown drill loudly", function()
			expect(function()
				Drills.schedule("nonexistent", 1)
			end).to.throw()
		end)
	end)

	describe("scoring", function()
		it("is reproducible for the same seed and player model", function()
			for _, drillId in ipairs(Drills.list()) do
				local a = SimDrill.run({ drill = drillId, seed = 8, leadAccuracy = 0.8, sigmaDeg = 1.2 })
				local b = SimDrill.run({ drill = drillId, seed = 8, leadAccuracy = 0.8, sigmaDeg = 1.2 })
				expect(a.score).to.equal(b.score)
				expect(a.rating).to.be.near(b.rating, 1e-12)
				expect(a.hits).to.equal(b.hits)
			end
		end)

		it("never returns a negative score", function()
			local result = SimDrill.run({ drill = "strafe", seed = 2, leadAccuracy = 0, sigmaDeg = 8 })
			expect(result.score >= 0).to.equal(true)
		end)

		it("maps each drill to its fundamental", function()
			expect(DrillScoring.drillFor("reactivity")).to.equal("popup")
			expect(DrillScoring.drillFor("crosshairPlacement")).to.equal("peek")
			expect(DrillScoring.drillFor("targetSwitching")).to.equal("switch")
		end)
	end)

	describe("drills measure what they claim to", function()
		--[[
			Phase 7 acceptance: "drill scores correlate with the corresponding
			match telemetry axis". Each of these varies exactly one skill and
			asserts the matching drill's rating moves with it -- and, where it
			matters, that the OTHER drills do not.
		]]
		it("Strafe rating tracks lead accuracy and nothing else", function()
			local bad = SimDrill.run({ drill = "strafe", seed = 4, leadAccuracy = 0.2, sigmaDeg = 0 })
			local good = SimDrill.run({ drill = "strafe", seed = 4, leadAccuracy = 1.0, sigmaDeg = 0 })
			expect(good.rating > bad.rating).to.equal(true)
			expect(bad.rating < 40).to.equal(true)
			expect(good.rating > 90).to.equal(true)
		end)

		it("Strafe rating is unmoved by pure reaction time", function()
			local quick = SimDrill.run({ drill = "strafe", seed = 4, leadAccuracy = 0.6, reactionSeconds = 0.15 })
			local slow = SimDrill.run({ drill = "strafe", seed = 4, leadAccuracy = 0.6, reactionSeconds = 0.45 })
			-- Lead error is measured against the solution AT the moment of
			-- firing, so a slower player has the same lead problem, later.
			expect(quick.rating).to.be.near(slow.rating, 12)
		end)

		it("Pop-Up rating tracks reaction time", function()
			local quick = SimDrill.run({ drill = "popup", seed = 6, reactionSeconds = 0.18 })
			local slow = SimDrill.run({ drill = "popup", seed = 6, reactionSeconds = 0.9 })
			expect(quick.rating > slow.rating).to.equal(true)
		end)

		it("Holdover rating tracks vertical error", function()
			local flat = SimDrill.run({ drill = "holdover", seed = 3, leadAccuracy = 1.0, sigmaDeg = 0 })
			local sloppy = SimDrill.run({ drill = "holdover", seed = 3, leadAccuracy = 0.1, sigmaDeg = 0 })
			-- leadAccuracy also carries the drop compensation, so a player who
			-- ignores the solution against a STATIC target is missing purely on
			-- holdover. That is exactly what this drill is for.
			expect(flat.rating > sloppy.rating).to.equal(true)
		end)

		it("Peek rating tracks crosshair placement", function()
			local placed = SimDrill.run({ drill = "peek", seed = 7, crosshairOffsetDeg = 2 })
			local wandering = SimDrill.run({ drill = "peek", seed = 7, crosshairOffsetDeg = 40 })
			expect(placed.rating > wandering.rating).to.equal(true)
		end)

		it("scores the Range at zero payout, always", function()
			expect(Config.require("range", "payout")).to.equal(0)
		end)
	end)
end
