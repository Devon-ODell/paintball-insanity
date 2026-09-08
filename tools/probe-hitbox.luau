--!nolint
--[[
	Hitbox agreement probe.

	    lune run tools/probe-hitbox

	Every bot is shot at as a vertical capsule -- radius bodyWidthMetres/2,
	height bodyHeightMetres -- by ProjectileSim, and that same capsule is used by
	MatchService live and by SimMatch headless. The body a player actually SEES
	is built separately by World/Wardrobe from the same hitbox numbers.

	Those two can disagree, and the disagreement is invisible in every other
	check: Wardrobe scales its pieces per build (a pro has broader shoulders than
	a rec player), and nothing until now compared the result against the capsule.

	Geometry that sticks OUT of the capsule is the expensive direction. A player
	who puts paint on a visible shoulder and gets no elimination learns that the
	game is lying to them, and this game asks them to trust their aim. Geometry
	well INSIDE the capsule is the cheap direction -- the capsule is deliberately
	generous, because a graze marks you in paintball -- so it is reported but not
	failed.

	Reports in centimetres because that is the scale a player perceives.

	A PROBE, not a gate: it exits 0. The one deviation it currently finds that
	matters -- a bump helmet's crown standing above the capsule -- has a fix with
	a visual cost (the helmet is narrower than the mask underneath it, so simply
	lowering it hides it inside the mask), and that trade is a call to make with
	the thing on screen, in the Studio pass. Turn this into a gate once that
	decision is made.
]]

local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Harness = require("./Harness")

local env = Harness.build()
env.globals.Instance = roblox.Instance
env.globals.Enum = roblox.Enum
env.globals.UDim2 = roblox.UDim2
env.globals.Color3 = roblox.Color3
env.globals.CFrame = roblox.CFrame
env.globals.Vector3 = roblox.Vector3

local Wardrobe = env.require(env.Server.World.Wardrobe)
local Config = env.require(env.Shared.Config)
local Units = env.require(env.Shared.Units)

local Color3 = roblox.Color3
local Enum = roblox.Enum
local CFrame = roblox.CFrame

local hitbox = Config.require("ballistics", "hitbox")
local radiusMetres = hitbox.bodyWidthMetres * 0.5
local heightMetres = hitbox.bodyHeightMetres

--[[
	How far out of the capsule a part reaches, in metres.

	Shape matters, and getting it wrong inflates the answer. Wardrobe builds the
	chest and every camo patch as Ball parts, and the corner of a ball's bounding
	box is not on the ball -- measuring that way reported a pro's chest 6cm
	outside the capsule when it is 1cm outside. Blocks are measured to the corner
	of their footprint, which for a block IS reachable; balls are measured as the
	ellipsoid they actually render as.

	Rotation is projected onto world X/Z for blocks. Balls and cylinders here are
	axis-aligned, and are measured as such.
]]
local function radialMetres(part: any): number
	local cf = part.CFrame
	local size = part.Size
	local p = cf.Position
	local distance = math.sqrt(p.X * p.X + p.Z * p.Z)

	if part.Shape == Enum.PartType.Ball then
		-- Support of an axis-aligned ellipsoid along the outward direction.
		local a, c = size.X / 2, size.Z / 2
		if distance < 1e-6 then
			return Units.studsToMetres(math.max(a, c))
		end
		local ux, uz = p.X / distance, p.Z / distance
		local support = math.sqrt((a * ux) ^ 2 + (c * uz) ^ 2)
		return Units.studsToMetres(distance + support)
	end

	local right, up, look = cf.RightVector, cf.UpVector, cf.LookVector
	local halfX = 0.5 * (math.abs(right.X) * size.X + math.abs(up.X) * size.Y + math.abs(look.X) * size.Z)
	local halfZ = 0.5 * (math.abs(right.Z) * size.X + math.abs(up.Z) * size.Y + math.abs(look.Z) * size.Z)
	local outX = math.abs(p.X) + halfX
	local outZ = math.abs(p.Z) + halfZ
	return Units.studsToMetres(math.sqrt(outX * outX + outZ * outZ))
end

--- Top of the part in world space, in metres.
local function topMetres(part: any): number
	local cf = part.CFrame
	local size = part.Size
	local right, up, look = cf.RightVector, cf.UpVector, cf.LookVector
	local halfY = 0.5 * (math.abs(right.Y) * size.X + math.abs(up.Y) * size.Y + math.abs(look.Y) * size.Z)
	return Units.studsToMetres(cf.Position.Y + halfY)
end

local outfits = Config.get("wardrobe").outfits
local names: { string } = {}
for name in pairs(outfits) do
	table.insert(names, name)
end
table.sort(names)

-- Only the outfits an enemy actually wears are shot at; civilians stand in the
-- hub and are never a target, so they are measured but never failed.
local COMBATANT: { [string]: boolean } = {
	botRec = true, botAmateur = true, botSemipro = true, botPro = true, botMarshal = true,
}

--- Builds a character exactly the way BotAvatar does, then stands it up.
local function buildStanding(name: string): Model
	local model = roblox.Instance.new("Model")
	local build = Wardrobe.buildOf(name)
	local body = Wardrobe.body(model, {
		build = build,
		torsoColour = Color3.fromRGB(200, 80, 60),
		limbColour = Color3.fromRGB(60, 60, 70),
		skinColour = Color3.fromRGB(198, 164, 132),
		handsForward = COMBATANT[name] == true,
		face = COMBATANT[name] ~= true,
	})
	local worn = Wardrobe.dress(name, model, build.height)
	-- Feet on the ground at the origin, which is where the capsule stands.
	local base = CFrame.new()
	body.pose(base)
	Wardrobe.place(worn, body.anchors(base))
	return model
end

print("\27[1mcheck-hitbox\27[0m")
print(string.format("  capsule: radius %.3f m, height %.3f m", radiusMetres, heightMetres))
print()
print(string.format("  %-14s %7s %7s %8s   %s", "outfit", "reach", "core", "top", "worst parts"))

local failures = 0
local worstName, worstOver = "", 0

for _, name in ipairs(names) do
	local ok, model = pcall(buildStanding, name)
	if not ok then
		print(string.format("  %-14s  \27[31mfailed to build: %s\27[0m", name, tostring(model)))
		failures += 1
		continue
	end

	--[[
		An outstretched arm or a marker held forward sitting outside a capsule is
		normal shooter design and is reported, not failed. What must not happen is
		the part of the body a player AIMS at -- the torso and the head -- sitting
		outside the capsule, or any geometry standing above its top, because a
		mask hit is what unlocks camos and a headshot that cannot land is a lie.
	]]
	local function isCore(partName: string): boolean
		return string.find(partName, "Torso") ~= nil
			or string.find(partName, "Chest") ~= nil
			or string.find(partName, "Head") ~= nil
			or string.find(partName, "Mask") ~= nil
			or string.find(partName, "Helmet") ~= nil
	end

	local reach, highest = 0, -math.huge
	local coreReach = 0
	local worstPart, tallestPart, worstCorePart = "", "", ""
	for _, d in ipairs((model :: any):GetDescendants()) do
		if d:IsA("BasePart") then
			local r, hi = radialMetres(d), topMetres(d)
			if r > reach then
				reach = r
				worstPart = d.Name
			end
			if isCore(d.Name) and r > coreReach then
				coreReach = r
				worstCorePart = d.Name
			end
			if hi > highest then
				highest = hi
				tallestPart = d.Name
			end
		end
	end

	local combatant = COMBATANT[name] == true
	local coreOver = coreReach - radiusMetres
	local aboveTop = highest - heightMetres

	print(string.format("  %-14s %7.3f %7.3f %8.3f   reach:%s  top:%s",
		name, reach, coreReach, highest, worstPart, tallestPart))

	if not combatant then
		continue
	end

	if coreOver > 0.005 then
		failures += 1
		print(string.format("      \27[31m%s reaches %.0f cm outside the capsule -- aimed-at body is not hittable\27[0m",
			worstCorePart, coreOver * 100))
		if coreOver > worstOver then
			worstOver, worstName = coreOver, name
		end
	end

	if aboveTop > 0.02 then
		failures += 1
		print(string.format("      \27[31m%s stands %.0f cm above the capsule top (%.3f m vs %.3f m)\27[0m",
			tallestPart, aboveTop * 100, highest, heightMetres))
		if aboveTop > worstOver then
			worstOver, worstName = aboveTop, name
		end
	end
end

print()
if failures > 0 then
	print(`\27[33m{failures} deviation(s) between a visible body and the capsule it is shot at\27[0m`)
	print(`  worst: {worstName}, {string.format("%.0f", worstOver * 100)} cm of aimed-at body outside the hitbox`)
end
if failures == 0 then
	print("\27[32mevery combatant's visible body is inside the capsule the server shoots at\27[0m")
end
