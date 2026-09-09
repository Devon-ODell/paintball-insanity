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

local BotAvatar = {}

export type Avatar = {
	model: Model,
	root: BasePart,
	head: BasePart,
	marker: BasePart,
	nameplate: BillboardGui,
	setPosition: (Avatar, Vector3, Vector3) -> (),
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
local function buildMarkerRig(model: Model, markerColour: Color3): (BasePart, BasePart, BasePart)
	local marker = part("Marker", Units.vectorToStuds(Vector3.new(0.07, 0.11, 0.44)), markerColour, model)
	marker.Material = Enum.Material.Metal
	marker.Reflectance = 0.06

	local barrel = part("Barrel", Units.vectorToStuds(Vector3.new(0.045, 0.045, 0.36)), shade(markerColour, 0.7), model)
	barrel.Shape = Enum.PartType.Cylinder
	barrel.Material = Enum.Material.Metal

	local hopperPart = part("Hopper", Units.vectorToStuds(Vector3.new(0.13, 0.22, 0.22)), WorldBuilder.colourOf("bunkerC"), model)
	hopperPart.Shape = Enum.PartType.Cylinder

	return marker, barrel, hopperPart
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

	local root = body.byName.Torso
	local head = body.byName.Head

	local marker, barrel, hopperPart = buildMarkerRig(model, markerColour)

	model.PrimaryPart = root
	local nameplate, label = buildNameplate(root, displayName, hitbox)

	model.Parent = parent

	local lastPosition: Vector3? = nil
	local lastAt = os.clock()

	local avatar: Avatar
	avatar = {
		model = model,
		root = root,
		head = head,
		marker = marker,
		nameplate = nameplate,

		setPosition = function(_: Avatar, position: Vector3, facing: Vector3)
			--[[
				Drive the walk cycle off distance actually covered.

				BotController moves the bot by CFrame, so there is no physics to
				read a velocity from -- but the distance between this call and
				the last one is exactly what the stride needs, and tying the
				cycle to it means the feet never slide. A bot that stops
				mid-step stops mid-step.
			]]
			local now = os.clock()
			local moved = if lastPosition then (position - lastPosition).Magnitude else 0
			local elapsed = math.max(now - lastAt, 1e-3)
			body.step(moved, moved / elapsed)
			lastPosition, lastAt = position, now

			local studs = Units.vectorToStuds(position)
			local flat = Vector3.new(facing.X, 0, facing.Z)
			if flat.Magnitude < 1e-4 then
				flat = Vector3.new(0, 0, -1)
			end
			local base = CFrame.new(studs) * CFrame.lookAt(Vector3.zero, flat.Unit).Rotation

			body.pose(base)
			Wardrobe.place(worn, body.anchors(base))

			--[[
				The marker rides across the chest, hopper up, barrel forward --
				and because both hands are on it, a bot's facing is readable at a
				glance. That is the information that makes peeking a decision
				rather than a coin flip.
			]]
			marker.CFrame = root.CFrame
				* CFrame.new(Units.metresToStuds(0.14), Units.metresToStuds(0.04), -Units.metresToStuds(0.30))
			barrel.CFrame = marker.CFrame
				* CFrame.new(0, 0, -Units.metresToStuds(0.38))
				* CFrame.Angles(0, math.pi / 2, 0)
			hopperPart.CFrame = marker.CFrame
				* CFrame.new(0, Units.metresToStuds(0.15), Units.metresToStuds(0.04))
				* CFrame.Angles(0, 0, math.pi / 2)
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
