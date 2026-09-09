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
local Config = require(ReplicatedStorage.Shared.Config)
local tuning = Config.get("clientEffects")

local Tracers = {}

export type Tracer = {
	position: Vector3,
	velocity: Vector3,
	spec: Ballistics.Spec,
	part: BasePart,
	--- Seconds of FLIGHT, accumulated from the same dt that advances the
	--- physics. It used to be a wall-clock stamp, which meant the ball's age and
	--- the ball's trajectory were driven by two different clocks that agree only
	--- while the frame rate holds -- and made the lifetime untestable.
	age: number,
	trail: Trail,
}

local live: { Tracer } = {}
local folder: Folder? = nil
local paintColour = Color3.fromRGB(246, 190, 62)

--[[
	Pools, because this is the only thing in the game that allocates per shot.

	A tracer is a Part, two Attachments and a Trail; a splat is another Part. An
	electronic marker fires about ten times a second, so building and destroying
	those was fifty instances a second of churn plus the collection behind it,
	during the exact seconds the frame budget matters most. Retired parts are
	parked (Parent = nil) and handed back out instead.

	Splats are also CAPPED. They expired on a fourteen-second timer and nothing
	bounded how many could be alive at once, so a sustained burst left well over a
	hundred parts on the field. Past the cap the oldest splat is recycled, which
	is both the cheapest and the least noticeable one to lose.
]]
type Assembly = { part: BasePart, trail: Trail }
local freeTracers: { Assembly } = {}
local freeSplats: { BasePart } = {}
local liveSplats: { { part: BasePart, expiresAt: number } } = {}
local effectsTime = 0
local SPLAT_CAP = tuning.splatCap
local SPLAT_SECONDS = tuning.splatSeconds
--- How long a tracer stays in the air before it is recycled. Long enough to
--- cover the longest sightline in the game at the slowest muzzle velocity.
local TRACER_SECONDS = tuning.tracerSeconds

local function container(): Folder
	if folder and folder.Parent then
		return folder :: Folder
	end
	local created = Instance.new("Folder")
	created.Name = "LiveRoundTracers"
	created.Parent = workspace
	folder = created
	return created
end

function Tracers.setPaintColour(colour: Color3)
	paintColour = colour
end

--- A tracer assembly, reused if one is parked and built if not.
local function acquireTracer(): Assembly
	local pooled = table.remove(freeTracers)
	if pooled then
		return pooled
	end
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(0.34, 0.34, 0.34)
	ball.Material = Enum.Material.Neon
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CastShadow = false

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
	trail.LightEmission = 0.5
	trail.Parent = ball

	return { part = ball, trail = trail }
end

--- Disable emission AND clear its recorded history before reuse. Enabled=false
--- alone leaves previous trail segments alive until their lifetime expires.
local function releaseTracer(tracer: Tracer)
	tracer.trail.Enabled = false
	tracer.trail:Clear()
	tracer.part.Parent = nil
	table.insert(freeTracers, { part = tracer.part, trail = tracer.trail })
end

function Tracers.fire(origin: Vector3, direction: Vector3, spec: Ballistics.Spec)
	if #live >= tuning.tracerCap then
		releaseTracer(table.remove(live, 1))
	end
	local assembly = acquireTracer()
	assembly.part.Color = paintColour
	assembly.part.CFrame = CFrame.new(Units.vectorToStuds(origin))
	assembly.trail.Color = ColorSequence.new(paintColour)
	assembly.trail.Enabled = true
	assembly.part.Parent = container()

	table.insert(live, {
		position = origin,
		velocity = direction.Unit * spec.muzzleVelocity,
		spec = spec,
		part = assembly.part,
		age = 0,
		trail = assembly.trail,
	})
end

--- Paint on a surface. Splatter only -- no impact effects that read as damage.
function Tracers.splat(at: Vector3, colour: Color3?)
	-- At the cap the oldest splat is recycled: it is both the cheapest one to
	-- lose and the one furthest from whatever the player is looking at now.
	local splat: BasePart
	if #liveSplats >= SPLAT_CAP then
		splat = table.remove(liveSplats, 1).part
	else
		splat = table.remove(freeSplats) or (function()
			local created = Instance.new("Part")
			created.Shape = Enum.PartType.Ball
			created.Size = Vector3.new(0.85, 0.2, 0.85)
			created.Material = Enum.Material.SmoothPlastic
			created.Anchored = true
			created.CanCollide = false
			created.CanQuery = false
			created.CanTouch = false
			created.CastShadow = false
			return created
		end)()
	end
	splat.Color = colour or paintColour
	splat.CFrame = CFrame.new(at)
	splat.Parent = container()
	-- One expiry clock replaces a delayed callback per splat. Reusing a part
	-- cannot let its previous owner's timer remove the new paint early.
	table.insert(liveSplats, { part = splat, expiresAt = effectsTime + SPLAT_SECONDS })
end

function Tracers.step(dt: number)
	effectsTime += dt
	for i = #liveSplats, 1, -1 do
		local splat = liveSplats[i]
		if effectsTime >= splat.expiresAt then
			splat.part.Parent = nil
			table.insert(freeSplats, splat.part)
			table.remove(liveSplats, i)
		end
	end
	for i = #live, 1, -1 do
		local tracer = live[i]
		local newPos, newVel = Ballistics.step(tracer.position, tracer.velocity, dt, tracer.spec)
		tracer.position = newPos
		tracer.velocity = newVel
		tracer.part.CFrame = CFrame.new(Units.vectorToStuds(newPos))

		tracer.age += dt
		if tracer.age > TRACER_SECONDS then
			releaseTracer(tracer)
			table.remove(live, i)
		end
	end
end

--[[
	Called when the server resolves a shot.

	This drew the splat and left the ball flying -- so a paintball the server had
	already ruled a hit carried on through the wall it hit for the rest of its
	three seconds, which is the comment above this function describing behaviour
	the function did not have.

	The remote carries no shot id, so the tracer is identified by position: the
	live one nearest the impact, and only if it is near enough to plausibly be
	the same ball. A miss leaves every tracer flying, which is correct.
]]
local RESOLVE_RADIUS_STUDS = tuning.resolveRadiusStuds

function Tracers.resolve(impactStuds: Vector3)
	Tracers.splat(impactStuds)

	local nearest, nearestDistance = nil, RESOLVE_RADIUS_STUDS
	for index, tracer in ipairs(live) do
		local distance = (Units.vectorToStuds(tracer.position) - impactStuds).Magnitude
		if distance < nearestDistance then
			nearest, nearestDistance = index, distance
		end
	end
	if nearest then
		releaseTracer(live[nearest])
		table.remove(live, nearest)
	end
end

--[[
	Counts, for the headless check.

	Pooling that quietly stopped pooling would look exactly like pooling that
	works -- the game would play the same and allocate the same as before -- so
	the pool is observable rather than trusted.
]]
function Tracers.stats(): { live: number, pooledTracers: number, liveSplats: number, pooledSplats: number }
	return {
		live = #live,
		pooledTracers = #freeTracers,
		liveSplats = #liveSplats,
		pooledSplats = #freeSplats,
	}
end

function Tracers.clear()
	for _, tracer in ipairs(live) do releaseTracer(tracer) end
	table.clear(live)
	for _, splat in ipairs(liveSplats) do
		splat.part.Parent = nil
		table.insert(freeSplats, splat.part)
	end
	table.clear(liveSplats)
end

function Tracers.bind()
	RunService.RenderStepped:Connect(Tracers.step)
end

return Tracers
