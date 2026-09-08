--!strict
--[[
	Shop -- server-authoritative purchasing.

	Two rules, both enforced here rather than trusted to the catalogue:

	  1. The client never names a price. It names an ITEM; the server looks up
	     what that costs. A client that sends its own price is ignored.
	  2. Nothing purchasable may improve accuracy. `assertNoPayToWin` walks the
	     whole catalogue and refuses to let the shop start if any attachment
	     tightens the cone or raises velocity. That is a design constraint, not a
	     business one: a pay-to-win aim trainer produces meaningless telemetry
	     and has no reason to exist.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local GearStats = require(ReplicatedStorage.Shared.GearStats)
local Consumables = require(ReplicatedStorage.Shared.Consumables)
local Profile = require(script.Parent.Profile)
local Pricing = require(ReplicatedStorage.Shared.CommerceCatalog)
local Commerce = require(script.Parent.Commerce)
local Camos = require(script.Parent.Parent.Progression.Camos)
local CamoCatalog = require(ReplicatedStorage.Shared.Camos)

local log = Log.scope("LiveRound.Economy")

local Shop = {}

export type Category =
	"markers" | "barrels" | "hoppers" | "tanks"
	| "jerseys" | "pads" | "helmets" | "shoulders" | "masks" | "markerSkins"
	| "pods" | "paintColors" | "consumables" | "camos"

local OWNERSHIP_FIELD: { [string]: string } = {
	markers = "ownedMarkers",
	barrels = "ownedBarrels",
	hoppers = "ownedHoppers",
	tanks = "ownedTanks",
	jerseys = "ownedJerseys",
	pads = "ownedPads",
	helmets = "ownedHelmets",
	shoulders = "ownedShoulders",
	pods = "ownedPods",
	masks = "ownedMasks",
	paintColors = "ownedPaintColors",
	markerSkins = "ownedMarkerSkins",
}

local LOADOUT_FIELD: { [string]: string } = {
	markers = "marker",
	barrels = "barrel",
	hoppers = "hopper",
	tanks = "tank",
	jerseys = "jersey",
	pads = "pads",
	helmets = "helmet",
	shoulders = "shoulders",
	pods = "pods",
	masks = "mask",
	paintColors = "paintColor",
	markerSkins = "markerSkin",
}

--------------------------------------------------------------------------------
-- Catalogue
--------------------------------------------------------------------------------

local function entryFor(category: Category, id: string): any?
	if category == "markers" then
		return Config.get("markers").markers[id]
	elseif category == "barrels" or category == "hoppers" or category == "tanks" then
		return Config.get("markers").attachments[category][id]
	elseif table.find(GearStats.CATEGORIES, category) then
		-- Protective and Paint & Air stock lives in gear.json, because those
		-- items carry mechanical stats and cosmetics do not.
		return GearStats.item(category, id)
	end
	local cosmetics = Config.require("economy", "shop.cosmetics")
	local group = cosmetics[category]
	return group and group[id]
end

Shop.entryFor = entryFor

function Shop.isCategory(value: any): boolean
	return type(value) == "string" and (OWNERSHIP_FIELD[value] ~= nil or value == "camos" or value == "consumables")
end

--[[
	Refuses to operate a catalogue that contains a pay-to-win item.

	Called at server start. Failing loudly at boot is the point: a shop that
	silently sells an accuracy upgrade is worse than a shop that will not start.
]]
function Shop.assertNoPayToWin()
	local attachments = Config.get("markers").attachments
	for _, group in ipairs({ "barrels", "hoppers", "tanks" }) do
		for id, entry in pairs(attachments[group]) do
			if (entry.spreadMultiplier or 1) ~= 1 then
				error(`Shop: '{id}' changes spread. Nothing purchasable may improve accuracy.`)
			end
			if (entry.velocityMultiplier or 1) > 1.05 then
				error(`Shop: '{id}' raises muzzle velocity beyond the cosmetic tolerance.`)
			end
		end
	end

	local robux = Config.require("economy", "shop.robux.products")
	for id, product in pairs(robux) do
		if product.affectsAccuracy ~= false then
			error(`Shop: Robux product '{id}' must declare affectsAccuracy = false.`)
		end
		if product.grants.markers or product.grants.barrels then
			error(`Shop: Robux product '{id}' grants gameplay items. Cosmetics and convenience only.`)
		end
	end
	--[[
		Protective and Paint & Air stock is audited by field name rather than by
		value: an item may only declare axes on GearStats.ALLOWED_FIELDS. That
		catches a `spreadMultiplier` or a `damageReduction` being added to
		gear.json, which is the realistic way this rule would get broken.
	]]
	local gearViolations = GearStats.audit()
	if #gearViolations > 0 then
		error(`Shop: gear.json declares disallowed stats -- {table.concat(gearViolations, "; ")}`)
	end

	--[[
		Consumables, audited the same way. This is where a damage term or a
		full-map reveal on the drone would be caught -- at boot, not in
		playtesting.
	]]
	local kitViolations = Consumables.audit()
	if #kitViolations > 0 then
		error(`Shop: consumables.json declares disallowed stats -- {table.concat(kitViolations, "; ")}`)
	end

	log.info("shop catalogue passed the pay-to-win audit")
end

--------------------------------------------------------------------------------
-- Transactions
--------------------------------------------------------------------------------

export type Result = { ok: boolean, reason: string?, balance: number }

function Shop.owns(handle: Profile.Handle, category: Category, id: string): boolean
	if category == "camos" then return CamoCatalog.isUnlocked(handle.data, id) end
	local field = OWNERSHIP_FIELD[category]
	if not field then
		return false
	end
	return table.find(handle.data[field] or {}, id) ~= nil
end

--[[
	Buys an item. The client sends a category and an id and nothing else; every
	other value in this function comes from server-side data.
]]
function Shop.purchase(handle: Profile.Handle, category: Category, id: string): Result
	if not handle:isActive() then return { ok = false, reason = "inactive profile", balance = handle.data.currency } end
	if category == "camos" then return { ok = false, reason = "earned through headshots", balance = handle.data.currency } end
	--[[
		Consumables stack instead of being owned once, so they get their own
		path: buying adds one to stock rather than flipping an ownership flag.
		Red and gold kit is refused here at any price -- it drops from marshals
		and deep horde waves, and nobody buys their way past getting good.
	]]
	if category == "consumables" then
		if Config.get("consumables").liveEnabled ~= true then
			return { ok = false, reason = "Field kit is coming later.", balance = handle.data.currency }
		end
		if not Consumables.item(id) then
			return { ok = false, reason = "unknown item", balance = handle.data.currency }
		end
		if not Consumables.isPurchasable(id) then
			return { ok = false, reason = "not for sale -- this one drops", balance = handle.data.currency }
		end
		local stock = (handle.data.consumables or {})[id] or 0
		if stock >= Pricing.config().maxConsumableStock then
			return { ok = false, reason = "kit stock is full", balance = handle.data.currency }
		end
		local cost = Pricing.shopCost((Consumables.item(id) :: any).cost)
		if cost == nil then return { ok = false, reason = "not for sale", balance = handle.data.currency } end
		if not Profile.debit(handle, cost, `consumables/{id}`) then
			return { ok = false, reason = "insufficient funds", balance = handle.data.currency }
		end
		handle.data.consumables = handle.data.consumables or {}
		handle.data.consumables[id] = (handle.data.consumables[id] or 0) + 1
		return { ok = true, balance = handle.data.currency }
	end

	local field = OWNERSHIP_FIELD[category]
	if not field then
		return { ok = false, reason = "unknown category", balance = handle.data.currency }
	end

	local entry = entryFor(category, id)
	if not entry then
		return { ok = false, reason = "unknown item", balance = handle.data.currency }
	end

	if Shop.owns(handle, category, id) then
		return { ok = false, reason = "already owned", balance = handle.data.currency }
	end

	local cost = Pricing.shopCost(entry.cost)
	if type(cost) ~= "number" then
		return { ok = false, reason = "item is not purchasable with currency", balance = handle.data.currency }
	end

	if not Profile.debit(handle, cost, `{category}/{id}`) then
		return { ok = false, reason = "insufficient funds", balance = handle.data.currency }
	end

	table.insert(handle.data[field], id)
	return { ok = true, balance = handle.data.currency }
end

--- Equips an owned item. Refuses anything not owned, which is the other half of
--- the exploit surface: buying is guarded, so equipping must be too.
function Shop.equip(handle: Profile.Handle, category: Category, id: string): Result
	if not handle:isActive() then return { ok = false, reason = "inactive profile", balance = handle.data.currency } end
	if category == "camos" then
		local ok, reason = Camos.equip(handle, id)
		return { ok = ok, reason = reason, balance = handle.data.currency }
	end
	local slot = LOADOUT_FIELD[category]
	if not slot then
		return { ok = false, reason = "unknown category", balance = handle.data.currency }
	end
	if not Shop.owns(handle, category, id) then
		return { ok = false, reason = "not owned", balance = handle.data.currency }
	end
	handle.data.loadout[slot] = id
	return { ok = true, balance = handle.data.currency }
end

--- Grants a Robux product's contents. Called only from a verified receipt.
function Shop.grantProduct(handle: Profile.Handle, productId: string): boolean
	if not handle:isActive() then return false end
	local product = Config.require("economy", "shop.robux.products")[productId]
	if not product then
		return false
	end
	for category, ids in pairs(product.grants) do
		local field = OWNERSHIP_FIELD[category]
		if field and type(ids) == "table" then
			for _, id in ipairs(ids) do
				if not Shop.owns(handle, category :: Category, id) then
					table.insert(handle.data[field], id)
				end
			end
		end
	end
	log.info(`granted robux product {productId} to {handle.userId}`)
	return true
end

--- The catalogue as the client should see it: ids, names, costs, ownership. No
--- prices are ever sent FROM the client, so this is display data only.
function Shop.catalogueFor(handle: Profile.Handle): any
	local out: any = {}
	for category in pairs(OWNERSHIP_FIELD) do
		local list = {}
		local ids: { string }
		if category == "markers" then
			ids = Config.get("markers").order
		elseif category == "barrels" or category == "hoppers" or category == "tanks" then
			ids = Config.require("economy", "shop." .. category)
		elseif table.find(GearStats.CATEGORIES, category) then
			ids = GearStats.order(category)
		else
			ids = {}
			for id in pairs(Config.require("economy", "shop.cosmetics." .. category)) do
				table.insert(ids, id)
			end
			table.sort(ids)
		end
		for _, id in ipairs(ids) do
			local entry = entryFor(category :: Category, id)
			if entry then
				table.insert(list, {
					id = id,
					displayName = entry.displayName,
					cost = Pricing.shopCost(entry.cost),
					free = Pricing.shopCost(entry.cost) == 0,
					description = entry.description or entry.blurb,
					stats = if category == "markers" then { roundsPerMinute = entry.roundsPerMinute, hopperCapacity = entry.hopperCapacity, reloadSeconds = entry.reloadSeconds, muzzleVelocity = entry.muzzleVelocity } else nil,
					owned = Shop.owns(handle, category :: Category, id),
					equipped = handle.data.loadout[LOADOUT_FIELD[category]] == id,
				})
			end
		end
		out[category] = list
	end
	out.consumables = Consumables.catalogue(handle.data.consumables or {})
	for _, row in ipairs(out.consumables) do
		row.comingSoon = Config.get("consumables").liveEnabled ~= true
		if row.comingSoon then row.purchasable = false end
		row.cost = if row.purchasable then Pricing.shopCost(row.cost) else nil
		row.free = row.cost == 0
	end
	out.camos = CamoCatalog.catalogue(handle.data)
	out.offers = Commerce.catalogueFor(handle)
	out.freeMode = Pricing.isFree()
	return out
end

return Shop
