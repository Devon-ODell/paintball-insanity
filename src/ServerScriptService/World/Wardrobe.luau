--!strict
--[[
	Wardrobe -- one set of clothes, two kinds of wearer.

	The people at The Landing (World/Npc) and the enemy team (Match/BotAvatar)
	were each growing their own pile of body parts, which is how you end up with
	six NPCs who are one silhouette in six colours. Both dress from here now.

	The contract is deliberately small. A wearer builds its own body and hands
	over a table of ANCHOR frames -- head, chest, hips, legs, feet. `dress`
	returns a flat list of { part, anchor, offset }, and the wearer decides when
	to place them. That is what lets the same outfit work on a static NPC placed
	once at build time and on a bot whose body is re-CFramed every tick.

	Everything here is fashion. No piece carries a stat, changes a hitbox, or is
	a firearm or firearm accessory -- see Data/wardrobe.json's `_rating` note and
	the audit in LiveRules.spec.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Units = require(ReplicatedStorage.Shared.Units)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.scope("LiveRound.World")

local Wardrobe = {}

export type Anchor = "head" | "chest" | "hips" | "legs" | "feet"

export type Worn = {
	part: BasePart,
	anchor: Anchor,
	--- Offset from the anchor, already converted to studs.
	offset: CFrame,
}

export type Build = { shoulders: number, height: number }

local MATERIAL: { [string]: Enum.Material } = {
	SmoothPlastic = Enum.Material.SmoothPlastic,
	Metal = Enum.Material.Metal,
	Glass = Enum.Material.Glass,
	Neon = Enum.Material.Neon,
	Fabric = Enum.Material.Fabric,
	Plastic = Enum.Material.Plastic,
}

local function data(): any
	return Config.get("wardrobe")
end

--- Palette lookup with the outfit's own overrides layered on top.
local function colourOf(key: string, tint: { [string]: { number } }?): Color3
	local override = tint and tint[key]
	local rgb = override or data().palette[key]
	if not rgb then
		return Color3.fromRGB(200, 200, 200)
	end
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

Wardrobe.colourOf = colourOf

function Wardrobe.outfit(name: string): any?
	return data().outfits[name]
end

--- Proportion nudges for a named outfit, defaulted. Six people should be six
--- silhouettes, and a few percent on shoulders and height does most of that.
function Wardrobe.buildOf(name: string?): Build
	local entry = name and data().outfits[name]
	local build = entry and entry.build
	return {
		shoulders = (build and build.shoulders) or 1,
		height = (build and build.height) or 1,
	}
end

--- Every piece name an outfit asks for. Exposed so specs can check the data
--- without constructing a single Instance.
function Wardrobe.piecesOf(name: string): { string }
	local entry = data().outfits[name]
	if not entry then
		return {}
	end
	return entry.wears
end

function Wardrobe.hasPiece(name: string): boolean
	return data().pieces[name] ~= nil
end

function Wardrobe.outfitNames(): { string }
	local out: { string } = {}
	for id in pairs(data().outfits) do
		table.insert(out, id)
	end
	table.sort(out)
	return out
end

--[[
	Dresses a wearer.

	`parent` receives the parts; `scale` stretches the outfit with the body so a
	shorter NPC does not wear a full-size helmet. Returns the worn list in draw
	order, which is also the order the data declares -- so an outfit that layers
	a plate carrier over a jersey just lists the jersey first.
]]
function Wardrobe.dress(outfitName: string, parent: Instance, scale: number?): { Worn }
	local entry = data().outfits[outfitName]
	if not entry then
		log.warn(`no outfit named '{outfitName}'`)
		return {}
	end
	local pieces = data().pieces
	local tint = entry.tint
	local stretch = scale or 1
	local worn: { Worn } = {}

	for _, pieceName in ipairs(entry.wears) do
		local piece = pieces[pieceName]
		if not piece then
			log.warn(`outfit '{outfitName}' wants piece '{pieceName}', which does not exist`)
			continue
		end
		for _, spec in ipairs(piece) do
			local part = Instance.new("Part")
			part.Name = `{pieceName}_{spec.name}`
			part.Size = Units.vectorToStuds(
				Vector3.new(spec.size[1], spec.size[2], spec.size[3]) * stretch
			)
			part.Color = colourOf(spec.colorKey, tint)
			part.Material = MATERIAL[spec.material or "SmoothPlastic"] or Enum.Material.SmoothPlastic
			part.Reflectance = spec.reflectance or 0
			part.Transparency = spec.transparency or 0
			part.Anchored = true
			--[[
				Clothes never collide and are never queryable. A hit is decided
				by Ballistics against the hitbox, never by a helmet's part -- if
				a night vision tube could catch a paintball, buying a hat would
				change the game, and nothing cosmetic may.
			]]
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			if spec.shape == "Ball" then
				part.Shape = Enum.PartType.Ball
			elseif spec.shape == "Cylinder" then
				part.Shape = Enum.PartType.Cylinder
			end
			part.Parent = parent

			local at = Vector3.new(spec.at[1], spec.at[2], spec.at[3]) * stretch
			local offset = CFrame.new(Units.vectorToStuds(at))
			local rot = spec.rotationDeg
			if rot then
				offset = offset * CFrame.Angles(math.rad(rot[1]), math.rad(rot[2]), math.rad(rot[3]))
			end
			table.insert(worn, { part = part, anchor = spec.anchor :: Anchor, offset = offset })
		end
	end
	return worn
end

--------------------------------------------------------------------------------
-- The body underneath
--------------------------------------------------------------------------------

export type Body = {
	parts: { BasePart },
	--- Named so the wearer can pose or splatter individual sections.
	byName: { [string]: BasePart },
	--- Anchor frames for a given base CFrame, ready to pass to `place`.
	anchors: (CFrame) -> { [string]: CFrame },
	--- Stands the figure up at `base`. Shared so an NPC and an enemy hold
	--- themselves the same way.
	pose: (CFrame) -> (),
}

export type BodyOptions = {
	build: Build,
	torsoColour: Color3,
	limbColour: Color3,
	skinColour: Color3,
	--- Bots hold a marker in both hands; people at the hub mostly do not.
	handsForward: boolean?,
}

--[[
	Builds the figure the clothes hang on.

	Shared so an NPC and an enemy are the same species. Before this the two
	files each grew their own pile of primitives and the hub people ended up
	visibly shorter and boxier than the players on the field.

	Arms are the important addition. A torso with no arms reads as a bollard at
	any distance, and this is a game about reading a human silhouette at 40m.
]]
function Wardrobe.body(parent: Instance, options: BodyOptions): Body
	local hitbox = Config.require("ballistics", "hitbox")
	local build = options.build
	local width = hitbox.bodyWidthMetres
	local height = build.height

	local parts: { BasePart } = {}
	local byName: { [string]: BasePart } = {}

	local function piece(name: string, size: Vector3, colour: Color3, ball: boolean?): BasePart
		local part = Instance.new("Part")
		part.Name = name
		part.Size = Units.vectorToStuds(size)
		part.Color = colour
		part.Material = Enum.Material.SmoothPlastic
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		if ball then
			part.Shape = Enum.PartType.Ball
		end
		part.Parent = parent
		table.insert(parts, part)
		byName[name] = part
		return part
	end

	local shoulderWidth = width * 1.04 * build.shoulders
	piece("Torso", Vector3.new(width * 0.90, hitbox.bodyHeightMetres * 0.34 * height, width * 0.52), options.torsoColour)
	piece("Chest", Vector3.new(shoulderWidth, hitbox.bodyHeightMetres * 0.22 * height, width * 0.58), options.torsoColour, true)
	piece("Hips", Vector3.new(width * 0.86, width * 0.48, width * 0.52), options.limbColour, true)
	piece("Thighs", Vector3.new(width * 0.80, hitbox.bodyHeightMetres * 0.26 * height, width * 0.46), options.limbColour)
	piece("Shins", Vector3.new(width * 0.70, hitbox.bodyHeightMetres * 0.22 * height, width * 0.40), options.limbColour)
	piece("Neck", Vector3.new(0.13, 0.09, 0.13), options.skinColour)
	piece("Head", Vector3.new(0.34, 0.36, 0.35), options.skinColour, true)

	-- Upper and lower arms, hung off the shoulders.
	for _, side in ipairs({ "L", "R" }) do
		piece(`UpperArm{side}`, Vector3.new(width * 0.24, hitbox.bodyHeightMetres * 0.18 * height, width * 0.26), options.torsoColour)
		piece(`Forearm{side}`, Vector3.new(width * 0.21, hitbox.bodyHeightMetres * 0.16 * height, width * 0.23), options.limbColour)
		piece(`Hand{side}`, Vector3.new(0.12, 0.12, 0.13), options.skinColour, true)
	end

	local handsForward = options.handsForward == true

	local function anchors(base: CFrame): { [string]: CFrame }
		local function at(metres: number, forward: number?): CFrame
			return base * CFrame.new(0, Units.metresToStuds(metres * height), Units.metresToStuds(forward or 0))
		end
		return {
			feet = at(0.08),
			legs = at(hitbox.bodyHeightMetres * 0.28),
			hips = at(hitbox.bodyHeightMetres * 0.50),
			chest = at(hitbox.chestHeightMetres),
			head = at(hitbox.headTopMetres - 0.17),
		}
	end

	--[[
		Poses the body against a base frame. Kept here rather than in the
		wearers so an NPC and a bot stand the same way -- the arms in particular,
		which are the part most likely to drift apart if written twice.
	]]
	local function pose(base: CFrame)
		local frames = anchors(base)
		byName.Thighs.CFrame = frames.legs
		byName.Shins.CFrame = frames.legs * CFrame.new(0, -Units.metresToStuds(hitbox.bodyHeightMetres * 0.22 * height), 0)
		byName.Hips.CFrame = frames.hips
		byName.Torso.CFrame = frames.chest
		byName.Chest.CFrame = frames.chest * CFrame.new(0, Units.metresToStuds(0.16 * height), 0)
		byName.Neck.CFrame = frames.head * CFrame.new(0, -Units.metresToStuds(0.17), 0)
		byName.Head.CFrame = frames.head
		for _, side in ipairs({ "L", "R" }) do
			local sign = if side == "L" then -1 else 1
			local shoulder = frames.chest
				* CFrame.new(Units.metresToStuds(sign * shoulderWidth * 0.56), Units.metresToStuds(0.12 * height), 0)
			byName[`UpperArm{side}`].CFrame = shoulder * CFrame.new(0, -Units.metresToStuds(0.16 * height), 0)
			if handsForward then
				-- Both hands up on the marker, elbows in. This is the shape that
				-- reads as "armed and looking at you" from across a field.
				byName[`Forearm{side}`].CFrame = shoulder
					* CFrame.new(Units.metresToStuds(-sign * 0.06), -Units.metresToStuds(0.30 * height), -Units.metresToStuds(0.20))
				byName[`Hand{side}`].CFrame = shoulder
					* CFrame.new(Units.metresToStuds(-sign * 0.08), -Units.metresToStuds(0.36 * height), -Units.metresToStuds(0.32))
			else
				byName[`Forearm{side}`].CFrame = shoulder * CFrame.new(0, -Units.metresToStuds(0.40 * height), 0)
				byName[`Hand{side}`].CFrame = shoulder * CFrame.new(0, -Units.metresToStuds(0.54 * height), 0)
			end
		end
	end

	return {
		parts = parts,
		byName = byName,
		anchors = anchors,
		pose = pose,
	}
end

--- Places every worn piece against the wearer's current anchor frames.
function Wardrobe.place(worn: { Worn }, anchors: { [string]: CFrame })
	for _, item in ipairs(worn) do
		local frame = anchors[item.anchor]
		if frame then
			item.part.CFrame = frame * item.offset
		end
	end
end

--- Fades an outfit with the body it is on, for the paint-splattered walk-off.
function Wardrobe.setTransparency(worn: { Worn }, value: number)
	for _, item in ipairs(worn) do
		item.part.Transparency = value
	end
end

return Wardrobe
