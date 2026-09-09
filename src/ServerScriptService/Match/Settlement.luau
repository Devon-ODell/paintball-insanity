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
]]

local ServerScriptService = game:GetService("ServerScriptService")
local Server = ServerScriptService.Server
local Payout = require(Server.Economy.Payout)
local CourseProgress = require(Server.Progression.CourseProgress)

local Settlement = {}

export type Params = {
	isCourse: boolean,
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
	Returns the payout breakdown, and the course record when there is one.

	The course branch writes the run's record as a side effect --
	`CourseProgress.record` is what decides the medal and therefore what the run
	was worth, so the two cannot be separated without computing the medal twice.
]]
function Settlement.payout(handle: any, params: Params): (any, any)
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
