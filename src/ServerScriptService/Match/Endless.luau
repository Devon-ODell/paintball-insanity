--!strict
--[[
	Endless -- horde wave composition.

	Pure. Given a wave number it returns how many bots, at what tier, with what
	parameter adjustments, and whether this is a breather or a boss wave.

	There is no health here either. One hit is out in horde exactly as everywhere
	else, so a wave gets harder by adding bodies, better players and tighter
	comms -- and by shrinking the target on the bosses. A bot that soaked three
	hits would break the single rule the whole game rests on.

	Every escalation is clamped to something a human could still be: reaction
	time floors at 120 ms, aim error at 0.45 degrees. Past the floors the waves
	get bigger, not superhuman.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)

local Endless = {}

export type Wave = {
	index: number,
	botCount: number,
	concurrent: number,
	tier: Types.BotTier,
	isBreather: boolean,
	isBoss: boolean,
	boss: string?,
	--- Multipliers and offsets applied on top of the tier's own parameters.
	veterancy: {
		reactionTimeMultiplier: number,
		aimErrorMultiplier: number,
		leadSolutionAccuracyAdd: number,
		contactShareDelayMultiplier: number,
	},
	milestone: string?,
}

local function cfg(): any
	return Config.require("endless", "waves")
end

--- Tier for a wave, from the ladder. The highest entry at or below the wave.
function Endless.tierFor(wave: number): Types.BotTier
	local tier: Types.BotTier = "rec"
	for _, entry in ipairs(cfg().tierLadder) do
		if wave >= entry.fromWave then
			tier = entry.tier
		end
	end
	return tier
end

function Endless.botCountFor(wave: number): number
	local c = cfg()
	local count = c.botsBase + (wave - 1) * c.botsPerWave
	return math.min(c.botsMax, math.floor(count + 0.5))
end

function Endless.isBreather(wave: number): boolean
	local every = cfg().breatherEveryWaves
	return wave > 0 and wave % every == 0
end

function Endless.isBoss(wave: number): boolean
	local every = cfg().bossEveryWaves
	return wave > 0 and wave % every == 0
end

--- Which boss shows up, cycling through the schedule.
function Endless.bossFor(wave: number): string?
	if not Endless.isBoss(wave) then
		return nil
	end
	local cycle: { string } = Config.require("bosses", "schedule.hordeCycle")
	local occurrence = wave // cfg().bossEveryWaves
	return cycle[((occurrence - 1) % #cycle) + 1]
end

--[[
	Veterancy: how much tighter the pro parameters get past the top of the ladder.

	Compounds per wave and is clamped by the floors in endless.json, so a
	wave-200 bot is a wave-40 bot with more friends rather than a machine. The
	clamping is the point -- BUILD_PLAN's rule is that every bot parameter must
	be something a human could match, and horde does not get an exemption.
]]
function Endless.veterancyFor(wave: number): any
	local c = cfg()
	local vet = c.veterancy
	local neutral = {
		reactionTimeMultiplier = 1,
		aimErrorMultiplier = 1,
		leadSolutionAccuracyAdd = 0,
		contactShareDelayMultiplier = 1,
	}
	if wave < vet.fromWave then
		return neutral
	end
	local steps = wave - vet.fromWave + 1
	return {
		reactionTimeMultiplier = vet.perWave.reactionTimeMultiplier ^ steps,
		aimErrorMultiplier = vet.perWave.aimErrorMultiplier ^ steps,
		leadSolutionAccuracyAdd = vet.perWave.leadSolutionAccuracyAdd * steps,
		contactShareDelayMultiplier = vet.perWave.contactShareDelayMultiplier ^ steps,
	}
end

--[[
	Applies a wave's veterancy to a tier's parameters, clamped at the floors.

	Returns a NEW table; the tier data itself is shared config and must never be
	mutated, or wave 30 would permanently ruin wave 1.
]]
function Endless.applyVeterancy(tierData: any, wave: Wave): any
	local floors = cfg().veterancy.floors
	local vet = wave.veterancy
	local out = table.clone(tierData)

	out.reactionTimeMs = math.max(floors.reactionTimeMs, tierData.reactionTimeMs * vet.reactionTimeMultiplier)
	out.aimErrorDeg = math.max(floors.aimErrorDeg, tierData.aimErrorDeg * vet.aimErrorMultiplier)
	out.leadSolutionAccuracy = math.min(
		floors.leadSolutionAccuracy,
		tierData.leadSolutionAccuracy + vet.leadSolutionAccuracyAdd
	)
	return out
end

function Endless.milestoneFor(wave: number): string?
	for _, entry in ipairs(Config.require("endless", "milestones")) do
		if entry.wave == wave then
			return entry.line
		end
	end
	return nil
end

--- The full description of a wave.
function Endless.wave(index: number): Wave
	local c = cfg()
	return {
		index = index,
		botCount = Endless.botCountFor(index),
		concurrent = math.min(c.concurrentCap, Endless.botCountFor(index)),
		tier = Endless.tierFor(index),
		isBreather = Endless.isBreather(index),
		isBoss = Endless.isBoss(index),
		boss = Endless.bossFor(index),
		veterancy = Endless.veterancyFor(index),
		milestone = Endless.milestoneFor(index),
	}
end

--------------------------------------------------------------------------------

--[[
	Horde payout for reaching a wave.

	Superlinear in depth, so wave 30 is worth far more than three runs to wave
	10 -- otherwise the optimal play is farming the easy waves, which is the
	opposite of what an endless mode is for. The same death penalty applies, so
	brute-forcing depth with forty respawns still earns almost nothing.
]]
function Endless.payoutFor(wavesSurvived: number, bossesBeaten: number): number
	local p = Config.require("endless", "payout")
	local base = p.perWaveBase * (wavesSurvived ^ p.waveExponent)
	return math.floor(base + bossesBeaten * p.bossBonus + 0.5)
end

--- Whether red or gold kit is available at this depth.
function Endless.dropTierFor(wave: number): string?
	local drops = cfg().dropTable
	if wave >= drops.gold.fromWave then
		return "gold"
	elseif wave >= drops.red.fromWave then
		return "red"
	end
	return nil
end

return Endless
