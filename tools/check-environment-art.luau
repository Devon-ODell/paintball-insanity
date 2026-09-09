--!strict
-- Structural/physics verification. Asset delivery and pixels require Studio.
local r = require("@lune/roblox")
local env = require("./Harness").build()
local art = env.require(env.Server.World.EnvironmentArt)
local materials = env.require(env.Server.World.EnvironmentMaterials)
local Units = env.require(env.Shared.Units)
local Config = env.require(env.Shared.Config)
local allowed = { Model = true, MeshPart = true, SurfaceAppearance = true, Folder = true, MaterialVariant = true }
local names = { "Redwood", "RedwoodDistant", "Beech", "Sapling", "Fern", "FernTall", "Rock", "MossRock", "FallenLog", "LeafLitter" }
local count = 0
for _, name in ipairs(names) do
	local template = env.Server.World.ArtAssets[name]
	assert(template:GetAttribute("SourceAssetId") == "6432306802", name .. ": lost provenance")
	for _, node in ipairs(template:GetDescendants()) do
		assert(allowed[node.ClassName], name .. ": unexpected imported class " .. node.ClassName)
		if node:IsA("MeshPart") then
			local xml = r.serializeModel({ node }, true)
			assert(xml:find('name="MeshContent"') and xml:find("rbxassetid://"), name .. ": missing mesh reference")
			assert(node:FindFirstChildOfClass("SurfaceAppearance"), name .. ": missing PBR surface")
			assert(node.RenderFidelity == r.Enum.RenderFidelity.Automatic, name .. ": lost automatic mesh LOD")
		end
	end
	local parent = r.Instance.new("Model")
	local parts = art.append(name, parent, 8, 5, false)
	assert(#parts >= 1 and #parts <= 3, name .. ": unbounded part cost")
	local minimumY = math.huge
	for _, part in ipairs(parts) do
		assert(part.Anchored and not part.CanCollide and not part.CanQuery and not part.CanTouch and not part.CastShadow)
		for _, x in ipairs({ -1, 1 }) do
			for _, y in ipairs({ -1, 1 }) do
				for _, z in ipairs({ -1, 1 }) do
					local p = Units.vectorToMetres(part.CFrame:PointToWorldSpace(part.Size * r.Vector3.new(x, y, z) / 2))
					minimumY = math.min(minimumY, p.Y)
					assert(p.Y >= -0.0001 and p.Y <= 8.0001, name .. ": exceeded vertical envelope")
					assert(math.sqrt(p.X * p.X + p.Z * p.Z) <= 2.5001, name .. ": exceeded reserved circular footprint")
				end
			end
		end
		count += 1
	end
	assert(math.abs(minimumY) < 0.0001, name .. ": floating template")
	parent:Destroy()
end
local service = env.game:GetService("MaterialService")
materials.install()
local first = #service:GetChildren()
materials.install()
assert(#service:GetChildren() == first, "material install stacks duplicate textures")
for key, name in pairs(Config.get("environmentArt").materials) do
	local part = r.Instance.new("Part")
	materials.apply(part, key)
	assert(part.MaterialVariant == name, "unwired material " .. name)
	assert(part.Material == service[name].BaseMaterial, "material variant base mismatch")
end
for _, node in ipairs(env.Server.World.ArtAssets.Materials:GetDescendants()) do
	assert(node:IsA("MaterialVariant"), "unexpected material payload " .. node.ClassName)
end
print(`Environment art: {#names} sanitized templates / {count} meshes; grounded, bounded, visual-only, PBR materials installed once.`)
