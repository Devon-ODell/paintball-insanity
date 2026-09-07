--!nolint
--[[
	Map flow and accessibility.

	    lune run tools/flow-report

	Engagement distance is decided by when line of sight first exists, not by how
	eagerly the bots push -- so this measures sight, cover and reachability
	rather than behaviour:

	  spawn sight   how far a player can see straight off their own spawn, and
	                whether an enemy spawn is visible from it. A map where the
	                player is visible on arrival cannot teach anything but trading.
	  cover walk    how far the average step is from something to hide behind.
	                This is the accessibility number: a player who is never near
	                cover has no way to fail forward.
	  reach         nav nodes actually reachable from the player's spawn.
]]
local Vector3 = require("@lune/roblox").Vector3
local Harness = require("./Harness")
local env = Harness.build()
local Config = env.require(env.ReplicatedStorage.Shared.Config)
local MapGeometry = env.require(env.ReplicatedStorage.Shared.MapGeometry)

local index = Config.get("maps_index")
local EYE = Config.require("ballistics", "hitbox").chestHeightMetres
-- Crouched eye line: low enough to be behind a snake, which is the whole point of one.
local CROUCH = EYE * 0.62

for _, name in ipairs(index.order) do
	local map = Config.map(name)
	local world = MapGeometry.build(map, index)
	local band = map.engagementBand
	print(`\n\27[1m{name}\27[0m  target median {band.targetMedianMetres}m, max {band.maxMetres}m`)

	-- 1. What can the player see from the moment they spawn?
	local spawn = Vector3.new(map.playerSpawn.position[1], EYE, map.playerSpawn.position[3])
	local visibleSpawns, longest = 0, 0
	for _, botSpawn in ipairs(map.botSpawns) do
		local at = Vector3.new(botSpawn.position[1], botSpawn.position[2] + EYE, botSpawn.position[3])
		if MapGeometry.hasLineOfSight(world, spawn, at) then
			visibleSpawns += 1
			longest = math.max(longest, (at - spawn).Magnitude)
			print(string.format("      sees enemy spawn at [%.0f, %.0f, %.0f] from [%.0f, %.0f] -- %.1fm",
				at.X, botSpawn.position[2], at.Z, spawn.X, spawn.Z, (at - spawn).Magnitude))
		end
	end
	local flag = if visibleSpawns > 0 then "\27[31m" else "\27[32m"
	print(string.format("  spawn sight   %s%d of %d enemy spawns visible on arrival\27[0m, longest %.1fm",
		flag, visibleSpawns, #map.botSpawns, longest))

	--[[
		Longest clear line between two nav nodes, measured STANDING and CROUCHED.

		The distinction matters more than it sounds. Speedball's snake tops out
		at 1.30m against a 1.32m eye line, so the wire reads as a 43.8m open lane
		standing and as broken cover crouched -- which is exactly what a snake
		is. An earlier pass of this tool only measured standing, called that a
		fault, and had two bunkers built on top of a working piece of design
		before the numbers were read properly.

		A lane that is long standing and short crouched is a map asking you to
		get low. A lane that is long BOTH ways is just an empty field.
	]]
	local worstLane, worstCrouched = 0, 0
	local worstFrom, worstTo = nil, nil
	local crouchFrom, crouchTo = nil, nil
	for i, a in ipairs(world.navNodes) do
		for j = i + 1, #world.navNodes do
			local b = world.navNodes[j]
			local from = Vector3.new(a.X, EYE, a.Z)
			local to = Vector3.new(b.X, EYE, b.Z)
			local span = (to - from).Magnitude
			if span > worstLane and MapGeometry.hasLineOfSight(world, from, to) then
				worstLane = span
				worstFrom, worstTo = from, to
			end
			if span > worstCrouched then
				local lowFrom = Vector3.new(a.X, CROUCH, a.Z)
				local lowTo = Vector3.new(b.X, CROUCH, b.Z)
				if MapGeometry.hasLineOfSight(world, lowFrom, lowTo) then
					worstCrouched = span
					crouchFrom, crouchTo = lowFrom, lowTo
				end
			end
		end
	end
	-- Only a lane that is over-long CROUCHED is a real fault; over-long
	-- standing and broken crouched is cover doing its job.
	local laneFlag = if worstCrouched > band.maxMetres then "\27[31m" else "\27[32m"
	print(string.format("  worst lane    %s%.1fm standing, %.1fm crouched\27[0m (band allows %.0fm)",
		laneFlag, worstLane, worstCrouched, band.maxMetres))
	if crouchFrom and worstCrouched > band.maxMetres then
		local mid = (crouchFrom + crouchTo) / 2
		print(string.format("      crouched lane runs [%.0f, %.0f] -> [%.0f, %.0f]; midpoint [%.1f, %.1f]",
			crouchFrom.X, crouchFrom.Z, crouchTo.X, crouchTo.Z, mid.X, mid.Z))
	end

	-- 2. Cover accessibility: from each nav node, distance to the nearest thing
	--    you could actually get behind.
	local total, worstStep = 0, 0
	for _, node in ipairs(world.navNodes) do
		local nearest = math.huge
		for _, volume in ipairs(world.volumes) do
			if volume.cover and volume.halfSize.Y >= 0.7 then
				local d = (Vector3.new(volume.center.X, 0, volume.center.Z)
					- Vector3.new(node.X, 0, node.Z)).Magnitude - volume.boundRadius
				nearest = math.min(nearest, math.max(0, d))
			end
		end
		total += nearest
		worstStep = math.max(worstStep, nearest)
	end
	local mean = total / math.max(1, #world.navNodes)
	local coverFlag = if mean > 8 then "\27[31m" else "\27[32m"
	print(string.format("  cover walk    %s%.1fm mean to cover\27[0m, worst %.1fm", coverFlag, mean, worstStep))

	-- 3. Reachability from the player's spawn.
	local startIndex = MapGeometry.nearestNavNode(world, spawn)
	local reached = 0
	for i = 1, #world.navNodes do
		if MapGeometry.findPath(world, startIndex, i) then reached += 1 end
	end
	local reachFlag = if reached < #world.navNodes then "\27[31m" else "\27[32m"
	print(string.format("  reach         %s%d of %d nav nodes reachable from spawn\27[0m",
		reachFlag, reached, #world.navNodes))
end
