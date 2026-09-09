--!strict
--[[
	WorldBuilder -- assembles a map's Parts from its JSON description.

	Nothing is authored in Studio. Every bunker, wall and tree in the game comes
	from Data/maps/*.json through this module, which means the geometry the bots
	reason about (MapGeometry, in metres) and the geometry the player collides
	with (Parts, in studs) are guaranteed to be the same shapes -- they are built
	from one source.

	Gameplay cover keeps its authored geometry. Mesh dressing, PBR materials
	and map lighting supply detail without changing the simulation bounds.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Fonts = require(ReplicatedStorage.Shared.Fonts)
local Units = require(ReplicatedStorage.Shared.Units)
local Tint = require(ReplicatedStorage.Shared.Tint)
local Log = require(ReplicatedStorage.Shared.Log)
local Inflatables = require(script.Parent.Inflatables)
local VehicleProps = require(script.Parent.Parent.World.VehicleProps)
local EnvironmentArt = require(script.Parent.Parent.World.EnvironmentArt)
local EnvironmentMaterials = require(script.Parent.Parent.World.EnvironmentMaterials)
local Atmosphere = require(script.Parent.Atmosphere)
local Surfaces = require(game:GetService("ReplicatedStorage").Shared.Surfaces)
local GroundLayers = require(ReplicatedStorage.Shared.GroundLayers)

local log = Log.scope("LiveRound.World")

local WorldBuilder = {}

local SHAPE_TO_CLASS: { [string]: string } = {
	box = "Part",
	cylinder = "Part",
	wedge = "WedgePart",
}

local function colourOf(key: string): Color3
	local palette = Config.require("maps_index", "palette")
	local rgb = palette[key]
	if not rgb then
		log.warn(`unknown palette key '{key}' -- falling back to concrete`)
		rgb = palette.concrete
	end
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

WorldBuilder.colourOf = colourOf

--[[
	Surface treatment per material family.

	The palette stays saturated and the silhouettes stay strong, but the
	surfaces are no longer all the same dead plastic: concrete and sand catch
	light differently from vinyl and timber, and that difference alone does most
	of the work of making a field look like a place.
]]
--[[
	Surface material and reflectance per palette key.

	The field floor is the largest unbroken surface a player ever looks at, and
	Grass across 88 metres is a flat green sheet -- LeafyGrass has real relief
	and catches the sun, which is most of what separates a field from a
	backdrop. Slate is cut paving stone; a boulder and a rock face are Rock.
	Speedball keeps plain Grass on `groundAlt` deliberately: a tournament field
	is mown short, and long grass under the bunkers would fight the one palette
	that map has.
]]
local SURFACE: { [string]: { material: Enum.Material, reflectance: number } } = {
	concrete = { material = Enum.Material.Concrete, reflectance = 0 },
	sand = { material = Enum.Material.Sand, reflectance = 0 },
	asphalt = { material = Enum.Material.Asphalt, reflectance = 0.02 },
	ground = { material = Enum.Material.LeafyGrass, reflectance = 0 },
	groundAlt = { material = Enum.Material.Grass, reflectance = 0 },
	timber = { material = Enum.Material.Wood, reflectance = 0 },
	timberDark = { material = Enum.Material.WoodPlanks, reflectance = 0 },
	rock = { material = Enum.Material.Rock, reflectance = 0 },
	mossRock = { material = Enum.Material.Rock, reflectance = 0 },
	sheetMetal = { material = Enum.Material.Metal, reflectance = 0.03 },
	rust = { material = Enum.Material.CorrodedMetal, reflectance = 0.03 },
	-- These three were used by the maps but declared in neither table, so every
	-- thicket, copse, outcrop and rusted screen rendered as concrete-grey smooth
	-- plastic. Woods and Holdfast were drawing their scrub as pale grey boxes.
	brush = { material = Enum.Material.LeafyGrass, reflectance = 0 },
	stone = { material = Enum.Material.Rock, reflectance = 0 },
	containerRust = { material = Enum.Material.CorrodedMetal, reflectance = 0.03 },
	-- Ground markings. A gravel freight lane and a dirt valley path were both
	-- being laid as Material.Ground, hardcoded at the call site, so the two read
	-- identically despite being different things in different places.
	gravel = { material = Enum.Material.Pebble, reflectance = 0 },
	trail = { material = Enum.Material.Ground, reflectance = 0 },
	foliage = { material = Enum.Material.LeafyGrass, reflectance = 0 },
	foliageDeep = { material = Enum.Material.LeafyGrass, reflectance = 0 },
	netting = { material = Enum.Material.Fabric, reflectance = 0 },
	bunkerA = { material = Enum.Material.SmoothPlastic, reflectance = 0.08 },
	bunkerB = { material = Enum.Material.SmoothPlastic, reflectance = 0.08 },
	bunkerC = { material = Enum.Material.SmoothPlastic, reflectance = 0.08 },
}

--[[
	Does the surface table have an opinion about this colour key?

	An undeclared key does not fail: it renders as smooth plastic and keeps
	building, which is how thickets and outcrops spent a while looking like
	concrete boxes. MapsSpec asserts every key a field asks for is declared here
	as well as in the palette -- the colour and the material are two separate
	fallbacks and either one alone is enough to make a field look wrong.
]]
function WorldBuilder.declaresSurface(colorKey: string): boolean
	return SURFACE[colorKey] ~= nil
end

--- The material a colour key implies, or `fallback` if the table has no opinion.
local function materialFor(colorKey: string, fallback: Enum.Material): Enum.Material
	local surface = SURFACE[colorKey]
	return if surface then surface.material else fallback
end

--[[
	The same answer, for a module decorating a field it did not build.

	FieldDetails paints the surrounding ground -- the largest single plane on
	screen, wider than the field on every side -- and was deciding its material
	with its own `if colorKey == "sand"` rule. Two opinions about one surface is
	how a field ends up with a floor that does not match its own surround.
]]
function WorldBuilder.materialFor(colorKey: string, fallback: Enum.Material): Enum.Material
	return materialFor(colorKey, fallback)
end

--[[
	Colour, material and reflectance for one piece of map geometry.

	The colour is varied by where the piece stands. Holdfast places twenty-two
	rocks from a single palette entry and Woods twelve timbers from another, and
	at that count one exact colour reads as one object stamped repeatedly rather
	than as twenty-two rocks. See Shared/Tint.

	`part.CFrame` is already set by the time this runs, which is what makes the
	variation free -- no argument to thread through, no generator to re-order,
	and the same piece is the same colour on every server.
]]
local function style(part: BasePart, colorKey: string, transparency: number?)
	local surface = SURFACE[colorKey] or { material = Enum.Material.SmoothPlastic, reflectance = 0.02 }
	part.Material = surface.material
	part.Reflectance = surface.reflectance
	local variation = Config.get("presentation").geometryTint
	if variation then
		part.Color = Tint.at(colourOf(colorKey), part.CFrame.Position, variation.valueSpread, variation.warmthSpread)
	else
		part.Color = colourOf(colorKey)
	end
	part.Transparency = transparency or 0
	part.CastShadow = true
	part.Anchored = true
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	EnvironmentMaterials.apply(part, colorKey)
end

local function buildPiece(piece: any, mirrorX: boolean, mirrorZ: boolean, parent: Instance)
	local px, py, pz = piece.position[1], piece.position[2], piece.position[3]
	local rotY = piece.rotationY or 0
	if mirrorX then
		px = -px
		rotY = -rotY
	end
	if mirrorZ then
		pz = -pz
		rotY = -rotY
	end

	local sizeMetres = Vector3.new(piece.size[1], piece.size[2], piece.size[3])
	local name = piece.id .. (if mirrorX then "_mx" else "") .. (if mirrorZ then "_mz" else "")
	local baseCFrame = CFrame.new(Units.vectorToStuds(Vector3.new(px, py, pz)))
		* CFrame.Angles(0, math.rad(rotY), math.rad(piece.rotationZ or 0))

	--[[
		Inflatable bunkers are rounded, seamed, multi-part models, so they get an
		invisible collision box matching the map JSON's oriented box exactly and
		the visual is inscribed inside it. That keeps ONE shape authoritative for
		player collision, bot line-of-sight and projectile blocking -- see the
		collision contract at the top of Inflatables.luau.
	]]
	if Inflatables.handles(piece.shape) then
		local model = Inflatables.build(
			piece.shape,
			baseCFrame,
			Units.vectorToStuds(sizeMetres),
			colourOf(piece.colorKey),
			name,
			parent
		)

		local hull = Instance.new("Part")
		hull.Name = "CollisionHull"
		hull.Size = Units.vectorToStuds(sizeMetres)
		hull.CFrame = baseCFrame
		hull.Anchored = true
		hull.Transparency = 1
		hull.CanCollide = true
		hull.CanQuery = true
		hull.CanTouch = false
		hull.CastShadow = false
		hull.Parent = model

		model:SetAttribute("cover", piece.cover == true)
		model:SetAttribute("concealment", false)
		return model
	end

	local className = SHAPE_TO_CLASS[piece.shape] or "Part"
	local part = Instance.new(className) :: BasePart
	part.Size = Units.vectorToStuds(sizeMetres)
	part.CFrame = baseCFrame

	if piece.shape == "cylinder" then
		-- Part cylinders run along X; map data describes height on Y.
		part.Size = Units.vectorToStuds(Vector3.new(sizeMetres.Y, sizeMetres.X, sizeMetres.Z))
		part.CFrame *= CFrame.Angles(0, 0, math.pi / 2)
		part.Shape = Enum.PartType.Cylinder
	end

	style(part, piece.colorKey, piece.transparency)

	--[[
		Concealment blocks sight but not paint. In the engine that means it must
		NOT collide and must NOT be queryable by the projectile raycast, but it
		must still be visible. The bots' own line-of-sight runs through
		MapGeometry, which already knows the difference.
	]]
	if piece.concealment then
		part.CanCollide = false
		part.CanQuery = false
		part.Transparency = math.max(part.Transparency, 0.15)
	else
		part.CanCollide = true
		part.CanQuery = true
	end

	part.Name = name
	part:SetAttribute("cover", piece.cover == true)
	part:SetAttribute("concealment", piece.concealment == true)
	part.Parent = parent
	if piece.prop then
		-- Keep the original map Part as the one authoritative collider.
		part.Transparency, part.CastShadow = 1, false
		VehicleProps.build(piece.prop, baseCFrame * CFrame.new(0, -Units.metresToStuds(sizeMetres.Y / 2), 0),
			colourOf(piece.colorKey), part, sizeMetres)
	end
	return part
end

-- Surface graphics and scenery are deliberately outside the authoritative
-- geometry folder: painted trails sit flush with the floor, graphics attach
-- to existing walls, and the tree line stays beyond the arena boundary.
-- None can catch paint, hide inside the nav graph or add collision volumes.
local function buildPresentation(mapData: any, root: Folder, geometry: Folder)
	local look = mapData.presentation
	if not look then return end
	local cfg = Config.get("presentation")
	local folder = Instance.new("Folder")
	folder.Name = "Presentation"
	folder.Parent = root
	local function color(key: string): Color3
		local rgb = cfg.palette[key]
		return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	end
	local function scenery(name: string, size: Vector3, cf: CFrame, key: string, material: Enum.Material): Part
		local part = Instance.new("Part")
		part.Name, part.Anchored = name, true
		part.Size, part.CFrame = Units.vectorToStuds(size), cf
		part.Color, part.Material = color(key), material
		part.CanCollide, part.CanQuery, part.CanTouch = false, false, false
		part.CastShadow = false
		part.TopSurface, part.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
		part.Parent = folder
		return part
	end
	--[[
		Ground markings overlap at every bend and cross each other at junctions,
		and every segment used to be laid at one height -- two faces on one
		plane, which shimmers as the camera moves. Shared/Surfaces assigns each
		marking a level such that no two that touch share one, and alternates
		consecutive segments within a marking. Levels are additive from the base
		height: subtracting eventually pushed a marking below the ground it is
		drawn on, which is worse than the shimmer it was fixing.
	]]
	local markingStep = cfg.groundMarking.layerStepMetres
	local markings = look.groundDetails or {}
	local markingLevels = Surfaces.assignLevels(markings)
	for detailIndex, trail in ipairs(markings) do
		for i = 1, #trail.points - 1 do
			local a, b = trail.points[i], trail.points[i + 1]
			local lift = Surfaces.segmentHeight(
				cfg.groundMarking.heightMetres, markingLevels[detailIndex], i, markingStep
			)
			local start = Vector3.new(a[1], a[2] + lift, a[3])
			local finish = Vector3.new(b[1], b[2] + lift, b[3])
			--[[
				Top-anchored, not centre-anchored.

				The separation that stops these shimmering has to be big enough
				for the depth buffer to resolve at range, and a wafer lifted that
				far reads as a floating ribbon. So the slab is thick and only its
				TOP face sits at the computed height -- the rest is buried in the
				ground, where the extra millimetres cost nothing to look at.
			]]
			local midpoint = (start + finish) / 2
				- Vector3.new(0, cfg.groundMarking.thicknessMetres / 2, 0)
			scenery(trail.id, Vector3.new(trail.widthMetres, cfg.groundMarking.thicknessMetres, (finish - start).Magnitude),
				GroundLayers.frame(Units.vectorToStuds(midpoint), finish - start),
				trail.color, materialFor(trail.color, Enum.Material.Ground))
		end
	end
	for _, facade in ipairs(look.facades or {}) do
		local host = geometry:FindFirstChild(facade.piece)
		assert(host and host:IsA("BasePart"), `missing facade host {facade.piece}`)
		local surface = Instance.new("SurfaceGui")
		surface.Name = "Landmark"
		surface.Face = Enum.NormalId[facade.face]
		surface.CanvasSize = Vector2.new(cfg.facades.canvasSize[1], cfg.facades.canvasSize[2])
		surface.MaxDistance = Units.metresToStuds(cfg.facades.maxDistanceMetres)
		surface.AlwaysOnTop = false
		surface.LightInfluence = 0
		surface.Parent = host
		for _, y in ipairs({ 0, 1 - cfg.facades.bandHeight }) do
			local stripe = Instance.new("Frame")
			stripe.Size = UDim2.fromScale(1, cfg.facades.bandHeight)
			stripe.Position = UDim2.fromScale(0, y)
			stripe.BackgroundColor3, stripe.BorderSizePixel = color(facade.accent), 0
			stripe.Parent = surface
		end
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(cfg.facades.labelSize[1], cfg.facades.labelSize[2])
		label.Position = UDim2.fromScale(cfg.facades.labelPosition[1], cfg.facades.labelPosition[2])
		label.BackgroundTransparency = 1
		label.Text, label.TextColor3 = facade.text, color("cream")
		label.TextStrokeColor3 = color("ink")
		label.TextStrokeTransparency = cfg.facades.textStrokeTransparency
		label.TextScaled, label.TextWrapped = true, true
		label.Font = Fonts.world("signTitle")
		label.Parent = surface
	end
	if look.treeLine then
		local treeCfg, profile = cfg.treeLine, look.treeLine
		local halfW, halfL = mapData.bounds.widthMetres / 2, mapData.bounds.lengthMetres / 2
		local serial = 0
		local function tree(x: number, z: number)
			serial += 1
			local height = profile.heightMetres + treeCfg.heightVariationMetres[(serial - 1) % #treeCfg.heightVariationMetres + 1]
			local model = Instance.new("Model")
			model.Name = "TreeLine"
			local art = EnvironmentArt.append("RedwoodDistant", model, height, treeCfg.crownWidthMetres, false)
			local at = CFrame.new(Units.vectorToStuds(Vector3.new(x, 0, z)))
			for _, part in ipairs(art) do part.CFrame = at * part.CFrame end
			model.Parent = folder
		end
		for _, side in ipairs({ -1, 1 }) do
			for i = 1, profile.perLongSide do
				local offset = treeCfg.insetOutsideBoundsMetres + treeCfg.offsetVariationMetres[(i - 1) % #treeCfg.offsetVariationMetres + 1]
				tree(side * (halfW + offset), -halfL + (i - 0.5) * mapData.bounds.lengthMetres / profile.perLongSide)
			end
			for i = 1, profile.perShortSide do
				local offset = treeCfg.insetOutsideBoundsMetres + treeCfg.offsetVariationMetres[(i - 1) % #treeCfg.offsetVariationMetres + 1]
				tree(-halfW + (i - 0.5) * mapData.bounds.widthMetres / profile.perShortSide, side * (halfL + offset))
			end
		end
	end
end

--- Builds the whole map under a fresh folder in Workspace and returns it.
function WorldBuilder.build(mapName: string, parent: Instance): Folder
	EnvironmentMaterials.install()
	local mapData = Config.map(mapName)

	local root = Instance.new("Folder")
	root.Name = `Map_{mapName}`

	local geometry = Instance.new("Folder")
	geometry.Name = "Geometry"
	geometry.Parent = root

	-- Ground.
	local bounds = mapData.bounds
	local ground = Instance.new("Part")
	ground.Size = Units.vectorToStuds(
		Vector3.new(bounds.widthMetres, mapData.ground.thicknessMetres, bounds.lengthMetres)
	)
	ground.CFrame = CFrame.new(0, -ground.Size.Y / 2, 0)
	style(ground, mapData.ground.colorKey)
	ground.Name = "Ground"
	ground.Parent = root

	-- Boundary walls. Netting on Speedball is see-through; Urban's are solid.
	if mapData.walls then
		local wallCfg = mapData.walls
		local height = Units.metresToStuds(wallCfg.heightMetres)
		local halfW = Units.metresToStuds(bounds.widthMetres / 2)
		local halfL = Units.metresToStuds(bounds.lengthMetres / 2)
		local thickness = Units.metresToStuds(0.4)
		local sides = {
			{ CFrame.new(0, height / 2, -halfL), Vector3.new(halfW * 2, height, thickness) },
			{ CFrame.new(0, height / 2, halfL), Vector3.new(halfW * 2, height, thickness) },
			{ CFrame.new(-halfW, height / 2, 0), Vector3.new(thickness, height, halfL * 2) },
			{ CFrame.new(halfW, height / 2, 0), Vector3.new(thickness, height, halfL * 2) },
		}
		local walls = Instance.new("Folder")
		walls.Name = "Walls"
		walls.Parent = root
		for i, side in ipairs(sides) do
			local wall = Instance.new("Part")
			wall.CFrame = side[1]
			wall.Size = side[2]
			style(wall, wallCfg.colorKey, wallCfg.transparency)
			wall.Name = `Wall{i}`
			wall.Parent = walls
		end
	end

	local groups = {}
	if mapData.terrain then
		table.insert(groups, mapData.terrain)
	end
	if mapData.geometry then
		table.insert(groups, mapData.geometry)
	end

	local count = 0
	for _, group in ipairs(groups) do
		for _, piece in ipairs(group) do
			buildPiece(piece, false, false, geometry)
			count += 1
			if piece.mirrorX then
				buildPiece(piece, true, false, geometry)
				count += 1
			end
			if piece.mirrorZ then
				buildPiece(piece, false, true, geometry)
				count += 1
			end
			if piece.mirrorX and piece.mirrorZ then
				buildPiece(piece, true, true, geometry)
				count += 1
			end
		end
	end

	buildPresentation(mapData, root, geometry)

	--[[
		Parent the world FIRST, then dress it.

		Atmosphere only touches Lighting, but it used to run before this line --
		so anything that threw in there discarded the entire built map and left
		the player in a match with no world at all. Cosmetics must never be able
		to take the field down with them.
	]]
	root.Parent = parent

	-- The look is part of the map, not a global setting: Woods needs its haze
	-- for the same reason it needs its sightlines.
	local styled, why = pcall(Atmosphere.apply, mapName)
	if not styled then
		log.warn(`{mapName} built, but its lighting profile failed: {why}`)
	end
	log.info(`built {mapName}: {count} pieces`)
	return root
end

--- A collision filter that ignores concealment and characters, for the
--- authoritative projectile raycasts.
function WorldBuilder.projectileParams(mapRoot: Instance, ignore: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	params.RespectCanCollide = true
	return params
end

return WorldBuilder
