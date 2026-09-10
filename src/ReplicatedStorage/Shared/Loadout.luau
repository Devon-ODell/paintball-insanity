--!strict
--[[
	Loadout -- the equipped kit, resolved once, into numbers the game uses.

	`GearStats.resolve` was written with the shop, audited by ship-check and the
	specs, and had NO PRODUCTION CALLER. Sprint, crouch, slide duration and
	cooldown, reload speed, loudness and pod count were authored per item, priced,
	displayed in the shop as tradeoffs, granted as chapter rewards -- and reached
	nothing. The barn advertised a quiet jersey that cost you mobility, and it
	cost nothing and bought nothing.

	This is the snapshot both halves consume. The server resolves it at the start
	of a match or a drill and keeps it for the whole run; the client is sent the
	same numbers so its prediction agrees with the authority rather than guessing.
	One resolution, one shape, one place to audit against the monetization rule:

	    nothing purchasable may improve accuracy, reduce recoil, increase
	    velocity, or otherwise substitute for aim.

	Notice what is NOT here. There is no spread term, no velocity term, no damage
	and no armour. Every axis below is a cost/benefit on how loud you are, how
	fast you move and how much paint you carry -- decisions the player makes
	against the same shooting they had to learn anyway.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local GearStats = require(ReplicatedStorage.Shared.GearStats)

local Loadout = {}

export type Resolved = {
	--- Scales the radius at which bots hear this player move and fire.
	loudnessMultiplier: number,
	--- Metres per second, already multiplied. The client moves at these and the
	--- server validates against them, so there is one set of numbers.
	walkSpeedMps: number,
	sprintSpeedMps: number,
	crouchSpeedMps: number,
	slideSpeedMps: number,
	slideDurationSeconds: number,
	slideCooldownSeconds: number,
	--- Seconds to refill the hopper.
	reloadSeconds: number,
	--- Balls the hopper holds, after the fed-hopper's capacity bonus.
	hopperCapacity: number,
	--- Balls per minute, capped by what the hopper can actually feed.
	roundsPerMinute: number,
	--- Hopper refills carried into a round. Reloads are not free any more.
	podCount: number?,
	--- What the marker itself is, so the client can tell whether a change to the
	--- loadout means rebuilding its predicted marker state.
	marker: string,
}

--[[
	Resolves a profile's loadout against the marker it is carrying.

	Movement is expressed as SPEEDS rather than as multipliers on purpose. A
	multiplier has to be applied by whoever consumes it, and "whoever consumes
	it" is how the carrier movement cost came to be a sprint multiplier that
	scaled every kind of locomotion including walking. A speed is a speed.
]]
--[[
	The attachment axes this game is willing to sell.

	Barrels, hoppers and tanks each declare more than this. `spreadMultiplier`,
	`velocityMultiplier` and `velocityConsistency` are DELIBERATELY NOT READ
	HERE, and must not be: a flatter, more consistent arc is less lead to work
	out, which is substituting for aim -- the one thing BUILD_PLAN's monetization
	rule forbids buying. They stay authored and inert rather than being deleted,
	because deleting them would lose the record of the decision; `tools/ship-check`
	asserts this function does not consume them.

	What IS sold: how loud you are, how fast you reload, how much you carry and
	how fast the hopper can feed. Every one of those is a cost somewhere else.
]]
local function attachment(group: string, id: any): any
	if type(id) ~= "string" then
		return nil
	end
	local groups = Config.require("markers", "attachments")
	return groups[group] and groups[group][id]
end

function Loadout.resolve(profileData: any, markerData: any?): Resolved
	local gear = GearStats.resolve(profileData and profileData.loadout)
	local player = Config.require("match", "player")
	local equipped = (profileData and profileData.loadout) or {}
	local markerName = equipped.marker or "mechanical"
	local marker = markerData or Config.require("markers", "markers." .. markerName)

	local barrel = attachment("barrels", equipped.barrel)
	local hopper = attachment("hoppers", equipped.hopper)
	local tank = attachment("tanks", equipped.tank)

	--- Multiplicative across every slot, so a quiet barrel and a quiet jersey
	--- compound -- and cost mobility or capacity on both.
	local loudness = gear.loudnessMultiplier
		* ((barrel and barrel.loudnessMultiplier) or 1)
		* ((hopper and hopper.loudnessMultiplier) or 1)
		* (marker.loudness or 1)

	--- The hopper cannot feed faster than it can feed. A force-fed hopper is
	--- what lets a high-rate marker actually run at its rate.
	local feedCap = (hopper and hopper.feedRateCap) or math.huge
	local roundsPerMinute = math.min(marker.roundsPerMinute, feedCap * 60)

	return {
		loudnessMultiplier = loudness,
		--[[
			Walking is not scaled by the sprint multiplier.

			`sprintMultiplier` is named for what it does, and gear that trades
			mobility for quiet is supposed to cost you the ability to CLOSE
			ground, not the ability to walk. Scaling everything would make a
			quiet build feel broken rather than deliberate.
		]]
		walkSpeedMps = player.walkSpeedMps,
		sprintSpeedMps = player.sprintSpeedMps * gear.sprintMultiplier,
		crouchSpeedMps = player.crouchSpeedMps * gear.crouchMultiplier,
		slideSpeedMps = player.slideSpeedMps,
		slideDurationSeconds = player.slideDurationSeconds * gear.slideDurationMultiplier,
		slideCooldownSeconds = player.slideCooldownSeconds * gear.slideCooldownMultiplier,
		reloadSeconds = marker.reloadSeconds * gear.reloadMultiplier
			* ((tank and tank.reloadMultiplier) or 1),
		hopperCapacity = math.floor(marker.hopperCapacity * ((hopper and hopper.capacityMultiplier) or 1) + 0.5),
		roundsPerMinute = roundsPerMinute,
		podCount = gear.podCount,
		marker = markerName,
	}
end

--- Neutral kit, for anything that has to act before a profile is available.
function Loadout.neutral(markerData: any?): Resolved
	return Loadout.resolve(nil, markerData)
end

--- Practice uses the equipped handling but never runs out of refills.
function Loadout.forRange(profileData: any): Resolved
	local resolved = Loadout.resolve(profileData)
	resolved.podCount = nil
	return resolved
end

return Loadout
