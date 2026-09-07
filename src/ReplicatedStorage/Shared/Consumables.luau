--!strict
--[[
	Consumables -- single-use field kit, and the rule that keeps it honest.

	Pure. Catalogue lookups, tier gating, carry-slot validation and the audit.

	THE RULE, restated because this file is where it would break first: nothing
	here touches the player's own accuracy, spread, velocity or recoil, and
	nothing hands them information they could not have got from something audible
	in the world. Every offensive item requires a LANDED SHOT first -- the effect
	is downstream of a hit, never on whether the hit lands.

	`ALLOWED_FIELDS` is the complete set of knobs an item may declare, and
	`audit()` fails on anything else. A `damage`, a `spreadMultiplier` or a
	`revealsAllEnemies` appearing in consumables.json fails the build.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local Consumables = {}

Consumables.ALLOWED_FIELDS = {
	"throwSpeedMps", "fuseSeconds", "burstRadiusMetres", "cloudRadiusMetres",
	"durationSeconds", "blocksSightBothWays", "roundsPerPickup", "splatterScale",
	"lensFogRadiusMetres", "lensFogSeconds", "visionRangeMultiplierWhileFogged",
	"moraleShockRadiusMetres", "moraleShockSeconds", "moraleStepsDown",
	"extraPods", "clearsBarrelBreak", "radiusMetres", "botsHoldFire",
	"revealsWhoFiredWithinSeconds", "revealRefreshSeconds", "loudness",
}

export type Tier = "common" | "red" | "gold"

export type Item = {
	id: string,
	displayName: string,
	tier: Tier,
	cost: number?,
	kind: string,
	blurb: string,
}

--- Every item id, in a stable order so the shop does not reshuffle itself.
function Consumables.order(): { string }
	local items = Config.require("consumables", "items")
	local ids: { string } = {}
	for id in pairs(items) do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		local ia, ib = items[a], items[b]
		-- Cheapest purchasable first, then the unbuyable tiers.
		local ca = ia.cost or math.huge
		local cb = ib.cost or math.huge
		if ca ~= cb then
			return ca < cb
		end
		return a < b
	end)
	return ids
end

function Consumables.item(id: string): any?
	return Config.require("consumables", "items")[id]
end

--- Can this be bought with earned currency at all? Red and gold kit cannot be,
--- at any price -- it drops. Nobody buys their way past getting good.
function Consumables.isPurchasable(id: string): boolean
	local item = Consumables.item(id)
	if not item then
		return false
	end
	local tier = Config.require("consumables", "tiers." .. item.tier)
	return tier.purchasable == true and type(item.cost) == "number"
end

function Consumables.maxSlots(): number
	return Config.require("consumables", "carry.maxSlots")
end

--[[
	Validates a carry loadout: a list of item ids the player wants to take in.

	Returns ok plus a reason. Refuses over-capacity, unknown items, and items the
	player does not have stock of. Duplicates ARE allowed -- taking two paint
	grenades is a legitimate choice.
]]
function Consumables.validateCarry(carry: { string }, stock: { [string]: number }): (boolean, string?)
	if #carry > Consumables.maxSlots() then
		return false, `only {Consumables.maxSlots()} slots`
	end

	local needed: { [string]: number } = {}
	for _, id in ipairs(carry) do
		if not Consumables.item(id) then
			return false, `unknown item '{id}'`
		end
		needed[id] = (needed[id] or 0) + 1
	end
	for id, count in pairs(needed) do
		if (stock[id] or 0) < count then
			return false, `not enough {id}`
		end
	end
	return true, nil
end

--- Deducts a carry loadout from stock. Returns the new stock table; the input
--- is not mutated, so a failed round can simply discard the result.
function Consumables.consume(stock: { [string]: number }, carry: { string }): { [string]: number }
	local out = table.clone(stock)
	for _, id in ipairs(carry) do
		out[id] = math.max(0, (out[id] or 0) - 1)
	end
	return out
end

--[[
	The full catalogue as the shop should show it, with ownership counts.

	Unpurchasable tiers are still listed -- seeing that Emberfill exists and that
	it drops from marshals is the point of listing it.
]]
function Consumables.catalogue(stock: { [string]: number }): { any }
	local out: { any } = {}
	for _, id in ipairs(Consumables.order()) do
		local item = Consumables.item(id) :: any
		local tier = Config.require("consumables", "tiers." .. item.tier)
		table.insert(out, {
			id = id,
			displayName = item.displayName,
			cost = item.cost,
			tier = item.tier,
			tierName = tier.displayName,
			tierColour = tier.colour,
			purchasable = Consumables.isPurchasable(id),
			source = tier.source,
			blurb = item.blurb,
			held = stock[id] or 0,
		})
	end
	return out
end

--[[
	Audits the catalogue by field name.

	This is the check that would catch someone adding a damage term or a
	full-map reveal to the drone. Returns the list of violations.
]]
function Consumables.audit(): { string }
	local allowed: { [string]: boolean } = {}
	for _, field in ipairs(Consumables.ALLOWED_FIELDS) do
		allowed[field] = true
	end
	local descriptive: { [string]: boolean } = {
		displayName = true, tier = true, cost = true, kind = true, blurb = true,
	}

	local violations: { string } = {}
	for _, id in ipairs(Consumables.order()) do
		local item = Consumables.item(id) :: any
		for field in pairs(item) do
			if not allowed[field] and not descriptive[field] and field:sub(1, 1) ~= "_" then
				table.insert(violations, `{id} declares '{field}'`)
			end
		end
	end
	return violations
end

return Consumables
