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
-- A stud is 0.28m here, so this is about four millimetres of world space.
local EPSILON_STUDS = 0.015
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
		if d:IsA("BasePart") and d.Transparency < 1 then
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
					name = d.Name,
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
-- Atmosphere touches Lighting, which the harness only mocks. The geometry is
-- parented before that point, so build as far as it gets and measure that.
pcall(function() Overworld.build(hub) end)
total += report("the landing", hub)

for _, name in ipairs(Config.get("maps_index").order) do
	local holder = roblox.Instance.new("Folder")
	pcall(function() WorldBuilder.build(name, holder) end)
	total += report(name, holder)
end

print("")
if total > 0 then
	print(`\27[31m{total} coplanar overlap(s) -- these shimmer when the camera moves\27[0m`)
	process.exit(1)
end
print("\27[32mno surface fights another\27[0m")
