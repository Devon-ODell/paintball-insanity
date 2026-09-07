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

--[[
	Walk cycle constants, in metres.

	`GAIT_STRIDE_LENGTH_METRES` is what stops the feet sliding: the phase
	advances with distance travelled, so at one half-cycle per 0.85m the feet
	land where the ground says they should rather than marching to a clock.
]]
local GAIT_STRIDE_LENGTH_METRES = 0.85
local GAIT_STRIDE_METRES = 0.26
local GAIT_LIFT_METRES = 0.09
local GAIT_BOB_METRES = 0.045
local GAIT_ARM_FRACTION = 0.55
local GAIT_FULL_SPEED_MPS = 3.2

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
	--- Advances the walk cycle by distance travelled and current speed.
	step: (number, number) -> (),
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
	--[[
		Legs are per-side, which they were not. One box across both legs cannot
		take a stride, so a bot could only ever slide -- and a body that slides
		reads as a prop no matter how good the kit on it is.
	]]
	for _, side in ipairs({ "L", "R" }) do
		piece(`Thigh{side}`, Vector3.new(width * 0.36, hitbox.bodyHeightMetres * 0.26 * height, width * 0.42), options.limbColour)
		piece(`Shin{side}`, Vector3.new(width * 0.31, hitbox.bodyHeightMetres * 0.22 * height, width * 0.36), options.limbColour)
	end
	piece("Neck", Vector3.new(0.13, 0.09, 0.13), options.skinColour)
	piece("Head", Vector3.new(0.34, 0.36, 0.35), options.skinColour, true)

	-- Upper and lower arms, hung off the shoulders.
	for _, side in ipairs({ "L", "R" }) do
		piece(`UpperArm{side}`, Vector3.new(width * 0.24, hitbox.bodyHeightMetres * 0.18 * height, width * 0.26), options.torsoColour)
		piece(`Forearm{side}`, Vector3.new(width * 0.21, hitbox.bodyHeightMetres * 0.16 * height, width * 0.23), options.limbColour)
		piece(`Hand{side}`, Vector3.new(0.12, 0.12, 0.13), options.skinColour, true)
	end

	local handsForward = options.handsForward == true

	--[[
		Gait.

		`phase` advances with distance travelled, so the stride is tied to the
		ground rather than to the clock -- a bot that stops mid-step stops
		mid-step instead of marching on the spot. `blend` fades the whole thing
		out when standing still.

		The swing is a translation, not a joint rotation. These are box limbs
		with no knees; swinging them about a hip would just shear them. Fore-aft
		displacement plus a lift on the forward foot reads correctly at the
		distances this game is played at, and costs one CFrame per limb.
	]]
	local gaitPhase, gaitBlend = 0, 0

	local function sideSwing(side: string): (number, number)
		local sign = if side == "L" then 1 else -1
		local swing = math.sin(gaitPhase) * sign
		local stride = swing * GAIT_STRIDE_METRES * gaitBlend
		-- Only the forward-going foot lifts.
		local lift = math.max(0, swing) * GAIT_LIFT_METRES * gaitBlend
		return stride, lift
	end

	local function anchors(base: CFrame): { [string]: CFrame }
		-- Two footfalls per stride cycle, so the bob runs at double frequency.
		local bob = -math.abs(math.cos(gaitPhase)) * GAIT_BOB_METRES * gaitBlend
		local function at(metres: number, forward: number?): CFrame
			return base
				* CFrame.new(0, Units.metresToStuds(metres * height + bob), Units.metresToStuds(forward or 0))
		end
		local frames: { [string]: CFrame } = {
			feet = at(0.08),
			legs = at(hitbox.bodyHeightMetres * 0.28),
			hips = at(hitbox.bodyHeightMetres * 0.50),
			chest = at(hitbox.chestHeightMetres),
			head = at(hitbox.headTopMetres - 0.17),
		}
		--[[
			Sided anchors, so boots and knee pads travel with the leg they are
			on. Wardrobe.place picks these up automatically for any worn part
			whose name ends in L or R.
		]]
		for _, side in ipairs({ "L", "R" }) do
			local stride, lift = sideSwing(side)
			frames[`feet{side}`] = frames.feet
				* CFrame.new(0, Units.metresToStuds(lift), -Units.metresToStuds(stride))
			frames[`legs{side}`] = frames.legs
				* CFrame.new(0, 0, -Units.metresToStuds(stride * 0.6))
		end
		return frames
	end

	--[[
		Advances the stride by how far the body actually moved.

		`stridesPerMetre` is what stops the walk cycle sliding: at one stride per
		1.1m the feet land where the ground says they should.
	]]
	local function step(distanceMetres: number, speed: number)
		gaitPhase = (gaitPhase + distanceMetres * math.pi / GAIT_STRIDE_LENGTH_METRES) % (math.pi * 2)
		local target = math.clamp(speed / GAIT_FULL_SPEED_MPS, 0, 1)
		-- Ease in and out so starting and stopping is not a snap.
		gaitBlend += (target - gaitBlend) * 0.25
	end

	--[[
		Poses the body against a base frame. Kept here rather than in the
		wearers so an NPC and a bot stand the same way -- the arms in particular,
		which are the part most likely to drift apart if written twice.
	]]
	local function pose(base: CFrame)
		local frames = anchors(base)
		for _, side in ipairs({ "L", "R" }) do
			local sign = if side == "L" then -1 else 1
			local stride, lift = sideSwing(side)
			local hip = frames.legs
				* CFrame.new(
					Units.metresToStuds(sign * width * 0.21),
					Units.metresToStuds(lift * 0.4),
					-Units.metresToStuds(stride)
				)
			byName[`Thigh{side}`].CFrame = hip
			byName[`Shin{side}`].CFrame = hip
				* CFrame.new(0, -Units.metresToStuds(hitbox.bodyHeightMetres * 0.22 * height), -Units.metresToStuds(stride * 0.35))
		end
		byName.Hips.CFrame = frames.hips
		byName.Torso.CFrame = frames.chest
		byName.Chest.CFrame = frames.chest * CFrame.new(0, Units.metresToStuds(0.16 * height), 0)
		byName.Neck.CFrame = frames.head * CFrame.new(0, -Units.metresToStuds(0.17), 0)
		byName.Head.CFrame = frames.head
		for _, side in ipairs({ "L", "R" }) do
			local sign = if side == "L" then -1 else 1
			local shoulder = frames.chest
				* CFrame.new(Units.metresToStuds(sign * shoulderWidth * 0.56), Units.metresToStuds(0.12 * height), 0)
			-- Arms swing against the leg on the same side, which is what an
			-- arm does and what makes a walk read as a walk.
			local armStride = select(1, sideSwing(if side == "L" then "R" else "L")) * GAIT_ARM_FRACTION
			byName[`UpperArm{side}`].CFrame = shoulder
				* CFrame.new(0, -Units.metresToStuds(0.16 * height), -Units.metresToStuds(armStride))
			if handsForward then
				-- Both hands up on the marker, elbows in. This is the shape that
				-- reads as "armed and looking at you" from across a field.
				byName[`Forearm{side}`].CFrame = shoulder
					* CFrame.new(Units.metresToStuds(-sign * 0.06), -Units.metresToStuds(0.30 * height), -Units.metresToStuds(0.20))
				byName[`Hand{side}`].CFrame = shoulder
					* CFrame.new(Units.metresToStuds(-sign * 0.08), -Units.metresToStuds(0.36 * height), -Units.metresToStuds(0.32))
			else
				byName[`Forearm{side}`].CFrame = shoulder
					* CFrame.new(0, -Units.metresToStuds(0.40 * height), -Units.metresToStuds(armStride * 1.5))
				byName[`Hand{side}`].CFrame = shoulder
					* CFrame.new(0, -Units.metresToStuds(0.54 * height), -Units.metresToStuds(armStride * 1.8))
			end
		end
	end

	return {
		parts = parts,
		byName = byName,
		anchors = anchors,
		pose = pose,
		step = step,
	}
end

--- Places every worn piece against the wearer's current anchor frames.
--[[
	Places every worn piece against the wearer's current anchor frames.

	A piece whose part name ends in L or R takes the sided anchor when the wearer
	offers one -- so a boot travels with the leg it is on rather than staying
	planted while the leg walks out from under it.
]]
function Wardrobe.place(worn: { Worn }, anchors: { [string]: CFrame })
	for _, item in ipairs(worn) do
		local frame = anchors[item.anchor]
		local suffix = string.sub(item.part.Name, -1)
		if suffix == "L" or suffix == "R" then
			frame = anchors[item.anchor .. suffix] or frame
		end
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
