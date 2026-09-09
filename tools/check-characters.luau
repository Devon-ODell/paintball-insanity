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

	--[[
		The shove has to be visible on the body, not just in the rules.

		A bot at contact range used to take a player out while standing
		perfectly still: the commit delay exists so the swing can be seen coming,
		and a warning nobody can see is not a warning. Asserted here because it
		is the one animation that plays for a fraction of a second and then
		removes the thing that would have shown it.
	]]
	local rest = avatar.marker.CFrame
	avatar:setSwing(0.38)
	avatar:setPosition(roblox.Vector3.new(0, 0, 0), roblox.Vector3.new(0, 0, -1))
	if (avatar.marker.CFrame.Position - rest.Position).Magnitude < 0.1 then
		print(`          {tier}: the marker does not move during a shove`)
		problems += 1
	end
	avatar:setSwing(nil)
	avatar:setPosition(roblox.Vector3.new(0, 0, 0), roblox.Vector3.new(0, 0, -1))
	if (avatar.marker.CFrame.Position - rest.Position).Magnitude > 1e-4 then
		print(`          {tier}: the marker did not come back to rest after a shove`)
		problems += 1
	end
end

print("")
if problems > 0 then
	print(`\27[31m{problems} problem(s)\27[0m`)
	require("@lune/process").exit(1)
end
--[[
	Nobody casts a shadow. Twelve bodies at 72 parts each, all moving, would be
	the most expensive shadows in the game -- and a moving caster costs far more
	than a static one. Wardrobe sets this on the body and the kit; the marker,
	the barrel and the hopper are built in BotAvatar and were missing it, so a
	bot's body cast nothing while the thing it was holding cast three.
]]
do
	local casting = {}
	for _, tier in ipairs({ "rec", "amateur", "semipro", "pro", "marshal" }) do
		local folder = roblox.Instance.new("Folder")
		BotAvatar.new(`shadow_{tier}`, "Probe", folder, tier)
		for _, descendant in ipairs(folder:GetDescendants()) do
			if descendant:IsA("BasePart") and descendant.CastShadow then
				table.insert(casting, `{tier}/{descendant.Name}`)
			end
		end
	end
	assert(#casting == 0, `characters must cast no shadows, these do: {table.concat(casting, ", ")}`)
end

--[[
	Civilians have faces; the enemy team does not need one.

	Every head used to be a bare skin-coloured ball, which is what made the
	people at The Landing read as mannequins standing next to a squad whose mask
	lenses gave them something to look at. The bots still get none: a full mask
	covers the eyes exactly as it should, and building four parts a bot that
	nobody can see costs forty-eight across a squad that is rebuilt at every
	round boundary.
]]
do
	local faceless = {}
	for _, person in ipairs(people) do
		local found = 0
		for _, descendant in ipairs(person.model:GetDescendants()) do
			if descendant:IsA("BasePart") and (descendant.Name == "EyeL" or descendant.Name == "EyeR") then
				found += 1
			end
		end
		if found < 2 then
			table.insert(faceless, person.id)
		end
	end
	assert(#faceless == 0, `everyone at The Landing needs a face, these have none: {table.concat(faceless, ", ")}`)

	local masked = roblox.Instance.new("Folder")
	BotAvatar.new("face_probe", "Probe", masked, "pro")
	for _, descendant in ipairs(masked:GetDescendants()) do
		if descendant:IsA("BasePart") then
			assert(
				descendant.Name ~= "EyeL" and descendant.Name ~= "EyeR",
				"a bot builds eyes nobody can see behind its mask"
			)
		end
	end
end

print("\27[32mevery character builds, the civilians have faces, and none of them casts a shadow\27[0m")
