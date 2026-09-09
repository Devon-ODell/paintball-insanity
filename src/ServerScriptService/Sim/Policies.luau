--!strict
--[[
	Policies -- scripted players for the sim harness.

	A policy is a pure function of the world state that returns an intent. They
	are not meant to play well; they are meant to be REPRODUCIBLE and to isolate
	one variable each, so that a tuning change shows up as a measurable
	difference rather than as a feeling.

	`neverLeads` is the important one. It is the policy BUILD_PLAN Phase 3 names:
	a player who aims dead at the body must produce high lead error and normal
	angular error. If a change ever makes those two move together, the telemetry
	has stopped being able to tell "you missed" from "you didn't lead", and the
	game has lost its reason to exist.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local AimModel = require(script.Parent.Parent.Bots.AimModel)

local Policies = {}

export type Intent = {
	--- Desired horizontal movement direction, or nil to hold position.
	move: Vector3?,
	sprint: boolean,
	crouch: boolean,
	--- Unit aim direction. nil means hold current aim.
	aim: Vector3?,
	fire: boolean,
}

export type Context = {
	t: number,
	position: Vector3,
	velocity: Vector3,
	muzzle: Vector3,
	aimHeight: number,
	spec: Ballistics.Spec,
	--- Bots this policy can actually see. A policy never gets a bot it cannot see.
	visible: { any },
	rng: any,
	world: any,
}

export type Policy = {
	name: string,
	decide: (Context) -> Intent,
}

local IDLE: Intent = { move = nil, sprint = false, crouch = false, aim = nil, fire = false }

--- Nearest visible bot, or nil.
local function nearest(ctx: Context): any?
	local best, bestD = nil, math.huge
	for _, bot in ipairs(ctx.visible) do
		local d = (bot.position - ctx.position).Magnitude
		if d < bestD then
			bestD, best = d, bot
		end
	end
	return best
end

local function aimPointOf(ctx: Context, bot: any): Vector3
	return bot.position + Vector3.new(0, ctx.aimHeight, 0)
end

--------------------------------------------------------------------------------

--- Stands still and does nothing. The floor: any change that makes this policy
--- win is a change that broke the bots.
function Policies.passive(): Policy
	return {
		name = "passive",
		decide = function()
			return IDLE
		end,
	}
end

--[[
	Perfect ballistics, no reaction time, no error. The ceiling.

	Not a realistic player -- it is the control. If `perfect` cannot clear a map,
	the map is unwinnable and the tuning is wrong regardless of what the other
	policies say.
]]
function Policies.perfect(): Policy
	return {
		name = "perfect",
		decide = function(ctx: Context): Intent
			local bot = nearest(ctx)
			if not bot then
				return IDLE
			end
			local aimPoint = Ballistics.solveLead(ctx.spec, ctx.muzzle, aimPointOf(ctx, bot), bot.velocity)
			if not aimPoint then
				return IDLE
			end
			return {
				move = nil,
				sprint = false,
				crouch = true,
				aim = ((aimPoint :: Vector3) - ctx.muzzle).Unit,
				fire = true,
			}
		end,
	}
end

--[[
	Aims exactly at the body: no lead, no holdover. The diagnostic policy.

	Its angular error against the BODY is near zero and its lead error is a full
	lead. That asymmetry is what the telemetry has to be able to see.
]]
function Policies.neverLeads(): Policy
	return {
		name = "neverLeads",
		decide = function(ctx: Context): Intent
			local bot = nearest(ctx)
			if not bot then
				return IDLE
			end
			return {
				move = nil,
				sprint = false,
				crouch = true,
				aim = (aimPointOf(ctx, bot) - ctx.muzzle).Unit,
				fire = true,
			}
		end,
	}
end

--[[
	Leads correctly but with a fixed angular jitter, and a reaction delay.

	This is the policy the tier curve is measured against, because it is the
	closest thing to a competent human: right idea, imperfect execution.
]]
--[[
	Advance to contact: what a benchmark does when it cannot see anybody.

	Shared by every policy, and it has to be, because `probe-trading` compares
	`human` against `rusher` and reads the gap as the map punishing a trade. The
	two policies only diverge once a bot is VISIBLE -- so if they reach contact
	differently, the probe is measuring the walk instead of the fight.

	It used to push to the world origin and idle within six metres. When the
	movement freeze was fixed and the benchmarks could finally cross a field,
	that meant the holding policy walked into the middle of the map and stood in
	the open, which is not holding an angle, it is standing in a field. Trading
	looked safer than holding on four of five fields as a direct result.

	Sweeping the enemy spawns in order is the fix. The target is a spawn rather
	than a centroid because on Holdfast the centroid sits inside the fort's own
	cover -- measured, it sees 0 of 12 spawns from there against Speedball's
	6 of 6. A benchmark standing in for a competent player is allowed to know
	where the enemy starts; it is never given a bot it cannot see.
]]
local function advanceToContact(ctx: Context, state: { index: number, started: number }): Intent
	local spawns = ctx.world and ctx.world.botSpawns
	local target = Vector3.new(0, 0, 0)
	if spawns and #spawns > 0 then
		if state.started >= 1 then
			local reached = Vector3.new(spawns[state.index].position[1], 0, spawns[state.index].position[3])
			if (reached - ctx.position).Magnitude < 8 then
				state.index = (state.index % #spawns) + 1
			end
		end
		state.started = 1
		target = Vector3.new(spawns[state.index].position[1], 0, spawns[state.index].position[3])
	end
	local delta = target - ctx.position
	if delta.Magnitude < 1 then
		return IDLE
	end
	return { move = Vector3.new(delta.X, 0, delta.Z), sprint = true, crouch = false, aim = nil, fire = false }
end

function Policies.competent(sigmaDeg: number?, reactionSeconds: number?): Policy
	local sigma = sigmaDeg or 1.6
	local reaction = reactionSeconds or 0.25
	local acquired: { [string]: number } = {}
	-- Which enemy spawn the sweep is walking to, and whether it has started.
	local sweep = { index = 1, started = 0 }

	return {
		name = `competent(sigma={sigma})`,
		decide = function(ctx: Context): Intent
			local bot = nearest(ctx)
			if not bot then
				return advanceToContact(ctx, sweep)
			end

			-- Reaction time, per target, so target switching costs time.
			local first = acquired[bot.id]
			if not first then
				acquired[bot.id] = ctx.t
				first = ctx.t
			end
			local ready = ctx.t - (first :: number) >= reaction

			local aimPoint = Ballistics.solveLead(ctx.spec, ctx.muzzle, aimPointOf(ctx, bot), bot.velocity)
			if not aimPoint then
				return IDLE
			end
			local direction = ((aimPoint :: Vector3) - ctx.muzzle).Unit
			direction = AimModel.rotate(
				direction,
				ctx.rng:nextGaussian() * sigma,
				ctx.rng:nextGaussian() * sigma
			)
			return { move = nil, sprint = false, crouch = true, aim = direction, fire = ready }
		end,
	}
end

--[[
	KNOWN LIMITATION, measured 2026-09-07.

	Both benchmark policies return `move = nil` the moment they acquire a target
	-- they plant and fire from wherever first contact happened. So the
	"engagement distance" the sim reports is the distance at which the player
	first SEES a bot, which is a property of sightlines and spawn separation, not
	of the fight the map is trying to produce.

	That is why every map misses the `targetMedianMetres` in its own
	engagementBand, and why Speedball -- the close map, target 16m -- produces
	the second-longest fights in the game at 29m. Two rounds of geometry and one
	of bot posture were spent on that number before this was understood; none of
	them moved it, and all three were reverted. See docs/PROGRESS.md.

	The fix is to keep closing while engaging, up to the band, in BOTH policies --
	they duplicate their decide loops, so changing one does nothing, which is its
	own trap. It is deliberately not done here: it moves every difficulty
	measurement in the suite at once and wants its own session with the
	before/after in hand.
]]

--[[
	Pushes into the open and trades. The policy that should LOSE.

	BUILD_PLAN: "Straight fights are unwinnable. Six markers beat one." If
	`rusher` ever starts clearing maps, the squad coordination has stopped
	working and the difficulty has quietly collapsed.
]]
function Policies.rusher(): Policy
	-- Built on `human`, not on `competent`, so the ONLY difference between the
	-- two benchmarks is behaviour. If rushing looked better than holding angles
	-- because the rusher also aimed better, the comparison would prove nothing.
	local base = Policies.human()
	return {
		name = "rusher",
		decide = function(ctx: Context): Intent
			local intent = base.decide(ctx)
			local bot = nearest(ctx)
			if bot then
				local delta = bot.position - ctx.position
				intent.move = Vector3.new(delta.X, 0, delta.Z)
				intent.sprint = delta.Magnitude > 14
				intent.crouch = false
			end
			return intent
		end,
	}
end

--[[
	A calibrated human.

	`competent` solves lead exactly, which no person does. This policy applies
	only `leadAccuracy` of the correct solution -- the same knob the bots use --
	plus a realistic reaction time and angular error. It is the benchmark the
	difficulty targets in BUILD_PLAN Phase 8 are stated against: a competent
	player should clear Speedball rec in a handful of attempts and pro in twenty.

	It also pushes in rather than turtling at spawn, because a player who never
	moves produces engagement distances that describe the spawn, not the map.
]]
function Policies.human(leadAccuracy: number?, sigmaDeg: number?, reactionSeconds: number?): Policy
	local accuracy = leadAccuracy or 0.7
	local sigma = sigmaDeg or 2.4
	local reaction = reactionSeconds or 0.34
	local acquired: { [string]: number } = {}
	local sweep = { index = 1, started = 0 }

	return {
		name = `human(lead={accuracy})`,
		decide = function(ctx: Context): Intent
			local bot = nearest(ctx)
			if not bot then
				return advanceToContact(ctx, sweep)
			end

			local first = acquired[bot.id]
			if not first then
				acquired[bot.id] = ctx.t
				first = ctx.t
			end
			if ctx.t - (first :: number) < reaction then
				return { move = nil, sprint = false, crouch = true, aim = nil, fire = false }
			end

			local aimPoint = aimPointOf(ctx, bot)
			local perfect = Ballistics.solveLead(ctx.spec, ctx.muzzle, aimPoint, bot.velocity)
			if not perfect then
				return IDLE
			end
			-- Same blend the bots use: how much of the correct answer a person
			-- actually applies. At 0.7 they lead, but not quite enough.
			local intended = aimPoint:Lerp(perfect :: Vector3, accuracy)
			local direction = (intended - ctx.muzzle).Unit
			direction = AimModel.rotate(direction, ctx.rng:nextGaussian() * sigma, ctx.rng:nextGaussian() * sigma)
			return { move = nil, sprint = false, crouch = true, aim = direction, fire = true }
		end,
	}
end

function Policies.byName(name: string): Policy
	if name == "passive" then
		return Policies.passive()
	elseif name == "perfect" then
		return Policies.perfect()
	elseif name == "neverLeads" then
		return Policies.neverLeads()
	elseif name == "rusher" then
		return Policies.rusher()
	elseif name == "competent" then
		return Policies.competent()
	elseif name == "human" then
		return Policies.human()
	end
	error(`unknown policy '{name}'`, 2)
end

return Policies
