--!nolint
--[[
	Headless match runner.

	    lune run tools/sim -- --map speedball --tier rec --policy competent --seeds 5
	    lune run tools/sim -- --map woods --marker pump --seed 42 --log

	Writes one JSON per run to Saved/Sims/ and prints a summary table. This is
	how every tuning decision in the project is supposed to be made: from sim
	data, not from intuition.
]]

local process = require("@lune/process")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Harness = require("./Harness")

local args: { [string]: string } = {}
local i = 1
while i <= #process.args do
	local a = process.args[i]
	local key = a:match("^%-%-(.+)$")
	if key then
		local next_ = process.args[i + 1]
		if next_ and not next_:match("^%-%-") then
			args[key] = next_
			i += 2
		else
			args[key] = "true"
			i += 1
		end
	else
		i += 1
	end
end

local env = Harness.build()
local SimMatch = env.require(env.Server.Sim.SimMatch)

local map = args.map or "speedball"
local tier = args.tier or "rec"
local policyName = args.policy or "competent"
local marker = args.marker or "mechanical"
local seedCount = tonumber(args.seeds) or 1
local firstSeed = tonumber(args.seed) or 1
local write = args.write ~= "false"

print(string.format(
	"\27[1m%s / %s / %s / %s\27[0m  %d seed(s)",
	map, tier, marker, policyName, seedCount
))
print(string.format("  %6s %8s %7s %6s %6s %7s %8s  %s",
	"seed", "result", "time", "elims", "deaths", "hit%", "payout", "weakest"))

local cleared, totalPayout, totalDeaths, totalRounds = 0, 0, 0, 0
local allDistances: { number } = {}

for s = 0, seedCount - 1 do
	local seed = firstSeed + s
	local result = SimMatch.run({
		map = map,
		seed = seed,
		policy = policyName,
		tier = tier,
		marker = marker,
		captureLog = args.log == "true",
		maxSeconds = tonumber(args.maxSeconds),
		singleRound = tonumber(args.single),
	})
	local o = result.outcome
	if o.cleared then cleared += 1 end
	totalPayout += result.summary.payout
	totalDeaths += o.deaths
	totalRounds += result.breakdown.roundsCleared
	for _, d in ipairs(result.engagementDistances) do
		table.insert(allDistances, d)
	end

	print(string.format("  %6d %8s %6.1fs %6d %6d %6.1f%% %8d  %s",
		seed,
		if o.cleared then "CLEARED" else "failed",
		o.durationSeconds,
		o.eliminations,
		o.deaths,
		result.summary.hitRate * 100,
		result.summary.payout,
		result.summary.weakest or "-"))

	if args.rounds == "true" then
		for i, r in ipairs(result.rounds) do
			print(string.format("           r%d  %-8s %d bots (%-8s) %5.1fs  %d elim  %d out   %d FF",
				r.index,
				if r.cleared then "won" else "LOST",
				r.botCount,
				r.tier,
				r.durationSeconds,
				r.eliminations,
				r.deaths,
				math.floor(result.breakdown.roundTotals[i] or 0)))
		end
	end

	if write then
		if not fs.isDir("Saved/Sims") then
			fs.writeDir("Saved/Sims")
		end
		local name = `Saved/Sims/{map}_{tier}_{marker}_{policyName}_{seed}.json`
		fs.writeFile(name, serde.encode("json", result, true))
	end
end

table.sort(allDistances)
local function percentile(p: number): number
	if #allDistances == 0 then return 0 end
	local idx = math.max(1, math.min(#allDistances, math.floor(#allDistances * p + 0.5)))
	return allDistances[idx]
end

print("")
print(string.format("  clear rate %.0f%%  rounds cleared %.1f/%d  mean deaths %.1f  mean payout %d",
	cleared / seedCount * 100,
	totalRounds / seedCount,
	tonumber(args.single) and 1 or 5,
	totalDeaths / seedCount,
	totalPayout // seedCount))
if #allDistances > 0 then
	print(string.format("  engagement distance p25/p50/p75: %.1f / %.1f / %.1f m",
		percentile(0.25), percentile(0.5), percentile(0.75)))
end
