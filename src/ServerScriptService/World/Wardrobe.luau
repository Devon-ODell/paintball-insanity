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

--[[
	Where a piece of clothing hangs.

	`elbows` and `hands` are new, and they exist because gloves and elbow pads
	were anchored to the CHEST at a fixed sideways offset -- so they hung in mid
	air at the spot an arm used to be while the arm itself swung out from under
	them. A joint frame is the only honest anchor for a thing worn on a joint.
]]
export type Anchor = "head" | "chest" | "hips" | "legs" | "feet" | "elbows" | "hands"

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
	anchors: (CFrame, Posture?) -> { [string]: CFrame },
	--- Stands the figure up at `base`, in an optional idle posture. Shared so an
	--- NPC and an enemy hold themselves the same way.
	pose: (CFrame, Posture?) -> (),
	--- Advances the walk cycle by distance travelled and current speed.
	step: (number, number) -> (),
}

--[[
	An idle posture: how far into a crouch or a sit, and how far leaned over.

	All three used to be a rigid offset applied to the whole figure -- `crouched`
	translated it 0.63 m down, which put its legs under the floor, and a lean
	rotated it about its feet like a falling statue. A body with joints bends
	them instead.
]]
export type Posture = { crouch: number?, sit: number?, lean: number? }

export type BodyOptions = {
	build: Build,
	torsoColour: Color3,
	limbColour: Color3,
	skinColour: Color3,
	--- Bots hold a marker in both hands; people at the hub mostly do not.
	handsForward: boolean?,
	--[[
		Whether to build a face.

		The enemy team wears full masks, and a lens covers the eyes exactly as it
		should -- so building them costs four parts a bot that nobody can ever
		see, forty-eight across a full squad, rebuilt at every round boundary.
		Civilians at The Landing get one; anyone in a mask does not.
	]]
	face: boolean?,
}


--------------------------------------------------------------------------------
-- The figure the clothes hang on
--------------------------------------------------------------------------------

--[[
	A skeleton, posed by rotating joints.

	What this replaces was thirteen ellipsoids stacked in a column that TRANSLATED
	fore and aft and never rotated once. A thigh that slides instead of pivoting
	is not a leg, it is a floating sausage, and a body made of them reads as a
	blob no matter how good the kit on it is or how carefully the stride is timed
	to the ground. It was also 3.9 heads tall, which is a bobblehead.

	So: real joint heights from `wardrobe.skeleton` at canonical human proportions,
	and forward kinematics down each limb. The hip rotates, the knee flexes off
	the thigh's frame, the ankle off the shin's. Each bone is an ellipsoid whose
	LOCAL Y IS THE BONE -- so orienting the joint frame orients the limb, and a
	segment sized a little longer than its bone overlaps its neighbour at the
	joint and reads continuous without a separate ball for every elbow.

	Everything below is metres until it touches a CFrame.
]]

--- Standing up straight. Shared rather than allocated per pose: a bot poses
--- twelve times a frame and none of them are leaning on anything.
local EMPTY_POSTURE: Posture = {}

local function vec3(values: { number }): Vector3
	return Vector3.new(values[1], values[2], values[3])
end

--- Metres to a stud-space offset. Every position in this file is authored in
--- metres; this is the one place that stops being true.
local function offset(x: number, y: number, z: number): CFrame
	return CFrame.new(Units.metresToStuds(x), Units.metresToStuds(y), Units.metresToStuds(z))
end

export type Metrics = {
	height: number,
	shoulder: number, elbow: number, wrist: number, neckBase: number,
	hip: number, knee: number, ankle: number,
	shoulderHalf: number, hipHalf: number,
	upperArm: number, forearm: number, thigh: number, shin: number,
}

--[[
	The figure's own measurements, in metres.

	Bone lengths are the GAPS between joint heights rather than numbers of their
	own, so a joint and the bone reaching it cannot drift apart.
]]
local function metricsFor(build: Build): Metrics
	local hitbox = Config.require("ballistics", "hitbox")
	local skeleton = data().skeleton
	local j = skeleton.joints
	local w = skeleton.widths
	local h = hitbox.bodyHeightMetres * build.height
	local at = function(fraction: number): number
		return fraction * h
	end
	local shoulder, elbow, wrist = at(j.shoulderFraction), at(j.elbowFraction), at(j.wristFraction)
	local hip, knee, ankle = at(j.hipFraction), at(j.kneeFraction), at(j.ankleFraction)
	return {
		height = h,
		shoulder = shoulder, elbow = elbow, wrist = wrist,
		neckBase = at(j.neckBaseFraction),
		hip = hip, knee = knee, ankle = ankle,
		--- Width scales with the shoulders, not the height: a broader player is
		--- broader, not taller.
		shoulderHalf = w.shoulderHalfMetres * build.shoulders,
		hipHalf = w.hipHalfMetres * build.shoulders,
		upperArm = shoulder - elbow,
		forearm = elbow - wrist,
		thigh = hip - knee,
		shin = knee - ankle,
	}
end

Wardrobe.metricsFor = metricsFor


--[[
	One figure, mid-pose.

	`Wardrobe.body` was a single closure holding all of this in upvalues, and at
	370 lines nothing that long gets read -- which is how a walk cycle came to
	peak its knee flexion at mid-stance and an arm came to roll the wrong way
	without anyone noticing. Naming the state makes each pass of a pose a
	function you can check on its own.
]]
type Rig = {
	byName: { [string]: BasePart },
	m: Metrics,
	build: Build,
	human: any, gaitCfg: any, postureCfg: any, torso: any, segments: any,
	hasFace: boolean,
	carry: boolean,
	--- Advances with distance travelled, so the stride is tied to the ground
	--- rather than to a clock. `blend` fades the cycle out at a standstill.
	phase: number,
	blend: number,
	--- The anchor frames the clothes hang on, refilled by every pose.
	frames: { [string]: CFrame },
}

--- Where this leg is in the cycle. The two legs are half a cycle apart, which is
--- what makes it a walk rather than a hop.
local function legPhase(rig: Rig, side: string): number
	return rig.phase + (if side == "L" then 0 else math.pi)
end

--- Degrees of gait, faded out with the walk itself.
local function radBlend(rig: Rig, degrees: number): number
	return math.rad(degrees) * rig.blend
end

--[[
	Builds the parts. Every one of them is an ellipsoid, because a human has no
	flat planes on it and the hard-edged boxes are what read as blocks.
]]
local function buildParts(parent: Instance, options: BodyOptions, rig: Rig): { BasePart }
	local parts: { BasePart } = {}
	local byName = rig.byName
	--[[
		Cloth is cloth and skin is not.

		The whole figure used to be SmoothPlastic, which is the one material with
		no surface response at all -- twelve bots on a field, every one of them
		reading as moulded plastic. A jersey and a pair of trousers are Fabric,
		which under the current material generation has a real weave and takes
		the light differently as a bot turns; hands and head stay smooth, because
		a fabric face is worse than a plastic one.
	]]
	local function materialFor(name: string): Enum.Material
		if name == "Head" or name == "Jaw" or name == "Neck" or string.find(name, "Hand") then
			return Enum.Material.SmoothPlastic
		end
		return Enum.Material.Fabric
	end

	--- Every part on this figure is an ellipsoid. A human has no flat planes on
	--- it, and the hard-edged boxes are what made the old figure read as blocks.
	local function piece(name: string, size: Vector3, colour: Color3): BasePart
		local part = Instance.new("Part")
		part.Name = name
		part.Shape = Enum.PartType.Ball
		part.Size = Units.vectorToStuds(size)
		part.Color = colour
		part.Material = materialFor(name)
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = parent
		table.insert(parts, part)
		rig.byName[name] = part
		return part
	end

	--[[
		A bone, sized to overlap the joints at both ends.

		`bleed` is what buys away the separate ball joint an articulated figure
		normally needs at every elbow and knee: an ellipsoid a little longer than
		its bone intersects its neighbour, and the union reads as one continuous
		limb. Twelve bots on a field is twelve times whatever this costs, so
		buying four joints a limb back is worth the two lines.
	]]
	local BONE_BLEED = 1.16
	local function bone(name: string, thickness: { number }, length: number, colour: Color3): BasePart
		return piece(name, Vector3.new(thickness[1], length * BONE_BLEED, thickness[2]), colour)
	end

	local skin, cloth, limb = options.skinColour, options.torsoColour, options.limbColour

	--------------------------------------------------------------------------
	-- Build
	--------------------------------------------------------------------------

	piece("Chest", vec3(rig.torso.chestSizeMetres) * rig.build.shoulders, cloth)
	piece("Waist", vec3(rig.torso.waistSizeMetres) * rig.build.shoulders, cloth)
	piece("Pelvis", vec3(rig.torso.pelvisSizeMetres) * rig.build.shoulders, limb)
	bone("Neck", rig.segments.neck, rig.m.height * 0.048, skin)
	piece("Head", vec3(rig.human.headSizeMetres) * rig.build.height, skin)

	for _, side in ipairs({ "L", "R" }) do
		--- The deltoid is what turns a stick pushed into a torso into a
		--- shoulder. It is also the widest point of the figure, so it is the
		--- one that has to stay inside the hit capsule.
		piece(`Deltoid{side}`, vec3(rig.segments.deltoid) * rig.build.shoulders, cloth)
		bone(`UpperArm{side}`, rig.segments.upperArm, rig.m.upperArm, cloth)
		bone(`Forearm{side}`, rig.segments.forearm, rig.m.forearm, limb)
		piece(`Hand{side}`, vec3(rig.segments.hand) * rig.build.height, skin)
		bone(`Thigh{side}`, rig.segments.thigh, rig.m.thigh, limb)
		bone(`Shin{side}`, rig.segments.shin, rig.m.shin, limb)
		piece(`Foot{side}`, vec3(rig.segments.foot) * rig.build.height, limb)
	end

	--[[
		A face, and the jaw that makes the skull a skull.

		The enemy team wears full masks and a lens covers all of this exactly as
		it should, so building it costs parts on a bot nobody can ever see --
		twelve of them, rebuilt at every round boundary. Ears go with the face
		for the same reason: they are under the mask strap.
	]]

	if rig.hasFace then
		piece("Jaw", Vector3.new(rig.human.headSizeMetres[1] * 0.86, rig.human.headSizeMetres[2] * 0.44, rig.human.headSizeMetres[3] * 0.88) * rig.build.height, skin)
		piece("Nose", vec3(rig.human.noseSizeMetres), skin)
		piece("Mouth", vec3(rig.human.mouthSizeMetres), colourOf("eye"))
		for _, side in ipairs({ "L", "R" }) do
			piece(`Ear{side}`, vec3(rig.human.earSizeMetres), skin)
			piece(`Brow{side}`, vec3(rig.human.browSizeMetres), colourOf("hairDark"))
			piece(`Eye{side}`, Vector3.new(0.032, 0.041, 0.026), colourOf("eyeShine"))
			piece(`Shine{side}`, Vector3.new(0.016, 0.022, 0.016), colourOf("eye"))
		end
	end


	return parts
end


local function poseLeg(rig: Rig, root: CFrame, side: string, hipBias: number, kneeBias: number)
	local sign = if side == "L" then -1 else 1
	local a = legPhase(rig, side)
	local hipAngle = math.sin(a) * radBlend(rig, rig.gaitCfg.hipSwingDeg) + hipBias
	--[[
		Knee flexion, as a bump across the swing phase.

		The cycle runs: heel strike at a quarter turn, mid-stance at a half,
		toe-off at three quarters, mid-swing at the top. The knee is nearly
		straight reaching for heel strike, straight again under load at
		mid-stance, folds through toe-off and is at its most flexed in
		mid-swing where the foot has to clear the ground.

		A raised cosine leading the cycle by `kneeLeadDeg` puts the peak
		between toe-off and mid-swing, and `kneeSharpness` narrows it so the
		leg is straight at both ends rather than permanently half-bent.
		Getting this wrong is not subtle: peaking it at mid-stance is a knee
		collapsing under the body's weight, and peaking it at toe-off throws
		the heel so far behind the hip that the foot leaves the field of play.

		A little flexion is carried through stance as well, so the legs are
		never locked straight -- which is what reads as stilts.
	]]
	local bump = 0.5 + 0.5 * math.cos(a + math.rad(rig.gaitCfg.kneeLeadDeg))
	local kneeAngle = radBlend(rig, rig.gaitCfg.kneeSwingDeg) * bump ^ rig.gaitCfg.kneeSharpness
		+ radBlend(rig, rig.gaitCfg.kneeStanceDeg) * math.max(0, -math.cos(a))
		+ kneeBias
	local ankleAngle = math.sin(a) * radBlend(rig, rig.gaitCfg.ankleSwingDeg)

	local hip = root * offset(sign * rig.m.hipHalf, rig.m.hip, 0) * CFrame.Angles(hipAngle, 0, 0)
	rig.byName[`Thigh{side}`].CFrame = hip * offset(0, -rig.m.thigh / 2, 0)

	local knee = hip * offset(0, -rig.m.thigh, 0) * CFrame.Angles(-kneeAngle, 0, 0)
	rig.byName[`Shin{side}`].CFrame = knee * offset(0, -rig.m.shin / 2, 0)

	--[[
		The foot levels itself against the leg swinging under it -- but only
		so far. Counter-rotating the full knee flexion would put the sole
		through a hundred degrees and throw the toe half a metre clear of the
		body; a real ankle runs out of travel and the foot tucks instead.
	]]
	local limit = math.rad(rig.gaitCfg.ankleLimitDeg)
	local ankle = knee * offset(0, -rig.m.shin, 0)
		* CFrame.Angles(math.clamp(kneeAngle - hipAngle + ankleAngle, -limit, limit), 0, 0)
	local foot = vec3(rig.segments.foot) * rig.build.height
	rig.byName[`Foot{side}`].CFrame = ankle * offset(0, -rig.m.ankle * 0.42, -foot.Z * 0.30)

	rig.frames[`legs{side}`] = knee
	rig.frames[`feet{side}`] = ankle
end

local function poseArm(rig: Rig, root: CFrame, side: string)
	local sign = if side == "L" then -1 else 1
	local shoulderAngle, elbowAngle, inward
	if rig.carry then
		--[[
			Both hands on the marker, elbows in. Fixed rather than swinging:
			this is the shape that reads as "armed and looking at you" from
			across a field, and it is how a player knows which way a bot is
			facing before it fires.
		]]
		shoulderAngle = math.rad(rig.gaitCfg.carryShoulderDeg)
		elbowAngle = math.rad(rig.gaitCfg.carryElbowDeg)
		--- Toward the centre line, which is the opposite of what `* sign`
		--- gives: the left arm hangs at -X, so tucking its elbow in means
		--- rolling it toward +X.
		inward = math.rad(rig.gaitCfg.carryInwardDeg) * -sign
	else
		--- Arms swing against the leg on the same side, which is what an arm
		--- does and what makes a walk read as a walk.
		local a = legPhase(rig, if side == "L" then "R" else "L")
		shoulderAngle = math.sin(a) * radBlend(rig, rig.gaitCfg.shoulderSwingDeg)
		elbowAngle = math.rad(rig.gaitCfg.elbowBaseDeg)
			+ radBlend(rig, rig.gaitCfg.elbowSwingDeg) * math.max(0, math.sin(a))
		inward = 0
	end

	local shoulder = root * offset(sign * rig.m.shoulderHalf, rig.m.shoulder, 0)
	rig.byName[`Deltoid{side}`].CFrame = shoulder
	local upper = shoulder * CFrame.Angles(shoulderAngle, 0, inward)
	rig.byName[`UpperArm{side}`].CFrame = upper * offset(0, -rig.m.upperArm / 2, 0)

	local elbow = upper * offset(0, -rig.m.upperArm, 0) * CFrame.Angles(elbowAngle, 0, 0)
	rig.byName[`Forearm{side}`].CFrame = elbow * offset(0, -rig.m.forearm / 2, 0)

	local wristFrame = elbow * offset(0, -rig.m.forearm, 0)
	local hand = vec3(rig.segments.hand) * rig.build.height
	rig.byName[`Hand{side}`].CFrame = wristFrame * offset(0, -hand.Z * 0.34, 0)
		* CFrame.Angles(math.rad(-72), 0, 0)

	rig.frames[`elbows{side}`] = elbow
	rig.frames[`hands{side}`] = wristFrame
end

local function poseHead(rig: Rig, root: CFrame)
	local headY = Config.require("ballistics", "hitbox").headTopMetres * rig.build.height
		- rig.human.headAnchorBelowTopMetres * rig.build.height
	local head = root * offset(0, headY, 0)
	rig.byName.Head.CFrame = head
	rig.byName.Neck.CFrame = root * offset(0, (rig.m.neckBase + headY) / 2, 0)
	rig.frames.head = head

	if not rig.hasFace then
		return
	end
	local size = vec3(rig.human.headSizeMetres) * rig.build.height
	rig.byName.Jaw.CFrame = head * offset(0, -size.Y * 0.30, -size.Z * 0.10)
	rig.byName.Nose.CFrame = head * CFrame.new(Units.vectorToStuds(vec3(rig.human.noseOffsetMetres)))
	rig.byName.Mouth.CFrame = head * CFrame.new(Units.vectorToStuds(vec3(rig.human.mouthOffsetMetres)))
	for _, side in ipairs({ "L", "R" }) do
		local sign = if side == "L" then -1 else 1
		local function mirrored(values: { number }): CFrame
			return CFrame.new(Units.vectorToStuds(Vector3.new(sign * values[1], values[2], values[3])))
		end
		rig.byName[`Ear{side}`].CFrame = head * mirrored(rig.human.earOffsetMetres)
		rig.byName[`Brow{side}`].CFrame = head * mirrored(rig.human.browOffsetMetres)
		local eye = head * mirrored(rig.human.eyeOffsetMetres)
		rig.byName[`Eye{side}`].CFrame = eye
		rig.byName[`Shine{side}`].CFrame = eye * offset(sign * 0.007, 0.009, -0.009)
	end
end

--[[
	Poses the whole figure against a base frame standing on the ground.

	Kept here rather than in the wearers so an NPC and a bot stand the same
	way -- the arms in particular, which are the part most likely to drift
	apart if written twice.
]]
local function poseFigure(rig: Rig, base: CFrame, posture: Posture?)
	local p = posture or EMPTY_POSTURE
	local crouch, sit = p.crouch or 0, p.sit or 0
	local hipBias = math.rad(rig.postureCfg.crouchHipDeg * crouch + rig.postureCfg.sitHipDeg * sit)
	local kneeBias = math.rad(rig.postureCfg.crouchKneeDeg * crouch + rig.postureCfg.sitKneeDeg * sit)

	--[[
		Bent legs are shorter, so the root lifts by exactly what they lost.

		Worked out from the bias angles alone rather than from the posed
		result, so it does not bounce with the walk cycle and needs no second
		pass. A leg is the thigh's vertical drop plus the shin's: with the
		knee bending backward off the thigh, the shin's absolute pitch is
		`hip - knee`.
	]]
	local ankleY = rig.m.hip - rig.m.thigh * math.cos(hipBias)
		- rig.m.shin * math.cos(hipBias - kneeBias)
	local lift = rig.m.ankle - ankleY

	--- Two footfalls per stride, so the bob runs at double frequency. The
	--- whole figure rides on it, feet included: a pelvis that bobbed alone
	--- would need the knees to absorb it, and that is real IK for something
	--- nobody can see at four centimetres.
	local bob = -math.abs(math.cos(rig.phase)) * GAIT_BOB_METRES * rig.blend
	local root = base * offset(0, bob + lift, 0)

	--[[
		A lean bends at the WAIST.

		Rotating the whole figure about its feet tips the soles off the
		ground and reads as a statue going over. Marge leaning on her counter
		is hinged at the hip, so the pivot is the hip and everything above it
		-- torso, head, arms -- comes with it.
	]]
	local upper = root
	if (p.lean or 0) ~= 0 then
		upper = root * offset(0, rig.m.hip, 0) * CFrame.Angles(p.lean :: number, 0, 0) * offset(0, -rig.m.hip, 0)
	end

	rig.byName.Chest.CFrame = upper * offset(0, rig.torso.chestFraction * rig.m.height, 0)
	rig.byName.Waist.CFrame = upper * offset(0, rig.torso.waistFraction * rig.m.height, 0)
	rig.byName.Pelvis.CFrame = root * offset(0, rig.torso.pelvisFraction * rig.m.height, 0)
	poseHead(rig, upper)
	for _, side in ipairs({ "L", "R" }) do
		poseLeg(rig, root, side, hipBias, kneeBias)
		poseArm(rig, upper, side)
	end

	--[[
		The anchors the clothes hang on.

		`chest`, `hips` and `legs` are the static ones a shirt or a pair of
		trousers is authored against. The sided ones -- `legsL`, `feetR`,
		`handsL`, `elbowsR` -- are the live joint frames from the passes
		above, so a knee pad travels with the knee it is on and a glove
		follows the hand rather than hanging at a fixed spot off the chest,
		which is what they used to do.
	]]
	rig.frames.chest = upper * offset(0, rig.torso.chestAnchorFraction * rig.m.height, 0)
	rig.frames.hips = root * offset(0, rig.torso.hipsAnchorFraction * rig.m.height, 0)
	rig.frames.legs = root * offset(0, (rig.m.hip + rig.m.ankle) / 2, 0)
	rig.frames.feet = root * offset(0, rig.m.ankle, 0)
	rig.frames.elbows = root * offset(0, rig.m.elbow, 0)
	rig.frames.hands = root * offset(0, rig.m.wrist, 0)
end

--- The anchor frames for the pose currently standing. `pose` fills these in,
--- so it has to have run: every caller poses before it dresses.

function Wardrobe.body(parent: Instance, options: BodyOptions): Body
	local skeleton = data().skeleton
	local rig: Rig = {
		byName = {},
		m = metricsFor(options.build),
		build = options.build,
		human = data().humanStyle,
		gaitCfg = skeleton.gait,
		postureCfg = skeleton.posture,
		torso = skeleton.torso,
		segments = skeleton.segments,
		hasFace = options.face ~= false,
		carry = options.handsForward == true,
		phase = 0,
		blend = 0,
		frames = {},
	}
	local parts = buildParts(parent, options, rig)

	local function step(distanceMetres: number, speed: number)
		rig.phase = (rig.phase + distanceMetres * math.pi / GAIT_STRIDE_LENGTH_METRES) % (math.pi * 2)
		local target = math.clamp(speed / GAIT_FULL_SPEED_MPS, 0, 1)
		-- Ease in and out so starting and stopping is not a snap.
		rig.blend += (target - rig.blend) * 0.25
	end

	local function pose(base: CFrame, posture: Posture?)
		poseFigure(rig, base, posture)
	end

	--- The anchor frames for the pose currently standing, which means posing
	--- first: every caller poses before it dresses.
	local function anchors(base: CFrame, posture: Posture?): { [string]: CFrame }
		poseFigure(rig, base, posture)
		return rig.frames
	end

	return {
		parts = parts,
		byName = rig.byName,
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
