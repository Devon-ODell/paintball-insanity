--!strict
--[[
	Courses -- pure reads over a profile's Shoothouse records.

	Shared because two very different callers need the same answer: Camos, to
	decide whether a course-earned finish is unlocked, and the client, to draw a
	player's best times. Neither may compute it their own way, or "all gold"
	starts meaning two things.

	Every read here is defensive. A record is persisted data and persisted data
	is the one input that arrives from a previous version of the game.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local Courses = {}

export type Record = {
	bestSeconds: number?,
	bestMedal: string?,
	runs: number,
	clears: number,
	bestDeaths: number?,
}

local MEDALS: { string } = { "bronze", "silver", "gold" }

local function isFinite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function counter(n: any): number
	if not isFinite(n) or n < 0 then
		return 0
	end
	return math.floor(n)
end

--- Ranks a medal weakest-first. Unknown or absent is 0, which is below bronze.
function Courses.medalRank(medal: any): number
	if type(medal) ~= "string" then
		return 0
	end
	return table.find(MEDALS, medal) or 0
end

--- One map's record, normalised. Always returns a table, never nil, so callers
--- do not each invent their own empty case.
function Courses.recordFor(data: any, mapName: string): Record
	local all = if type(data) == "table" then data.courseRecords else nil
	local entry = if type(all) == "table" then all[mapName] else nil
	if type(entry) ~= "table" then
		return { bestSeconds = nil, bestMedal = nil, runs = 0, clears = 0, bestDeaths = nil }
	end
	local best = entry.bestSeconds
	local deaths = entry.bestDeaths
	return {
		bestSeconds = if isFinite(best) and best > 0 then best else nil,
		-- A medal that is not on the ladder is not a medal.
		bestMedal = if Courses.medalRank(entry.bestMedal) > 0 then entry.bestMedal else nil,
		runs = counter(entry.runs),
		clears = counter(entry.clears),
		bestDeaths = if isFinite(deaths) and deaths >= 0 then math.floor(deaths) else nil,
	}
end

--- Maps whose best medal is at least `medal`. Counted over the courses that
--- actually exist on disk, so adding a sixth field moves the target honestly
--- rather than leaving an unlock stranded at the old count.
function Courses.medalCount(data: any, medal: string): number
	local want = Courses.medalRank(medal)
	local count = 0
	for _, name in ipairs(Config.mapNames()) do
		if Courses.medalRank(Courses.recordFor(data, name).bestMedal) >= want then
			count += 1
		end
	end
	return count
end

function Courses.goldCount(data: any): number
	return Courses.medalCount(data, "gold")
end

--- How many maps have a course authored at all. The denominator for "all gold".
function Courses.courseCount(): number
	local count = 0
	for _, name in ipairs(Config.mapNames()) do
		local ok, map = pcall(Config.map, name)
		if ok and type(map) == "table" and map.course then
			count += 1
		end
	end
	return count
end

--- The unlock predicate shared by camos and by the Aurum route. Kept in one
--- place because "gold on all five" is a rule, and a rule with two
--- implementations is a rule with two answers.
function Courses.meets(data: any, requirement: any): boolean
	if type(requirement) ~= "table" then
		return false
	end
	if requirement.kind == "courseGold" then
		local need = requirement.count
		if not isFinite(need) then
			return false
		end
		return Courses.goldCount(data) >= need
	elseif requirement.kind == "courseMedal" then
		local need = requirement.count
		if not isFinite(need) then
			return false
		end
		return Courses.medalCount(data, requirement.medal or "bronze") >= need
	end
	return false
end

--- Human-readable "what is left", for the shop and the camo board.
function Courses.remainingFor(data: any, requirement: any): number
	if type(requirement) ~= "table" or not isFinite(requirement.count) then
		return 0
	end
	local have = if requirement.kind == "courseMedal"
		then Courses.medalCount(data, requirement.medal or "bronze")
		else Courses.goldCount(data)
	return math.max(0, requirement.count - have)
end

return Courses
