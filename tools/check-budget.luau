--!nolint
--[[
	Render budget gate.

	    lune run tools/check-budget

	Builds every field and the hub and checks what they actually cost against the
	budgets in Data/presentation.json. Exits non-zero over budget, so it can sit
	in CI beside map-validate and course-report.

	Three numbers, and they are not interchangeable:

	  parts          what has to be streamed and drawn at all.
	  shadow casters far more expensive than a part under Future lighting with
	                 global shadows, and the thing that ran away here -- the hub
	                 was casting 5784 of them, most landing behind other trees.
	  transparent m² semi-transparent surfaces cannot early-out of the depth
	                 test, so a 132 x 20 m boundary wall at 0.2 alpha forces
	                 overdraw across much of the screen. Area matters more than
	                 count, which is why this measures metres rather than parts.

	Budgets are deliberately a little above what is measured today. They are a
	tripwire for a regression, not a target to fill.
]]

local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Harness = require("./Harness")

local env = Harness.build()
env.globals.Instance = roblox.Instance
local lighting = roblox.Instance.new("Lighting")
local getService = env.game.GetService
env.game.GetService = function(self: any, name: string): any
	return if name == "Lighting" then lighting else getService(self, name)
end
env.globals.UDim2 = roblox.UDim2
env.globals.Enum = roblox.Enum

local WorldBuilder = env.require(env.Server.Match.WorldBuilder)
local FieldDetails = env.require(env.Server.Match.FieldDetails)
local Foliage = env.require(env.Server.World.Foliage)
local Config = env.require(env.Shared.Config)
local Units = env.require(env.Shared.Units)

local budgets = Config.require("presentation", "budget")
local problems = 0

local function report(label: string, measured: number, budget: number, unit: string)
	local over = measured > budget
	if over then
		problems += 1
	end
	local headroom = budget - measured
	print(string.format("  %s %-9s %8.0f %-4s of %6.0f   %s",
		if over then "\27[31mOVER\27[0m" else "\27[32mok  \27[0m",
		label, measured, unit, budget,
		if over then string.format("\27[31m%.0f over\27[0m", -headroom) else string.format("%.0f spare", headroom)))
end

--- Parts, shadow casters, and the surface area of anything semi-transparent.
local function measure(container: Instance): (number, number, number)
	local parts, shadows, transparentArea = 0, 0, 0
	for _, descendant in ipairs(container:GetDescendants()) do
		if descendant:IsA("BasePart") then
			parts += 1
			if descendant.CastShadow then
				shadows += 1
			end
			local alpha = descendant.Transparency
			if alpha > 0.01 and alpha < 0.99 then
				--[[
					The largest face, in metres. A boundary wall is a single slab
					and its cost is its area on screen, not the fact that it is
					one part.
				]]
				local size = descendant.Size
				local largest = math.max(size.X * size.Y, size.X * size.Z, size.Y * size.Z)
				transparentArea += Units.studsToMetres(1) * Units.studsToMetres(1) * largest
			end
		end
	end
	return parts, shadows, transparentArea
end

print("\27[1mcheck-budget\27[0m")

for _, name in ipairs(Config.mapNames()) do
	local root = roblox.Instance.new("Folder")
	local world = WorldBuilder.build(name, root)
	-- The venue props are part of what a player looks at, so they are part of
	-- what the field costs.
	FieldDetails.build(name, world)
	local parts, shadows, transparent = measure(world)
	print(`\n\27[1m{name}\27[0m`)
	report("parts", parts, budgets.map.parts, "")
	report("shadows", shadows, budgets.map.shadowCasters, "")
	report("alpha", transparent, budgets.map.transparentSquareMetres, "m2")
end

do
	local cfg = Config.get("overworld")
	local palette = {}
	for key, rgb in pairs(cfg.palette) do
		palette[key] = roblox.Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	end
	local folder = roblox.Instance.new("Folder")
	Foliage.scatter(cfg.scatter, palette, cfg.trails, folder)
	local parts, shadows = measure(folder)
	print("\n\27[1mthe landing (foliage)\27[0m")
	report("parts", parts, budgets.hubFoliage.parts, "")
	report("shadows", shadows, budgets.hubFoliage.shadowCasters, "")
end

print("")
if problems > 0 then
	print(`\27[31m{problems} budget(s) exceeded\27[0m`)
	process.exit(1)
end
print("\27[32meverything is inside its render budget\27[0m")
