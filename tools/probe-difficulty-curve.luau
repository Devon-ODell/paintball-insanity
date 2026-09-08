--!nolint
--- Mean deaths per tier on one field, which must rise monotonically.
--- `lune run tools/probe-difficulty-curve [map] [seeds]`
local process = require("@lune/process")
local Harness = require("./Harness")
local env = Harness.build()
local SimMatch = env.require(env.ServerScriptService.Server.Sim.SimMatch)
local map = process.args[1] or "speedball"
local seeds = tonumber(process.args[2]) or 6
local previous, ok = -1, true
for _, tier in ipairs({ "rec", "amateur", "semipro", "pro" }) do
	local deaths = 0
	for seed = 1, seeds do
		--[[
			Round 3 is the control round, the same one Sim.spec measures: tierOffset
			0, so the tier asked for is the tier that plays. Rounds 4 and 5 escalate
			by design and would collapse semipro and pro into the same fight.
		]]
		deaths += SimMatch.run({ map = map, seed = seed, policy = "human", tier = tier,
			maxSeconds = 240, singleRound = 3 }).outcome.deaths
	end
	local mean = deaths / seeds
	local rising = mean > previous
	if not rising then ok = false end
	print(string.format("  %-9s %6.2f  %s", tier, mean, if rising then "" else "\27[31mnot above the tier below\27[0m"))
	previous = mean
end
print(if ok then "\27[32mdeaths rise at every tier\27[0m" else "\27[31mthe curve is not monotonic\27[0m")
