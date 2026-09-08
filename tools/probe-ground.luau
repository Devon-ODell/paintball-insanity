--!nolint
--[[
	Ground layering probe.

	    lune run tools/probe-ground

	Reports the vertical extent of the hub's ground slab and everything drawn on
	it -- trails, joins, zones -- in metres, so "the floor looks wrong" can be
	checked against numbers instead of guessed at.

	What matters is the gap between the ground's TOP face and each surface's
	BOTTOM face. A surface that floats above the ground shows a shadow line and a
	step; one that sinks below it disappears. Neither is visible in a screenshot
	of a single part, which is why this exists.

	Diagnostic only. Never edits anything, never gates.
]]

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

local Overworld = env.require(env.Server.World.Overworld)
local Units = env.require(env.Shared.Units)

local root = roblox.Instance.new("Folder")
Overworld.build(root)

local function metres(studs: number): number
	return Units.studsToMetres(studs)
end

--[[
	True world-space vertical half-extent of a part.

	A part's own Y axis is only vertical when the part is unrotated, and the
	trail joins and the clearing are cylinders rotated flat -- reading Size.Y on
	those reports a diameter as if it were a thickness. Project all three of the
	part's axes onto world Y instead.
]]
local function halfHeightStuds(part: any): number
	local cf = part.CFrame
	local size = part.Size
	return 0.5 * (
		math.abs(cf.RightVector.Y) * size.X
		+ math.abs(cf.UpVector.Y) * size.Y
		+ math.abs(cf.LookVector.Y) * size.Z
	)
end

local function extentMetres(part: any): (number, number)
	local centre = part.CFrame.Position.Y
	local half = halfHeightStuds(part)
	return metres(centre - half), metres(centre + half)
end

-- The ground slab everything else is drawn on.
local groundTop: number? = nil
for _, d in ipairs(root:GetDescendants()) do
	if d:IsA("BasePart") and d.Name == "ForestFloor" then
		local _, top = extentMetres(d)
		groundTop = top
	end
end

if not groundTop then
	print("no ForestFloor found; nothing to compare against")
	return
end

print(`\27[1mhub ground layering\27[0m   ForestFloor top face at y = {string.format("%.3f", groundTop)} m`)
print(string.format("  %-26s %9s %9s %9s  %s", "surface", "bottom", "top", "gap", "verdict"))

type Row = { name: string, bottom: number, top: number, count: number }
local rows: { [string]: Row } = {}
local order: { string } = {}

local function onGround(part: any): boolean
	-- Only what is drawn ON the floor. Mannequins, foliage and props stand on
	-- it and would drown the signal.
	local node: any = part.Parent
	while node do
		if node.Name == "Terrain" or node.Name == "Trails" then
			return true
		end
		node = node.Parent
	end
	return false
end

for _, d in ipairs(root:GetDescendants()) do
	if d:IsA("BasePart") and d.Name ~= "ForestFloor" and onGround(d) then
		-- Group trail segments/joins by their trail id rather than per segment.
		local group = string.match(d.Name, "^(.-)_join%d+$") or string.match(d.Name, "^(.-)_%d+$") or d.Name
		local bottom, top = extentMetres(d)
		local row = rows[group]
		if not row then
			row = { name = group, bottom = bottom, top = top, count = 0 }
			rows[group] = row
			table.insert(order, group)
		end
		row.bottom = math.min(row.bottom, bottom)
		row.top = math.max(row.top, top)
		row.count += 1
	end
end

-- Only the things actually sitting on the floor are interesting here.
local interesting: { string } = {}
for _, name in ipairs(order) do
	local row = rows[name]
	if row.bottom < groundTop + 1.0 and row.top > groundTop - 1.0 then
		table.insert(interesting, name)
	end
end
table.sort(interesting, function(a: string, b: string): boolean
	return rows[a].bottom < rows[b].bottom
end)

local floating = 0
for _, name in ipairs(interesting) do
	local row = rows[name]
	local gap = row.bottom - groundTop
	local verdict
	if gap > 0.005 then
		floating += 1
		verdict = `\27[31mfloats {string.format("%.0f", gap * 100)} cm above the floor\27[0m`
	elseif row.top < groundTop then
		verdict = "\27[31mburied\27[0m"
	else
		verdict = "\27[32mseated\27[0m"
	end
	print(string.format("  %-26s %9.3f %9.3f %9.3f  %s   (%d parts)",
		name, row.bottom, row.top, gap, verdict, row.count))
end

print()
if floating > 0 then
	print(`\27[31m{floating} surface group(s) do not touch the ground they are drawn on\27[0m`)
else
	print("\27[32mevery ground surface is seated on the floor\27[0m")
end
