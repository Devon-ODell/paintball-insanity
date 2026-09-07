--!strict
--[[
	Prescription -- the one line the post-match screen exists to deliver.

	"You are bad at aiming" is useless. "You under-lead by 0.8 m; run Strafe and
	aim at empty ground ahead of them" is a thing a person can go and do. The
	loop -- play, get told exactly what you are bad at, drill it, play again --
	is the product, and this module is the hinge in the middle of it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)
local Aggregate = require(script.Parent.Aggregate)

local Prescription = {}

export type Result = { line: string, drill: string, fundamental: Types.Fundamental }

local function fill(template: string, values: { [string]: string }): string
	return (template:gsub("{(%w+)}", function(key)
		return values[key] or ("{" .. key .. "}")
	end))
end

local function round(n: number, places: number): string
	local mult = 10 ^ places
	return string.format("%." .. places .. "f", math.floor(n * mult + 0.5) / mult)
end

--[[
	Chooses the prescription for a finished session.

	leadAndDrop is special-cased: which of the three lead prescriptions fires
	depends on the SIGN analysis, not the score. Everything else is a direct
	lookup on the weakest confident fundamental.
]]
function Prescription.forSession(log: any, scores: { [Types.Fundamental]: Types.FundamentalScore }): Result?
	local weakest = Aggregate.weakest(scores)
	if not weakest then
		return nil
	end

	local table_ = Config.require("telemetry", "prescriptions")
	local entry = scores[weakest]

	if weakest == "leadAndDrop" then
		local bias, verdict = Aggregate.leadDiagnosis(log)
		local key = if verdict == "under"
			then "leadAndDropUnder"
			elseif verdict == "over" then "leadAndDropOver"
			else "leadAndDropSpread"
		local rule = table_[key]
		return {
			fundamental = weakest,
			drill = rule.drill,
			line = fill(rule.line, {
				bias = round(math.abs(bias), 2),
				error = round(entry.rawMean, 2),
			}),
		}
	end

	local rule = table_[weakest]
	if not rule then
		return nil
	end

	local scoring = Config.require("telemetry", "scoring")
	local targetRaw = scoring[weakest].scale * 0.45

	return {
		fundamental = weakest,
		drill = rule.drill,
		line = fill(rule.line, {
			acquire = round(entry.rawMean, 0),
			target = round(targetRaw, 0),
			error = round(entry.rawMean, 2),
			gap = round(entry.rawMean / 1000, 1),
			offset = round(entry.rawMean, 1),
		}),
	}
end

--- Builds the whole post-match summary. The server sends this; the client only
--- draws it.
function Prescription.summarise(
	log: any,
	outcome: Types.MatchOutcome,
	tier: Types.BotTier,
	payout: number
): Types.SessionSummary
	local scores = Aggregate.score(log)
	local bias = select(1, Aggregate.leadDiagnosis(log))
	local shots = outcome.shots

	return {
		map = log.map,
		marker = log.marker,
		tier = tier,
		durationSeconds = outcome.durationSeconds,
		shots = shots,
		hits = outcome.hits,
		hitRate = if shots > 0 then outcome.hits / shots else 0,
		eliminations = outcome.eliminations,
		deaths = outcome.deaths,
		cleared = outcome.cleared,
		scores = scores,
		weakest = Aggregate.weakest(scores),
		prescription = Prescription.forSession(log, scores),
		leadBiasM = bias,
		payout = payout,
	}
end

return Prescription
