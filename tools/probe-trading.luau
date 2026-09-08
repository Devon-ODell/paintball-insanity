--!nolint
--[[
	Does the squad punish trading harder than holding angles?

	    lune run tools/probe-trading            -- every field
	    lune run tools/probe-trading speedball  -- one field
	    lune run tools/probe-trading all 8      -- every field, 8 seeds

	Mean deaths for the rusher policy must exceed the human policy on every map.
	`rusher` is built on `human` so the ONLY difference between the two runs is
	behaviour -- if rushing looked worse because the rusher also aimed worse, the
	comparison would prove nothing.

	This used to probe Speedball alone, which was a real hole: the 88% field
	rescale was validated against this metric on one map and then applied to four
	others that were never measured. Now it walks the whole curriculum. It is
	slow on purpose -- it runs a full round per seed per policy per map -- so it
	is an on-demand balance probe, not a suite check.
]]

local process = require("@lune/process")
local Harness = require("./Harness")
local env = Harness.build()
local SimMatch = env.require(env.ServerScriptService.Server.Sim.SimMatch)
local Config = env.require(env.ReplicatedStorage.Shared.Config)

local requested = process.args[1]
local seeds = tonumber(process.args[2]) or 6

local maps: { string } = {}
if requested and requested ~= "all" then
	table.insert(maps, requested)
else
	for _, name in ipairs(Config.mapNames()) do
		table.insert(maps, name)
	end
end

--[[
	Round 3 is the control round: tierOffset 0, so the tier asked for is the tier
	that plays. Its bot count follows Data/match.json rather than being pinned
	here, so doubling the squad does not silently change what this measures.
]]
local function batch(map: string, policy: string): number
	local deaths = 0
	for seed = 1, seeds do
		local result = SimMatch.run({
			map = map, seed = seed, policy = policy,
			tier = "semipro", maxSeconds = 240, singleRound = 3,
		})
		deaths += result.outcome.deaths
	end
	return deaths / seeds
end

print(`\27[1mprobe-trading\27[0m  {seeds} seeds, round 3, semipro`)
local failures = 0
for _, map in ipairs(maps) do
	local holding = batch(map, "human")
	local trading = batch(map, "rusher")
	local ok = trading > holding
	if not ok then
		failures += 1
	end
	print(string.format("  %-11s holding %5.2f   trading %5.2f   gap %+.2f  %s",
		map, holding, trading, trading - holding,
		if ok then "\27[32mok\27[0m" else "\27[31mtrading is not punished\27[0m"))
end

print("")
if failures > 0 then
	print(`\27[31m{failures} field(s) do not punish trading\27[0m`)
	process.exit(1)
end
print("\27[32mevery field punishes trading harder than holding an angle\27[0m")
