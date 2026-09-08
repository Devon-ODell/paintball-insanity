--!strict
-- Real instance/property validation plus an optional geometry export for offline
-- inspection. The export is source geometry, not a Studio screenshot.
local Harness = require("./Harness")
local roblox = require("@lune/roblox")
local env = Harness.build()
local Config = env.require(env.Shared.Config)
local Units = env.require(env.Shared.Units)
local Vehicles = env.require(env.Server.World.VehicleProps)
local Yard = env.require(env.Server.World.YardProps)
local root = roblox.Instance.new("Folder")
local exported = {}
for _, kind in ipairs({ "sedan", "pickup" }) do
	local model = Vehicles.build(kind, roblox.CFrame.identity, roblox.Color3.fromRGB(109, 139, 122), root,
		if kind == "sedan" then roblox.Vector3.new(2.2, 1.6, 4.6) else nil)
	assert(#model:GetChildren() <= Config.get("vehicleProps").partBudget, kind .. " over budget")
	local tires, arches = 0, 0
	local output = {}
	local names = {}
	for _, part in ipairs(model:GetChildren()) do
		assert(not names[part.Name], "duplicate vehicle part " .. part.Name)
		names[part.Name] = true
		assert(part.Anchored and not part.CanCollide and not part.CanQuery and not part.CanTouch, "vehicle decoration entered physics")
		assert(part.Transparency == 0, "vehicle glazing introduced transparency overdraw")
		if part.Name:sub(1, 4) == "Tire" then
			tires += 1
			assert(math.abs(part.CFrame.Position.Y - part.Size.Y / 2) < 0.001, "tire does not touch ground")
		end
		if part.Name:sub(1, 9) == "WheelArch" then arches += 1 end
		assert(part.Shape ~= roblox.Enum.PartType.Ball, "vehicle uses a blob for its silhouette")
		local limits = if kind == "sedan" then roblox.Vector3.new(2.2, 1.6, 4.6) else roblox.Vector3.new(2.42, 2.1, 4.6)
		for _, x in ipairs({ -1, 1 }) do
			for _, y in ipairs({ -1, 1 }) do
				for _, z in ipairs({ -1, 1 }) do
					local corner = Units.vectorToMetres(part.CFrame:PointToWorldSpace(part.Size * roblox.Vector3.new(x, y, z) / 2))
					assert(math.abs(corner.X) <= limits.X / 2 + 0.01 and math.abs(corner.Z) <= limits.Z / 2 + 0.01
						and corner.Y >= -0.01 and corner.Y <= limits.Y + 0.01, part.Name .. " escaped vehicle bounds")
				end
			end
		end
		local size = Units.vectorToMetres(part.Size)
		local position = Units.vectorToMetres(part.CFrame.Position)
		table.insert(output, { name = part.Name, size = { size.X, size.Y, size.Z },
			cf = { (roblox.CFrame.new(position) * part.CFrame.Rotation):GetComponents() },
			shape = part.Shape.Name, color = { part.Color.R, part.Color.G, part.Color.B } })
	end
	assert(tires == 4 and arches > 0, "missing wheels or fenders")
	assert(model:FindFirstChild("Windshield") and model:FindFirstChild("RearGlass"), "missing glazing")
	if kind == "pickup" then
		assert(model:FindFirstChild("BedFloor") and model:FindFirstChild("Tailgate"), "missing open pickup bed")
	end
	exported[kind] = output
	print(`{kind}: {#model:GetChildren()} parts; grounded tires, wheel arches, glazing and visual-only geometry passed`)
end
local palette = {}
for key, rgb in pairs(Config.get("overworld").palette) do palette[key] = roblox.Color3.fromRGB(unpack(rgb)) end
for _, kind in ipairs({ "picnicTable", "airRack", "palletStack" }) do
	local model = Yard.build(kind, roblox.CFrame.identity, palette, root)
	assert(#model:GetChildren() < 50, "yard prop over budget")
	print(`{kind}: {#model:GetChildren()} parts built`)
end
-- Check the actual Urban integration, not just the reusable builder.
local lighting = roblox.Instance.new("Lighting")
local getService = env.game.GetService
env.game.GetService = function(self: any, name: string): any
	return if name == "Lighting" then lighting else getService(self, name)
end
local WorldBuilder = env.require(env.Server.Match.WorldBuilder)
local urban = WorldBuilder.build("urban", root)
for _, piece in ipairs(Config.map("urban").geometry) do
	if piece.prop then
		local hull = urban.Geometry:FindFirstChild(piece.id)
		assert(hull.Transparency == 1 and hull.CanCollide and hull.CanQuery, "lost authoritative car hull")
		assert((hull.Size - Units.vectorToStuds(roblox.Vector3.new(unpack(piece.size)))).Magnitude < 0.001, "car collision dimensions changed")
		assert(hull:FindFirstChild("sedan"), "Urban car did not get its vehicle model")
	end
end
print("Urban cars retain their original collision dimensions and have vehicle assemblies")
local outputPath = require("@lune/process").args[1]
if outputPath then
	require("@lune/fs").writeFile(outputPath, require("@lune/serde").encode("json", exported))
end
