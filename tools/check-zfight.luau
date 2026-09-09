--!nolint
--[[
	Finds coplanar overlapping surfaces -- the cause of the shimmering,
	"one texture inside another" look when the camera moves.

	    lune run tools/check-zfight

	Z-fighting is a depth-buffer precision problem: two faces at the same height
	whose footprints overlap have no stable winner, so the renderer flips between
	them per pixel per frame. It is invisible in a screenshot and obvious the
	moment you walk. This finds it arithmetically instead.

	Only flat, ground-facing parts are considered -- a wall sharing a plane with
	another wall is normal construction. Rotated parts are compared on their
	bounding footprint, so this over-reports slightly rather than missing cases.
]]
local roblox = require("@lune/roblox")
local process = require("@lune/process")
local Harness = require("./Harness")
local env = Harness.build()
local Config = env.require(env.ReplicatedStorage.Shared.Config)
local Overworld = env.require(env.ServerScriptService.Server.World.Overworld)
local WorldBuilder = env.require(env.ServerScriptService.Server.Match.WorldBuilder)

-- Two faces closer than this in Y, with overlapping footprints, will fight.
-- A stud is 0.28m here, so this is about one centimetre of world space. It was
-- 0.015 studs (4 mm), which passed markings the depth buffer could not actually
-- separate at range -- the fields shimmered while this tool reported them clean.
local EPSILON_STUDS = 0.035
local MIN_OVERLAP_STUDS = 0.4

--[[
	An oriented footprint. Rotated parts must be compared as oriented boxes, not
	as axis-aligned bounds: the bridge's fourteen planks are 0.68m wide on 0.79m
	centres -- a real 0.11m gap -- but the deck is turned 8 degrees, and their
	axis-aligned bounds overlap by 0.36m. The AABB version of this tool reported
	all fourteen as fighting. They are not.
]]
type Face = {
	name: string,
	y: number,
	cx: number, cz: number,
	hx: number, hz: number,
	rx: number, rz: number, -- local X axis in world XZ
	lx: number, lz: number, -- local Z axis in world XZ
}

local function collect(root: any): { Face }
	local faces: { Face } = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and not d:IsA("MeshPart") and d.Transparency < 1 then
			local size, cf = d.Size, d.CFrame
			local pos = cf.Position
			--[[
				Only genuinely horizontal parts. A pitched roof sheet is not a
				floor tile, and comparing one on its axis-aligned size reported
				the barn's two roof panels as fighting each other when they are
				simply meeting at the ridge. UpVector.Y near 1 is the test.
			]]
			local level = cf.UpVector.Y > 0.98
			local flat = size.Y < math.min(size.X, size.Z) * 0.5
			if level and flat and math.min(size.X, size.Z) > 1 then
				--[[
					Top faces only. A buried bottom face cannot shimmer -- you
					are never looking at it -- and comparing both halved the
					signal-to-noise of this report for no gain. What the player
					sees on the ground is the set of upward-facing surfaces.
				]]
				table.insert(faces, {
					name = d:GetFullName(),
					y = pos.Y + size.Y / 2,
					cx = pos.X, cz = pos.Z,
					hx = size.X / 2, hz = size.Z / 2,
					rx = cf.RightVector.X, rz = cf.RightVector.Z,
					lx = cf.LookVector.X, lz = cf.LookVector.Z,
				})
			end
		end
	end
	return faces
end

--- Separating-axis overlap of two oriented rectangles in XZ. Returns the
--- smallest penetration depth, or 0 when an axis separates them.
local function overlap(a: Face, b: Face): number
	local dx, dz = b.cx - a.cx, b.cz - a.cz
	local smallest = math.huge
	for _, axis in ipairs({
		{ a.rx, a.rz }, { a.lx, a.lz }, { b.rx, b.rz }, { b.lx, b.lz },
	}) do
		local ax, az = axis[1], axis[2]
		local reachA = math.abs(a.rx * ax + a.rz * az) * a.hx + math.abs(a.lx * ax + a.lz * az) * a.hz
		local reachB = math.abs(b.rx * ax + b.rz * az) * b.hx + math.abs(b.lx * ax + b.lz * az) * b.hz
		local gap = math.abs(dx * ax + dz * az) - (reachA + reachB)
		if gap >= 0 then
			return 0
		end
		smallest = math.min(smallest, -gap)
	end
	return smallest
end

--------------------------------------------------------------------------------
-- Vertical surfaces
--------------------------------------------------------------------------------

--[[
	Walls fight too.

	The horizontal pass above deliberately ignores upright parts, on the
	reasoning that "a wall sharing a plane with another wall is normal
	construction". That is true when they sit EDGE TO EDGE and false when their
	footprints OVERLAP -- two panels occupying the same plane over the same
	square metre have no depth winner, which is the shimmer you see strafing
	past a bunker face or a barn wall.

	So the test is the same one, rotated: take every thin upright part, group by
	the plane it lies in (parallel normal, same offset along that normal), and
	report the pairs whose rectangles genuinely overlap inside that plane.
]]
type Panel = {
	name: string,
	nx: number, ny: number, nz: number,   -- plane normal
	d: number,                             -- plane offset along the normal
	cx: number, cy: number, cz: number,    -- centre
	ux: number, uy: number, uz: number, hu: number, -- in-plane axis 1 + half extent
	vx: number, vy: number, vz: number, hv: number, -- in-plane axis 2 + half extent
}

local function collectVertical(root: any): { Panel }
	local panels: { Panel } = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 1 then
			local size, cf = d.Size, d.CFrame
			local axes = {
				{ v = cf.RightVector, s = size.X },
				{ v = cf.UpVector, s = size.Y },
				{ v = cf.LookVector, s = size.Z },
			}
			-- The thin axis is the panel's normal.
			local ti = 1
			for i = 2, 3 do
				if axes[i].s < axes[ti].s then ti = i end
			end
			local n = axes[ti].v
			local thin = axes[ti].s
			-- Upright: the normal points sideways, not up. And genuinely thin
			-- relative to the face it carries, or it is a block, not a panel.
			local other1, other2 = nil, nil
			for i = 1, 3 do
				if i ~= ti then
					if other1 == nil then other1 = axes[i] else other2 = axes[i] end
				end
			end
			local a1 = other1 :: any
			local a2 = other2 :: any
			local upright = math.abs(n.Y) < 0.2
			local flat = thin < math.min(a1.s, a2.s) * 0.5
			local big = math.min(a1.s, a2.s) > 1
			if upright and flat and big then
				table.insert(panels, {
					name = d.Name,
					nx = n.X, ny = n.Y, nz = n.Z,
					d = n.X * cf.Position.X + n.Y * cf.Position.Y + n.Z * cf.Position.Z,
					cx = cf.Position.X, cy = cf.Position.Y, cz = cf.Position.Z,
					ux = a1.v.X, uy = a1.v.Y, uz = a1.v.Z, hu = a1.s / 2,
					vx = a2.v.X, vy = a2.v.Y, vz = a2.v.Z, hv = a2.s / 2,
				})
			end
		end
	end
	return panels
end

--- Separating-axis overlap of two rectangles that share a plane, measured in 3D
--- against each rectangle's own in-plane axes.
local function overlapPlanar(a: Panel, b: Panel): number
	local dx, dy, dz = b.cx - a.cx, b.cy - a.cy, b.cz - a.cz
	local smallest = math.huge
	local axes = {
		{ a.ux, a.uy, a.uz }, { a.vx, a.vy, a.vz },
		{ b.ux, b.uy, b.uz }, { b.vx, b.vy, b.vz },
	}
	for _, ax in ipairs(axes) do
		local px, py, pz = ax[1], ax[2], ax[3]
		local reachA = math.abs(a.ux * px + a.uy * py + a.uz * pz) * a.hu
			+ math.abs(a.vx * px + a.vy * py + a.vz * pz) * a.hv
		local reachB = math.abs(b.ux * px + b.uy * py + b.uz * pz) * b.hu
			+ math.abs(b.vx * px + b.vy * py + b.vz * pz) * b.hv
		local gap = math.abs(dx * px + dy * py + dz * pz) - (reachA + reachB)
		if gap >= 0 then
			return 0
		end
		smallest = math.min(smallest, -gap)
	end
	return smallest
end

local function reportVertical(label: string, root: any): number
	local panels = collectVertical(root)
	local found, seen = {}, {}
	for i = 1, #panels do
		for j = i + 1, #panels do
			local a, b = panels[i], panels[j]
			local dot = a.nx * b.nx + a.ny * b.ny + a.nz * b.nz
			if math.abs(dot) > 0.98 then
				-- Same plane? Compare offsets with b's normal flipped to match a.
				local db = if dot > 0 then b.d else -b.d
				if math.abs(a.d - db) <= EPSILON_STUDS then
					local shared = overlapPlanar(a, b)
					if shared >= MIN_OVERLAP_STUDS then
						local key = a.name .. "|" .. b.name
						if not seen[key] then
							seen[key] = true
							table.insert(found, { a = a.name, b = b.name, shared = shared })
						end
					end
				end
			end
		end
	end
	print(`  {#panels} upright panels`)
	if #found == 0 then
		print("  \27[32mno upright overlaps\27[0m")
		return 0
	end
	table.sort(found, function(p, q) return p.shared > q.shared end)
	for i = 1, math.min(#found, 12) do
		local p = found[i]
		print(string.format("  \27[31mfights\27[0m  %-26s %-26s %.1f studs shared",
			p.a, p.b, p.shared))
	end
	if #found > 12 then
		print(`  ... and {#found - 12} more`)
	end
	return #found
end

local function report(label: string, root: any): number
	local faces = collect(root)
	table.sort(faces, function(p, q) return p.y < q.y end)
	local pairsFound, seen = {}, {}
	for i = 1, #faces do
		for j = i + 1, #faces do
			if faces[j].y - faces[i].y > EPSILON_STUDS then break end
			if faces[i].name ~= faces[j].name or true then
				local shared = overlap(faces[i], faces[j])
				if shared >= MIN_OVERLAP_STUDS then
					local key = faces[i].name .. "|" .. faces[j].name
					if not seen[key] then
						seen[key] = true
						table.insert(pairsFound, {
							a = faces[i].name, b = faces[j].name,
							y = faces[i].y, shared = shared,
						})
					end
				end
			end
		end
	end
	print(`\n\27[1m{label}\27[0m  {#faces} flat faces`)
	if #pairsFound == 0 then
		print("  \27[32mno coplanar overlaps\27[0m")
		return 0
	end
	table.sort(pairsFound, function(p, q) return p.shared > q.shared end)
	for i = 1, math.min(#pairsFound, 12) do
		local p = pairsFound[i]
		print(string.format("  \27[31mfights\27[0m  %-26s %-26s at y=%.3f, %.1f studs shared",
			p.a, p.b, p.y, p.shared))
	end
	if #pairsFound > 12 then
		print(`  ... and {#pairsFound - 12} more`)
	end
	return #pairsFound
end

local total = 0
local hub = roblox.Instance.new("Folder")
-- A failed build must fail the gate; measuring a partial/empty scene can pass.
Overworld.build(hub)
total += report("the landing", hub)
total += reportVertical("the landing", hub)

for _, name in ipairs(Config.get("maps_index").order) do
	local holder = roblox.Instance.new("Folder")
	WorldBuilder.build(name, holder)
	total += report(name, holder)
	total += reportVertical(name, holder)
end

print("")
if total > 0 then
	print(`\27[31m{total} coplanar overlap(s) -- these shimmer when the camera moves\27[0m`)
	process.exit(1)
end
print("\27[32mno surface fights another\27[0m")
