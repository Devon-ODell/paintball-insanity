--!nolint
-- Reports nav-graph connectivity per map. Run after editing any Data/maps file.
local Harness = require("./Harness")
local env = Harness.build()
local RS = env.ReplicatedStorage
local MapGeometry = env.require(RS.Shared.MapGeometry)
local Config = env.require(RS.Shared.Config)

for _, name in ipairs(Config.mapNames()) do
	local world = MapGeometry.build(Config.map(name), Config.get("maps_index"))
	print(string.format("\n%s: %d nodes, %d volumes", name, #world.navNodes, #world.volumes))
	-- components
	local seen, comps = {}, {}
	for i = 1, #world.navNodes do
		if seen[i] then continue end
		local comp, q, h = {}, { i }, 1
		seen[i] = true
		while h <= #q do
			local c = q[h]; h += 1
			table.insert(comp, c)
			for _, n in ipairs(world.navEdges[c]) do
				if not seen[n] then seen[n] = true; table.insert(q, n) end
			end
		end
		table.insert(comps, comp)
	end
	table.sort(comps, function(a, b) return #a > #b end)
	print(string.format("  %d component(s)", #comps))
	for ci, comp in ipairs(comps) do
		if ci == 1 then
			print(string.format("    main: %d nodes", #comp))
		else
			local parts = {}
			for _, i in ipairs(comp) do
				local p = world.navNodes[i]
				table.insert(parts, string.format("#%d(%.0f,%.0f,%.0f)", i - 1, p.X, p.Y, p.Z))
			end
			print("    orphan: " .. table.concat(parts, " "))
		end
	end
	local lonely = {}
	for i = 1, #world.navNodes do
		if #world.navEdges[i] == 0 then
			local p = world.navNodes[i]
			table.insert(lonely, string.format("#%d(%.0f,%.0f,%.0f)", i - 1, p.X, p.Y, p.Z))
		end
	end
	if #lonely > 0 then print("  no edges at all: " .. table.concat(lonely, " ")) end
end
