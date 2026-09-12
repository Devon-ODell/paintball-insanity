--!strict
local Config = require(script.Parent.Config)
local CombatPose = {}

function CombatPose.muzzle(ground: Vector3, aim: Vector3, crouching: boolean, lean: number): Vector3
	local player = Config.require("match", "player")
	local hitbox = Config.require("ballistics", "hitbox")
	local height = if crouching
		then hitbox.chestHeightMetres * (player.crouchEyeHeightMetres / player.eyeHeightMetres)
		else hitbox.chestHeightMetres
	local muzzle = ground + Vector3.new(0, height, 0)
	if lean ~= 0 then
		local flat = Vector3.new(aim.X, 0, aim.Z)
		if flat.Magnitude > 1e-6 then
			local right = flat.Unit:Cross(Vector3.new(0, 1, 0))
			--[[
				`forward x up` is Roblox's own RightVector: the identity CFrame
				looks down -Z with +X to the right, and (0,0,-1) x (0,1,0) is
				(1,0,0). The client sets `Humanoid.CameraOffset.X` to
				`+leanOffset` for `lean = 1`, and CameraOffset is in the
				character's local space where +X is its right -- so a positive
				lean moves the camera to the player's right and the muzzle has
				to follow it there.
			]]
			muzzle += right * (lean * player.leanOffsetMetres)
		end
	end
	return muzzle
end

return CombatPose
