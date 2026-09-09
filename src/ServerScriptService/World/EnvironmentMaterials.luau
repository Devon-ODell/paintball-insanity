--!strict
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS.Shared.Config)
local MaterialService = game:GetService("MaterialService")
local EnvironmentMaterials = {}

function EnvironmentMaterials.install()
	local cfg = Config.get("environmentArt")
	for _, source in ipairs(script.Parent.ArtAssets.Materials:GetChildren()) do
		if not MaterialService:FindFirstChild(source.Name) then
			local material = source:Clone()
			material.StudsPerTile = cfg.materialTileStuds[source.Name] or material.StudsPerTile
			material.Parent = MaterialService
		end
	end
end

function EnvironmentMaterials.apply(part: BasePart, key: string)
	local cfg = Config.get("environmentArt")
	local name = cfg.materials[key]
	if not name then return end
	local material = MaterialService:FindFirstChild(name) :: MaterialVariant?
	if not material then return end
	part.Material = material.BaseMaterial
	part.MaterialVariant = name
	-- The texture already contains albedo; the old solid-colour palette would
	-- multiply it down twice. Retain palette variation with a lighter tint.
	part.Color = part.Color:Lerp(Color3.new(1, 1, 1), cfg.materialTintLift)
end

return EnvironmentMaterials
