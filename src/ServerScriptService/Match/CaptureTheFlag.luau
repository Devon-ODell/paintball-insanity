--!strict
--[[
	CaptureTheFlag -- solo CTF on Holdfast.

	One runner against a squad that has to both defend and attack. It works
	because the squad must SPLIT: reading which half is thinner, and punishing
	that half, is the entire mode.

	Pure state machine. It owns flag positions, carriers, captures and the
	squad's defend/attack division; it never touches an Instance. The caller
	feeds it positions each tick and acts on the events it returns.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local CaptureTheFlag = {}
CaptureTheFlag.__index = CaptureTheFlag

export type FlagState = "home" | "carried" | "dropped"

export type Flag = {
	owner: "player" | "bots",
	home: Vector3,
	position: Vector3,
	state: FlagState,
	carrier: string?,
	droppedAt: number?,
}

export type Event = {
	kind: string,
	actor: string?,
	flag: string?,
	position: Vector3?,
	score: { player: number, bots: number }?,
}

export type Game = typeof(setmetatable(
	{} :: {
		cfg: any,
		flags: { [string]: Flag },
		score: { player: number, bots: number },
		elapsed: number,
		finished: boolean,
		winner: string?,
		captures: number,
		returns: number,
		_lastAssign: number,
		_lastSquadSize: number,
		_split: { defenders: number, attackers: number },
	},
	CaptureTheFlag
))

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

--------------------------------------------------------------------------------

function CaptureTheFlag.new(mapData: any): Game
	local cfg = Config.require("gamemodes", "captureTheFlag")
	local ctf = mapData.captureTheFlag
	if not ctf then
		error(`CaptureTheFlag: {mapData.id} declares no captureTheFlag block`, 2)
	end

	local enemyHome = vec(ctf.enemyFlag.position)
	local playerHome = vec(ctf.playerFlag.position)

	return setmetatable({
		cfg = cfg,
		flags = {
			-- The "enemy" flag is the one the PLAYER is trying to take.
			enemy = {
				owner = "bots",
				home = enemyHome,
				position = enemyHome,
				state = "home" :: FlagState,
				carrier = nil,
				droppedAt = nil,
			},
			player = {
				owner = "player",
				home = playerHome,
				position = playerHome,
				state = "home" :: FlagState,
				carrier = nil,
				droppedAt = nil,
			},
		},
		score = { player = 0, bots = 0 },
		elapsed = 0,
		finished = false,
		winner = nil,
		captures = 0,
		returns = 0,
		_lastAssign = -math.huge,
		_lastSquadSize = -1,
		_split = { defenders = cfg.squadSplit.defendersBase, attackers = cfg.squadSplit.attackersBase },
	}, CaptureTheFlag) :: any
end

--------------------------------------------------------------------------------

--- Which flag a given actor is trying to steal.
local function targetFlagFor(actor: string): string
	return if actor == "player" then "enemy" else "player"
end

--- ...and which one they defend.
local function ownFlagFor(actor: string): string
	return if actor == "player" then "player" else "enemy"
end

--[[
	Can this actor capture right now?

	Standard CTF: your own flag has to be home. Alone, that rule is what forces
	you to care about defence at all -- otherwise the optimal play is to ignore
	their runner entirely and race.
]]
function CaptureTheFlag.canCapture(self: Game, actor: string): boolean
	if not self.cfg.mustHaveOwnFlagHome then
		return true
	end
	return self.flags[ownFlagFor(actor)].state == "home"
end

--------------------------------------------------------------------------------

--[[
	One tick.

	`actors` is a list of { id, team, position, alive }. The player is team
	"player"; every bot is team "bots". Returns the events that happened, in
	order, so the caller can play sounds and fire remotes for each.
]]
function CaptureTheFlag.step(self: Game, dt: number, actors: { any }): { Event }
	local events: { Event } = {}
	if self.finished then
		return events
	end

	self.elapsed += dt
	local flagCfg = self.cfg.flag

	-- Carried flags ride along with whoever has them.
	for name, flag in pairs(self.flags) do
		if flag.state ~= "carried" then
			continue
		end
		local carrier = nil
		for _, actor in ipairs(actors) do
			if actor.id == flag.carrier then
				carrier = actor
			end
		end
		--[[
			A carrier who is gone -- eliminated, or left -- drops it where they
			stood. A dropped flag is not a reset: it is a flag lying in the open
			that both sides now want, which is the most interesting state in the
			mode.
		]]
		if not carrier or not carrier.alive then
			if carrier then flag.position = carrier.position end
			flag.state = "dropped"
			flag.carrier = nil
			flag.droppedAt = self.elapsed
			table.insert(events, { kind = "flagDropped", flag = name, position = flag.position })
		else
			flag.position = carrier.position
		end
	end

	-- A dropped flag goes home if nobody wants it.
	for name, flag in pairs(self.flags) do
		if flag.state == "dropped" and flag.droppedAt then
			if self.elapsed - (flag.droppedAt :: number) >= flagCfg.returnAfterSecondsIdle then
				flag.state = "home"
				flag.position = flag.home
				flag.droppedAt = nil
				table.insert(events, { kind = "flagReturned", flag = name, position = flag.home })
			end
		end
	end

	for _, actor in ipairs(actors) do
		if not actor.alive then
			continue
		end

		local target = self.flags[targetFlagFor(actor.team)]
		local own = self.flags[ownFlagFor(actor.team)]

		-- Pick up the enemy flag.
		if target.state ~= "carried" and (actor.position - target.position).Magnitude <= flagCfg.pickupRadiusMetres then
			target.state = "carried"
			target.carrier = actor.id
			target.position = actor.position
			target.droppedAt = nil
			table.insert(events, { kind = "flagTaken", actor = actor.id, flag = targetFlagFor(actor.team) })
		end

		--[[
			Touching your OWN flag while it is lying out returns it instantly.
			That is the defensive play the mode needs to be winnable solo: you
			cannot be in two places, but you can undo a failed enemy run in one
			touch on your way past.
		]]
		if own.state == "dropped" and (actor.position - own.position).Magnitude <= flagCfg.pickupRadiusMetres then
			own.state = "home"
			own.position = own.home
			own.droppedAt = nil
			if actor.team == "player" then
				self.returns += 1
			end
			table.insert(events, { kind = "flagRecovered", actor = actor.id, flag = ownFlagFor(actor.team) })
		end

		-- Capture.
		if target.state == "carried" and target.carrier == actor.id then
			local atHome = (actor.position - own.home).Magnitude <= flagCfg.captureRadiusMetres
			if atHome and CaptureTheFlag.canCapture(self, actor.team) then
				target.state = "home"
				target.position = target.home
				target.carrier = nil

				if actor.team == "player" then
					self.score.player += 1
					self.captures += 1
				else
					self.score.bots += 1
				end
				table.insert(events, {
					kind = "captured",
					actor = actor.id,
					flag = targetFlagFor(actor.team),
					score = { player = self.score.player, bots = self.score.bots },
				})
			end
		end
	end

	-- Win conditions.
	local target = self.cfg.capturesToWin
	if self.score.player >= target then
		self.finished = true
		self.winner = "player"
		table.insert(events, { kind = "matchWon", actor = "player" })
	elseif self.score.bots >= target then
		self.finished = true
		self.winner = "bots"
		table.insert(events, { kind = "matchLost", actor = "bots" })
	elseif self.elapsed >= self.cfg.timeLimitSeconds then
		self.finished = true
		self.winner = if self.score.player > self.score.bots then "player"
			elseif self.score.bots > self.score.player then "bots"
			else "draw"
		table.insert(events, { kind = "timeUp", actor = self.winner })
	end

	return events
end

--------------------------------------------------------------------------------

--[[
	How the squad divides itself, right now.

	Behind, they push; ahead, they turtle. Reading that shift -- and hitting
	whichever half just got thinner -- is the read the whole mode is built to
	teach, so it is deliberately legible rather than random.
]]
function CaptureTheFlag.squadSplit(self: Game, squadSize: number): { defenders: number, attackers: number }
	local cfg = self.cfg.squadSplit
	if squadSize == self._lastSquadSize and self.elapsed - self._lastAssign < cfg.reassignEverySeconds then
		return self._split
	end
	self._lastAssign = self.elapsed
	self._lastSquadSize = squadSize

	local shape
	if self.score.bots < self.score.player then
		shape = cfg.whenLosing
	elseif self.score.bots > self.score.player then
		shape = cfg.whenWinning
	else
		shape = { defenders = cfg.defendersBase, attackers = cfg.attackersBase }
	end

	-- Scale the declared shape to whatever squad size the round actually has,
	-- and never leave the keep completely unattended.
	local total = shape.defenders + shape.attackers
	local defenders = math.min(squadSize, math.max(1, math.floor(squadSize * (shape.defenders / total) + 0.5)))
	self._split = { defenders = defenders, attackers = math.max(0, squadSize - defenders) }
	return self._split
end

--- The role a specific bot should be playing, by index.
function CaptureTheFlag.roleFor(self: Game, index: number, squadSize: number): string
	local split = CaptureTheFlag.squadSplit(self, squadSize)
	--[[
		A bot carrying the player's flag stops being either -- it runs for home
		and its escort collapses onto it. The caller checks carrierRole first.
	]]
	return if index <= split.defenders then "defend" else "attack"
end

--- Is this bot the one carrying the player's flag?
function CaptureTheFlag.isCarrier(self: Game, id: string): boolean
	return self.flags.player.carrier == id
end

--- Where a bot in this role should be heading.
function CaptureTheFlag.objectiveFor(self: Game, role: string, id: string): Vector3
	if CaptureTheFlag.isCarrier(self, id) then
		return self.flags.enemy.home
	end
	if role == "defend" then
		--[[
			A defender guards whichever thing is actually at risk: the flag if
			it has been moved, its home plinth otherwise. Sitting on an empty
			plinth while the flag is halfway across the map is how defence AI
			looks stupid.
		]]
		local enemy = self.flags.enemy
		return if enemy.state == "home" then enemy.home else enemy.position
	end
	local playerFlag = self.flags.player
	return if playerFlag.state == "home" then playerFlag.home else playerFlag.position
end

--------------------------------------------------------------------------------

--- Carrying costs speed and makes noise, so you cannot outrun the squad with
--- it -- you have to have made the room before you picked it up.
function CaptureTheFlag.carrierModifiers(self: Game, id: string): { sprint: number, loudness: number }
	local flagCfg = self.cfg.flag
	for _, flag in pairs(self.flags) do
		if flag.carrier == id then
			return { sprint = flagCfg.carrierSprintMultiplier, loudness = flagCfg.carrierLoudnessMultiplier }
		end
	end
	return { sprint = 1, loudness = 1 }
end

function CaptureTheFlag.payout(self: Game): number
	local p = self.cfg.payout
	local total = self.captures * p.perCapture + self.returns * p.perFlagReturn
	if self.winner == "player" then
		total += p.winBonus
	end
	return math.floor(total + 0.5)
end

function CaptureTheFlag.summary(self: Game): any
	return {
		mode = "captureTheFlag",
		score = self.score,
		captures = self.captures,
		returns = self.returns,
		winner = self.winner,
		durationSeconds = self.elapsed,
		payout = CaptureTheFlag.payout(self),
	}
end

return CaptureTheFlag
