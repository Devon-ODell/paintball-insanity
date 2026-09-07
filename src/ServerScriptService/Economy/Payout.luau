--!strict
--[[
	Payout -- server-side only, always.

	payout = base(map) * tier * marker * deathPenalty * accuracyBonus * streak * flawless

	The load-bearing term is deathPenalty. Respawns are free and unlimited, so
	anyone can finish any map; the penalty is what makes only skill profitable.
	A clean clear must pay many times what a grind pays, and EconomySpec asserts
	that ratio rather than trusting the curve to stay tuned.

	Pure. No Instances, no player objects, no clock. Every input is a number the
	server measured itself -- nothing here ever comes from a client.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)

local Payout = {}

export type Input = {
	map: string,
	tier: Types.BotTier,
	marker: string,
	deaths: number,
	shots: number,
	hits: number,
	longestStreak: number,
	cleared: boolean,
}

export type Breakdown = {
	base: number,
	tierMultiplier: number,
	markerMultiplier: number,
	deathPenalty: number,
	accuracyBonus: number,
	streakBonus: number,
	flawlessBonus: number,
	total: number,
	cleared: boolean,
}

--- multiplier = floor + (1 - floor) * exp(-decay * deaths)
function Payout.deathPenalty(deaths: number): number
	local cfg = Config.require("economy", "deathPenalty")
	if deaths <= 0 then
		return 1
	end
	return cfg.floor + (1 - cfg.floor) * math.exp(-cfg.decay * deaths)
end

--[[
	Accuracy bonus from the server's own hit count.

	Below `minShotsToQualify` it returns 1: a player who fired four balls and hit
	three of them has not demonstrated accuracy, they have demonstrated patience,
	and paying for it would reward hiding.
]]
function Payout.accuracyBonus(shots: number, hits: number): number
	local cfg = Config.require("economy", "accuracyBonus")
	if shots < cfg.minShotsToQualify or shots <= 0 then
		return 1
	end
	local hitRate = hits / shots
	if hitRate <= cfg.threshold then
		return 1
	end
	return 1 + cfg.gain * (hitRate - cfg.threshold) / (1 - cfg.threshold)
end

--- Consecutive eliminations without being hit. Rewards isolation over trades.
function Payout.streakBonus(longestStreak: number): number
	local cfg = Config.require("economy", "streakBonus")
	return 1 + math.min(cfg.max, math.max(0, longestStreak - 1) * cfg.perElimination)
end

function Payout.compute(input: Input): Breakdown
	local base = Config.require("economy", "basePayout." .. input.map)
	local tierMultiplier = Config.require("bots", "tiers." .. input.tier .. ".payoutMultiplier")
	local markerMultiplier = Config.require("markers", "markers." .. input.marker .. ".payoutMultiplier")

	local deathPenalty = Payout.deathPenalty(input.deaths)
	local accuracyBonus = Payout.accuracyBonus(input.shots, input.hits)
	local streakBonus = Payout.streakBonus(input.longestStreak)
	local flawlessBonus = if input.cleared and input.deaths == 0
		then Config.require("economy", "flawlessBonus.multiplier")
		else 1

	--[[
		An unfinished round pays nothing. Respawning is free, so if a timeout
		still paid out, the optimal strategy would be to hide until the clock
		ran down -- which is the exact opposite of the behaviour the game is
		trying to teach.
	]]
	local total = 0
	if input.cleared then
		total = base
			* tierMultiplier
			* markerMultiplier
			* deathPenalty
			* accuracyBonus
			* streakBonus
			* flawlessBonus
		total = math.floor(total + 0.5)
	end

	return {
		base = base,
		tierMultiplier = tierMultiplier,
		markerMultiplier = markerMultiplier,
		deathPenalty = deathPenalty,
		accuracyBonus = accuracyBonus,
		streakBonus = streakBonus,
		flawlessBonus = flawlessBonus,
		total = total,
		cleared = input.cleared,
	}
end

--------------------------------------------------------------------------------
-- Five-round matches
--------------------------------------------------------------------------------

export type RoundResult = {
	index: number,
	tier: Types.BotTier,
	payoutMultiplier: number,
	cleared: boolean,
}

export type MatchInput = {
	map: string,
	marker: string,
	rounds: { RoundResult },
	deaths: number,
	shots: number,
	hits: number,
	longestStreak: number,
}

export type MatchBreakdown = {
	roundTotals: { number },
	roundsCleared: number,
	roundsPlayed: number,
	base: number,
	markerMultiplier: number,
	deathPenalty: number,
	accuracyBonus: number,
	streakBonus: number,
	flawlessBonus: number,
	total: number,
	cleared: boolean,
}

--[[
	Payout for a whole five-round match.

	Each round earns base * its own tier multiplier * its own share, and only if
	that round was actually cleared -- a round you ran out of clock on pays
	nothing, same as before. The MATCH-level terms are then applied once to the
	sum: deaths, accuracy, streak and flawless.

	Deaths accumulating across all five rounds and being charged once at the end
	is the load-bearing choice. It means dying cheaply in round 1 to learn the
	angles still costs you round 5's money, which is what keeps the escalation
	from turning into a free practice mode.
]]
function Payout.computeMatch(input: MatchInput): MatchBreakdown
	local base = Config.require("economy", "basePayout." .. input.map)
	local markerMultiplier = Config.require("markers", "markers." .. input.marker .. ".payoutMultiplier")

	local roundTotals: { number } = {}
	local subtotal = 0
	local cleared = 0
	for i, round in ipairs(input.rounds) do
		local value = 0
		if round.cleared then
			local tierMultiplier = Config.require("bots", "tiers." .. round.tier .. ".payoutMultiplier")
			value = base * tierMultiplier * markerMultiplier * round.payoutMultiplier
			cleared += 1
		end
		roundTotals[i] = value
		subtotal += value
	end

	local allCleared = cleared == #input.rounds and #input.rounds > 0
	local deathPenalty = Payout.deathPenalty(input.deaths)
	local accuracyBonus = Payout.accuracyBonus(input.shots, input.hits)
	local streakBonus = Payout.streakBonus(input.longestStreak)
	local flawlessBonus = if allCleared and input.deaths == 0
		then Config.require("economy", "flawlessBonus.multiplier")
		else 1

	local total = math.floor(subtotal * deathPenalty * accuracyBonus * streakBonus * flawlessBonus + 0.5)

	return {
		roundTotals = roundTotals,
		roundsCleared = cleared,
		roundsPlayed = #input.rounds,
		base = base,
		markerMultiplier = markerMultiplier,
		deathPenalty = deathPenalty,
		accuracyBonus = accuracyBonus,
		streakBonus = streakBonus,
		flawlessBonus = flawlessBonus,
		total = total,
		cleared = allCleared,
	}
end

--- The ratio a no-death clear pays over an n-death clear, all else equal.
--- Exposed so the tuning target from BUILD_PLAN Phase 6 can be asserted.
function Payout.deathPenaltyRatio(deaths: number): number
	return 1 / Payout.deathPenalty(deaths)
end

return Payout
