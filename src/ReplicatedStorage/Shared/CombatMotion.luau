--!strict
-- Pure, normalized reload timeline. Duration comes from MarkerState, including
-- marker variants; animation never awards ammo or changes the shot direction.
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

function CombatMotion.reload(progress: number): any
	local frames = Config.get("combatAnimations").reload
	local t = math.clamp(progress, 0, 1)
	local a, b = frames[1], frames[#frames]
	for i = 2, #frames do
		if t <= frames[i].t then
			a, b = frames[i - 1], frames[i]
			break
		end
	end
	local u = (t - a.t) / (b.t - a.t)
	u = u * u * (3 - 2 * u)
	return {
		marker = CombatMotion.pose(a.position, a.rotation):Lerp(CombatMotion.pose(b.position, b.rotation), u),
		lid = a.lid + (b.lid - a.lid) * u,
		pod = CombatMotion.pose(a.pod, a.podRotation):Lerp(CombatMotion.pose(b.pod, b.podRotation), u),
		hand = Units.vectorToStuds(CombatMotion.vector(a.hand):Lerp(CombatMotion.vector(b.hand), u)),
		showPod = a.showPod,
	}
end

return CombatMotion
