--!strict
--[[
	What the server believes, as opposed to what the client says.

	The server already owned the thing that matters most: a hit is decided by its
	own swept simulation against its own view of the field, and there is no
	client-reported-hit remote anywhere in this project. These cover the two
	things it did NOT own -- position, which Capture the Flag scores on, and
	stance, which decided both the cone and where the muzzle was.

	None of this is proof against a compromised client on a platform where the
	character controller is client-authoritative. It is a bound, and a bound that
	is tested is worth more than an assumption that is not.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local Config = require(ReplicatedStorage.Shared.Config)
local Loadout = require(ReplicatedStorage.Shared.Loadout)
local PlayerState = require(Server.Match.PlayerState)

return function()
	local kit, state
	beforeEach(function()
		kit = Loadout.resolve({ loadout = { marker = "mechanical" } })
		state = PlayerState.new(kit)
	end)

	describe("where the server thinks you are", function()
		it("cannot renew replication slack every frame", function()
			PlayerState.observe(state, Vector3.zero, 0)
			for frame = 1, 60 do
				local at = PlayerState.believedPosition(state)
				PlayerState.observe(state, at + Vector3.new(3, 0, 0), frame / 60)
			end
			expect(PlayerState.believedPosition(state).Magnitude < 40).to.equal(true)
			expect(state.rejections > 0).to.equal(true)
		end)

		it("refuses nonfinite character positions", function()
			PlayerState.observe(state, Vector3.zero, 0)
			local at, ok = PlayerState.observe(state, Vector3.new(0/0, 0, 0), 1)
			expect(ok).to.equal(false)
			expect(at).to.equal(Vector3.zero)
		end)

		it("believes the first position it is given", function()
			local at = Vector3.new(3, 0, 4)
			local believed, accepted = PlayerState.observe(state, at, 0)
			expect(accepted).to.equal(true)
			expect(believed).to.equal(at)
		end)

		it("believes an ordinary sprint", function()
			PlayerState.observe(state, Vector3.zero, 0)
			--- A tenth of a second at sprint speed.
			local step = kit.sprintSpeedMps * 0.1
			local _, accepted = PlayerState.observe(state, Vector3.new(0, 0, step), 0.1)
			expect(accepted).to.equal(true)
		end)

		--[[
			The one that matters. CTF captures are proximity to a flag and to a
			home base, so a position that cannot be reached is a score that was
			not earned.
		]]
		it("refuses a teleport, and keeps you where you could have been", function()
			PlayerState.observe(state, Vector3.zero, 0)
			local believed, accepted = PlayerState.observe(state, Vector3.new(0, 0, 400), 0.1)
			expect(accepted).to.equal(false)
			expect(believed).to.equal(Vector3.zero)
			expect(state.rejections).to.equal(1)
		end)

		--- A refused sample must not become the new baseline, or a cheat could
		--- walk across the map one refused step at a time.
		it("does not let refused steps accumulate into a walk", function()
			PlayerState.observe(state, Vector3.zero, 0)
			for i = 1, 20 do
				PlayerState.observe(state, Vector3.new(0, 0, 400 * i), i * 0.1)
			end
			expect(PlayerState.believedPosition(state)).to.equal(Vector3.zero)
			expect(state.rejections).to.equal(20)
		end)

		--[[
			A respawn moves the player instantly and on purpose, and the server
			does it itself -- so it is ANNOUNCED rather than inferred. Without
			this every respawn would look like a teleport.
		]]
		it("accepts a declared respawn anywhere", function()
			PlayerState.observe(state, Vector3.zero, 0)
			local believed, accepted = PlayerState.observe(state, Vector3.new(0, 0, 400), 0.1, true)
			expect(accepted).to.equal(true)
			expect(believed).to.equal(Vector3.new(0, 0, 400))
			expect(state.rejections).to.equal(0)
		end)

		--[[
			The server moving the player is not a teleport, and it has to SAY so.

			`observe(..., respawned)` cannot carry this on its own: the flag that
			describes a respawn is cleared synchronously the moment the character
			is placed, before any heartbeat runs, so the jump from the death site
			to the spawn arrived looking exactly like a teleport and was refused.
			The believed position -- and therefore the squad's aim and line of
			sight -- then stayed pinned where the player had just died.
		]]
		it("accepts wherever the server itself just put the player", function()
			PlayerState.observe(state, Vector3.zero, 0)
			PlayerState.teleported(state)
			local believed, accepted = PlayerState.observe(state, Vector3.new(0, 0, 400), 0.1)
			expect(accepted).to.equal(true)
			expect(believed).to.equal(Vector3.new(0, 0, 400))
			expect(state.rejections).to.equal(0)
			--- And it does not disable the bound afterwards.
			local _, second = PlayerState.observe(state, Vector3.new(0, 0, 900), 0.2)
			expect(second).to.equal(false)
		end)

		--- Replication arrives late and in bursts, so a legitimate player's
		--- apparent speed over one short sample is routinely above their real
		--- one. The tolerance is for that, and catching a teleport across the
		--- map is worth far more than fighting jitter.
		it("tolerates a burst of replication rather than fighting it", function()
			PlayerState.observe(state, Vector3.zero, 0)
			local burst = kit.sprintSpeedMps * 0.2
			local _, accepted = PlayerState.observe(state, Vector3.new(0, 0, burst), 0.02)
			expect(accepted).to.equal(true)
		end)
	end)

	describe("what the server thinks you are doing", function()
		--[[
			Crouch reached `Spread` as a boolean ON THE FIRE REQUEST, so a client
			standing still could claim a crouch and collect the tighter cone
			without ever crouching.
		]]
		it("does not grant a crouch nobody declared", function()
			expect(PlayerState.stanceFor(state, Vector3.zero, nil)).to.equal("standing")
		end)

		it("grants a declared crouch to somebody slow enough to be crouching", function()
			PlayerState.setIntent(state, true, 0)
			expect(PlayerState.stanceFor(state, Vector3.zero, nil)).to.equal("crouching")
		end)

		--- You cannot crouch-walk at sprint speed, and the cone must not think
		--- you can.
		it("refuses a crouch to somebody moving too fast for one", function()
			PlayerState.setIntent(state, true, 0)
			local fast = Vector3.new(0, 0, kit.walkSpeedMps + 2)
			expect(PlayerState.stanceFor(state, fast, nil)).to.equal("sprinting")
			local walking = Vector3.new(0, 0, kit.crouchSpeedMps + 1)
			expect(PlayerState.stanceFor(state, walking, nil)).never.to.equal("crouching")
		end)

		it("clamps a forged lean to one body width either way", function()
			PlayerState.setIntent(state, false, 99)
			expect(state.lean).to.equal(1)
			PlayerState.setIntent(state, false, -99)
			expect(state.lean).to.equal(-1)
			PlayerState.setIntent(state, false, 0 / 0)
			expect(state.lean).to.equal(0)
			PlayerState.setIntent(state, false, "left")
			expect(state.lean).to.equal(0)
		end)
	end)

	describe("where the shot comes from", function()
		local ground = Vector3.new(0, 0, 0)
		local aim = Vector3.new(0, 0, 1)

		it("fires from chest height when standing", function()
			local chest = Config.require("ballistics", "hitbox.chestHeightMetres")
			local muzzle = PlayerState.muzzle(state, ground, aim, "standing")
			expect(math.abs(muzzle.Y - chest) < 1e-6).to.equal(true)
			expect(math.abs(muzzle.X) < 1e-6).to.equal(true)
		end)

		--[[
			Crouching lowers the camera and the muzzle stayed at standing chest
			height, so a crouched player shooting over low cover saw the shot
			clear the lip and the authoritative ball hit it.
		]]
		it("fires lower when crouched, as the camera does", function()
			local standing = PlayerState.muzzle(state, ground, aim, "standing")
			local crouched = PlayerState.muzzle(state, ground, aim, "crouching")
			expect(crouched.Y < standing.Y).to.equal(true)
		end)

		--[[
			Leaning moved the camera sideways around a corner and the muzzle
			stayed in the middle of the body, so the player saw a clear angle on
			somebody who was, authoritatively, still behind a wall.
		]]
		--[[
			And to the correct SIDE.

			An earlier version of this had the sign inverted, which is worse than
			not leaning at all: the camera went one way and the authoritative
			muzzle went the other, so a right lean fired from 1.1 m to the LEFT
			of where the player was looking from. A test that only checked
			magnitudes and opposite signs could not see it, so this one names the
			direction.

			`forward x up` is Roblox's RightVector -- the identity CFrame looks
			down -Z with +X right -- so a player facing +Z has their right at -X,
			and `CameraOffset.X = +offset` for a right lean puts the camera
			there.
		]]
		it("fires from where the lean put the camera, on the correct side", function()
			local offset = Config.require("match", "player.leanOffsetMetres")
			local expectedRight = aim.Unit:Cross(Vector3.new(0, 1, 0))

			PlayerState.setIntent(state, false, 1)
			local right = PlayerState.muzzle(state, ground, aim, "standing")
			PlayerState.setIntent(state, false, -1)
			local left = PlayerState.muzzle(state, ground, aim, "standing")
			PlayerState.setIntent(state, false, 0)
			local centred = PlayerState.muzzle(state, ground, aim, "standing")

			expect(((right - centred) - expectedRight * offset).Magnitude < 1e-6).to.equal(true)
			expect(((left - centred) + expectedRight * offset).Magnitude < 1e-6).to.equal(true)
			--- And the lean does not change the height.
			expect(math.abs(right.Y - left.Y) < 1e-6).to.equal(true)
			expect(math.abs(right.Y - centred.Y) < 1e-6).to.equal(true)
		end)

		--[[
			Crouching used to be a camera effect wearing the clothes of a cover
			mechanic: it lowered what the player could see over and changed
			nothing about the target. The entity handed to `ProjectileSim` was
			always the full standing capsule, and the squad looked at and shot at
			standing chest height regardless.
		]]
		it("makes a crouched player a shorter target, not just a lower camera", function()
			local standingHeight, standingAim = PlayerState.capsule("standing")
			local crouchHeight, crouchAim = PlayerState.capsule("crouching")
			expect(crouchHeight < standingHeight).to.equal(true)
			expect(crouchAim < standingAim).to.equal(true)
			--- The same ratio the camera drops by, so what the player feels and
			--- what the squad sees are one decision.
			local player = Config.require("match", "player")
			local drop = player.crouchEyeHeightMetres / player.eyeHeightMetres
			expect(math.abs(crouchHeight / standingHeight - drop) < 1e-9).to.equal(true)
		end)

		it("leaves a moving or standing player their full height", function()
			local full = Config.require("ballistics", "hitbox.bodyHeightMetres")
			for _, stance in ipairs({ "standing", "moving", "sprinting" }) do
				expect((PlayerState.capsule(stance :: any))).to.equal(full)
			end
		end)

		it("leans along the player's own right, whichever way they face", function()
			PlayerState.setIntent(state, false, 1)
			local facingZ = PlayerState.muzzle(state, ground, Vector3.new(0, 0, 1), "standing")
			local facingX = PlayerState.muzzle(state, ground, Vector3.new(1, 0, 0), "standing")
			--- Facing +Z the offset is on X; facing +X it is on Z. A lean that
			--- always moved along world X would be a lean that only works on one
			--- half of the map.
			expect(math.abs(facingZ.X) > 1e-6).to.equal(true)
			expect(math.abs(facingX.Z) > 1e-6).to.equal(true)
		end)
	end)
end
