--!nolint
--[[
	Drives every drill through RangeService with a scripted shooter.

	    lune run tools/check-range

	The Range's pure halves -- the schedule and the scorer -- have had specs
	since before there was a hub. What had never been executed was the half that
	needs a player, which is exactly why pressing F at the gate did nothing for
	so long without any test noticing.

	This gate used to run Pop-Up only, and its "perfect shooter" solved its shots
	against the same schedule coordinates the live Range placed targets at. That
	made it blind to the thing most worth catching: the live Range was treating
	firing-line-LOCAL positions as WORLD positions, which put the 50 m holdover
	target ten metres behind the shooter and the far strafe lane outside the
	floor. Both halves were consistently wrong, 22 of 74 shots landed, and the
	gate passed.

	So the shooter now solves in world space through `Drills.worldFrame`, and the
	geometry is asserted independently of whether anything hits: announced
	distance, forward hemisphere, and containment inside the floor and berms. On
	top of that it checks the shapes (a graze outside the visible ball must
	miss), the deadline (a drill ends on its own clock whether the player fires
	nothing or fires continuously), the bounded target population, and the wire
	the client actually receives.
]]
local roblox = require("@lune/roblox")
local Harness = require("./Harness")
local env = Harness.build()

local function replace(node, value)
	node._loaded, node._result = true, value
end

local function signal()
	local listeners = {}
	return {
		Connect = function(_, fn)
			table.insert(listeners, fn)
			return { Disconnect = function() end }
		end,
		fire = function(_, ...)
			for _, fn in ipairs(listeners) do fn(...) end
		end,
	}
end

local heartbeat = signal()
env.game:GetService("RunService").Heartbeat = heartbeat

local actualRemotes = env.require(env.ReplicatedStorage.Net.Remotes)
local events = {}
local function event(name)
	if not events[name] then
		events[name] = {
			OnServerEvent = signal(),
			sent = {},
			FireClient = function(self, _, payload) table.insert(self.sent, payload) end,
		}
	end
	return events[name]
end
local function resetEvents()
	for _, e in pairs(events) do
		e.sent = {}
	end
end
replace(env.ReplicatedStorage.Net.Remotes, {
	event = event,
	validateFireRequest = actualRemotes.validateFireRequest,
})

local Units = env.require(env.Shared.Units)
local Ballistics = env.require(env.Shared.Ballistics)
local Config = env.require(env.Shared.Config)
local Drills = env.require(env.Server.Range.Drills)
local RangeService = env.require(env.Server.Range.RangeService)

local V3 = roblox.Vector3

local cfg = Config.get("range")
local ballisticsData = Config.get("ballistics")
local chest = ballisticsData.hitbox.chestHeightMetres
local markerData = Config.require("markers", "markers.mechanical")
local spec = Ballistics.specFromMarker(markerData, ballisticsData)

--[[
	The shooter stands on the firing line.

	RangeService derives the muzzle from the character's feet, so the mock root
	has to sit half a torso plus a hip height above the line for the muzzle to
	land where a real player's would. Getting this wrong would make every
	scripted shot miss and the check would "pass" by asserting nothing.
]]
local hipHeight, rootHalf = 1.5, 1
local lineStuds = Units.vectorToStuds(
	V3.new(cfg.firingLine.position[1], cfg.firingLine.position[2], cfg.firingLine.position[3])
)
local humanoid = { HipHeight = hipHeight }
local root = {
	Position = lineStuds + V3.new(0, rootHalf + hipHeight, 0),
	Size = V3.new(2, rootHalf * 2, 1),
	AssemblyLinearVelocity = V3.zero,
	CFrame = roblox.CFrame.new(lineStuds),
}
local character = {
	FindFirstChild = function() return root end,
	FindFirstChildOfClass = function() return humanoid end,
	WaitForChild = function(_, name) return if name == "Humanoid" then humanoid else root end,
}
local player = {
	UserId = 4242,
	Name = "RangeProbe",
	Character = character,
	Parent = env.game:GetService("Players"),
	LoadCharacterAsync = function() end,
}

local muzzle = V3.new(
	cfg.firingLine.position[1],
	cfg.firingLine.position[2] + chest,
	cfg.firingLine.position[3]
)

-- No real Workspace in the harness; give the range somewhere to be built.
local stage = roblox.Instance.new("Folder")
RangeService.worldParent = stage

local finished = nil
RangeService.onFinished = function(_, result) finished = result end

--------------------------------------------------------------------------------
-- Geometry: where the targets actually are, independent of anything hitting
--------------------------------------------------------------------------------

local frame = Drills.worldFrame()
local function toWorld(p) return Drills.toWorld(frame, p) end

--[[
	The firing line looks at the far end of the floor, so the shooter's forward
	reach is the floor's half-length plus however far behind centre they stand.
	Anything beyond that is outside the berm; anything at or behind zero is
	behind the shooter.
]]
local halfLength = cfg.bounds.lengthMetres / 2
local halfWidth = cfg.bounds.widthMetres / 2
local lineOffset = frame.origin.X * frame.forward.X + frame.origin.Z * frame.forward.Z
local maxForward = halfLength - lineOffset

local geometryChecked = 0
for _, drillId in ipairs(Drills.list()) do
	local schedule = Drills.schedule(drillId, 99)
	assert(#schedule.targets > 0, `{drillId} must schedule targets`)

	local live = 0
	for _, target in ipairs(schedule.targets) do
		--[[
			Nothing appears after the whistle, and nothing outlives it. Peek
			advances its clock by the reveal delay BEFORE placing a target, so
			it could schedule one the player can never engage; counting that as
			a missed opportunity would be a lie about the player.
		]]
		assert(target.spawnAt < schedule.durationSeconds,
			`{drillId} target {target.id} spawns at {target.spawnAt}s, after the {schedule.durationSeconds}s drill`)
		assert(target.expiresAt <= schedule.durationSeconds + 1e-6,
			`{drillId} target {target.id} outlives the drill`)

		-- Both ends of a moving target's track, not just where it starts.
		for _, localPos in ipairs({
			target.position,
			target.position + target.velocity * (target.expiresAt - target.spawnAt),
		}) do
			local world = toWorld(localPos)
			local rel = world - frame.origin
			local forward = rel.X * frame.forward.X + rel.Z * frame.forward.Z
			local lateral = rel.X * frame.right.X + rel.Z * frame.right.Z

			assert(forward > 0,
				`{drillId} target {target.id} is {string.format("%.1f", forward)} m FORWARD of the firing line -- `
					.. "a target behind the shooter can never be engaged")

			--[[
				The announced distance is the promise the drill makes. Holdover
				says "50 metres" in its own config and the player learns a
				holdover for it; if the ball only flies 5 m the lesson is wrong.
			]]
			local announced = localPos.Magnitude
			local actual = (world - V3.new(frame.origin.X, frame.origin.Y + localPos.Y, frame.origin.Z)).Magnitude
			assert(math.abs(actual - math.sqrt(announced ^ 2 - localPos.Y ^ 2)) < 0.05
					or math.abs((world - muzzle).Magnitude - (localPos - V3.new(0, chest, 0)).Magnitude) < 1.0,
				`{drillId} target {target.id} is not at its announced range`)

			assert(forward <= maxForward + 1e-6,
				`{drillId} target {target.id} is {string.format("%.1f", forward)} m out, past the {string.format("%.1f", maxForward)} m back berm`)
			assert(math.abs(lateral) <= halfWidth + 1e-6,
				`{drillId} target {target.id} is {string.format("%.1f", lateral)} m wide, outside the {halfWidth} m side berm`)
			assert(world.Y > 0, `{drillId} target {target.id} is under the floor`)
			geometryChecked += 1
		end
	end

	--[[
		A bounded population.

		Switch's premise is `simultaneousTargets` alive at once -- the cost being
		measured is the swing between them. It used to accumulate a new target
		every 3.35 s in each of three lanes and expire none of them until the
		drill ended, so a player who fired nothing faced 54 targets at 59 s.
	]]
	local drillCfg = Config.require("range", "drills." .. drillId)
	local cap = drillCfg.simultaneousTargets
	for i = 0, math.floor(schedule.durationSeconds / 0.25) do
		local n = #Drills.activeAt(schedule, i * 0.25)
		if n > live then live = n end
		if cap then
			assert(n <= cap,
				`{drillId} had {n} targets alive at {i * 0.25}s, above its declared {cap}`)
		end
	end
	assert(live > 0, `{drillId} must have targets alive at some point`)
	print(string.format("  %-9s %3d targets, at most %d alive, all inside the range", drillId, #schedule.targets, live))
end
print(string.format("Geometry: %d target positions checked against the firing line.", geometryChecked))

--------------------------------------------------------------------------------
-- The live loop, once per drill
--------------------------------------------------------------------------------

--- Fires one solved shot at each target as it appears, in WORLD space.
local function runDrill(drillId: string, options: any?)
	local opts = options or {}
	resetEvents()
	finished = nil
	assert(RangeService.start(player, drillId, 99), `{drillId} must start`)
	assert(RangeService.isActive(player), `{drillId} must report itself active`)

	local schedule = Drills.schedule(drillId, 99)
	local engaged = {}
	local t, frames, shotsTaken = 0, 0, 0
	local dt = 1 / 30
	--[[
		The probe obeys the marker's fire rate.

		The service gates on it, so a shot sent inside the interval is silently
		dropped -- and a probe that marked the target engaged anyway spent two
		of every three Switch targets on rejections it never noticed, then read
		the resulting three-second gaps as a scoring bug.
	]]
	local shotInterval = 60 / markerData.roundsPerMinute
	local nextShotAt = 0

	--[[
		The probe reports where it is looking, because a player does.

		Crosshair placement asks where the crosshair was at the INSTANT a target
		appeared, and there is no shot at that instant to read it from. Without
		this stream the server falls back to the previous shot's direction,
		which on Peek -- three known angles sixty degrees apart -- reports the
		swing between shots rather than the placement, and scored every run at
		zero however well it was played.

		`opts.ignoreCue` is the control: the same probe, not acting on the cue,
		must score materially worse. A measurement that cannot tell those two
		players apart is not measuring placement.
	]]
	local aimReportSeconds = Config.require("ui", "aimReportSeconds")
	local nextAimAt = 0
	local currentAim = frame.forward
	if not opts.ignoreCue then
		event("DrillCue").FireClient = function(self, _, payload)
			table.insert(self.sent, payload)
			--- Park on the announced bearing, at chest height, the way a player
			--- who has learned the three angles does.
			local a = math.rad(payload.bearingDeg)
			local at = toWorld(V3.new(
				math.sin(a) * payload.distanceMetres,
				chest,
				-math.cos(a) * payload.distanceMetres
			))
			currentAim = (at - muzzle).Unit
		end
	end
	local maxFrames = math.ceil((schedule.durationSeconds + 60) / dt)

	while not finished and frames < maxFrames do
		--[[
			One target per frame, not every live target at once.

			The marker's own fire rate gates the Range exactly as it gates a
			match, so three shots stamped with the same clock time resolve as
			one shot and two rejections. Spraying the whole live set every frame
			therefore engaged one target per lane-dwell on Switch -- three
			seconds between eliminations on a drill whose entire subject is the
			swing between targets, which scored zero and looked like a scoring
			bug rather than a probe that cannot pull a trigger three times in an
			instant. A player picks the next target; so does this.
		]]
		if not opts.silent and t >= nextShotAt then
			for _, target in ipairs(Drills.activeAt(schedule, t)) do
				if not engaged[target.id] then
					engaged[target.id] = true
					local world = toWorld(target.position + target.velocity * (t - target.spawnAt))
					local velocity = Drills.rotateToWorld(frame, target.velocity)
					local solved = Ballistics.solveLead(spec, muzzle, world, velocity)
					if solved then
						event("FireMarker").OnServerEvent:fire(player, {
							origin = Units.vectorToStuds(muzzle),
							direction = (solved - muzzle).Unit,
							stance = "standing",
							clientTime = t,
						})
						shotsTaken += 1
						nextShotAt = t + shotInterval
						--- After a shot the crosshair is where the shot went,
						--- until the next cue moves it.
						currentAim = (solved - muzzle).Unit
					end
					break
				end
			end
		end
		if t >= nextAimAt then
			nextAimAt = t + aimReportSeconds
			event("ReportAim").OnServerEvent:fire(player, currentAim)
		end
		if opts.fireUpwardEveryFrame then
			event("FireMarker").OnServerEvent:fire(player, {
				origin = Units.vectorToStuds(muzzle),
				direction = V3.new(0, 1, 0),
				stance = "standing",
				clientTime = t,
			})
		end
		heartbeat:fire(dt)
		t += dt
		frames += 1
	end
	return finished, t, shotsTaken, schedule
end

local ranAny = false
for _, drillId in ipairs(Drills.list()) do
	local result, elapsed, shotsTaken, schedule = runDrill(drillId)
	assert(result, `{drillId} must finish on its own clock`)
	assert(shotsTaken > 0, `{drillId}: the probe must actually have fired`)
	assert(result.drill == drillId, "the result must name the drill")

	--[[
		The deadline is the deadline.

		`finished` only flips once the last ball has landed, and the loop used to
		keep accepting new trigger pulls in the meantime -- so a player firing at
		the sky could hold a 60 s drill open past 80 s. Shots already in the air
		still get to resolve, within the drain window, and nothing longer.
	]]
	assert(elapsed <= schedule.durationSeconds + cfg.shotDrainSeconds + 1,
		`{drillId} ran {string.format("%.1f", elapsed)}s, past its {schedule.durationSeconds}s deadline plus drain`)

	--[[
		A solved shot must land. Every drill, not just the stationary one -- a
		coordinate error in a moving-target drill hides behind the lead solution
		unless the solution is computed in the same space the target lives in.
	]]
	assert(result.hits > 0,
		`{drillId}: a solved shot must hit (got {result.hits} of {result.shots} shots)`)
	assert(result.hits / math.max(1, result.shots) > 0.5,
		`{drillId}: a solved shot should usually hit (got {result.hits}/{result.shots})`)
	assert(result.score > 0, `{drillId}: a hitting run must score above zero`)
	assert(result.rating >= 0 and result.rating <= 100, `{drillId}: rating stays on the 0-100 curve`)

	--[[
		Shots are trigger pulls; expired targets are missed opportunities.

		These used to share one counter, so "accuracy" was the fraction of
		OPPORTUNITIES taken rather than the fraction of BALLS that landed, and a
		player who never fired read the same as one who missed everything.
	]]
	assert(result.shots <= shotsTaken,
		`{drillId}: counted {result.shots} shots for {shotsTaken} trigger pulls`)
	assert(result.missedOpportunities >= 0, `{drillId}: missed opportunities must be counted separately`)

	--- The rating has to come from the axis the drill claims to grade.
	local drillCfg = Config.require("range", "drills." .. drillId)
	assert(result.fundamental == drillCfg.fundamental, `{drillId}: the result must name its fundamental`)
	if drillCfg.secondaryFundamental then
		assert(result.secondaryFundamental == drillCfg.secondaryFundamental and result.secondaryRating,
			`{drillId} declares a secondary fundamental and must actually measure it`)
	end

	local scored = event("DrillScore").sent[1]
	assert(scored, `{drillId}: the client must be sent its score`)
	assert(scored.hits == result.hits and scored.shots == result.shots,
		`{drillId}: the client's score must match the server's`)
	assert(scored.rating and scored.accuracy ~= nil,
		`{drillId}: the client must be sent the rating and accuracy, not just a hit count`)

	assert(not RangeService.isActive(player), `{drillId}: the drill must clear itself when it ends`)
	assert(#stage:GetChildren() == 0, `{drillId}: the range must be torn down when the drill ends`)

	print(string.format(
		"  %-9s %d/%d hits, %d missed, score %d, %s %d",
		drillId, result.hits, result.shots, result.missedOpportunities,
		result.score, result.fundamental, math.floor(result.rating)
	))
	ranAny = true
end
assert(ranAny, "at least one drill must have run")

--------------------------------------------------------------------------------
-- The wire the client actually receives
--------------------------------------------------------------------------------

do
	resetEvents()
	assert(RangeService.start(player, "popup", 99), "popup must start")
	local state = event("MatchStateChanged").sent[1]
	assert(state and state.phase == "live", "starting a drill must put the client in the live phase")
	assert(state.drill == "popup", "the client must be told which drill it is")
	--[[
		The Range enters straight into `live`. The client resets hopper, spread
		and outs on `warmup` or on a round change and gets neither here, so it
		needs something on this payload to reset on -- without it a drill
		inherited the previous match's half-empty hopper and out count.
	]]
	assert(state.mode == "range" and state.drillName,
		"a drill must arrive as its own presentation state, not as a match round")

	assert(not RangeService.start(player, "popup", 99), "a second concurrent drill must be refused")

	event("FireMarker").OnServerEvent:fire(player, {
		origin = Units.vectorToStuds(muzzle),
		direction = V3.new(0, 0, 1),
		stance = "standing",
		clientTime = 0,
	})

	local fired = event("MarkerFired").sent[1]
	assert(fired, "the range must tell the client about its own shot")

	--[[
		Every wire in this project speaks metres, and this one did not.

		RangeService sent `Units.vectorToStuds(muzzle)` while Tracers.fire takes
		metres and converts them itself, so every tracer on the range began
		three and a half times further from the player than the muzzle it
		claimed to come from. Asserted against the shot's own height: a muzzle is
		about chest high in metres and about four in studs.
	]]
	assert(math.abs(fired.origin.Y - chest) < 0.5,
		`MarkerFired origin Y is {fired.origin.Y}, expected about {chest} -- this wire is in metres, not studs`)
	assert(fired.source == "self",
		"the range's own shots must be marked, or the client plays enemy fire at the player")

	--[[
		A self event is an acknowledgement, not a tracer.

		`Client/init.client.luau` calls `Tracers.fire(origin, direction, spec)`
		on this remote, and the Range sends no spec -- which threw on every
		accepted Range shot. It also already drew a predicted tracer for this
		exact trigger pull, so rendering this one would put two balls in the air.
		The contract is: no spec means do not render, and `ammo` is what the
		client reconciles its hopper against.
	]]
	assert(fired.spec == nil,
		"a self MarkerFired must not carry a spec -- the client already drew this shot")
	assert(type(fired.ammo) == "number",
		"a self MarkerFired must carry the authoritative hopper count to reconcile against")

	RangeService.stop(player)
	assert(not RangeService.isActive(player), "stop must clear the session")
	assert(#stage:GetChildren() == 0, "stop must tear the range down")
end

--------------------------------------------------------------------------------
-- The shapes: a graze outside the visible ball must miss
--------------------------------------------------------------------------------

do
	--[[
		The visible target is a sphere of radius r centred at `position`, and
		`ProjectileSim` reads `position` as the BOTTOM of a vertical capsule of
		`height`. Passing the centre with height 2r made the hittable column run
		from y-r to y+3r: shots through empty space two diameters above the
		visible ball counted as hits.

		Fired flat and level at a fixed target, offset vertically. Ball radius
		plus target radius is the real contact distance, so the test offsets are
		set well outside it in each direction.
	]]
	local ProjectileSim = env.require(env.Server.Ballistics.ProjectileSim)
	local MapGeometry = env.require(env.Shared.MapGeometry)
	local world = {
		id = "shapeProbe", volumes = {}, navNodes = {}, navEdges = {}, anchors = {},
		prePlacement = {}, sightlines = {}, botSpawns = {},
		playerSpawn = { position = { 0, 0, 0 }, lookAt = { 0, 0, 1 } },
		playerRespawns = {}, bounds = cfg.bounds,
		engagementBand = { minMetres = 10, maxMetres = 40 },
	}
	assert(MapGeometry.cast(world, V3.new(0, 1, 0), V3.new(0, 1, 5)) == nil, "the shape probe has no walls")

	local radius = 0.35
	local ballRadius = ballisticsData.ballRadiusMetres or 0.0086
	local centre = V3.new(0, chest, 15)

	local function grazes(offsetY: number): boolean
		local sim = ProjectileSim.new(world, ballisticsData)
		local origin = V3.new(0, chest + offsetY, 0)
		local solved = Ballistics.solveLead(spec, origin, centre + V3.new(0, offsetY, 0), V3.zero)
		if not solved then return false end
		sim:fire({
			origin = origin, direction = (solved - origin).Unit, spec = spec,
			ownerId = "probe", team = "player", t = 0,
		})
		local hit = false
		for i = 1, 600 do
			for _, e in ipairs(sim:step(1 / 240, i / 240, { {
				id = "ball", team = "target", position = centre, velocity = V3.zero,
				radius = radius, height = 0, alive = true,
			} })) do
				if e.kind == "target" then hit = true end
			end
			if #sim.projectiles == 0 then break end
		end
		return hit
	end

	assert(grazes(0), "a level shot at the centre of the ball must hit it")
	local clear = radius + ballRadius + 0.15
	assert(not grazes(clear),
		`a shot passing {string.format("%.2f", clear)} m ABOVE a {radius} m ball must miss -- `
			.. "this is the capsule extending two diameters above the visible target")
	assert(not grazes(-clear),
		`a shot passing {string.format("%.2f", clear)} m BELOW a {radius} m ball must miss`)
end

--------------------------------------------------------------------------------
-- Peek: the cue is delivered, and acting on it is what the rating measures
--------------------------------------------------------------------------------

do
	local onCue = runDrill("peek")
	local cues = event("DrillCue").sent
	--[[
		The cue has to arrive BEFORE the target, or it is a caption.

		Peek's angles are deliberately learnable and the drill grades whether
		the crosshair was already parked on the one that is coming. The bearing
		has been authored in the schedule since the drill was written and the
		Range never sent it, which left Peek indistinguishable from Pop-Up with
		a longer wait.
	]]
	assert(#cues > 0, "Peek must announce the bearing its targets will appear at")
	local schedule = Drills.schedule("peek", 99)
	local byId = {}
	for _, target in ipairs(schedule.targets) do byId[target.id] = target end
	for _, cue in ipairs(cues) do
		local target = byId[cue.targetId]
		assert(target, "a cue must name a real target")
		assert(cue.bearingDeg == target.announcedBearingDeg, "the cue must announce the target's own bearing")
		assert(cue.inSeconds > 0, "a cue that arrives with the target is not a cue")
	end
	local seen = {}
	for _, cue in ipairs(cues) do
		assert(not seen[cue.targetId], "a cue repeated every frame is noise, not a cue")
		seen[cue.targetId] = true
	end

	--[[
		The control.

		The same probe, hitting every target just as fast, but never moving its
		crosshair onto the announced angle ahead of the reveal. Crosshair
		placement is exactly the difference between those two players, so a
		rating that cannot separate them is not measuring it -- which is what
		the previous-shot approximation did, scoring both at zero.
	]]
	local ignoringCue = runDrill("peek", { ignoreCue = true })
	assert(onCue.hits == ignoringCue.hits,
		"the control must land the same shots, so only placement differs")
	assert(onCue.rating > ignoringCue.rating + 10,
		`parking on the announced angle must rate above ignoring it `
			.. `(got {math.floor(onCue.rating)} vs {math.floor(ignoringCue.rating)})`)
	print(string.format(
		"  peek       crosshair placement %d on the cue, %d ignoring it",
		math.floor(onCue.rating), math.floor(ignoringCue.rating)
	))
end

--------------------------------------------------------------------------------
-- The deadline, with nobody firing and with somebody firing forever
--------------------------------------------------------------------------------

do
	local result, elapsed = runDrill("popup", { silent = true })
	assert(result, "a drill nobody fires at must still end on its clock")
	assert(elapsed <= Config.require("range", "drills.popup.durationSeconds") + cfg.shotDrainSeconds + 1,
		"an unengaged drill must end on time")
	assert(result.shots == 0, "nobody fired, so nothing may be counted as a shot")
	assert(result.missedOpportunities > 0,
		"every target came and went unengaged, and those are missed opportunities")
	assert(result.hits == 0, "nobody fired, so nothing hit")
	assert(result.accuracy == 0, "no shots means no accuracy, not a division by zero")
end

do
	local duration = Config.require("range", "drills.popup.durationSeconds")
	local result, elapsed = runDrill("popup", { silent = true, fireUpwardEveryFrame = true })
	assert(result, "a drill fired at continuously must still end")
	--[[
		Firing at the sky used to keep a 60 s drill alive past 80 s: every new
		trigger pull after the deadline added a projectile that had to land
		before the drill could finish.
	]]
	assert(elapsed <= duration + cfg.shotDrainSeconds + 1,
		`continuous fire held the drill open to {string.format("%.1f", elapsed)}s, past {duration}s plus drain`)
end

--------------------------------------------------------------------------------
-- Free, always
--------------------------------------------------------------------------------

--- The Range is free. Data/range.json pays zero and ship-check asserts it; this
--- checks the live loop never invented a payout of its own.
assert(cfg.payout == 0, "the Range must not pay")
for _, sent in ipairs(event("MatchSummary").sent) do
	assert((sent.payout or 0) == 0, "a drill must never pay out")
end

-- Practice must agree with the equipped marker's handling without a pod cap.
do
 local Profile = env.require(env.Server.Economy.Profile)
 local MarkerState = env.require(env.Shared.MarkerState)
 local handle = Profile.load(player.UserId)
 local saved = handle.data.loadout
 handle.data.loadout = table.clone(saved)
 handle.data.loadout.hopper = "forceFed"
 handle.data.loadout.tank = "carbon"
 resetEvents()
 assert(RangeService.start(player, "popup", 99))
 local entry = event("MatchStateChanged").sent[1]
 assert(entry.kit and entry.loadout, "Range entry must include its resolved kit")
 assert(entry.kit.podCount == nil, "practice refills must be unlimited")
 local predicted = MarkerState.new(markerData, entry.kit)
 assert(predicted.capacity > markerData.hopperCapacity, "equipped hopper did not reach practice")
 assert(predicted.reloadSeconds < markerData.reloadSeconds, "equipped tank did not reach practice")
 local fire = { origin = Units.vectorToStuds(muzzle), direction = V3.yAxis, stance = "standing", clientTime = 0 }
 assert(predicted:fire(0))
 event("FireMarker").OnServerEvent:fire(player, fire)
 assert(event("MarkerFired").sent[1].ammo == predicted.ammo, "Range server and prediction disagree on hopper capacity")
 event("RequestReload").OnServerEvent:fire(player)
 assert(predicted:reload(0))
 heartbeat:fire(predicted.reloadSeconds + 0.01)
 assert(predicted:fire(predicted.reloadSeconds + 0.01))
 event("FireMarker").OnServerEvent:fire(player, fire)
 assert(#event("MarkerFired").sent == 2, "Range server did not complete the equipped reload on time")
 assert(event("MarkerFired").sent[2].ammo == predicted.ammo, "Range reload refilled to a different capacity")
 -- More refills than any finite stock must stay available in the prediction.
 for i = 1, 12 do
  local now = i * (predicted.reloadSeconds + 1)
  predicted:update(now)
  predicted:fire(now)
  assert(predicted:reload(now), "practice prediction ran out of pods")
 end
 RangeService.stop(player)
 handle.data.loadout = saved
end

print(string.format("Range checks passed: all %d drills ran end to end.", #Drills.list()))
