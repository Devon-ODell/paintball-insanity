--!strict
--[[
	RoundSchedule -- resolves "round 3 of a semipro match" into a concrete setup.

	Pure and data-driven. A match is five rounds and the enemy team grows each
	one: two bots in round 1, the full six by round 5, with better players
	arriving for the last two. The player gets to learn a map's angles against a
	pair before those angles have to survive a squad.

	Everything about the escalation lives in Data/match.json so it can be tuned
	without touching logic, per CLAUDE.md.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)
local Dev = require(ReplicatedStorage.Shared.Dev)

local RoundSchedule = {}

export type Round = {
	index: number,
	botCount: number,
	tier: Types.BotTier,
	payoutMultiplier: number,
	--- True for the last round, which the HUD and the chatter both care about.
	isFinal: boolean,
}

--- Steps a tier up by `offset` places, capped at the top of the ladder.
function RoundSchedule.escalate(baseTier: Types.BotTier, offset: number): Types.BotTier
	local order: { string } = Config.require("bots", "tierOrder")
	local index = table.find(order, baseTier) or 1
	local stepped = math.clamp(index + offset, 1, #order)
	return order[stepped] :: Types.BotTier
end

function RoundSchedule.count(): number
	return Config.require("match", "rounds.count")
end

function RoundSchedule.intermissionSeconds(): number
	return Config.require("match", "rounds.intermissionSeconds")
end

function RoundSchedule.timeLimitSeconds(): number
	return Config.require("match", "rounds.roundTimeLimitSeconds")
end

--- The round the match should open on. Normally 1; the skipRounds dev flag
--- lets tuning jump straight to the hard end.
function RoundSchedule.startIndex(): number
	if Dev.flag("skipRounds") then
		return math.clamp(Dev.value("skipRounds", "startAtRound", 1), 1, RoundSchedule.count())
	end
	return 1
end

--[[
	Resolves one round.

	`baseTier` is what the player picked. The schedule's tierOffset is what the
	field does about it. The forceTier dev flag overrides both, for tuning the
	top end without playing four warm-up rounds first.
]]
function RoundSchedule.get(index: number, baseTier: Types.BotTier): Round
	local schedule: { any } = Config.require("match", "rounds.schedule")
	local entry: any = nil
	for _, candidate in ipairs(schedule) do
		if candidate.round == index then
			entry = candidate
			break
		end
	end
	if not entry then
		error(`RoundSchedule: no round {index} in Data/match.json`, 2)
	end

	local tier = RoundSchedule.escalate(baseTier, entry.tierOffset or 0)
	if Dev.flag("forceTier") then
		tier = Dev.value("forceTier", "tier", tier) :: Types.BotTier
	end

	local squadSize = Config.require("match", "squadSize")
	return {
		index = index,
		-- Never ask for more bots than the map has spawns for.
		botCount = math.min(entry.bots, squadSize),
		tier = tier,
		payoutMultiplier = entry.payoutMultiplier,
		isFinal = index >= RoundSchedule.count(),
	}
end

--- Every round of a match, in order, starting from the dev start index.
function RoundSchedule.all(baseTier: Types.BotTier): { Round }
	local out: { Round } = {}
	for index = RoundSchedule.startIndex(), RoundSchedule.count() do
		table.insert(out, RoundSchedule.get(index, baseTier))
	end
	return out
end

--- Sum of the payout multipliers actually being played, so the economy specs
--- can assert what a full clean match is worth.
function RoundSchedule.totalPayoutMultiplier(baseTier: Types.BotTier): number
	local total = 0
	for _, round in ipairs(RoundSchedule.all(baseTier)) do
		total += round.payoutMultiplier
	end
	return total
end

return RoundSchedule
