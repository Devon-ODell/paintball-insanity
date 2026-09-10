--!strict
--[[
	Settlement -- what a finished match was worth, and by which of the two rules.

	Lifted out of MatchService.finish, which had grown to 228 lines inside a
	1,171-line closure. This is the one piece of that function with a single
	clear responsibility and no engine surface at all: it takes what the server
	counted and returns a payout breakdown. Nothing here touches an Instance, a
	remote or a player's character.

	The two rules are the reason this is worth naming rather than inlining.

	A **gauntlet** is paid per round and charged once, at the end, for the whole
	match's deaths. Accumulating deaths across five rounds and billing them
	together is what stops the easy early rounds becoming free practice.

	A **course** is paid per medal instead, because its clock already carries the
	deaths at ten seconds each. Charging the economy's exponential death penalty
	on top of that would price one mistake twice -- once in the time and again
	in the money -- which reads to a player as the game being unfair rather than
	as it being hard.

	**Horde** is paid once, for the depth reached, and superlinearly: wave 30 is
	worth far more than three runs to wave 10. A linear curve would make farming
	the easy early waves the optimal play, which is the exact opposite of what an
	endless mode is for. The ordinary death penalty still applies, so
	brute-forcing depth with forty respawns still earns almost nothing -- the
	same rule as everywhere else in this game.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local Server = ServerScriptService.Server
local Payout = require(Server.Economy.Payout)
local CourseProgress = require(Server.Progression.CourseProgress)
local Endless = require(Server.Match.Endless)

local Settlement = {}

export type Params = {
	isCourse: boolean,
	isHorde: boolean,
	mapName: string,
	markerName: string,
	--- One entry per round actually played.
	reports: { any },
	--- The schedule the match was supposed to run, for the expected-rounds term.
	schedule: { any },
	deaths: number,
	shots: number,
	hits: number,
	longestStreak: number,
	liveSeconds: number,
	cleared: boolean,
}

--[[
	Boss waves actually beaten.

	`Endless.payoutFor` has taken a boss count since it was written and the only
	caller passed a literal zero, so `endless.payout.bossBonus` was authored,
	tuned and multiplied by nothing on every run. A boss is the hardest thing in
	the mode and it paid exactly what an ordinary wave of the same depth paid.

	Counted from cleared reports the same way depth is, so the wave you died on
	does not pay -- including if it was the boss.
]]
local function bossesBeaten(reports: { any }): number
	local count = 0
	for _, report in ipairs(reports) do
		if report.cleared and report.isBoss then
			count += 1
		end
	end
	return count
end

--[[
	Returns the payout breakdown, and the course record when there is one.

	The course branch writes the run's record as a side effect --
	`CourseProgress.record` is what decides the medal and therefore what the run
	was worth, so the two cannot be separated without computing the medal twice.
]]
--[[
	Waves fully cleared.

	A horde run is not paid for the wave it died on, so this counts cleared
	reports rather than the depth reached: reaching wave 20 and losing it is a
	wave-19 run.
]]
local function wavesSurvived(reports: { any }): number
	local count = 0
	for _, report in ipairs(reports) do
		if report.cleared then
			count += 1
		end
	end
	return count
end

function Settlement.payout(handle: any, params: Params): (any, any)
	if params.isHorde then
		local depth = wavesSurvived(params.reports)
		local bosses = bossesBeaten(params.reports)
		local total = Endless.payoutFor(depth, bosses)
		--[[
			Depth is charged for deaths the same way a gauntlet is. Payout.apply
			owns that curve, so horde cannot drift from the rule the rest of the
			game is balanced around: death costs payout, never progress.
		]]
		return {
			total = math.floor(total * Payout.deathPenalty(params.deaths) + 0.5),
			cleared = false,
			roundsCleared = depth,
			roundsPlayed = #params.reports,
			wavesSurvived = depth,
			bossesBeaten = bosses,
			--[[
				The death penalty, stated rather than left to a default.

				The summary panel reads `deathPenalty` and shows x1 when it is
				absent, so a horde run that lost half its payout to respawns
				reported a full one. The number below is the number that was
				actually applied.
			]]
			deathPenalty = Payout.deathPenalty(params.deaths),
		}, nil
	end
	if not params.isCourse then
		local roundResults: { Payout.RoundResult } = {}
		for index, report in ipairs(params.reports) do
			roundResults[index] = {
				index = report.index,
				tier = report.tier,
				payoutMultiplier = report.payoutMultiplier,
				cleared = report.cleared,
			}
		end
		return Payout.computeMatch({
			expectedRounds = #params.schedule,
			map = params.mapName,
			marker = params.markerName,
			rounds = roundResults,
			deaths = params.deaths,
			shots = params.shots,
			hits = params.hits,
			longestStreak = params.longestStreak,
		}), nil
	end

	local outcome = CourseProgress.record(handle, {
		mapName = params.mapName,
		liveSeconds = params.liveSeconds,
		deaths = params.deaths,
		cleared = params.cleared,
		playerCount = 1,
	})
	local roundsCleared = 0
	for _, report in ipairs(params.reports) do
		if report.cleared then
			roundsCleared += 1
		end
	end
	return {
		total = if outcome then outcome.payout else 0,
		cleared = params.cleared,
		roundsCleared = roundsCleared,
		roundsPlayed = #params.reports,
		course = outcome,
	}, outcome
end

return Settlement
