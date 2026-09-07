--!strict
--[[
	CourseProgress -- persistent Shoothouse records.

	The mutating half of the course. Course itself is pure and decides what a run
	was worth; this decides what the profile remembers about it, in the same
	split Progression/Camos and Shared/Camos already use.

	Records are the whole reason to run a course twice, so what is kept is
	deliberately small and hard to argue with: your best time, the best medal
	that time earned, how many runs and clears, and the fewest deaths you have
	ever finished with.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Courses = require(ReplicatedStorage.Shared.Courses)
local Course = require(script.Parent.Parent.Match.Course)

local CourseProgress = {}

export type RunResult = {
	mapName: string,
	--- Clock time only. The death penalty is added here, not by the caller.
	liveSeconds: number,
	deaths: number,
	cleared: boolean,
	playerCount: number,
}

export type Outcome = {
	seconds: number,
	medal: string?,
	--- Medal tiers reached on this map for the first time, weakest first.
	newMedals: { string },
	isRecord: boolean,
	previousBest: number?,
	payout: number,
	goldCount: number,
	--- False for a co-op run: it ranks and it is recorded, it just does not buy
	--- the Aurum. See Data/course.json coop.countsTowardAurum.
	countsTowardAurum: boolean,
}

local function ensure(data: any, mapName: string): any
	data.courseRecords = if type(data.courseRecords) == "table" then data.courseRecords else {}
	local entry = data.courseRecords[mapName]
	if type(entry) ~= "table" then
		entry = { runs = 0, clears = 0 }
		data.courseRecords[mapName] = entry
	end
	return entry
end

--[[
	Records one finished run and returns what it was worth.

	A run that was not cleared still counts as a run and still pays the "none"
	multiplier -- you were there, you shot at people, the field takes your money
	either way -- but it never sets a time, a medal or a record.
]]
function CourseProgress.record(handle: any, run: RunResult): Outcome?
	if not handle:isActive() then
		return nil
	end
	local data = handle.data
	local entry = ensure(data, run.mapName)
	local previous = Courses.recordFor(data, run.mapName)

	entry.runs = previous.runs + 1
	local seconds = Course.finalSeconds(run.liveSeconds, run.deaths)
	local medal: string? = nil
	local newMedals: { string } = {}
	local isRecord = false

	if run.cleared then
		entry.clears = previous.clears + 1
		medal = Course.medalFor(run.mapName, seconds)
		isRecord = Course.isRecord(seconds, previous.bestSeconds)
		if isRecord then
			entry.bestSeconds = seconds
		end
		-- Medals ratchet: a slower run today never takes yesterday's gold away.
		if Course.isBetterMedal(medal, previous.bestMedal) then
			for _, id in ipairs(Course.medals()) do
				if Course.medalRank(id) > Course.medalRank(previous.bestMedal)
					and Course.medalRank(id) <= Course.medalRank(medal) then
					table.insert(newMedals, id)
				end
			end
			entry.bestMedal = medal
		end
		if previous.bestDeaths == nil or run.deaths < previous.bestDeaths then
			entry.bestDeaths = run.deaths
		end
	end

	return {
		seconds = seconds,
		medal = medal,
		newMedals = newMedals,
		isRecord = isRecord,
		previousBest = previous.bestSeconds,
		payout = Course.payoutFor(run.mapName, medal, newMedals),
		goldCount = Courses.goldCount(data),
		countsTowardAurum = Course.countsTowardAurum(run.playerCount),
	}
end

--- Every map's record, in curriculum order, for the board and the client.
function CourseProgress.summary(data: any): { any }
	local out = {}
	for _, name in ipairs(require(ReplicatedStorage.Shared.Config).mapNames()) do
		if Course.hasCourse(name) then
			local record = Courses.recordFor(data, name)
			table.insert(out, {
				mapName = name,
				bestSeconds = record.bestSeconds,
				bestMedal = record.bestMedal,
				runs = record.runs,
				clears = record.clears,
				bestDeaths = record.bestDeaths,
				par = Course.parSeconds(name),
			})
		end
	end
	return out
end

return CourseProgress
