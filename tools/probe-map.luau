--!nolint
local process = require("@lune/process")
local Harness = require("./Harness")
local env = Harness.build()
local SimMatch = env.require(env.ServerScriptService.Server.Sim.SimMatch)
local map = process.args[1] or "urban"
local all, cleared = {}, 0
for seed = 1, 3 do
	local r = SimMatch.run({ map = map, seed = seed, policy = "human", tier = "rec", maxSeconds = 240 })
	for _, d in ipairs(r.engagementDistances) do table.insert(all, d) end
	if r.cleared then cleared += 1 end
end
table.sort(all)
print(string.format("%s  engagements %d  median %.1f  cleared %d/3", map, #all,
	if #all > 0 then all[math.max(1, #all // 2)] else -1, cleared))
