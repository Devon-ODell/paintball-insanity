--!strict
-- Actual CTF field and flags, saved for static Studio inspection.
-- Play paintball-ctf-playtest.rbxlx for the live mode.
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
materials.Use2022Materials = true
local getService = env.game.GetService
env.game.GetService = function(self: any, name: string): any
	if name == "Workspace" then return world end
	if name == "Lighting" then return lighting end
	if name == "MaterialService" then return materials end
	return getService(self, name)
end
local Config = env.require(env.Shared.Config)
env.require(env.Shared.Log).setLevel("error")
local data = env.require(env.Server.Match.FlagArena).prepare(Config.map("holdfast"))
local map = env.require(env.Server.Match.WorldBuilder).build("holdfast", world, data)
local rules = env.require(env.Server.Match.CaptureTheFlag).new(data)
env.require(env.Server.Match.FlagVisuals).new(map, rules)
local stairs = 0
for _, item in ipairs(map:GetDescendants()) do
	if item:IsA("BasePart") and item.Name:sub(1, 4) == "ctf_" then
		assert(item.CanCollide and item.Anchored, "CTF approach must have real anchored collision")
		stairs += 1
	end
end
assert(stairs > 0, "prepared CTF geometry never reached the physical world builder")
print("Physical CTF approach pieces: " .. stairs)
local Units = env.require(env.Shared.Units)
local spawn = data.playerSpawn
local origin = Units.vectorToStuds(r.Vector3.new(spawn.position[1], spawn.position[2] + 1.7, spawn.position[3]))
local target = Units.vectorToStuds(r.Vector3.new(spawn.lookAt[1], spawn.lookAt[2], spawn.lookAt[3]))
local back = (origin - target).Unit
local right = r.Vector3.yAxis:Cross(back).Unit
local camera = r.Instance.new("Camera")
camera.Name = "CTFReviewCamera"
camera.CFrame = r.CFrame.fromMatrix(origin, right, back:Cross(right), back)
camera.Focus = r.CFrame.new(target)
camera.FieldOfView = 75
camera.Parent = world
world.CurrentCamera = camera
fs.writeDir("build")
local path = "build/ctf-review.rbxlx"
local place = r.Instance.new("DataModel")
world.Parent, lighting.Parent, materials.Parent = place, place, place
fs.writeFile(path, r.serializePlace(place, true))
print("Built " .. path .. "; open in Studio to inspect actual CTF stairs, decks, flags and map art.")
