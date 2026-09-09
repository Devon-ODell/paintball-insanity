--!strict
-- Offline allowlist import of Roblox's endorsed art. No downloaded script runs.
-- Usage: lune run tools/import-environment-art /tmp/roblox-forest.rbxm /tmp/roblox-environment.rbxm
local r = require("@lune/roblox")
local fs = require("@lune/fs")
local args = require("@lune/process").args
local forest = r.deserializeModel(fs.readFile(args[1]))[1]
local environment = r.deserializeModel(fs.readFile(args[2]))[1]
local destination = "src/ServerScriptService/World/ArtAssets"
fs.writeDir(destination)
local selection = {
	Redwood = "RedwoodTree-Var01", RedwoodDistant = "Redwoodtree-LowLOD-Var01",
	Beech = "BeechwoodTree_Var02", Sapling = "BeechwoodSapling_Var01",
	Fern = "Fern_Var01", FernTall = "FernTallVar01", Rock = "MediumBoulderVar01",
	MossRock = "MediumMossBoulder01", FallenLog = "FallenTreeMossyVar01", LeafLitter = "DenseLeafPatch",
}
for name, sourceName in pairs(selection) do
	local source = assert(forest:FindFirstChild(sourceName), sourceName)
	local model = r.Instance.new("Model")
	model.Name = name
	local min = r.Vector3.new(math.huge, math.huge, math.huge)
	local max = -min
	-- Flatten the selected static meshes; omit optional soil planes, embedded
	-- plants and every behavior/constraint/package link from the source model.
	for _, original in ipairs(source:GetChildren()) do
		if original:IsA("MeshPart") and original.Name ~= "Soil" then
			local part = original:Clone()
			for _, child in ipairs(part:GetChildren()) do
				if not child:IsA("SurfaceAppearance") then child:Destroy() end
			end
			part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch = true, false, false, false
			part.CastShadow = true
			part.RenderFidelity = r.Enum.RenderFidelity.Automatic
			part.Parent = model
			for _, x in ipairs({ -1, 1 }) do
				for _, y in ipairs({ -1, 1 }) do
					for _, z in ipairs({ -1, 1 }) do
						local v = part.CFrame:PointToWorldSpace(part.Size * r.Vector3.new(x, y, z) / 2)
						min = r.Vector3.new(math.min(min.X, v.X), math.min(min.Y, v.Y), math.min(min.Z, v.Z))
						max = r.Vector3.new(math.max(max.X, v.X), math.max(max.Y, v.Y), math.max(max.Z, v.Z))
					end
				end
			end
		end
	end
	assert(#model:GetChildren() > 0, "empty art selection " .. name)
	local ground = r.Vector3.new((min.X + max.X) / 2, min.Y, (min.Z + max.Z) / 2)
	for _, part in ipairs(model:GetChildren()) do part.CFrame = part.CFrame - ground end
	model:SetAttribute("SourceAssetId", "6432306802")
	model:SetAttribute("SourceModel", sourceName)
	model:SetAttribute("SourceSize", max - min)
	fs.writeFile(destination .. "/" .. name .. ".rbxmx", r.serializeModel({ model }, true))
	print(name, #model:GetChildren(), max - min)
end
-- Material-only subset of the official Environment Art library.
local materials = r.Instance.new("Folder")
materials.Name = "Materials"
local wanted = { Moss = true, Stones = true, Concrete_Board_Formed_A = true, MetalPanels = true }
for _, item in ipairs(environment:GetDescendants()) do
	if item:IsA("MaterialVariant") and wanted[item.Name] then
		local material = item:Clone()
		material:ClearAllChildren()
		material.Name = "LR_" .. item.Name
		material.Parent = materials
	end
end
fs.writeFile(destination .. "/Materials.rbxmx", r.serializeModel({ materials }, true))
