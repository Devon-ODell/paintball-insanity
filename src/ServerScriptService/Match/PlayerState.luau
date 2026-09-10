--!strict
--[[
	PlayerState -- what the server believes about where the player is and what
	they are doing, as opposed to what their client says.

	The server owns projectile outcomes: a hit is decided by its own swept
	simulation against its own view of the field, and there is no
	client-reported-hit remote anywhere in this project. That is the hard part
	and it was already right. What was not owned:

	  - POSITION. The server took the character's replicated root position and
	    velocity as fact. That is fine for a hit test -- a player who teleports
	    still has to aim -- and it is not fine for CAPTURE THE FLAG, where
	    scoring is proximity to a flag and to a home base. Forging a hit and
	    forging a position are different problems, and only the first one was
	    solved.

	  - STANCE. Crouch reached `Spread` as a BOOLEAN ON THE FIRE REQUEST, so a
	    client could send `stance = "crouching"` while standing still and
	    collect the 0.72x cone without ever crouching. Lean was not transmitted
	    at all, so the server's muzzle stayed in the middle of the body while the
	    client's camera leaned half a metre around a corner: the player saw a
	    clear shot and the authoritative ball hit the wall.

	None of this can be made perfect against a compromised client on a platform
	where the character controller is client-authoritative. What it can be is
	BOUNDED: movement is checked against the speed the player's own kit allows,
	stance is a state the server holds and transitions rather than a field on a
	packet, and the muzzle is derived from that state.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Types = require(ReplicatedStorage.Shared.Types)

local log = Log.scope("LiveRound.PlayerState")

local PlayerState = {}
PlayerState.__index = PlayerState

export type State = typeof(setmetatable({} :: {
	--- The resolved kit, for the speeds this player is actually allowed.
	kit: any,
	--- Last position the server accepted, in metres.
	position: Vector3?,
	--- Server time of that acceptance.
	at: number,
	--- Server-held stance. Crouch is a STATE here, not a packet field.
	crouching: boolean,
	--- -1, 0 or 1. Which way the player is leaning, as the server understands it.
	lean: number,
	--- How many impossible displacements have been seen. Rejections are the
	--- interesting number; one is a hitch, a hundred is a problem.
	rejections: number,
	--- The last displacement the server refused to believe, in metres.
	worstMetres: number,
}, PlayerState))

function PlayerState.new(kit: any): State
	return setmetatable({
		kit = kit,
		position = nil :: Vector3?,
		at = 0,
		crouching = false,
		lean = 0,
		rejections = 0,
		worstMetres = 0,
	}, PlayerState)
end

--[[
	The fastest this player could legitimately have moved, in metres per second.

	Their own kit's top speed, plus the tolerance. The tolerance is not slack for
	cheating -- it is for the fact that a replicated position arrives late and in
	bursts, so a legitimate player's apparent speed over one short sample is
	routinely well above their actual speed. A generous bound that catches a
	teleport across the map is worth far more than a tight one that fights
	ordinary network jitter.
]]
local function speedLimit(self: State): number
	local rules = Config.require("match", "movementValidation")
	local top = math.max(
		self.kit.sprintSpeedMps,
		self.kit.slideSpeedMps,
		self.kit.walkSpeedMps
	)
	return top * rules.speedTolerance
end

--[[
	Offers the server a new observed position.

	Returns the position the server is willing to believe, and whether it
	believed the new one. A refused sample does not move the accepted position:
	the player keeps the last place they could actually have been, which is what
	stops a teleport from scoring.

	`respawned` is how a legitimate discontinuity is declared. A respawn, a
	round change and a course checkpoint all move the player instantly and on
	purpose, and the server does those itself, so they are announced rather than
	inferred.
]]
function PlayerState.observe(self: State, position: Vector3, t: number, respawned: boolean?): (Vector3, boolean)
	if respawned or self.position == nil then
		self.position = position
		self.at = t
		return position, true
	end
	local elapsed = math.max(t - self.at, 0)
	local rules = Config.require("match", "movementValidation")
	--- A floor on the window, so a sample arriving in the same frame as the last
	--- one does not divide a real displacement by nearly zero.
	local window = math.max(elapsed, rules.minimumWindowSeconds)
	local moved = (position - (self.position :: Vector3)).Magnitude
	local allowed = speedLimit(self) * window + rules.slackMetres

	if moved > allowed then
		self.rejections += 1
		if moved > self.worstMetres then
			self.worstMetres = moved
		end
		--[[
			Logged once every so often rather than per sample.

			A player falling through the world produces this every frame, and a
			log line per frame buries everything else -- the same failure the
			leaderboard's read warnings had.
		]]
		if self.rejections % rules.logEvery == 1 then
			log.warn(string.format(
				"refused a %.1f m step in %.3f s (limit %.1f m); %d refused so far",
				moved, window, allowed, self.rejections
			))
		end
		return self.position :: Vector3, false
	end

	self.position = position
	self.at = t
	return position, true
end

--- Where the server believes the player is. Nil before the first observation.
function PlayerState.believedPosition(self: State): Vector3?
	return self.position
end

--[[
	Declares that the server itself just moved the player.

	A respawn, a round change and a course checkpoint all move the player
	instantly and on purpose. Passing `respawned` to the next `observe` cannot
	express that reliably, because the flag that describes it is cleared
	synchronously the moment the character is placed -- before any heartbeat runs
	-- so the enormous jump from the death site to the spawn arrived looking
	exactly like a teleport and was refused. The believed position then stayed
	pinned at the death site for seconds, which is where the squad would have
	been shooting.

	Whoever does the moving says so, at the moment they do it.
]]
function PlayerState.teleported(self: State)
	self.position = nil
end

--[[
	The stance the server will grade this shot at.

	Movement wins over crouch, because you cannot crouch-walk at sprint speed --
	and it is derived from the OBSERVED velocity rather than from anything the
	client asserted. Crouch is then the server's own held state, so a request
	claiming to be crouched while the server never saw a crouch begin gets the
	standing cone it earned.
]]
function PlayerState.stanceFor(self: State, velocity: Vector3, player: any): Types.Stance
	local flat = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	if flat > self.kit.walkSpeedMps + 0.1 then
		return "sprinting"
	elseif flat > 0.3 then
		return "moving"
	elseif self.crouching then
		--[[
			And only if the player could actually be crouched.

			A crouch is a slow stance. Holding the key while moving at walking
			pace is not crouching, and the cone should not think it is.
		]]
		if flat <= self.kit.crouchSpeedMps + 0.1 then
			return "crouching"
		end
		return "standing"
	end
	return "standing"
end

--[[
	Records a stance intent from the client.

	Crouch and lean are PRESENTATION on the client -- they move the camera and
	the local walk speed -- and the server needs them to keep its muzzle and its
	cone in step with what the player can see. Nothing here is trusted as fact:
	`stanceFor` still checks the crouch against observed speed, and the lean is
	clamped to the offset the tuning file allows.
]]
function PlayerState.setIntent(self: State, crouching: any, lean: any)
	self.crouching = crouching == true
	if type(lean) == "number" and lean == lean then
		self.lean = math.clamp(math.floor(lean + 0.5), -1, 1)
	else
		self.lean = 0
	end
end

--[[
	Where the muzzle is, given the stance the server actually believes.

	Two things used to be missing here, and both of them were visible to the
	player and invisible to the server:

	  - CROUCHING lowers the camera to `crouchEyeHeightMetres` and the server
	    kept firing from standing chest height, so a crouched player shooting
	    over low cover saw the shot clear the lip and the authoritative ball hit
	    it.
	  - LEANING moves the camera `leanOffsetMetres` sideways around a corner and
	    the server kept the muzzle in the middle of the body, so the player saw a
	    clear angle on somebody who was, authoritatively, still behind a wall.

	`right` is the player's own right in world axes, from their aim.
]]
function PlayerState.muzzle(self: State, ground: Vector3, aim: Vector3, stance: Types.Stance): Vector3
	local player = Config.require("match", "player")
	local hitbox = Config.require("ballistics", "hitbox")
	local height = if stance == "crouching"
		then hitbox.chestHeightMetres * (player.crouchEyeHeightMetres / player.eyeHeightMetres)
		else hitbox.chestHeightMetres
	local muzzle = ground + Vector3.new(0, height, 0)
	if self.lean ~= 0 then
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
			muzzle += right * (self.lean * player.leanOffsetMetres)
		end
	end
	return muzzle
end

--[[
	How tall the player is to the squad, and where their centre of mass is.

	Crouching lowered the camera and the muzzle and changed nothing about the
	target: the player entity handed to `ProjectileSim` was always the full
	standing capsule, and `BotController` looked at and shot at standing chest
	height regardless. So crouching behind low cover changed what the PLAYER
	could see and nothing at all about what could see them -- which makes it a
	camera effect wearing the clothes of a cover mechanic.

	Scaled by the same ratio the camera drops by, so what the player feels and
	what the squad sees are the same decision.
]]
function PlayerState.capsule(stance: Types.Stance): (number, number)
	local hitbox = Config.require("ballistics", "hitbox")
	if stance ~= "crouching" then
		return hitbox.bodyHeightMetres, hitbox.chestHeightMetres
	end
	local player = Config.require("match", "player")
	local drop = player.crouchEyeHeightMetres / player.eyeHeightMetres
	return hitbox.bodyHeightMetres * drop, hitbox.chestHeightMetres * drop
end

return PlayerState
