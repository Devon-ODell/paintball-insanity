--!strict
--[[
	Melee -- the butt of the marker, and who it can reach.

	Paintball has no knife and this game is never going to have one. What it has
	is the thing everybody who has ever played actually does at contact range:
	turn the marker around and shove somebody with the tank. That is the whole
	mechanic. One shove, one elimination, same as a mark.

	This module is the geometry and nothing else -- no state, no timing, no
	instances -- so the server, the bots and the headless simulation all answer
	"could that swing have reached?" with the same arithmetic instead of three
	nearly-identical distance checks that drift apart. The cooldown and the
	swing clock belong to whoever is swinging.

	It replaces the barrel tag. That rule sat in match.json unimplemented since
	the rules were written, and when it was finally built it asked a bot to
	decline a shot at four metres, which reads less like paintball courtesy and
	more like the squad refusing to play. A shove is the same distance rule
	pointed the right way round: closing has to cost you something.
]]

local Config = require(script.Parent.Config)

local Melee = {}

export type Rules = {
	rangeMetres: number,
	reachHeightMetres: number,
	arcDegrees: number,
	cooldownSeconds: number,
	swingSeconds: number,
	contactFraction: number,
}

--- Anything with a position. Bots, players and simulated capsules all qualify.
export type Reachable = { position: Vector3, alive: boolean? }

function Melee.rules(): Rules
	return Config.require("match", "hitRules.melee") :: Rules
end

--- Seconds from the start of a swing to the moment the butt arrives.
function Melee.contactDelay(rules: Rules): number
	return rules.swingSeconds * rules.contactFraction
end

--[[
	Could a swing from `origin`, facing `facing`, reach `target`?

	Horizontal, deliberately. A shove does not care whether the target is
	crouched or standing on the low side of a berm -- only that they are inside
	arm's length and in front of you. Height is a sanity bound, so somebody on a
	catwalk overhead is not shoved through the floor.
]]
function Melee.reaches(origin: Vector3, facing: Vector3, target: Vector3, rules: Rules): boolean
	local delta = target - origin
	if math.abs(delta.Y) > rules.reachHeightMetres then
		return false
	end
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local distance = flat.Magnitude
	if distance > rules.rangeMetres then
		return false
	end
	--- Touching, or as near as makes no difference: there is no meaningful
	--- bearing to a target you are standing inside, so the arc cannot reject it.
	if distance < 1e-3 then
		return true
	end
	local aim = Vector3.new(facing.X, 0, facing.Z)
	if aim.Magnitude < 1e-3 then
		return false
	end
	local cosine = aim.Unit:Dot(flat.Unit)
	return cosine >= math.cos(math.rad(rules.arcDegrees / 2))
end

--[[
	The nearest reachable target, or nil.

	Nearest rather than most-centred: at this range the player is looking at
	whoever they walked into, and picking by bearing would let a bot standing
	directly behind another one steal the hit.
]]
function Melee.pick(origin: Vector3, facing: Vector3, candidates: { Reachable }, rules: Rules): Reachable?
	local best: Reachable? = nil
	local bestDistance = math.huge
	for _, candidate in ipairs(candidates) do
		if candidate.alive == false then
			continue
		end
		if Melee.reaches(origin, facing, candidate.position, rules) then
			local distance = (candidate.position - origin).Magnitude
			if distance < bestDistance then
				best, bestDistance = candidate, distance
			end
		end
	end
	return best
end

return Melee
