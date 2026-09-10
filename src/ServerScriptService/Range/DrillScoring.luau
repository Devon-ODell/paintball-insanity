--!strict
--[[
	DrillScoring -- turns a drill run into a score AND a fundamental rating.

	The rating matters more than the score. It is computed with the same curve
	Telemetry/Aggregate uses on match data, which is what makes "your tracking is
	38 in matches" and "you scored 41 on Strafe" comparable numbers. Without that
	shared ruler, the post-match prescription would be pointing at a drill whose
	score meant something different, and the whole play-diagnose-drill-play loop
	would be decorative.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local DrillScoring = {}

export type ShotEvent = {
	t: number,
	hit: boolean,
	targetId: string?,
	--[[
		What produced this event.

		`shot` is a trigger pull. `expired` is a target that came and went
		without being engaged -- still a miss, still penalised, but NOT a shot.
		Counting both as shots made "accuracy" the fraction of OPPORTUNITIES
		taken rather than the fraction of BALLS that landed, so a player who
		never fired and a player who missed everything read identically. Absent
		means `shot`, so an older caller keeps its meaning.
	]]
	kind: ("shot" | "expired")?,
	--- Milliseconds between the target appearing and this shot.
	timeToAcquireMs: number?,
	--- Milliseconds since the previous target was eliminated. Switch's metric:
	--- the cost being trained there is the swing between targets, not how long
	--- the target that was hit had been standing there.
	timeBetweenEliminationsMs: number?,
	angularErrorDeg: number?,
	leadErrorM: number?,
	holdoverErrorM: number?,
	crosshairOffsetDegAtReveal: number?,
}

export type Result = {
	drill: string,
	fundamental: string,
	score: number,
	hits: number,
	--- Trigger pulls. Expired targets are not counted here.
	shots: number,
	--- Targets that came and went unengaged.
	missedOpportunities: number,
	accuracy: number,
	--- 0-100 on the same curve the match aggregator uses.
	rating: number,
	--- The drill's secondary fundamental, where it has one, on the same curve.
	secondaryFundamental: string?,
	secondaryRating: number?,
	rawMean: number,
}

local function mean(values: { number }): number
	if #values == 0 then
		return 0
	end
	local sum = 0
	for _, v in ipairs(values) do
		sum += v
	end
	return sum / #values
end

--- Same curve as Telemetry/Aggregate. Duplicating the formula would be how the
--- two rulers silently drift apart, so the constants come from the same file.
local function curve(raw: number, scale: number, shape: number): number
	if raw <= 0 then
		return 100
	end
	return math.clamp(100 * math.exp(-((raw / scale) ^ shape)), 0, 100)
end

--[[
	The raw measurement a fundamental is graded on, pulled from shot events.

	Keyed by FUNDAMENTAL rather than by drill, because a drill's secondary
	fundamental has to be measured by the same ruler its primary drill uses or
	the two ratings are not comparable -- and comparability across the drill,
	the match aggregator and the prescription is the entire product.
]]
local function sampleFor(fundamental: string, event: ShotEvent): number?
	if fundamental == "reactivity" then
		return event.timeToAcquireMs
	elseif fundamental == "flicking" then
		return event.angularErrorDeg
	elseif fundamental == "leadAndDrop" then
		-- Whichever error the drill actually produced: Strafe measures lead,
		-- Holdover measures drop, and they share one fundamental.
		if event.leadErrorM then
			return math.abs(event.leadErrorM)
		end
		return if event.holdoverErrorM then math.abs(event.holdoverErrorM) else nil
	elseif fundamental == "tracking" then
		return if event.leadErrorM then math.abs(event.leadErrorM) else nil
	elseif fundamental == "targetSwitching" then
		return event.timeBetweenEliminationsMs
	elseif fundamental == "crosshairPlacement" then
		return event.crosshairOffsetDegAtReveal
	end
	return nil
end

local function rawSamples(fundamental: string, events: { ShotEvent }): { number }
	local out: { number } = {}
	for _, event in ipairs(events) do
		local value = sampleFor(fundamental, event)
		if value ~= nil then
			table.insert(out, value)
		end
	end
	return out
end

local function ratingFor(fundamental: string, events: { ShotEvent }): (number, number)
	local rule = Config.require("telemetry", "scoring." .. fundamental)
	local samples = rawSamples(fundamental, events)
	local raw = mean(samples)
	return (if #samples == 0 then 0 else curve(raw, rule.scale, rule.shape)), raw
end

function DrillScoring.score(drillId: string, events: { ShotEvent }): Result
	local cfg = Config.require("range", "drills." .. drillId)
	local scoring = cfg.scoring

	local hits, shots, missedOpportunities = 0, 0, 0
	local points = 0

	for _, event in ipairs(events) do
		if (event.kind or "shot") == "expired" then
			missedOpportunities += 1
		else
			shots += 1
		end
		if event.hit then
			hits += 1
			points += scoring.hitPoints

			if drillId == "popup" and event.timeToAcquireMs then
				points += (scoring.acquireBonusMs - (event.timeToAcquireMs :: number)) * scoring.acquirePenaltyPerMs
			elseif drillId == "strafe" and event.leadErrorM then
				points -= math.abs(event.leadErrorM :: number) * scoring.leadErrorPenaltyPerMetre
			elseif drillId == "switch" and event.timeBetweenEliminationsMs then
				points += (scoring.switchBonusMs - (event.timeBetweenEliminationsMs :: number))
					* scoring.switchPenaltyPerMs
			elseif drillId == "holdover" and event.holdoverErrorM then
				points -= math.abs(event.holdoverErrorM :: number) * scoring.verticalErrorPenaltyPerMetre
			elseif drillId == "peek" and event.crosshairOffsetDegAtReveal then
				points += (scoring.placementBonusDeg - (event.crosshairOffsetDegAtReveal :: number))
					* scoring.placementPenaltyPerDeg
			end
		else
			points -= scoring.missPenalty
		end
	end

	local fundamental = cfg.fundamental
	local rating, raw = ratingFor(fundamental, events)

	--[[
		The secondary fundamental, actually measured.

		range.json has declared `secondaryFundamental` on Pop-Up and Strafe
		since they were authored, and nothing read it -- Pop-Up claimed to train
		flicking while its rating consumed only acquisition time, and Strafe
		claimed tracking while reporting lead error. Naming a second axis and
		grading it off the first one is worse than not claiming it, because the
		prescription believes the number.
	]]
	local secondary = cfg.secondaryFundamental
	local secondaryRating: number? = nil
	if type(secondary) == "string" then
		secondaryRating = (ratingFor(secondary, events))
	end

	return {
		drill = drillId,
		fundamental = fundamental,
		score = math.max(0, math.floor(points + 0.5)),
		hits = hits,
		shots = shots,
		missedOpportunities = missedOpportunities,
		accuracy = if shots > 0 then hits / shots else 0,
		rating = rating,
		secondaryFundamental = if secondaryRating then secondary else nil,
		secondaryRating = secondaryRating,
		rawMean = raw,
	}
end

--- The drill that trains a given fundamental, for the post-match prescription.
function DrillScoring.drillFor(fundamental: string): string?
	for _, drillId in ipairs(Config.require("range", "drillOrder")) do
		if Config.require("range", "drills." .. drillId .. ".fundamental") == fundamental then
			return drillId
		end
	end
	return nil
end

return DrillScoring
