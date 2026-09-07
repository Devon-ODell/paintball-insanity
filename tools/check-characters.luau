--!nolint
--[[
	Builds every person in the game and counts what came out.

	    lune run tools/check-characters

	Constructs real Roblox instances through Lune's property database, so this
	catches a bad Enum, an unknown property or a missing wardrobe piece. It
	cannot tell you whether anyone looks good -- that still needs Studio.
]]
local roblox = require("@lune/roblox")
local Harness = require("./Harness")
local env = Harness.build()
local Config = env.require(env.ReplicatedStorage.Shared.Config)
local Wardrobe = env.require(env.ServerScriptService.Server.World.Wardrobe)
local Npc = env.require(env.ServerScriptService.Server.World.Npc)
local BotAvatar = env.require(env.ServerScriptService.Server.Match.BotAvatar)

local problems = 0

print("\27[1mwardrobe\27[0m")
for _, name in ipairs(Wardrobe.outfitNames()) do
	local missing = {}
	for _, piece in ipairs(Wardrobe.piecesOf(name)) do
		if not Wardrobe.hasPiece(piece) then
			table.insert(missing, piece)
			problems += 1
		end
	end
	local holder = roblox.Instance.new("Folder")
	local worn = Wardrobe.dress(name, holder, 1)
	local status = if #missing > 0 then `\27[31mMISSING {table.concat(missing, ", ")}\27[0m` else "ok"
	print(string.format("  %-12s %2d pieces  %3d parts   %s", name, #Wardrobe.piecesOf(name), #worn, status))
end

print("\n\27[1mthe landing\27[0m")
local palette = {}
for key, rgb in pairs(Config.get("overworld").palette) do
	palette[key] = roblox.Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end
local folder = roblox.Instance.new("Folder")
local people = Npc.buildAll(palette, folder)
local names = {}
for id in pairs(people) do table.insert(names, id) end
table.sort(names)
for _, id in ipairs(names) do
	local model = people[id].model
	local count = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then count += 1 end
	end
	if count < 12 then
		print(string.format("  %-12s \27[31m%d parts -- too few to read as a person\27[0m", id, count))
		problems += 1
	else
		print(string.format("  %-12s %3d parts", id, count))
	end
end

print("\n\27[1mthe enemy team\27[0m")
for _, tier in ipairs({ "rec", "amateur", "semipro", "pro", "marshal" }) do
	local parent = roblox.Instance.new("Folder")
	local avatar = BotAvatar.new(`probe_{tier}`, "Probe", parent, tier)
	avatar:setPosition(roblox.Vector3.new(0, 0, 0), roblox.Vector3.new(0, 0, -1))
	local count = 0
	for _, d in ipairs(avatar.model:GetDescendants()) do
		if d:IsA("BasePart") then count += 1 end
	end
	print(string.format("  %-10s %-12s %3d parts", tier, BotAvatar.outfitFor(tier), count))
	if count < 14 then problems += 1 end
end

print("")
if problems > 0 then
	print(`\27[31m{problems} problem(s)\27[0m`)
	require("@lune/process").exit(1)
end
print("\27[32mevery character builds\27[0m")
