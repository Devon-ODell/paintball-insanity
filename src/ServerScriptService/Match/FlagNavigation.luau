--!strict
-- Navigation for a territory runner: reach the actual flag, including the last
-- metres after the nearest nav node, and never shortcut through a keep wall.
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS.Shared.Config)
local MapGeometry = require(RS.Shared.MapGeometry)
local FlagNavigation = {}

local function clear(world: any, a: Vector3, b: Vector3): boolean
	local hitbox = Config.require("ballistics", "hitbox")
	local cfg = Config.require("gamemodes", "captureTheFlag.navigation")
	local delta = b - a
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if math.abs(delta.Y) > flat.Magnitude * cfg.maxSlope + cfg.stepToleranceMetres then return false end
	local side = if flat.Magnitude > 0 then Vector3.new(-flat.Z, 0, flat.X).Unit * hitbox.bodyWidthMetres / 2 else Vector3.zero
	for _, height in ipairs({ cfg.stepToleranceMetres, hitbox.chestHeightMetres }) do
		local up = Vector3.new(0, height, 0)
		for _, offset in ipairs({ Vector3.zero, side, -side }) do
			if MapGeometry.cast(world, a + up + offset, b + up + offset, { ignoreConcealment = true }) then return false end
		end
	end
	local samples = math.max(1, math.ceil(delta.Magnitude / cfg.supportSampleMetres))
	for i = 0, samples do
		local at = a:Lerp(b, i / samples)
		if not MapGeometry.isSupported(world, at, cfg.stepToleranceMetres) then return false end
	end
	return true
end

function FlagNavigation.build(world: any): any
	local nav = table.clone(world)
	nav.navNodes, nav.navEdges = {}, {}
	local height = Config.require("ballistics", "hitbox.chestHeightMetres")
	for _, at in ipairs(world.navNodes) do
		local blocked = false
		for _, volume in ipairs(world.volumes) do
			if (volume.cover or volume.walkable) and MapGeometry.containsPoint(volume, at + Vector3.new(0, height, 0)) then blocked = true; break end
		end
		if not blocked and MapGeometry.isSupported(world, at) then table.insert(nav.navNodes, at) end
	end
	local radius = Config.map(world.id).navLinkRadiusMetres
	for i = 1, #nav.navNodes do nav.navEdges[i] = {} end
	for i, a in ipairs(nav.navNodes) do
		for j = i + 1, #nav.navNodes do
			local b = nav.navNodes[j]
			if (a - b).Magnitude <= radius and clear(world, a, b) then
				table.insert(nav.navEdges[i], j); table.insert(nav.navEdges[j], i)
			end
		end
	end
	return nav
end

local function connectedNode(world: any, at: Vector3): number?
	local best, distance = nil, math.huge
	for i, node in ipairs(world.navNodes) do
		local d = (node - at).Magnitude
		if d < distance and clear(world, at, node) then best, distance = i, d end
	end
	return best
end

function FlagNavigation.step(world: any, bot: any, destination: Vector3, dt: number, t: number, speed: number)
	local cfg = Config.require("gamemodes", "captureTheFlag.navigation")
	local route = bot._flagRoute
	if not route or (t >= route.expires and ((route.destination - destination).Magnitude > cfg.arrivalMetres or route.blocked)) then
		local points = {}
		if not clear(world, bot.position, destination) then
			local from, to = connectedNode(world, bot.position), connectedNode(world, destination)
			local path = if from and to then MapGeometry.findPath(world, from, to) else nil
			if path then for _, index in ipairs(path) do table.insert(points, world.navNodes[index]) end end
		end
		table.insert(points, destination)
		route = { destination = destination, points = points, index = 1, expires = t + cfg.repathSeconds }
		bot._flagRoute = route
	end
	local goal = route.points[route.index]
	if goal and (goal - bot.position).Magnitude <= cfg.arrivalMetres then
		route.index += 1; goal = route.points[route.index]
	end
	bot.velocity = Vector3.zero
	if not goal then return end
	local delta = goal - bot.position
	local distance = delta.Magnitude
	if distance == 0 then return end
	local nextAt = bot.position + delta.Unit * math.min(speed * dt, distance)
	-- Settle onto each tread, so a diagonal path never cuts into the stairs.
	nextAt = MapGeometry.groundPoint(world, nextAt, cfg.stepToleranceMetres)
	if not clear(world, bot.position, nextAt) then route.blocked = true; return end
	bot.velocity = (nextAt - bot.position) / dt
	bot.position = nextAt
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude > 0 and not bot.hasLineOfSight then bot.facing = flat.Unit end
end

return FlagNavigation
