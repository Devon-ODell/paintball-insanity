--!strict
--[[
	Surfaces -- keeping overlapping ground decoration off each other's planes.

	Trails, lanes and street markings all overlap: segments overlap at every bend
	so a corner does not show a notch, and paths cross each other at junctions.
	Two faces on the same plane have no stable depth winner, so the renderer
	picks a different one per pixel per frame and the ground shimmers as you
	walk. It is invisible in a screenshot and unmissable in motion.

	The naive fix -- give path number N a lift of N steps -- fails in both
	directions: stacking upward puts a kerb across every junction, and sinking
	downward eventually pushes a path below the ground it is drawn on. Both were
	tried here first.

	So: only paths that actually TOUCH need to differ, which is a graph
	colouring. Greedy is more than good enough; three levels covers every map in
	the game. `tools/check-zfight` is what proves it.
]]

local Surfaces = {}

export type Path = { points: { { number } }, widthMetres: number }

local function pointToSegment(px: number, pz: number, sx: number, sz: number, ex: number, ez: number): number
	local dx, dz = ex - sx, ez - sz
	local lengthSq = dx * dx + dz * dz
	if lengthSq < 1e-9 then
		local ox, oz = px - sx, pz - sz
		return math.sqrt(ox * ox + oz * oz)
	end
	local t = math.clamp(((px - sx) * dx + (pz - sz) * dz) / lengthSq, 0, 1)
	local ox, oz = px - (sx + dx * t), pz - (sz + dz * t)
	return math.sqrt(ox * ox + oz * oz)
end

--- Closest approach between two segments, flattened to XZ.
local function segmentDistance(a1: { number }, a2: { number }, b1: { number }, b2: { number }): number
	return math.min(
		pointToSegment(a1[1], a1[3], b1[1], b1[3], b2[1], b2[3]),
		pointToSegment(a2[1], a2[3], b1[1], b1[3], b2[1], b2[3]),
		pointToSegment(b1[1], b1[3], a1[1], a1[3], a2[1], a2[3]),
		pointToSegment(b2[1], b2[3], a1[1], a1[3], a2[1], a2[3])
	)
end

--- Do these two paths come close enough to overlap on the ground?
function Surfaces.touch(a: Path, b: Path): boolean
	local clearance = (a.widthMetres + b.widthMetres) / 2 + 0.5
	for i = 1, #a.points - 1 do
		for j = 1, #b.points - 1 do
			if segmentDistance(a.points[i], a.points[i + 1], b.points[j], b.points[j + 1]) < clearance then
				return true
			end
		end
	end
	return false
end

--[[
	A level per path, such that no two touching paths share one.

	Returns levels starting at 0, in the order the paths were given. Callers
	multiply by whatever step keeps them apart in their own scale.
]]
function Surfaces.assignLevels(paths: { Path }): { number }
	local levels: { number } = {}
	for index, path in ipairs(paths) do
		local taken: { [number]: boolean } = {}
		for other = 1, index - 1 do
			if Surfaces.touch(path, paths[other]) then
				taken[levels[other]] = true
			end
		end
		local level = 0
		while taken[level] do
			level += 1
		end
		levels[index] = level
	end
	return levels
end

--[[
	Height for one segment of a path.

	`level` separates paths that cross; the four-step alternation separates
	consecutive segments of the SAME path, which overlap by construction. Four
	rather than two because a closed loop's last segment is adjacent to its
	first, and with two levels both landed on the same one.
]]
function Surfaces.segmentHeight(base: number, level: number, index: number, step: number): number
	return base + level * step * 4 + (index % 4) * step
end

return Surfaces
