--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local CommerceCatalog = require(ReplicatedStorage.Shared.CommerceCatalog)
local Units = require(ReplicatedStorage.Shared.Units)

local FieldDetails = {}

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

function FieldDetails.build(mapName: string, parent: Instance): any
	local cfg = Config.get("venue")
	local map = Config.map(mapName)
	local presentation = Config.get("presentation")
	local look = map.presentation
	local halfW, halfL = map.bounds.widthMetres / 2, map.bounds.lengthMetres / 2
	local model = Instance.new("Model")
	model.Name = "FieldSupply"
	model.Parent = parent
	local function colour(key: string): Color3
		local rgb = cfg.palette[key]
		return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	end
	local function part(name: string, at: Vector3, size: Vector3, key: string, collide: boolean?): Part
		local p = Instance.new("Part")
		p.Name, p.Anchored = name, true
		p.Size, p.Position = Units.vectorToStuds(size), Units.vectorToStuds(at)
		p.Material, p.Color = Enum.Material.SmoothPlastic, colour(key)
		p.CanCollide = collide == true
		p.CanQuery = collide == true
		p.CanTouch = false
		p.CastShadow = collide == true
		p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
		p.Parent = model
		return p
	end
	local function sign(p: BasePart, text: string, face: Enum.NormalId)
		local surface = Instance.new("SurfaceGui")
		surface.Face = face
		surface.CanvasSize = Vector2.new(1000, 180)
		surface.LightInfluence = 0
		surface.AlwaysOnTop = false
		surface.MaxDistance = Units.metresToStuds(presentation.venue.signMaxDistanceMetres)
		surface.Parent = p
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextColor3 = colour("cream")
		label.TextScaled, label.TextWrapped = true, true
		label.Text = text
		label.Parent = surface
	end
	local offset = Vector3.new(0, 0, -halfL)
	local surroundings = part("SurroundingGround", Vector3.new(0, -0.55, -6), Vector3.new(halfW * 2 + 60, 1, halfL * 2 + 70), "teal", true)
	local groundRgb = Config.get("maps_index").palette[map.ground.colorKey]
	surroundings.Color = Color3.fromRGB(groundRgb[1], groundRgb[2], groundRgb[3])
	surroundings.Material = if map.ground.colorKey == "sand" then Enum.Material.Sand else Enum.Material.Grass
	local pieces: { [string]: Part } = {}
	for _, prop in ipairs(cfg.props) do
		pieces[prop[1]] = part(prop[1], vec(prop[2]) + offset, vec(prop[3]), prop[4], true)
	end
	for _, entry in ipairs(cfg.signs) do
		sign(pieces[entry[1]], entry[2], Enum.NormalId[entry[3]])
	end

	-- Turf bands and boundary paint are cosmetic: they never alter bot navigation.
	if look and look.groundStripes then
		for z = -halfL + cfg.field.stripeSpacing / 2, halfL, cfg.field.stripeSpacing do
			local stripe = part("MownTurf", Vector3.new(0, 0.006, z), Vector3.new(halfW * 2, 0.012, cfg.field.stripeSpacing / 2), "teal")
			local rgb = presentation.palette.turf
			stripe.Color, stripe.Material = Color3.fromRGB(rgb[1], rgb[2], rgb[3]), Enum.Material.Grass
		end
	end
	if look and look.boundaryLines then
		for _, x in ipairs({ -halfW + 0.7, halfW - 0.7 }) do
			part("Sideline", Vector3.new(x, 0.025, 0), Vector3.new(cfg.field.lineWidth, 0.025, halfL * 2 - 1.4), "cream")
		end
		for _, z in ipairs({ -halfL + 0.7, 0, halfL - 0.7 }) do
			part("FieldLine", Vector3.new(0, 0.026, z), Vector3.new(halfW * 2 - 1.4, 0.025, cfg.field.lineWidth), "cream")
		end
	end
	for _, x in ipairs({ -halfW - 0.2, halfW + 0.2 }) do
		for z = -halfL, halfL, cfg.field.postSpacing do
			part("NetPost", Vector3.new(x, map.walls.heightMetres / 2, z), Vector3.new(cfg.field.postWidth, map.walls.heightMetres, cfg.field.postWidth), "ink")
		end
		local banner = part("FieldBanner", Vector3.new(x, cfg.field.bannerHeight, 0), vec(cfg.field.bannerSize), "teal")
		banner.CFrame *= CFrame.Angles(0, math.pi / 2, 0)
		local bannerText = if look then look.banner else "LIVE ROUND / PLAY THE ANGLES"
		sign(banner, bannerText, Enum.NormalId.Front)
		sign(banner, bannerText, Enum.NormalId.Back)
		for _, z in ipairs({ -halfL + 3, halfL - 3 }) do
			part("FloodlightMast", Vector3.new(x, cfg.field.floodlightHeight / 2, z), Vector3.new(0.2, cfg.field.floodlightHeight, 0.2), "ink")
			local lamp = part("Floodlight", Vector3.new(x, cfg.field.floodlightHeight, z), Vector3.new(1.8, 0.5, 0.4), "cream")
			lamp.Material = Enum.Material.Neon
		end
	end

	-- Physical marker displays behind the counter.
	local markers = Config.get("markers")
	local display = presentation.venue
	local columns = math.min(display.displayColumns, #markers.order)
	local spacing = display.displayWidthMetres / columns
	for i, id in ipairs(markers.order) do
		local design = cfg.markerModels[id] or cfg.markerModels.mechanical
		local column, row = (i - 1) % columns, math.floor((i - 1) / columns)
		local at = offset + Vector3.new((column - (columns - 1) / 2) * spacing,
			display.displayBaseHeightMetres + row * display.displayRowHeightMetres, -21.3)
		local body = part("Display_" .. id, at, vec(design.body) * display.displayModelScale, "cream")
		body.Color = Color3.fromRGB(design.color[1], design.color[2], design.color[3])
		part("DisplayBarrel", at + Vector3.new(0.65, 0, 0), Vector3.new(design.barrel * display.displayModelScale, 0.09, 0.09), "ink")
		part("DisplayGrip", at + Vector3.new(-0.05, -0.28, 0), Vector3.new(0.14, 0.4, 0.16), "ink")
		local hopper = part("DisplayHopper", at + Vector3.new(0, 0.28, 0), Vector3.new(0.48, 0.3, 0.25), "ink")
		hopper.Shape = Enum.PartType.Ball
		local plaque = part("PriceTag", at + Vector3.new(0, -0.58, 0.1), vec(display.priceTagSizeMetres), "ink")
		local entry = markers.markers[id]
		local price = CommerceCatalog.shopCost(entry.cost)
		local priceText = if price == nil then "EARNED" elseif price == 0 then "FREE" else price .. " FF"
		sign(plaque, entry.displayName .. " / " .. priceText, Enum.NormalId.Back)
	end
	for i, id in ipairs({ "yellow", "pink", "cyan", "lime", "violet" }) do
		local tub = part("Paint_" .. id, offset + Vector3.new(-4 + i * 1.3, 1.65, -17.6), Vector3.new(0.65, 0.5, 0.65), "cream")
		local rgb = cfg.paintColors[id]
		tub.Color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	end
	local function prompt(name: string, position: any, text: string): Part
		local p = part(name, offset + vec(position), Vector3.new(1.3, 1.3, 0.15), "amber")
		sign(p, text, Enum.NormalId.Front)
		sign(p, text, Enum.NormalId.Back)
		local action = Instance.new("ProximityPrompt")
		action.Name = "Interact"
		action.ActionText, action.ObjectText = text, cfg.name
		action.KeyboardKeyCode = Enum.KeyCode[cfg.interactionKey]
		action.MaxActivationDistance = Units.metresToStuds(cfg.interactionRadiusMetres)
		action.HoldDuration = cfg.holdSeconds
		action.RequiresLineOfSight = false
		action.Parent = p
		return p
	end
	local exit = prompt("FieldExit", cfg.exitPosition, "LEAVE ROUND / SHOP")
	local enter = prompt("FieldEntrance", cfg.returnPosition, "ENTER FIELD")
	local counter = prompt("ShopCounter", cfg.counterPosition, "BROWSE SUPPLIES")
	return { model = model, exit = exit, enter = enter, counter = counter,
		spawn = offset + vec(cfg.shopSpawn), lookAt = offset + vec(cfg.shopLookAt) }
end

return FieldDetails
