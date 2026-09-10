--!strict
--[[
	Horde, as the match loop actually sees it.

	`Endless` was pure and spec-covered from the start; what was missing was
	anything that ran it. These cover the seam that integration added -- a wave
	expressed as a ROUND the ordinary loop can execute -- and the two rules that
	would silently stop being true if someone retuned the data.

	The mode has no failure state of its own. It ends on the ordinary round time
	limit, which is what "it does not have an end, only a depth you stopped at"
	means in code. Nothing here needs to assert that because nothing here
	implements it: the gauntlet's clock does.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local Endless = require(Server.Match.Endless)
local BotController = require(Server.Bots.BotController)
local Rng = require(ReplicatedStorage.Shared.Rng)
local Config = require(ReplicatedStorage.Shared.Config)

return function()
	describe("a wave as a round", function()
		it("fields the concurrent cap, never the whole wave at once", function()
			local cap = Config.require("endless", "waves.concurrentCap")
			for index = 1, 60 do
				local round = Endless.round(index)
				expect(round.botCount <= cap).to.equal(true)
				expect(round.botCount > 0).to.equal(true)
			end
		end)

		--[[
			The bodies past the cap have to arrive as replacements or they are
			simply lost, and depth would stop meaning anything after the wave
			totals exceed twelve.
		]]
		it("sends everything past the cap in as reinforcements", function()
			for index = 1, 60 do
				local wave = Endless.wave(index)
				local round = Endless.round(index)
				expect(round.botCount + round.reinforcements).to.equal(wave.botCount)
			end
		end)

		it("pays nothing per round -- horde is paid once, for depth", function()
			expect(Endless.round(1).payoutMultiplier).to.equal(0)
			expect(Endless.round(30).payoutMultiplier).to.equal(0)
		end)

		--- Every fifth wave is the only time nobody is shooting at you.
		it("pauses on breathers and runs straight on otherwise", function()
			local every = Config.require("endless", "waves.breatherEveryWaves")
			for index = 1, 30 do
				local pause = Endless.round(index).intermissionSeconds
				if index % every == 0 then
					expect(pause > 0).to.equal(true)
				else
					expect(pause).to.equal(0)
				end
			end
		end)

		it("names a marshal on boss waves and nobody otherwise", function()
			local every = Config.require("endless", "waves.bossEveryWaves")
			for index = 1, 30 do
				local wave = Endless.round(index).endless
				expect(wave.isBoss).to.equal(index % every == 0)
				if wave.isBoss then
					expect(type(wave.boss)).to.equal("string")
				end
			end
		end)
	end)

	describe("a field marshal", function()
		local function bot(boss: string?)
			return BotController.new({
				id = "probe",
				name = "Probe",
				tier = "pro",
				role = "anchor",
				anchorId = "a",
				position = Vector3.new(0, 0, 0),
				facing = Vector3.new(0, 0, -1),
				world = { volumes = {}, botSpawns = {}, prePlacement = {} } :: any,
				coordinator = {} :: any,
				rng = Rng.new(1),
				boss = boss,
			})
		end

		--[[
			The whole boss rule, and the reason it needs no new hit model: paint
			on the body does not count because the body is not a target. A
			marshal presenting a body-length capsule would mean the rule was
			never applied and the "boss" is just a bot in a different hat.
		]]
		it("presents its hopper instead of its body", function()
			local common = Config.require("bosses", "common")
			local target = BotController.asTarget(bot("marshal"))
			expect(target.radius).to.equal(common.hopperRadiusMetres)
			expect(target.height < 0.8).to.equal(true)
			expect(target.position.Y + target.height / 2).to.be.near(common.hopperHeightMetres, 1e-6)
		end)

		it("is a far smaller target than an ordinary bot", function()
			local ordinary = BotController.asTarget(bot(nil))
			local marshal = BotController.asTarget(bot("marshal"))
			expect(marshal.height < ordinary.height / 2).to.equal(true)
		end)

		--- One hit is still one hit. A boss that took two would break the rule
		--- every other thing in this game rests on.
		it("is still eliminated by a single mark", function()
			local marshal = bot("marshal")
			expect(marshal.alive).to.equal(true)
			BotController.eliminate(marshal, 0)
			expect(marshal.alive).to.equal(false)
		end)
	end)

	describe("payout", function()
		--[[
			Superlinear in depth on purpose: if three runs to wave 10 paid as
			well as one to wave 30, farming the shallow end would be the optimal
			play, which is the opposite of what an endless mode is for.
		]]
		it("makes depth worth more than repetition", function()
			expect(Endless.payoutFor(30, 0) > Endless.payoutFor(10, 0) * 3).to.equal(true)
		end)

		it("pays nothing for a run that reached nowhere", function()
			expect(Endless.payoutFor(0, 0)).to.equal(0)
		end)

		--[[
			`bossBonus` was authored, tuned, and multiplied by a literal zero.

			`Settlement.payout` called `Endless.payoutFor(depth, 0)`, so the
			hardest thing in the mode paid exactly what an ordinary wave of the
			same depth paid. A number in the data that nothing can move is worse
			than no number, because it reads as a decision somebody made.
		]]
		it("pays a boss bonus that is actually worth something", function()
			expect(Config.require("endless", "payout.bossBonus") > 0).to.equal(true)
			expect(Endless.payoutFor(10, 1) > Endless.payoutFor(10, 0)).to.equal(true)
			expect(Endless.payoutFor(10, 2) - Endless.payoutFor(10, 1))
				.to.equal(Endless.payoutFor(10, 1) - Endless.payoutFor(10, 0))
		end)
	end)

	--[[
		Settlement is where the boss bonus and the depth actually reach a player,
		and where every one of them used to be dropped.
	]]
	describe("what a horde run settles to", function()
		local Settlement = require(Server.Match.Settlement)
		local Payout = require(Server.Economy.Payout)

		local function reports(waves: { { cleared: boolean, isBoss: boolean? } })
			local out = {}
			for index, wave in ipairs(waves) do
				table.insert(out, {
					index = index, tier = "rec", botCount = 4, payoutMultiplier = 0,
					cleared = wave.cleared, isBoss = wave.isBoss, deaths = 0,
					eliminations = 0, shots = 0, hits = 0,
				})
			end
			return out
		end
		local function settle(waves: any, deaths: number)
			return (Settlement.payout({ isActive = function() return true end, data = {} }, {
				isCourse = false, isHorde = true, mapName = "speedball", markerName = "mechanical",
				reports = reports(waves), schedule = {}, deaths = deaths, shots = 10, hits = 5,
				longestStreak = 1, liveSeconds = 60, cleared = false,
			}))
		end

		it("counts the marshals that actually fell, and pays for them", function()
			local plain = settle({ { cleared = true }, { cleared = true }, { cleared = false } }, 0)
			local withBoss = settle({ { cleared = true }, { cleared = true, isBoss = true }, { cleared = false } }, 0)
			expect(plain.bossesBeaten).to.equal(0)
			expect(withBoss.bossesBeaten).to.equal(1)
			expect(withBoss.total > plain.total).to.equal(true)
		end)

		--- The wave you died on does not pay, including if it was the boss.
		it("does not pay for a marshal who was still standing", function()
			local died = settle({ { cleared = true }, { cleared = false, isBoss = true } }, 0)
			expect(died.bossesBeaten).to.equal(0)
			expect(died.wavesSurvived).to.equal(1)
		end)

		--[[
			The summary panel reads `deathPenalty` and shows x1 when it is
			absent, so a horde run that lost half its payout to respawns
			reported a full one.
		]]
		it("states the death penalty it actually applied", function()
			local clean = settle({ { cleared = true }, { cleared = true } }, 0)
			local costly = settle({ { cleared = true }, { cleared = true } }, 6)
			expect(clean.deathPenalty).to.equal(1)
			expect(costly.deathPenalty).to.equal(Payout.deathPenalty(6))
			expect(costly.deathPenalty < 1).to.equal(true)
			expect(costly.total < clean.total).to.equal(true)
		end)
	end)
end
