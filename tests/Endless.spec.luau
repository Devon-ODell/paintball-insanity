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
	end)
end
