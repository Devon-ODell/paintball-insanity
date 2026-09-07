--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Camos = require(ReplicatedStorage.Shared.Camos)
local Units = require(ReplicatedStorage.Shared.Units)

local ViewMarker = {}
local model: Model? = nil
local parts: { { part: Part, offset: CFrame, tint: string } } = {}
local markerColour = Color3.new()
local barrelColour = Color3.new()
local camoId = "factory"
local skinId = "raw"
local pulseAt = -math.huge
local kickAt = -math.huge
local animated = false

local function vector(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

local function colour(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function paint(alpha: number)
	local tuning = Config.get("markers").viewModel
	local camo = Camos.visual(camoId)
	local reactive = camo and camo.reactive == true
	local skin = tuning.skins[skinId]
	local base = if reactive then colour(camo.baseColor) elseif skin and skin.baseColor then colour(skin.baseColor) else markerColour
	local accent = if reactive then colour(camo.accentColor) elseif skin and skin.accentColor then colour(skin.accentColor) else colour(tuning.trimColor)
	local pulse = if reactive then colour(camo.pulseColor) else accent
	for _, item in ipairs(parts) do
		local part = item.part
		if item.tint == "body" then
			part.Color = base:Lerp(pulse, alpha * tuning.pulseBaseBlend)
		elseif item.tint == "accent" or item.tint == "camo" then
			part.Color = accent:Lerp(pulse, alpha * tuning.pulsePeakBlend)
			part.Material = if reactive and alpha > 0 then Enum.Material.Neon else Enum.Material.SmoothPlastic
			part.Transparency = if item.tint == "camo" and not reactive and skinId ~= "splitDust" then 1 else 0
		elseif item.tint == "barrel" then
			part.Color = barrelColour
		end
	end
end

function ViewMarker.setSkin(id: string?)
	skinId = if id and Config.get("markers").viewModel.skins[id] then id else "raw"
	paint(0)
end

function ViewMarker.setCamo(id: string?)
	camoId = if id and Camos.visual(id) then id else Config.get("camos").default
	pulseAt = -math.huge
	animated = false
	paint(0)
end

function ViewMarker.equip(id: string, camo: string?)
	if model then model:Destroy() end
	table.clear(parts)
	local assembly = Instance.new("Model")
	assembly.Name = "LocalPaintballMarker"
	model = assembly
	local markerData = Config.get("markers")
	local marker = markerData.markers[id] or markerData.markers.mechanical
	local tuning = markerData.viewModel
	local models = Config.get("venue").markerModels
	local spec = marker.model or models[id] or models[marker.archetype] or models.mechanical
	markerColour = colour(if marker.cosmetic then marker.cosmetic.bodyColour else spec.color)
	barrelColour = colour(if marker.cosmetic then marker.cosmetic.barrelColour else tuning.darkColor)
	local dark = colour(tuning.darkColor)
	local trim = colour(tuning.trimColor)

	local function piece(name: string, size: Vector3, at: Vector3, tint: string, shape: string?, rotation: CFrame?)
		local part = Instance.new("Part")
		part.Name, part.Size = name, Units.vectorToStuds(size)
		part.Color = if tint == "body" then markerColour elseif tint == "metal" then trim else dark
		part.Material = if tint == "metal" or tint == "barrel" then Enum.Material.Metal else Enum.Material.SmoothPlastic
		part.Reflectance = if tint == "metal" or marker.cosmetic then tuning.reflectance else 0
		part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch, part.CastShadow = true, false, false, false, false
		if shape == "Ball" then part.Shape = Enum.PartType.Ball
		elseif shape == "Cylinder" then part.Shape = Enum.PartType.Cylinder end
		part.Parent = assembly
		table.insert(parts, {
			part = part,
			offset = CFrame.new(Units.vectorToStuds(at)) * (rotation or CFrame.identity),
			tint = tint,
		})
	end
	piece("Receiver", vector(spec.body), Vector3.zero, "body")
	piece("Barrel", Vector3.new(spec.barrel, tuning.barrelDiameterMetres, tuning.barrelDiameterMetres),
		Vector3.new(0, tuning.barrelHeightMetres, -spec.barrel / 2 - spec.body[3] / 2), "barrel", "Cylinder", CFrame.Angles(0, math.pi / 2, 0))
	for _, part in ipairs(tuning.pieces) do
		local at = vector(part.at)
		if part.colour == "accent" then
			at = Vector3.new(math.sign(at.X) * (spec.body[1] / 2 + part.size[1] / 2), at.Y, at.Z)
		end
		piece(part.name, vector(part.size), at, part.colour, part.shape)
	end
	for index, panel in ipairs(tuning.camoPanels) do
		local at = vector(panel.at)
		at = Vector3.new(math.sign(at.X) * (spec.body[1] / 2 + panel.size[1] / 2), at.Y, at.Z)
		piece(`CamoPanel{index}`, vector(panel.size), at, "camo", nil, CFrame.Angles(math.rad(panel.rotationDeg), 0, 0))
	end
	ViewMarker.setCamo(camo)
end

-- Called only for confirmed server headshots by the client controller. The
-- light is purely local; it does not change spread or illuminate the field.
function ViewMarker.reactHeadshot()
	local camo = Camos.visual(camoId)
	if camo and camo.reactive then
		pulseAt = os.clock()
		animated = true
	end
end

function ViewMarker.fire()
	kickAt = os.clock()
end

function ViewMarker.step(camera: Camera, visible: boolean)
	if not model then return end
	local parent = if visible then camera else nil
	if model.Parent ~= parent then model.Parent = parent end
	if not visible then return end
	local tuning = Config.get("markers").viewModel
	local now = os.clock()
	local kick = math.clamp(1 - (now - kickAt) / tuning.kickSeconds, 0, 1)
	local at = camera.CFrame * CFrame.new(vector(tuning.offsetStuds))
		* CFrame.new(0, 0, kick * tuning.kickBackStuds)
		* CFrame.Angles(math.rad(kick * tuning.kickDegrees), 0, 0)
	for _, item in ipairs(parts) do item.part.CFrame = at * item.offset end
	if animated then
		local elapsed = now - pulseAt
		local fade = math.clamp(1 - elapsed / tuning.pulseSeconds, 0, 1)
		paint(fade * (1 + math.cos(elapsed * tuning.pulseFrequencyHz * math.pi * 2)) / 2)
		if fade <= 0 then animated = false end
	end
end

return ViewMarker
