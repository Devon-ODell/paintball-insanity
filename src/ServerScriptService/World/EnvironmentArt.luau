--!strict
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS.Shared.Config)
local Units = require(RS.Shared.Units)
local assets = script.Parent.ArtAssets
local EnvironmentArt = {}

-- Preserve authored proportions and UVs. Fit uniformly inside the footprint
-- the placement system already reserved, then ground the normalized template.
function EnvironmentArt.append(name: string, parent: Instance, height: number, width: number, castsShadow: boolean): { BasePart }
	local template = assert(assets:FindFirstChild(name), `Missing environment art {name}`)
	local source = template:GetAttribute("SourceSize") :: Vector3
	local scale = math.min(Units.metresToStuds(height) / source.Y, Units.metresToStuds(width) / math.sqrt(source.X * source.X + source.Z * source.Z))
	assert(scale > 0 and scale < math.huge, "environment art must fit a finite positive footprint")
	local parts: { BasePart } = {}
	for _, original in ipairs(template:GetChildren()) do
		if original:IsA("MeshPart") then
			local part = original:Clone()
			part.Size = original.Size * scale
			part.CFrame = CFrame.new(original.CFrame.Position * scale) * original.CFrame.Rotation
			part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch = true, false, false, false
			part.CastShadow = castsShadow
			part:SetAttribute("EnvironmentArt", name)
			local foliage = string.find(string.lower(part.Name), "lea") ~= nil or name == "Fern" or name == "FernTall"
			if foliage then
				part:AddTag("LR_WindFoliage")
			end
			part.Parent = parent
			table.insert(parts, part)
		end
	end
	return parts
end

function EnvironmentArt.plant(kind: string, parent: Instance, rng: any, layer: any, footprint: number, nearPaths: boolean): boolean
	local cfg = Config.get("environmentArt")
	local variants = cfg.variants[kind]
	if not variants then return false end
	local name = variants[rng:nextInt(1, #variants)]
	if kind == "tree" and not nearPaths then name = "RedwoodDistant" end
	local height = rng:nextRange(layer.heightMetres[1], layer.heightMetres[2])
	local leanAllowance = math.sin(math.rad(layer.leanDegrees or 0)) * layer.heightMetres[2]
	-- Scale the footprint with sampled height too. A fixed width clamp would
	-- collapse most of the height range into identical trees and ferns.
	local width = math.max(0, (footprint - leanAllowance) * 2) * height / layer.heightMetres[2]
	if kind == "fallenLog" then
		width = height
		-- This layer's height is the log length, not its standing height.
	end
	local meshes = EnvironmentArt.append(name, parent, height, width, nearPaths and (kind == "tree" or kind == "broadleaf" or kind == "rock" or kind == "fallenLog"))
	if kind == "tree" or kind == "broadleaf" then
		local top = 0
		for _, part in ipairs(meshes) do top = math.max(top, part.CFrame.Position.Y + part.Size.Y / 2) end
		local fittedHeight = Units.studsToMetres(top)
		local diameter = rng:nextRange(layer.trunkDiameterMetres[1], layer.trunkDiameterMetres[2])
		local hull = Instance.new("Part")
		hull.Name = "TrunkCollision"
		hull.Shape = Enum.PartType.Cylinder
		hull.Size = Units.vectorToStuds(Vector3.new(fittedHeight * cfg.colliderHeightFraction, diameter, diameter))
		hull.CFrame = CFrame.new(0, hull.Size.X / 2, 0) * CFrame.Angles(0, 0, math.pi / 2)
		hull.Anchored, hull.CanCollide, hull.CanQuery, hull.CanTouch = true, true, true, false
		hull.Transparency, hull.CastShadow = 1, false
		hull.Parent = parent
	elseif kind == "moss" then
		for _, part in ipairs(meshes) do
			part.CFrame += Vector3.new(0, Units.metresToStuds(cfg.groundOffsetMetres), 0)
		end
	end
	return true
end

return EnvironmentArt
