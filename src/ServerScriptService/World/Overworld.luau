--!strict
--[[
	Overworld -- The Landing.

	The woodsy hub between matches: a clearing with a pole barn on it, gravel
	trails out to four trailheads, a creek with a footbridge, a pond, a firepit,
	and a lot of trees. Built entirely from Data/overworld.json.

	It exists for one reason. This game is a deliberate meat grinder -- the
	player is meant to lose repeatedly and improve -- and a grinder with no let-up
	is just unpleasant. The walk back from a bad match is the only pacing device
	the design has, so it is quiet, it is slow, and there is nothing to fight.

	Nothing here collides with gameplay: the hub is a separate space and no bot,
	projectile or telemetry record ever exists in it.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Fonts = require(ReplicatedStorage.Shared.Fonts)
local Units = require(ReplicatedStorage.Shared.Units)
local Log = require(ReplicatedStorage.Shared.Log)

local Foliage = require(script.Parent.Foliage)
local EnvironmentMaterials = require(script.Parent.EnvironmentMaterials)
local VehicleProps = require(script.Parent.VehicleProps)
local YardProps = require(script.Parent.YardProps)
local Surfaces = require(ReplicatedStorage.Shared.Surfaces)
local GroundLayers = require(ReplicatedStorage.Shared.GroundLayers)
local PoleBarn = require(script.Parent.PoleBarn)
local NoticeBoard = require(script.Parent.NoticeBoard)
local Npc = require(script.Parent.Npc)
local Atmosphere = require(script.Parent.Parent.Match.Atmosphere)
local Course = require(script.Parent.Parent.Match.Course)

local log = Log.scope("LiveRound.World")

local Overworld = {}

export type Gate = {
	id: string,
	map: string,
	displayName: string,
	prompt: ProximityPrompt,
	--- The Shoothouse prompt on the same post. Absent for a field with no
	--- course authored, and for the Range.
	coursePrompt: ProximityPrompt?,
	position: Vector3,
}

export type Hub = {
	model: Model,
	gates: { Gate },
	bays: { PoleBarn.Bay },
	board: any,
	people: { [string]: Npc.Handle },
	spawn: Vector3,
	lookAt: Vector3,
	stopCycle: (() -> ())?,
	destroy: (Hub) -> (),
}

--[[
	Surface material per palette key.

	These are the built-in materials, which under the current generation carry
	real roughness and depth rather than a tinted noise overlay -- so picking the
	right one is free detail, and picking a lazy one is a flat surface no amount
	of lighting recovers. The ground is the largest thing on screen at all times
	and was the worst offender: a single 88m slab of Grass reads as a bedsheet,
	while LeafyGrass has actual relief to catch the sun.

	Concrete was doing duty for both a gravel lane and a creek bed. Neither is
	concrete. Pebble is loose stone, Ground is packed dirt, and Rock is what a
	creek bed and a boulder are made of.
]]
local MATERIAL: { [string]: Enum.Material } = {
	forestFloor = Enum.Material.LeafyGrass,
	clearingGrass = Enum.Material.Grass,
	gravel = Enum.Material.Pebble,
	dirt = Enum.Material.Ground,
	water = Enum.Material.Water,
	creekBed = Enum.Material.Rock,
	barnWood = Enum.Material.Wood,
	barnWoodDark = Enum.Material.WoodPlanks,
	signPost = Enum.Material.Wood,
	signBoard = Enum.Material.SmoothPlastic,
	trunk = Enum.Material.Wood,
	rock = Enum.Material.Rock,
	sheetMetal = Enum.Material.Metal,
	truckRed = Enum.Material.Metal,
	truckBlue = Enum.Material.Metal,
	tarp = Enum.Material.Fabric,
	lantern = Enum.Material.Neon,
	brass = Enum.Material.Metal,
	cattail = Enum.Material.Grass,
}

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

--------------------------------------------------------------------------------

function Overworld.build(parent: Instance?): Hub
	EnvironmentMaterials.install()
	local cfg = Config.get("overworld")
	local root = Instance.new("Model")
	root.Name = "TheLanding"

	local palette: { [string]: Color3 } = {}
	for key, rgb in pairs(cfg.palette) do
		palette[key] = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	end

	--[[
		Placed by CFrame, not by Position.

		Identical in Roblox for an unrotated part, and NOT identical to the
		headless harness, where the two properties are independent: a part set
		through `.Position` reads back a CFrame at the origin. Every structural
		check -- check-zfight above all -- measures CFrame, so the whole hub was
		being analysed as though it were stacked at the world origin, and a
		measurement taken against it sent me chasing a metre of burial that does
		not exist. Set the one the tools read.
	]]
	local function slab(name: string, at: Vector3, size: Vector3, key: string, holder: Instance, collide: boolean?): Part
		local part = Instance.new("Part")
		part.Name = name
		part.Size = Units.vectorToStuds(size)
		part.CFrame = CFrame.new(Units.vectorToStuds(at))
		part.Color = palette[key] or Color3.fromRGB(150, 150, 150)
		part.Material = MATERIAL[key] or Enum.Material.SmoothPlastic
		EnvironmentMaterials.apply(part, key)
		part.Anchored = true
		part.CanCollide = collide ~= false
		part.CanQuery = collide ~= false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = holder
		return part
	end

	----------------------------------------------------------------------------
	-- Ground, zones, trails
	----------------------------------------------------------------------------

	local terrainFolder = Instance.new("Folder")
	terrainFolder.Name = "Terrain"
	terrainFolder.Parent = root

	local bounds = cfg.bounds
	slab(
		"ForestFloor",
		Vector3.new(0, -cfg.ground.thicknessMetres / 2, 0),
		Vector3.new(bounds.widthMetres, cfg.ground.thicknessMetres, bounds.lengthMetres),
		cfg.ground.colorKey,
		terrainFolder
	)

	--[[
		Zones are thin patches laid on the floor in order. Circles are built as
		cylinders and rectangles as boxes; both sit a few centimetres proud of
		whatever came before, so the paint order in the data is the paint order
		on the ground.
	]]
	-- Water and solid zones use the same visible-height plan as trails. Water
	-- clears its bank surface instead of disappearing beneath a later layer.
	local groundPlan = GroundLayers.plan(cfg.zones, cfg.trails, cfg.surfaceLayerMetres.alternateMetres, cfg.barn)
	for index, zone in ipairs(cfg.zones) do
		local height = groundPlan.zones[index]
		local depth = zone.depthMetres
		local part: Part
		if zone.shape == "circle" then
			part = slab(
				zone.id,
				Vector3.new(zone.position[1], (if depth then height - depth / 2 else height / 2), zone.position[3]),
				Vector3.new(zone.radiusMetres * 2, depth or height, zone.radiusMetres * 2),
				zone.colorKey,
				terrainFolder,
				depth == nil
			)
			part.Shape = Enum.PartType.Cylinder
			part.CFrame = CFrame.new(part.CFrame.Position) * CFrame.Angles(0, 0, math.pi / 2)
			part.Size = Units.vectorToStuds(Vector3.new(depth or height, zone.radiusMetres * 2, zone.radiusMetres * 2))
		else
			part = slab(
				zone.id,
				Vector3.new(zone.position[1], (if depth then height - depth / 2 else height / 2), zone.position[3]),
				Vector3.new(zone.size[1], depth or height, zone.size[2]),
				zone.colorKey,
				terrainFolder,
				depth == nil
			)
			if zone.rotationY then
				part.CFrame = CFrame.new(part.CFrame.Position) * CFrame.Angles(0, math.rad(zone.rotationY), 0)
			end
		end
		if zone.transparency then
			part.Transparency = zone.transparency
		end
		-- Water is walked past, not swum in; it never collides or blocks a ray.
		if zone.material == "water" then
			part.CanCollide = false
			part.CanQuery = false
			part.Reflectance = 0.18
		end
	end

	--[[
		Trails are laid as overlapping slabs between the listed points, so a path
		bends without anyone hand-placing a hundred tiles. Every gate and every
		building sits on one: the player should never have to guess where to walk.
	]]
	local trailFolder = Instance.new("Folder")
	trailFolder.Name = "Trails"
	trailFolder.Parent = root

	-- Zones, path segments and rounded joins share an overlap plan. Reuse low
	-- levels wherever surfaces are disjoint, and reserve the barn floor planes.
	local layer = cfg.surfaceLayerMetres
	for trailIndex, trail in ipairs(cfg.trails) do
		for i = 1, #trail.points - 1 do
			local depth = layer.trailDepthMetres
			local segmentY = groundPlan.trails[trailIndex].segments[i]
			local joinY = groundPlan.trails[trailIndex].joins[i]
			local a = vec(trail.points[i])
			local b = vec(trail.points[i + 1])
			local delta = b - a
			local length = delta.Magnitude
			if length < 1e-4 then
				continue
			end
			--[[
				segmentY is the trail's VISIBLE SURFACE, so the slab hangs below it
				rather than straddling it. Trails are decals -- CanCollide and
				CanQuery are both false and the player walks on the floor at y=0 --
				so every centimetre of lift is a centimetre the path is drawn up the
				player's leg. Hanging the depth downward into the two-metre floor
				also means no trail ever shows a floating edge from a low angle.
			]]
			local segmentCentre = segmentY - depth / 2
			local segment = slab(
				`{trail.id}_{i}`,
				(a + b) / 2 + Vector3.new(0, segmentCentre, 0),
				Vector3.new(trail.widthMetres, depth, length + trail.widthMetres * 0.5),
				trail.colorKey,
				trailFolder,
				false
			)
			segment.CFrame = GroundLayers.frame(
				Units.vectorToStuds((a + b) / 2 + Vector3.new(0, segmentCentre, 0)), delta
			)
			-- Rounded joins, so a bend does not show a notch.
			local join = slab(
				`{trail.id}_join{i}`,
				b + Vector3.new(0, joinY - depth / 2, 0),
				Vector3.new(trail.widthMetres, depth, trail.widthMetres),
				trail.colorKey,
				trailFolder,
				false
			)
			join.Shape = Enum.PartType.Cylinder
			join.CFrame = CFrame.new(join.CFrame.Position) * CFrame.Angles(0, 0, math.pi / 2)
			-- A Roblox cylinder runs along its X axis, and the rotation above stands
			-- that axis up, so X carries the depth and Y/Z carry the disc.
			join.Size = Units.vectorToStuds(Vector3.new(depth, trail.widthMetres, trail.widthMetres))
		end
	end

	----------------------------------------------------------------------------
	-- Footbridge
	----------------------------------------------------------------------------

	if cfg.bridge then
		local bridgeFolder = Instance.new("Folder")
		bridgeFolder.Name = "Bridge"
		bridgeFolder.Parent = root

		local b = cfg.bridge
		local base = CFrame.new(Units.vectorToStuds(vec(b.position))) * CFrame.Angles(0, math.rad(b.rotationY), 0)

		for i = 0, b.plankCount - 1 do
			local along = -b.lengthMetres / 2 + (b.lengthMetres / b.plankCount) * (i + 0.5)
			local plank = slab(`Plank{i}`, Vector3.zero, Vector3.new(b.widthMetres, 0.12, b.lengthMetres / b.plankCount * 0.86), "barnWood", bridgeFolder)
			plank.CFrame = base * CFrame.new(0, 0, Units.metresToStuds(along))
		end
		for _, side in ipairs({ -1, 1 }) do
			local rail = slab(`Rail{side}`, Vector3.zero, Vector3.new(0.1, 0.1, b.lengthMetres), "barnWoodDark", bridgeFolder, false)
			rail.CFrame = base * CFrame.new(Units.metresToStuds(side * b.widthMetres / 2), Units.metresToStuds(b.railHeightMetres), 0)
			for post = 0, 4 do
				local along = -b.lengthMetres / 2 + (b.lengthMetres / 4) * post
				local upright = slab(`Post{side}_{post}`, Vector3.zero, Vector3.new(0.12, b.railHeightMetres, 0.12), "barnWoodDark", bridgeFolder, false)
				upright.CFrame = base
					* CFrame.new(Units.metresToStuds(side * b.widthMetres / 2), Units.metresToStuds(b.railHeightMetres / 2), Units.metresToStuds(along))
			end
		end
	end

	----------------------------------------------------------------------------
	-- Foliage
	----------------------------------------------------------------------------

	local foliageFolder = Instance.new("Folder")
	foliageFolder.Name = "Foliage"
	foliageFolder.Parent = root
	--[[
		Layers are ceilings, not promises: every instance is rejection-sampled
		against the exclusions, the trails and its own footprint, and gives up
		after a fixed number of tries. A layer that comes up well short is a
		tuning problem -- too many exclusions, too small an annulus -- and it is
		invisible from inside the game, so say so here.
	]]
	-- The floor slab is centred on the origin, so its walkable surface is half a
	-- thickness up. Scatter is sampled in XZ only and has to be told.
	local placed, scatterReport = Foliage.scatter(
		cfg.scatter, palette, cfg.trails, foliageFolder, cfg.ground.thicknessMetres / 2
	)
	for _, layer in ipairs(scatterReport) do
		if layer.placed < layer.requested * 0.85 then
			log.warn(`foliage layer '{layer.id}' placed {layer.placed} of {layer.requested} -- crowded out`)
		end
	end

	----------------------------------------------------------------------------
	-- Buildings
	----------------------------------------------------------------------------

	local barn = PoleBarn.build(cfg.barn, palette, root)
	local board = NoticeBoard.build(cfg.leaderboard, palette, root)
	local people = Npc.buildAll(palette, root)

	----------------------------------------------------------------------------
	-- Gates
	----------------------------------------------------------------------------

	local gateFolder = Instance.new("Folder")
	gateFolder.Name = "Gates"
	gateFolder.Parent = root

	local gates: { Gate } = {}
	for index, gateCfg in ipairs(cfg.gates) do
		local at = vec(gateCfg.position)
		local base = CFrame.new(Units.vectorToStuds(at)) * CFrame.Angles(0, math.rad(gateCfg.rotationY or 0), 0)

		local holder = Instance.new("Model")
		holder.Name = `Gate_{gateCfg.id}`
		holder.Parent = gateFolder

		local function arch(name: string, offset: Vector3, size: Vector3, key: string, collide: boolean?): Part
			local part = slab(name, Vector3.zero, size, key, holder, collide)
			part.CFrame = base * CFrame.new(Units.vectorToStuds(offset))
			return part
		end

		arch("PostL", Vector3.new(-2.6, 2.2, 0), Vector3.new(0.34, 4.4, 0.34), "signPost")
		arch("PostR", Vector3.new(2.6, 2.2, 0), Vector3.new(0.34, 4.4, 0.34), "signPost")
		arch("Lintel", Vector3.new(0, 4.5, 0), Vector3.new(6.0, 0.4, 0.4), gateCfg.colorKey, false)
		local plaque = arch("Plaque", Vector3.new(0, 3.5, 0.1), Vector3.new(5.0, 1.5, 0.12), "signBoard", false)

		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Front
		gui.CanvasSize = Vector2.new(700, 210)
		gui.LightInfluence = 0.2
		gui.Parent = plaque

		local title = Instance.new("TextLabel")
		title.Size = UDim2.fromScale(1, 0.58)
		title.BackgroundTransparency = 1
		title.Font = Fonts.world("signTitle")
		title.TextColor3 = Color3.fromRGB(42, 34, 26)
		title.TextScaled = true
		title.Text = gateCfg.displayName
		title.Parent = gui

		local sub = Instance.new("TextLabel")
		sub.Size = UDim2.fromScale(1, 0.38)
		sub.Position = UDim2.fromScale(0, 0.6)
		sub.BackgroundTransparency = 1
		sub.Font = Fonts.world("signBody")
		sub.TextColor3 = Color3.fromRGB(108, 88, 66)
		sub.TextScaled = true
		sub.Text = gateCfg.subtitle
		sub.Parent = gui

		local trigger = arch("Trigger", Vector3.new(0, 1.2, 0), Vector3.new(4.6, 2.4, 0.6), "signPost", false)
		trigger.Transparency = 1

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "Enter"
		prompt.ActionText = `Play {gateCfg.displayName}`
		prompt.ObjectText = gateCfg.subtitle
		prompt.KeyboardKeyCode = Enum.KeyCode.F
		prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
		prompt.HoldDuration = 0.45
		prompt.MaxActivationDistance = Units.metresToStuds(Config.require("venue", "gateRadiusMetres"))
		prompt.RequiresLineOfSight = false
		prompt.Parent = trigger

		--[[
			The same post offers both ways to play the field: hold F for the five
			rounds, hold E for the timed course. Two prompts on one trigger keeps
			the mode choice where the player already is, which is the only place
			a mode choice can live without a lobby -- and this project does not
			have one on purpose.
		]]
		local coursePrompt: ProximityPrompt? = nil
		if Course.hasCourse(gateCfg.map) then
			local second = Instance.new("ProximityPrompt")
			second.Name = "Shoothouse"
			second.ActionText = "Run the Shoothouse"
			local par = Course.parSeconds(gateCfg.map)
			second.ObjectText = `Timed course -- gold at {par.gold}s`
			second.KeyboardKeyCode = Enum.KeyCode.E
			second.GamepadKeyCode = Enum.KeyCode.ButtonY
			second.HoldDuration = 0.45
			second.MaxActivationDistance = prompt.MaxActivationDistance
			second.RequiresLineOfSight = false
			second.UIOffset = Vector2.new(0, 44)
			second.Parent = trigger
			coursePrompt = second
		end

		gates[index] = {
			id = gateCfg.id,
			coursePrompt = coursePrompt,
			map = gateCfg.map,
			displayName = gateCfg.displayName,
			prompt = prompt,
			position = at,
		}
	end

	----------------------------------------------------------------------------
	-- Props
	----------------------------------------------------------------------------

	local propFolder = Instance.new("Folder")
	propFolder.Name = "Props"
	propFolder.Parent = root

	--[[
		Set dressing. Vehicle and yard assemblies are authored separately; none are load
		bearing and all of them are what makes a clearing look like somewhere
		people actually spend a Saturday.
	]]
	local function buildProp(prop: any)
		local at = vec(prop.position)
		local base = CFrame.new(Units.vectorToStuds(at)) * CFrame.Angles(0, math.rad(prop.rotationY or 0), 0)
		local holder = Instance.new("Model")
		holder.Name = prop.kind
		holder.Parent = propFolder

		local function piece(name: string, offset: Vector3, size: Vector3, key: string, collide: boolean?): Part
			local part = slab(name, Vector3.zero, size, key, holder, collide)
			part.CFrame = base * CFrame.new(Units.vectorToStuds(offset))
			return part
		end

		if YardProps.handles(prop.kind) then
			YardProps.build(prop.kind, base, palette, holder)
		elseif prop.kind == "firepit" then
			for i = 0, 9 do
				local angle = (i / 10) * math.pi * 2
				piece(`Stone{i}`, Vector3.new(math.cos(angle) * 1.2, 0.18, math.sin(angle) * 1.2), Vector3.new(0.42, 0.36, 0.42), "rock")
			end
			piece("Ash", Vector3.new(0, 0.06, 0), Vector3.new(1.9, 0.1, 1.9), "dirt", false)
			local embers = piece("Embers", Vector3.new(0, 0.16, 0), Vector3.new(0.7, 0.14, 0.7), "lantern", false)
			embers.Transparency = 0.25
			local light = Instance.new("PointLight")
			light.Brightness = 1.1
			light.Range = Units.metresToStuds(9)
			light.Color = Color3.fromRGB(252, 168, 82)
			light.Parent = embers
		elseif prop.kind == "logBench" then
			local log_ = piece("Log", Vector3.new(0, 0.3, 0), Vector3.new(2.6, 0.55, 0.55), "trunk")
			log_.Shape = Enum.PartType.Cylinder
			log_.Size = Units.vectorToStuds(Vector3.new(2.6, 0.55, 0.55))
		elseif prop.kind == "truck" then
			local vehicle = VehicleProps.build("pickup", base, palette[prop.colorKey or "truckRed"], holder)
			VehicleProps.addHubCollision(vehicle, "pickup", base)
		elseif prop.kind == "chronoStand" then
			piece("Post", Vector3.new(0, 0.9, 0), Vector3.new(0.16, 1.8, 0.16), "signPost")
			piece("Box", Vector3.new(0, 1.7, 0.2), Vector3.new(0.6, 0.4, 0.3), "sheetMetal", false)
			local sign = piece("Sign", Vector3.new(0, 2.2, 0.16), Vector3.new(1.5, 0.6, 0.06), "signBoard", false)
			local gui = Instance.new("SurfaceGui")
			gui.Face = Enum.NormalId.Front
			gui.CanvasSize = Vector2.new(400, 160)
			gui.LightInfluence = 0.2
			gui.Parent = sign
			local label = Instance.new("TextLabel")
			label.Size = UDim2.fromScale(1, 1)
			label.BackgroundTransparency = 1
			label.Font = Fonts.world("signTitle")
			label.TextColor3 = Color3.fromRGB(44, 36, 26)
			label.TextScaled = true
			label.TextWrapped = true
			label.Text = "CHRONO\nALL MARKERS BEFORE PLAY"
			label.Parent = gui
		elseif prop.kind == "dock" then
			for i = 0, 5 do
				piece(`Plank{i}`, Vector3.new(0, 0.4, -i * 0.9), Vector3.new(2.2, 0.1, 0.8), "barnWood")
			end
			for _, z in ipairs({ 0, -2.7, -4.5 }) do
				piece(`Pile{z}`, Vector3.new(-1.0, 0.15, z), Vector3.new(0.16, 0.7, 0.16), "barnWoodDark", false)
				piece(`Pile2{z}`, Vector3.new(1.0, 0.15, z), Vector3.new(0.16, 0.7, 0.16), "barnWoodDark", false)
			end
		elseif prop.kind == "canoe" then
			local hull = piece("Hull", Vector3.new(0, 0.3, 0), Vector3.new(0.9, 0.5, 4.2), "truckRed", false)
			hull.Shape = Enum.PartType.Cylinder
			hull.Size = Units.vectorToStuds(Vector3.new(4.2, 0.9, 0.5))
			hull.CFrame = base * CFrame.new(0, Units.metresToStuds(0.3), 0) * CFrame.Angles(0, math.pi / 2, 0)
		elseif prop.kind == "lantern" then
			piece("Post", Vector3.new(0, 1.5, 0), Vector3.new(0.14, 3.0, 0.14), "signPost")
			piece("Arm", Vector3.new(0.3, 2.95, 0), Vector3.new(0.7, 0.1, 0.1), "signPost", false)
			local glass = piece("Glass", Vector3.new(0.6, 2.75, 0), Vector3.new(0.3, 0.36, 0.3), "lantern", false)
			glass.Transparency = 0.15
			local light = Instance.new("PointLight")
			light.Brightness = 1.5
			light.Range = Units.metresToStuds(14)
			light.Color = Color3.fromRGB(252, 214, 138)
			light.Parent = glass
		elseif prop.kind == "trailSign" then
			piece("Post", Vector3.new(0, 1.1, 0), Vector3.new(0.14, 2.2, 0.14), "signPost")
			for i, entry in ipairs({ "TOURNAMENT FIELD", "THE BACK LOT", "THE BACK FORTY" }) do
				local arm = piece(`Arm{i}`, Vector3.new(0.55, 2.0 - (i - 1) * 0.34, 0), Vector3.new(1.5, 0.24, 0.06), "signBoard", false)
				arm.CFrame = arm.CFrame * CFrame.Angles(0, math.rad((i - 2) * 46), 0)
				local gui = Instance.new("SurfaceGui")
				gui.Face = Enum.NormalId.Front
				gui.CanvasSize = Vector2.new(380, 60)
				gui.LightInfluence = 0.25
				gui.Parent = arm
				local label = Instance.new("TextLabel")
				label.Size = UDim2.fromScale(1, 1)
				label.BackgroundTransparency = 1
				label.Font = Fonts.world("signBody")
				label.TextColor3 = Color3.fromRGB(48, 38, 28)
				label.TextScaled = true
				label.Text = entry
				label.Parent = gui
			end
		end
	end

	for _, prop in ipairs(cfg.props) do
		buildProp(prop)
	end

	----------------------------------------------------------------------------
	-- Ambience
	----------------------------------------------------------------------------

	local soundFolder = Instance.new("Folder")
	soundFolder.Name = "Ambience"
	soundFolder.Parent = root

	for _, bed in ipairs(cfg.ambience.beds) do
		local emitter = Instance.new("Part")
		emitter.Name = `Ambience_{bed.id}`
		emitter.Size = Vector3.new(1, 1, 1)
		emitter.CFrame = CFrame.new(Units.vectorToStuds(vec(bed.position)))
		emitter.Anchored = true
		emitter.CanCollide = false
		emitter.CanQuery = false
		emitter.Transparency = 1
		emitter.Parent = soundFolder

		local sound = Instance.new("Sound")
		sound.Name = bed.id
		sound.Looped = bed.looped
		sound.Volume = bed.volume
		sound.RollOffMaxDistance = Units.metresToStuds(bed.radiusMetres)
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		--[[
			Sound ids are deliberately left empty in the data. Audio assets are
			uploaded per experience and hardcoding someone else's id ships a
			broken build. Put an id in Data/overworld.json and this plays.
		]]
		if bed.soundId then
			sound.SoundId = bed.soundId
			sound:Play()
		end
		sound.Parent = emitter
	end

	----------------------------------------------------------------------------

	root.Parent = parent or Workspace
	Atmosphere.applyProfile(cfg.lighting, "the landing")

	local peopleCount = 0
	for _ in pairs(people) do
		peopleCount += 1
	end
	log.info(`built The Landing: {placed} plants, {#gates} gates, {#barn.bays} bays, {peopleCount} people`)

	local hub: Hub
	hub = {
		model = root,
		gates = gates,
		bays = barn.bays,
		board = board,
		people = people,
		spawn = vec(cfg.spawn.position),
		lookAt = vec(cfg.spawn.lookAt),
		stopCycle = NoticeBoard.startCycle(board),
		destroy = function(self: Hub)
			if self.stopCycle then
				(self.stopCycle :: () -> ())()
			end
			self.model:Destroy()
		end,
	}
	return hub
end

return Overworld
