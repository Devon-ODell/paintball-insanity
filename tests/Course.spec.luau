--!nolint
--[[
	The Shoothouse: stage composition, the clock, medals, records and co-op.

	The load-bearing assertions here are the ones about EARNING. A medal must be
	a threshold on a time that includes the death penalty, a record must never go
	backwards, and the Aurum route must not be reachable by being carried through
	a co-op run.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local Config = require(ReplicatedStorage.Shared.Config)
local Course = require(Server.Match.Course)
local CourseProgress = require(Server.Progression.CourseProgress)
local Courses = require(ReplicatedStorage.Shared.Courses)
local Camos = require(ReplicatedStorage.Shared.Camos)

--- A stand-in for the ProfileStore handle: the two fields the code touches.
local function profile(): any
	local handle = { data = {}, active = true }
	function handle:isActive()
		return self.active
	end
	return handle
end

local function maps(): { string }
	return Config.mapNames()
end

return function()
	describe("stage composition", function()
		it("lays every course through its own map's anchors, once each", function()
			for _, name in ipairs(maps()) do
				local map = Config.map(name)
				local seen = {}
				local count = 0
				for _, stage in ipairs(Course.all(name, "rec")) do
					for _, id in ipairs(stage.anchorIds) do
						expect(seen[id]).to.equal(nil)
						seen[id] = true
						count += 1
					end
				end
				expect(count).to.equal(#map.anchors)
			end
		end)

		it("escalates the concurrent defender count every stage", function()
			for _, name in ipairs(maps()) do
				local previous = 0
				for _, stage in ipairs(Course.all(name, "rec")) do
					expect(stage.concurrent > previous).to.equal(true)
					previous = stage.concurrent
				end
			end
		end)

		it("refills each stage's cover rather than doubling up on it", function()
			local waves = Config.require("course", "wavesPerStage")
			expect(waves > 1).to.equal(true)
			for _, name in ipairs(maps()) do
				for _, stage in ipairs(Course.all(name, "rec")) do
					-- Never more bodies at once than there are bunkers to hold.
					expect(stage.concurrent).to.equal(#stage.anchorIds)
					expect(stage.botCount).to.equal(#stage.anchorIds * waves)
				end
			end
		end)

		it("never regresses the tier and escalates it by the last stage", function()
			for _, name in ipairs(maps()) do
				local stages = Course.all(name, "rec")
				expect(stages[1].tier).to.equal("rec")
				expect(stages[#stages].tier).never.to.equal("rec")
			end
		end)

		it("caps escalation at the top of the ladder", function()
			for _, name in ipairs(maps()) do
				for _, stage in ipairs(Course.all(name, "pro")) do
					expect(stage.tier).to.equal("pro")
				end
			end
		end)

		it("marks only the last stage as final", function()
			for _, name in ipairs(maps()) do
				local stages = Course.all(name, "rec")
				for i, stage in ipairs(stages) do
					expect(stage.isFinal).to.equal(i == #stages)
				end
			end
		end)

		it("reports no course for a map that has none", function()
			expect(Course.hasCourse("not_a_map")).to.equal(false)
			expect(Course.stageCount("not_a_map")).to.equal(0)
		end)
	end)

	describe("the clock", function()
		it("charges every death against the time that is judged", function()
			local penalty = Course.deathPenaltySeconds()
			expect(Course.finalSeconds(100, 0)).to.equal(100)
			expect(Course.finalSeconds(100, 3)).to.equal(100 + penalty * 3)
		end)

		it("never credits time back for a negative death count", function()
			expect(Course.finalSeconds(100, -5)).to.equal(100)
		end)
	end)

	describe("medals", function()
		it("awards each medal at exactly its own par", function()
			for _, name in ipairs(maps()) do
				local par = Course.parSeconds(name)
				expect(Course.medalFor(name, par.gold)).to.equal("gold")
				expect(Course.medalFor(name, par.silver)).to.equal("silver")
				expect(Course.medalFor(name, par.bronze)).to.equal("bronze")
				expect(Course.medalFor(name, par.bronze + 0.01)).to.equal(nil)
			end
		end)

		it("orders par so a faster run can never earn a worse medal", function()
			for _, name in ipairs(maps()) do
				local par = Course.parSeconds(name)
				expect(par.gold < par.silver).to.equal(true)
				expect(par.silver < par.bronze).to.equal(true)
			end
		end)

		it("ranks medals by the ladder, not alphabetically", function()
			-- "bronze" < "gold" < "silver" as strings, which is why this matters.
			expect(Course.isBetterMedal("gold", "silver")).to.equal(true)
			expect(Course.isBetterMedal("bronze", "silver")).to.equal(false)
			expect(Course.isBetterMedal("bronze", nil)).to.equal(true)
			expect(Course.isBetterMedal(nil, "bronze")).to.equal(false)
		end)
	end)

	describe("payout", function()
		it("pays a medal more than no medal, and gold most", function()
			for _, name in ipairs(maps()) do
				local none = Course.payoutFor(name, nil, {})
				local bronze = Course.payoutFor(name, "bronze", {})
				local gold = Course.payoutFor(name, "gold", {})
				expect(none < bronze).to.equal(true)
				expect(bronze < gold).to.equal(true)
			end
		end)

		it("pays the first-medal bonus only for newly reached tiers", function()
			local repeated = Course.payoutFor("speedball", "gold", {})
			local first = Course.payoutFor("speedball", "gold", { "gold" })
			expect(first > repeated).to.equal(true)
		end)

		it("never out-earns a full gauntlet on the same map", function()
			-- The course is a skill test and a leaderboard, never the efficient
			-- way to farm. A clean gold must stay under one clean five-round run.
			local RoundSchedule = require(Server.Match.RoundSchedule)
			for _, name in ipairs(maps()) do
				local gauntlet = Config.require("economy", "basePayout")[name]
					* RoundSchedule.totalPayoutMultiplier("rec")
				expect(Course.payoutFor(name, "gold", {}) < gauntlet).to.equal(true)
			end
		end)
	end)

	describe("records", function()
		it("keeps the faster of two runs", function()
			local handle = profile()
			CourseProgress.record(handle, { mapName = "speedball", liveSeconds = 200, deaths = 0, cleared = true, playerCount = 1 })
			local slower = CourseProgress.record(handle, { mapName = "speedball", liveSeconds = 260, deaths = 0, cleared = true, playerCount = 1 })
			expect(slower.isRecord).to.equal(false)
			expect(Courses.recordFor(handle.data, "speedball").bestSeconds).to.equal(200)

			local faster = CourseProgress.record(handle, { mapName = "speedball", liveSeconds = 150, deaths = 0, cleared = true, playerCount = 1 })
			expect(faster.isRecord).to.equal(true)
			expect(Courses.recordFor(handle.data, "speedball").bestSeconds).to.equal(150)
		end)

		it("never takes a medal back for a slower run afterwards", function()
			local handle = profile()
			local par = Course.parSeconds("speedball")
			CourseProgress.record(handle, { mapName = "speedball", liveSeconds = par.gold, deaths = 0, cleared = true, playerCount = 1 })
			expect(Courses.recordFor(handle.data, "speedball").bestMedal).to.equal("gold")
			CourseProgress.record(handle, { mapName = "speedball", liveSeconds = par.bronze, deaths = 0, cleared = true, playerCount = 1 })
			expect(Courses.recordFor(handle.data, "speedball").bestMedal).to.equal("gold")
		end)

		it("counts a failed run but never lets it set a time or a medal", function()
			local handle = profile()
			CourseProgress.record(handle, { mapName = "speedball", liveSeconds = 30, deaths = 1, cleared = false, playerCount = 1 })
			local record = Courses.recordFor(handle.data, "speedball")
			expect(record.runs).to.equal(1)
			expect(record.clears).to.equal(0)
			expect(record.bestSeconds).to.equal(nil)
			expect(record.bestMedal).to.equal(nil)
		end)

		it("charges the death penalty before deciding the medal", function()
			local handle = profile()
			local par = Course.parSeconds("speedball")
			-- Inside gold on the clock, outside it once two deaths are charged.
			local seconds = par.gold - Course.deathPenaltySeconds()
			local outcome = CourseProgress.record(handle,
				{ mapName = "speedball", liveSeconds = seconds, deaths = 2, cleared = true, playerCount = 1 })
			expect(outcome.medal).never.to.equal("gold")
		end)

		it("reports each medal tier as new exactly once", function()
			local handle = profile()
			local par = Course.parSeconds("speedball")
			local first = CourseProgress.record(handle, { mapName = "speedball", liveSeconds = par.bronze, deaths = 0, cleared = true, playerCount = 1 })
			expect(#first.newMedals).to.equal(1)
			local jump = CourseProgress.record(handle, { mapName = "speedball", liveSeconds = par.gold, deaths = 0, cleared = true, playerCount = 1 })
			-- Bronze straight to gold reports silver and gold together.
			expect(#jump.newMedals).to.equal(2)
			local again = CourseProgress.record(handle, { mapName = "speedball", liveSeconds = par.gold, deaths = 0, cleared = true, playerCount = 1 })
			expect(#again.newMedals).to.equal(0)
		end)

		it("survives a profile with no course records at all", function()
			local record = Courses.recordFor({}, "speedball")
			expect(record.runs).to.equal(0)
			expect(record.bestSeconds).to.equal(nil)
			expect(Courses.goldCount({})).to.equal(0)
		end)

		it("refuses a medal that is not on the ladder", function()
			local data = { courseRecords = { speedball = { bestMedal = "platinum", runs = 1 } } }
			expect(Courses.recordFor(data, "speedball").bestMedal).to.equal(nil)
			expect(Courses.goldCount(data)).to.equal(0)
		end)
	end)

	describe("co-op", function()
		it("takes two players and no more", function()
			expect(Course.maxPlayers()).to.equal(2)
		end)

		it("fields more defenders for a second player", function()
			for _, name in ipairs(maps()) do
				for _, stage in ipairs(Course.all(name, "rec")) do
					expect(Course.concurrentFor(stage, 2) > Course.concurrentFor(stage, 1)).to.equal(true)
					expect(Course.concurrentFor(stage, 1)).to.equal(stage.concurrent)
				end
			end
		end)

		it("does not let a co-op run buy the gold marker", function()
			expect(Course.countsTowardAurum(1)).to.equal(true)
			expect(Course.countsTowardAurum(2)).to.equal(false)
		end)
	end)

	describe("the Aurum route", function()
		local function goldEverywhere(): any
			local data = { courseRecords = {} }
			for _, name in ipairs(maps()) do
				data.courseRecords[name] = { bestMedal = "gold", bestSeconds = 10, runs = 1, clears = 1 }
			end
			return data
		end

		it("opens only on gold across every course", function()
			local requirement = Config.require("course", "rewards.aurumKompressor.requires")
			local data = goldEverywhere()
			expect(Courses.meets(data, requirement)).to.equal(true)

			data.courseRecords[maps()[1]].bestMedal = "silver"
			expect(Courses.meets(data, requirement)).to.equal(false)
			expect(Courses.remainingFor(data, requirement)).to.equal(1)
		end)

		it("asks for exactly as many golds as there are courses", function()
			expect(Config.require("course", "rewards.aurumKompressor.requires").count)
				.to.equal(Courses.courseCount())
		end)

		it("makes deferred course finishes earnable through mask hits", function()
			for _, id in ipairs({ "chalkline", "shoothouse", "aurumFinish" }) do
				local required = Camos.visual(id).requiredHeadshots
				expect(required > 0).to.equal(true)
				expect(Camos.isUnlocked({ camoProgress = { headshots = required - 1 } }, id)).to.equal(false)
				expect(Camos.isUnlocked({ camoProgress = { headshots = required } }, id)).to.equal(true)
				expect(Camos.isUnlocked(goldEverywhere(), id)).to.equal(false)
			end
		end)

		it("has no remaining unlock after completing the release headshot ladder", function()
			local data = { camoProgress = { headshots = 100000 } }
			expect(Camos.nextUnlock(data)).to.equal(nil)
		end)
	end)

	--[[
		The Shoothouse once shipped fully specced and completely unreachable: no
		match loop referenced it and Bootstrap refused every mode but gauntlet.
		Nothing in a unit suite noticed, because unit specs call the rules module
		directly -- which is what they are for.

		These assert the DATA INVARIANT the player path actually depends on, so
		the gap cannot reopen quietly. The end-to-end proof that a course runs
		lives in tools/run-live-checks, which goes through MatchService.
	]]
	describe("mode integration", function()
		local modes = Config.get("gamemodes")

		it("only offers modes that have a live match loop", function()
			for _, name in ipairs(modes.order) do
				local mode = modes.modes[name]
				expect(mode).to.be.ok()
				expect(mode.integrated).to.equal(true)
			end
		end)

		it("offers the Shoothouse, and every field it lists has a course", function()
			expect(table.find(modes.order, "shoothouse")).to.be.ok()
			for _, name in ipairs(modes.modes.shoothouse.maps) do
				expect(Course.hasCourse(name)).to.equal(true)
			end
		end)

		it("keeps the default mode integrated", function()
			expect(modes.modes[modes.default].integrated).to.equal(true)
		end)

		--[[
			Deliberately asserted, not aspirational. Horde and Capture the Flag
			are pure rules modules with specs and no match loop; marking them
			integrated without wiring one would put them back in the exact state
			the Shoothouse was found in.
		]]
		it("does not pretend Horde or Capture the Flag are playable", function()
			expect(modes.modes.horde.integrated).to.equal(false)
			expect(modes.modes.captureTheFlag.integrated).to.equal(false)
			expect(table.find(modes.order, "horde")).to.equal(nil)
			expect(table.find(modes.order, "captureTheFlag")).to.equal(nil)
		end)
	end)
end
