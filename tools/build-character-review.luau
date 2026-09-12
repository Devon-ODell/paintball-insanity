--!strict
--[[
	Every person in the game, standing in a line, saved for Studio inspection.

	    lune run tools/build-character-review

	The gates can prove a figure is 7.5 heads tall, that its knees flex through a
	stride and that nothing it wears leaves the hit capsule. They cannot tell you
	whether it looks like a person -- and "these all resemble blocks and blobs"
	is a judgement nobody can make from a part count.

	So: the six people at The Landing, the five enemy tiers, and one figure frozen
	at eight points through a single stride so the walk can be read as a sequence
	rather than guessed at from a number. Open it, orbit it, and say what is
	wrong with it.
]]
local r = require("@lune/roblox")
local fs = require("@lune/fs")
local env = require("./Harness").build()

local world = r.Instance.new("Workspace")
world.Name = "Workspace"
local terrain = r.Instance.new("Terrain")
terrain.Parent = world
local lighting = r.Instance.new("Lighting")
local materials = r.Instance.new("MaterialService")
lighting.LightingStyle = r.Enum.LightingStyle.Realistic
lighting.PrioritizeLightingQuality = true
lighting.Ambient = r.Color3.fromRGB(96, 100, 108)
lighting.OutdoorAmbient = r.Color3.fromRGB(118, 124, 134)
materials.Use2022Materials = true
local getService = env.game.GetService
env.game.GetService = function(self: any, name: string): any
	if name == "Workspace" then return world end
	if name == "Lighting" then return lighting end
	if name == "MaterialService" then return materials end
	return getService(self, name)
end

local Config = env.require(env.Shared.Config)
local Units = env.require(env.Shared.Units)
local Wardrobe = env.require(env.Server.World.Wardrobe)
local Npc = env.require(env.Server.World.Npc)
local BotAvatar = env.require(env.Server.Match.BotAvatar)
env.require(env.Shared.Log).setLevel("error")

--- Something to stand on, and a metre grid to read proportions against.
local ground = r.Instance.new("Part")
ground.Name = "Ground"
ground.Anchored = true
ground.Size = Units.vectorToStuds(r.Vector3.new(46, 0.4, 16))
ground.CFrame = r.CFrame.new(Units.vectorToStuds(r.Vector3.new(0, -0.2, 0)))
ground.Color = r.Color3.fromRGB(96, 102, 92)
ground.Material = r.Enum.Material.Grass
ground.Parent = world

--[[
	A height reference at every half metre.

	The single number that decides whether a figure reads as a person is how many
	head-heights tall it is, and the eye is much better at judging that against a
	ruler than in isolation.
]]
local rulerFolder = r.Instance.new("Folder")
rulerFolder.Name = "HeightRuler"
rulerFolder.Parent = world
for i = 1, 4 do
	local metres = i * 0.5
	local mark = r.Instance.new("Part")
	mark.Name = string.format("Mark_%.1fm", metres)
	mark.Anchored = true
	mark.CanCollide = false
	mark.Size = Units.vectorToStuds(r.Vector3.new(44, 0.012, 0.012))
	mark.CFrame = r.CFrame.new(Units.vectorToStuds(r.Vector3.new(0, metres, -3.2)))
	mark.Color = if math.abs(metres - 1.8) < 0.01
		then r.Color3.fromRGB(226, 96, 72) else r.Color3.fromRGB(232, 228, 214)
	mark.Material = r.Enum.Material.Neon
	mark.Parent = rulerFolder
end

local palette = {}
for key, rgb in pairs(Config.get("overworld").palette) do
	palette[key] = r.Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

local function label(text: string, at: r.Vector3, parent: Instance)
	local post = r.Instance.new("Part")
	post.Name = `Label_{text}`
	post.Anchored = true
	post.CanCollide = false
	post.Transparency = 1
	post.Size = Units.vectorToStuds(r.Vector3.new(0.2, 0.2, 0.2))
	post.CFrame = r.CFrame.new(Units.vectorToStuds(at))
	post.Parent = parent
	local gui = r.Instance.new("BillboardGui")
	gui.Size = r.UDim2.fromScale(7, 1.1)
	gui.AlwaysOnTop = true
	gui.Parent = post
	local caption = r.Instance.new("TextLabel")
	caption.Size = r.UDim2.fromScale(1, 1)
	caption.BackgroundTransparency = 1
	caption.Text = text
	caption.TextScaled = true
	caption.TextColor3 = r.Color3.fromRGB(246, 242, 230)
	caption.TextStrokeTransparency = 0.3
	caption.Parent = gui
end

--------------------------------------------------------------------------------
-- The people at The Landing, each in their own idle posture
--------------------------------------------------------------------------------

local landing = r.Instance.new("Folder")
landing.Name = "TheLanding"
landing.Parent = world
local people = Npc.buildAll(palette, landing)
local names = {}
for id in pairs(people) do table.insert(names, id) end
table.sort(names)
for index, id in ipairs(names) do
	local x = -18 + (index - 1) * 3.2
	local person = people[id]
	--- Npc.build places each figure where it stands in the hub; move the whole
	--- model onto the review line without disturbing how it is posed.
	local root = person.model.PrimaryPart
	if root then
		local shift = r.CFrame.new(Units.vectorToStuds(r.Vector3.new(x, 0, 0)) - r.Vector3.new(root.CFrame.Position.X, 0, root.CFrame.Position.Z))
		for _, part in ipairs(person.model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CFrame = shift * part.CFrame
			end
		end
	end
	label(id, r.Vector3.new(x, 2.05, 0), landing)
end

--------------------------------------------------------------------------------
-- The enemy team, one of each tier
--------------------------------------------------------------------------------

local squad = r.Instance.new("Folder")
squad.Name = "TheEnemyTeam"
squad.Parent = world
for index, tier in ipairs({ "rec", "amateur", "semipro", "pro", "marshal" }) do
	local x = 2 + (index - 1) * 3.2
	local avatar = BotAvatar.new(`review_{tier}`, tier, squad, tier)
	avatar:setPosition(r.Vector3.new(x, 0, 0), r.Vector3.new(0, 0, -1))
	label(`{tier} — {BotAvatar.outfitFor(tier)}`, r.Vector3.new(x, 2.05, 0), squad)
end

--------------------------------------------------------------------------------
-- One stride, frozen
--------------------------------------------------------------------------------

--[[
	The same figure at eight points through a single walk cycle.

	This is the thing that could not be judged from the old build at all: the
	limbs translated fore and aft without ever rotating, and laid out as a
	sequence that is immediately obvious. Read left to right -- heel strike,
	mid-stance, toe-off, mid-swing.
]]
local walk = r.Instance.new("Folder")
walk.Name = "OneStride"
walk.Parent = world
local FRAMES = 8
local stride = Config.get("wardrobe")
for i = 0, FRAMES - 1 do
	local holder = r.Instance.new("Model")
	holder.Name = `Stride_{i + 1}`
	local build = Wardrobe.buildOf("botPro")
	local body = Wardrobe.body(holder, {
		build = build,
		torsoColour = r.Color3.fromRGB(196, 82, 64),
		limbColour = r.Color3.fromRGB(58, 60, 66),
		skinColour = r.Color3.fromRGB(198, 164, 132),
		handsForward = false,
		face = true,
	})
	--- Walk it up to this point in the cycle at full pace, so the blend is
	--- saturated and the pose is the one a moving bot actually holds.
	for _ = 1, 40 do body.step(0.06, 3.2) end
	local target = (i / FRAMES) * 0.85 * 2
	local walked = 0
	while walked < target do
		body.step(0.01, 3.2)
		walked += 0.01
	end
	local at = Units.vectorToStuds(r.Vector3.new(-18 + i * 5.2, 0, 6))
	body.pose(r.CFrame.new(at))
	holder.Parent = walk
end
label("one stride, eight frames — heel strike to mid-swing", r.Vector3.new(0, 2.4, 6), walk)

--------------------------------------------------------------------------------

local origin = Units.vectorToStuds(r.Vector3.new(0, 2.4, -11))
local target = Units.vectorToStuds(r.Vector3.new(0, 1.0, 0))
local back = (origin - target).Unit
local right = r.Vector3.yAxis:Cross(back).Unit
local camera = r.Instance.new("Camera")
camera.Name = "CharacterReviewCamera"
camera.CFrame = r.CFrame.fromMatrix(origin, right, back:Cross(right), back)
camera.Focus = r.CFrame.new(target)
camera.FieldOfView = 60
camera.Parent = world
world.CurrentCamera = camera

local parts = 0
for _, item in ipairs(world:GetDescendants()) do
	if item:IsA("BasePart") then parts += 1 end
end

fs.writeDir("build")
local path = "build/character-review.rbxlx"
local place = r.Instance.new("DataModel")
world.Parent, lighting.Parent, materials.Parent = place, place, place
fs.writeFile(path, r.serializePlace(place, true))
print(`Built {path} ({parts} parts): six at The Landing, five enemy tiers, and one stride in eight frames.`)
print("Open it in Studio and orbit the line. The red rule is 1.80 m -- the height the server shoots at.")
