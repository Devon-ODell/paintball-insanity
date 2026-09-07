--!nolint
-- Static map validation. Reports nav nodes buried in cover, orphaned nodes and
-- anchors whose cover does not exist. Run after editing any Data/maps file.
local Vector3 = require("@lune/roblox").Vector3
local Harness = require("./Harness")
local process = require("@lune/process")
local env = Harness.build()
local RS = env.ReplicatedStorage
local MG = env.require(RS.Shared.MapGeometry)
local Config = env.require(RS.Shared.Config)
local index = Config.get("maps_index")
local probe = index.assembly.coverProbeHeightMetres

local problems = 0
for _, name in ipairs(Config.mapNames()) do
	local world = MG.build(Config.map(name), index)
	print(string.format("\n%s", name))
	local buried = MG.nodesInsideCover(world, probe)
	if #buried > 0 then
		print(string.format("  %d nav node(s) inside cover:", #buried))
		for _, b in ipairs(buried) do
			print(string.format("    #%d %s -> %s", b.index - 1, tostring(b.position), b.volumeId))
		end
		problems += #buried
	else
		print("  no nav nodes inside cover")
	end
	if MG.isConnected(world) then
		print("  nav graph connected")
	else
		print("  NAV GRAPH DISCONNECTED")
		problems += 1
	end
	local deg = 0
	for i = 1, #world.navNodes do deg += #world.navEdges[i] end
	print(string.format("  %d nodes, mean degree %.1f", #world.navNodes, deg / #world.navNodes))
end
print("")
if problems > 0 then
	print(string.format("%d problem(s)", problems))
	process.exit(1)
end
print("all maps valid")
