--!strict
-- One overlap graph for zone surfaces, individual path segments and joins.
-- Heights are assigned to actual intersecting shapes, not whole trail IDs.
local GroundLayers = {}
type Footprint = { x: number, z: number, hx: number, hz: number, angle: number, level: number }

local function overlaps(a: Footprint, b: Footprint): boolean
	local ax, az = math.cos(a.angle), math.sin(a.angle)
	local bx, bz = math.cos(b.angle), math.sin(b.angle)
	local dx, dz = b.x - a.x, b.z - a.z
	for _, axis in ipairs({ { ax, az }, { -az, ax }, { bx, bz }, { -bz, bx } }) do
		local x, z = axis[1], axis[2]
		local ra = a.hx * math.abs(x * ax + z * az) + a.hz * math.abs(-x * az + z * ax)
		local rb = b.hx * math.abs(x * bx + z * bz) + b.hz * math.abs(-x * bz + z * bx)
		if math.abs(dx * x + dz * z) > ra + rb then return false end
	end
	return true
end

-- Explicit horizontal basis keeps the slab level after its centre is buried.
-- It also avoids Lune 0.10.5's lookAt handedness mismatch in build validation.
function GroundLayers.frame(position: Vector3, direction: Vector3): CFrame
	local z = Vector3.new(direction.X, 0, direction.Z).Unit
	return CFrame.fromMatrix(position, Vector3.yAxis:Cross(z), Vector3.yAxis, z)
end

function GroundLayers.plan(zones: { any }, trails: { any }, step: number, barn: any?): any
	assert(step > 0 and step < math.huge, "ground layer step must be finite and positive")
	local fixed: { any } = {}
	if barn then
		for _, surface in pairs(barn.groundSurfaces) do
			table.insert(fixed, { x = barn.position[1], z = barn.position[3],
				hx = (barn.widthMetres + surface.overhang) / 2, hz = (barn.depthMetres + surface.overhang) / 2,
				angle = -math.rad(barn.rotationY or 0), level = 0,
				height = barn.position[2] + surface.centerY + surface.thickness / 2 })
		end
	end
	local placed: { Footprint } = {}
	local zoneCount = 0
	local result: any = { zones = {}, trails = {}, maxHeight = 0 }
	local function put(x: number, z: number, hx: number, hz: number, angle: number, isZone: boolean): number
		local shape: Footprint = { x = x, z = z, hx = hx, hz = hz, angle = angle, level = 0 }
		local minimum = 1
		local taken = {}
		for index, other in ipairs(placed) do
			if overlaps(shape, other) then
				taken[other.level] = true
				-- Zones retain painter order; paths always clear the zones below.
				if isZone or index <= zoneCount then minimum = math.max(minimum, other.level + 1) end
			end
		end
		local function reserved(level: number): boolean
			for _, other in ipairs(fixed) do
				if overlaps(shape, other) and math.abs(level * step - other.height) < step then return true end
			end
			return false
		end
		while taken[minimum] or reserved(minimum) do minimum += 1 end
		shape.level = minimum
		table.insert(placed, shape)
		local height = minimum * step
		result.maxHeight = math.max(result.maxHeight, height)
		return height
	end
	for i, zone in ipairs(zones) do
		local hx = if zone.shape == "circle" then zone.radiusMetres else zone.size[1] / 2
		local hz = if zone.shape == "circle" then zone.radiusMetres else zone.size[2] / 2
		result.zones[i] = put(zone.position[1], zone.position[3], hx, hz, -math.rad(zone.rotationY or 0), true)
	end
	zoneCount = #placed
	for index, trail in ipairs(trails) do
		local heights: any = { segments = {}, joins = {} }
		result.trails[index] = heights
		for i = 1, #trail.points - 1 do
			local a, b = trail.points[i], trail.points[i + 1]
			local dx, dz = b[1] - a[1], b[3] - a[3]
			local length = math.sqrt(dx * dx + dz * dz)
			-- The long axis follows the path; expand by the same end overlap
			-- the renderer uses, so the graph sees the joins the player sees.
			heights.segments[i] = put((a[1] + b[1]) / 2, (a[3] + b[3]) / 2,
				(length + trail.widthMetres / 2) / 2, trail.widthMetres / 2, math.atan2(dz, dx), false)
			heights.joins[i] = put(b[1], b[3], trail.widthMetres / 2, trail.widthMetres / 2, 0, false)
		end
	end
	return result
end

return GroundLayers
