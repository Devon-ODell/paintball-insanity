--!nolint
--- What the forest actually placed, and how many parts it costs.
local roblox = require("@lune/roblox")
local Harness = require("./Harness")
local env = Harness.build()
local Config = env.require(env.ReplicatedStorage.Shared.Config)
local Foliage = env.require(env.ServerScriptService.Server.World.Foliage)

local cfg = Config.get("overworld")
local palette = {}
for key, rgb in pairs(cfg.palette) do
	palette[key] = roblox.Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end
local folder = roblox.Instance.new("Folder")
local total, report = Foliage.scatter(cfg.scatter, palette, cfg.trails, folder)

print(string.format("%-14s %8s %8s %8s   %s", "layer", "asked", "placed", "reach", ""))
for _, layer in ipairs(report) do
	local spec
	for _, l in ipairs(cfg.scatter.layers) do if l.id == layer.id then spec = l end end
	local reach = Foliage.footprintRadius(spec)
	local ratio = layer.placed / math.max(1, layer.requested)
	local colour = if ratio >= 0.85 then "\27[32m" else "\27[31m"
	print(string.format("%-14s %8d %s%8d\27[0m %8.2fm", layer.id, layer.requested, colour, layer.placed, reach))
end
local parts, shadows = 0, 0
for _, d in ipairs(folder:GetDescendants()) do
	if d:IsA("BasePart") then
		parts += 1
		if d.CastShadow then shadows += 1 end
	end
end
print(string.format("\n%d instances, %d parts (%.1f parts each)", total, parts, parts / math.max(1, total)))

print(string.format("%d shadow casters; %d parts have shadows disabled (structural counts, not rendered performance)", shadows, parts - shadows))
