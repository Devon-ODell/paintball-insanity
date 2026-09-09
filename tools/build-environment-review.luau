--!strict
-- Actual generated hub, saved as a static inspection place. No game scripts,
-- purchases or persistence execute when opening it. Run the demo for gameplay.
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
env.require(env.Server.World.Overworld).build(world)
local Units = env.require(env.Shared.Units)
local spawn = Config.get("overworld").spawn
local origin = Units.vectorToStuds(r.Vector3.new(spawn.position[1], spawn.position[2] + 1.7, spawn.position[3]))
local target = Units.vectorToStuds(r.Vector3.new(spawn.lookAt[1], spawn.lookAt[2], spawn.lookAt[3]))
local back = (origin - target).Unit
local right = r.Vector3.yAxis:Cross(back).Unit
local camera = r.Instance.new("Camera")
camera.Name = "LandingReviewCamera"
camera.CFrame = r.CFrame.fromMatrix(origin, right, back:Cross(right), back)
camera.Focus = r.CFrame.new(target)
camera.FieldOfView = 75
camera.Parent = world
world.CurrentCamera = camera
fs.writeDir("build")
local path = "build/environment-review.rbxlx"
local place = r.Instance.new("DataModel")
world.Parent, lighting.Parent, materials.Parent = place, place, place
fs.writeFile(path, r.serializePlace(place, true))
print("Built " .. path .. "; open in Studio to inspect actual mesh, PBR, sky and ground assets.")
