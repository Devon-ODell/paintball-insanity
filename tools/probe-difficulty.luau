--!strict
-- Report the same control-round difficulty sample as Sim.spec, with per-run evidence.
local process = require("@lune/process")
local Harness = require("./Harness")
local env = Harness.build()
local Config = env.require(env.Shared.Config)
local SimMatch = env.require(env.Server.Sim.SimMatch)
local tiers = if process.args[1] then { process.args[1] } else Config.get("bots").tierOrder
local map = process.args[2] or "speedball"
local runs = tonumber(process.args[3]) or 6
local firstSeed = tonumber(process.args[4]) or 1
for _, tier in ipairs(tiers) do
	local deaths, clears = 0, 0
	for seed = firstSeed, firstSeed + runs - 1 do
		local result = SimMatch.run({ map = map, tier = tier, policy = "human", seed = seed, maxSeconds = 240, singleRound = 3 })
		deaths += result.outcome.deaths
		if result.outcome.cleared then clears += 1 end
		print(string.format("%s seed=%d outs=%d clear=%s", tier, seed, result.outcome.deaths, tostring(result.outcome.cleared)))
	end
	print(string.format("%s %s mean outs=%.2f clears=%d/%d", map, tier, deaths / runs, clears, runs))
end
