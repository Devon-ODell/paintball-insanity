--!strict
-- Build every bunker with real Roblox property types, independent of the hub.
local Harness = require("./Harness")
local env = Harness.build()
local roblox = require("@lune/roblox")
local Inflatables = env.require(env.ServerScriptService.Server.Match.Inflatables)
local Config = env.require(env.ReplicatedStorage.Shared.Config)
local Units = env.require(env.ReplicatedStorage.Shared.Units)
local parent = roblox.Instance.new("Folder")
local count = 0
for _, piece in ipairs(Config.map("speedball").geometry) do
	if Inflatables.handles(piece.shape) then
		local size = Units.vectorToStuds(roblox.Vector3.new(unpack(piece.size)))
		local model = Inflatables.build(piece.shape, roblox.CFrame.identity, size, roblox.Color3.new(0, 0, 1), piece.id, parent)
		assert(#model:GetChildren() < 32, "bunker exceeded visual part budget")
		local wedges = 0
		for _, part in ipairs(model:GetChildren()) do
			assert(not part.CanQuery and not part.CanCollide and not part.CanTouch, "visual bunker changed collision")
			assert(part.Size.X > 0 and part.Size.Y > 0 and part.Size.Z > 0, "invalid bunker dimensions")
			if part.Shape == roblox.Enum.PartType.Wedge then wedges += 1 end
		end
		if piece.shape == "inflatable_dorito" then
			assert(wedges == 8 and not model:FindFirstChild("Crown"), "pyramid must have four triangular faces and one apex, not a ridge")
			local apex = model:FindFirstChild("Apex").CFrame.Position
			for _, panel in ipairs(model:GetChildren()) do
				if panel.Name == "PyramidPanel" then
					local tip = panel.CFrame:PointToWorldSpace(roblox.Vector3.new(0, panel.Size.Y / 2, panel.Size.Z / 2))
					assert((tip - apex).Magnitude < 0.001, "a pyramid face does not meet the common apex")
				end
			end
		end
		if piece.shape == "inflatable_can" then
			local top = model:FindFirstChild("TopCap")
			local bottom = model:FindFirstChild("BottomCap")
			assert(math.abs(top.CFrame.Position.Y + top.Size.Y / 2 - size.Y / 2) < 0.001, "can top exceeds authored height")
			assert(math.abs(bottom.CFrame.Position.Y - bottom.Size.Y / 2 + size.Y / 2) < 0.001, "can bottom exceeds authored height")
		end
		count += 1
	end
end
print(`Built {count} speedball bunker definitions: four-sided pyramids, bounded can caps, collision-free visuals, part budgets passed`)
