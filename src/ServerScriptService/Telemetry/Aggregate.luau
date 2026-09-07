--!strict
--[[
	Aggregate -- turns a ShotLog into the six fundamentals.

	Pure. Every constant comes from Data/telemetry.json.

	The interesting part is the lead diagnosis. `leadErrorM` is signed, so a
	player who consistently under-leads produces a large mean with a consistent
	sign, while a player who simply misses produces a large spread around zero.
	Those get different prescriptions because they need different practice, and
	distinguishing them is the thing this game does that other aim trainers do not.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)

local Aggregate = {}

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

--- score = 100 * exp(-(raw/scale)^shape). Lower raw is better on every axis.
local function curve(raw: number, scale: number, shape: number): number
	if raw <= 0 then
		return 100
	end
	local score = 100 * math.exp(-((raw / scale) ^ shape))
	return math.clamp(score, 0, 100)
end

export type Buckets = {
	reactivity: { number },
	flicking: { number },
	targetSwitching: { number },
	tracking: { number },
	crosshairPlacement: { number },
	leadAndDrop: { number },
	leadSigned: { number },
}

--[[
	Sorts every shot into the fundamentals it is evidence for. A single shot can
	be evidence for several -- a long flick onto a crossing target at 40 m tells
	you about flicking AND tracking AND lead -- and the classification thresholds
	all live in Data/telemetry.json.
]]
function Aggregate.bucket(log: any): Buckets
	local rules = Config.require("telemetry", "classification")

	local buckets: Buckets = {
		reactivity = {},
		flicking = {},
		targetSwitching = {},
		tracking = {},
		crosshairPlacement = {},
		leadAndDrop = {},
		leadSigned = {},
	}

	for _, shot in ipairs(log.shots) do
		if shot.timeToAcquireMs then
			table.insert(buckets.reactivity, shot.timeToAcquireMs)
		end

		if shot.priorAimSwingDeg and shot.priorAimSwingDeg >= rules.flickMinPriorAngleDeg then
			table.insert(buckets.flicking, shot.angularErrorDeg)
		end

		if
			shot.targetLateralSpeed >= rules.trackingMinLateralSpeedMps
			and shot.distance <= rules.trackingMaxDistanceMetres
		then
			table.insert(buckets.tracking, shot.angularErrorDeg)
		end

		if shot.crosshairOffsetDegAtReveal ~= nil then
			local visible = shot.targetVisibleMsBeforeShot
			if visible == nil or visible <= rules.crosshairMaxVisibleMs then
				table.insert(buckets.crosshairPlacement, shot.crosshairOffsetDegAtReveal)
			end
		end

		if shot.distance >= rules.leadMinDistanceMetres then
			local lead = shot.leadErrorM
			local holdover = shot.holdoverErrorM
			if lead ~= nil or holdover ~= nil then
				local weights = Config.require("telemetry", "leadAndDrop")
				local l = (lead or 0) * weights.leadWeight
				local h = (holdover or 0) * weights.holdoverWeight
				table.insert(buckets.leadAndDrop, math.sqrt(l * l + h * h))
				if lead ~= nil then
					table.insert(buckets.leadSigned, lead)
				end
			end
		end
	end

	local maxGap = rules.switchMaxGapSeconds * 1000
	for _, elim in ipairs(log.eliminations) do
		local gap = elim.msSincePreviousElimination
		-- A gap longer than the window is repositioning, not switching, and
		-- crediting it would punish correct play.
		if gap and gap <= maxGap then
			table.insert(buckets.targetSwitching, gap)
		end
	end

	return buckets
end

function Aggregate.score(log: any): { [Types.Fundamental]: Types.FundamentalScore }
	local buckets = Aggregate.bucket(log)
	local scoring = Config.require("telemetry", "scoring")
	local names: { string } = Config.require("telemetry", "fundamentals")

	local out: { [Types.Fundamental]: Types.FundamentalScore } = {}
	for _, name in ipairs(names) do
		local samples: { number } = (buckets :: any)[name]
		local rule = scoring[name]
		local absolute = {}
		for i, v in ipairs(samples) do
			absolute[i] = math.abs(v)
		end
		local raw = mean(absolute)
		out[name :: Types.Fundamental] = {
			fundamental = name :: Types.Fundamental,
			score = if #samples == 0 then 0 else curve(raw, rule.scale, rule.shape),
			samples = #samples,
			rawMean = raw,
			confident = #samples >= rule.minSamples,
		}
	end
	return out
end

--[[
	Diagnoses a systematic lead bias.

	Returns the signed mean lead error and a verdict: "under", "over" or
	"spread". "spread" means the player's errors are large but unsigned, which
	points at drop rather than lead -- a different drill entirely.
]]
function Aggregate.leadDiagnosis(log: any): (number, string)
	local buckets = Aggregate.bucket(log)
	local signed = buckets.leadSigned
	if #signed == 0 then
		return 0, "spread"
	end

	local bias = mean(signed)
	local significance = Config.require("telemetry", "leadAndDrop.biasSignificanceM")

	local sameSign = 0
	for _, v in ipairs(signed) do
		if (v < 0) == (bias < 0) and math.abs(v) > 1e-6 then
			sameSign += 1
		end
	end
	local consistency = sameSign / #signed

	if math.abs(bias) >= significance and consistency >= 0.7 then
		return bias, if bias < 0 then "under" else "over"
	end
	return bias, "spread"
end

--- The weakest confident fundamental. Unconfident axes are never called out --
--- telling someone they are bad at tracking off four shots is worse than silence.
function Aggregate.weakest(scores: { [Types.Fundamental]: Types.FundamentalScore }): Types.Fundamental?
	local worst: Types.FundamentalScore? = nil
	for _, entry in pairs(scores) do
		if entry.confident then
			if worst == nil or entry.score < (worst :: Types.FundamentalScore).score then
				worst = entry
			end
		end
	end
	return if worst then (worst :: Types.FundamentalScore).fundamental else nil
end

return Aggregate
