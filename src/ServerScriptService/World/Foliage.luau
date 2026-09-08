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
	--- Rejection-sampling budget per instance. Nil falls back to the default.
	placementAttempts: number?,
	--- Optional predicate the caller can add on top of the standard rules.
	allow: ((Vector3) -> boolean)?,
}

export type LayerReport = { id: string, requested: number, placed: number }

local DEFAULT_PLACEMENT_ATTEMPTS = 40

--[[
	Shape coefficients, hoisted out of the builders.

	These are shared with `Foliage.footprintRadius` below. That sharing is the
	whole point: the padding is only correct while it matches the geometry the
	builder actually draws, and two copies of "the bottom canopy tier is 6.1
	trunk diameters wide" would drift the first time someone retuned a tree.
]]
local CANOPY_TIERS = 7
local CANOPY_BASE = 7.0
local CANOPY_TAPER = 5.8
local CANOPY_BOTTOM_FRACTION = 0.30
local CANOPY_SPAN_FRACTION = 0.62
local SPIRE_WIDTH_FACTOR = 1.3
local CROWN_HEIGHT_FRACTION = 0.99
local TRUNK_SECTIONS = 3
local TRUNK_TOP_FRACTION = 0.46
local BROADLEAF_CROWN_FACTOR = 5.4
local BROADLEAF_LOBES = 5
local SAPLING_BUSH_FACTOR = 0.7
local FERN_FROND_SPREAD = 0.5
local FERN_MAX_TILT_DEGREES = 28
local ROCK_MAX_WIDTH_FACTOR = 2.4
local MOSS_WIDTH_FACTOR = 2.6
local CATTAIL_JITTER_METRES = 0.2
local CATTAIL_MAX_TILT_DEGREES = 9

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

--[[
	Does this instance overlap the exclusion?

	`footprint` is the instance's own horizontal radius, and passing it is the
	difference between "the trunk is outside the barn" and "the tree is outside
	the barn". A canopy pine whose trunk centre lands a metre clear of the barn
	rect still puts three metres of crown through the wall, which is what the
	unpadded version of this test allowed.
]]
local function insideExclusion(point: Vector3, exclusion: any, footprint: number): boolean
	local centre = Vector3.new(exclusion.position[1], 0, exclusion.position[3])
	if exclusion.shape == "circle" then
		return (Vector3.new(point.X, 0, point.Z) - centre).Magnitude <= exclusion.radiusMetres + footprint
	end
	local half = Vector3.new(exclusion.size[1] / 2 + footprint, 0, exclusion.size[2] / 2 + footprint)
	local delta = point - centre
	return math.abs(delta.X) <= half.X and math.abs(delta.Z) <= half.Z
end

--[[
	How far this layer's widest instance reaches from its own centre, in metres.

	Read off the layer's own dimensions and the shape coefficients above rather
	than a tuned constant, and always from the TOP of each range: placement is
	tested before the builder rolls its dice, so the estimate has to hold for the
	largest thing the layer can produce.
]]
function Foliage.footprintRadius(layer: any): number
	local kind = layer.kind
	local tallest = layer.heightMetres and layer.heightMetres[2] or 0

	if kind == "tree" then
		local diameter = layer.trunkDiameterMetres[2]
		-- The widest tier is the lowest one, at t = 0.
		local canopy = diameter * CANOPY_BASE / 2
		-- A leaning tree carries its crown sideways as well as up.
		local lean = math.rad(layer.leanDegrees or 0)
		return canopy + math.sin(lean) * tallest * CROWN_HEIGHT_FRACTION
	elseif kind == "broadleaf" then
		--[[
			A lobe can sit its own radius out from the trunk AND be offset by up
			to 0.28 of the crown, so the reach is the sum, not the larger.
		]]
		local diameter = layer.trunkDiameterMetres[2]
		local crown = diameter * BROADLEAF_CROWN_FACTOR
		local lean = math.rad(layer.leanDegrees or 0)
		return crown * 0.28 + crown * 0.9 / 2 + math.sin(lean) * tallest * 0.9
	elseif kind == "moss" then
		return tallest * MOSS_WIDTH_FACTOR / 2
	elseif kind == "sapling" then

		local lean = math.rad(layer.leanDegrees or 0)
		return tallest * SAPLING_BUSH_FACTOR / 2 + math.sin(lean) * tallest * 0.78
	elseif kind == "fern" then
		-- Half the frond span, plus how far the tilt throws the tall axis over.
		return tallest * FERN_FROND_SPREAD / 2 + math.sin(math.rad(FERN_MAX_TILT_DEGREES)) * tallest / 2
	elseif kind == "rock" then
		return tallest * ROCK_MAX_WIDTH_FACTOR / 2
	elseif kind == "fallenLog" then
		-- Logs lie down, so the layer's "height" range is their length.
		return tallest / 2
	elseif kind == "cattail" then
		return CATTAIL_JITTER_METRES + math.sin(math.rad(CATTAIL_MAX_TILT_DEGREES)) * tallest / 2
	end
	return 0
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

	`footprint` is the caller's horizontal reach and defaults to zero, so a bare
	two-argument call still asks the old question -- "is this POINT clear?" --
	while the scatter asks the one that matters: "does this THING fit?"
]]
--[[
	Does anything at `point` need to cast a shadow?

	The hub scattered 1559 plants into 8069 parts, and 5784 of those parts were
	shadow casters -- decided purely by part NAME, so a pine eighty metres into
	the treeline cost exactly as much as one standing on the trail. Under Future
	lighting with global shadows that is the most expensive thing in the game,
	and almost all of it lands behind other trees where nobody can see it.

	The test is proximity to somewhere a player can actually stand: within
	`shadowRadiusMetres` of a trail centreline, or that far from one of the open
	areas the scatter already carves out -- the clearing, the barn apron, the
	pond, the west corridor, and every gate. Those exclusions exist because the
	player goes there, which makes them exactly the right list to reuse.

	Distance from the hub centre would have been simpler and wrong: the gates sit
	sixty-three to eighty-two metres out, so a centre-radius rule strips the
	shadows from precisely the trees a player is standing among at the Back Forty.
]]
--- Is `point` within `radius` of a trail centreline, or of one of the open areas
--- the scatter carves out? Those exclusions exist because the player goes there,
--- which makes them the right list to measure "near the player" against.
function Foliage.nearPlayerPaths(point: Vector3, ctx: ScatterContext, radius: number): boolean
	for _, exclusion in ipairs(ctx.exclusions) do
		if insideExclusion(point, exclusion, radius) then
			return true
		end
	end
	for _, trail in ipairs(ctx.trails) do
		local reach = radius + trail.widthMetres / 2
		local points = trail.points
		for i = 1, #points - 1 do
			local a = Vector3.new(points[i][1], 0, points[i][3])
			local b = Vector3.new(points[i + 1][1], 0, points[i + 1][3])
			if distanceToSegment(point, a, b) < reach then
				return true
			end
		end
	end
	return false
end

function Foliage.castsShadowAt(point: Vector3, ctx: ScatterContext): boolean
	local radius = Config.get("presentation").foliage.shadowRadiusMetres
	if type(radius) ~= "number" then
		-- No radius authored: keep every shadow, which is the old behaviour.
		return true
	end
	return Foliage.nearPlayerPaths(point, ctx, radius)
end

function Foliage.canPlace(point: Vector3, ctx: ScatterContext, footprint: number?, ignoresExclusions: boolean?): boolean
	local reach = footprint or 0
	--[[
		Reeds are the exception, and they are why this flag exists.

		The pond's exclusion is there to keep TREES out of the water. Cattails
		grow in the shallows -- their whole layer is an annulus around the pond
		centre, entirely inside that exclusion -- so the rule that protects the
		pond was silently deleting all ninety of them. Nobody could see it while
		`scatter` reported one total; the per-layer report is what surfaced it.
	]]
	if not ignoresExclusions then
		for _, exclusion in ipairs(ctx.exclusions) do
			if insideExclusion(point, exclusion, reach) then
				return false
			end
		end
	end

	for _, trail in ipairs(ctx.trails) do
		local clearance = ctx.trailClearance + trail.widthMetres / 2 + reach
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
	A conifer.

	Roblox has no cone primitive and a Cylinder part cannot taper, so the old
	version's "cones built from cylinders with a scaled top" did not exist -- it
	was three tall drums with a gap above them and a ball floating on top, which
	is why the treeline read as blobs.

	This is a continuous stepped spire instead: seven tiers whose width AND
	height both fall off toward the top, spaced closer than they are tall so they
	overlap and no gap opens between them. Stepping is what sells a conifer at
	distance; a smooth cone would read as a traffic bollard.

	The trunk is three stacked sections of falling diameter with a flared butt,
	because a cylinder of constant width is the other half of the blob problem.
]]
local function buildConiferTrunk(model: Model, height: number, diameter: number, colour: Color3, topFraction: number)
	for i = 1, TRUNK_SECTIONS do
		local lower = (i - 1) / TRUNK_SECTIONS
		local upper = i / TRUNK_SECTIONS
		local sectionHeight = height * topFraction * (upper - lower)
		-- Taper: full diameter at the butt, a bit over half at the top.
		local width = diameter * (1 - lower * 0.45)
		local section = part(`Trunk{i}`, model)
		section.Shape = Enum.PartType.Cylinder
		section.Size = Units.vectorToStuds(Vector3.new(sectionHeight * 1.06, width, width))
		section.Color = colour
		section.Material = MATERIALS.trunk
		if i == 1 then
			-- Only the butt stops you walking; the taper above is decoration.
			section.CanCollide = true
			section.CanQuery = true
		end
		section.CFrame = CFrame.new(0, Units.metresToStuds(height * topFraction * (lower + upper) / 2), 0)
			* CFrame.Angles(0, 0, math.pi / 2)
	end
	-- Root flare. Cheap, and it is what stops a trunk looking like a pipe pushed
	-- into the ground.
	local flare = part("Flare", model)
	flare.Shape = Enum.PartType.Ball
	flare.Size = Units.vectorToStuds(Vector3.new(diameter * 1.7, diameter * 1.1, diameter * 1.7))
	flare.Color = colour
	flare.Material = MATERIALS.trunk
	flare.CFrame = CFrame.new(0, Units.metresToStuds(diameter * 0.28), 0)
end

local function buildTree(model: Model, rng: Rng.Generator, layer: any, palette: Palette)
	local height = rng:nextRange(layer.heightMetres[1], layer.heightMetres[2])
	local diameter = rng:nextRange(layer.trunkDiameterMetres[1], layer.trunkDiameterMetres[2])
	local trunkKey = layer.trunkKeys[rng:nextInt(1, #layer.trunkKeys)]
	local canopyKey = layer.colorKeys[rng:nextInt(1, #layer.colorKeys)]
	local shadeKey = layer.shadeKeys and layer.shadeKeys[rng:nextInt(1, #layer.shadeKeys)] or canopyKey

	buildConiferTrunk(model, height, diameter, palette[trunkKey], TRUNK_TOP_FRACTION)

	for i = 1, CANOPY_TIERS do
		local t = (i - 1) / (CANOPY_TIERS - 1)
		local tierWidth = diameter * (CANOPY_BASE - t * CANOPY_TAPER)
		local tierHeight = height * (0.155 - t * 0.055)
		local at = height * (CANOPY_BOTTOM_FRACTION + t * CANOPY_SPAN_FRACTION)
		local tier = part(`Canopy{i}`, model)
		tier.Shape = Enum.PartType.Cylinder
		tier.Size = Units.vectorToStuds(Vector3.new(tierHeight, tierWidth, tierWidth))
		-- Alternating tones give the canopy depth without a second material.
		tier.Color = palette[if i % 2 == 0 then shadeKey else canopyKey]
		tier.Material = MATERIALS.canopy
		tier.CFrame = CFrame.new(0, Units.metresToStuds(at), 0) * CFrame.Angles(0, 0, math.pi / 2)
	end

	local spire = part("Crown", model)
	spire.Shape = Enum.PartType.Ball
	spire.Size = Units.vectorToStuds(
		Vector3.new(diameter * SPIRE_WIDTH_FACTOR, height * 0.09, diameter * SPIRE_WIDTH_FACTOR)
	)
	spire.Color = palette[canopyKey]
	spire.Material = MATERIALS.canopy
	spire.CFrame = CFrame.new(0, Units.metresToStuds(height * CROWN_HEIGHT_FRACTION), 0)
end

--[[
	A broadleaf. A forest of nothing but conifers reads as a Christmas tree farm,
	and the shape difference is most of what makes a treeline look like woodland.

	Tapered trunk, two lifted limbs, and a crown of overlapping lobes at
	different heights and offsets rather than one ball -- a single sphere is
	exactly the blob this is meant to replace.
]]
local function buildBroadleaf(model: Model, rng: Rng.Generator, layer: any, palette: Palette)
	local height = rng:nextRange(layer.heightMetres[1], layer.heightMetres[2])
	local diameter = rng:nextRange(layer.trunkDiameterMetres[1], layer.trunkDiameterMetres[2])
	local trunkKey = layer.trunkKeys[rng:nextInt(1, #layer.trunkKeys)]
	local canopyKey = layer.colorKeys[rng:nextInt(1, #layer.colorKeys)]
	local shadeKey = layer.shadeKeys and layer.shadeKeys[rng:nextInt(1, #layer.shadeKeys)] or canopyKey

	buildConiferTrunk(model, height, diameter, palette[trunkKey], 0.62)

	-- Two limbs off the main stem, angled up and out.
	for i = 1, 2 do
		local bearing = rng:nextNumber() * math.pi * 2
		local limb = part(`Limb{i}`, model)
		limb.Shape = Enum.PartType.Cylinder
		limb.Size = Units.vectorToStuds(Vector3.new(height * 0.26, diameter * 0.42, diameter * 0.42))
		limb.Color = palette[trunkKey]
		limb.Material = MATERIALS.trunk
		limb.CFrame = CFrame.new(0, Units.metresToStuds(height * 0.5), 0)
			* CFrame.Angles(0, bearing, 0)
			* CFrame.new(0, Units.metresToStuds(height * 0.09), 0)
			* CFrame.Angles(0, 0, math.rad(52))
	end

	local crown = diameter * BROADLEAF_CROWN_FACTOR
	for i = 1, BROADLEAF_LOBES do
		local bearing = (i / BROADLEAF_LOBES) * math.pi * 2 + rng:nextRange(-0.4, 0.4)
		local reach = crown * rng:nextRange(0.14, 0.28)
		local lobeWidth = crown * rng:nextRange(0.62, 0.9)
		local lobe = part(`Canopy{i}`, model)
		lobe.Shape = Enum.PartType.Ball
		lobe.Size = Units.vectorToStuds(Vector3.new(lobeWidth, lobeWidth * rng:nextRange(0.72, 0.95), lobeWidth))
		lobe.Color = palette[if i % 2 == 0 then shadeKey else canopyKey]
		lobe.Material = MATERIALS.canopy
		lobe.CFrame = CFrame.new(
			Units.metresToStuds(math.cos(bearing) * reach),
			Units.metresToStuds(height * rng:nextRange(0.66, 0.9)),
			Units.metresToStuds(math.sin(bearing) * reach)
		)
	end
end

--[[
	A moss patch: a very flat dome, half sunk into the floor.

	Deliberately domed rather than a flat disc. A flat patch laid on the ground
	is coplanar with it, and two faces on one plane shimmer as the camera moves
	-- the exact bug tools/check-zfight exists to catch. A dome has no coplanar
	face, so ground detail can be scattered freely without re-creating it.
]]
local function buildMoss(model: Model, rng: Rng.Generator, layer: any, palette: Palette)
	local height = rng:nextRange(layer.heightMetres[1], layer.heightMetres[2])
	local key = layer.colorKeys[rng:nextInt(1, #layer.colorKeys)]
	local width = height * rng:nextRange(1.8, MOSS_WIDTH_FACTOR)
	local patch = part("Moss", model)
	patch.Shape = Enum.PartType.Ball
	patch.Size = Units.vectorToStuds(Vector3.new(width, height, width * rng:nextRange(0.8, 1.2)))
	patch.Color = palette[key]
	patch.Material = MATERIALS.fern
	patch.CFrame = CFrame.new(0, Units.metresToStuds(height * 0.12), 0)
		* CFrame.Angles(0, rng:nextNumber() * math.pi * 2, 0)
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
	bush.Size = Units.vectorToStuds(Vector3.new(height * SAPLING_BUSH_FACTOR, height * 0.6, height * SAPLING_BUSH_FACTOR))
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
		frond.Size = Units.vectorToStuds(Vector3.new(height * 0.18, height, height * FERN_FROND_SPREAD))
		frond.Color = palette[key]
		frond.Material = MATERIALS.fern
		frond.CFrame = CFrame.new(0, Units.metresToStuds(height * 0.45), 0)
			* CFrame.Angles(0, (i / 3) * math.pi * 2 + rng:nextRange(-0.3, 0.3), math.rad(rng:nextRange(12, FERN_MAX_TILT_DEGREES)))
	end
end

local function buildRock(model: Model, rng: Rng.Generator, layer: any, palette: Palette)
	local height = rng:nextRange(layer.heightMetres[1], layer.heightMetres[2])
	local key = layer.colorKeys[rng:nextInt(1, #layer.colorKeys)]
	local rock = part("Rock", model)
	rock.Shape = Enum.PartType.Ball
	rock.Size = Units.vectorToStuds(Vector3.new(height * rng:nextRange(1.4, ROCK_MAX_WIDTH_FACTOR), height, height * rng:nextRange(1.3, 2.1)))
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
			Units.metresToStuds(rng:nextRange(-CATTAIL_JITTER_METRES, CATTAIL_JITTER_METRES)),
			Units.metresToStuds(height / 2),
			Units.metresToStuds(rng:nextRange(-CATTAIL_JITTER_METRES, CATTAIL_JITTER_METRES))
		) * CFrame.Angles(
			math.rad(rng:nextRange(-CATTAIL_MAX_TILT_DEGREES, CATTAIL_MAX_TILT_DEGREES)),
			0,
			math.rad(rng:nextRange(-CATTAIL_MAX_TILT_DEGREES, CATTAIL_MAX_TILT_DEGREES))
		)
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
	broadleaf = buildBroadleaf,
	moss = buildMoss,
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

	--[[
		Padding raises the rejection rate, so the attempt cap stopped being a
		safety valve and started being the thing that decides how dense the woods
		are. It lives in the data now, and `Foliage.scatter` reports what each
		layer actually managed so a shortfall shows up in the log instead of just
		looking like a thin forest.
	]]
	local attempts = ctx.placementAttempts or DEFAULT_PLACEMENT_ATTEMPTS
	local footprint = Foliage.footprintRadius(layer)

	local placed = 0
	for _ = 1, layer.count do
		local point: Vector3? = nil
		for _ = 1, attempts do
			local angle = rng:nextNumber() * math.pi * 2
			-- Square-root the radius so points spread evenly by area rather
			-- than bunching toward the middle of the ring.
			local u = rng:nextNumber()
			local inner = layer.innerRadiusMetres
			local outer = layer.outerRadiusMetres
			local radius = math.sqrt(inner * inner + u * (outer * outer - inner * inner))
			local candidate = centre + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			--[[
				`nearPathsMetres` concentrates a layer where it can be seen.

				Ferns are three parts each and stand half a metre tall; four
				hundred of them scattered to the hub's edge spends most of its
				budget on ground cover behind a treeline nobody walks through. The
				same count packed into the band along the trails is denser where
				it reads and absent where it does not -- better looking and
				cheaper at once. Layers without the field scatter everywhere, as
				trees must, because a treeline IS the thing seen from a distance.
			]]
			local visible = layer.nearPathsMetres == nil
				or Foliage.nearPlayerPaths(candidate, ctx, layer.nearPathsMetres)
			if visible and Foliage.canPlace(candidate, ctx, footprint, layer.ignoresExclusions) then
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

		--[[
			Shadows are decided per INSTANCE, after the builder has decided them
			per part name. A part still has to be the kind of thing that casts --
			a canopy tier, a trunk, a rock -- and now it also has to be somewhere
			the player will get close enough to see the shadow land.
		]]
		if not Foliage.castsShadowAt(point :: Vector3, ctx) then
			for _, child in ipairs(model:GetChildren()) do
				if child:IsA("BasePart") then
					child.CastShadow = false
				end
			end
		end

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

--- Scatters every layer in a scatter block. Returns the total placed and a
--- per-layer report, so the caller can say which layer came up short.
function Foliage.scatter(scatter: any, palette: Palette, trails: { any }, parent: Instance): (number, { LayerReport })
	local rng = Rng.new(scatter.seed)
	local ctx: ScatterContext = {
		palette = palette,
		exclusions = scatter.exclusions,
		trails = trails,
		trailClearance = scatter.trailClearanceMetres,
		placementAttempts = scatter.placementAttempts,
	}

	local total = 0
	local report: { LayerReport } = {}
	for _, layer in ipairs(scatter.layers) do
		local placed = Foliage.scatterLayer(layer, ctx, rng, parent)
		total += placed
		table.insert(report, { id = layer.id, requested = layer.count, placed = placed })
	end
	return total, report
end

return Foliage
