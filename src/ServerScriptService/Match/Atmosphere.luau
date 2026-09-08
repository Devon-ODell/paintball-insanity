--!strict
--[[
	Atmosphere -- the look, applied per map, entirely from code.

	Nothing in this file changes what the game IS: no geometry, no visibility, no
	ballistics. It changes how it reads. Three things do most of the work:

	  * Future lighting technology, for real shadows and light bounce off the
	    saturated bunkers instead of flat ambient fill.
	  * Atmosphere density and haze, which is what makes distance legible. A 70 m
	    sightline in Woods has to LOOK like 70 m or the player has no way to
	    judge the holdover it needs -- so the haze is a gameplay affordance
	    dressed as an art choice.
	  * A little bloom and reflectance, which is what sells the inflatables as
	    pressurised vinyl rather than coloured boxes.

	All values come from Data/maps_index.json. Nothing numeric is hardcoded here.
]]

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.scope("LiveRound.World")

local Atmosphere = {}

local MANAGED_NAME = "LiveRoundLook"

local function colour(rgb: { number }?): Color3?
	if not rgb then
		return nil
	end
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

--- Shallow merge of a per-map override onto the default block. Nested tables
--- (atmosphere, bloom, ...) merge one level deeper so a map can tweak haze
--- without restating the whole atmosphere.
local function merge(base: any, override: any?): any
	local out: any = {}
	for key, value in pairs(base) do
		out[key] = value
	end
	if not override then
		return out
	end
	for key, value in pairs(override) do
		if type(value) == "table" and type(out[key]) == "table" and not value[1] then
			local nested: any = {}
			for k, v in pairs(out[key]) do
				nested[k] = v
			end
			for k, v in pairs(value) do
				nested[k] = v
			end
			out[key] = nested
		else
			out[key] = value
		end
	end
	return out
end

local function ensure(className: string, name: string): Instance
	local existing = Lighting:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local created = Instance.new(className)
	created.Name = name
	created:SetAttribute(MANAGED_NAME, true)
	created.Parent = Lighting
	return created
end

--[[
	Volumetric clouds.

	The single largest thing that can be done to a Roblox sky without uploading
	an asset. Without them the sky above a field is a flat gradient, and a flat
	gradient is what makes an outdoor scene read as a screensaver -- there is
	nothing up there to give the light a source or the horizon a scale.

	Clouds must be parented to Terrain, not Lighting, which is the one thing
	about them that is easy to get wrong; a Clouds under Lighting silently does
	nothing. Guarded because the headless harness has no Terrain and this is a
	look, never a requirement.
]]
local function applyClouds(cfg: any)
	local ok = pcall(function()
		local terrain = Workspace:FindFirstChildOfClass("Terrain")
		if not terrain then
			return
		end
		local existing = terrain:FindFirstChild("LiveRoundClouds")
		if cfg == nil or cfg.enabled == false then
			if existing then
				existing:Destroy()
			end
			return
		end
		local clouds = existing
		if not clouds or not clouds:IsA("Clouds") then
			if clouds then
				clouds:Destroy()
			end
			clouds = Instance.new("Clouds")
			clouds.Name = "LiveRoundClouds"
			clouds:SetAttribute(MANAGED_NAME, true)
			clouds.Parent = terrain
		end
		local sky = clouds :: Clouds
		sky.Cover = cfg.cover
		sky.Density = cfg.density
		sky.Color = colour(cfg.color) :: Color3
		sky.Enabled = true
	end)
	if not ok then
		log.info("clouds unavailable in this context; sky falls back to the gradient")
	end
end

--[[
	Opts into the current material set once.

	Roblox shipped a second generation of built-in materials with real physical
	response -- concrete that is rough, metal that is not plastic with a shine.
	An experience created before that keeps the legacy set unless it asks, and
	every surface in this game is a built-in material, so this is the cheapest
	visual upgrade available: no asset, no part, no tuning.
]]
local materialsUpgraded = false
local function useCurrentMaterials()
	if materialsUpgraded then
		return
	end
	materialsUpgraded = true
	local ok = pcall(function()
		local service = game:GetService("MaterialService")
		if service.Use2022Materials ~= true then
			service.Use2022Materials = true
		end
	end)
	if not ok then
		log.info("material generation is not settable here; using whatever the place has")
	end
end

--[[
	Applies a map's look. Safe to call repeatedly; it reuses the instances it
	created last time rather than stacking effects.
]]
function Atmosphere.apply(mapName: string?)
	local root = Config.require("maps_index", "lighting")
	Atmosphere.applyProfile(merge(root.default, if mapName then root.perMap[mapName] else nil), mapName or "default")
end

--[[
	Applies a complete lighting block directly.

	The hub is not a map and has no entry in maps_index, but it needs the same
	treatment -- more so, since its whole job is atmosphere. This is the seam
	that lets Overworld hand in its own profile without pretending to be a field.
]]
function Atmosphere.applyProfile(cfg: any, label: string)
	local ok = pcall(function()
		Lighting.Technology = Enum.Technology[cfg.technology]
	end)
	if not ok then
		-- Technology is not assignable at runtime in every context; the project
		-- file sets it too, so this is a best-effort upgrade rather than a
		-- requirement.
		log.info("lighting technology is set from default.project.json, not at runtime")
	end

	Lighting.Brightness = cfg.brightness
	Lighting.ExposureCompensation = cfg.exposureCompensation
	Lighting.GlobalShadows = cfg.globalShadows
	Lighting.ShadowSoftness = cfg.shadowSoftness
	Lighting.EnvironmentDiffuseScale = cfg.environmentDiffuseScale
	Lighting.EnvironmentSpecularScale = cfg.environmentSpecularScale
	Lighting.Ambient = colour(cfg.ambient) :: Color3
	Lighting.OutdoorAmbient = colour(cfg.outdoorAmbient) :: Color3
	Lighting.ColorShift_Top = colour(cfg.colorShiftTop) :: Color3
	Lighting.ColorShift_Bottom = colour(cfg.colorShiftBottom) :: Color3
	Lighting.ClockTime = cfg.clockTime
	Lighting.GeographicLatitude = cfg.geographicLatitude

	local atmosphere = ensure("Atmosphere", "LiveRoundAtmosphere") :: Atmosphere
	atmosphere.Density = cfg.atmosphere.density
	atmosphere.Offset = cfg.atmosphere.offset
	atmosphere.Color = colour(cfg.atmosphere.color) :: Color3
	atmosphere.Decay = colour(cfg.atmosphere.decay) :: Color3
	atmosphere.Glare = cfg.atmosphere.glare
	atmosphere.Haze = cfg.atmosphere.haze

	local bloom = ensure("BloomEffect", "LiveRoundBloom") :: BloomEffect
	bloom.Intensity = cfg.bloom.intensity
	bloom.Size = cfg.bloom.size
	bloom.Threshold = cfg.bloom.threshold
	bloom.Enabled = cfg.bloom.intensity > 0

	local rays = ensure("SunRaysEffect", "LiveRoundSunRays") :: SunRaysEffect
	rays.Intensity = cfg.sunRays.intensity
	rays.Spread = cfg.sunRays.spread
	rays.Enabled = cfg.sunRays.intensity > 0

	local correction = ensure("ColorCorrectionEffect", "LiveRoundColor") :: ColorCorrectionEffect
	correction.Brightness = cfg.colorCorrection.brightness or 0
	correction.Contrast = cfg.colorCorrection.contrast
	correction.Saturation = cfg.colorCorrection.saturation
	correction.TintColor = colour(cfg.colorCorrection.tintColor) :: Color3

	--[[
		Match profiles disable depth of field so distant masks stay sharp.
		The hub can retain its soft focus; switch the effect off entirely when
		both intensities are zero instead of leaving a redundant render pass.
	]]
	local dof = ensure("DepthOfFieldEffect", "LiveRoundDof") :: DepthOfFieldEffect
	dof.FarIntensity = cfg.depthOfField.farIntensity
	dof.FocusDistance = cfg.depthOfField.focusDistance
	dof.InFocusRadius = cfg.depthOfField.inFocusRadius
	dof.NearIntensity = cfg.depthOfField.nearIntensity or 0
	dof.Enabled = dof.FarIntensity > 0 or dof.NearIntensity > 0

	applyClouds(cfg.clouds)
	useCurrentMaterials()

	log.info(`applied look for {label}`)
end

--- Removes everything this module created. Used when tearing a map down.
function Atmosphere.clear()
	for _, child in ipairs(Lighting:GetChildren()) do
		if child:GetAttribute(MANAGED_NAME) then
			child:Destroy()
		end
	end
	-- Clouds live under Terrain rather than Lighting, so the loop above cannot
	-- see them and a torn-down map would keep the previous field's sky.
	pcall(function()
		local terrain = Workspace:FindFirstChildOfClass("Terrain")
		local clouds = terrain and terrain:FindFirstChild("LiveRoundClouds")
		if clouds then
			clouds:Destroy()
		end
	end)
end

return Atmosphere
