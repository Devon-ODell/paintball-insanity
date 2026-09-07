--!strict
--[[
	Boss -- field marshals, built without a health bar.

	There is no health anywhere in this game and adding one here would break the
	single rule everything else rests on. So a marshal is padded head to foot,
	paint on the body does not count, and only the HOPPER counts -- about
	eighteen centimetres across, sitting just above and behind the shoulder.

	A boss is therefore still one hit. It is a very small hit, at range, on
	someone better than you, who has an escort and who only exposes the hopper
	when they lean out. That makes the fight a precision test, which is exactly
	what this game trains. A three-thousand-health bullet sponge in an aim
	trainer would have taught nobody anything.

	Pure with respect to Roblox: it describes the target volume and answers hit
	tests. ProjectileSim does the intersecting.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)

local Boss = {}

export type Definition = {
	id: string,
	displayName: string,
	subtitle: string,
	tier: Types.BotTier,
	marker: string,
	escortCount: number,
	escortTier: Types.BotTier,
	hopperRadiusMetres: number,
	moveStyle: string,
	repositionEverySeconds: number,
	peekDiscipline: number,
	dropTier: string,
	count: number,
	intro: string,
	defeat: string,
}

function Boss.definition(id: string): Definition?
	local raw = Config.require("bosses", "bosses")[id]
	if not raw then
		return nil
	end
	local common = Config.require("bosses", "common")
	return {
		id = id,
		displayName = raw.displayName,
		subtitle = raw.subtitle,
		tier = raw.tier,
		marker = raw.marker,
		escortCount = raw.escortCount,
		escortTier = raw.escortTier,
		hopperRadiusMetres = raw.hopperRadiusMetres or common.hopperRadiusMetres,
		moveStyle = raw.moveStyle,
		repositionEverySeconds = raw.repositionEverySeconds,
		peekDiscipline = raw.peekDiscipline,
		dropTier = raw.dropTier,
		count = raw.count or 1,
		intro = raw.intro,
		defeat = raw.defeat,
	}
end

function Boss.ids(): { string }
	local out: { string } = {}
	for id in pairs(Config.require("bosses", "bosses")) do
		table.insert(out, id)
	end
	table.sort(out)
	return out
end

--------------------------------------------------------------------------------

export type Target = {
	id: string,
	team: string,
	position: Vector3,
	velocity: Vector3,
	radius: number,
	height: number,
	alive: boolean,
}

--[[
	The hit volume for a marshal.

	Returned as a very short capsule at hopper height rather than a full body,
	so ProjectileSim's existing capsule test does the right thing with no special
	casing. The body is simply not a target: paint on it does nothing, which is
	the whole design.
]]
function Boss.hitTarget(definition: Definition, id: string, position: Vector3, velocity: Vector3, alive: boolean): Target
	local common = Config.require("bosses", "common")
	return {
		id = id,
		team = "bots",
		position = position + Vector3.new(0, common.hopperHeightMetres, 0),
		velocity = velocity,
		radius = definition.hopperRadiusMetres,
		--[[
			A very short capsule, not a point: a hopper is a physical object with
			some height to it, and a zero-height target would be unhittable at
			the ranges Woods is played at.
		]]
		height = definition.hopperRadiusMetres * 1.4,
		alive = alive,
	}
end

--[[
	Is the hopper actually exposed right now?

	A marshal squared up behind cover has the hopper tucked; leaning out to
	shoot swings it into the open. Learning that timing IS the fight, so the
	window is tied to whether they are currently firing or peeking rather than
	being always-on.
]]
function Boss.hopperExposed(state: { peeking: boolean, firing: boolean, repositioning: boolean }): boolean
	return state.peeking or state.firing or state.repositioning
end

--- The angular size of the hopper at a distance, in degrees. Exposed because it
--- is the number that says how hard the fight actually is.
function Boss.angularSizeDeg(definition: Definition, distanceMetres: number): number
	if distanceMetres <= 0 then
		return 180
	end
	return math.deg(2 * math.atan(definition.hopperRadiusMetres / distanceMetres))
end

--[[
	Bot parameters for a marshal: their tier, with peek discipline overridden.

	Marshals are not given superhuman aim -- they are given a tier that already
	exists and much better discipline about when to show themselves. That keeps
	BUILD_PLAN's rule intact: every parameter is still something a human could
	match.
]]
function Boss.parametersFor(definition: Definition): any
	local tierData = table.clone(Config.require("bots", "tiers." .. definition.tier))
	tierData.peekDiscipline = definition.peekDiscipline
	tierData.repositionChance = 1 / math.max(1, definition.repositionEverySeconds)
	tierData.marker = definition.marker
	return tierData
end

--- The boss for the gauntlet's boss chapter.
function Boss.forChapter(chapterId: string): string?
	return Config.require("bosses", "schedule.gauntlet")[chapterId]
end

return Boss
