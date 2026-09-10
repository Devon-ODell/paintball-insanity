--!strict
--[[
	Input -- first-person controller.

	Movement interacts with shooting, which is the whole point: sprinting
	multiplies the cone by 9x on every marker, so stop-to-shoot timing is a
	fundamental the game ENFORCES rather than suggests. The recovery window after
	releasing sprint is the thing the player is learning to feel, so it is
	surfaced on the HUD rather than hidden.

	This module decides intent only. The server decides outcomes.
]]

local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)
local Units = require(ReplicatedStorage.Shared.Units)

local Input = {}

local player = Players.LocalPlayer
local pointerFree = false
local leanLeft, leanRight = false, false

export type State = {
	sprinting: boolean,
	crouching: boolean,
	sliding: boolean,
	slideEndsAt: number,
	slideReadyAt: number,
	lean: number,
	firing: boolean,
	lastSprintAt: number,
	reloadRequested: boolean,
	swingRequested: boolean,
}

local state: State = {
	sprinting = false,
	crouching = false,
	sliding = false,
	slideEndsAt = 0,
	slideReadyAt = 0,
	lean = 0,
	firing = false,
	lastSprintAt = -math.huge,
	reloadRequested = false,
	swingRequested = false,
}

function Input.state(): State
	return state
end

--[[
	The stance the server should be told about.

	Reported, not enforced, on the client -- the server recomputes the spread
	from its own view of the player's velocity. Sending it anyway means the
	telemetry can see the difference between "moved and missed" and "stood still
	and missed", which are different lessons.
]]
function Input.stance(): Types.Stance
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local velocity = if root then (root :: BasePart).AssemblyLinearVelocity else Vector3.zero
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	if state.sprinting and speed > 1 then
		return "sprinting"
	elseif speed > 1 then
		return "moving"
	elseif state.crouching then
		return "crouching"
	end
	return "standing"
end

--- Seconds since the player stopped sprinting; the cone is still wide inside
--- the recovery window.
function Input.sprintRecovery(now: number): number
	local recovery = Config.require("match", "player.sprintToFireRecoverySeconds")
	local since = now - state.lastSprintAt
	return math.clamp(1 - since / recovery, 0, 1)
end

local function humanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local carrierMultiplier = 1

local function applySpeed()
	local h = humanoid()
	if not h then
		return
	end
	local cfg = Config.require("match", "player")
	local metres: number
	if state.sliding then
		metres = cfg.slideSpeedMps
	elseif state.crouching then
		metres = cfg.crouchSpeedMps
	elseif state.sprinting then
		metres = cfg.sprintSpeedMps
	else
		metres = cfg.walkSpeedMps
	end
	h.WalkSpeed = Units.metresToStuds(metres * carrierMultiplier)
end

function Input.setCarrierMultiplier(multiplier: number)
	carrierMultiplier = math.clamp(multiplier, 0, 1)
	applySpeed()
end

local function setSprint(active: boolean)
	if state.sprinting and not active then state.lastSprintAt = os.clock() end
	state.sprinting = active
end

local function released(inputState: Enum.UserInputState): boolean
	return inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel
end

local function reset()
	setSprint(false)
	state.firing, state.sliding, state.crouching = false, false, false
	state.lean, state.reloadRequested, state.swingRequested = 0, false, false
	leanLeft, leanRight = false, false
	applySpeed()
end

function Input.bind()
	local cfg = Config.require("match", "player")

	ContextActionService:BindAction("LR_Sprint", function(_, inputState)
		if pointerFree then return Enum.ContextActionResult.Pass end
		if inputState == Enum.UserInputState.Begin then
			setSprint(true)
			state.crouching = false
		elseif released(inputState) then
			setSprint(false)
		end
		applySpeed()
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL3)

	ContextActionService:BindAction("LR_Crouch", function(_, inputState)
		if pointerFree then return Enum.ContextActionResult.Pass end
		if inputState == Enum.UserInputState.Begin then
			state.crouching = true
			setSprint(false)
		elseif released(inputState) then
			state.crouching = false
		end
		applySpeed()
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.LeftControl, Enum.KeyCode.ButtonB)

	ContextActionService:BindAction("LR_Slide", function(_, inputState)
		if pointerFree then return Enum.ContextActionResult.Pass end
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		local now = os.clock()
		local h = humanoid()
		if not h or h.MoveDirection.Magnitude == 0 or h.FloorMaterial == Enum.Material.Air or not state.sprinting or now < state.slideReadyAt then
			return Enum.ContextActionResult.Pass
		end
		state.sliding = true
		state.slideEndsAt = now + cfg.slideDurationSeconds
		state.slideReadyAt = now + cfg.slideDurationSeconds + cfg.slideCooldownSeconds
		applySpeed()

		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.C, Enum.KeyCode.ButtonR1)

	ContextActionService:BindAction("LR_LeanLeft", function(_, inputState)
		if pointerFree then return Enum.ContextActionResult.Pass end
		if inputState == Enum.UserInputState.Begin then leanLeft = true elseif released(inputState) then leanLeft = false end
		state.lean = (if leanRight then 1 else 0) - (if leanLeft then 1 else 0)
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.Q, Enum.KeyCode.DPadLeft)

	ContextActionService:BindAction("LR_LeanRight", function(_, inputState)
		if pointerFree then return Enum.ContextActionResult.Pass end
		if inputState == Enum.UserInputState.Begin then leanRight = true elseif released(inputState) then leanRight = false end
		state.lean = (if leanRight then 1 else 0) - (if leanLeft then 1 else 0)
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.E, Enum.KeyCode.DPadRight)

	ContextActionService:BindAction("LR_Reload", function(_, inputState)
		if pointerFree then return Enum.ContextActionResult.Pass end
		if inputState == Enum.UserInputState.Begin then
			state.reloadRequested = true
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.R, Enum.KeyCode.ButtonX)

	--[[
		The shove. Bound next to reload rather than next to fire, because it is
		the same kind of decision: a thing you commit to instead of shooting, not
		a second trigger. V and the right stick click are where every console
		shooter has put melee for fifteen years, and a twelve-year-old should not
		have to be told where it is.
	]]
	ContextActionService:BindAction("LR_Melee", function(_, inputState)
		if pointerFree then return Enum.ContextActionResult.Pass end
		if inputState == Enum.UserInputState.Begin then
			state.swingRequested = true
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.V, Enum.KeyCode.ButtonR3)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or pointerFree then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
			state.firing = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
			state.firing = false
		end
	end)
	UserInputService.WindowFocusReleased:Connect(reset)

	player.CharacterAdded:Connect(function(character)
		reset()
		state.slideEndsAt, state.slideReadyAt = 0, 0
		state.lastSprintAt = -math.huge
		character:WaitForChild("Humanoid")
		if player.Character == character then applySpeed() end
	end)
	applySpeed()
end

function Input.consumeReload(): boolean
	local requested = state.reloadRequested
	state.reloadRequested = false
	return requested
end

function Input.consumeSwing(): boolean
	local requested = state.swingRequested
	state.swingRequested = false
	return requested
end

function Input.isPointerFree(): boolean
	return pointerFree
end

function Input.setPointerFree(free: boolean)
	pointerFree = free
	if free then reset() end
	UserInputService.MouseIconEnabled = free
	UserInputService.MouseBehavior = if free then Enum.MouseBehavior.Default else Enum.MouseBehavior.LockCenter
end

function Input.tick(dt: number)
	if state.sliding and os.clock() >= state.slideEndsAt then
		state.sliding = false
		applySpeed()
	end
	if not pointerFree then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end

	local h = humanoid()
	if not h then
		return
	end
	local cfg = Config.require("match", "player")
	local targetX = state.lean * Units.metresToStuds(cfg.leanOffsetMetres)
	local current = h.CameraOffset
	local alpha = 1 - math.exp(-dt * cfg.leanSpeed)
	local targetY = if state.sliding then -Units.metresToStuds(Config.get("combatAnimations").slideEyeDropMetres) elseif state.crouching then Units.metresToStuds(cfg.crouchEyeHeightMetres - cfg.eyeHeightMetres) else 0
	h.CameraOffset = Vector3.new(current.X + (targetX - current.X) * alpha, current.Y + (targetY - current.Y) * alpha, current.Z)
end

return Input
