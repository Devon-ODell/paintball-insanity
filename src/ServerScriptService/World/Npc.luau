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
local Fonts = require(ReplicatedStorage.Shared.Fonts)
local Units = require(ReplicatedStorage.Shared.Units)
local Log = require(ReplicatedStorage.Shared.Log)
local Wardrobe = require(script.Parent.Wardrobe)

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
	Idle poses. What stops six people standing in identical T-poses around a
	field: Marge leans on her counter, Denny sits on a bench, Wheels is crouched
	over something.

	These used to be a vertical TRANSLATION of the whole figure, which was the
	only thing a body of rigid ellipsoids could do -- `crouched` dropped Wheels
	0.63 m and buried his legs under the yard, leaving a torso on the floor, and
	`sitting` did the same to Denny. Now the figure has knees: a crouch bends
	them and `Wardrobe.body` lifts the root by however much the bent legs
	shortened, so the feet stay on the ground. A lean bends at the waist rather
	than tipping the soles off it.
]]
local POSES: { [string]: Wardrobe.Posture } = {
	standing = {},
	leaning = { lean = 0.20 },
	bouncing = { crouch = 0.06, lean = -0.05 },
	crouched = { crouch = 0.82, lean = 0.34 },
	armsFolded = { lean = -0.05 },
	sitting = { sit = 0.94, lean = 0.10 },
}

function Npc.build(id: string, cfg: any, palette: { [string]: Color3 }, parent: Instance): Handle
	local hitbox = Config.require("ballistics", "hitbox")
	local body = palette[cfg.colorKey] or Color3.fromRGB(150, 150, 150)
	local accent = palette[cfg.accentKey] or shade(body, 0.7)
	local skin = Color3.fromRGB(198, 164, 132)
	local pose = POSES[cfg.idlePose] or POSES.standing

	local model = Instance.new("Model")
	model.Name = `Npc_{id}`

	local at = Vector3.new(cfg.position[1], cfg.position[2], cfg.position[3])
	local lookAt = Vector3.new(cfg.lookAt[1], cfg.lookAt[2], cfg.lookAt[3])
	local facing = lookAt - at
	if facing.Magnitude < 1e-4 then
		facing = Vector3.new(0, 0, -1)
	end
	local flat = Vector3.new(facing.X, 0, facing.Z).Unit
	local base = CFrame.lookAt(Units.vectorToStuds(at), Units.vectorToStuds(at) + flat)

	--[[
		Everyone at The Landing is built on the same figure as the enemy team
		(World/Wardrobe) and then dressed from their own outfit. The outfits are
		written against the dialogue: Denny is in full night-raid kit for rec
		league on a Tuesday, and the Marshal -- who never says a word -- is the
		only person on the property wearing nothing but an armband.

		The pose offsets stay here because they belong to this NPC, not to the
		wardrobe: Marge leans on her counter, Denny sits on a bench, Wheels is
		crouched over something.
	]]
	local outfitName = cfg.outfit or id
	local build = Wardrobe.buildOf(outfitName)
	local figure = Wardrobe.body(model, {
		build = build,
		torsoColour = body,
		limbColour = accent,
		skinColour = skin,
		handsForward = false,
	})
	local worn = Wardrobe.dress(outfitName, model, build.height)

	--- The posture is bent into the figure rather than applied on top of it, so
	--- a crouching person's legs are crouched and still standing on the ground.
	Wardrobe.place(worn, figure.anchors(base, pose))

	local head = figure.byName.Head
	local torso = figure.byName.Chest

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
	name.Font = Fonts.world("nameplate")
	name.TextColor3 = Color3.fromRGB(246, 242, 230)
	name.TextStrokeTransparency = 0.4
	name.TextScaled = true
	name.Text = cfg.displayName
	name.Parent = plate

	local role = Instance.new("TextLabel")
	role.Size = UDim2.fromScale(1, 0.4)
	role.Position = UDim2.fromScale(0, 0.6)
	role.BackgroundTransparency = 1
	role.Font = Fonts.world("signBody")
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
