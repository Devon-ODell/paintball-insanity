--!strict
--[[
	MapGeometry -- turns a Data/maps/*.json description into collision volumes,
	line-of-sight queries and a navigation graph.

	Pure, in metres, no Roblox services. The live server and the headless sim
	both run against this same model, so a bot that cannot see you in the sim
	cannot see you in the game either. That property is what makes the sim
	harness trustworthy.

	Volumes are oriented boxes. Cylinders are treated as their bounding box for
	line-of-sight purposes; at paintball ranges the difference is smaller than
	the projectile, and an exact cylinder test would cost more than it buys.
]]

local Ballistics = require(script.Parent.Ballistics)

local MapGeometry = {}

export type Volume = {
	id: string,
	--- The piece id from the map JSON, before any mirror suffix. Anchors
	--- reference this, not `id`, so a mirrored bunker is still findable.
	sourceId: string,
	center: Vector3,
	halfSize: Vector3,
	rotationY: number, -- radians
	cover: boolean, -- stops projectiles
	concealment: boolean, -- blocks sight only
	walkable: boolean,
	--- Bounding-sphere radius, precomputed for broad-phase rejection.
	boundRadius: number,
}

export type Hit = {
	position: Vector3,
	volumeId: string,
	distance: number,
}

export type World = {
	id: string,
	volumes: { Volume },
	navNodes: { Vector3 },
	navEdges: { { number } },
	anchors: { any },
	prePlacement: { any },
	sightlines: { any },
	botSpawns: { any },
	playerSpawn: any,
	playerRespawns: { any },
	bounds: any,
	engagementBand: any,
}

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

--------------------------------------------------------------------------------
-- Volume construction
--------------------------------------------------------------------------------

local function addVolume(out: { Volume }, piece: any, mirrorX: boolean, mirrorZ: boolean)
	local pos = vec(piece.position)
	local size = vec(piece.size)
	local rotY = math.rad(piece.rotationY or 0)

	if mirrorX then
		pos = Vector3.new(-pos.X, pos.Y, pos.Z)
		rotY = -rotY
	end
	if mirrorZ then
		pos = Vector3.new(pos.X, pos.Y, -pos.Z)
		rotY = -rotY
	end

	-- A cylinder laid on its side (rotationZ 90) is a horizontal log: its
	-- height axis becomes horizontal, so swap the extents before bounding it.
	if (piece.rotationZ or 0) ~= 0 then
		size = Vector3.new(size.Y, size.X, size.Z)
	end

	local half = size * 0.5
	local suffix = (if mirrorX then "_mx" else "") .. (if mirrorZ then "_mz" else "")
	table.insert(out, {
		id = piece.id .. suffix,
		sourceId = piece.id,
		center = pos,
		halfSize = half,
		rotationY = rotY,
		boundRadius = half.Magnitude,
		cover = piece.cover == true,
		concealment = piece.concealment == true,
		walkable = piece.walkable == true,
	})
end

local function buildVolumes(mapData: any): { Volume }
	local volumes: { Volume } = {}
	-- Built explicitly rather than as `{ mapData.terrain, mapData.geometry }`:
	-- a nil first element truncates the array and silently drops all geometry.
	local groups: { { any } } = {}
	if mapData.terrain then
		table.insert(groups, mapData.terrain)
	end
	if mapData.geometry then
		table.insert(groups, mapData.geometry)
	end
	for _, group in ipairs(groups) do
		for _, piece in ipairs(group) do
			addVolume(volumes, piece, false, false)
			if piece.mirrorX then
				addVolume(volumes, piece, true, false)
			end
			if piece.mirrorZ then
				addVolume(volumes, piece, false, true)
			end
			if piece.mirrorX and piece.mirrorZ then
				addVolume(volumes, piece, true, true)
			end
		end
	end
	return volumes
end

--------------------------------------------------------------------------------
-- Ray / segment intersection
--------------------------------------------------------------------------------

local function toLocal(volume: Volume, point: Vector3): Vector3
	local d = point - volume.center
	local c, s = math.cos(-volume.rotationY), math.sin(-volume.rotationY)
	return Vector3.new(d.X * c - d.Z * s, d.Y, d.X * s + d.Z * c)
end

local function rotateDirection(volume: Volume, dir: Vector3): Vector3
	local c, s = math.cos(-volume.rotationY), math.sin(-volume.rotationY)
	return Vector3.new(dir.X * c - dir.Z * s, dir.Y, dir.X * s + dir.Z * c)
end

--- Slab test in the volume's local frame. Returns the entry parameter along the
--- segment in [0,1], or nil.
local function segmentVolume(volume: Volume, from: Vector3, to: Vector3): number?
	local origin = toLocal(volume, from)
	local dir = rotateDirection(volume, to - from)
	local h = volume.halfSize

	local tMin, tMax = 0, 1
	local components = {
		{ origin.X, dir.X, h.X },
		{ origin.Y, dir.Y, h.Y },
		{ origin.Z, dir.Z, h.Z },
	}
	for _, c in ipairs(components) do
		local o, d, half = c[1], c[2], c[3]
		if math.abs(d) < 1e-9 then
			if o < -half or o > half then
				return nil
			end
		else
			local t1 = (-half - o) / d
			local t2 = (half - o) / d
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			if t1 > tMin then
				tMin = t1
			end
			if t2 < tMax then
				tMax = t2
			end
			if tMin > tMax then
				return nil
			end
		end
	end
	return tMin
end

export type CastOptions = {
	--- true for projectiles: brush does not stop paint.
	ignoreConcealment: boolean?,
	--- ids to skip, e.g. the volume a bot is leaning out from.
	ignore: { [string]: boolean }?,
}

--- True when `point` is inside this volume, in the volume's own frame.
function MapGeometry.containsPoint(volume: Volume, point: Vector3): boolean
	local p = toLocal(volume, point)
	local h = volume.halfSize
	return math.abs(p.X) <= h.X and math.abs(p.Y) <= h.Y and math.abs(p.Z) <= h.Z
end

--[[
	Height of the highest solid surface beneath `point`, at or below its own Y.

	Volumes rotate only about Y, so every top face is level and the test reduces
	to a 2D point-in-rotated-rectangle against the footprint. Concealment-only
	volumes (brush, netting) are skipped -- you cannot stand on a bush.

	Returns the ground plane when nothing holds the point up, which is the answer
	that actually matters here: a spawn with nothing under it is a bot standing
	in the sky, and until now nothing in the pipeline could tell.
]]
function MapGeometry.supportHeightAt(world: World, point: Vector3, tolerance: number?): number
	local slack = tolerance or 0.75
	local best = 0
	for _, volume in ipairs(world.volumes) do
		if volume.cover or volume.walkable then
			local top = volume.center.Y + volume.halfSize.Y
			if top <= point.Y + slack and top > best then
				local flat = toLocal(volume, Vector3.new(point.X, volume.center.Y, point.Z))
				if math.abs(flat.X) <= volume.halfSize.X and math.abs(flat.Z) <= volume.halfSize.Z then
					best = top
				end
			end
		end
	end
	return best
end

--- True when something actually holds this point up at its stated height.
function MapGeometry.isSupported(world: World, point: Vector3, tolerance: number?): boolean
	local slack = tolerance or 0.75
	return math.abs(MapGeometry.supportHeightAt(world, point, slack) - point.Y) <= slack
end

--- Drops a point onto whatever holds it up. Spawns go through this so a Y typo
--- in a map file produces a bot on the roof, never a bot in the air.
function MapGeometry.groundPoint(world: World, point: Vector3, tolerance: number?): Vector3
	return Vector3.new(point.X, MapGeometry.supportHeightAt(world, point, tolerance), point.Z)
end

--- Nearest blocking volume along a segment, or nil if the segment is clear.
function MapGeometry.cast(world: World, from: Vector3, to: Vector3, options: CastOptions?): Hit?
	local opts = options or {}
	local best: Hit? = nil
	local bestT = math.huge
	local delta = to - from
	local length = delta.Magnitude
	if length < 1e-9 then
		return nil
	end
	local invLenSq = 1 / (length * length)

	for _, volume in ipairs(world.volumes) do
		-- Broad phase: reject anything whose bounding sphere cannot reach the
		-- segment. The narrow OBB test is ~20x the cost, and a match fires tens
		-- of thousands of these, so this is the difference between a sim run
		-- taking seconds and taking minutes.
		do
			local toCenter = volume.center - from
			local along = math.clamp(toCenter:Dot(delta) * invLenSq, 0, 1)
			local nearest = toCenter - delta * along
			if nearest.Magnitude > volume.boundRadius then
				continue
			end
		end
		if not volume.cover and not volume.concealment then
			continue
		end
		if volume.concealment and not volume.cover and opts.ignoreConcealment then
			continue
		end
		if opts.ignore and opts.ignore[volume.id] then
			continue
		end
		local t = segmentVolume(volume, from, to)
		if t and t < bestT then
			bestT = t
			best = { position = from + delta * t, volumeId = volume.id, distance = length * t }
		end
	end
	return best
end

--- Can `from` see `to`? Concealment counts here; it does not count for paint.
function MapGeometry.hasLineOfSight(world: World, from: Vector3, to: Vector3, ignore: { [string]: boolean }?): boolean
	return MapGeometry.cast(world, from, to, { ignoreConcealment = false, ignore = ignore }) == nil
end

--- Would a paintball fired along this segment reach? Brush does not stop paint.
function MapGeometry.paintCanReach(world: World, from: Vector3, to: Vector3): boolean
	return MapGeometry.cast(world, from, to, { ignoreConcealment = true }) == nil
end

--------------------------------------------------------------------------------
-- Navigation
--------------------------------------------------------------------------------

local function buildNav(volumes: { Volume }, nodes: { Vector3 }, radius: number, probeHeight: number): { { number } }
	local edges: { { number } } = {}
	for i = 1, #nodes do
		edges[i] = {}
	end
	local blockers: { Volume } = {}
	for _, v in ipairs(volumes) do
		if v.cover and not v.walkable then
			table.insert(blockers, v)
		end
	end
	local probeWorld: World = {
		id = "nav",
		volumes = blockers,
		navNodes = {},
		navEdges = {},
		anchors = {},
		prePlacement = {},
		sightlines = {},
		botSpawns = {},
		playerSpawn = nil,
		playerRespawns = {},
		bounds = nil,
		engagementBand = nil,
	}

	-- A node may legitimately sit hard against cover -- that is what a bunker
	-- position IS. Volumes containing either endpoint are therefore excluded
	-- from that pair's probe, or every playable position would be unreachable.
	local containing: { { [string]: boolean } } = {}
	for i, node in ipairs(nodes) do
		local set: { [string]: boolean } = {}
		local probe = node + Vector3.new(0, probeHeight, 0)
		for _, v in ipairs(blockers) do
			if MapGeometry.containsPoint(v, probe) then
				set[v.id] = true
			end
		end
		containing[i] = set
	end

	for i = 1, #nodes do
		for j = i + 1, #nodes do
			local a, b = nodes[i], nodes[j]
			if (a - b).Magnitude > radius then
				continue
			end
			-- Probe at walking height so the test asks "can a player walk this",
			-- not "can a paintball fly this".
			local pa = a + Vector3.new(0, probeHeight, 0)
			local pb = b + Vector3.new(0, probeHeight, 0)
			local ignore: { [string]: boolean } = {}
			for id in pairs(containing[i]) do
				ignore[id] = true
			end
			for id in pairs(containing[j]) do
				ignore[id] = true
			end
			if MapGeometry.cast(probeWorld, pa, pb, { ignoreConcealment = true, ignore = ignore }) == nil then
				table.insert(edges[i], j)
				table.insert(edges[j], i)
			end
		end
	end
	return edges
end

--[[
	Reports nav nodes that are buried inside cover. A node inside a bunker is a
	map-authoring mistake: bots will path to a place they cannot stand, and the
	automatic linker will refuse to connect it to anything.
]]
function MapGeometry.nodesInsideCover(world: World, probeHeight: number): { { index: number, position: Vector3, volumeId: string } }
	local out = {}
	for i, node in ipairs(world.navNodes) do
		local probe = node + Vector3.new(0, probeHeight, 0)
		for _, v in ipairs(world.volumes) do
			if v.cover and not v.walkable and MapGeometry.containsPoint(v, probe) then
				table.insert(out, { index = i, position = node, volumeId = v.id })
				break
			end
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Assembly
--------------------------------------------------------------------------------

function MapGeometry.build(mapData: any, indexData: any): World
	local volumes = buildVolumes(mapData)

	local nodes: { Vector3 } = {}
	for i, n in ipairs(mapData.navNodes) do
		nodes[i] = vec(n)
	end

	local assembly = indexData.assembly
	-- Link radius is per-map: Woods is three times the size of Speedball, so a
	-- single global radius either shreds the big map's graph or turns the small
	-- map's into a fully connected mesh that ignores its own cover.
	local radius = mapData.navLinkRadiusMetres or assembly.navLinkRadiusMetres
	local edges = buildNav(volumes, nodes, radius, assembly.coverProbeHeightMetres)

	-- Hand-authored vertical links: ladders, stair towers, roof hatches. The
	-- automatic linker probes a straight line at walking height and correctly
	-- refuses to connect a rooftop to the ground below it, so anything a bot
	-- climbs has to be declared in the map.
	for _, link in ipairs(mapData.navLinks or {}) do
		local a, b = link[1] + 1, link[2] + 1
		if not edges[a] or not edges[b] then
			error(`{mapData.id}: navLink references a node that does not exist`)
		end
		if not table.find(edges[a], b) then
			table.insert(edges[a], b)
			table.insert(edges[b], a)
		end
	end

	return {
		id = mapData.id,
		volumes = volumes,
		navNodes = nodes,
		navEdges = edges,
		anchors = mapData.anchors,
		prePlacement = mapData.prePlacementAngles or {},
		sightlines = mapData.sightlines or {},
		botSpawns = mapData.botSpawns,
		playerSpawn = mapData.playerSpawn,
		playerRespawns = mapData.playerRespawns or { mapData.playerSpawn },
		bounds = mapData.bounds,
		engagementBand = mapData.engagementBand,
	}
end

--- True when the map declares a piece with this id, mirrored or not.
function MapGeometry.hasPiece(world: World, sourceId: string): boolean
	for _, v in ipairs(world.volumes) do
		if v.sourceId == sourceId then
			return true
		end
	end
	return false
end

function MapGeometry.nearestNavNode(world: World, position: Vector3): number
	local best, bestD = 1, math.huge
	for i, node in ipairs(world.navNodes) do
		local d = (node - position).Magnitude
		if d < bestD then
			bestD, best = d, i
		end
	end
	return best
end

--- Breadth-first path between nav nodes. The graphs are tens of nodes, so BFS
--- is both fast enough and deterministic, which A* with a tie-broken heap is not.
function MapGeometry.findPath(world: World, startIndex: number, goalIndex: number): { number }?
	if startIndex == goalIndex then
		return { startIndex }
	end
	local cameFrom: { [number]: number } = {}
	local visited: { [number]: boolean } = { [startIndex] = true }
	local queue = { startIndex }
	local head = 1

	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, neighbour in ipairs(world.navEdges[current]) do
			if visited[neighbour] then
				continue
			end
			visited[neighbour] = true
			cameFrom[neighbour] = current
			if neighbour == goalIndex then
				local path = { goalIndex }
				local node = goalIndex
				while cameFrom[node] do
					node = cameFrom[node]
					table.insert(path, 1, node)
				end
				return path
			end
			table.insert(queue, neighbour)
		end
	end
	return nil
end

--- True when every nav node is reachable from every other. Maps that fail this
--- will strand bots, which is why MapsSpec asserts it.
function MapGeometry.isConnected(world: World): boolean
	if #world.navNodes == 0 then
		return false
	end
	local visited: { [number]: boolean } = { [1] = true }
	local queue, head, count = { 1 }, 1, 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, n in ipairs(world.navEdges[current]) do
			if not visited[n] then
				visited[n] = true
				count += 1
				table.insert(queue, n)
			end
		end
	end
	return count == #world.navNodes
end

--- Bearing helper used by chatter callouts and by crossfire detection.
function MapGeometry.bearingDeg(from: Vector3, to: Vector3): number
	local d = to - from
	return math.deg(math.atan2(d.X, -d.Z))
end

--- Convenience re-export so callers that already have a World do not need to
--- reach for Ballistics separately when checking a shot is even possible.
function MapGeometry.canPaintReachAt(world: World, from: Vector3, to: Vector3, spec: Ballistics.Spec): boolean
	if not MapGeometry.paintCanReach(world, from, to) then
		return false
	end
	local dir = Ballistics.aimDirection(spec, from, to)
	return dir ~= nil
end

return MapGeometry
