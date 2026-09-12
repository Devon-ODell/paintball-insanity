--!strict
--[[
	BotAvatar -- the visible body for a BotController.

	Deliberately not a Roblox Humanoid rig. Bots are simulated by BotController
	in metres and moved here by CFrame, so a Humanoid would add pathfinding,
	physics and replication cost for a body that is already being driven. It
	would also make the sim and the live server disagree, which is the one thing
	this project cannot afford.

	Built entirely from code -- nothing in Studio.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Fonts = require(ReplicatedStorage.Shared.Fonts)
local Units = require(ReplicatedStorage.Shared.Units)
local WorldBuilder = require(script.Parent.WorldBuilder)
local Wardrobe = require(script.Parent.Parent.World.Wardrobe)
local CombatMotion = require(ReplicatedStorage.Shared.CombatMotion)

local BotAvatar = {}

export type Avatar = {
	model: Model,
	root: BasePart,
	head: BasePart,
	marker: BasePart,
	nameplate: BillboardGui,
	--- Swing progress, 0 to 1, or nil when this bot is not mid-shove.
	swing: number?,
	setSwing: (Avatar, number?) -> (),
	setPosition: (Avatar, Vector3, Vector3, number?) -> (),
	splatter: (Avatar, Vector3, Color3?) -> (),
	destroy: (Avatar) -> (),
}

local function shade(colour: Color3, factor: number): Color3
	return Color3.new(colour.R * factor, colour.G * factor, colour.B * factor)
end

local function part(name: string, size: Vector3, colour: Color3, parent: Instance): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = colour
	p.Material = Enum.Material.SmoothPlastic
	p.Reflectance = 0
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	--[[
		Characters cast no shadows, and that has to include what they are
		carrying. World/Wardrobe already sets this false on every body part and
		every piece of kit, but the marker was built here and missed it -- so a
		bot's body cast nothing while its marker, barrel and hopper did. That is
		a marker shadow with no person under it, and twelve squads' worth of it
		is thirty-six MOVING casters, which cost far more than static ones.
	]]
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--- Which kit a tier wears. Difficulty you can read before the first shot: rec
--- turns up in rental gear, pro turns up as a squad.
local OUTFIT_FOR_TIER: { [string]: string } = {
	rec = "botRec",
	amateur = "botAmateur",
	semipro = "botSemipro",
	pro = "botPro",
	marshal = "botMarshal",
}

function BotAvatar.outfitFor(tier: string?): string
	return OUTFIT_FOR_TIER[tier or "rec"] or "botRec"
end

--[[
	The marker a bot carries: body, barrel and hopper.

	Split out of BotAvatar.new because that function had grown to 214 lines and
	nothing that long gets read.

	Returns all three parts, because `setPosition` poses each of them every frame
	and the barrel and hopper hang off the marker's own frame rather than the
	body's. Returning only the marker left the other two out of scope and every
	bot failed on the first pose -- caught immediately by check-characters.
]]
--[[
	The marker a bot carries.

	Four parts, and the fourth is the point: a body, a barrel and a hopper read
	as a bent stick at forty metres, and the air tank slung back under the grip
	is what makes the silhouette say paintball rather than "gun". It is also
	the end that lands a shove, so a bot that has closed to contact range is
	holding something the player can see it swing.

	Everything here is built-in material and colour -- this project uploads no
	assets -- so the read comes from shape and specular contrast: anodized tank,
	milled barrel, matte hopper.
]]
local function buildMarkerRig(model: Model, markerColour: Color3): (BasePart, BasePart, BasePart, BasePart)
	local marker = part("Marker", Units.vectorToStuds(Vector3.new(0.07, 0.11, 0.44)), markerColour, model)
	marker.Material = Enum.Material.Metal
	marker.Reflectance = 0.06

	local barrel = part("Barrel", Units.vectorToStuds(Vector3.new(0.045, 0.045, 0.36)), shade(markerColour, 0.7), model)
	barrel.Shape = Enum.PartType.Cylinder
	barrel.Material = Enum.Material.Metal

	local hopperPart = part("Hopper", Units.vectorToStuds(Vector3.new(0.13, 0.22, 0.22)), WorldBuilder.colourOf("bunkerC"), model)
	hopperPart.Shape = Enum.PartType.Cylinder

	local tank = part("AirTank", Units.vectorToStuds(Vector3.new(0.3, 0.13, 0.13)), shade(markerColour, 0.55), model)
	tank.Shape = Enum.PartType.Cylinder
	tank.Material = Enum.Material.Foil
	tank.Reflectance = 0.18

	return marker, barrel, hopperPart, tank
end

--[[
	The floating name, capped in range so a full squad is not twelve labels.

	Returns the label as well as the gui: `splatter` rewrites it to "-- OUT"
	when a bot is marked, and returning only the BillboardGui left that write
	pointing at a nil. check-demo-world caught it; check-characters did not,
	because nothing there stands a bot down.
]]
local function buildNameplate(root: BasePart, displayName: string, hitbox: any): (BillboardGui, TextLabel)
	local nameplate = Instance.new("BillboardGui")
	nameplate.Name = "Nameplate"
	nameplate.Size = UDim2.fromScale(6, 1.2)
	nameplate.StudsOffsetWorldSpace = Vector3.new(0, Units.metresToStuds(hitbox.bodyHeightMetres + 0.35), 0)
	nameplate.AlwaysOnTop = false
	nameplate.MaxDistance = Units.metresToStuds(45)
	nameplate.Parent = root

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = displayName
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.4
	label.TextScaled = true
	label.Font = Fonts.world("nameplate")
	label.Parent = nameplate
	return nameplate, label
end

function BotAvatar.new(id: string, displayName: string, parent: Instance, tier: string?): Avatar
	local hitbox = Config.require("ballistics", "hitbox")
	local jersey = WorldBuilder.colourOf("enemyJersey")
	local trousers = WorldBuilder.colourOf("asphalt")
	local markerColour = WorldBuilder.colourOf("rust")

	local model = Instance.new("Model")
	model.Name = id

	--[[
		A paintball player, built on the shared figure in World/Wardrobe so the
		enemy team and the people at The Landing are the same species. What is
		specific to a bot is the kit and the marker: the outfit is chosen by
		TIER, so a rec squad and a pro squad are different silhouettes and the
		player can price a round before anybody fires.
	]]
	local outfitName = BotAvatar.outfitFor(tier)
	local build = Wardrobe.buildOf(outfitName)
	local body = Wardrobe.body(model, {
		build = build,
		torsoColour = jersey,
		limbColour = trousers,
		skinColour = Color3.fromRGB(198, 164, 132),
		handsForward = true,
		-- Every tier wears a full mask; the lens is the face.
		face = false,
	})
	local worn = Wardrobe.dress(outfitName, model, build.height)

	local root = body.byName.Chest
	local head = body.byName.Head

	local marker, barrel, hopperPart, tank = buildMarkerRig(model, markerColour)

	model.PrimaryPart = root
	local nameplate, label = buildNameplate(root, displayName, hitbox)

	model.Parent = parent

	local lastPosition: Vector3? = nil
	local defaultStep = Config.get("ballistics").simulation.fixedStep

	local avatar: Avatar
	avatar = {
		model = model,
		root = root,
		head = head,
		marker = marker,
		nameplate = nameplate,
		swing = nil,

		--[[
			How far through a shove this bot is, 0 to 1, or nil.

			Set by MatchService from the controller's own clock before the pose
			is applied, so the marker swings on exactly the schedule the rule
			resolves on rather than on a second timer that could drift.
		]]
		setSwing = function(self: Avatar, progress: number?)
			self.swing = progress
		end,

		setPosition = function(self: Avatar, position: Vector3, facing: Vector3, dt: number?)
			--[[
				Drive the walk cycle off distance actually covered.

				BotController moves the bot by CFrame, so there is no physics to
				read a velocity from -- but the distance between this call and
				the last one is exactly what the stride needs, and tying the
				cycle to it means the feet never slide. A bot that stops
				mid-step stops mid-step.
			]]
			local moved = if lastPosition then (position - lastPosition).Magnitude else 0
			-- Catch-up ticks can run back-to-back: CPU time is not movement time.
			local elapsed = math.max(dt or defaultStep, 1e-6)
			body.step(moved, moved / elapsed)
			lastPosition = position

			local studs = Units.vectorToStuds(position)
			local flat = Vector3.new(facing.X, 0, facing.Z)
			if flat.Magnitude < 1e-4 then
				flat = Vector3.new(0, 0, -1)
			end
			local base = CFrame.new(studs) * CFrame.lookAt(Vector3.zero, flat.Unit).Rotation

			--- Poses the figure and hands back the frames its clothes hang on.
			local frames = body.anchors(base)
			Wardrobe.place(worn, frames)

			--[[
				The marker is held IN THE HANDS.

				It used to be placed off the chest at a constant, which meant it
				floated at a fixed spot near the torso while the arms were
				somewhere else entirely -- and when the arms started articulating
				the constant it was measured against stopped existing. The grip
				hand is where a marker is: taking the POSITION from the hand and
				the ORIENTATION from the body is what keeps it level while still
				travelling with the arm.

				Both hands are on it, which is what makes a bot's facing readable
				at a glance -- the information that makes peeking a decision
				rather than a coin flip.
			]]
			--[[
				And when the bot shoves, the marker actually swings.

				The pose comes from the SAME timeline the first-person swing
				reads, so the two views cannot describe different attacks, and it
				runs on the controller's clock rather than a second timer. Before
				this, a bot at contact range took a player out while standing
				perfectly still -- the commit delay exists to be seen, and a
				warning nobody can see is not a warning.
			]]
			local swingPose = if self.swing then CombatMotion.swing(self.swing) else nil
			local grip = frames.handsR or frames.hands
			marker.CFrame = CFrame.new(grip.Position) * base.Rotation
				* CFrame.new(0, Units.metresToStuds(0.06), -Units.metresToStuds(0.06))
				* (if swingPose
					then CFrame.new(Units.vectorToStuds(swingPose.marker.Position)) * swingPose.marker.Rotation
					else CFrame.identity)
			barrel.CFrame = marker.CFrame
				* CFrame.new(0, 0, -Units.metresToStuds(0.38))
				* CFrame.Angles(0, math.pi / 2, 0)
			hopperPart.CFrame = marker.CFrame
				* CFrame.new(0, Units.metresToStuds(0.15), Units.metresToStuds(0.04))
				* CFrame.Angles(0, 0, math.pi / 2)
			-- Slung back and down under the grip, angled into the shoulder, the
			-- way a tank actually sits. Posed here with the rest of the rig:
			-- splitting this builder once already left a part in scope for the
			-- assembly and out of scope for the pose.
			tank.CFrame = marker.CFrame
				* CFrame.new(0, -Units.metresToStuds(0.1), Units.metresToStuds(0.3))
				* CFrame.Angles(math.rad(-10), math.pi / 2, 0)
		end,

		--[[
			Marks the avatar and stands it down. Paint splatter only -- no
			ragdoll, no injury, no death. The bot is hit, marked, and walks off,
			which is both the paintball rule and the content rating.
		]]
		splatter = function(self: Avatar, at: Vector3, paintColour: Color3?)
			local splat = Instance.new("Part")
			splat.Size = Units.vectorToStuds(Vector3.new(0.22, 0.05, 0.22))
			splat.Shape = Enum.PartType.Ball
			splat.Color = paintColour or WorldBuilder.colourOf("bunkerC")
			splat.Material = Enum.Material.SmoothPlastic
			splat.Anchored = true
			splat.CanCollide = false
			splat.CanQuery = false
			-- Paint on a player, so it moves with the player: the same rule as
			-- every other part of a character, and a caster nobody would see.
			splat.CastShadow = false
			splat.CFrame = CFrame.new(Units.vectorToStuds(at))
			splat.Parent = self.model

			-- Body, kit and marker all fade together. A bot standing down in a
			-- solid helmet over a ghost torso would read as a rendering bug.
			for _, descendant in ipairs(self.model:GetDescendants()) do
				if descendant:IsA("BasePart") and descendant ~= splat then
					descendant.Transparency = 0.55
				end
			end
			label.Text = `{displayName} — OUT`
			label.TextColor3 = Color3.fromRGB(190, 190, 190)
		end,

		destroy = function(self: Avatar)
			self.model:Destroy()
		end,
	}
	return avatar
end

return BotAvatar
