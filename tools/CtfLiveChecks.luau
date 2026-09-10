--!strict
-- Driven by run-live-checks, using its real MatchService and controllable wire.
return function(ctx: any)
	local env, service, event, advance = ctx.env, ctx.service, ctx.event, ctx.advance
	local Config = env.require(env.Shared.Config)
	local Profile = env.require(env.Server.Economy.Profile)
	local Units = env.require(env.Shared.Units)
	local roblox = require("@lune/roblox")
	local player = ctx.player
	local profile = Profile.load(player.UserId)
	local cfg = Config.require("gamemodes", "captureTheFlag")
	local Arena = env.require(env.Server.Match.FlagArena)
	local data = Arena.prepare(Config.map("holdfast"))
	local function vec(a: any): any return roblox.Vector3.new(a[1],a[2],a[3]) end
	local home, enemy = vec(data.captureTheFlag.playerFlag.position), vec(data.captureTheFlag.enemyFlag.position)
	local function at(where: any)
		ctx.root.Position = Units.vectorToStuds(where) + roblox.Vector3.new(0, ctx.root.Size.Y/2 + 1.5, 0)
	end
	local function latest(): any
		local sent = event("MatchStateChanged").sent
		for i = #sent, 1, -1 do if sent[i].ctf then return sent[i].ctf end end
		error("CTF never sent its HUD state")
	end
	--[[
		A player who has cleared Woods -- as a GAUNTLET.

		This seeded `bestClears`, which used to be the map-unlock authority and
		is not any more: it keeps the cleanest clear of a field whatever produced
		it, so a flawless Shoothouse run masked a three-out gauntlet clear and
		opened the next map on a mode the chapter gate does not accept.
		`gauntletClears` is the one authority now, and this fixture asks for the
		thing it is actually pretending to have.
	]]
	profile.data.bestClears.woods = { deaths = 0, tier = "rec", mode = "gauntlet" }
	profile.data.gauntletClears = { woods = { rec = 0 } }
	assert(not service.start(player, "holdfast", "rec", 54, "captureTheFlag"), "CTF chapter gate was bypassed")
	table.insert(profile.data.chaptersCompleted, "backForty")
	assert(not service.start(player, "speedball", "rec", 54, "captureTheFlag"), "CTF accepted an unsupported map")
	local first = #ctx.madeBots + 1
	assert(service.start(player, "holdfast", "rec", 54, "captureTheFlag"))
	at(enemy)
	advance(0.1)
	assert(latest().enemyFlag == "home", "flags must not be taken during warmup")
	-- Park mock bots out of contact so each rule can be isolated.
	for i = first, #ctx.madeBots do ctx.madeBots[i].position = roblox.Vector3.new(30,0,0) end
	advance(Config.require("match", "warmupSeconds") + 0.1)
	assert(latest().carrying, "walking into the flag did not pick it up")
	assert(latest().sprintMultiplier < 1, "carrier speed modifier never reached the client")
	at(home); advance(0.1)
	assert(latest().score.player == 1, "returning to home failed to capture")
	-- Wiping every bot must leave CTF running, then replace the roster at nine seconds.
	local count = #ctx.madeBots
	for i = first, count do ctx.madeBots[i]:eliminate(0) end
	advance(0.1)
	assert(service.isActive(player), "CTF incorrectly ended on a squad wipe")
	advance(cfg.respawn.botSeconds - 0.2)
	assert(#ctx.madeBots == count, "CTF bots respawned early")
	advance(0.4)
	assert(#ctx.madeBots == count + cfg.squadSize, "CTF failed to replace its whole squad")
	for i = count + 1, #ctx.madeBots do
		assert((ctx.madeBots[i].position - enemy).Magnitude < 10, "CTF replacement did not spawn in its own keep")
		ctx.madeBots[i].position = roblox.Vector3.new(30,0,0)
	end
	-- Both flags out: no score until the bot carrier is marked and our flag recovered.
	local carrier = ctx.madeBots[count+1]
	carrier.position = home
	at(enemy); advance(0.1)
	carrier.position = roblox.Vector3.new(20,0,0)
	at(home); advance(0.1)
	assert(latest().score.player == 1 and latest().playerFlag == "carried", "missing-home flag allowed a score")
	carrier:eliminate(0); advance(0.1)
	assert(latest().playerFlag == "dropped", "marked carrier failed to drop its flag")
	at(carrier.position); advance(0.1)
	assert(latest().playerFlag == "home", "touch return failed")
	at(home); advance(0.1)
	assert(latest().score.player == 2, "recovered flag did not unblock the capture")
	at(enemy); advance(0.1); at(home); advance(0.1)
	assert(not service.isActive(player), "capture target did not end CTF")
	local report = event("MatchSummary").sent[#event("MatchSummary").sent]
	assert(report.mode == "captureTheFlag" and report.ctf.winner == "player", "CTF summary lost its mode/winner")
	assert(report.breakdown.total == cfg.payout.perCapture*3 + cfg.payout.perFlagReturn + cfg.payout.winBonus, "objective payout is wrong")
	assert(not (profile.data.gauntletClears and profile.data.gauntletClears.holdfast), "CTF wrote a Gauntlet clear")
	assert(not profile.data.bestClears.holdfast, "CTF polluted the field-unlock clear table")
	local balance, matches = profile.data.currency, profile.data.lifetime.matches
	service.stop(player); advance(0.2)
	assert(profile.data.currency == balance and profile.data.lifetime.matches == matches, "CTF paid or recorded twice")
	print("CTF live checks passed: gates, warmup, pickup, capture, denial, recovery, full-squad respawn, victory, objective payout and exactly-once settlement.")
	-- Use an actual delayed scheduler for the player lifecycle. The shared smoke
	-- harness normally runs delay immediately, which cannot prove respawn timing.
	local originalDelay, originalLoad = env.globals.task.delay, player.LoadCharacterAsync
	local now, loads, pending = 0, 0, {}
	env.globals.task.delay = function(seconds, fn, ...)
		table.insert(pending, { at = now + seconds, fn = fn, args = table.pack(...) })
	end
	player.LoadCharacterAsync = function() loads += 1 end
	local function tickFor(seconds)
		local left = seconds
		while left > 0 do
			local slice = math.min(1/60, left)
			now += slice; advance(slice); left -= slice
			for i = #pending, 1, -1 do
				if pending[i].at <= now then
					local job = table.remove(pending, i); job.fn(table.unpack(job.args, 1, job.args.n))
				end
			end
		end
	end
	first = #ctx.madeBots + 1
	assert(service.start(player, "holdfast", "rec", 55, "captureTheFlag"))
	for i = first, #ctx.madeBots do ctx.madeBots[i].position = roblox.Vector3.new(30,0,0) end
	at(enemy); tickFor(Config.require("match", "warmupSeconds") + 0.1)
	local droppedAt = roblox.Vector3.new(20,0,20)
	at(droppedAt)
	ctx.queueHits({ctx.hit("bots", "player")}); tickFor(0.1)
	assert(latest().enemyFlag == "dropped" and not latest().carrying, "player elimination failed to drop the flag")
	local loadCount = loads
	tickFor(cfg.respawn.playerSeconds - 0.3)
	assert(loads == loadCount, "player respawned early")
	tickFor(0.4)
	assert(loads == loadCount + 1, "player did not respawn on schedule")
	tickFor(Config.require("match", "respawn.invulnerabilitySeconds") + 0.2)
	ctx.queueHits({ctx.hit("bots", "player")}); tickFor(0.1)
	service.stop(player)
	loadCount = loads
	tickFor(cfg.respawn.playerSeconds + 0.2)
	assert(loads == loadCount and not service.isActive(player), "pending respawn resurrected a stopped match")
	env.globals.task.delay, player.LoadCharacterAsync = originalDelay, originalLoad

	local limit = cfg.timeLimitSeconds
	cfg.timeLimitSeconds = 0.5
	first = #ctx.madeBots + 1
	assert(service.start(player, "holdfast", "rec", 56, "captureTheFlag"))
	for i = first, #ctx.madeBots do ctx.madeBots[i].position = roblox.Vector3.new(30,0,0) end
	at(home); advance(Config.require("match", "warmupSeconds") + 1)
	cfg.timeLimitSeconds = limit
	report = event("MatchSummary").sent[#event("MatchSummary").sent]
	assert(not service.isActive(player) and report.ctf.winner == "draw" and report.breakdown.total == 0, "idle timeout did not draw with zero payout")
	first = #ctx.madeBots + 1
	assert(service.start(player, "holdfast", "rec", 57, "captureTheFlag"))
	for i = first, #ctx.madeBots do ctx.madeBots[i].position = roblox.Vector3.new(30,0,0) end
	at(roblox.Vector3.new(-30,0,0)); advance(Config.require("match", "warmupSeconds") + 0.1)
	carrier = ctx.madeBots[first]
	for _ = 1, cfg.capturesToWin do
		carrier.position = home; advance(0.1)
		carrier.position = enemy; advance(0.1)
	end
	report = event("MatchSummary").sent[#event("MatchSummary").sent]
	assert(not service.isActive(player) and report.ctf.winner == "bots" and report.breakdown.total == 0, "bot captures did not produce a defeat without a win bonus")
	print("CTF lifecycle checks passed: carrier elimination, timed player respawn, cancelled pending respawn, timeout/draw and bot victory.")

end
