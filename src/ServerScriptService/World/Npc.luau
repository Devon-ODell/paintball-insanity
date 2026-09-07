--!strict
--[[
	Npc -- the people standing around The Landing.

	Bodies built from the same rounded primitives as BotAvatar, but in civilian
	shapes: no masks, no markers, different silhouettes so you can tell Marge
	from Tildy across the clearing. Each gets a nameplate, a role line and a
	ProximityPrompt.

	They are scenery with a conversation attached. No NPC ever moves, fights, or
	exists inside a match -- the hub is the only place they are.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Units = require(ReplicatedStorage.Shared.Units)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.scope("LiveRound.Hub")

local Npc = {}

export type Handle = {
	id: string,
	displayName: string,
	model: Model,
	prompt: ProximityPrompt,
	position: Vector3,
	setAvailable: (Handle, boolean) -> (),
}

local function shade(colour: Color3, factor: number): Color3
	return Color3.new(
		math.clamp(colour.R * factor, 0, 1),
		math.clamp(colour.G * factor, 0, 1),
		math.clamp(colour.B * factor, 0, 1)
	)
end

--[[
	Idle poses.

	Purely a set of vertical and rotational offsets, but it is what stops six
	people standing in identical T-poses around a field. Marge leans on her
	counter; Denny sits on a bench; Wheels is crouched over something.
]]
local POSES: { [string]: { lift: number, lean: number, crouch: number } } = {
	standing = { lift = 0, lean = 0, crouch = 0 },
	leaning = { lift = -0.06, lean = 0.14, crouch = 0 },
	bouncing = { lift = 0.04, lean = -0.05, crouch = 0 },
	crouched = { lift = -0.42, lean = 0.3, crouch = 0.42 },
	armsFolded = { lift = 0, lean = -0.04, crouch = 0 },
	sitting = { lift = -0.48, lean = 0.08, crouch = 0.5 },
}

function Npc.build(id: string, cfg: any, palette: { [string]: Color3 }, parent: Instance): Handle
	local hitbox = Config.require("ballistics", "hitbox")
	local body = palette[cfg.colorKey] or Color3.fromRGB(150, 150, 150)
	local accent = palette[cfg.accentKey] or shade(body, 0.7)
	local skin = Color3.fromRGB(198, 164, 132)
	local pose = POSES[cfg.idlePose] or POSES.standing

	local model = Instance.new("Model")
	model.Name = `Npc_{id}`

	local function part(name: string, size: Vector3, colour: Color3, ball: boolean?): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = Units.vectorToStuds(size)
		p.Color = colour
		p.Material = Enum.Material.SmoothPlastic
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if ball then
			p.Shape = Enum.PartType.Ball
		end
		p.Parent = model
		return p
	end

	local width = hitbox.bodyWidthMetres
	local at = Vector3.new(cfg.position[1], cfg.position[2], cfg.position[3])
	local lookAt = Vector3.new(cfg.lookAt[1], cfg.lookAt[2], cfg.lookAt[3])
	local facing = lookAt - at
	if facing.Magnitude < 1e-4 then
		facing = Vector3.new(0, 0, -1)
	end
	local flat = Vector3.new(facing.X, 0, facing.Z).Unit
	local base = CFrame.lookAt(Units.vectorToStuds(at), Units.vectorToStuds(at) + flat)

	local function place(p: BasePart, heightMetres: number, forward: number?)
		p.CFrame = base
			* CFrame.new(0, Units.metresToStuds(heightMetres + pose.lift), Units.metresToStuds(forward or 0))
			* CFrame.Angles(pose.lean, 0, 0)
	end

	local legs = part("Legs", Vector3.new(width * 0.8, hitbox.bodyHeightMetres * 0.46 * (1 - pose.crouch * 0.5), width * 0.5), accent)
	local hips = part("Hips", Vector3.new(width * 0.86, width * 0.5, width * 0.54), shade(body, 0.8), true)
	local torso = part("Torso", Vector3.new(width * 0.9, hitbox.bodyHeightMetres * 0.38, width * 0.54), body)
	local shoulders = part("Shoulders", Vector3.new(width * 1.02, hitbox.bodyHeightMetres * 0.24, width * 0.58), body, true)
	local head = part("Head", Vector3.new(0.34, 0.36, 0.34), skin, true)
	local hair = part("Hair", Vector3.new(0.36, 0.2, 0.36), shade(accent, 0.6), true)

	place(legs, hitbox.bodyHeightMetres * 0.24)
	place(hips, hitbox.bodyHeightMetres * 0.5)
	place(torso, hitbox.chestHeightMetres)
	place(shoulders, hitbox.chestHeightMetres + 0.17)
	place(head, hitbox.headTopMetres - 0.17)
	place(hair, hitbox.headTopMetres - 0.06)

	--- A silent NPC gets no nameplate role line -- the Marshal does not
	--- introduce herself and that is the whole character.
	local plate = Instance.new("BillboardGui")
	plate.Name = "Nameplate"
	plate.Size = UDim2.fromScale(9, 2.0)
	plate.StudsOffsetWorldSpace = Vector3.new(0, Units.metresToStuds(hitbox.bodyHeightMetres + 0.5), 0)
	plate.AlwaysOnTop = false
	plate.MaxDistance = Units.metresToStuds(38)
	plate.Parent = head

	local name = Instance.new("TextLabel")
	name.Size = UDim2.fromScale(1, 0.58)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.TextColor3 = Color3.fromRGB(246, 242, 230)
	name.TextStrokeTransparency = 0.4
	name.TextScaled = true
	name.Text = cfg.displayName
	name.Parent = plate

	local role = Instance.new("TextLabel")
	role.Size = UDim2.fromScale(1, 0.4)
	role.Position = UDim2.fromScale(0, 0.6)
	role.BackgroundTransparency = 1
	role.Font = Enum.Font.Gotham
	role.TextColor3 = Color3.fromRGB(186, 180, 166)
	role.TextStrokeTransparency = 0.6
	role.TextScaled = true
	role.Text = if cfg.silent then "" else cfg.role
	role.Parent = plate

	local trigger = Instance.new("Part")
	trigger.Name = "Trigger"
	trigger.Size = Units.vectorToStuds(Vector3.new(1.6, hitbox.bodyHeightMetres, 1.6))
	trigger.CFrame = base * CFrame.new(0, Units.metresToStuds(hitbox.bodyHeightMetres / 2), 0)
	trigger.Transparency = 1
	trigger.Anchored = true
	trigger.CanCollide = true
	trigger.CanQuery = false
	trigger.Parent = model

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Talk"
	prompt.ActionText = if cfg.silent then "Look" else `Talk to {cfg.displayName}`
	prompt.ObjectText = cfg.displayName
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = 0.15
	prompt.MaxActivationDistance = Units.metresToStuds(Config.require("venue", "interactionRadiusMetres"))
	prompt.RequiresLineOfSight = false
	prompt.Parent = trigger

	model.PrimaryPart = torso
	model.Parent = parent

	local handle: Handle
	handle = {
		id = id,
		displayName = cfg.displayName,
		model = model,
		prompt = prompt,
		position = at,
		setAvailable = function(_: Handle, available: boolean)
			prompt.Enabled = available
		end,
	}
	return handle
end

--- Builds everyone. Returns them keyed by id.
function Npc.buildAll(palette: { [string]: Color3 }, parent: Instance): { [string]: Handle }
	local folder = Instance.new("Folder")
	folder.Name = "People"
	folder.Parent = parent

	local out: { [string]: Handle } = {}
	local ids: { string } = {}
	for id in pairs(Config.require("npcs", "npcs")) do
		table.insert(ids, id)
	end
	-- Sorted, so the build order is deterministic and diffable.
	table.sort(ids)

	for _, id in ipairs(ids) do
		out[id] = Npc.build(id, Config.require("npcs", "npcs." .. id), palette, folder)
	end
	log.info(`{#ids} people at the landing`)
	return out
end

return Npc
