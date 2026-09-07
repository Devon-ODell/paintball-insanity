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
local Units = require(ReplicatedStorage.Shared.Units)
local WorldBuilder = require(script.Parent.WorldBuilder)

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
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--- A rounded limb or torso section. Paintball players are people in bulky
--- jerseys, not boxes, and the silhouette reads much better rounded.
local function capsule(name: string, size: Vector3, colour: Color3, parent: Instance): BasePart
	local p = part(name, size, colour, parent)
	p.Shape = Enum.PartType.Ball
	return p
end

function BotAvatar.new(id: string, displayName: string, parent: Instance): Avatar
	local hitbox = Config.require("ballistics", "hitbox")
	local jersey = WorldBuilder.colourOf("enemyJersey")
	local mask = WorldBuilder.colourOf("netting")
	local trousers = WorldBuilder.colourOf("asphalt")
	local lensColour = WorldBuilder.colourOf("bunkerB")
	local hopperColour = WorldBuilder.colourOf("bunkerC")
	local markerColour = WorldBuilder.colourOf("rust")

	local model = Instance.new("Model")
	model.Name = id

	--[[
		A paintball player: bulky jersey over a rounded torso, padded shoulders,
		a full-face mask with a tinted lens, and a marker held across the chest.
		Built from rounded primitives so the silhouette reads as a person at
		40 m, which is the range the whole game is about.
	]]
	local torsoHeight = hitbox.bodyHeightMetres * 0.40
	local width = hitbox.bodyWidthMetres

	local root = part("Torso", Units.vectorToStuds(Vector3.new(width * 0.92, torsoHeight, width * 0.56)), jersey, model)

	-- Rounded shoulders and hips soften the box into a body.
	local shoulders = capsule(
		"Shoulders",
		Units.vectorToStuds(Vector3.new(width * 1.04, torsoHeight * 0.62, width * 0.6)),
		jersey,
		model
	)
	local hips = capsule(
		"Hips",
		Units.vectorToStuds(Vector3.new(width * 0.9, torsoHeight * 0.5, width * 0.56)),
		shade(jersey, 0.82),
		model
	)

	local legs = part(
		"Legs",
		Units.vectorToStuds(Vector3.new(width * 0.82, hitbox.bodyHeightMetres * 0.46, width * 0.5)),
		trousers,
		model
	)
	local knees = capsule(
		"Knees",
		Units.vectorToStuds(Vector3.new(width * 0.84, width * 0.5, width * 0.52)),
		shade(trousers, 0.85),
		model
	)

	-- Mask: a rounded head with a darker, glossy lens across the front.
	local head = capsule("Head", Units.vectorToStuds(Vector3.new(0.36, 0.38, 0.38)), mask, model)
	local lens = part("Lens", Units.vectorToStuds(Vector3.new(0.30, 0.15, 0.10)), lensColour, model)
	lens.Material = Enum.Material.Glass
	lens.Reflectance = 0.35
	local hopperPart = capsule("Hopper", Units.vectorToStuds(Vector3.new(0.24, 0.22, 0.30)), hopperColour, model)

	local marker = part("Marker", Units.vectorToStuds(Vector3.new(0.07, 0.11, 0.58)), markerColour, model)
	marker.Material = Enum.Material.Metal
	marker.Reflectance = 0.06
	local barrel = part("Barrel", Units.vectorToStuds(Vector3.new(0.045, 0.045, 0.34)), shade(markerColour, 0.7), model)
	barrel.Shape = Enum.PartType.Cylinder
	barrel.Material = Enum.Material.Metal

	model.PrimaryPart = root

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
	label.Font = Enum.Font.GothamBold
	label.Parent = nameplate

	model.Parent = parent

	local avatar: Avatar
	avatar = {
		model = model,
		root = root,
		head = head,
		marker = marker,
		nameplate = nameplate,

		setPosition = function(_: Avatar, position: Vector3, facing: Vector3)
			local studs = Units.vectorToStuds(position)
			local flat = Vector3.new(facing.X, 0, facing.Z)
			if flat.Magnitude < 1e-4 then
				flat = Vector3.new(0, 0, -1)
			end
			local look = CFrame.lookAt(Vector3.zero, flat.Unit)

			local function at(heightMetres: number): CFrame
				return CFrame.new(studs + Vector3.new(0, Units.metresToStuds(heightMetres), 0)) * look.Rotation
			end

			legs.CFrame = at(hitbox.bodyHeightMetres * 0.24)
			knees.CFrame = at(hitbox.bodyHeightMetres * 0.30)
			hips.CFrame = at(hitbox.bodyHeightMetres * 0.50)
			root.CFrame = at(hitbox.chestHeightMetres)
			shoulders.CFrame = at(hitbox.chestHeightMetres + 0.16)
			head.CFrame = at(hitbox.headTopMetres - 0.17)

			-- The lens faces where the bot is looking, so the player can read a
			-- bot's facing at a glance -- which is the information that makes
			-- peeking a decision rather than a coin flip.
			lens.CFrame = head.CFrame * CFrame.new(0, Units.metresToStuds(0.01), Units.metresToStuds(-0.17))
			hopperPart.CFrame = head.CFrame * CFrame.new(0, Units.metresToStuds(-0.08), Units.metresToStuds(0.2))

			marker.CFrame = root.CFrame
				* CFrame.new(Units.metresToStuds(0.2), Units.metresToStuds(0.02), Units.metresToStuds(-0.36))
			barrel.CFrame = marker.CFrame
				* CFrame.new(0, 0, Units.metresToStuds(-0.42))
				* CFrame.Angles(0, math.pi / 2, 0)
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
			splat.CFrame = CFrame.new(Units.vectorToStuds(at))
			splat.Parent = self.model

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
