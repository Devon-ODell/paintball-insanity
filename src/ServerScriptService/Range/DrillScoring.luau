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
	--- Milliseconds between the target appearing and this shot.
	timeToAcquireMs: number?,
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
	shots: number,
	accuracy: number,
	--- 0-100 on the same curve the match aggregator uses.
	rating: number,
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

--- The raw measurement this drill grades on, pulled from its shot events.
local function rawSamples(drillId: string, events: { ShotEvent }): { number }
	local out: { number } = {}
	for _, event in ipairs(events) do
		local value: number? = nil
		if drillId == "popup" then
			value = event.timeToAcquireMs
		elseif drillId == "strafe" then
			value = if event.leadErrorM then math.abs(event.leadErrorM) else nil
		elseif drillId == "switch" then
			value = event.timeToAcquireMs
		elseif drillId == "holdover" then
			value = if event.holdoverErrorM then math.abs(event.holdoverErrorM) else nil
		elseif drillId == "peek" then
			value = event.crosshairOffsetDegAtReveal
		end
		if value ~= nil then
			table.insert(out, value)
		end
	end
	return out
end

function DrillScoring.score(drillId: string, events: { ShotEvent }): Result
	local cfg = Config.require("range", "drills." .. drillId)
	local scoring = cfg.scoring

	local hits, shots = 0, #events
	local points = 0

	for _, event in ipairs(events) do
		if event.hit then
			hits += 1
			points += scoring.hitPoints

			if drillId == "popup" and event.timeToAcquireMs then
				points += (scoring.acquireBonusMs - (event.timeToAcquireMs :: number)) * scoring.acquirePenaltyPerMs
			elseif drillId == "strafe" and event.leadErrorM then
				points -= math.abs(event.leadErrorM :: number) * scoring.leadErrorPenaltyPerMetre
			elseif drillId == "switch" and event.timeToAcquireMs then
				points += (scoring.switchBonusMs - (event.timeToAcquireMs :: number)) * scoring.switchPenaltyPerMs
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
	local rule = Config.require("telemetry", "scoring." .. fundamental)
	local samples = rawSamples(drillId, events)
	local raw = mean(samples)

	return {
		drill = drillId,
		fundamental = fundamental,
		score = math.max(0, math.floor(points + 0.5)),
		hits = hits,
		shots = shots,
		accuracy = if shots > 0 then hits / shots else 0,
		rating = if #samples == 0 then 0 else curve(raw, rule.scale, rule.shape),
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
