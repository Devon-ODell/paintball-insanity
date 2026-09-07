--!strict
--[[
	Tracers -- the cosmetic flight of a paintball, drawn locally.

	The client fires a tracer the instant the player pulls the trigger so the
	game feels responsive. The SERVER decides whether anything was hit, and it
	uses its own simulation. The two can disagree; when they do, the server wins
	and the tracer is simply wrong for a few hundred milliseconds.

	Both run Shared/Ballistics with the same marker spec, so they disagree only
	by latency, never by physics.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local Units = require(ReplicatedStorage.Shared.Units)

local Tracers = {}

export type Tracer = {
	position: Vector3,
	velocity: Vector3,
	spec: Ballistics.Spec,
	part: BasePart,
	bornAt: number,
	trail: Trail,
}

local live: { Tracer } = {}
local folder: Folder? = nil
local paintColour = Color3.fromRGB(246, 190, 62)

local function container(): Folder
	if folder and folder.Parent then
		return folder :: Folder
	end
	local created = Instance.new("Folder")
	created.Name = "LiveRoundTracers"
	created.Parent = workspace.CurrentCamera
	folder = created
	return created
end

function Tracers.setPaintColour(colour: Color3)
	paintColour = colour
end

function Tracers.fire(origin: Vector3, direction: Vector3, spec: Ballistics.Spec)
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(0.34, 0.34, 0.34)
	ball.Color = paintColour
	ball.Material = Enum.Material.Neon
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CastShadow = false
	ball.CFrame = CFrame.new(Units.vectorToStuds(origin))

	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0.1, 0)
	a0.Parent = ball
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -0.1, 0)
	a1.Parent = ball

	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.22
	trail.WidthScale = NumberSequence.new(1, 0)
	trail.Transparency = NumberSequence.new(0.2, 1)
	trail.Color = ColorSequence.new(paintColour)
	trail.LightEmission = 0.5
	trail.Parent = ball

	ball.Parent = container()

	table.insert(live, {
		position = origin,
		velocity = direction.Unit * spec.muzzleVelocity,
		spec = spec,
		part = ball,
		bornAt = os.clock(),
		trail = trail,
	})
end

--- Paint on a surface. Splatter only -- no impact effects that read as damage.
function Tracers.splat(at: Vector3, colour: Color3?)
	local splat = Instance.new("Part")
	splat.Shape = Enum.PartType.Ball
	splat.Size = Vector3.new(0.85, 0.2, 0.85)
	splat.Color = colour or paintColour
	splat.Material = Enum.Material.SmoothPlastic
	splat.Anchored = true
	splat.CanCollide = false
	splat.CanQuery = false
	splat.CastShadow = false
	splat.CFrame = CFrame.new(at)
	splat.Parent = container()
	task.delay(14, function()
		splat:Destroy()
	end)
end

function Tracers.step(dt: number)
	local now = os.clock()
	for i = #live, 1, -1 do
		local tracer = live[i]
		local newPos, newVel = Ballistics.step(tracer.position, tracer.velocity, dt, tracer.spec)
		tracer.position = newPos
		tracer.velocity = newVel
		tracer.part.CFrame = CFrame.new(Units.vectorToStuds(newPos))

		if now - tracer.bornAt > 3 then
			tracer.part:Destroy()
			table.remove(live, i)
		end
	end
end

--- Called when the server resolves a shot, so a tracer that the server says hit
--- something stops flying through it.
function Tracers.resolve(impactStuds: Vector3)
	Tracers.splat(impactStuds)
end

function Tracers.bind()
	RunService.RenderStepped:Connect(Tracers.step)
end

return Tracers
