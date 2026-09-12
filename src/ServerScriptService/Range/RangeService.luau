--!strict
--[[
	RangeService -- the live drill loop.

	The Range is the aim trainer with the costume off: no bots, no payout, no
	round structure, just a target schedule and a score. Everything that decides
	WHAT appears and WHAT it is worth already existed as pure logic in
	Range/Drills and Range/DrillScoring, and `Sim/SimDrill` has been driving them
	headlessly since before there was a hub to stand in. What was missing was the
	half that needs a player: geometry to stand on, targets you can see, and a
	real clock.

	So this module is deliberately thin. It builds a range, ticks the schedule,
	and hands the same `DrillScoring.ShotEvent` list the simulation produces to
	the same scorer. A drill scored here and a drill scored in SimDrill differ
	only in who pulled the trigger -- which is the whole point of having built
	the pure half first.

	Firing is the match's firing: the client sends an intent, the server decides
	where the muzzle was, the marker's own fire rate gates it and the projectile
	is simulated authoritatively. Training against a more forgiving weapon than
	the one you take onto the field would make the Range a liar.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AimHistory = require(ReplicatedStorage.Shared.AimHistory)
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local MapGeometry = require(ReplicatedStorage.Shared.MapGeometry)
local MarkerState = require(ReplicatedStorage.Shared.MarkerState)
local Loadout = require(ReplicatedStorage.Shared.Loadout)
local Remotes = require(ReplicatedStorage.Net.Remotes)
local Rng = require(ReplicatedStorage.Shared.Rng)
local Spread = require(ReplicatedStorage.Shared.Spread)
local Types = require(ReplicatedStorage.Shared.Types)
local Units = require(ReplicatedStorage.Shared.Units)

local PlayerState = require(script.Parent.Parent.Match.PlayerState)
local ProjectileSim = require(script.Parent.Parent.Ballistics.ProjectileSim)
local Profile = require(script.Parent.Parent.Economy.Profile)
local ShotMeasure = require(script.Parent.Parent.Telemetry.ShotMeasure)
local DrillScoring = require(script.Parent.DrillScoring)
local Drills = require(script.Parent.Drills)

local log = Log.scope("LiveRound.Range")

local RangeService = {}

type Session = {
	stop: () -> (),
}

local sessions: { [Player]: Session } = {}
local rangeWorlds: { [Player]: Folder } = {}

--- Called when a drill ends, so the caller can put the player back in the hub.
RangeService.onFinished = nil :: ((Player, DrillScoring.Result) -> ())?

--[[
	Where the range gets built. Workspace in a running game.

	A seam, not a setting: the headless harness has no real Workspace to parent
	to, and without somewhere to put the geometry the whole live loop stays
	untestable -- which is the condition this module was written to end.
]]
RangeService.worldParent = nil :: Instance?

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

--[[
	The collision world.

	`ProjectileSim` only ever asks `MapGeometry.cast`, which walks `volumes`, so
	the Range needs exactly one volume -- the floor -- for a ball that misses to
	land somewhere instead of flying forever. The nav graph, anchors, sightlines
	and spawns that a match map carries are all bot machinery, and there are no
	bots here. Empty is the honest value, not a placeholder.
]]
local function collisionWorld(cfg: any): MapGeometry.World
	local bounds = cfg.bounds
	local thickness = cfg.ground.thicknessMetres
	local half = Vector3.new(bounds.widthMetres / 2, thickness / 2, bounds.lengthMetres / 2)
	local floor: MapGeometry.Volume = {
		id = "rangeFloor",
		sourceId = "rangeFloor",
		center = Vector3.new(0, -thickness / 2, 0),
		halfSize = half,
		rotationY = 0,
		cover = true,
		concealment = false,
		walkable = true,
		boundRadius = half.Magnitude,
	}
	return {
		id = "range",
		volumes = { floor },
		navNodes = {},
		navEdges = {},
		anchors = {},
		prePlacement = {},
		sightlines = {},
		botSpawns = {},
		playerSpawn = { position = cfg.firingLine.position, lookAt = cfg.firingLine.lookAt },
		playerRespawns = {},
		bounds = bounds,
		engagementBand = { minMetres = 10, maxMetres = 40 },
	}
end

local function slab(name: string, at: Vector3, size: Vector3, colour: Color3, material: Enum.Material, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Units.vectorToStuds(size)
	part.CFrame = CFrame.new(Units.vectorToStuds(at))
	part.Color = colour
	part.Material = material
	part.Anchored = true
	part.CanCollide = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--[[
	What you actually stand in.

	Flat-shaded and deliberately plain: a concrete pad, a berm on three sides to
	stop the sky reading as an escape, and a painted firing line. The Range is
	the one place in the game with nothing to look at on purpose -- every metre
	of decoration here is a metre of distraction from a moving dot.
]]
local function buildRange(cfg: any, parent: Instance): Folder
	local palette = Config.get("maps_index").palette
	local function colour(key: string): Color3
		local rgb = palette[key] or { 150, 150, 150 }
		return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	end

	local root = Instance.new("Folder")
	root.Name = "TheRange"

	local bounds = cfg.bounds
	local thickness = cfg.ground.thicknessMetres
	slab(
		"RangeFloor",
		Vector3.new(0, -thickness / 2, 0),
		Vector3.new(bounds.widthMetres, thickness, bounds.lengthMetres),
		colour(cfg.ground.colorKey),
		Enum.Material.Concrete,
		root
	)

	-- Berms. Tall enough to close the view, thin enough to cost nothing.
	local bermHeight = bounds.heightMetres
	local bermThickness = 1
	local halfW, halfL = bounds.widthMetres / 2, bounds.lengthMetres / 2
	local bermColour = colour("rock")
	slab("BermBack", Vector3.new(0, bermHeight / 2, halfL),
		Vector3.new(bounds.widthMetres, bermHeight, bermThickness), bermColour, Enum.Material.Concrete, root)
	slab("BermLeft", Vector3.new(-halfW, bermHeight / 2, 0),
		Vector3.new(bermThickness, bermHeight, bounds.lengthMetres), bermColour, Enum.Material.Concrete, root)
	slab("BermRight", Vector3.new(halfW, bermHeight / 2, 0),
		Vector3.new(bermThickness, bermHeight, bounds.lengthMetres), bermColour, Enum.Material.Concrete, root)

	--[[
		The firing line, and the distance marks behind it.

		Lifted clear of the pad on the same principle the fields use for their
		ground markings: two faces on one plane shimmer the moment the camera
		moves. See Data/presentation.json groundMarking.
	]]
	local marking = Config.require("presentation", "groundMarking")
	local lineY = marking.heightMetres
	local lineThickness = marking.thicknessMetres
	local firingZ = cfg.firingLine.position[3]
	slab("FiringLine",
		Vector3.new(0, lineY - lineThickness / 2, firingZ),
		Vector3.new(bounds.widthMetres * 0.5, lineThickness, 0.35),
		colour("bunkerC"), Enum.Material.SmoothPlastic, root)

	for _, metres in ipairs({ 10, 20, 30, 40 }) do
		local z = firingZ + metres
		if z < halfL - 1 then
			slab(`RangeMark_{metres}`,
				Vector3.new(0, lineY + marking.layerStepMetres - lineThickness / 2, z),
				Vector3.new(bounds.widthMetres * 0.32, lineThickness, 0.2),
				colour("concrete"), Enum.Material.SmoothPlastic, root)
		end
	end

	root.Parent = parent
	return root
end


--------------------------------------------------------------------------------
-- The drill
--------------------------------------------------------------------------------

--[[
	One drill run, as a value.

	This was a single 600-line closure. Everything it needed lived in upvalues,
	which is comfortable to write and impossible to reason about at the edges --
	and the edges are where the Range's bugs were: listeners installed before the
	session that owns them existed, a spread state that was fired through but
	never stepped, a deadline enforced in one of the two places that needed it.
	Naming the state makes each phase of a frame a function you can read on its
	own, and makes "what does teardown have to unwind" a list rather than a
	search.
]]
type Session = {
	player: Player,
	drillId: string,
	drillCfg: any,
	cfg: any,
	spec: Ballistics.Spec,
	hitbox: any,
	schedule: Drills.Schedule,
	worldFrame: Drills.Frame,
	drainSeconds: number,
	cueLeadSeconds: number,
	aimTolerance: number,
	root: Folder,
	targetFolder: Folder,
	targetColour: Color3,
	projectiles: ProjectileSim.Sim,
	markerState: MarkerState.State,
	spread: any,
	aim: AimHistory.History,

	--- Elapsed drill time. The drill's own clock, not the server's.
	t: number,
	finished: boolean,
	events: { DrillScoring.ShotEvent },
	parts: { [string]: BasePart },
	spawnedAt: { [string]: number },
	--- Targets already resolved -- hit, or expired and counted as a miss. A
	--- target is scored exactly once whichever way it ends.
	settled: { [string]: boolean },
	--- Targets whose bearing has already been announced. A cue repeated every
	--- frame for a second is noise, not a cue.
	cued: { [string]: boolean },
	previousAim: Vector3?,
	--[[
		When the last target went down.

		Switch grades `timeBetweenEliminationsMs` -- the swing from one target
		to the next -- which is not the same number as how long the target that
		was hit had been standing there. The first elimination is measured from
		the start of the drill, so a slow opening is not free.
	]]
	lastEliminationAt: number?,
	connections: { RBXScriptConnection },
	playerState: PlayerState.State,
}

function RangeService.isActive(player: Player): boolean
	return sessions[player] ~= nil
end

--- Whether a drill id is one the Range actually offers.
function RangeService.isDrill(drillId: any): boolean
	if type(drillId) ~= "string" then
		return false
	end
	for _, id in ipairs(Drills.list()) do
		if id == drillId then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Reading the player
--------------------------------------------------------------------------------

local function playerGround(session: Session): Vector3?
	local character = session.player.Character
	if not character then
		return nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not hrp or not humanoid then
		return nil
	end
	local feet = hrp.Position - Vector3.new(0, hrp.Size.Y / 2 + humanoid.HipHeight, 0)
	return Units.vectorToMetres(feet)
end

local function playerVelocity(session: Session): Vector3
	local character = session.player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return Vector3.zero
	end
	return Units.vectorToMetres(hrp.AssemblyLinearVelocity)
end

--------------------------------------------------------------------------------
-- The targets
--------------------------------------------------------------------------------

--[[
	The live targets, in world metres.

	The single local-to-world boundary. `Drills` authors targets relative to the
	firing line with -Z forward; everything downstream -- visible parts,
	projectile targets, shot measurement -- wants world metres. Doing the
	transform once, here, is what stops the two spaces from drifting. Doing it
	at each consumer is how the live Range came to use schedule coordinates as
	world coordinates, which put the 50 m holdover target ten metres BEHIND the
	shooter and the far strafe lane outside the floor.
]]
local function liveTargets(session: Session, now: number): { Drills.Target }
	local out: { Drills.Target } = {}
	for _, target in ipairs(Drills.activeAt(session.schedule, now)) do
		table.insert(out, {
			id = target.id,
			spawnAt = target.spawnAt,
			expiresAt = target.expiresAt,
			position = Drills.toWorld(session.worldFrame, target.position),
			velocity = Drills.rotateToWorld(session.worldFrame, target.velocity),
			radius = target.radius,
			announcedBearingDeg = target.announcedBearingDeg,
		})
	end
	return out
end

local function clearTargets(session: Session)
	for id, part in pairs(session.parts) do
		part:Destroy()
		session.parts[id] = nil
	end
end

--[[
	Peek's cue, announced BEFORE the reveal.

	`announcedBearingDeg` is the whole premise of the drill: the angles are
	KNOWN, and the skill being trained is having the crosshair already parked on
	the one that is coming. The schedule has authored the bearing since the drill
	was written and nothing ever told the player what it was, which left Peek
	indistinguishable from Pop-Up with a longer wait between targets.

	Sent `cueLeadSeconds` ahead, once per target, in the player's own frame --
	positive is to their right. Announcing it AT the reveal would not be a cue;
	it would be a caption.
]]
local function announceCues(session: Session)
	for _, target in ipairs(session.schedule.targets) do
		if target.announcedBearingDeg and not session.cued[target.id]
			and session.t >= target.spawnAt - session.cueLeadSeconds
			and session.t < target.spawnAt
		then
			session.cued[target.id] = true
			Remotes.event("DrillCue"):FireClient(session.player, {
				drill = session.drillId,
				targetId = target.id,
				bearingDeg = target.announcedBearingDeg,
				distanceMetres = Vector3.new(target.position.X, 0, target.position.Z).Magnitude,
				inSeconds = target.spawnAt - session.t,
			})
		end
	end
end

--- Spawns and moves the visible targets.
local function syncVisibleTargets(session: Session, live: { Drills.Target })
	for _, target in ipairs(live) do
		if session.settled[target.id] then
			continue
		end
		local part = session.parts[target.id]
		if not part then
			part = Instance.new("Part")
			part.Name = `Target_{target.id}`
			part.Shape = Enum.PartType.Ball
			part.Size = Units.vectorToStuds(Vector3.one * target.radius * 2)
			part.Color = session.targetColour
			part.Material = Enum.Material.SmoothPlastic
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CastShadow = false
			part.Parent = session.targetFolder
			session.parts[target.id] = part
			session.spawnedAt[target.id] = session.t
		end
		;(part :: BasePart).CFrame = CFrame.new(Units.vectorToStuds(target.position))
	end
end

--[[
	A target that came and went unengaged is a miss, and has to be recorded as
	one -- dropping it would let a player who never fires score the same as one
	who never misses. It is NOT a shot, though: nobody pulled a trigger. Those
	two used to share a counter, which made "accuracy" the fraction of
	opportunities taken rather than the fraction of balls that landed.
]]
local function retireExpired(session: Session, liveById: { [string]: any })
	for id, part in pairs(session.parts) do
		if liveById[id] then
			continue
		end
		part:Destroy()
		session.parts[id] = nil
		if session.settled[id] then
			continue
		end
		session.settled[id] = true
		local lifetime = 0
		for _, target in ipairs(session.schedule.targets) do
			if target.id == id then
				lifetime = target.expiresAt - target.spawnAt
				break
			end
		end
		table.insert(session.events, {
			t = session.t,
			hit = false,
			kind = "expired",
			targetId = id,
			timeToAcquireMs = lifetime * 1000,
		})
	end
end

--[[
	The hittable shapes.

	A drill target is a BALL, and its hittable shape has to be that ball.
	`ProjectileSim` treats `position` as the BOTTOM of a vertical capsule of
	`height`, so passing the sphere's centre with height 2r made the hittable
	column run from y-r to y+3r -- shots through empty space two diameters above
	the visible target counted as hits. A zero-height capsule about the centre IS
	a sphere, and `segmentSegmentDistance` guards the degenerate axis explicitly,
	so this is the supported spelling rather than a lucky one.
]]
local function simTargetsFor(session: Session, live: { Drills.Target }): { ProjectileSim.Target }
	local out: { ProjectileSim.Target } = {}
	for _, target in ipairs(live) do
		if not session.settled[target.id] then
			table.insert(out, {
				id = target.id,
				team = "target",
				position = target.position,
				velocity = target.velocity,
				radius = target.radius,
				height = 0,
				alive = true,
			})
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Firing
--------------------------------------------------------------------------------

local function handleFire(session: Session, payload: any)
	if session.finished then
		return
	end
	--[[
		The whistle is the whistle.

		`finished` only flips once the last ball has landed, so between the
		deadline and the drain the drill was still accepting new trigger pulls
		-- and each one spawned a projectile that had to land before the drill
		could end. Firing into the sky kept a 60 s drill alive past 80 s and
		scored shots taken after time.
	]]
	if session.t >= session.schedule.durationSeconds then
		return
	end
	local request = Remotes.validateFireRequest(payload)
	if not request then
		return
	end
	local ground = playerGround(session)
	if not ground then
		return
	end
	local stance = PlayerState.stanceFor(session.playerState, playerVelocity(session), session.player)
	local muzzle = PlayerState.muzzle(session.playerState, ground, request.direction, stance)

	if session.markerState.ammo <= 0 then
		session.markerState:reload(session.t)
	end
	if not session.markerState:fire(session.t) then
		return
	end

		local shotDirection = session.spread:fire(request.direction, session.t, stance)

	--[[
		Candidates are the live targets, and their positions already carry the
		drill's own height -- `Drills.schedule` builds them around the hitbox's
		chest height. So the measurement's `aimHeight` is zero here, where a
		match passes the chest height and adds it to a bot's foot position.
		Passing it twice put every measured shot a chest above the thing it was
		measuring.
	]]
	local candidates: { ShotMeasure.Candidate } = {}
	for _, target in ipairs(liveTargets(session, session.t)) do
		if not session.settled[target.id] then
			table.insert(candidates, {
				id = target.id,
				position = target.position,
				velocity = target.velocity,
				visibleSince = session.spawnedAt[target.id],
			})
		end
	end

	local measurement = ShotMeasure.measure({
		t = session.t,
		origin = muzzle,
		direction = request.direction,
		spec = session.spec,
		stance = stance,
		previousDirection = session.previousAim,
		candidates = candidates,
		aimHeight = 0,
		--- Real aim history, so crosshair placement is measured rather than
		--- inferred from where the previous shot happened to go.
		aimAt = function(at: number): Vector3?
			return session.aim:at(at, session.aimTolerance)
		end,
	})

	session.projectiles:fire({
		origin = muzzle,
		direction = shotDirection,
		spec = session.spec,
		ownerId = "player",
		team = "player",
		t = session.t,
		meta = { measurement = measurement, firedAt = session.t },
	})
	session.previousAim = request.direction

	--[[
		An acknowledgement, not a tracer.

		The client already drew a predicted tracer for this exact trigger pull,
		so a second one would put two balls in the air for one shot. It carries
		no `spec` on purpose -- the client's handler renders only when a spec is
		present -- and `ammo` is what the predicted hopper reconciles against.

		Metres, not studs: this once sent `Units.vectorToStuds(muzzle)` while
		`Tracers.fire` takes metres and converts them itself, so every tracer on
		the range began three and a half times further out than the muzzle it
		claimed to come from. `source` is the other half -- MatchService sends
		this remote only for the SQUAD's shots, and one remote meaning two
		opposite things is how a client ends up playing enemy fire at itself.
	]]
	Remotes.event("MarkerFired"):FireClient(session.player, {
		origin = muzzle,
		direction = shotDirection,
		ammo = session.markerState.ammo,
		source = "self",
	})
end

--------------------------------------------------------------------------------
-- Resolving paint
--------------------------------------------------------------------------------

local function resolveShots(session: Session, dt: number, live: { Drills.Target })
	for _, event in ipairs(session.projectiles:step(dt, session.t, simTargetsFor(session, live))) do
		local projectile = event.projectile
		local measurement = projectile.meta and projectile.meta.measurement
		local hitId = if event.kind == "target" then event.targetId else nil
		local scored = hitId ~= nil and not session.settled[hitId :: string]
		local firedAt = projectile.meta and projectile.meta.firedAt or session.t
		local sinceLastElimination: number? = nil
		if scored then
			local id = hitId :: string
			session.settled[id] = true
			local part = session.parts[id]
			if part then
				part:Destroy()
				session.parts[id] = nil
			end
			sinceLastElimination = (session.t - (session.lastEliminationAt or 0)) * 1000
			session.lastEliminationAt = session.t
		end
		--[[
			One event per trigger pull, hit or miss, plus the expiries above. A
			burst that lands one ball scores as one hit and the rest as misses,
			which is the correct answer for a trainer that grades aim rather
			than rate of fire.
		]]
		table.insert(session.events, {
			t = firedAt,
			hit = scored,
			kind = "shot",
			targetId = hitId,
			timeToAcquireMs = if scored and session.spawnedAt[hitId :: string]
				then (firedAt - session.spawnedAt[hitId :: string]) * 1000
				else nil,
			timeBetweenEliminationsMs = sinceLastElimination,
			angularErrorDeg = measurement and measurement.angularErrorDeg,
			leadErrorM = measurement and measurement.leadErrorM,
			holdoverErrorM = measurement and measurement.holdoverErrorM,
			crosshairOffsetDegAtReveal = measurement and measurement.crosshairOffsetDegAtReveal,
		})

		Remotes.event("ShotResolved"):FireClient(session.player, {
			shotId = projectile.id,
			hit = scored,
			targetId = hitId,
			impact = Units.vectorToStuds(event.position),
			holdoverErrorM = measurement and measurement.holdoverErrorM,
			leadErrorM = measurement and measurement.leadErrorM,
		})
	end
end

--------------------------------------------------------------------------------
-- Teardown
--------------------------------------------------------------------------------

--[[
	Everything a session allocated, unwound.

	One list, walked once. Listeners used to be installed BEFORE the session
	that owns them was registered, so a character load that failed in between
	called `RangeService.stop` while `sessions[player]` was still nil -- and the
	fire, reload and aim listeners it had already connected stayed connected,
	answering for a drill that no longer existed. Registration now happens before
	anything is allocated, and this unwinds whatever got as far as being made.
]]
local function teardown(session: Session)
	session.finished = true
	for _, connection in ipairs(session.connections) do
		connection:Disconnect()
	end
	table.clear(session.connections)
	clearTargets(session)
	session.projectiles:clear()
	if rangeWorlds[session.player] then
		rangeWorlds[session.player]:Destroy()
		rangeWorlds[session.player] = nil
	end
end

--[[
	The drill ended on its own clock: score it, keep it, and say so.

	`DrillScoring` produced a rating, a fundamental, a secondary fundamental and
	an accuracy, and every one of them was discarded the moment the banner faded
	-- no client listened to `DrillScore`, and nothing persisted a practice
	record. Running the same drill twice a week apart told the player nothing
	about whether they had improved, which is the only reason to run it twice.
]]
local function finishSession(session: Session)
	if session.finished then
		return
	end
	local player = session.player
	teardown(session)
	sessions[player] = nil

	local result = DrillScoring.score(session.drillId, session.events)

	--- Written to `practice`, NOT to `fundamentals`. See `Profile.recordDrill`
	--- for why a drill result must not overwrite the match estimate.
	local previousBest: any = nil
	local handle = Profile.get(player.UserId)
	if handle then
		previousBest = Profile.recordDrill(handle, result)
	end

	log.info(
		`{player.Name} finished {session.drillId}: score={result.score} `
			.. `{result.hits}/{result.shots} rating={math.floor(result.rating)}`
	)
	if player.Parent == Players then
		--[[
			The whole result, not a hit count.

			The rating is the number that matters -- it is on the same curve the
			match aggregator uses, which is what makes "your tracking is 38 in
			matches" and "you scored 41 on Strafe" the same kind of claim.
		]]
		Remotes.event("DrillScore"):FireClient(player, {
			drill = result.drill,
			drillName = session.drillCfg.displayName,
			fundamental = result.fundamental,
			score = result.score,
			hits = result.hits,
			shots = result.shots,
			missedOpportunities = result.missedOpportunities,
			accuracy = result.accuracy,
			rating = result.rating,
			secondaryFundamental = result.secondaryFundamental,
			secondaryRating = result.secondaryRating,
			previousBest = previousBest,
		})
	end
	if RangeService.onFinished then
		(RangeService.onFinished :: any)(player, result)
	end
end

function RangeService.stop(player: Player)
	local session = sessions[player]
	if session then
		sessions[player] = nil
		teardown(session)
	end
	--- Belt and braces: a world can outlive a session only if construction
	--- failed between allocating it and registering it, which the ordering
	--- below is meant to prevent. Cheap enough to guarantee rather than assume.
	if rangeWorlds[player] then
		rangeWorlds[player]:Destroy()
		rangeWorlds[player] = nil
	end
end

--------------------------------------------------------------------------------
-- The frame
--------------------------------------------------------------------------------

local function stepSession(session: Session, dt: number)
	if session.finished then
		return
	end
	session.t += dt
	session.markerState:update(session.t)
	--[[
		Sustained spread has to DECAY, and only `Spread.step` does that.

		The Range fired through the same `Spread` state the match uses but never
		stepped it, so the cone grew by `spreadGrowthPerShotDeg` on every trigger
		pull and never came back down -- within ten shots the drill was pegged at
		`sustainedSpreadDeg` for the rest of the run. An aim trainer that
		silently trains you against a permanently maximum cone is worse than no
		aim trainer, because the score still moves. `MatchService` and `SimMatch`
		both do this every step; the Range was the only one of the three that did
		not.
	]]
	session.spread:step(dt, session.t, playerVelocity(session))

	announceCues(session)

	local live = liveTargets(session, session.t)
	local liveById: { [string]: any } = {}
	for _, target in ipairs(live) do
		liveById[target.id] = target
	end

	syncVisibleTargets(session, live)
	retireExpired(session, liveById)
	resolveShots(session, dt, live)

	--[[
		End on the deadline, once the balls already in the air have landed or the
		drain window closes.

		An unbounded wait for an empty projectile list is a wait on physics the
		player controls: a ball fired straight up is still in flight twenty
		seconds later. In-flight shots deserve to resolve -- they were taken in
		time -- but not forever.
	]]
	if session.t >= session.schedule.durationSeconds
		and (#session.projectiles.projectiles == 0
			or session.t >= session.schedule.durationSeconds + session.drainSeconds)
	then
		finishSession(session)
	end
end

--------------------------------------------------------------------------------
-- Starting one
--------------------------------------------------------------------------------

--- Puts the player on the firing line, facing down the range.
local function placeOnLine(session: Session): boolean
	local player = session.player
	local ok = pcall(function()
		player:LoadCharacterAsync()
	end)
	if not ok or player.Parent ~= Players then
		return false
	end
	local character = player.Character
	local hrp = character and character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	local humanoid = character and character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not hrp or not humanoid then
		return false
	end
	local at = vec(session.cfg.firingLine.position)
	local toward = vec(session.cfg.firingLine.lookAt) - at
	local spawnAt = Units.vectorToStuds(at)
		+ Vector3.new(0, (hrp :: BasePart).Size.Y / 2 + (humanoid :: Humanoid).HipHeight, 0)
	;(hrp :: BasePart).CFrame = CFrame.lookAt(spawnAt, spawnAt + Vector3.new(toward.X, 0, toward.Z))
	;(hrp :: BasePart).AssemblyLinearVelocity = Vector3.zero
	return true
end

--[[
	Puts a player back on the firing line after their character disappeared.

	`Players.CharacterAutoLoads` is off, so nothing reloads a character on its
	own -- and the Range never had an elimination path to do it, because nothing
	on the Range shoots back. So the native reset button, or walking off the
	firing line, left the player with no character at all for the rest of the
	drill while the schedule kept presenting targets to nobody.

	Costs nothing. There is no payout here and no out to charge; the drill's own
	clock is the only thing running, and it does not stop.
]]
function RangeService.recover(player: Player): boolean
	local session = sessions[player]
	if not session or session.finished then
		return false
	end
	return placeOnLine(session)
end

--[[
	Runs one drill for one player.

	Returns false when it could not start -- no profile, an unknown drill, or a
	drill already running -- so the caller can say so rather than leaving the
	player standing at a gate that did nothing. That silent nothing is exactly
	what the Range did before this module existed.

	The ORDER matters. `sessions[player]` is claimed before anything is
	allocated and before the character load yields, so a second request arriving
	during that yield is refused rather than building a second range at the same
	origin, and so every listener connected along the way has a registered owner
	to unwind it. Every failure path from here goes through `RangeService.stop`.
]]
function RangeService.start(player: Player, drillId: string, seed: number?): boolean
	if sessions[player] then
		log.warn(`{player.Name} already has a drill running`)
		return false
	end
	if not RangeService.isDrill(drillId) then
		log.warn(`{player.Name} asked for unknown drill '{tostring(drillId)}'`)
		return false
	end
	local handle = Profile.load(player.UserId)
	if not handle or player.Parent ~= Players then
		log.warn(`no profile session for {player.Name}; refusing to start a drill`)
		return false
	end

	local cfg = Config.get("range")
	local ballisticsData = Config.get("ballistics")
	local markerData = Config.require("markers", "markers." .. handle.data.loadout.marker)
	local kit = Loadout.forRange(handle.data)
	local rootSeed = seed or math.floor(os.clock() * 1000) % 2147483647
	local rng = Rng.new(rootSeed)

	if rangeWorlds[player] then
		rangeWorlds[player]:Destroy()
	end
	local root = buildRange(cfg, RangeService.worldParent or Workspace)
	rangeWorlds[player] = root
	local targetFolder = Instance.new("Folder")
	targetFolder.Name = "Targets"
	targetFolder.Parent = root

	local palette = Config.get("maps_index").palette
	local targetRgb = palette.bunkerA or { 232, 86, 70 }

	local session: Session = {
		player = player,
		drillId = drillId,
		drillCfg = Config.require("range", "drills." .. drillId),
		cfg = cfg,
		spec = Ballistics.specFromMarker(markerData, ballisticsData),
		hitbox = ballisticsData.hitbox,
		schedule = Drills.schedule(drillId, rootSeed),
		worldFrame = Drills.worldFrame(),
		drainSeconds = cfg.shotDrainSeconds,
		cueLeadSeconds = cfg.cueLeadSeconds,
		aimTolerance = cfg.aimSampleToleranceSeconds,
		root = root,
		targetFolder = targetFolder,
		targetColour = Color3.fromRGB(targetRgb[1], targetRgb[2], targetRgb[3]),
		projectiles = ProjectileSim.new(collisionWorld(cfg), ballisticsData),
		markerState = MarkerState.new(markerData, kit),
		playerState = PlayerState.new(kit),
		spread = Spread.new(markerData, Config.get("match").player, rng:fork(500)),
		--[[
			Where the crosshair has been, on the drill's own clock.

			Peek grades crosshair placement -- how far off you were at the
			instant the target appeared -- and there is no shot at that instant
			to read it from. Without this the server answered with the direction
			of the PREVIOUS shot, so a player parked exactly on one of Peek's
			three known angles still scored as sixty degrees off whenever their
			last shot went to a different one. Every Peek run scored zero.
		]]
		aim = AimHistory.new(cfg.aimHistorySeconds, cfg.aimHistorySamples),
		t = 0,
		finished = false,
		events = {},
		parts = {},
		spawnedAt = {},
		settled = {},
		cued = {},
		previousAim = nil,
		lastEliminationAt = nil,
		connections = {},
	}
	sessions[player] = session

	table.insert(session.connections, Remotes.event("FireMarker").OnServerEvent:Connect(function(who, payload)
		if who == player then
			handleFire(session, payload)
		end
	end))
	table.insert(session.connections, Remotes.event("RequestReload").OnServerEvent:Connect(function(who)
		if who == player and not session.finished then
			session.markerState:reload(session.t)
		end
	end))
	table.insert(session.connections, Remotes.event("ReportStance").OnServerEvent:Connect(function(who, crouching, lean)
		if who == player and not session.finished then
			PlayerState.setIntent(session.playerState, crouching, lean)
		end
	end))
	table.insert(session.connections, Remotes.event("ReportAim").OnServerEvent:Connect(function(who, direction)
		if who == player and not session.finished and typeof(direction) == "Vector3" then
			session.aim:record(session.t, direction)
		end
	end))

	if not placeOnLine(session) then
		RangeService.stop(player)
		return false
	end

	table.insert(session.connections, RunService.Heartbeat:Connect(function(dt: number)
		stepSession(session, dt)
	end))

	--[[
		A drill is its own presentation state, not a match round.

		The client reset hopper, spread and outs on `warmup` or on a round
		change, and the Range enters straight into `live` with neither -- so a
		previous match's half-empty hopper and out count survived into a fresh
		drill. `drill` is the flag the client resets on; `drillName` and
		`fundamental` are what it puts on the card instead of round wording.
	]]
	local drillCfg = session.drillCfg
	Remotes.event("MatchStateChanged"):FireClient(player, {
		phase = "live",
		map = "range",
		mode = "range",
		loadout = handle.data.loadout,
		kit = kit,
		drill = drillId,
		drillName = drillCfg.displayName,
		fundamental = drillCfg.fundamental,
		notice = `{drillCfg.displayName} -- {math.floor(drillCfg.durationSeconds)}s`,
		seconds = drillCfg.durationSeconds,
	})
	log.info(`{player.Name} started drill {drillId} (seed {rootSeed})`)
	return true
end

--[[
	Bound from Bootstrap rather than on require.

	Connecting at module scope means the mere act of requiring this file touches
	a live service, which makes it unrunnable in the headless harness -- and an
	unrunnable module is one that never gets a check written for it. That is
	most of how the Range ended up shipped-but-dead in the first place.
]]
function RangeService.bind()
	Players.PlayerRemoving:Connect(function(player)
		RangeService.stop(player)
	end)
end

return RangeService
