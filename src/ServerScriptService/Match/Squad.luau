--!strict
--[[
	Squad -- where a bot stands when a round opens, and what it is.

	Lifted out of MatchService, which had grown past 1,250 lines inside a single
	closure once horde landed. `check-static`'s length ratchet is what caught
	that: adding a mode to a function that size is how a God object stays one,
	and the honest answer to the gate was to pay the debt rather than raise the
	number it was frozen at.

	This owns placement and construction only. The match keeps the roster --
	`bots`, `botsById`, `avatars` are read from a dozen places in the loop and
	moving them would have been a rewrite rather than an extraction.

	Three modes place their people differently and that is the whole content of
	this module:

	  * A **course stage** puts its defenders ON the cover they hold, looking
	    down the approach, which is what makes a stage a band of the map rather
	    than a wave walking in from the back.
	  * A **gauntlet or horde wave** uses the authored spawns, fanned onto a
	    small ring when the squad outnumbers them -- Speedball has six spawns and
	    fields twelve, because adding more measurably broke the field.
	  * A **horde boss wave** fields a marshal, which is the same placement and a
	    very different target.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Config = require(ReplicatedStorage.Shared.Config)
local MapGeometry = require(ReplicatedStorage.Shared.MapGeometry)

local Server = ServerScriptService.Server
local BotController = require(Server.Bots.BotController)
local BotAvatar = require(Server.Match.BotAvatar)
local Endless = require(Server.Match.Endless)

local Squad = {}

export type Context = {
	world: MapGeometry.World,
	root: any,
	names: { string },
	botFolder: Instance,
	anchorById: { [string]: any },
	coordinator: any,
	assignments: { any },
	vecOf: ({ number }) -> Vector3,
}

--[[
	Where this bot starts, and which way it is looking.

	Ground-settled in every branch: the map data is authored to put everyone on
	the ground, but a Y typo used to produce a bot standing in mid-air and
	nothing in the pipeline could tell. This makes the worst case "on the roof
	of the thing underneath you" instead of "in the sky".
]]
local function placement(ctx: Context, round: any, ordinal: number): (Vector3, Vector3)
	local position: Vector3, facing: Vector3
	if round.stage then
		local ids = round.stage.anchorIds
		local anchor = ctx.anchorById[ids[((ordinal - 1) % #ids) + 1]]
		position = MapGeometry.groundPoint(ctx.world, ctx.vecOf(anchor.position))
		facing = round.stage.checkpoint.position - position
	else
		--- Reused spawns are fanned onto a small ring rather than stacking
		--- bodies at one point: deterministic, a metre and a half out, and
		--- settled onto whatever holds the point up like every other spawn.
		local slot = ((ordinal - 1) % #ctx.world.botSpawns) + 1
		local reuse = if round.captureTheFlag then 0 else math.floor((ordinal - 1) / #ctx.world.botSpawns)
		local spawn = ctx.world.botSpawns[slot]
		local at = ctx.vecOf(spawn.position)
		if reuse > 0 then
			local angle = (ordinal * 2.399963) + reuse
			at += Vector3.new(math.cos(angle), 0, math.sin(angle)) * (1.5 * reuse)
		end
		position = MapGeometry.groundPoint(ctx.world, at)
		facing = ctx.vecOf(spawn.lookAt) - position
	end
	facing = Vector3.new(facing.X, 0, facing.Z)
	if facing.Magnitude < 1e-6 then
		facing = Vector3.new(0, 0, -1)
	end
	return position, facing.Unit
end

--[[
	Builds one bot and its avatar, and starts it moving to its opening anchor.

	`ordinal` is its number within the round and keeps counting through horde
	replacements, so ids and spawn slots stay unique for a whole wave.
]]
function Squad.spawn(ctx: Context, round: any, ordinal: number, spawnSlot: number?): (any, any)
	local position, facing = placement(ctx, round, spawnSlot or ordinal)

	--- Replacements past the opening squad reuse an assignment and a name; ids
	--- stay unique because the ordinal keeps counting.
	local assignment = ctx.assignments[((ordinal - 1) % #ctx.assignments) + 1]
	--- One marshal per boss wave, fielded first so it is there for the whole
	--- wave rather than arriving late as a replacement.
	local boss = if round.endless and round.endless.isBoss and ordinal == 1
		then round.endless.boss
		else nil

	local bot = BotController.new({
		id = `r{round.index}_bot{ordinal}`,
		name = ctx.names[((ordinal - 1) % #ctx.names) + 1],
		tier = round.tier,
		role = assignment.role,
		anchorId = assignment.anchorId,
		position = position,
		facing = facing,
		world = ctx.world,
		coordinator = ctx.coordinator,
		rng = ctx.root:fork(round.index * 1000 + ordinal),
		--- Horde only. A copy, never the shared tier table, or wave 30 would
		--- permanently ruin wave 1.
		tierData = if round.endless
			then Endless.applyVeterancy(Config.require("bots", `tiers.{round.tier}`), round.endless)
			else nil,
		boss = boss,
	})

	-- Kit tracks tier, so a squad's difficulty is readable on sight -- and a
	-- marshal wears the marshal's, which is the only warning the player gets
	-- that the body is not worth shooting.
	local avatar = BotAvatar.new(bot.id, bot.name, ctx.botFolder, if boss then "marshal" else round.tier)
	avatar:setPosition(bot.position, bot.facing)

	local anchor = ctx.coordinator:anchorById(assignment.anchorId)
	if anchor and not round.captureTheFlag then
		BotController.pathTo(bot, ctx.vecOf(anchor.position))
		BotController.setState(bot, "repositioning", 0, "moving to opening anchor")
	end
	return bot, avatar
end

--[[
	Where the player comes back.

	A course sends you back to the checkpoint you reached -- not to the start,
	and not to whichever spawn is furthest from the squad. Losing your progress
	up the field is what the ten-second penalty is instead of.

	Everywhere else it is the authored respawn furthest from anyone still alive,
	which is the only thing standing between a respawn and being marked again
	before the player has finished loading their thumb onto the trigger.
]]
function Squad.respawnPoint(ctx: Context, round: any, bots: { any }): Vector3
	if round.stage then
		return MapGeometry.groundPoint(ctx.world, round.stage.checkpoint.position)
	end
	local best, chosen = -math.huge, MapGeometry.groundPoint(ctx.world, ctx.vecOf(ctx.world.playerRespawns[1].position))
	for _, entry in ipairs(ctx.world.playerRespawns) do
		local candidate = MapGeometry.groundPoint(ctx.world, ctx.vecOf(entry.position))
		local nearest = math.huge
		for _, bot in ipairs(bots) do
			if bot.alive then
				nearest = math.min(nearest, (bot.position - candidate).Magnitude)
			end
		end
		if nearest > best then
			best, chosen = nearest, candidate
		end
	end
	return chosen
end

--- The bot behind a spoken line, or nil for a squad-wide announcement. Chatter
--- names its speaker; this is what turns that name back into somebody standing
--- somewhere, which is what gives a callout a direction.
function Squad.named(bots: { any }, name: any): any
	if type(name) ~= "string" then
		return nil
	end
	for _, bot in ipairs(bots) do
		if bot.alive and bot.name == name then
			return bot
		end
	end
	return nil
end

return Squad
