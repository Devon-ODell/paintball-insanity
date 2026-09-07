--!strict
--[[
	Foliage -- deterministic trees, ferns, rocks and deadfall for the hub.

	Seeded through Shared/Rng, so the same trees grow in the same places on every
	server and across every restart. That matters more than it sounds: the hub is
	somewhere the player is meant to learn -- "the board is past the big leaning
	pine" -- and a forest that reshuffles on load is scenery rather than a place.

	Everything here is scenery. Trunks collide so you cannot walk through a tree;
	canopies, ferns and cattails do not collide and are not queryable, so nothing
	in the woods can block a camera or catch a raycast.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Rng = require(ReplicatedStorage.Shared.Rng)
local Units = require(ReplicatedStorage.Shared.Units)
local Config = require(ReplicatedStorage.Shared.Config)

local Foliage = {}

export type Palette = { [string]: Color3 }

export type ScatterContext = {
	palette: Palette,
	exclusions: { any },
	trails: { any },
	trailClearance: number,
	--- Optional predicate the caller can add on top of the standard rules.
	allow: ((Vector3) -> boolean)?,
}

local MATERIALS: { [string]: Enum.Material } = {
	trunk = Enum.Material.Wood,
	canopy = Enum.Material.LeafyGrass,
	fern = Enum.Material.Grass,
	rock = Enum.Material.Slate,
}

local function part(name: string, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = Config.get("presentation").foliage.shadowParts[name] == true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--------------------------------------------------------------------------------
-- Placement rules
--------------------------------------------------------------------------------

local function insideExclusion(point: Vector3, exclusion: any): boolean
	if exclusion.shape == "circle" then
		local centre = Vector3.new(exclusion.position[1], 0, exclusion.position[3])
		return (Vector3.new(point.X, 0, point.Z) - centre).Magnitude <= exclusion.radiusMetres
	end
	local centre = Vector3.new(exclusion.position[1], 0, exclusion.position[3])
	local half = Vector3.new(exclusion.size[1] / 2, 0, exclusion.size[2] / 2)
	local delta = point - centre
	return math.abs(delta.X) <= half.X and math.abs(delta.Z) <= half.Z
end

--- Distance from a point to a line segment, flattened to the XZ plane.
local function distanceToSegment(point: Vector3, a: Vector3, b: Vector3): number
	local p = Vector3.new(point.X, 0, point.Z)
	local s = Vector3.new(a.X, 0, a.Z)
	local e = Vector3.new(b.X, 0, b.Z)
	local delta = e - s
	local lengthSq = delta:Dot(delta)
	if lengthSq < 1e-9 then
		return (p - s).Magnitude
	end
	local t = math.clamp((p - s):Dot(delta) / lengthSq, 0, 1)
	return (p - (s + delta * t)).Magnitude
end

--[[
	Can something grow here?

	Three rules, in order of how often they fire: not inside an exclusion (the
	clearing, the barn apron, the pond), not on a trail, and not failing whatever
	extra predicate the caller supplied. Trails are cleared by distance to the
	path segments rather than by a big exclusion box, so a winding trail stays
	winding instead of mowing a rectangle through the woods.
]]
function Foliage.canPlace(point: Vector3, ctx: ScatterContext): boolean
	for _, exclusion in ipairs(ctx.exclusions) do
		if insideExclusion(point, exclusion) then
			return false
		end
	end

	for _, trail in ipairs(ctx.trails) do
		local clearance = ctx.trailClearance + trail.widthMetres / 2
		local points = trail.points
		for i = 1, #points - 1 do
			local a = Vector3.new(points[i][1], 0, points[i][3])
			local b = Vector3.new(points[i + 1][1], 0, points[i + 1][3])
			if distanceToSegment(point, a, b) < clearance then
				return false
			end
		end
	end

	if ctx.allow and not ctx.allow(point) then
		return false
	end
	return true
end

--------------------------------------------------------------------------------
-- Shapes
--------------------------------------------------------------------------------

--[[
	A conifer: tapered trunk, three stacked canopy cones, a slight lean.

	Cones are built from cylinders with a scaled top rather than real cones,
	because a Roblox cylinder is one part and a mesh cone is an asset upload.
	At the distances the hub is viewed from, the read is identical.
]]
local function buildTree(model: Model, rng: Rng.Generator, layer: any, palette: Palette)
	local height = rng:nextRange(layer.heightMetres[1], layer.heightMetres[2])
	local diameter = rng:nextRange(layer.trunkDiameterMetres[1], layer.trunkDiameterMetres[2])
	local trunkKey = layer.trunkKeys[rng:nextInt(1, #layer.trunkKeys)]
	local canopyKey = layer.colorKeys[rng:nextInt(1, #layer.colorKeys)]

	local trunk = part("Trunk", model)
	trunk.Shape = Enum.PartType.Cylinder
	trunk.Size = Units.vectorToStuds(Vector3.new(height, diameter, diameter))
	trunk.Color = palette[trunkKey]
	trunk.Material = MATERIALS.trunk
	-- Trunks are the one part of a tree that stops you walking.
	trunk.CanCollide = true
	trunk.CanQuery = true
	trunk.CFrame = CFrame.new(0, Units.metresToStuds(height / 2), 0) * CFrame.Angles(0, 0, math.pi / 2)

	local tiers = 3
	for i = 1, tiers do
		local fraction = i / tiers
		local tierWidth = diameter * (7.5 - fraction * 4.2)
		local tierHeight = height * 0.3
		local at = height * (0.42 + fraction * 0.2)
		local cone = part(`Canopy{i}`, model)
		cone.Shape = Enum.PartType.Cylinder
		cone.Size = Units.vectorToStuds(Vector3.new(tierHeight, tierWidth, tierWidth))
		cone.Color = palette[canopyKey]
		cone.Material = MATERIALS.canopy
		cone.Transparency = 0
		cone.CFrame = CFrame.new(0, Units.metresToStuds(at), 0) * CFrame.Angles(0, 0, math.pi / 2)
	end

	local crown = part("Crown", model)
	crown.Shape = Enum.PartType.Ball
	crown.Size = Units.vectorToStuds(Vector3.new(diameter * 2.4, height * 0.2, diameter * 2.4))
	crown.Color = palette[canopyKey]
	crown.Material = MATERIALS.canopy
	crown.CFrame = CFrame.new(0, Units.metresToStuds(height * 0.94), 0)
end

local function buildSapling(model: Model, rng: Rng.Generator, layer: any, palette: Palette)
	local height = rng:nextRange(layer.heightMetres[1], layer.heightMetres[2])
	local key = layer.colorKeys[rng:nextInt(1, #layer.colorKeys)]

	local stem = part("Stem", model)
	stem.Shape = Enum.PartType.Cylinder
	stem.Size = Units.vectorToStuds(Vector3.new(height, 0.12, 0.12))
	stem.Color = palette.trunk or palette[key]
	stem.Material = MATERIALS.trunk
	stem.CFrame = CFrame.new(0, Units.metresToStuds(height / 2), 0) * CFrame.Angles(0, 0, math.pi / 2)

	local bush = part("Bush", model)
	bush.Shape = Enum.PartType.Ball
	bush.Size = Units.vectorToStuds(Vector3.new(height * 0.7, height * 0.6, height * 0.7))
	bush.Color = palette[key]
	bush.Material = MATERIALS.canopy
	bush.CFrame = CFrame.new(0, Units.metresToStuds(height * 0.78), 0)
end

--- A fern: three splayed fronds. Cheap, and it is what stops the forest floor
--- reading as a flat green plane.
local function buildFern(model: Model, rng: Rng.Generator, layer: any, palette: Palette)
	local height = rng:nextRange(layer.heightMetres[1], layer.heightMetres[2])
	local key = layer.colorKeys[rng:nextInt(1, #layer.colorKeys)]
	for i = 1, 3 do
		local frond = part(`Frond{i}`, model)
		frond.Size = Units.vectorToStuds(Vector3.new(height * 0.18, height, height * 0.5))
		frond.Color = palette[key]
		frond.Material = MATERIALS.fern
		frond.CFrame = CFrame.new(0, Units.metresToStuds(height * 0.45), 0)
			* CFrame.Angles(0, (i / 3) * math.pi * 2 + rng:nextRange(-0.3, 0.3), math.rad(rng:nextRange(12, 28)))
	end
end

local function buildRock(model: Model, rng: Rng.Generator, layer: any, palette: Palette)
	local height = rng:nextRange(layer.heightMetres[1], layer.heightMetres[2])
	local key = layer.colorKeys[rng:nextInt(1, #layer.colorKeys)]
	local rock = part("Rock", model)
	rock.Shape = Enum.PartType.Ball
	rock.Size = Units.vectorToStuds(Vector3.new(height * rng:nextRange(1.4, 2.4), height, height * rng:nextRange(1.3, 2.1)))
	rock.Color = palette[key]
	rock.Material = MATERIALS.rock
	rock.CanCollide = true
	rock.CanQuery = true
	-- Sunk slightly, so it reads as coming out of the ground rather than resting on it.
	rock.CFrame = CFrame.new(0, Units.metresToStuds(height * 0.3), 0)
		* CFrame.Angles(rng:nextRange(-0.2, 0.2), rng:nextRange(0, math.pi), rng:nextRange(-0.2, 0.2))
end

local function buildFallenLog(model: Model, rng: Rng.Generator, layer: any, palette: Palette)
	local length = rng:nextRange(layer.heightMetres[1], layer.heightMetres[2])
	local diameter = rng:nextRange(0.4, 0.8)
	local key = layer.colorKeys[rng:nextInt(1, #layer.colorKeys)]
	local log = part("Log", model)
	log.Shape = Enum.PartType.Cylinder
	log.Size = Units.vectorToStuds(Vector3.new(length, diameter, diameter))
	log.Color = palette[key]
	log.Material = MATERIALS.trunk
	log.CanCollide = true
	log.CanQuery = true
	log.CFrame = CFrame.new(0, Units.metresToStuds(diameter * 0.45), 0)
		* CFrame.Angles(0, rng:nextRange(0, math.pi), 0)
end

local function buildCattail(model: Model, rng: Rng.Generator, layer: any, palette: Palette)
	local height = rng:nextRange(layer.heightMetres[1], layer.heightMetres[2])
	local key = layer.colorKeys[rng:nextInt(1, #layer.colorKeys)]
	for i = 1, 4 do
		local blade = part(`Blade{i}`, model)
		blade.Size = Units.vectorToStuds(Vector3.new(0.06, height, 0.06))
		blade.Color = palette[key]
		blade.Material = MATERIALS.fern
		blade.CFrame = CFrame.new(
			Units.metresToStuds(rng:nextRange(-0.2, 0.2)),
			Units.metresToStuds(height / 2),
			Units.metresToStuds(rng:nextRange(-0.2, 0.2))
		) * CFrame.Angles(math.rad(rng:nextRange(-9, 9)), 0, math.rad(rng:nextRange(-9, 9)))
	end
	local head = part("Head", model)
	head.Shape = Enum.PartType.Cylinder
	head.Size = Units.vectorToStuds(Vector3.new(height * 0.2, 0.08, 0.08))
	head.Color = palette.cattail or palette[key]
	head.Material = MATERIALS.fern
	head.CFrame = CFrame.new(0, Units.metresToStuds(height * 0.94), 0) * CFrame.Angles(0, 0, math.pi / 2)
end

local BUILDERS: { [string]: (Model, Rng.Generator, any, Palette) -> () } = {
	tree = buildTree,
	sapling = buildSapling,
	fern = buildFern,
	rock = buildRock,
	fallenLog = buildFallenLog,
	cattail = buildCattail,
}

function Foliage.handles(kind: string): boolean
	return BUILDERS[kind] ~= nil
end

--------------------------------------------------------------------------------
-- Scatter
--------------------------------------------------------------------------------

--[[
	Scatters one layer into `parent`, returning how many actually took.

	Placement is rejection-sampled: pick a point in the annulus, test it against
	the rules, try again if it fails. Capped at a fixed number of attempts per
	item so a badly configured layer cannot hang the server -- it just produces
	fewer trees, and the count in the data becomes a ceiling rather than a
	promise.
]]
function Foliage.scatterLayer(layer: any, ctx: ScatterContext, rng: Rng.Generator, parent: Instance): number
	local builder = BUILDERS[layer.kind]
	if not builder then
		error(`Foliage: no builder for kind '{layer.kind}'`, 2)
	end

	local centre = if layer.centre
		then Vector3.new(layer.centre[1], 0, layer.centre[3])
		else Vector3.new(0, 0, 0)

	local folder = Instance.new("Folder")
	folder.Name = layer.id
	folder.Parent = parent

	local placed = 0
	for _ = 1, layer.count do
		local point: Vector3? = nil
		for _ = 1, 12 do
			local angle = rng:nextNumber() * math.pi * 2
			-- Square-root the radius so points spread evenly by area rather
			-- than bunching toward the middle of the ring.
			local u = rng:nextNumber()
			local inner = layer.innerRadiusMetres
			local outer = layer.outerRadiusMetres
			local radius = math.sqrt(inner * inner + u * (outer * outer - inner * inner))
			local candidate = centre + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			if Foliage.canPlace(candidate, ctx) then
				point = candidate
				break
			end
		end
		if not point then
			continue
		end

		local model = Instance.new("Model")
		model.Name = layer.id
		builder(model, rng, layer, ctx.palette)

		local lean = layer.leanDegrees or 0
		local orientation = CFrame.new(Units.vectorToStuds(point :: Vector3))
			* CFrame.Angles(
				math.rad(rng:nextRange(-lean, lean)),
				rng:nextNumber() * math.pi * 2,
				math.rad(rng:nextRange(-lean, lean))
			)

		for _, child in ipairs(model:GetChildren()) do
			if child:IsA("BasePart") then
				child.CFrame = orientation * child.CFrame
			end
		end
		local first = model:GetChildren()[1]
		if first and first:IsA("BasePart") then
			model.PrimaryPart = first
		end
		model.Parent = folder
		placed += 1
	end

	return placed
end

--- Scatters every layer in a scatter block. Returns the total placed.
function Foliage.scatter(scatter: any, palette: Palette, trails: { any }, parent: Instance): number
	local rng = Rng.new(scatter.seed)
	local ctx: ScatterContext = {
		palette = palette,
		exclusions = scatter.exclusions,
		trails = trails,
		trailClearance = scatter.trailClearanceMetres,
	}

	local total = 0
	for _, layer in ipairs(scatter.layers) do
		total += Foliage.scatterLayer(layer, ctx, rng, parent)
	end
	return total
end

return Foliage
