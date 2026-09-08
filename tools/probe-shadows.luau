--!nolint
--[[
	Shadow attribution probe.

	    lune run tools/probe-shadows [mapName]

	check-budget says a field is over its shadow budget. This says WHICH parts
	are casting, grouped by name, so the fix can be aimed at the trim rather than
	applied blindly to the whole field.

	Diagnostic only: it builds the same field check-budget does and reports. It
	never edits anything and is not a gate.
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
local Config = env.require(env.Shared.Config)

local target = process.args[1] or "speedball"

local root = roblox.Instance.new("Folder")
local world = WorldBuilder.build(target, root)
FieldDetails.build(target, world)

type Row = { name: string, casting: number, quiet: number }

local rows: { [string]: Row } = {}
local order: { string } = {}
local casting, quiet = 0, 0

for _, descendant in ipairs(world:GetDescendants()) do
	if descendant:IsA("BasePart") then
		local name = descendant.Name
		local row = rows[name]
		if not row then
			row = { name = name, casting = 0, quiet = 0 }
			rows[name] = row
			table.insert(order, name)
		end
		if descendant.CastShadow then
			row.casting += 1
			casting += 1
		else
			row.quiet += 1
			quiet += 1
		end
	end
end

table.sort(order, function(a: string, b: string): boolean
	if rows[a].casting ~= rows[b].casting then
		return rows[a].casting > rows[b].casting
	end
	return a < b
end)

local budget = Config.require("presentation", "budget").map.shadowCasters

print(`\27[1m{target}\27[0m  shadow casters by part name`)
print(string.format("  %-22s %8s %8s", "part", "casting", "quiet"))
for _, name in ipairs(order) do
	local row = rows[name]
	if row.casting > 0 then
		print(string.format("  %-22s %8d %8d", name, row.casting, row.quiet))
	end
end

print()
print(string.format("  %-22s %8d %8d", "TOTAL", casting, quiet))
print(string.format("  budget %d -> %s", budget,
	if casting > budget then `\27[31m{casting - budget} OVER\27[0m` else `\27[32m{budget - casting} spare\27[0m`))
