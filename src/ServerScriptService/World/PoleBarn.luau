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
local Units = require(ReplicatedStorage.Shared.Units)
local Log = require(ReplicatedStorage.Shared.Log)

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
	sheetMetal = Enum.Material.CorrodedMetal,
	sheetMetalRust = Enum.Material.CorrodedMetal,
	gravel = Enum.Material.Pebble,
	tarp = Enum.Material.Fabric,
	signBoard = Enum.Material.SmoothPlastic,
	signPost = Enum.Material.Wood,
	brass = Enum.Material.Metal,
	lantern = Enum.Material.Neon,
}

--------------------------------------------------------------------------------

--- Builds the barn. `palette` is the overworld palette; `origin` is the barn's
--- world CFrame, so everything below is authored in barn-local metres.
function PoleBarn.build(cfg: any, palette: { [string]: Color3 }, parent: Instance): Barn
	local model = Instance.new("Model")
	model.Name = "PoleBarn"

	local function colour(key: string): Color3
		return palette[key] or Color3.fromRGB(160, 160, 160)
	end

	local origin = CFrame.new(Units.vectorToStuds(Vector3.new(cfg.position[1], cfg.position[2], cfg.position[3])))
		* CFrame.Angles(0, math.rad(cfg.rotationY or 0), 0)

	--- Places a box in barn-local metres. Sizes are metres; the studs conversion
	--- happens here so no call site below ever has to think about it.
	local function slab(name: string, at: Vector3, size: Vector3, key: string, collide: boolean?): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = Units.vectorToStuds(size)
		p.CFrame = origin * CFrame.new(Units.vectorToStuds(at))
		p.Color = colour(key)
		p.Material = MATERIAL[key] or Enum.Material.SmoothPlastic
		p.Anchored = true
		p.CanCollide = collide ~= false
		p.CanQuery = collide ~= false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = model
		return p
	end

	local function rotated(name: string, at: Vector3, size: Vector3, key: string, rollRadians: number, collide: boolean?): Part
		local p = slab(name, at, size, key, collide)
		p.CFrame = origin * CFrame.new(Units.vectorToStuds(at)) * CFrame.Angles(rollRadians, 0, 0)
		return p
	end

	local halfW = cfg.widthMetres / 2
	local halfD = cfg.depthMetres / 2
	local wallH = cfg.wallHeightMetres
	local rise = cfg.roofRiseMetres

	----------------------------------------------------------------------------
	-- Slab and posts
	----------------------------------------------------------------------------

	slab("Slab", Vector3.new(0, -0.08, 0), Vector3.new(cfg.widthMetres + 1.6, 0.16, cfg.depthMetres + 1.6), "gravel")
	slab("Floor", Vector3.new(0, 0.02, 0), Vector3.new(cfg.widthMetres, 0.1, cfg.depthMetres), "barnWoodDark")

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

	local slopeLength = math.sqrt(halfD * halfD + rise * rise)
	local pitch = math.atan2(rise, halfD)

	for _, side in ipairs({ -1, 1 }) do
		local sheet = rotated(
			`Roof_{side}`,
			Vector3.new(0, wallH + rise / 2, side * (halfD / 2)),
			Vector3.new(cfg.widthMetres + 1.4, 0.16, slopeLength),
			"sheetMetal",
			true
		)
		sheet.CFrame = origin
			* CFrame.new(Units.vectorToStuds(Vector3.new(0, wallH + rise / 2, side * (halfD / 2))))
			* CFrame.Angles(side * -pitch, 0, 0)
	end

	slab("RidgeCap", Vector3.new(0, wallH + rise + 0.08, 0), Vector3.new(cfg.widthMetres + 1.5, 0.18, 0.5), "sheetMetalRust", false)

	-- Rafters and the ridge beam, left visible from inside.
	slab("RidgeBeam", Vector3.new(0, wallH + rise - 0.25, 0), Vector3.new(cfg.widthMetres, 0.3, 0.26), "beam", false)
	for i = 0, postCount do
		local x = -halfW + i * (cfg.widthMetres / postCount)
		for _, side in ipairs({ -1, 1 }) do
			local rafter = slab(
				`Rafter_{i}_{side}`,
				Vector3.new(x, wallH + rise / 2, side * (halfD / 2)),
				Vector3.new(0.16, 0.26, slopeLength),
				"beam",
				false
			)
			rafter.CFrame = origin
				* CFrame.new(Units.vectorToStuds(Vector3.new(x, wallH + rise / 2 - 0.2, side * (halfD / 2))))
				* CFrame.Angles(side * -pitch, 0, 0)
		end
		-- Collar tie across the span.
		slab(`Tie_{i}`, Vector3.new(x, wallH + rise * 0.42, 0), Vector3.new(0.14, 0.2, cfg.depthMetres * 0.55), "beam", false)
	end

	----------------------------------------------------------------------------
	-- Signage
	----------------------------------------------------------------------------

	local fascia = slab("Fascia", Vector3.new(0, wallH + rise * 0.52, halfD + 0.35), Vector3.new(cfg.widthMetres * 0.62, 2.4, 0.2), "signBoard")
	do
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Front
		gui.CanvasSize = Vector2.new(1400, 240)
		gui.LightInfluence = 0.15
		gui.Parent = fascia

		local title = Instance.new("TextLabel")
		title.Size = UDim2.fromScale(1, 0.62)
		title.BackgroundTransparency = 1
		title.Font = Enum.Font.GothamBold
		title.TextColor3 = Color3.fromRGB(46, 36, 26)
		title.TextScaled = true
		title.Text = cfg.name
		title.Parent = gui

		local sub = Instance.new("TextLabel")
		sub.Size = UDim2.fromScale(1, 0.34)
		sub.Position = UDim2.fromScale(0, 0.64)
		sub.BackgroundTransparency = 1
		sub.Font = Enum.Font.GothamMedium
		sub.TextColor3 = Color3.fromRGB(96, 76, 56)
		sub.TextScaled = true
		sub.Text = cfg.subtitle
		sub.Parent = gui
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

		-- Shelving behind it.
		for shelf = 1, 3 do
			slab(
				`Shelf_{bayCfg.id}_{shelf}`,
				Vector3.new(localX, 1.5 + shelf * 0.95, backZ - 1.0),
				Vector3.new(9.0, 0.09, 0.6),
				"barnWood",
				false
			)
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
		local sign = slab(`BaySign_{bayCfg.id}`, Vector3.new(localX, 4.6, backZ - 1.18), Vector3.new(7.4, 1.5, 0.1), "signBoard", false)
		do
			local gui = Instance.new("SurfaceGui")
			gui.Face = Enum.NormalId.Front
			gui.CanvasSize = Vector2.new(900, 190)
			gui.LightInfluence = 0.2
			gui.Parent = sign

			local title = Instance.new("TextLabel")
			title.Size = UDim2.fromScale(1, 0.56)
			title.BackgroundTransparency = 1
			title.Font = Enum.Font.GothamBold
			title.TextColor3 = Color3.fromRGB(42, 34, 26)
			title.TextScaled = true
			title.Text = bayCfg.displayName
			title.Parent = gui

			local blurb = Instance.new("TextLabel")
			blurb.Size = UDim2.fromScale(1, 0.4)
			blurb.Position = UDim2.fromScale(0, 0.58)
			blurb.BackgroundTransparency = 1
			blurb.Font = Enum.Font.Gotham
			blurb.TextColor3 = Color3.fromRGB(104, 84, 62)
			blurb.TextScaled = true
			blurb.TextWrapped = true
			blurb.Text = bayCfg.blurb
			blurb.Parent = gui
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
