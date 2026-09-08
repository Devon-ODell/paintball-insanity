--!strict
-- Authored vehicle assemblies. Callers own collision; every visible component
-- is decorative so parked course cars retain their authoritative map OBB.
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS.Shared.Config)
local Units = require(RS.Shared.Units)
local VehicleProps = {}

local function vec(a: { number }): Vector3
	return Vector3.new(a[1], a[2], a[3])
end

function VehicleProps.build(kind: string, base: CFrame, bodyColour: Color3, parent: Instance, fitMetres: Vector3?): Model
	local cfg = Config.get("vehicleProps")
	local spec = assert(cfg.models[kind], `Unknown vehicle '{kind}'`)
	local scale = if fitMetres then fitMetres / vec(spec.size) else Vector3.one
	local model = Instance.new("Model")
	model.Name = kind
	local function piece(name: string, at: Vector3, size: Vector3, tint: string, rotation: CFrame?, shape: string?, shadow: boolean?): Part
		local part = Instance.new("Part")
		part.Name = name
		part.Size = Units.vectorToStuds(size * scale)
		part.CFrame = base * CFrame.new(Units.vectorToStuds(at * scale)) * (rotation or CFrame.identity)
		part.Shape = if shape == "Cylinder" then Enum.PartType.Cylinder elseif shape == "Wedge" then Enum.PartType.Wedge else Enum.PartType.Block
		local rgb = cfg.palette[tint]
		part.Color = if tint == "body" then bodyColour else Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		part.Material = if tint == "body" or tint == "metal" then Enum.Material.Metal else Enum.Material.SmoothPlastic
		part.Reflectance = cfg.reflectance[tint] or 0
		part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch = true, false, false, false
		part.CastShadow = shadow == true
		part.Parent = model
		return part
	end
	for _, entry in ipairs(spec.parts) do
		for _, side in ipairs(if entry.mirrorX then { -1, 1 } else { 1 }) do
			local mirror = Vector3.new(side, 1, 1)
			local at, size, rotation
			if entry.a then
				local a, b = vec(entry.a) * mirror, vec(entry.b) * mirror
				at = (a + b) / 2
				size = Vector3.new(entry.width, (b - a).Magnitude, entry.depth)
				local along = (b - a).Unit
				local normal = Vector3.xAxis:Cross(along).Unit
				rotation = CFrame.fromMatrix(Vector3.zero, along:Cross(normal).Unit, along, normal)
			else
				at, size = vec(entry.at) * mirror, vec(entry.size)
				local r = if entry.rotation then vec(entry.rotation) else Vector3.zero
				rotation = CFrame.Angles(math.rad(r.X), math.rad(r.Y * side), math.rad(r.Z * side))
			end
			piece(entry.name .. (if entry.mirrorX then tostring(side) else ""), at, size, entry.tint, rotation, entry.shape, entry.shadow)
		end
	end

	local w = spec.wheels
	for axleIndex, z in ipairs(w.axles) do
		for _, side in ipairs({ -1, 1 }) do
			local centre = Vector3.new(side * w.x, w.y, z)
			local suffix = `{axleIndex}_{side}`
			piece("Tire" .. suffix, centre, Vector3.new(w.width, w.radius * 2, w.radius * 2), "rubber", nil, "Cylinder", true)
			local outer = centre + Vector3.new(side * (w.width / 2), 0, 0)
			piece("Rim" .. suffix, outer, Vector3.new(w.archWidth, w.rimRadius * 2, w.rimRadius * 2), "trim", nil, "Cylinder")
			piece("Hub" .. suffix, outer + Vector3.new(side * w.archWidth, 0, 0), Vector3.new(w.archWidth, w.rimRadius, w.rimRadius), "metal", nil, "Cylinder")
			for spoke = 1, w.rimSpokes do
				local angle = spoke / w.rimSpokes * math.pi * 2
				piece(`Spoke{suffix}_{spoke}`, outer + Vector3.new(side * w.archWidth / 2, math.cos(angle) * w.rimRadius / 2, math.sin(angle) * w.rimRadius / 2),
					Vector3.new(w.archWidth, w.rimRadius, w.archWidth), "metal", CFrame.Angles(angle, 0, 0))
			end
			-- A segmented half arch leaves real negative space around each tire.
			for segment = 1, w.archSegments do
				local angle = (segment - 0.5) / w.archSegments * math.pi
				local radius = w.archRadius + w.fenderThickness / 2
				piece(`WheelArch{suffix}_{segment}`, Vector3.new(side * (w.x + w.width / 2), w.y + math.sin(angle) * radius, z + math.cos(angle) * radius),
					Vector3.new(w.archWidth, w.fenderThickness, 2 * radius * math.tan(math.pi / (2 * w.archSegments))), "body", CFrame.Angles(math.pi / 2 - angle, 0, 0))
			end
		end
	end
	model.Parent = parent
	return model
end

-- Hub pickups keep the original two coarse colliders, separate from trim.
function VehicleProps.addHubCollision(model: Model, kind: string, base: CFrame)
	for i, hull in ipairs(Config.get("vehicleProps").models[kind].collision) do
		local part = Instance.new("Part")
		part.Name = `CollisionHull{i}`
		part.Size = Units.vectorToStuds(vec(hull.size))
		part.CFrame = base * CFrame.new(Units.vectorToStuds(vec(hull.at)))
		part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch = true, true, true, false
		part.Transparency, part.CastShadow = 1, false
		part.Parent = model
	end
end

return VehicleProps
