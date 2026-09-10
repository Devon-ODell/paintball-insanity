--!strict
-- CTF's live adapter. Combat stays in MatchService; flags, respawn tickets,
-- objectives, presentation and the objective payout are owned here.
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS.Shared.Config)
local MapGeometry = require(RS.Shared.MapGeometry)
local Dev = require(RS.Shared.Dev)
local Campaign = require(script.Parent.Parent.Progression.Campaign)
local Rules = require(script.Parent.CaptureTheFlag)
local Navigation = require(script.Parent.FlagNavigation)
local Visuals = require(script.Parent.FlagVisuals)
local Payout = require(script.Parent.Parent.Economy.Payout)
local FlagMatch = {}
FlagMatch.__index = FlagMatch

function FlagMatch.canStart(mapName: string, profile: any): boolean
	local cfg = Config.get("gamemodes").modes.captureTheFlag
	return cfg.integrated == true and table.find(cfg.maps, mapName) ~= nil
		and Config.map(mapName).captureTheFlag ~= nil
		and (Dev.flag("unlockEverything") or Campaign.unlocks(Campaign.recordFromProfile(profile)).captureTheFlag == true)
end

function FlagMatch.new(data: any, world: any, parent: Instance): any
	local rules = Rules.new(data)
	return setmetatable({ rules = rules, nav = Navigation.build(world), visuals = Visuals.new(parent, rules),
		respawns = {}, nextSend = 0, lastPosition = rules.flags.player.home,
		schedule = { { index = 1, tier = "rec", botCount = rules.cfg.squadSize, payoutMultiplier = 1, isFinal = true, captureTheFlag = true } },
	}, FlagMatch)
end

function FlagMatch.snapshot(self: any): any
	local r = self.rules
	return { score = { player = r.score.player, bots = r.score.bots }, target = r.cfg.capturesToWin,
		seconds = math.max(0, r.cfg.timeLimitSeconds - r.elapsed),
		playerFlag = r.flags.player.state, enemyFlag = r.flags.enemy.state,
		carrying = r.flags.enemy.carrier == "player", sprintMultiplier = r:carrierModifiers("player").sprint,
		winner = r.winner }
end

function FlagMatch.step(self: any, dt: number, position: Vector3?, playerAlive: boolean, bots: { any }, replaceBot: (number) -> (), send: (any) -> ())
	if position then self.lastPosition = position end
	local actors = { { id = "player", team = "player", position = self.lastPosition, alive = playerAlive } }
	for _, bot in ipairs(bots) do table.insert(actors, { id = bot.id, team = "bots", position = bot.position, alive = bot.alive }) end
	local events = self.rules:step(dt, actors)
	for i, bot in ipairs(bots) do
		if not bot.alive then
			self.respawns[i] = self.respawns[i] or (self.rules.elapsed + self.rules.cfg.respawn.botSeconds)
			if not self.rules.finished and self.rules.elapsed >= self.respawns[i] then
				replaceBot(i); self.respawns[i] = nil
			end
		end
	end
	if #events > 0 or self.rules.elapsed >= self.nextSend then
		self.visuals:update()
		local snapshot = self:snapshot()
		snapshot.events = events
		send(snapshot)
		self.nextSend = self.rules.elapsed + self.rules.cfg.networkIntervalSeconds
	end
end

function FlagMatch.navigator(self: any, bot: any, index: number, bots: { any }, t: number): (any, number) -> ()
	local r, cfg = self.rules, self.rules.cfg
	local role = r:roleFor(index, #bots)
	local destination = r:objectiveFor(role, bot.id)
	local carrier = r:isCarrier(bot.id)
	if role == "defend" and r.flags.enemy.state == "home" and not carrier then
		local offsets = cfg.arena.guardOffsetsMetres
		local offset = offsets[(index - 1) % #offsets + 1]
		destination = r.flags.enemy.home + Vector3.new(offset[1], 0, offset[2])
	elseif not carrier and r.flags.player.state == "carried" then
		-- Keep the first defenders at home; the attacking detail escorts its runner.
		local split = r:squadSplit(#bots)
		if index > split.defenders and index <= split.defenders + cfg.botCarrier.escortCount then
			destination = r.flags.player.position + Vector3.new(if index % 2 == 0 then cfg.navigation.escortOffsetMetres else -cfg.navigation.escortOffsetMetres, 0, 0)
		end
	end
	destination = MapGeometry.groundPoint(self.nav, destination)
	local speed = Config.require("bots", "movement.sprintSpeedMps")
	if carrier then speed *= cfg.botCarrier.sprintMultiplier end
	return function(actor: any, dt: number)
		local cycle = cfg.navigation.combatHoldSeconds + cfg.navigation.combatMoveSeconds
		if not carrier and actor.hasLineOfSight and t % cycle < cfg.navigation.combatHoldSeconds then
			actor.velocity = Vector3.zero; return
		end
		Navigation.step(self.nav, actor, destination, dt, t, speed)
		if role == "defend" and r.flags.enemy.state == "home" and actor.velocity.Magnitude == 0 and not actor.hasLineOfSight then
			local delta = r.flags.player.home - actor.position
			actor.facing = Vector3.new(delta.X, 0, delta.Z).Unit
		end
	end
end

function FlagMatch.breakdown(self: any, deaths: number, shots: number, hits: number): any
	local r = self.rules
	local death = if r.cfg.payout.usesDeathPenalty then Payout.deathPenalty(deaths) else 1
	local accuracy = if r.cfg.payout.usesAccuracyBonus then Payout.accuracyBonus(shots, hits) else 1
	return { total = math.floor(r:payout() * death * accuracy + 0.5), base = r:payout(),
		deathPenalty = death, accuracyBonus = accuracy, cleared = r.winner == "player",
		roundsCleared = 0, roundsPlayed = 0, ctf = r:summary() }
end

function FlagMatch.destroy(self: any) self.visuals:destroy(); table.clear(self.respawns) end
return FlagMatch
