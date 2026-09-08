--!strict
--[[
	Course -- Shoothouse stage composition, timing and medals.

	Pure, in the same sense Endless and RoundSchedule are pure: given a map and a
	stage index it says who is defending, from which anchors, at what tier. It
	builds nothing and it touches no profile. MatchService does the instancing;
	Progression/CourseProgress does the persisting.

	The mode is one map met in order. Every field already declares fourteen
	anchors -- the authored cover positions its bots fight from -- and a course
	is those fourteen sorted by depth and dealt out two, three, four, five. Each
	stage's cover then refills once (wavesPerStage), so a course fields
	twenty-eight defenders without ever putting two bodies on one bunker. That is
	why this module can be pure: there is no new geometry to invent, only an
	ordering to apply to geometry the map already had.

	Timing is one clock with no pauses. Dying costs `deathPenaltySeconds` and a
	checkpoint, never the run -- the same bargain the rest of the game makes,
	restated in the only currency a timed mode has.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)
local RoundSchedule = require(script.Parent.RoundSchedule)

local Course = {}

export type Checkpoint = {
	position: Vector3,
	lookAt: Vector3,
}

export type Stage = {
	index: number,
	id: string,
	displayName: string,
	note: string,
	tier: Types.BotTier,
	--- The map anchors this stage's defenders hold. One defender per anchor,
	--- per wave -- never two bodies on the same bunker at the same time.
	anchorIds: { string },
	--- Alive at once.
	concurrent: number,
	--- How many times this stage's cover refills before the field moves up.
	waves: number,
	--- Everyone this stage will field, across all its waves.
	botCount: number,
	checkpoint: Checkpoint,
	isFinal: boolean,
}

export type Par = {
	gold: number,
	silver: number,
	bronze: number,
}

--- Every medal, weakest first. "none" is not a medal and is never in here.
local MEDALS: { string } = { "bronze", "silver", "gold" }

local function rules(): any
	return Config.get("course")
end

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

--- The course block for a map, or nil if that map has no course authored.
--- Config.map errors on an unknown map rather than returning nil, so an
--- unrecognised name has to read as "no course" here, not as a crash.
function Course.data(mapName: string): any?
	local ok, map = pcall(Config.map, mapName)
	if not ok or type(map) ~= "table" then
		return nil
	end
	return map.course
end

function Course.hasCourse(mapName: string): boolean
	return Course.data(mapName) ~= nil
end

function Course.stageCount(mapName: string): number
	local data = Course.data(mapName)
	return if data then #data.stages else 0
end

function Course.parSeconds(mapName: string): Par
	local data = Course.data(mapName)
	if not data then
		error(`Course: map {mapName} has no course`, 2)
	end
	return data.parSeconds
end

--[[
	Resolves one stage.

	`baseTier` is what the player picked; the stage's own tierOffset is the
	escalation on top of it, capped at the top of the ladder by RoundSchedule.
	Stages three and four bring better players, for the same reason rounds four
	and five of a gauntlet do.
]]
function Course.stage(mapName: string, index: number, baseTier: Types.BotTier): Stage
	local data = Course.data(mapName)
	if not data then
		error(`Course: map {mapName} has no course`, 2)
	end
	local entry = data.stages[index]
	if not entry then
		error(`Course: {mapName} has no stage {index}`, 2)
	end
	local waves = math.max(1, math.floor(rules().wavesPerStage or 1))
	return {
		index = index,
		id = entry.id,
		displayName = entry.displayName,
		note = entry._note or "",
		tier = RoundSchedule.escalate(baseTier, entry.tierOffset or 0),
		anchorIds = entry.anchors,
		concurrent = #entry.anchors,
		waves = waves,
		botCount = #entry.anchors * waves,
		checkpoint = {
			position = vec(entry.checkpoint.position),
			lookAt = vec(entry.checkpoint.lookAt),
		},
		isFinal = index >= #data.stages,
	}
end

function Course.all(mapName: string, baseTier: Types.BotTier): { Stage }
	local out: { Stage } = {}
	for index = 1, Course.stageCount(mapName) do
		table.insert(out, Course.stage(mapName, index, baseTier))
	end
	return out
end

--- Total defenders on a course -- twenty-eight everywhere, but derived rather
--- than assumed so a map that authors a different split still reports honestly.
function Course.totalBots(mapName: string): number
	local total = 0
	for _, stage in ipairs(Course.all(mapName, "rec")) do
		total += stage.botCount
	end
	return total
end

--[[
	Defenders alive at once, for a given number of players.

	One player meets the stage as authored. Each extra player adds
	botScalePerExtraPlayer again, rounded up -- two people do not get to walk a
	course built for one. Co-op is capped at coop.maxPlayers and this is the only
	mode that takes a second player at all.
]]
function Course.concurrentFor(stage: Stage, playerCount: number): number
	local coop = rules().coop
	local players = math.clamp(math.floor(playerCount), 1, coop.maxPlayers)
	local scale = 1 + (players - 1) * coop.botScalePerExtraPlayer
	return math.ceil(stage.concurrent * scale)
end

function Course.maxPlayers(): number
	local coop = rules().coop
	return if coop.enabled then coop.maxPlayers else 1
end

--- Whether a run by this many players counts toward the Aurum route. Co-op
--- medals are recorded and ranked; they just do not buy the gold marker.
function Course.countsTowardAurum(playerCount: number): boolean
	return playerCount <= 1 or rules().coop.countsTowardAurum == true
end

export type Round = {
	index: number,
	botCount: number,
	tier: Types.BotTier,
	payoutMultiplier: number,
	isFinal: boolean,
	stage: Stage,
	wave: number,
}

--[[
	The course, flattened into the round shape MatchService already drives.

	Each stage's cover refills `wavesPerStage` times, so four stages become eight
	rounds, each carrying the stage it belongs to. This lives here rather than
	inside the match closure because it is pure -- it is the whole reason the mode
	could be added without a second match loop, and it is the part worth having
	specs on.
]]
function Course.schedule(mapName: string, baseTier: Types.BotTier, playerCount: number?): { Round }
	local rounds: { Round } = {}
	for _, stage in ipairs(Course.all(mapName, baseTier)) do
		for wave = 1, stage.waves do
			table.insert(rounds, {
				index = #rounds + 1,
				botCount = Course.concurrentFor(stage, playerCount or 1),
				tier = stage.tier,
				-- A course pays per medal, never per round.
				payoutMultiplier = 0,
				isFinal = stage.isFinal and wave == stage.waves,
				stage = stage,
				wave = wave,
			})
		end
	end
	return rounds
end

function Course.deathPenaltySeconds(): number
	return rules().timing.deathPenaltySeconds
end

--[[
	The time that actually counts: the clock plus ten seconds a death.

	The penalty is charged here rather than by stopping the clock on respawn so
	that the number on the HUD during a run is always the number being judged.
]]
function Course.finalSeconds(liveSeconds: number, deaths: number): number
	return liveSeconds + math.max(0, deaths) * Course.deathPenaltySeconds()
end

--- The best medal `seconds` earns on this map, or nil for a clear outside par.
function Course.medalFor(mapName: string, seconds: number): string?
	local par = Course.parSeconds(mapName)
	local best: string? = nil
	for _, medal in ipairs(MEDALS) do
		if seconds <= (par :: any)[medal] then
			best = medal
		end
	end
	return best
end

--- Medals weakest-first. Callers that rank medals must use this, not their own
--- ordering, or bronze and gold end up comparing as strings.
function Course.medals(): { string }
	return table.clone(MEDALS)
end

function Course.medalRank(medal: string?): number
	if not medal then
		return 0
	end
	return table.find(MEDALS, medal) or 0
end

--- True when `candidate` is strictly better than `existing`.
function Course.isBetterMedal(candidate: string?, existing: string?): boolean
	return Course.medalRank(candidate) > Course.medalRank(existing)
end

--[[
	Payout for a finished run.

	Off the map's own basePayout, scaled by medal. `newMedals` is whichever
	medal tiers this run reached for the FIRST time on this map -- those pay a
	one-off bonus so that a first gold is an event and the hundredth is a
	leaderboard entry.

	The economy's exponential death penalty deliberately does not apply: deaths
	already cost ten seconds each and the medal already priced that in.
]]
function Course.payoutFor(mapName: string, medal: string?, newMedals: { string }?): number
	local base = Config.require("economy", "basePayout")[mapName]
	if type(base) ~= "number" then
		error(`Course: no basePayout for map {mapName}`, 2)
	end
	local pay = rules().payout
	local multiplier = pay.medalMultiplier[medal or "none"] or pay.medalMultiplier.none
	local total = base * multiplier
	for _, id in ipairs(newMedals or {}) do
		total += pay.firstMedalBonus[id] or 0
	end
	return math.floor(total + 0.5)
end

--- Whether a completed run beats the stored record. Time first; a faster run
--- with a worse medal is impossible, since medals are thresholds on time.
function Course.isRecord(seconds: number, bestSeconds: number?): boolean
	return bestSeconds == nil or seconds < bestSeconds
end

return Course
