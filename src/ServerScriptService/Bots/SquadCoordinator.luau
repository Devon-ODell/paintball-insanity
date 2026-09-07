--!strict
--[[
	SquadCoordinator -- the reason six bots beat one player.

	Individually a bot is beatable; that is the point of every parameter in
	AimModel being human-matchable. The squad is what makes a straight fight
	unwinnable, and it does it with three mechanisms:

	  * Contact sharing, with a per-tier DELAY. Rec bots take two seconds to tell
	    each other anything; pros take a fifth of a second. This is what makes
	    high tiers feel omniscient without any bot ever seeing through a wall.
	  * Focus fire inside a short window, so a player who is spotted by two bots
	    is being shot by two bots.
	  * Crossfire declaration: two living anchors whose bearings to the player
	    differ by more than the configured separation. Holding one angle against
	    a declared crossfire is what punishes camping, which is the whole lesson
	    of Speedball.

	Pure and tick-driven, so it runs identically in the sim harness.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)
local MapGeometry = require(ReplicatedStorage.Shared.MapGeometry)
local Rng = require(ReplicatedStorage.Shared.Rng)

local SquadCoordinator = {}
SquadCoordinator.__index = SquadCoordinator

export type Contact = {
	position: Vector3,
	velocity: Vector3,
	seenAt: number,
	reportedBy: string,
	--- When this sighting becomes usable by bots other than the reporter.
	sharedAt: number,
}

export type Coordinator = typeof(setmetatable(
	{} :: {
		tier: Types.BotTier,
		tierData: any,
		squadData: any,
		world: MapGeometry.World,
		rng: Rng.Generator,
		contact: Contact?,
		focusUntil: number,
		crossfireActive: boolean,
		crossfireSince: number?,
		_lastCrossfireCall: number,
	},
	SquadCoordinator
))

function SquadCoordinator.new(tier: Types.BotTier, world: MapGeometry.World, rng: Rng.Generator): Coordinator
	return setmetatable({
		tier = tier,
		tierData = Config.require("bots", "tiers." .. tier),
		squadData = Config.require("bots", "squad"),
		world = world,
		rng = rng,
		contact = nil,
		focusUntil = -math.huge,
		crossfireActive = false,
		crossfireSince = nil,
		_lastCrossfireCall = -math.huge,
	}, SquadCoordinator) :: any
end

--------------------------------------------------------------------------------
-- Role and anchor assignment
--------------------------------------------------------------------------------

export type Assignment = { role: Types.BotRole, anchorId: string }

--[[
	Hands out roles in the configured proportions and gives each bot an anchor
	that accepts its role. Deterministic given the generator, so a seed
	reproduces the same squad shape.
]]
function SquadCoordinator.assign(self: Coordinator, count: number): { Assignment }
	local roles = self.squadData.roles
	local order: { Types.BotRole } = { "anchor", "flanker", "pressure" }

	local queue: { Types.BotRole } = {}
	for _, role in ipairs(order) do
		for _ = 1, roles[role].count do
			table.insert(queue, role)
		end
	end
	-- Top up if the squad is larger than the declared role counts.
	while #queue < count do
		table.insert(queue, order[(#queue % #order) + 1])
	end

	local byRole: { [string]: { any } } = { anchor = {}, flanker = {}, pressure = {} }
	for _, anchor in ipairs(self.world.anchors) do
		for _, role in ipairs(anchor.roles) do
			if byRole[role] then
				table.insert(byRole[role], anchor)
			end
		end
	end

	local used: { [string]: boolean } = {}
	local out: { Assignment } = {}
	for i = 1, count do
		local role = queue[i]
		local candidates = byRole[role]
		local chosen: any = nil
		-- Prefer an unused anchor; fall back to sharing when the map runs out.
		for _ = 1, 12 do
			local pick = candidates[self.rng:nextInt(1, #candidates)]
			if not used[pick.id] then
				chosen = pick
				break
			end
			chosen = chosen or pick
		end
		used[chosen.id] = true
		out[i] = { role = role, anchorId = chosen.id }
	end
	return out
end

function SquadCoordinator.anchorById(self: Coordinator, id: string): any?
	for _, anchor in ipairs(self.world.anchors) do
		if anchor.id == id then
			return anchor
		end
	end
	return nil
end

--- Anchors this map offers for a role, used when a bot decides to reposition.
function SquadCoordinator.anchorsForRole(self: Coordinator, role: Types.BotRole): { any }
	local out = {}
	for _, anchor in ipairs(self.world.anchors) do
		if table.find(anchor.roles, role) then
			table.insert(out, anchor)
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Contact sharing
--------------------------------------------------------------------------------

--- A bot saw the player. The sighting becomes available to the rest of the
--- squad only after this tier's comms delay.
function SquadCoordinator.reportContact(
	self: Coordinator,
	botId: string,
	position: Vector3,
	velocity: Vector3,
	t: number
)
	local delayMs = self.squadData.contactShareDelayMs[self.tier]
	self.contact = {
		position = position,
		velocity = velocity,
		seenAt = t,
		reportedBy = botId,
		sharedAt = t + delayMs / 1000,
	}
	if self.rng:nextNumber() <= self.tierData.focusFireChance then
		self.focusUntil = t + self.squadData.focusFireWindowSeconds
	end
end

--[[
	The best contact this bot is allowed to act on.

	The reporter can act immediately -- it has its own eyes. Everyone else waits
	out the comms delay. Nothing here ever returns a position no bot has seen.
]]
function SquadCoordinator.contactFor(self: Coordinator, botId: string, t: number): Contact?
	local contact = self.contact
	if not contact then
		return nil
	end
	if contact.reportedBy ~= botId and t < contact.sharedAt then
		return nil
	end
	-- Sightings go stale; a bot that keeps shooting at a five-second-old
	-- position is a bot that looks broken rather than beaten.
	if t - contact.seenAt > 6 then
		return nil
	end
	return contact
end

function SquadCoordinator.isFocusFiring(self: Coordinator, t: number): boolean
	return t < self.focusUntil
end

--------------------------------------------------------------------------------
-- Crossfire
--------------------------------------------------------------------------------

--[[
	Declares a crossfire when two living bots hold angles on the player that are
	separated by more than the configured bearing.

	Returns true on the tick the crossfire is newly declared, so the caller can
	fire the callout line exactly once.
]]
function SquadCoordinator.updateCrossfire(
	self: Coordinator,
	bots: { any },
	playerPosition: Vector3,
	t: number
): boolean
	local bearings: { number } = {}
	for _, bot in ipairs(bots) do
		if bot.alive and bot.hasLineOfSight then
			table.insert(bearings, MapGeometry.bearingDeg(playerPosition, bot.position))
		end
	end

	local separation = self.squadData.crossfireMinSeparationDeg
	local active = false
	for i = 1, #bearings do
		for j = i + 1, #bearings do
			local diff = math.abs(((bearings[i] - bearings[j] + 180) % 360) - 180)
			if diff >= separation then
				active = true
				break
			end
		end
		if active then
			break
		end
	end

	local newlyDeclared = active and not self.crossfireActive
	self.crossfireActive = active
	if newlyDeclared then
		self.crossfireSince = t
	elseif not active then
		self.crossfireSince = nil
	end
	return newlyDeclared
end

--------------------------------------------------------------------------------
-- Morale
--------------------------------------------------------------------------------

function SquadCoordinator.moraleErrorMultiplier(aliveCount: number): number
	local Chatter = require(script.Parent.Chatter)
	local state = Chatter.moraleFor(aliveCount)
	return Config.require("bots", "morale.aimErrorPenaltyByState." .. state)
end

return SquadCoordinator
