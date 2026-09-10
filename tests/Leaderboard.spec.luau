--!nolint
--[[
	The leaderboard's validation and formatting halves, which are the parts that
	matter and the parts that are pure. The DataStore half is thin by design and
	needs a live server.

	A leaderboard is the one place in this game where a bad number is permanent,
	so the validation is tested from the hostile direction: every way a run could
	claim a time it did not earn.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local Leaderboard = require(Server.Leaderboard.Leaderboard)
local RoundSchedule = require(Server.Match.RoundSchedule)
local Config = require(ReplicatedStorage.Shared.Config)

--- A legitimate full clear: five rounds, 2+3+4+5+6 = 20 eliminations.
local function fullClear(overrides: any): any
	local expected = 0
	for _, round in ipairs(RoundSchedule.all("rec")) do
		expected += round.botCount
	end
	local submission = {
		userId = 1234,
		displayName = "Tester",
		map = "speedball",
		tier = "rec",
		marker = "mechanical",
		seconds = 240,
		deaths = 3,
		eliminations = expected,
		roundsCleared = 5,
		roundsPlayed = 5,
	}
	for k, v in pairs(overrides or {}) do
		submission[k] = v
	end
	return submission
end

local function expectedEliminations(): number
	local total = 0
	for _, round in ipairs(RoundSchedule.all("rec")) do
		total += round.botCount
	end
	return total
end

return function()
	describe("validation", function()
		it("accepts a legitimate full clear", function()
			local ok, reason = Leaderboard.validate(fullClear({}), expectedEliminations())
			expect(ok).to.equal(true)
			expect(reason).to.equal(nil)
		end)

		it("refuses a partial clear", function()
			--[[
				A time means ALL FIVE rounds. Four rounds and a timeout is not a
				fast run, it is an unfinished one, and putting it on the board
				would make the board meaningless.
			]]
			local ok, reason = Leaderboard.validate(
				fullClear({ roundsCleared = 4, seconds = 90 }),
				expectedEliminations()
			)
			expect(ok).to.equal(false)
			expect((reason :: string):find("4 of 5") ~= nil).to.equal(true)
		end)

		it("refuses a run whose eliminations do not match the schedule", function()
			-- Twenty bots die in a five-round match. Anything else did not happen.
			local ok = Leaderboard.validate(fullClear({ eliminations = 6 }), expectedEliminations())
			expect(ok).to.equal(false)
		end)

		it("refuses a time below the physical floor", function()
			local floor = Config.require("leaderboard", "validation.minimumSecondsPerRound")
			local ok, reason = Leaderboard.validate(
				fullClear({ seconds = floor * 5 - 0.01 }),
				expectedEliminations()
			)
			expect(ok).to.equal(false)
			expect((reason :: string):find("floor") ~= nil).to.equal(true)
		end)

		it("accepts a time exactly at the floor", function()
			local floor = Config.require("leaderboard", "validation.minimumSecondsPerRound")
			expect(Leaderboard.validate(fullClear({ seconds = floor * 5 }), expectedEliminations())).to.equal(true)
		end)

		it("refuses an absurdly long time", function()
			expect(Leaderboard.validate(fullClear({ seconds = 99999 }), expectedEliminations())).to.equal(false)
		end)

		it("refuses NaN", function()
			expect(Leaderboard.validate(fullClear({ seconds = 0 / 0 }), expectedEliminations())).to.equal(false)
		end)

		it("refuses a match with no rounds", function()
			expect(Leaderboard.validate(
				fullClear({ roundsPlayed = 0, roundsCleared = 0 }),
				expectedEliminations()
			)).to.equal(false)
		end)
	end)

	describe("time encoding", function()
		it("round-trips through centiseconds", function()
			for _, seconds in ipairs({ 0, 1.23, 62.5, 240.07, 3599.99 }) do
				local encoded = Leaderboard.toCentiseconds(seconds)
				expect(Leaderboard.fromCentiseconds(encoded)).to.be.near(seconds, 0.005)
			end
		end)

		it("encodes to an integer, because OrderedDataStore requires one", function()
			local encoded = Leaderboard.toCentiseconds(123.456)
			expect(encoded).to.equal(math.floor(encoded))
		end)

		it("preserves ordering", function()
			expect(Leaderboard.toCentiseconds(90.1) < Leaderboard.toCentiseconds(90.2)).to.equal(true)
		end)
	end)

	describe("formatting", function()
		it("reads as minutes and seconds", function()
			expect(Leaderboard.formatTime(247.32)).to.equal("4:07.32")
			expect(Leaderboard.formatTime(59.5)).to.equal("0:59.50")
			expect(Leaderboard.formatTime(3600)).to.equal("60:00.00")
		end)

		it("pads the seconds so a column of times lines up", function()
			expect(#Leaderboard.formatTime(65)).to.equal(#Leaderboard.formatTime(125))
		end)

		it("does not crash on nonsense", function()
			expect(Leaderboard.formatTime(0 / 0)).to.equal("--:--")
			expect(Leaderboard.formatTime(-5)).to.equal("--:--")
		end)
	end)

	describe("ranking", function()
		it("sorts fastest first", function()
			local ranked = Leaderboard.rank({
				{ userId = 1, displayName = "Slow", seconds = 300 },
				{ userId = 2, displayName = "Fast", seconds = 180 },
				{ userId = 3, displayName = "Middle", seconds = 240 },
			})
			expect(ranked[1].displayName).to.equal("Fast")
			expect(ranked[1].rank).to.equal(1)
			expect(ranked[3].displayName).to.equal("Slow")
		end)

		it("breaks ties on deaths, which is the tiebreak the rest of the game uses", function()
			local ranked = Leaderboard.rank({
				{ userId = 1, displayName = "Messy", seconds = 200, deaths = 9 },
				{ userId = 2, displayName = "Clean", seconds = 200, deaths = 0 },
			})
			expect(ranked[1].displayName).to.equal("Clean")
		end)

		it("carries the tier through, because it is the interesting column", function()
			--[[
				Times are NOT normalised by tier. A rec clear and a pro clear sit
				on the same board with the tier shown, because the interesting
				question is not "who is fastest" but "who was fastest against
				what". Adjusting for tier would hide exactly that.
			]]
			local ranked = Leaderboard.rank({
				{ userId = 1, displayName = "A", seconds = 200, tier = "pro", marker = "pump" },
			})
			expect(ranked[1].tier).to.equal("pro")
			expect(ranked[1].marker).to.equal("pump")
		end)

		it("handles an empty board", function()
			expect(#Leaderboard.rank({})).to.equal(0)
		end)

		it("does not mutate its input", function()
			local input = {
				{ userId = 1, displayName = "B", seconds = 300 },
				{ userId = 2, displayName = "A", seconds = 100 },
			}
			Leaderboard.rank(input)
			expect(input[1].displayName).to.equal("B")
		end)
	end)

	--[[
		Horde never finishes, so it could never reach a board gated on `cleared`.

		The declared wave leaderboard never wrote a single row in its life. A
		depth is not a time -- bigger is better and there is no last round to
		have cleared -- so it is a board with its own rules rather than a special
		case threaded through the time board's validation.
	]]
	describe("the wave board", function()
		local function hordeRun(overrides: any?)
			local submission = fullClear({
				mode = "horde",
				depth = 12,
				roundsCleared = 12,
				roundsPlayed = 13,
				seconds = 480,
			})
			for k, v in pairs(overrides or {}) do submission[k] = v end
			return submission
		end

		it("ranks horde on depth, descending", function()
			local rules = Leaderboard.boardRules("horde")
			expect(rules.rankBy).to.equal("depth")
			expect(rules.ascending).to.equal(false)
		end)

		it("leaves every other mode a time board, ascending", function()
			for _, mode in ipairs({ "gauntlet", "shoothouse" }) do
				local rules = Leaderboard.boardRules(mode)
				expect(rules.rankBy).to.equal("time")
				expect(rules.ascending ~= false).to.equal(true)
			end
			--- Absent means gauntlet, which is what every stored row was before
			--- there was more than one mode.
			expect(Leaderboard.boardRules(nil).rankBy).to.equal("time")
		end)

		--[[
			A run that never cleared a "final" round is exactly what horde IS.
			The time board's rules cannot describe it and must not be applied.
		]]
		it("accepts a run that cleared no final round", function()
			local ok, reason = Leaderboard.validate(hordeRun(), 0)
			expect(ok).to.equal(true)
			expect(reason).to.equal(nil)
		end)

		it("refuses a depth that is not a whole number of waves", function()
			expect((Leaderboard.validate(hordeRun({ depth = 4.5 }), 0))).to.equal(false)
			expect((Leaderboard.validate(hordeRun({ depth = 0 }), 0))).to.equal(false)
			expect((Leaderboard.validate(hordeRun({ depth = 0 / 0 }), 0))).to.equal(false)
			--- Missing entirely, which is what a caller that forgot the field
			--- would send. `pairs` cannot express a removal, so it is built
			--- without one.
			local noDepth = hordeRun()
			noDepth.depth = nil
			expect((Leaderboard.validate(noDepth, 0))).to.equal(false)
		end)

		--- You cannot have survived more waves than you played.
		it("refuses a depth deeper than the run", function()
			expect((Leaderboard.validate(hordeRun({ depth = 20, roundsPlayed = 13 }), 0))).to.equal(false)
		end)

		it("puts the deepest run first, and breaks a tie on outs", function()
			local ranked = Leaderboard.rank({
				{ userId = 1, displayName = "Shallow", seconds = 100, depth = 8, deaths = 0 },
				{ userId = 2, displayName = "Deep", seconds = 900, depth = 22, deaths = 9 },
				{ userId = 3, displayName = "Tied", seconds = 800, depth = 22, deaths = 2 },
			})
			expect(ranked[1].displayName).to.equal("Tied")
			expect(ranked[2].displayName).to.equal("Deep")
			expect(ranked[3].displayName).to.equal("Shallow")
		end)
	end)

	--[[
		Times were already separated by mode. The DECORATION next to each name
		was not: it was keyed on `{map}_{userId}` alone, so a Shoothouse personal
		best overwrote the tier, marker and out count shown against that player's
		gauntlet time on the same field.
	]]
	describe("record separation", function()
		it("keys a row's metadata per board, not per map", function()
			local gauntlet = Leaderboard.metaKey("speedball", "gauntlet", 1234)
			local course = Leaderboard.metaKey("speedball", "shoothouse", 1234)
			local horde = Leaderboard.metaKey("speedball", "horde", 1234)
			expect(gauntlet).never.to.equal(course)
			expect(course).never.to.equal(horde)
			--- Gauntlet keeps the bare key it has always had, so no stored
			--- decoration is orphaned by the separation.
			expect(gauntlet).to.equal(Leaderboard.metaKey("speedball", nil, 1234))
			expect(gauntlet).to.equal("speedball_1234")
		end)

		it("keeps two players' rows apart on the same board", function()
			expect(Leaderboard.metaKey("woods", "shoothouse", 1))
				.never.to.equal(Leaderboard.metaKey("woods", "shoothouse", 2))
		end)
	end)

	describe("configuration", function()
		it("quarantines dev runs onto separate keys", function()
			--[[
				Testing with infinite money and skipped rounds must never be able
				to touch the real board. The suffix is what guarantees it.
			]]
			local suffix = Config.require("leaderboard", "store.devSuffix")
			expect(#suffix > 0).to.equal(true)
		end)

		it("shows the tier rather than adjusting for it", function()
			expect(Config.require("leaderboard", "tierWeighting.showTier")).to.equal(true)
		end)

		it("cycles pages slowly enough to read while walking past", function()
			expect(Config.require("leaderboard", "display.pageSeconds") >= 6).to.equal(true)
		end)
	end)
end
