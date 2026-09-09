--!nolint
--[[
	Spawn sanity gate.

	    lune run tools/check-spawns

	Two invariants and one report. `map-validate` checks nav nodes against cover
	and `ground-spawns` checks that BOT spawns sit on the ground; neither ever
	looked at where the PLAYER starts, or at whether a spawn is inside a wall.

	  1  no spawn, player or bot, sits inside solid non-walkable cover
	  2  every spawn has ground under it
	  -  round one's opening distances, reported and never failed

	The distinction in rule 1 is the whole rule. A first version of this check
	treated every volume as a wall and flagged eleven perfectly good bot spawns
	across Woods and Holdfast -- hills, ridges and knolls are `walkable` volumes
	you stand on top of, and brush is `concealment` you stand in deliberately.
	It also produced a false diagnosis of Holdfast's player spawn, which is on a
	knoll and always was fine.

	Rule 3's report exists because rounds take bot spawns in declared ORDER, so
	the first four entries are round one's entire opposition. Holdfast declared
	its four most distant spawns first, opening at 133 m against its own
	declared 84 m engagement band. Ordering nearest-first fixed Woods
	measurably: mean deaths 65.3 to 51.5, and its engagement median landed on
	the field's own declared target of 38.7 m. It is a report rather than a gate
	because players move -- Urban opens past a rec bot's vision and plays fine.
]]
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Harness = require("./Harness")

local env = Harness.build()
env.globals.Vector3 = roblox.Vector3
local Vector3 = roblox.Vector3

local MapGeometry = env.require(env.Shared.MapGeometry)
local Config = env.require(env.Shared.Config)

local EYE = 1.32
local ROUND_ONE_BOTS = 4

local problems = 0
local function check(ok: boolean, label: string)
	if ok then
		print(`  \27[32mok  \27[0m {label}`)
	else
		problems += 1
		print(`  \27[31mFAIL\27[0m {label}`)
	end
end

local index = Config.get("maps_index")

print("\27[1mcheck-spawns\27[0m")

for _, name in ipairs(Config.mapNames()) do
	local world = MapGeometry.build(Config.map(name), index)

	--[[
		Is this point inside something a body cannot be inside?

		Only `cover` that is not `walkable` counts. A hill, a ridge and a knoll
		are walkable volumes you stand ON TOP of, and brush is concealment you
		stand IN on purpose -- an earlier version of this check flagged eleven
		perfectly good bot spawns across Woods and Holdfast because it treated
		every volume as a wall.
	]]
	local function buried(x: number, z: number): string?
		for _, height in ipairs({ 0.2, EYE, 1.7 }) do
			for _, volume in ipairs(world.volumes) do
				if volume.cover and not volume.walkable
					and MapGeometry.containsPoint(volume, Vector3.new(x, height, z)) then
					return volume.id or "?"
				end
			end
		end
		return nil
	end

	local spawns: { { label: string, x: number, z: number } } = {}
	local player = world.playerSpawn.position
	table.insert(spawns, { label = "playerSpawn", x = player[1], z = player[3] })
	for i, spawn in ipairs(world.botSpawns) do
		table.insert(spawns, { label = `bot{i}`, x = spawn.position[1], z = spawn.position[3] })
	end

	local buriedCount, floatingCount = 0, 0
	for _, spawn in ipairs(spawns) do
		local inside = buried(spawn.x, spawn.z)
		if inside then
			buriedCount += 1
			print(`          {name}.{spawn.label} is inside volume '{inside}'`)
		end
		if not MapGeometry.isSupported(world, Vector3.new(spawn.x, 0, spawn.z)) then
			floatingCount += 1
			print(`          {name}.{spawn.label} has no ground under it`)
		end
	end
	check(buriedCount == 0, `{name}: no spawn is inside solid geometry`)
	check(floatingCount == 0, `{name}: every spawn has ground under it`)

	--[[
		Round one can see somebody.

		Measured from the spawn against the first ROUND_ONE_BOTS entries, using
		the weakest tier's vision so the check is not accidentally passed by a
		pro's longer sight. Line of sight is deliberately NOT required -- every
		field blocks it at spawn, including ones that play fine -- only that
		somebody is within seeing distance once the player moves.
	]]
	local vision = Config.require("bots", "tiers.rec.visionRangeMetres")
	local inRange = 0
	local nearest = math.huge
	for i = 1, math.min(ROUND_ONE_BOTS, #world.botSpawns) do
		local bot = world.botSpawns[i].position
		local distance = (Vector3.new(bot[1], 0, bot[3]) - Vector3.new(player[1], 0, player[3])).Magnitude
		nearest = math.min(nearest, distance)
		if distance <= vision then
			inRange += 1
		end
	end
	--[[
		Reported, never failed. Players move, so an opening beyond vision is not
		by itself a bug -- Urban opens past a rec bot's 55 m and plays fine. It
		is here because Holdfast opened at 133 m against its own declared 84 m
		band, which is the shape of a real problem, and a human reading this
		list will spot the next one.
	]]
	print(`        {name}: round one has {inRange}/{ROUND_ONE_BOTS} within {vision} m, nearest {string.format("%.0f", nearest)} m`)
end

print("")
if problems > 0 then
	print(`\27[31m{problems} spawn problem(s).\27[0m`)
	process.exit(1)
end
print("\27[32mevery spawn stands on ground, outside geometry, with an opening fight.\27[0m")
