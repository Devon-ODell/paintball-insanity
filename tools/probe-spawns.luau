--!nolint
local Vector3 = require("@lune/roblox").Vector3
local Harness = require("./Harness")
local env = Harness.build()
local Config = env.require(env.ReplicatedStorage.Shared.Config)
local MapGeometry = env.require(env.ReplicatedStorage.Shared.MapGeometry)
local index = Config.get("maps_index")
for _, name in ipairs(index.order) do
	local world = MapGeometry.build(Config.map(name), index)
	print(`\n{name}`)
	local map = Config.map(name)
	for i, spawn in ipairs(map.botSpawns) do
		local p = Vector3.new(spawn.position[1], spawn.position[2], spawn.position[3])
		local support = MapGeometry.supportHeightAt(world, p)
		local flag = if math.abs(support - p.Y) <= 0.75 then "ok " else "AIR"
		print(`  bot{i}  declared y={string.format("%.2f", p.Y)}  supported at {string.format("%.2f", support)}  {flag}`)
	end
	for i, spawn in ipairs(map.playerRespawns) do
		local p = Vector3.new(spawn.position[1], spawn.position[2], spawn.position[3])
		local support = MapGeometry.supportHeightAt(world, p)
		local flag = if math.abs(support - p.Y) <= 0.75 then "ok " else "AIR"
		print(`  respawn{i}  declared y={string.format("%.2f", p.Y)}  supported at {string.format("%.2f", support)}  {flag}`)
	end
end
