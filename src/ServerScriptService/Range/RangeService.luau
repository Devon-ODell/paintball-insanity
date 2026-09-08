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

local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local MapGeometry = require(ReplicatedStorage.Shared.MapGeometry)
local MarkerState = require(ReplicatedStorage.Shared.MarkerState)
local Remotes = require(ReplicatedStorage.Net.Remotes)
local Rng = require(ReplicatedStorage.Shared.Rng)
local Spread = require(ReplicatedStorage.Shared.Spread)
local Types = require(ReplicatedStorage.Shared.Types)
local Units = require(ReplicatedStorage.Shared.Units)

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

function RangeService.isActive(player: Player): boolean
	return sessions[player] ~= nil
end

function RangeService.stop(player: Player)
	local session = sessions[player]
	if session then
		sessions[player] = nil
		session.stop()
	end
	if rangeWorlds[player] then
		rangeWorlds[player]:Destroy()
		rangeWorlds[player] = nil
	end
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

--[[
	Runs one drill for one player.

	Returns false when it could not start -- no profile, an unknown drill, or a
	drill already running -- so the caller can say so rather than leaving the
	player standing at a gate that did nothing. That silent nothing is exactly
	what the Range did before this module existed.
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
	local hitbox = ballisticsData.hitbox
	local markerName = handle.data.loadout.marker
	local markerData = Config.require("markers", "markers." .. markerName)
	local spec = Ballistics.specFromMarker(markerData, ballisticsData)
	local matchData = Config.get("match")

	local world = collisionWorld(cfg)
	if rangeWorlds[player] then
		rangeWorlds[player]:Destroy()
	end
	local root = buildRange(cfg, RangeService.worldParent or Workspace)
	rangeWorlds[player] = root

	local targetFolder = Instance.new("Folder")
	targetFolder.Name = "Targets"
	targetFolder.Parent = root

	local rootSeed = seed or math.floor(os.clock() * 1000) % 2147483647
	local rng = Rng.new(rootSeed)
	local schedule = Drills.schedule(drillId, rootSeed)
	local projectiles = ProjectileSim.new(world, ballisticsData)
	local markerState = MarkerState.new(markerData)
	local spread = Spread.new(markerData, matchData.player, rng:fork(500))

	local events: { DrillScoring.ShotEvent } = {}
	local parts: { [string]: BasePart } = {}
	local spawnedAt: { [string]: number } = {}
	--- Targets already resolved -- hit, or expired and counted as a miss. A
	--- target is scored exactly once whichever way it ends.
	local settled: { [string]: boolean } = {}
	local t = 0
	local finished = false
	local previousAim: Vector3? = nil
	local connection: RBXScriptConnection? = nil
	local fireConnection: RBXScriptConnection? = nil
	local reloadConnection: RBXScriptConnection? = nil

	local palette = Config.get("maps_index").palette
	local targetRgb = palette.bunkerA or { 232, 86, 70 }
	local targetColour = Color3.fromRGB(targetRgb[1], targetRgb[2], targetRgb[3])

	local function playerGround(): Vector3?
		local character = player.Character
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

	local function playerVelocity(): Vector3
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			return Vector3.zero
		end
		return Units.vectorToMetres(hrp.AssemblyLinearVelocity)
	end

	local function clearTargets()
		for id, part in pairs(parts) do
			part:Destroy()
			parts[id] = nil
		end
	end

	local function finish()
		if finished then
			return
		end
		finished = true
		if connection then connection:Disconnect() end
		if fireConnection then fireConnection:Disconnect() end
		if reloadConnection then reloadConnection:Disconnect() end
		clearTargets()
		projectiles:clear()
		sessions[player] = nil

		local result = DrillScoring.score(drillId, events)
		log.info(
			`{player.Name} finished {drillId}: score={result.score} `
				.. `{result.hits}/{result.shots} rating={math.floor(result.rating)}`
		)
		if player.Parent == Players then
			Remotes.event("DrillScore"):FireClient(player, {
				drill = result.drill,
				fundamental = result.fundamental,
				score = result.score,
				hits = result.hits,
				shots = result.shots,
				accuracy = result.accuracy,
				rating = result.rating,
			})
		end
		if rangeWorlds[player] then
			rangeWorlds[player]:Destroy()
			rangeWorlds[player] = nil
		end
		if RangeService.onFinished then
			(RangeService.onFinished :: any)(player, result)
		end
	end

	--------------------------------------------------------------------------
	-- Firing
	--------------------------------------------------------------------------

	local function onFire(payload: any)
		if finished then
			return
		end
		local request = Remotes.validateFireRequest(payload)
		if not request then
			return
		end
		local ground = playerGround()
		if not ground then
			return
		end
		local muzzle = (ground :: Vector3) + Vector3.new(0, hitbox.chestHeightMetres, 0)

		if markerState.ammo <= 0 then
			markerState:reload(t)
		end
		if not markerState:fire(t) then
			return
		end

		local stance = spread:stance(playerVelocity(), request.stance == "crouching") :: Types.Stance
		local shotDirection = spread:fire(request.direction, t, stance)

		--[[
			Candidates are the live targets, and their positions already carry
			the drill's own height -- `Drills.schedule` builds them around the
			hitbox's chest height. So the measurement's `aimHeight` is zero
			here, where a match passes the chest height and adds it to a bot's
			foot position. Passing it twice put every measured shot a chest
			above the thing it was measuring.
		]]
		local candidates: { ShotMeasure.Candidate } = {}
		for _, target in ipairs(Drills.activeAt(schedule, t)) do
			if not settled[target.id] then
				table.insert(candidates, {
					id = target.id,
					position = target.position,
					velocity = target.velocity,
					visibleSince = spawnedAt[target.id],
				})
			end
		end

		local measurement = ShotMeasure.measure({
			t = t,
			origin = muzzle,
			direction = request.direction,
			spec = spec,
			stance = stance,
			previousDirection = previousAim,
			candidates = candidates,
			aimHeight = 0,
		})

		projectiles:fire({
			origin = muzzle,
			direction = shotDirection,
			spec = spec,
			ownerId = "player",
			team = "player",
			t = t,
			meta = { measurement = measurement, firedAt = t },
		})
		previousAim = request.direction

		Remotes.event("MarkerFired"):FireClient(player, {
			origin = Units.vectorToStuds(muzzle),
			direction = shotDirection,
			ammo = markerState.ammo,
		})
	end

	fireConnection = Remotes.event("FireMarker").OnServerEvent:Connect(function(who, payload)
		if who == player then
			onFire(payload)
		end
	end)
	reloadConnection = Remotes.event("RequestReload").OnServerEvent:Connect(function(who)
		if who == player and not finished then
			markerState:reload(t)
		end
	end)

	--------------------------------------------------------------------------
	-- The loop
	--------------------------------------------------------------------------

	local function step(dt: number)
		if finished then
			return
		end
		t += dt
		markerState:update(t)

		local live = Drills.activeAt(schedule, t)
		local liveById: { [string]: any } = {}
		for _, target in ipairs(live) do
			liveById[target.id] = target
		end

		-- Spawn and move the visible targets.
		for _, target in ipairs(live) do
			if not settled[target.id] then
				local part = parts[target.id]
				if not part then
					part = Instance.new("Part")
					part.Name = `Target_{target.id}`
					part.Shape = Enum.PartType.Ball
					part.Size = Units.vectorToStuds(Vector3.one * target.radius * 2)
					part.Color = targetColour
					part.Material = Enum.Material.SmoothPlastic
					part.Anchored = true
					part.CanCollide = false
					part.CanQuery = false
					part.CastShadow = false
					part.Parent = targetFolder
					parts[target.id] = part
					spawnedAt[target.id] = t
				end
				;(part :: BasePart).CFrame = CFrame.new(Units.vectorToStuds(target.position))
			end
		end

		--[[
			A target that came and went unengaged is a miss, and has to be
			recorded as one. Dropping it would let a player who never fires
			score the same as one who never misses.
		]]
		for id, part in pairs(parts) do
			if not liveById[id] then
				part:Destroy()
				parts[id] = nil
				if not settled[id] then
					settled[id] = true
					local lifetime = 0
					for _, target in ipairs(schedule.targets) do
						if target.id == id then
							lifetime = target.expiresAt - target.spawnAt
							break
						end
					end
					table.insert(events, {
						t = t,
						hit = false,
						targetId = id,
						timeToAcquireMs = lifetime * 1000,
					})
				end
			end
		end

		-- Resolve paint.
		local simTargets: { ProjectileSim.Target } = {}
		for _, target in ipairs(live) do
			if not settled[target.id] then
				table.insert(simTargets, {
					id = target.id,
					team = "target",
					position = target.position,
					velocity = target.velocity,
					radius = target.radius,
					height = target.radius * 2,
					alive = true,
				})
			end
		end

		for _, event in ipairs(projectiles:step(dt, t, simTargets)) do
			local projectile = event.projectile
			local measurement = projectile.meta and projectile.meta.measurement
			local hitId = if event.kind == "target" then event.targetId else nil
			local scored = hitId ~= nil and not settled[hitId :: string]
			if scored then
				local id = hitId :: string
				settled[id] = true
				local part = parts[id]
				if part then
					part:Destroy()
					parts[id] = nil
				end
			end
			--[[
				One event per trigger pull, hit or miss, plus the expiries
				above. DrillScoring counts `#events` as shots, so a burst that
				lands one ball scores as one hit and the rest as misses --
				which is the correct answer for a trainer that grades aim
				rather than rate of fire.
			]]
			table.insert(events, {
				t = projectile.meta and projectile.meta.firedAt or t,
				hit = scored,
				targetId = hitId,
				timeToAcquireMs = if scored and spawnedAt[hitId :: string]
					then ((projectile.meta and projectile.meta.firedAt or t) - spawnedAt[hitId :: string]) * 1000
					else nil,
				angularErrorDeg = measurement and measurement.angularErrorDeg,
				leadErrorM = measurement and measurement.leadErrorM,
				holdoverErrorM = measurement and measurement.holdoverErrorM,
				crosshairOffsetDegAtReveal = measurement and measurement.crosshairOffsetDegAtReveal,
			})

			Remotes.event("ShotResolved"):FireClient(player, {
				shotId = projectile.id,
				hit = scored,
				targetId = hitId,
				impact = Units.vectorToStuds(event.position),
				holdoverErrorM = measurement and measurement.holdoverErrorM,
				leadErrorM = measurement and measurement.leadErrorM,
			})
		end

		if t >= schedule.durationSeconds and #projectiles.projectiles == 0 then
			finish()
		end
	end

	-- Put the player on the line.
	local ok = pcall(function()
		player:LoadCharacterAsync()
	end)
	if not ok or player.Parent ~= Players then
		RangeService.stop(player)
		return false
	end
	local character = player.Character
	local hrp = character and character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	local humanoid = character and character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not hrp or not humanoid then
		RangeService.stop(player)
		return false
	end
	local at = vec(cfg.firingLine.position)
	local toward = vec(cfg.firingLine.lookAt) - at
	local spawnAt = Units.vectorToStuds(at)
		+ Vector3.new(0, (hrp :: BasePart).Size.Y / 2 + (humanoid :: Humanoid).HipHeight, 0)
	;(hrp :: BasePart).CFrame = CFrame.lookAt(spawnAt, spawnAt + Vector3.new(toward.X, 0, toward.Z))
	;(hrp :: BasePart).AssemblyLinearVelocity = Vector3.zero

	connection = RunService.Heartbeat:Connect(step)
	sessions[player] = {
		stop = function()
			finished = true
			if connection then connection:Disconnect() end
			if fireConnection then fireConnection:Disconnect() end
			if reloadConnection then reloadConnection:Disconnect() end
			clearTargets()
			projectiles:clear()
		end,
	}

	local drillCfg = Config.require("range", "drills." .. drillId)
	Remotes.event("MatchStateChanged"):FireClient(player, {
		phase = "live",
		map = "range",
		mode = "range",
		drill = drillId,
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
