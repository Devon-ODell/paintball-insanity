--!nolint
--[[
	Median engagement distance per map, against the band each map declares.

	    lune run tools/engagement-report

	BUILD_PLAN Phase 5 asks the maps to produce genuinely different fights. This
	is the instrument for that: it prints what each map is aiming at, what it
	actually produces, and the correction that would close the gap -- which goes
	into that map's engagementBand.postureBias and gets re-measured.
]]
local Harness = require("./Harness")
local env = Harness.build()
local Config = env.require(env.ReplicatedStorage.Shared.Config)
local SimMatch = env.require(env.ServerScriptService.Server.Sim.SimMatch)

local SEEDS = 3
print(string.format("%-10s %8s %8s %8s %7s   %s", "map", "target", "actual", "delta", "shots", "suggested bias"))

for _, map in ipairs(Config.get("maps_index").order) do
	local band = Config.map(map).engagementBand
	local all = {}
	for seed = 1, SEEDS do
		local r = SimMatch.run({ map = map, seed = seed, policy = "human", tier = "rec", maxSeconds = 240 })
		for _, d in ipairs(r.engagementDistances) do
			table.insert(all, d)
		end
	end
	table.sort(all)
	if #all == 0 then
		print(string.format("%-10s %8.1f %8s %8s %7d   \27[33mno engagements -- the sim never fights here\27[0m",
			map, band.targetMedianMetres, "--", "--", 0))
		continue
	end
	local median = all[math.max(1, #all // 2)]
	local delta = median - band.targetMedianMetres
	local colour = if math.abs(delta) <= band.targetMedianMetres * 0.2 then "\27[32m" else "\27[31m"
	-- Bands scale linearly with the range multiplier, so the first-order
	-- correction is just the ratio. Damped, because geometry has the last word.
	local current = (band.postureBias and band.postureBias.range) or 1
	local suggested = current * (1 + 0.6 * (band.targetMedianMetres / median - 1))
	print(string.format("%-10s %8.1f %s%8.1f %+8.1f\27[0m %7d   range %.2f",
		map, band.targetMedianMetres, colour, median, delta, #all, suggested))
end
