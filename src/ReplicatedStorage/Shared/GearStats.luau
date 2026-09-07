--!strict
--[[
	GearStats -- what a loadout actually does.

	Pure. Resolves the player's equipped jersey, pads and pods into a single set
	of multipliers, and it is deliberately the ONLY place that resolution
	happens, so there is exactly one function to audit against the monetization
	rule.

	The rule, restated because it is the thing this module exists to protect:
	nothing purchasable may improve accuracy, reduce recoil, increase velocity or
	otherwise substitute for aim. So the fields below are the complete allowed
	set, `ALLOWED_FIELDS` is asserted against Data/gear.json by the specs and by
	tools/ship-check, and there is no spread, damage or velocity term anywhere in
	the resolved result. There is no armour stat. One hit is out.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local GearStats = {}

--- The complete set of axes gear is permitted to touch.
GearStats.ALLOWED_FIELDS = {
	"loudnessMultiplier",
	"sprintMultiplier",
	"crouchMultiplier",
	"slideDurationMultiplier",
	"slideCooldownMultiplier",
	"reloadMultiplier",
	"podCount",
}

export type Resolved = {
	--- Scales the radius at which bots hear the player fire and move.
	loudnessMultiplier: number,
	sprintMultiplier: number,
	crouchMultiplier: number,
	slideDurationMultiplier: number,
	slideCooldownMultiplier: number,
	reloadMultiplier: number,
	--- How many hopper refills are carried into a round.
	podCount: number,
}

local NEUTRAL: Resolved = {
	loudnessMultiplier = 1,
	sprintMultiplier = 1,
	crouchMultiplier = 1,
	slideDurationMultiplier = 1,
	slideCooldownMultiplier = 1,
	reloadMultiplier = 1,
	podCount = 2,
}

function GearStats.neutral(): Resolved
	return table.clone(NEUTRAL)
end

--- Looks up one gear item, or nil. Category is "jerseys", "pads" or "pods".
function GearStats.item(category: string, id: string): any?
	local gear = Config.get("gear")
	if category == "jerseys" then
		return gear.protective.jerseys.items[id]
	elseif category == "pads" then
		return gear.protective.pads.items[id]
	elseif category == "helmets" then
		return gear.protective.helmets.items[id]
	elseif category == "shoulders" then
		return gear.protective.shoulders.items[id]
	elseif category == "pods" then
		return gear.paintAndAir.pods.items[id]
	end
	return nil
end

--- The ids a category offers, in display order.
function GearStats.order(category: string): { string }
	local gear = Config.get("gear")
	if category == "jerseys" then
		return gear.protective.jerseys.order
	elseif category == "pads" then
		return gear.protective.pads.order
	elseif category == "helmets" then
		return gear.protective.helmets.order
	elseif category == "shoulders" then
		return gear.protective.shoulders.order
	elseif category == "pods" then
		return gear.paintAndAir.pods.order
	end
	return {}
end

--- Every gear category, for the shop and the audit.
GearStats.CATEGORIES = { "jerseys", "pads", "helmets", "shoulders", "pods" }

--[[
	Resolves a loadout into one set of multipliers.

	Multiplicative across slots, so a quiet jersey and quiet pads compound --
	which is the intended build, and it costs mobility on both slots to get it.
	`podCount` is taken rather than multiplied, since it is a count and only the
	pod harness sets it.
]]
function GearStats.resolve(loadout: any): Resolved
	local result = GearStats.neutral()
	if type(loadout) ~= "table" then
		return result
	end

	local slots = {
		{ category = "jerseys", id = loadout.jersey },
		{ category = "pads", id = loadout.pads },
		{ category = "helmets", id = loadout.helmet },
		{ category = "shoulders", id = loadout.shoulders },
		{ category = "pods", id = loadout.pods },
	}

	for _, slot in ipairs(slots) do
		if type(slot.id) ~= "string" then
			continue
		end
		local entry = GearStats.item(slot.category, slot.id)
		if not entry then
			continue
		end
		result.loudnessMultiplier *= entry.loudnessMultiplier or 1
		result.sprintMultiplier *= entry.sprintMultiplier or 1
		result.crouchMultiplier *= entry.crouchMultiplier or 1
		result.slideDurationMultiplier *= entry.slideDurationMultiplier or 1
		result.slideCooldownMultiplier *= entry.slideCooldownMultiplier or 1
		result.reloadMultiplier *= entry.reloadMultiplier or 1
		if entry.podCount then
			result.podCount = entry.podCount
		end
	end

	return result
end

--[[
	Audits the whole catalogue.

	Returns the list of violations: any item declaring a numeric field outside
	ALLOWED_FIELDS. A `spreadMultiplier` or a `damageReduction` appearing in
	gear.json is caught here rather than in playtesting, which is the only place
	it would otherwise show up -- as a game that had quietly stopped being an aim
	trainer.
]]
function GearStats.audit(): { string }
	local allowed: { [string]: boolean } = {}
	for _, field in ipairs(GearStats.ALLOWED_FIELDS) do
		allowed[field] = true
	end
	-- Descriptive fields carry no mechanical weight and are always fine.
	local descriptive: { [string]: boolean } = {
		displayName = true,
		cost = true,
		colorKey = true,
		blurb = true,
		cosmetic = true,
		-- Which campaign chapter unlocks the item. Progression, not a stat.
		unlockChapter = true,
		purchasable = true,
	}

	local violations: { string } = {}
	for _, category in ipairs(GearStats.CATEGORIES) do
		for _, id in ipairs(GearStats.order(category)) do
			local entry = GearStats.item(category, id)
			if not entry then
				continue
			end
			for field in pairs(entry) do
				if not allowed[field] and not descriptive[field] and field:sub(1, 1) ~= "_" then
					table.insert(violations, `{category}/{id} declares '{field}'`)
				end
			end
		end
	end
	return violations
end

return GearStats
