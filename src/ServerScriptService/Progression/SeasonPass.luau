--!strict
--[[
	SeasonPass -- the server side of the season track.

	Shared/Season is the arithmetic and knows nothing about players. This owns
	the profile: it keeps the record current, adds marks when a match ends, and
	grants what the track owes. Every grant is server-side off the profile's own
	marks; nothing here is ever driven by a client asking.

	Ownership of the paid track comes from Roblox, not from us. Commerce
	re-checks `UserOwnsGamePassAsync` on join and after a purchase and records
	the result on the profile, so a player who bought the pass and then lost a
	save still owns it -- Roblox is the authority on what was paid for.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Season = require(ReplicatedStorage.Shared.Season)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.scope("LiveRound.Season")

local SeasonPass = {}

--[[
	Where a reward lands in the inventory.

	Deliberately shorter than the full inventory. Markers, barrels, hoppers,
	tanks, pods, pads and shoulders all carry mechanical stats in gear.json or
	markers.json, and a track that could hand one out would be selling rate of
	fire or sprint speed. Colour only.
]]
local FIELDS: { [string]: string } = {
	paintColors = "ownedPaintColors",
	markerSkins = "ownedMarkerSkins",
	jerseys = "ownedJerseys",
	masks = "ownedMasks",
}

function SeasonPass.config(): any
	return Config.get("seasons")
end

--- Categories a season reward may use. Read by ship-check as well.
function SeasonPass.allowedCategories(): { [string]: string }
	return FIELDS
end

--[[
	The player's record for the CURRENT season, created or rolled over as
	needed. Rolling over resets marks and claims; it never touches inventory, so
	last season's jersey stays in the wardrobe.
]]
function SeasonPass.record(handle: any): Season.Record
	local cfg = SeasonPass.config()
	local existing = handle.data.season
	local record = Season.recordFor(existing, cfg.id)
	handle.data.season = record
	return record
end

--- Whether this player owns the current season's pass, as recorded by Commerce.
function SeasonPass.ownsPass(handle: any): boolean
	local cfg = SeasonPass.config()
	local passes = handle.data.commerce and handle.data.commerce.passes
	return passes ~= nil and passes[cfg.passOfferId] ~= nil
end

--- Adds the marks a finished match was worth. Returns the new total.
function SeasonPass.award(handle: any, summary: any): number
	if not handle:isActive() then
		return 0
	end
	local cfg = SeasonPass.config()
	local record = SeasonPass.record(handle)
	local gained = Season.marksFor(summary, cfg.scoring)
	record.marks += gained
	return record.marks
end

--[[
	Grants everything the track owes and returns what was handed over.

	Safe to call repeatedly and safe to call on join: `claimed` makes each
	reward grant once. Calling it after a purchase is what makes buying the pass
	mid-season honest -- every paid reward up to the tier already reached is
	handed over immediately rather than being lost for not having bought it
	sooner.
]]
function SeasonPass.grantDue(handle: any): { Season.Reward }
	if not handle:isActive() then
		return {}
	end
	local cfg = SeasonPass.config()
	local record = SeasonPass.record(handle)
	local owns = SeasonPass.ownsPass(handle)
	local due = Season.rewardsDue(record, cfg.tiers, owns)

	for _, reward in ipairs(due) do
		local field = FIELDS[reward.category]
		if not field then
			log.warn(`season reward '{reward.category}/{reward.id}' is not a grantable category; skipped`)
			continue
		end
		local owned = handle.data[field]
		if type(owned) ~= "table" then
			owned = {}
			handle.data[field] = owned
		end
		if not table.find(owned, reward.id) then
			table.insert(owned, reward.id)
		end
	end

	Season.markClaimed(record, cfg.tiers, owns)
	if #due > 0 then
		log.info(`granted {#due} season reward(s) to {handle.userId}`)
	end
	return due
end

--- What the HUD and the barn need to draw the track.
function SeasonPass.summary(handle: any): any
	local cfg = SeasonPass.config()
	local record = SeasonPass.record(handle)
	return {
		id = cfg.id,
		displayName = cfg.displayName,
		marks = record.marks,
		tier = Season.tierFor(record.marks, cfg.tiers),
		tierCount = #cfg.tiers,
		toNext = Season.toNextTier(record.marks, cfg.tiers),
		ownsPass = SeasonPass.ownsPass(handle),
		passOfferId = cfg.passOfferId,
	}
end

return SeasonPass
