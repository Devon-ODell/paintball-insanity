--!nolint
--- Does the squad punish trading harder than holding angles?
--- Mean deaths for the rusher policy must exceed the human policy.
local process = require("@lune/process")
local Harness = require("./Harness")
local env = Harness.build()
local SimMatch = env.require(env.ServerScriptService.Server.Sim.SimMatch)
local function batch(policy: string, runs: number): number
	local deaths = 0
	for seed = 1, runs do
		-- Round 3 is the control round, same as Sim.spec: four bots and
		-- tierOffset 0, so the tier asked for is the tier that plays.
		local r = SimMatch.run({
			map = "speedball", seed = seed, policy = policy,
			tier = "semipro", maxSeconds = 240, singleRound = 3,
		})
		deaths += r.outcome.deaths
	end
	return deaths / runs
end
local holding = batch("human", 6)
local trading = batch("rusher", 6)
print(string.format("holding %.2f deaths   trading %.2f deaths   gap %+.2f  %s",
	holding, trading, trading - holding,
	if trading > holding then "\27[32mok\27[0m" else "\27[31mtrading is not punished\27[0m"))
