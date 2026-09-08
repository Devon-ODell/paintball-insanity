--!strict
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS.Shared.Config)
local Units = require(RS.Shared.Units)
local YardProps = {}

local function vec(a: { number }): Vector3
	return Vector3.new(a[1], a[2], a[3])
end

function YardProps.handles(kind: string): boolean
	return Config.get("yardProps").models[kind] ~= nil
end

function YardProps.build(kind: string, base: CFrame, palette: { [string]: Color3 }, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = kind
	for _, entry in ipairs(Config.get("yardProps").models[kind]) do
		local part = Instance.new("Part")
		part.Name = entry.name
		part.Size = Units.vectorToStuds(vec(entry.size))
		local r = if entry.rotation then vec(entry.rotation) else Vector3.zero
		part.CFrame = base * CFrame.new(Units.vectorToStuds(vec(entry.at)))
			* CFrame.Angles(math.rad(r.X), math.rad(r.Y), math.rad(r.Z))
		part.Shape = if entry.shape == "Cylinder" then Enum.PartType.Cylinder else Enum.PartType.Block
		part.Color = palette[entry.colorKey]
		part.Material = if entry.colorKey == "barnWood" or entry.colorKey == "barnWoodDark" then Enum.Material.Wood
			elseif entry.colorKey == "tarp" then Enum.Material.Fabric else Enum.Material.Metal
		part.Anchored, part.CanTouch = true, false
		part.CanCollide, part.CanQuery = entry.collide == true, entry.collide == true
		part.CastShadow = entry.shadow == true
		part.Parent = model
	end
	model.Parent = parent
	return model
end

return YardProps
