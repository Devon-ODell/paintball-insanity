--!nolint
--[[
	Solo CTF. The assertions that matter are the ones about the RULES holding
	under abuse: you cannot capture into an empty plinth, a dropped flag is not
	a free reset, and the squad split must actually shift with the score --
	because reading that shift is the entire mode.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local Config = require(ReplicatedStorage.Shared.Config)
local CTF = require(Server.Match.CaptureTheFlag)

local function game()
	return CTF.new(Config.map("holdfast"))
end

local function actor(id: string, team: string, position: Vector3, alive: boolean?)
	return { id = id, team = team, position = position, alive = alive ~= false }
end

--- Steps until a predicate holds or the budget runs out.
local function pump(g: any, actors: { any }, seconds: number): { any }
	local all: { any } = {}
	local dt = 1 / 30
	for _ = 1, math.floor(seconds / dt) do
		for _, event in ipairs(g:step(dt, actors)) do
			table.insert(all, event)
		end
	end
	return all
end

local function kinds(events: { any }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, event in ipairs(events) do
		set[event.kind] = true
	end
	return set
end

return function()
	describe("setup", function()
		it("puts both flags home", function()
			local g = game()
			expect(g.flags.enemy.state).to.equal("home")
			expect(g.flags.player.state).to.equal("home")
			expect(g.score.player).to.equal(0)
		end)

		it("puts the two keeps at opposite ends", function()
			local g = game()
			expect(g.flags.enemy.home.Z > 0).to.equal(true)
			expect(g.flags.player.home.Z < 0).to.equal(true)
			expect((g.flags.enemy.home - g.flags.player.home).Magnitude > 100).to.equal(true)
		end)

		it("refuses a map with no CTF block", function()
			expect(function()
				CTF.new(Config.map("speedball"))
			end).to.throw()
		end)
	end)

	describe("taking and capturing", function()
		it("picks the flag up on touch", function()
			local g = game()
			local events = g:step(0.1, { actor("player", "player", g.flags.enemy.home) })
			expect(kinds(events).flagTaken).to.equal(true)
			expect(g.flags.enemy.state).to.equal("carried")
			expect(g.flags.enemy.carrier).to.equal("player")
		end)

		it("carries the flag with the carrier", function()
			local g = game()
			g:step(0.1, { actor("player", "player", g.flags.enemy.home) })
			local moved = g.flags.enemy.home + Vector3.new(0, 0, -20)
			g:step(0.1, { actor("player", "player", moved) })
			expect((g.flags.enemy.position - moved).Magnitude).to.be.near(0, 1e-6)
		end)

		it("scores a capture at your own plinth", function()
			local g = game()
			g:step(0.1, { actor("player", "player", g.flags.enemy.home) })
			local events = g:step(0.1, { actor("player", "player", g.flags.player.home) })
			expect(kinds(events).captured).to.equal(true)
			expect(g.score.player).to.equal(1)
			expect(g.flags.enemy.state).to.equal("home")
		end)

		it("refuses a capture while your own flag is out", function()
			--[[
				The rule that forces a solo player to care about defence. Without
				it the optimal play is to ignore their runner entirely and race,
				and the mode collapses into a footrace.
			]]
			local g = game()
			g:step(0.1, {
				actor("player", "player", g.flags.enemy.home),
				actor("bot1", "bots", g.flags.player.home),
			})
			expect(g.flags.player.state).to.equal("carried")

			local events = g:step(0.1, {
				actor("player", "player", g.flags.player.home),
				actor("bot1", "bots", g.flags.player.home + Vector3.new(0, 0, 10)),
			})
			expect(kinds(events).captured).to.equal(nil)
			expect(g.score.player).to.equal(0)
		end)

		it("lets the squad score too", function()
			local g = game()
			g:step(0.1, { actor("bot1", "bots", g.flags.player.home) })
			g:step(0.1, { actor("bot1", "bots", g.flags.enemy.home) })
			expect(g.score.bots).to.equal(1)
		end)
	end)

	describe("dropping", function()
		it("drops the flag where the carrier fell", function()
			local g = game()
			g:step(0.1, { actor("player", "player", g.flags.enemy.home) })
			local fellAt = g.flags.enemy.home + Vector3.new(4, 0, -30)
			g:step(0.1, { actor("player", "player", fellAt) })
			local events = g:step(0.1, { actor("player", "player", fellAt, false) })
			expect(kinds(events).flagDropped).to.equal(true)
			expect(g.flags.enemy.state).to.equal("dropped")
			expect((g.flags.enemy.position - fellAt).Magnitude).to.be.near(0, 1e-6)
		end)

		it("lets a dropped flag be picked straight back up", function()
			--[[
				A dropped flag is not a reset -- it is a flag lying in the open
				that both sides now want, which is the most interesting state in
				the mode.
			]]
			local g = game()
			g:step(0.1, { actor("player", "player", g.flags.enemy.home) })
			local fellAt = g.flags.enemy.home + Vector3.new(0, 0, -30)
			g:step(0.1, { actor("player", "player", fellAt) })
			g:step(0.1, { actor("player", "player", fellAt, false) })

			g:step(0.1, { actor("player2", "player", fellAt) })
			expect(g.flags.enemy.state).to.equal("carried")
			expect(g.flags.enemy.carrier).to.equal("player2")
		end)

		it("sends an abandoned flag home on the timer", function()
			local g = game()
			g:step(0.1, { actor("player", "player", g.flags.enemy.home) })
			local fellAt = g.flags.enemy.home + Vector3.new(0, 0, -30)
			g:step(0.1, { actor("player", "player", fellAt) })
			g:step(0.1, { actor("player", "player", fellAt, false) })

			local idle = Config.require("gamemodes", "captureTheFlag.flag.returnAfterSecondsIdle")
			local events = pump(g, { actor("nobody", "player", Vector3.new(500, 0, 500)) }, idle + 1)
			expect(kinds(events).flagReturned).to.equal(true)
			expect(g.flags.enemy.state).to.equal("home")
		end)

		it("returns your own flag instantly when you touch it", function()
			local g = game()
			g:step(0.1, { actor("bot1", "bots", g.flags.player.home) })
			local fellAt = g.flags.player.home + Vector3.new(0, 0, 25)
			g:step(0.1, { actor("bot1", "bots", fellAt) })
			g:step(0.1, { actor("bot1", "bots", fellAt, false) })
			expect(g.flags.player.state).to.equal("dropped")

			local events = g:step(0.1, { actor("player", "player", fellAt) })
			expect(kinds(events).flagRecovered).to.equal(true)
			expect(g.flags.player.state).to.equal("home")
			expect(g.returns).to.equal(1)
		end)
	end)

	describe("winning", function()
		it("ends at the capture target", function()
			local g = game()
			local target = Config.require("gamemodes", "captureTheFlag.capturesToWin")
			for _ = 1, target do
				g:step(0.1, { actor("player", "player", g.flags.enemy.home) })
				g:step(0.1, { actor("player", "player", g.flags.player.home) })
			end
			expect(g.finished).to.equal(true)
			expect(g.winner).to.equal("player")
		end)

		it("stops processing once it is over", function()
			local g = game()
			local target = Config.require("gamemodes", "captureTheFlag.capturesToWin")
			for _ = 1, target do
				g:step(0.1, { actor("player", "player", g.flags.enemy.home) })
				g:step(0.1, { actor("player", "player", g.flags.player.home) })
			end
			local after = g:step(0.1, { actor("player", "player", g.flags.enemy.home) })
			expect(#after).to.equal(0)
			expect(g.score.player).to.equal(target)
		end)

		it("calls time on the clock", function()
			local g = game()
			g.elapsed = Config.require("gamemodes", "captureTheFlag.timeLimitSeconds") - 0.05
			local events = g:step(0.1, {})
			expect(kinds(events).timeUp).to.equal(true)
			expect(g.winner).to.equal("draw")
		end)
	end)

	describe("the squad split", function()
		it("defends more than it attacks at level score", function()
			local g = game()
			local split = g:squadSplit(6)
			expect(split.defenders + split.attackers).to.equal(6)
			expect(split.defenders > split.attackers).to.equal(true)
		end)

		it("pushes when behind and turtles when ahead", function()
			--[[
				The read the whole mode is built to teach: watch the split shift,
				then hit whichever half just got thinner.
			]]
			local behind = game()
			behind.score.player = 2
			behind._lastAssign = -math.huge
			local pushing = behind:squadSplit(6)

			local ahead = game()
			ahead.score.bots = 2
			ahead._lastAssign = -math.huge
			local turtling = ahead:squadSplit(6)

			expect(pushing.attackers > turtling.attackers).to.equal(true)
			expect(turtling.defenders > pushing.defenders).to.equal(true)
		end)

		it("never leaves the keep completely unattended", function()
			for _, size in ipairs({ 1, 2, 3, 6, 10 }) do
				local g = game()
				g.score.bots = 5
				g._lastAssign = -math.huge
				local split = g:squadSplit(size)
				expect(split.defenders >= 1).to.equal(true)
				expect(split.defenders + split.attackers).to.equal(size)
			end
		end)

		it("holds a split for the reassign interval", function()
			local g = game()
			local first = g:squadSplit(6)
			g.score.player = 3
			local second = g:squadSplit(6)
			expect(second.defenders).to.equal(first.defenders)
		end)
	end)

	describe("bot objectives", function()
		it("sends defenders to the flag, not to an empty plinth", function()
			--[[
				Sitting on an empty plinth while the flag is halfway across the
				map is how defence AI looks stupid.
			]]
			local g = game()
			g:step(0.1, { actor("player", "player", g.flags.enemy.home) })
			local away = g.flags.enemy.home + Vector3.new(0, 0, -40)
			g:step(0.1, { actor("player", "player", away) })

			local objective = g:objectiveFor("defend", "bot1")
			expect((objective - away).Magnitude).to.be.near(0, 1e-6)
		end)

		it("sends attackers at the player's flag", function()
			local g = game()
			expect((g:objectiveFor("attack", "bot1") - g.flags.player.home).Magnitude).to.be.near(0, 1e-6)
		end)

		it("sends a carrier home regardless of role", function()
			local g = game()
			g:step(0.1, { actor("bot1", "bots", g.flags.player.home) })
			expect(g:isCarrier("bot1")).to.equal(true)
			expect((g:objectiveFor("defend", "bot1") - g.flags.enemy.home).Magnitude).to.be.near(0, 1e-6)
		end)
	end)

	describe("carrying costs", function()
		it("slows the carrier and makes them loud", function()
			local g = game()
			g:step(0.1, { actor("player", "player", g.flags.enemy.home) })
			local mods = g:carrierModifiers("player")
			expect(mods.sprint < 1).to.equal(true)
			expect(mods.loudness > 1).to.equal(true)
		end)

		it("leaves everyone else alone", function()
			local g = game()
			local mods = g:carrierModifiers("bot1")
			expect(mods.sprint).to.equal(1)
			expect(mods.loudness).to.equal(1)
		end)
	end)

	describe("payout", function()
		it("pays per capture and per return", function()
			local g = game()
			g.captures = 2
			g.returns = 3
			local p = Config.require("gamemodes", "captureTheFlag.payout")
			expect(g:payout()).to.equal(2 * p.perCapture + 3 * p.perFlagReturn)
		end)

		it("adds the win bonus only on a win", function()
			local g = game()
			g.captures = 3
			local without = g:payout()
			g.winner = "player"
			expect(g:payout() > without).to.equal(true)
		end)

		it("pays nothing for doing nothing", function()
			expect(game():payout()).to.equal(0)
		end)
	end)

	describe("mode gating", function()
		it("locks CTF behind the Woods chapter", function()
			expect(Config.require("gamemodes", "modes.captureTheFlag.unlockRequires")).to.equal("backForty")
		end)

		it("locks horde behind the pro circuit", function()
			expect(Config.require("gamemodes", "modes.horde.unlockRequires")).to.equal("proCircuit")
		end)

		it("leaves the gauntlet always open", function()
			-- JSON null decodes as absent, so this reads the table directly
			-- rather than through Config.require, which errors on a missing key.
			local gauntlet = Config.get("gamemodes").modes.gauntlet
			expect(gauntlet.unlockRequires).to.equal(nil)
		end)

		it("only offers CTF on the map built for it", function()
			local maps = Config.require("gamemodes", "modes.captureTheFlag.maps")
			expect(#maps).to.equal(1)
			expect(maps[1]).to.equal("holdfast")
		end)
	end)
end
