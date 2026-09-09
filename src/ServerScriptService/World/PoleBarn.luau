--!strict
--[[
	PoleBarn -- Parsons Field Supply.

	A real pole barn: pressure-treated posts on a gravel apron, girts spanning
	between them, corrugated sheet metal hung on the outside, a gable roof on
	exposed rafters, and a big rolling door on the front. It is built the way the
	real thing is built -- posts first, then the skin -- because that is what
	makes the inside read as a shed rather than a room.

	Three bays across the back wall, each with a counter, a signboard, a hanging
	work light and a ProximityPrompt:

	    MARKERS          sidegrades, never upgrades
	    PAINT & AIR      how much you carry and how fast it feeds
	    PROTECTIVE       quiet or quick, and none of it stops paint

	Layout and stock both come from Data/overworld.json and Data/gear.json.
	Nothing is authored in Studio.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Fonts = require(ReplicatedStorage.Shared.Fonts)
local Units = require(ReplicatedStorage.Shared.Units)
local Log = require(ReplicatedStorage.Shared.Log)
local EnvironmentMaterials = require(script.Parent.EnvironmentMaterials)

local log = Log.scope("LiveRound.World")

local PoleBarn = {}

export type Bay = {
	id: string,
	displayName: string,
	categories: { string },
	prompt: ProximityPrompt,
	counter: BasePart,
	standPosition: Vector3,
}

export type Barn = {
	model: Model,
	bays: { Bay },
	doorPosition: Vector3,
}

--------------------------------------------------------------------------------

local MATERIAL: { [string]: Enum.Material } = {
	barnWood = Enum.Material.Wood,
	barnWoodDark = Enum.Material.WoodPlanks,
	beam = Enum.Material.Wood,
	sheetMetal = Enum.Material.Metal,
	sheetMetalRust = Enum.Material.Metal,
	gravel = Enum.Material.Concrete,
	tarp = Enum.Material.Fabric,
	signBoard = Enum.Material.SmoothPlastic,
	signPost = Enum.Material.Wood,
	brass = Enum.Material.Metal,
	lantern = Enum.Material.Neon,
	-- Shop stock. Long-standing Enum.Material values only; nothing here is new
	-- enough to need checking against the current API.
	pegboard = Enum.Material.WoodPlanks,
	paintCase = Enum.Material.SmoothPlastic,
	podPlastic = Enum.Material.SmoothPlastic,
	podPlasticAlt = Enum.Material.SmoothPlastic,
	maskLens = Enum.Material.Glass,
	maskShell = Enum.Material.SmoothPlastic,
	jerseyRed = Enum.Material.Fabric,
	jerseyBlue = Enum.Material.Fabric,
	jerseyOchre = Enum.Material.Fabric,
	steelTank = Enum.Material.Metal,
	chalkboard = Enum.Material.Slate,
	extinguisher = Enum.Material.Metal,
	clockFace = Enum.Material.SmoothPlastic,
	gaugeFace = Enum.Material.SmoothPlastic,
	paper = Enum.Material.SmoothPlastic,
}

--[[
	Every shelf-prop kind the bay builder knows how to make.

	Declared here rather than inferred from the switch below, so a typo in
	`barn.bays[].shelfProps` fails a spec instead of silently building nothing --
	which, for set dressing, would look exactly like the bug this replaced.
]]
local PROP_KINDS: { [string]: boolean } = {
	markerRack = true, barrelBin = true, barrelSocks = true, chronoReadout = true,
	paintCases = true, podRack = true, tankRow = true, fillStation = true,
	maskShelf = true, jerseyRail = true, padStack = true,
	register = true, squeegeeJar = true, tapeRoll = true, coffeeCup = true,
	priceList = true, corkboard = true, wallClock = true, fireExtinguisher = true,
	aisleShelf = true, roadSign = true,
}

function PoleBarn.handlesProp(kind: string): boolean
	return PROP_KINDS[kind] == true
end

--------------------------------------------------------------------------------

--- Sheet and rafter stock in metres, shared by the builder and by `roofline`.
local ROOF_SHEET_THICKNESS = 0.16
local RAFTER_DEPTH = 0.26

export type Roofline = {
	eaveHeightMetres: number,
	ridgeHeightMetres: number,
	riseMetres: number,
	pitchRadians: number,
	slopeLengthMetres: number,
	eaveOverhangHorizontalMetres: number,
	sign: { halfWidthMetres: number, heightMetres: number, centreHeightMetres: number },
}

--[[
	Every derived roof number, in one pure function.

	Deliberately Roblox-free. This is a building whose correctness is arithmetic
	and there is no Studio in the verification loop, so OverworldSpec asserts the
	ridge sits above the eaves from here rather than anyone squinting at a
	screenshot. Callers get the numbers; the builder does the placing.
]]
function PoleBarn.roofline(cfg: any): Roofline
	local halfD = cfg.depthMetres / 2
	local rise = cfg.roofRiseMetres
	local pitch = math.atan2(rise, halfD)
	local overhang = cfg.eaveOverhangMetres or 0
	local signHeight = cfg.signHeightMetres or 2.4
	local signStandoff = cfg.signStandoffMetres or 0.35
	return {
		eaveHeightMetres = cfg.wallHeightMetres,
		ridgeHeightMetres = cfg.wallHeightMetres + rise,
		riseMetres = rise,
		pitchRadians = pitch,
		-- Ridge to eave along the slope, plus whatever hangs past the wall.
		slopeLengthMetres = halfD / math.cos(pitch) + overhang,
		eaveOverhangHorizontalMetres = overhang * math.cos(pitch),
		sign = {
			halfWidthMetres = cfg.widthMetres * (cfg.signWidthFraction or 0.62) / 2,
			heightMetres = signHeight,
			centreHeightMetres = cfg.wallHeightMetres + signStandoff + signHeight / 2,
		},
	}
end

--- Height of the roof surface above the floor at depth `z` from the ridge.
--- Used by the gable infill and asserted by the spec.
function PoleBarn.roofHeightAt(cfg: any, z: number): number
	local halfD = cfg.depthMetres / 2
	local clamped = math.min(math.abs(z), halfD)
	return cfg.wallHeightMetres + cfg.roofRiseMetres * (1 - clamped / halfD)
end

--------------------------------------------------------------------------------

--- Builds the barn. `palette` is the overworld palette; `origin` is the barn's
--- world CFrame, so everything below is authored in barn-local metres.
function PoleBarn.build(cfg: any, palette: { [string]: Color3 }, parent: Instance): Barn
	EnvironmentMaterials.install()
	local model = Instance.new("Model")
	model.Name = "PoleBarn"

	local function colour(key: string): Color3
		return palette[key] or Color3.fromRGB(160, 160, 160)
	end

	local origin = CFrame.new(Units.vectorToStuds(Vector3.new(cfg.position[1], cfg.position[2], cfg.position[3])))
		* CFrame.Angles(0, math.rad(cfg.rotationY or 0), 0)

	--[[
		One sign implementation for the whole barn.

		There were two inline SurfaceGui blocks in here already and the shop
		dressing wanted a third; this is that one. `lines` is a list of
		{ text, heightFraction, colour, bold } drawn top to bottom on the part's
		front face.
	]]
	local function signFace(part: BasePart, canvas: Vector2, lines: { any })
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Front
		gui.CanvasSize = canvas
		gui.LightInfluence = 0.18
		gui.Parent = part
		local y = 0
		for _, line in ipairs(lines) do
			local label = Instance.new("TextLabel")
			label.Size = UDim2.fromScale(1, line.height)
			label.Position = UDim2.fromScale(0, y)
			label.BackgroundTransparency = 1
			label.Font = if line.bold then Fonts.world("signTitle") else Fonts.world("signBody")
			label.TextColor3 = line.colour
			label.TextScaled = true
			label.TextWrapped = line.wrap == true
			label.Text = line.text
			label.Parent = gui
			y += line.height
		end
		return gui
	end

	--- Places a box in barn-local metres. Sizes are metres; the studs conversion
	--- happens here so no call site below ever has to think about it.
	local function slab(name: string, at: Vector3, size: Vector3, key: string, collide: boolean?): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = Units.vectorToStuds(size)
		p.CFrame = origin * CFrame.new(Units.vectorToStuds(at))
		p.Color = colour(key)
		p.Material = MATERIAL[key] or Enum.Material.SmoothPlastic
		EnvironmentMaterials.apply(p, key)
		p.Anchored = true
		p.CanCollide = collide ~= false
		p.CanQuery = collide ~= false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = model
		return p
	end

	local halfW = cfg.widthMetres / 2
	local halfD = cfg.depthMetres / 2
	local wallH = cfg.wallHeightMetres
	local rise = cfg.roofRiseMetres

	----------------------------------------------------------------------------
	-- Slab and posts
	----------------------------------------------------------------------------

	-- Top at +0.04 rather than flush. A concrete apron stands a little proud of
	-- the dirt, and flush meant 217 studs of it sharing the ground's plane.
	for _, name in ipairs({ "Slab", "Floor" }) do
		local surface = cfg.groundSurfaces[name]
		slab(name, Vector3.new(0, surface.centerY, 0),
			Vector3.new(cfg.widthMetres + surface.overhang, surface.thickness, cfg.depthMetres + surface.overhang), surface.colorKey)
	end

	--[[
		The posts are the building. Everything else hangs off them, and leaving
		them proud of the walls on the inside is what makes it read as a pole
		barn instead of a box with a roof on it.
	]]
	local postSpacing = 5.75
	local postCount = math.floor(cfg.widthMetres / postSpacing)
	for i = 0, postCount do
		local x = -halfW + i * (cfg.widthMetres / postCount)
		for _, z in ipairs({ -halfD, halfD }) do
			slab(`Post_{i}_{z}`, Vector3.new(x, wallH / 2, z), Vector3.new(0.34, wallH, 0.34), "beam")
		end
	end
	for _, x in ipairs({ -halfW, halfW }) do
		local depthPosts = math.floor(cfg.depthMetres / postSpacing)
		for i = 1, depthPosts - 1 do
			local z = -halfD + i * (cfg.depthMetres / depthPosts)
			slab(`SidePost_{x}_{i}`, Vector3.new(x, wallH / 2, z), Vector3.new(0.34, wallH, 0.34), "beam")
		end
	end

	-- Girts: the horizontal runs the metal is screwed to.
	for _, height in ipairs({ 1.4, 3.4, 5.4, wallH - 0.3 }) do
		slab(`GirtBack_{height}`, Vector3.new(0, height, -halfD), Vector3.new(cfg.widthMetres, 0.18, 0.14), "beam", false)
		slab(`GirtLeft_{height}`, Vector3.new(-halfW, height, 0), Vector3.new(0.14, 0.18, cfg.depthMetres), "beam", false)
		slab(`GirtRight_{height}`, Vector3.new(halfW, height, 0), Vector3.new(0.14, 0.18, cfg.depthMetres), "beam", false)
	end

	----------------------------------------------------------------------------
	-- Sheet metal skin
	----------------------------------------------------------------------------

	--[[
		Corrugation, faked with alternating panel depth. Two tones of metal in an
		irregular pattern reads as replaced panels, which is what an old barn
		actually looks like -- and it breaks up 46 metres of flat grey wall.
	]]
	local panelWidth = 1.15
	local panels = math.floor(cfg.widthMetres / panelWidth)
	for i = 0, panels - 1 do
		local x = -halfW + panelWidth * (i + 0.5)
		local rusted = (i % 7 == 3) or (i % 11 == 5)
		local key = if rusted then "sheetMetalRust" else "sheetMetal"
		local depth = if i % 2 == 0 then 0.1 else 0.07
		slab(`PanelBack_{i}`, Vector3.new(x, wallH / 2, -halfD - 0.12), Vector3.new(panelWidth * 0.98, wallH, depth), key)
	end

	local sidePanels = math.floor(cfg.depthMetres / panelWidth)
	for _, side in ipairs({ -1, 1 }) do
		for i = 0, sidePanels - 1 do
			local z = -halfD + panelWidth * (i + 0.5)
			local rusted = (i % 5 == 2)
			local key = if rusted then "sheetMetalRust" else "sheetMetal"
			local depth = if i % 2 == 0 then 0.1 else 0.07
			slab(
				`PanelSide_{side}_{i}`,
				Vector3.new(side * (halfW + 0.12), wallH / 2, z),
				Vector3.new(depth, wallH, panelWidth * 0.98),
				key
			)
		end
	end

	----------------------------------------------------------------------------
	-- Front wall, with the rolling door open
	----------------------------------------------------------------------------

	local doorHalf = cfg.doorWidthMetres / 2
	local frontSpan = halfW - doorHalf
	for _, side in ipairs({ -1, 1 }) do
		local centreX = side * (doorHalf + frontSpan / 2)
		local frontPanels = math.max(1, math.floor(frontSpan / panelWidth))
		for i = 0, frontPanels - 1 do
			local x = centreX - frontSpan / 2 + panelWidth * (i + 0.5)
			local key = if i % 6 == 4 then "sheetMetalRust" else "sheetMetal"
			slab(
				`PanelFront_{side}_{i}`,
				Vector3.new(x, wallH / 2, halfD + 0.12),
				Vector3.new(panelWidth * 0.98, wallH, 0.09),
				key
			)
		end
	end

	-- Header over the door, and the rolled-up door itself sitting above it.
	slab("DoorHeader", Vector3.new(0, wallH - 0.45, halfD + 0.1), Vector3.new(cfg.doorWidthMetres + 0.8, 0.9, 0.3), "beam")
	slab("RolledDoor", Vector3.new(0, wallH - 1.15, halfD + 0.28), Vector3.new(cfg.doorWidthMetres, 0.7, 0.7), "sheetMetalRust", false)
	slab("DoorTrackL", Vector3.new(-doorHalf, wallH / 2, halfD + 0.26), Vector3.new(0.14, wallH, 0.14), "sheetMetal", false)
	slab("DoorTrackR", Vector3.new(doorHalf, wallH / 2, halfD + 0.26), Vector3.new(0.14, wallH, 0.14), "sheetMetal", false)

	----------------------------------------------------------------------------
	-- Gable roof on exposed rafters
	----------------------------------------------------------------------------

	--[[
		The pitch sign is the whole trick here, so it is worth stating.

		Rotating a part about its local X by +theta sends local +Z to
		(0, -sin theta, cos theta) -- outward and DOWN. Each sheet is centred on
		its own half of the span and runs from the ridge at z = 0 out to the eave
		at z = side * halfD, so the sheet on the +Z side wants exactly that: its
		+Z end must fall by `rise`. Hence `side * pitch`.

		This block used to negate it. Both slopes then fell toward the centre,
		which is a valley rather than a gable, and the ridge cap and ridge beam
		were left floating over the trough at the height the ridge should have
		been. `PoleBarn.roofline` below derives the same numbers without a
		running Roblox so OverworldSpec can assert the ridge is the high point.
	]]
	local roof = PoleBarn.roofline(cfg)
	local pitch = roof.pitchRadians
	local downY, downZ = -math.sin(pitch), math.cos(pitch)
	local sheetMid = roof.slopeLengthMetres / 2

	for _, side in ipairs({ -1, 1 }) do
		-- Walk down-slope from the ridge to find the sheet's centre, so the
		-- overhang lengthens the sheet at the eave instead of sliding the whole
		-- panel off the ridge.
		local at = Vector3.new(0, roof.ridgeHeightMetres + downY * sheetMid, side * downZ * sheetMid)
		local sheet = slab(
			`Roof_{side}`,
			at,
			Vector3.new(cfg.widthMetres + 1.4, ROOF_SHEET_THICKNESS, roof.slopeLengthMetres),
			"sheetMetal"
		)
		sheet.CFrame = origin * CFrame.new(Units.vectorToStuds(at)) * CFrame.Angles(side * pitch, 0, 0)
	end

	slab("RidgeCap", Vector3.new(0, roof.ridgeHeightMetres + 0.08, 0), Vector3.new(cfg.widthMetres + 1.5, 0.18, 0.5), "sheetMetalRust", false)

	-- Rafters and the ridge beam, left visible from inside.
	slab("RidgeBeam", Vector3.new(0, roof.ridgeHeightMetres - 0.25, 0), Vector3.new(cfg.widthMetres, 0.3, 0.26), "beam", false)

	--[[
		Rafters tuck under the sheets along the ROOF normal, not along world Y.
		Offsetting in Y would leave them proud of the metal at the ridge and
		buried at the eave, which is visible from inside the barn -- the one
		place these are meant to be seen.
	]]
	local rafterDrop = ROOF_SHEET_THICKNESS / 2 + RAFTER_DEPTH / 2
	for i = 0, postCount do
		local x = -halfW + i * (cfg.widthMetres / postCount)
		for _, side in ipairs({ -1, 1 }) do
			local at = Vector3.new(x, roof.ridgeHeightMetres + downY * sheetMid, side * downZ * sheetMid)
			local rafter = slab(
				`Rafter_{i}_{side}`,
				at,
				Vector3.new(0.16, RAFTER_DEPTH, roof.slopeLengthMetres),
				"beam",
				false
			)
			rafter.CFrame = origin
				* CFrame.new(Units.vectorToStuds(at))
				* CFrame.Angles(side * pitch, 0, 0)
				* CFrame.new(0, -Units.metresToStuds(rafterDrop), 0)
		end
		-- Collar tie across the span, below the ridge where a real one sits.
		slab(`Tie_{i}`, Vector3.new(x, wallH + rise * 0.42, 0), Vector3.new(0.14, 0.2, cfg.depthMetres * 0.55), "beam", false)
	end

	----------------------------------------------------------------------------
	-- Gable infill
	----------------------------------------------------------------------------

	--[[
		The ridge runs along X, so the two gable triangles are the SHORT walls.
		While the roof was inverted these were hidden; corrected, they are open
		holes between the eave and the ridge and you can see straight into the
		attic from outside. Filled with the same panel run as the walls, stepped
		to the slope.
	]]
	local gablePanels = math.max(1, math.floor(cfg.depthMetres / panelWidth))
	for _, side in ipairs({ -1, 1 }) do
		for i = 0, gablePanels - 1 do
			local z = -halfD + cfg.depthMetres * ((i + 0.5) / gablePanels)
			local height = rise * (1 - math.abs(z) / halfD)
			if height > 0.12 then
				local key = if i % 5 == 2 then "sheetMetalRust" else "sheetMetal"
				slab(
					`Gable_{side}_{i}`,
					Vector3.new(side * (halfW + 0.12), wallH + height / 2, z),
					Vector3.new(0.08, height, (cfg.depthMetres / gablePanels) * 0.98),
					key,
					false
				)
			end
		end
	end

	----------------------------------------------------------------------------
	-- Signage
	----------------------------------------------------------------------------

	--[[
		The door is on the long wall, so the front of the barn is an EAVE, not a
		gable -- there is no triangle to hang a sign in and nothing above the
		door but roof edge. So the board stands proud of the eave on two
		brackets, the way a farm store actually signs itself. Height and width
		come from the data; the standoff is what keeps it off the metal.
	]]
	local signTop = roof.sign.centreHeightMetres + roof.sign.heightMetres / 2
	local signZ = halfD + roof.eaveOverhangHorizontalMetres + 0.3
	local wallFaceZ = halfD + 0.22
	for _, sx in ipairs({ -1, 1 }) do
		local bracketBottom = wallH - 1.9
		local bracketX = sx * roof.sign.halfWidthMetres * 0.7
		local postZ = signZ - 0.16
		slab(
			`SignBracket_{sx}`,
			Vector3.new(bracketX, (bracketBottom + signTop) / 2, postZ),
			Vector3.new(0.22, signTop - bracketBottom, 0.22),
			"signPost",
			false
		)
		-- Tie back to the wall below the eave, so the board is visibly held up
		-- rather than standing in mid-air in front of the barn.
		slab(
			`SignStrut_{sx}`,
			Vector3.new(bracketX, wallH - 1.5, (wallFaceZ + postZ) / 2),
			Vector3.new(0.16, 0.16, postZ - wallFaceZ),
			"signPost",
			false
		)
	end

	local fascia = slab(
		"Fascia",
		Vector3.new(0, roof.sign.centreHeightMetres, signZ),
		Vector3.new(roof.sign.halfWidthMetres * 2, roof.sign.heightMetres, 0.2),
		"signBoard",
		false
	)
	signFace(fascia, Vector2.new(1400, 240), {
		{ text = cfg.name, height = 0.62, colour = Color3.fromRGB(46, 36, 26), bold = true },
		{ text = cfg.subtitle, height = 0.36, colour = Color3.fromRGB(96, 76, 56) },
	})

	----------------------------------------------------------------------------
	-- Interior lighting
	----------------------------------------------------------------------------

	--[[
		Shop lights hung off the rafters, down the length of the barn.

		The interior was dark, and with the roof the right way up it is darker --
		a gable actually closes the building in where the valley was letting
		daylight through the ridge. Each of these is a PointLight, so the count
		lives in the data next to a note about why it is small.
	]]
	local lights = cfg.interiorLights
	if lights then
		for i = 1, lights.count do
			local x = -halfW + cfg.widthMetres * (i / (lights.count + 1))
			local cord = slab(`ShopLightCord_{i}`, Vector3.new(x, lights.heightMetres + 0.5, 0), Vector3.new(0.04, 1.0, 0.04), "beam", false)
			cord.CastShadow = false
			local shade = slab(`ShopLightShade_{i}`, Vector3.new(x, lights.heightMetres, 0), Vector3.new(0.7, 0.22, 0.7), "sheetMetal", false)
			shade.CastShadow = false
			local bulb = slab(`ShopLightBulb_{i}`, Vector3.new(x, lights.heightMetres - 0.16, 0), Vector3.new(0.26, 0.16, 0.26), "lantern", false)
			bulb.Transparency = 0.1
			bulb.CastShadow = false
			local light = Instance.new("PointLight")
			light.Brightness = lights.brightness
			light.Range = Units.metresToStuds(lights.rangeMetres)
			light.Color = colour("lantern")
			light.Parent = bulb
		end
	end

	----------------------------------------------------------------------------
	-- Bays
	----------------------------------------------------------------------------

	local bays: { Bay } = {}
	local barnPosition = Vector3.new(cfg.position[1], cfg.position[2], cfg.position[3])

	for index, bayCfg in ipairs(cfg.bays) do
		local worldStand = Vector3.new(bayCfg.position[1], bayCfg.position[2], bayCfg.position[3])
		local localX = worldStand.X - barnPosition.X
		local backZ = -halfD + 1.4

		-- Back-wall bay panel, so each section reads as its own shop.
		slab(`BayWall_{bayCfg.id}`, Vector3.new(localX, wallH / 2 - 0.4, backZ - 1.3), Vector3.new(10.5, wallH - 0.8, 0.14), bayCfg.colorKey, false)

		-- Counter, with a worn timber top.
		local counter = slab(`Counter_{bayCfg.id}`, Vector3.new(localX, 0.55, backZ), Vector3.new(9.2, 1.1, cfg.counterDepthMetres), "barnWood")
		slab(`CounterTop_{bayCfg.id}`, Vector3.new(localX, 1.13, backZ), Vector3.new(9.6, 0.1, cfg.counterDepthMetres + 0.3), "barnWoodDark")

		--[[
			Pegboard, then shelving in front of it. The shelves sit 0.95m off the
			wall panel so the board stays visible between them -- an unbroken run
			of shelf against bare sheet metal is what made these read as storage
			rather than as a counter someone works behind.
		]]
		slab(
			`Pegboard_{bayCfg.id}`,
			Vector3.new(localX, 3.5, backZ - 1.21),
			Vector3.new(9.6, 3.4, 0.06),
			"pegboard",
			false
		)
		for shelf = 1, 3 do
			slab(
				`Shelf_{bayCfg.id}_{shelf}`,
				Vector3.new(localX, 1.5 + shelf * 0.95, backZ - 0.95),
				Vector3.new(9.0, 0.09, 0.5),
				"barnWood",
				false
			)
			for _, bx in ipairs({ -4.2, 0, 4.2 }) do
				slab(
					`ShelfBracket_{bayCfg.id}_{shelf}_{bx}`,
					Vector3.new(localX + bx, 1.5 + shelf * 0.95 - 0.14, backZ - 1.1),
					Vector3.new(0.07, 0.28, 0.24),
					"beam",
					false
				)
			end
		end

		-- Hanging work light over the counter.
		local shade = slab(`LightShade_{bayCfg.id}`, Vector3.new(localX, wallH - 1.5, backZ + 0.6), Vector3.new(0.9, 0.3, 0.9), "sheetMetal", false)
		slab(`LightCord_{bayCfg.id}`, Vector3.new(localX, wallH - 0.8, backZ + 0.6), Vector3.new(0.05, 1.1, 0.05), "beam", false)
		local bulb = slab(`Bulb_{bayCfg.id}`, Vector3.new(localX, wallH - 1.72, backZ + 0.6), Vector3.new(0.3, 0.2, 0.3), "lantern", false)
		bulb.Transparency = 0.1
		local light = Instance.new("PointLight")
		light.Brightness = 1.4
		light.Range = Units.metresToStuds(11)
		light.Color = colour("lantern")
		light.Parent = bulb
		shade.CastShadow = false

		-- Signboard above the counter.
		-- Above the shelving, not through it: the top shelf reaches 4.4m.
		local sign = slab(`BaySign_{bayCfg.id}`, Vector3.new(localX, 5.6, backZ - 1.18), Vector3.new(7.4, 1.5, 0.1), "signBoard", false)
		signFace(sign, Vector2.new(900, 190), {
			{ text = bayCfg.displayName, height = 0.56, colour = Color3.fromRGB(42, 34, 26), bold = true },
			{ text = bayCfg.blurb, height = 0.42, colour = Color3.fromRGB(104, 84, 62), wrap = true },
		})


		--[[
			Stock.

			Empty shelves are the reason these bays read as storage rather than
			as a shop. Each bay's stock comes out of `barn.bays[].shelfProps` and
			is built by the switch below, mirroring `buildProp` in Overworld
			rather than inventing a second architecture for set dressing.

			Positions in the data are bay-local metres: X across the counter, Y
			off the floor, Z out from the back wall. Every piece is non-colliding
			and non-queryable -- none of it may block a camera or catch a ray.
		]]
		local function bayProp(prop: any)
			local at = Vector3.new(localX + prop.at[1], prop.at[2], backZ + prop.at[3])
			local base = origin
				* CFrame.new(Units.vectorToStuds(at))
				* CFrame.Angles(0, math.rad(prop.rotationY or 0), 0)

			local pieceIndex = 0
			local function piece(offset: Vector3, size: Vector3, key: string): Part
				pieceIndex += 1
				local part = slab(`{prop.kind}_{bayCfg.id}_{pieceIndex}`, Vector3.zero, size, key, false)
				part.CFrame = base * CFrame.new(Units.vectorToStuds(offset))
				part.CastShadow = false
				return part
			end
			local function tube(offset: Vector3, length: number, diameter: number, key: string, vertical: boolean?): Part
				local part = piece(offset, Vector3.new(length, diameter, diameter), key)
				part.Shape = Enum.PartType.Cylinder
				part.CFrame = base
					* CFrame.new(Units.vectorToStuds(offset))
					* (if vertical then CFrame.Angles(0, 0, math.pi / 2) else CFrame.Angles(0, math.pi / 2, 0))
				return part
			end

			local kind = prop.kind
			local tint = prop.colorKey

			----------------------------------------------------------------
			-- MARKERS bay
			----------------------------------------------------------------
			if kind == "markerRack" then
				-- Marker bodies hanging on hooks, muzzles down, the way a pro
				-- shop actually racks them.
				local count = prop.count or 4
				for i = 1, count do
					local x = (i - (count + 1) / 2) * 0.42
					piece(Vector3.new(x, 0.34, 0), Vector3.new(0.11, 0.3, 0.13), tint or "signBoard")
					tube(Vector3.new(x, -0.04, -0.02), 0.62, 0.05, "sheetMetal", true)
					tube(Vector3.new(x, 0.52, -0.03), 0.1, 0.22, "maskShell", true)
					piece(Vector3.new(x, 0.66, 0), Vector3.new(0.02, 0.12, 0.02), "brass")
				end
				piece(Vector3.new(0, 0.74, -0.02), Vector3.new(count * 0.42 + 0.2, 0.05, 0.05), "sheetMetal")

			elseif kind == "barrelBin" then
				-- Loose barrels stood on end in an open crate.
				piece(Vector3.new(0, 0.22, 0), Vector3.new(0.62, 0.44, 0.42), "barnWoodDark")
				for i = 1, prop.count or 9 do
					local x = ((i - 1) % 3 - 1) * 0.17
					local z = (math.floor((i - 1) / 3) - 1) * 0.14
					tube(Vector3.new(x, 0.62, z), 0.66, 0.05, if i % 2 == 0 then "sheetMetal" else "brass", true)
				end

			elseif kind == "barrelSocks" then
				for i = 1, prop.count or 5 do
					local x = (i - 3) * 0.14
					piece(Vector3.new(x, 0.16, 0), Vector3.new(0.1, 0.32, 0.07),
						if i % 3 == 0 then "jerseyRed" elseif i % 3 == 1 then "jerseyBlue" else "jerseyOchre")
				end

			elseif kind == "chronoReadout" then
				piece(Vector3.new(0, 0.14, 0), Vector3.new(0.34, 0.28, 0.2), "maskShell")
				local face = piece(Vector3.new(0, 0.18, 0.11), Vector3.new(0.26, 0.14, 0.02), "gaugeFace")
				signFace(face, Vector2.new(260, 140), {
					{ text = "CHRONO", height = 0.34, colour = Color3.fromRGB(96, 108, 96) },
					{ text = prop.readout or "284 FPS", height = 0.6, colour = Color3.fromRGB(38, 54, 40), bold = true },
				})

			----------------------------------------------------------------
			-- PAINT & AIR bay
			----------------------------------------------------------------
			elseif kind == "paintCases" then
				-- Stacked cases of paint. Slightly out of square, because a
				-- perfectly aligned stack reads as a render.
				local rows = prop.rows or 3
				for i = 1, rows do
					local case = piece(
						Vector3.new(0, 0.13 + (i - 1) * 0.26, 0),
						Vector3.new(0.78, 0.26, 0.54),
						"paintCase"
					)
					case.CFrame = base
						* CFrame.new(Units.vectorToStuds(Vector3.new(0, 0.13 + (i - 1) * 0.26, 0)))
						* CFrame.Angles(0, math.rad((i % 2 == 0 and 4 or -3)), 0)
					piece(Vector3.new(0, 0.13 + (i - 1) * 0.26, 0.28), Vector3.new(0.3, 0.12, 0.01), "paper")
				end

			elseif kind == "podRack" then
				piece(Vector3.new(0, 0.3, -0.06), Vector3.new(0.9, 0.6, 0.05), "sheetMetal")
				for i = 1, prop.count or 8 do
					local x = ((i - 1) % 4 - 1.5) * 0.2
					local y = 0.16 + math.floor((i - 1) / 4) * 0.32
					tube(Vector3.new(x, y, 0.06), 0.28, 0.11,
						if (i + math.floor(i / 4)) % 2 == 0 then "podPlastic" else "podPlasticAlt", true)
					tube(Vector3.new(x, y + 0.16, 0.06), 0.03, 0.115, "maskShell", true)
				end

			elseif kind == "tankRow" then
				-- Air tanks standing in a row, same pattern as the airRack out
				-- on the apron.
				for i = 1, prop.count or 6 do
					local x = (i - (prop.count or 6) / 2 - 0.5) * 0.19
					tube(Vector3.new(x, 0.24, 0), 0.44, 0.14, if i % 3 == 0 then "brass" else "steelTank", true)
					tube(Vector3.new(x, 0.5, 0), 0.09, 0.07, "sheetMetal", true)
				end
				piece(Vector3.new(0, 0.02, 0), Vector3.new((prop.count or 6) * 0.19 + 0.1, 0.04, 0.24), "beam")

			elseif kind == "fillStation" then
				piece(Vector3.new(0, 0.45, 0), Vector3.new(0.4, 0.9, 0.3), "sheetMetalRust")
				local gauge = piece(Vector3.new(0, 0.76, 0.16), Vector3.new(0.2, 0.2, 0.02), "gaugeFace")
				signFace(gauge, Vector2.new(200, 200), {
					{ text = "FILL", height = 0.3, colour = Color3.fromRGB(110, 104, 96) },
					{ text = prop.readout or "3000", height = 0.44, colour = Color3.fromRGB(40, 46, 52), bold = true },
					{ text = "PSI", height = 0.24, colour = Color3.fromRGB(110, 104, 96) },
				})
				tube(Vector3.new(0.12, 0.2, 0.2), 0.5, 0.035, "maskShell")

			----------------------------------------------------------------
			-- PROTECTIVE bay
			----------------------------------------------------------------
			elseif kind == "maskShelf" then
				for i = 1, prop.count or 4 do
					local x = (i - (prop.count or 4) / 2 - 0.5) * 0.36
					piece(Vector3.new(x, 0.16, 0), Vector3.new(0.26, 0.3, 0.24), "maskShell")
					local lens = piece(Vector3.new(x, 0.18, 0.13), Vector3.new(0.24, 0.15, 0.04), "maskLens")
					lens.Reflectance = 0.28
					piece(Vector3.new(x, 0.3, -0.06), Vector3.new(0.2, 0.05, 0.14), "jerseyRed")
				end

			elseif kind == "jerseyRail" then
				tube(Vector3.new(0, 0.98, 0), prop.width or 1.9, 0.04, "sheetMetal")
				for i = 1, prop.count or 5 do
					local x = (i - (prop.count or 5) / 2 - 0.5) * ((prop.width or 1.9) / (prop.count or 5))
					local key = if i % 3 == 0 then "jerseyRed" elseif i % 3 == 1 then "jerseyBlue" else "jerseyOchre"
					piece(Vector3.new(x, 0.92, 0), Vector3.new(0.03, 0.1, 0.03), "sheetMetal")
					piece(Vector3.new(x, 0.62, 0), Vector3.new(0.34, 0.5, 0.1), key)
					piece(Vector3.new(x, 0.78, 0), Vector3.new(0.5, 0.14, 0.09), key)
				end

			elseif kind == "padStack" then
				for i = 1, prop.count or 4 do
					local pad = piece(
						Vector3.new(0, 0.05 + (i - 1) * 0.1, 0),
						Vector3.new(0.42, 0.1, 0.3),
						if i % 2 == 0 then "maskShell" else "beam"
					)
					pad.CFrame = base
						* CFrame.new(Units.vectorToStuds(Vector3.new(0, 0.05 + (i - 1) * 0.1, 0)))
						* CFrame.Angles(0, math.rad(i * 6 - 12), 0)
				end

			----------------------------------------------------------------
			-- Counter and wall dressing, stocked in every bay
			----------------------------------------------------------------
			elseif kind == "register" then
				piece(Vector3.new(0, 0.1, 0), Vector3.new(0.34, 0.2, 0.28), "maskShell")
				local screen = piece(Vector3.new(0, 0.26, -0.04), Vector3.new(0.3, 0.16, 0.03), "gaugeFace")
				screen.CFrame = base * CFrame.new(Units.vectorToStuds(Vector3.new(0, 0.26, -0.04)))
					* CFrame.Angles(math.rad(-18), 0, 0)
				piece(Vector3.new(0.24, 0.06, 0.02), Vector3.new(0.12, 0.12, 0.16), "beam")

			elseif kind == "squeegeeJar" then
				local jar = piece(Vector3.new(0, 0.11, 0), Vector3.new(0.16, 0.22, 0.16), "maskLens")
				jar.Transparency = 0.55
				jar.Reflectance = 0.1
				for i = 1, 5 do
					piece(Vector3.new((i - 3) * 0.03, 0.24, (i % 2) * 0.03), Vector3.new(0.02, 0.2, 0.02),
						if i % 2 == 0 then "podPlastic" else "podPlasticAlt")
				end

			elseif kind == "tapeRoll" then
				tube(Vector3.new(0, 0.04, 0), 0.05, 0.13, "maskShell", true)
				tube(Vector3.new(0, 0.04, 0), 0.055, 0.06, "paintCase", true)

			elseif kind == "coffeeCup" then
				tube(Vector3.new(0, 0.05, 0), 0.1, 0.08, "clockFace", true)
				tube(Vector3.new(0, 0.1, 0), 0.01, 0.082, "maskShell", true)

			elseif kind == "priceList" then
				local board = piece(Vector3.new(0, 0, 0), Vector3.new(prop.width or 1.5, prop.height or 1.0, 0.04), "chalkboard")
				local lines: { any } = { { text = prop.title or "TODAY", height = 0.22, colour = Color3.fromRGB(226, 220, 200), bold = true } }
				for _, line in ipairs(prop.lines or {}) do
					table.insert(lines, { text = line, height = 0.78 / math.max(1, #(prop.lines or {})), colour = Color3.fromRGB(196, 200, 186) })
				end
				signFace(board, Vector2.new(420, 300), lines)

			elseif kind == "corkboard" then
				piece(Vector3.new(0, 0, 0), Vector3.new(prop.width or 1.2, prop.height or 0.9, 0.04), "paintCase")
				for i = 1, prop.count or 5 do
					local flyer = piece(
						Vector3.new(((i - 1) % 3 - 1) * 0.34, (math.floor((i - 1) / 3) - 0.5) * 0.36, 0.03),
						Vector3.new(0.26, 0.3, 0.01),
						"paper"
					)
					flyer.CFrame = flyer.CFrame * CFrame.Angles(0, 0, math.rad((i % 3 - 1) * 5))
				end

			elseif kind == "wallClock" then
				tube(Vector3.new(0, 0, 0), 0.06, 0.36, "maskShell")
				local face = piece(Vector3.new(0, 0, 0.04), Vector3.new(0.3, 0.3, 0.02), "clockFace")
				signFace(face, Vector2.new(200, 200), {
					{ text = "", height = 0.3, colour = Color3.new() },
					{ text = "PARSONS", height = 0.26, colour = Color3.fromRGB(120, 104, 82) },
					{ text = "EST 1998", height = 0.2, colour = Color3.fromRGB(150, 136, 112) },
				})

			elseif kind == "aisleShelf" then
				--[[
					A free-standing aisle. Two uprights, boards between them, and
					stock on the boards -- the point is that the player walks
					BETWEEN things rather than along one wall, which is the
					difference between a shop and a diorama.

					Deliberately shallow: three boards, not six. A barn aisle you
					can see over is a shop; one you cannot is a warehouse.
				]]
				local length = prop.length or 3.2
				local shelves = prop.shelves or 3
				for _, side in ipairs({ -1, 1 }) do
					piece(Vector3.new(side * length / 2, 0.9, 0), Vector3.new(0.08, 1.8, 0.5), "sheetMetal")
				end
				for level = 1, shelves do
					local y = 0.30 + (level - 1) * 0.52
					piece(Vector3.new(0, y, 0), Vector3.new(length, 0.05, 0.5), "barnWoodDark")
					-- Stock, alternating so an aisle does not read as one product.
					local perShelf = prop.perShelf or 5
					for i = 1, perShelf do
						local x = (i - (perShelf + 1) / 2) * (length / (perShelf + 0.6))
						local tone = if (i + level) % 3 == 0 then "paintCase"
							elseif (i + level) % 3 == 1 then "podPlastic"
							else "podPlasticAlt"
						piece(Vector3.new(x, y + 0.17, 0), Vector3.new(0.22, 0.28, 0.3), tone)
					end
				end

			elseif kind == "roadSign" then
				--[[
					An actual road sign, because Marge did not commission
					signage -- she used what the county left behind. Real
					proportions: a u-channel post, a plate standing off it, and
					highway colours. A diamond is rotated 45 degrees, which is
					the whole reason a warning sign reads from distance.
				]]
				local face = prop.face or "guide"
				local width = prop.width or 1.5
				local height = prop.height or 0.75
				local top = prop.top or 2.4
				tube(Vector3.new(0, top / 2, 0), top, 0.07, "signSteel", true)
				local plateKey = if face == "warning" then "signYellow"
					elseif face == "stop" then "signRed"
					elseif face == "regulatory" then "signWhite"
					else "signGreen"
				local plate = piece(Vector3.new(0, top, 0.05), Vector3.new(width, height, 0.04), plateKey)
				if face == "warning" then
					plate.CFrame = plate.CFrame * CFrame.Angles(0, 0, math.rad(45))
				end
				local ink = if face == "warning" or face == "regulatory"
					then Color3.fromRGB(28, 28, 30)
					else Color3.fromRGB(236, 236, 230)
				local rows: { any } = {}
				for _, line in ipairs(prop.lines or { prop.text or "" }) do
					table.insert(rows, { text = line, height = 1 / math.max(1, #(prop.lines or { 1 })), colour = ink })
				end
				signFace(plate, Vector2.new(math.floor(width * 260), math.floor(height * 260)), rows)

			elseif kind == "fireExtinguisher" then
				tube(Vector3.new(0, 0.28, 0), 0.5, 0.16, "extinguisher", true)
				tube(Vector3.new(0, 0.56, 0), 0.08, 0.06, "sheetMetal", true)
				piece(Vector3.new(0, 0.5, 0.06), Vector3.new(0.14, 0.04, 0.1), "maskShell")
				piece(Vector3.new(0, 0.3, -0.1), Vector3.new(0.2, 0.06, 0.05), "sheetMetal")
			end
		end

		for _, prop in ipairs(bayCfg.shelfProps or {}) do
			if PROP_KINDS[prop.kind] then
				bayProp(prop)
			else
				log.warn(`bay '{bayCfg.id}' asks for prop kind '{prop.kind}', which has no builder`)
			end
		end

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "Browse"
		prompt.ActionText = `Browse {bayCfg.displayName}`
		prompt.ObjectText = cfg.name
		prompt.KeyboardKeyCode = Enum.KeyCode.F
		prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
		prompt.HoldDuration = 0.2
		prompt.MaxActivationDistance = Units.metresToStuds(5)
		prompt.RequiresLineOfSight = false
		prompt.Parent = counter

		bays[index] = {
			id = bayCfg.id,
			displayName = bayCfg.displayName,
			categories = bayCfg.categories,
			prompt = prompt,
			counter = counter,
			standPosition = worldStand,
		}
	end

	model.PrimaryPart = model:FindFirstChild("Floor") :: BasePart?
	model.Parent = parent

	log.info(`built the pole barn: {#bays} bays, {#model:GetChildren()} parts`)

	return {
		model = model,
		bays = bays,
		doorPosition = barnPosition + Vector3.new(0, 0, halfD + 2),
	}
end

return PoleBarn
