--!strict
--[[
	CombatMotion -- every first-person animation, as pure arithmetic.

	Timelines live in Data/combatAnimations.json and are sampled here. Nothing in
	this module touches an Instance, reads the clock or knows what a marker is,
	which is what lets the headless client check the poses at all. Duration comes
	from MarkerState, including marker variants; animation never awards ammo,
	changes a shot direction, or decides a hit.
]]
local Config = require(script.Parent.Config)
local Units = require(script.Parent.Units)
local CombatMotion = {}

function CombatMotion.vector(values: { number }): Vector3
	return Vector3.new(values[1], values[2], values[3])
end

function CombatMotion.pose(position: { number }, rotation: { number }): CFrame
	return CFrame.new(CombatMotion.vector(position))
		* CFrame.Angles(math.rad(rotation[1]), math.rad(rotation[2]), math.rad(rotation[3]))
end

--[[
	The two keyframes either side of `progress`, and how far between them.

	Shared by every timeline so the reload and the swing cannot drift apart in
	how they interpolate. Smoothstep on the blend rather than a straight lerp:
	linear segments make a hand arrive at a keyframe and change direction on the
	same frame, which is the animation equivalent of a corner.
]]
local function sample(frames: { any }, progress: number): (any, any, number)
	local t = math.clamp(progress, 0, 1)
	local a, b = frames[1], frames[#frames]
	for i = 2, #frames do
		if t <= frames[i].t then
			a, b = frames[i - 1], frames[i]
			break
		end
	end
	local u = (t - a.t) / (b.t - a.t)
	return a, b, u * u * (3 - 2 * u)
end

function CombatMotion.reload(progress: number): any
	local a, b, u = sample(Config.get("combatAnimations").reload, progress)
	return {
		marker = CombatMotion.pose(a.position, a.rotation):Lerp(CombatMotion.pose(b.position, b.rotation), u),
		lid = a.lid + (b.lid - a.lid) * u,
		pod = CombatMotion.pose(a.pod, a.podRotation):Lerp(CombatMotion.pose(b.pod, b.podRotation), u),
		hand = Units.vectorToStuds(CombatMotion.vector(a.hand):Lerp(CombatMotion.vector(b.hand), u)),
		showPod = a.showPod,
	}
end

--[[
	The shove, in first person.

	The server decides the hit from Melee and the geometry it can see; this is
	only what the hands do. The contact keyframe deliberately sits at the same
	fraction of the swing as match.json's hitRules.melee.contactFraction, so the
	frame where the butt arrives on screen is the frame the server resolves.
]]
function CombatMotion.swing(progress: number): any
	local a, b, u = sample(Config.get("combatAnimations").melee, progress)
	return {
		marker = CombatMotion.pose(a.position, a.rotation):Lerp(CombatMotion.pose(b.position, b.rotation), u),
		hand = Units.vectorToStuds(CombatMotion.vector(a.hand):Lerp(CombatMotion.vector(b.hand), u)),
	}
end

--[[
	Recoil as an impulse rather than a fade.

	Returns 1 on the frame of the shot and decays to 0 over `seconds`, crossing
	slightly past rest once on the way -- a damped spring, which is what a
	blowback marker does in the hands. The previous curve was a straight line
	from 1 to 0, which reads as the marker being dragged backwards.

	Signed on purpose: the small negative lobe is the settle, and a caller that
	clamps it away gets the old behaviour back.
]]
function CombatMotion.recoil(elapsed: number, seconds: number): number
	if elapsed < 0 or elapsed >= seconds or seconds <= 0 then
		return 0
	end
	local cfg = Config.get("combatAnimations").recoil
	local u = elapsed / seconds
	return math.exp(-cfg.decay * u) * (1 - u) * math.cos(u * cfg.settleTurns * math.pi * 2)
end

return CombatMotion
