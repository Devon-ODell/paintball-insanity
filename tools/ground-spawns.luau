--!nolint
--[[
	Finds ground-level replacements for bot spawns that start up on structures.

	    lune run tools/ground-spawns

	Reports only; it never writes a map file. Search is a deterministic outward
	ring walk from each existing spawn, so the same map always proposes the same
	positions and a diff is reviewable.
]]
local Vector3 = require("@lune/roblox").Vector3
local Harness = require("./Harness")
local env = Harness.build()
local Config = env.require(env.ReplicatedStorage.Shared.Config)
local MapGeometry = env.require(env.ReplicatedStorage.Shared.MapGeometry)

local index = Config.get("maps_index")

local function insideAny(world, point): boolean
	for _, volume in ipairs(world.volumes) do
		if volume.cover and MapGeometry.containsPoint(volume, point) then
			return true
		end
	end
	return false
end

local function nearestNodeDistance(world, point): number
	local best = math.huge
	for _, node in ipairs(world.navNodes) do
		local d = (Vector3.new(node.X, 0, node.Z) - Vector3.new(point.X, 0, point.Z)).Magnitude
		if d < best then best = d end
	end
	return best
end

for _, name in ipairs(index.order) do
	local map = Config.map(name)
	local world = MapGeometry.build(map, index)
	local halfW = map.bounds.widthMetres / 2 - 2
	local halfL = map.bounds.lengthMetres / 2 - 2
	print(`\n\27[1m{name}\27[0m`)

	local taken = {}
	for _, spawn in ipairs(map.botSpawns) do
		local p = Vector3.new(spawn.position[1], spawn.position[2], spawn.position[3])
		if p.Y <= 0.75 then table.insert(taken, p) end
	end

	for i, spawn in ipairs(map.botSpawns) do
		local p = Vector3.new(spawn.position[1], spawn.position[2], spawn.position[3])
		if p.Y <= 0.75 then
			print(`  bot{i}  already on the ground at [{p.X}, 0, {p.Z}]`)
			continue
		end
		local found = nil
		-- Outward rings, one metre at a time, 24 bearings each. Deterministic.
		for radius = 2, 40, 1 do
			for step = 0, 23 do
				local angle = (step / 24) * math.pi * 2
				local candidate = Vector3.new(
					p.X + math.cos(angle) * radius,
					0,
					p.Z + math.sin(angle) * radius
				)
				if math.abs(candidate.X) > halfW or math.abs(candidate.Z) > halfL then continue end
				-- Real ground, not a rooftop, and not standing in a wall.
				if MapGeometry.supportHeightAt(world, Vector3.new(candidate.X, 0.4, candidate.Z)) > 0.4 then continue end
				if insideAny(world, Vector3.new(candidate.X, 1.0, candidate.Z)) then continue end
				if nearestNodeDistance(world, candidate) > 7 then continue end
				local clear = true
				for _, other in ipairs(taken) do
					if (Vector3.new(other.X, 0, other.Z) - candidate).Magnitude < 6 then clear = false end
				end
				if not clear then continue end
				found = candidate
				break
			end
			if found then break end
		end
		if found then
			table.insert(taken, found)
			print(`  bot{i}  was [{p.X}, {p.Y}, {p.Z}] on a structure  ->  [{string.format("%.1f", found.X)}, 0, {string.format("%.1f", found.Z)}]`)
		else
			print(`  bot{i}  was [{p.X}, {p.Y}, {p.Z}]  -> \27[31mNO GROUND FOUND\27[0m`)
		end
	end
end
