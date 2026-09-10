--!strict
-- CTF gets accessible keep decks and home-team spawns without changing courses.
-- The same prepared data builds physical Parts and authoritative collision/nav.
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS.Shared.Config)
local FlagArena = {}

function FlagArena.prepare(source: any): any
	local cfg = Config.require("gamemodes", "captureTheFlag.arena")
	local data = table.clone(source)
	data.geometry = table.clone(source.geometry)
	data.terrain = {}
	for _, piece in ipairs(source.terrain or {}) do
		local solid = table.clone(piece)
		if solid.walkable then solid.cover = true end
		table.insert(data.terrain, solid)
	end
	data.navNodes = table.clone(source.navNodes)
	data.captureTheFlag = table.clone(source.captureTheFlag)
	for _, team in ipairs({ "enemy", "player" }) do
		local side = if team == "enemy" then 1 else -1
		data.captureTheFlag[team .. "Flag"] = { position = { cfg.flagXMetres, cfg.deckHeightMetres, side * cfg.flagZMetres } }
		local function node(x: number, y: number, z: number)
			table.insert(data.navNodes, { x, y, side * z })
		end
		local function tread(index: string, z: number, top: number, length: number, addNode: boolean?)
			table.insert(data.geometry, { id = `ctf_{team}_{index}`, shape = "box",
				position = { 0, top - cfg.stairsStepMetres / 2, side * z },
				size = { cfg.stairsWidthMetres, cfg.stairsStepMetres, length },
				colorKey = "timber", cover = true, walkable = true })
			if addNode ~= false then node(0, top, z) end
		end
		node(0, 0, cfg.stairsStartMetres - cfg.stairsTreadMetres)
		local count = math.ceil(cfg.stairsTopMetres / cfg.stairsStepMetres)
		for i = 1, count do
			tread(`up{i}`, cfg.stairsStartMetres + (i - 0.5) * cfg.stairsTreadMetres,
				math.min(cfg.stairsTopMetres, i * cfg.stairsStepMetres), cfg.stairsTreadMetres, i == 1 or i == count or i % Config.require("gamemodes", "captureTheFlag.navigation.nodeEverySteps") == 0)
		end
		local start = cfg.stairsStartMetres + count * cfg.stairsTreadMetres
		tread("landing", (start + cfg.landingEndMetres) / 2, cfg.stairsTopMetres, cfg.landingEndMetres - start)
		local down = math.ceil((cfg.stairsTopMetres - cfg.deckHeightMetres) / cfg.stairsStepMetres)
		local depth = (cfg.deckEntryMetres - cfg.landingEndMetres) / down
		-- The existing deck is the final tread; duplicating its top causes shimmer.
		for i = 1, down - 1 do
			tread(`down{i}`, cfg.landingEndMetres + (i - 0.5) * depth,
				math.max(cfg.deckHeightMetres, cfg.stairsTopMetres - i * cfg.stairsStepMetres), depth, i == 1 or i == down - 1 or i % Config.require("gamemodes", "captureTheFlag.navigation.nodeEverySteps") == 0)
		end
		local bridgeSteps = math.ceil(cfg.bridgeHeightMetres / cfg.stairsStepMetres)
		for i = 1, bridgeSteps do
			tread(`bridge{i}`, cfg.bridgeEndMetres + (bridgeSteps - i + 0.5) * cfg.stairsTreadMetres,
				math.min(cfg.bridgeHeightMetres, i * cfg.stairsStepMetres), cfg.stairsTreadMetres, i == 1 or i == bridgeSteps or i % Config.require("gamemodes", "captureTheFlag.navigation.nodeEverySteps") == 0)
		end
		node(0, cfg.deckHeightMetres, cfg.deckEntryMetres)
		node(cfg.flagXMetres, cfg.deckHeightMetres, cfg.flagZMetres)
		for _, offset in ipairs(cfg.spawnOffsetsMetres) do
			node(cfg.flagXMetres + offset[1], cfg.deckHeightMetres, cfg.flagZMetres + offset[2])
		end
	end
	data.playerSpawn = { position = { cfg.flagXMetres, cfg.deckHeightMetres, -cfg.flagZMetres }, lookAt = { 0, cfg.deckHeightMetres, 0 } }
	data.playerRespawns, data.botSpawns = {}, {}
	for _, offset in ipairs(cfg.spawnOffsetsMetres) do
		for _, side in ipairs({ -1, 1 }) do
			table.insert(if side == 1 then data.botSpawns else data.playerRespawns, {
				position = { cfg.flagXMetres + offset[1], cfg.deckHeightMetres, side * (cfg.flagZMetres + offset[2]) },
				lookAt = { 0, cfg.deckHeightMetres, 0 },
			})
		end
	end
	return data
end

return FlagArena
