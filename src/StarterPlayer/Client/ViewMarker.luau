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
	--[[
		Cosmetic variants (the yard colourways) carry their own `model` block,
		which sets dimensions and colour but no archetype hardware. Keep the
		archetype spec alongside so a teal mechanical still wears a bolt handle.
	]]
	local archetypeSpec = models[marker.archetype] or models.mechanical
	local spec = marker.model or models[id] or archetypeSpec
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
	--- A piece's own rotation, declared in degrees in the data. This is what
	--- lets a cylinder lie along Z (an air tank) or stand along Y (a hopper)
	--- instead of every round thing having to be a sphere.
	local function rotationOf(entry: any): CFrame?
		local r = entry.rotationDeg
		if not r then
			return nil
		end
		return CFrame.Angles(math.rad(r[1]), math.rad(r[2]), math.rad(r[3]))
	end

	piece("Receiver", vector(spec.body), Vector3.zero, "body")

	--[[
		The barrel, in three parts rather than one smooth tube.

		A single cylinder reads as a length of pipe. What makes a muzzle look
		like hardware is the step up to a ported shroud and a bore you can see
		into -- and the muzzle is the part of this model the player stares at for
		the whole match, so it is worth the four extra parts.
	]]
	local axis = CFrame.Angles(0, math.pi / 2, 0)
	local dia = tuning.barrelDiameterMetres
	local barrelY = tuning.barrelHeightMetres
	local barrelBase = spec.body[3] / 2
	local shroudLength = math.min(tuning.muzzleShroudMetres, spec.barrel * 0.4)
	local rearLength = spec.barrel - shroudLength

	piece("Barrel", Vector3.new(rearLength, dia, dia),
		Vector3.new(0, barrelY, -barrelBase - rearLength / 2), "barrel", "Cylinder", axis)

	local shroudDia = dia * tuning.shroudDiameterScale
	local shroudZ = -barrelBase - rearLength - shroudLength / 2
	piece("MuzzleShroud", Vector3.new(shroudLength, shroudDia, shroudDia),
		Vector3.new(0, barrelY, shroudZ), "metal", "Cylinder", axis)

	-- Porting: slots cut across the top of the shroud, which is where a real
	-- ported barrel vents.
	local port = vector(tuning.portSizeMetres)
	for i = 1, tuning.portCount do
		local along = (i - (tuning.portCount + 1) / 2) * (shroudLength / (tuning.portCount + 1))
		piece(`Port{i}`, port, Vector3.new(0, barrelY + shroudDia * 0.34, shroudZ + along), "dark")
	end

	-- The bore. Inset at the muzzle face so the barrel reads as open.
	piece("Bore", Vector3.new(tuning.boreDepthMetres, dia * 0.6, dia * 0.6),
		Vector3.new(0, barrelY, -barrelBase - spec.barrel + tuning.boreDepthMetres / 2), "dark", "Cylinder", axis)

	--[[
		Shared hardware first, then whatever this archetype adds on top. `hide`
		lets an archetype drop a shared piece it has no business wearing -- the
		squared electronic body does not carry the stack tube's valve cap.
	]]
	local hidden: { [string]: boolean } = {}
	for _, name in ipairs(spec.hide or archetypeSpec.hide or {}) do
		hidden[name] = true
	end
	for _, part in ipairs(tuning.pieces) do
		if not hidden[part.name] then
			local at = vector(part.at)
			if part.colour == "accent" then
				at = Vector3.new(math.sign(at.X) * (spec.body[1] / 2 + part.size[1] / 2), at.Y, at.Z)
			end
			piece(part.name, vector(part.size), at, part.colour, part.shape, rotationOf(part))
		end
	end
	for _, part in ipairs(spec.pieces or archetypeSpec.pieces or {}) do
		piece(part.name, vector(part.size), vector(part.at), part.colour, part.shape, rotationOf(part))
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
	--[[
		`offsetStuds` is in STUDS. Everything else in this module is metres run
		through Units.vectorToStuds; this one is applied raw to the camera CFrame,
		which is why it reads small next to the part sizes. Do not "fix" it by
		converting -- retune it, and read the note in markers.json beside it.
	]]
	local tilt = vector(tuning.tiltDegrees)
	local at = camera.CFrame * CFrame.new(vector(tuning.offsetStuds))
		* CFrame.Angles(math.rad(tilt.Y), math.rad(tilt.Z), math.rad(tilt.X))
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
