--!strict
local Harness = require("./Harness")
local roblox = require("@lune/roblox")
local env = Harness.build()
local Config = env.require(env.Shared.Config)
local Geometry = env.require(env.Shared.MapGeometry)
local Arena = env.require(env.Server.Match.FlagArena)
local Navigation = env.require(env.Server.Match.FlagNavigation)
local FlagMatch = env.require(env.Server.Match.FlagMatch)
local data = Arena.prepare(Config.map("holdfast"))
local world = Geometry.build(data, Config.get("maps_index"))
local folder = roblox.Instance.new("Folder")
local game = FlagMatch.new(data, world, folder)
local nav = game.nav
local clockStart = os.clock()
print(`CTF navigation: {#nav.navNodes} supported nodes`)
local bot = { position = game.rules.flags.enemy.home, velocity = roblox.Vector3.zero, facing = roblox.Vector3.new(0,0,-1) }
local function travel(to: any)
	bot._flagRoute = nil
	local destination = to
	for tick = 1, 3600 do
		Navigation.step(nav, bot, destination, 1/60, tick/60, 6)
		if (bot.position - destination).Magnitude <= 0.5 then return tick/60 end
	end
	error(`CTF runner stuck at {bot.position}, destination {destination}`)
end
print(`Enemy runner reaches player flag in {travel(game.rules.flags.player.home)}s`)
print(`Carrier returns home in {travel(game.rules.flags.enemy.home)}s`)
game:destroy()
assert(#folder:GetChildren() == 0, "CTF presentation leaked after cleanup")
print(string.format("CTF arena, objective navigation and visual lifecycle passed (route checks %.2fs)", os.clock() - clockStart))

-- Real controllers must obey the adapter, not just a test calling move directly.
local Bots = env.require(env.Server.Bots.BotController)
local Coordinator = env.require(env.Server.Bots.SquadCoordinator)
local Rng = env.require(env.Shared.Rng)
local rng = Rng.new(734)
local coordinator = Coordinator.new("rec", world, rng:fork(1))
local assignments = coordinator:assign(6)
local run = FlagMatch.new(data, world, folder)
local bots = {}
for i, spawn in ipairs(world.botSpawns) do
	local assignment = assignments[i]
	local at = roblox.Vector3.new(spawn.position[1], spawn.position[2], spawn.position[3])
	table.insert(bots, Bots.new({ id = "ctf_bot" .. i, name = "Runner " .. i, tier = "rec",
		role = assignment.role, anchorId = assignment.anchorId, position = at,
		facing = roblox.Vector3.new(0,0,-1), world = world, coordinator = coordinator, rng = rng:fork(i + 1) }))
end
local player = { alive = false, position = run.rules.flags.player.home, velocity = roblox.Vector3.zero }
local dt = 1/30
local noOp = function() end
for tick = 1, math.ceil(run.rules.cfg.timeLimitSeconds/dt) do
	local t = tick*dt
	for i, member in ipairs(bots) do
		member:tick(dt, { t = t, dt = dt, player = player, squad = bots, moraleErrorMultiplier = 1,
			aliveCount = #bots, chatter = noOp, projectiles = { fire = function() error("bot fired at an absent player") end },
			navigate = run:navigator(member, i, bots, t) })
	end
	run:step(dt, player.position, false, bots, function() error("untargeted bot eliminated") end, noOp)
	if run.rules.finished then break end
end
assert(run.rules.winner == "bots" and run.rules.score.bots == run.rules.cfg.capturesToWin,
	"real CTF squad could not take and capture three flags before timeout")
print(string.format("Real CTF controllers: three autonomous captures in %.1fs of match time", run.rules.elapsed))
run:destroy()
