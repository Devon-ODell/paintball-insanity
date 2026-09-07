--!strict
-- Optional cosmetic collections. Free claims and verified marketplace grants
-- share inventory mutations; clients never supply prices, grants or ownership.
local RS = game:GetService("ReplicatedStorage")
local Catalog = require(RS.Shared.CommerceCatalog)
local Config = require(RS.Shared.Config)
local Profile = require(script.Parent.Profile)
local Log = require(RS.Shared.Log).scope("LiveRound.Commerce")

local Commerce = {}
local FIELDS = { paintColors = "ownedPaintColors", markerSkins = "ownedMarkerSkins" }

function Commerce.audit(): { string }
	local problems = {}
	local cfg = Catalog.config()
	local used = {}
	for _, id in ipairs(cfg.order) do
		local offer = cfg.offers[id]
		if not offer then table.insert(problems, `missing offer {id}`); continue end
		if offer.kind ~= "pass" and offer.kind ~= "developerProduct" then
			table.insert(problems, `unsupported offer kind {id}`)
		end
		if offer.affectsAccuracy ~= false then table.insert(problems, `non-cosmetic offer {id}`) end
		for category, ids in pairs(offer.grants) do
			if not FIELDS[category] or type(ids) ~= "table" then
				table.insert(problems, `disallowed grant {id}/{category}`)
			else
				for _, itemId in ipairs(ids) do
					if not Config.get("economy").shop.cosmetics[category][itemId] then
						table.insert(problems, `unknown grant {id}/{itemId}`)
					end
				end
			end
		end
		if Catalog.validId(offer.marketplaceId) then
			local key = offer.kind .. "/" .. tostring(offer.marketplaceId)
			if used[key] then table.insert(problems, `duplicate marketplace id {key}`) end
			used[key] = true
		elseif cfg.paidEnabled and not cfg.freeMode and offer.enabled then
			table.insert(problems, `paid offer {id} has no marketplace id`)
		end
	end
	-- These require separate live benefits/eligibility flows; a switch cannot
	-- accidentally enable ads, random rewards, subscriptions or paid access.
	for feature, enabled in pairs(cfg.features) do
		if enabled then table.insert(problems, `unsupported feature enabled: {feature}`) end
	end
	return problems
end

local function owns(data: any, offer: any): boolean
	for category, ids in pairs(offer.grants) do
		for _, id in ipairs(ids) do
			if not table.find(data[FIELDS[category]] or {}, id) then return false end
		end
	end
	return true
end

local function grant(data: any, offer: any)
	for category, ids in pairs(offer.grants) do
		local field = FIELDS[category]
		assert(field, "Commerce refuses non-cosmetic grants")
		data[field] = data[field] or {}
		for _, id in ipairs(ids) do
			if not table.find(data[field], id) then table.insert(data[field], id) end
		end
	end
end

function Commerce.catalogueFor(handle: Profile.Handle): { any }
	local out = {}
	for _, id in ipairs(Catalog.config().order) do
		local offer = Catalog.offer(id)
		if offer.enabled then
			table.insert(out, {
				id = id, displayName = offer.displayName, description = offer.description,
				kind = offer.kind, marketplaceId = offer.marketplaceId,
				owned = owns(handle.data, offer), free = Catalog.isFree(),
				price = if Catalog.isFree() then 0 else nil,
				purchasable = Catalog.isFree() or (Catalog.canPrompt(offer) and Profile.isPersistent()),
			})
		end
	end
	return out
end

-- Injectable boundaries let receipt retries, lost sessions and failed writes be
-- tested with the production transaction logic, without making a real purchase.
function Commerce.new(deps: any?): any
	local d = deps or {
		marketplace = game:GetService("MarketplaceService"),
		policy = game:GetService("PolicyService"),
		players = game:GetService("Players"),
		profileFor = function(userId: number) return Profile.get(userId) end,
		persistent = Profile.isPersistent,
		save = Profile.saveConfirmed,
	}
	local self: any = { deps = d, policies = {}, busy = {}, lastRequest = {} }

	function self:policyFor(player: Player): any?
		local cached = self.policies[player.UserId]
		if cached and cached.expires > os.clock() then return cached.value end
		local ok, policy = pcall(function() return d.policy:GetPolicyInfoForPlayerAsync(player) end)
		if not ok or type(policy) ~= "table" then return nil end
		self.policies[player.UserId] = { value = policy, expires = os.clock() + Catalog.config().policyCacheSeconds }
		return policy
	end

	function self:claim(player: Player, id: string): any
		local offer = Catalog.offer(id)
		if not Catalog.isFree() then return { ok = false, reason = "Free claims are unavailable." } end
		if not offer or not offer.enabled then return { ok = false, reason = "Collection unavailable." } end
		local handle = d.profileFor(player.UserId)
		if not handle or not handle:isActive() then return { ok = false, reason = "Field pass unavailable." } end
		Profile.reconcile(handle.data)
		grant(handle.data, offer)
		handle.data.commerce.claims[id] = true
		if d.persistent() and not d.save(handle, function(saved: any)
			return saved and saved.commerce and saved.commerce.claims[id] == true
		end) then
			return { ok = false, reason = "Your collection is in your kit; save confirmation is pending. Try again shortly." }
		end
		return { ok = true, free = true }
	end

	function self:refreshPass(player: Player, id: string): boolean
		local offer = Catalog.offer(id)
		if not offer or offer.kind ~= "pass" or not Catalog.validId(offer.marketplaceId) then return false end
		if not d.persistent() then return false end
		local ok, owned = pcall(function() return d.marketplace:UserOwnsGamePassAsync(player.UserId, offer.marketplaceId) end)
		-- Refresh the handle AFTER every yielding ownership request.
		local handle = d.profileFor(player.UserId)
		if not ok or owned ~= true or not handle or not handle:isActive() then return false end
		Profile.reconcile(handle.data)
		grant(handle.data, offer)
		handle.data.commerce.passes[id] = offer.marketplaceId
		return d.save(handle, function(saved: any)
			return saved and saved.commerce and saved.commerce.passes[id] == offer.marketplaceId
		end)
	end

	function self:prompt(player: Player, id: string): any
		local offer = Catalog.offer(id)
		-- This check precedes ALL marketplace calls, even with configured IDs.
		if not Catalog.canPrompt(offer) then return { ok = false, reason = "Everything is free in this build. Use Claim free." } end
		if not d.persistent() then return { ok = false, reason = "Purchases are unavailable in this session." } end
		if not self:policyFor(player) then return { ok = false, reason = "Store eligibility is unavailable. Please try later." } end
		if offer.kind == "pass" and self:refreshPass(player, id) then return { ok = true, owned = true } end
		local handle = d.profileFor(player.UserId)
		if not handle or not handle:isActive() then return { ok = false, reason = "Field pass unavailable." } end
		if owns(handle.data, offer) then return { ok = true, owned = true } end
		local ok, info = pcall(function()
			return d.marketplace:GetProductInfoAsync(offer.marketplaceId,
				if offer.kind == "pass" then Enum.InfoType.GamePass else Enum.InfoType.Product)
		end)
		if not ok or not info or info.IsForSale ~= true then return { ok = false, reason = "Collection unavailable." } end
		-- Re-check after yielding; configuration/session may have changed.
		if not Catalog.canPrompt(offer) or not handle:isActive() then return { ok = false, reason = "Store unavailable." } end
		local prompted = pcall(function()
			if offer.kind == "pass" then d.marketplace:PromptGamePassPurchase(player, offer.marketplaceId)
			else d.marketplace:PromptProductPurchase(player, offer.marketplaceId) end
		end)
		return { ok = prompted, reason = if prompted then nil else "The purchase window could not open." }
	end

	function self:processReceipt(receipt: any): Enum.ProductPurchaseDecision
		local pending = Enum.ProductPurchaseDecision.NotProcessedYet
		if type(receipt) ~= "table" or type(receipt.PurchaseId) ~= "string" or receipt.PurchaseId == ""
			or not Catalog.validId(receipt.ProductId) or not Catalog.validId(receipt.PlayerId) then return pending end
		-- Receipts already charged must be fulfilled even if selling was since
		-- disabled. Never gate fulfilment on freeMode or policy eligibility.
		local offerId, offer
		for id, entry in pairs(Catalog.config().offers) do
			if entry.kind == "developerProduct" and entry.marketplaceId == receipt.ProductId then
				offerId, offer = id, entry; break
			end
		end
		if not offer or not d.persistent() or not d.players:GetPlayerByUserId(receipt.PlayerId) then return pending end
		if self.busy[receipt.PlayerId] then return pending end
		local handle = d.profileFor(receipt.PlayerId)
		if not handle or not handle:isActive() then return pending end
		self.busy[receipt.PlayerId] = true
		local ok, saved = pcall(function()
			Profile.reconcile(handle.data)
			local receipts = handle.data.commerce.receipts
			if receipts[receipt.PurchaseId] == nil then
				grant(handle.data, offer)
				receipts[receipt.PurchaseId] = { productId = receipt.ProductId, offerId = offerId }
			elseif receipts[receipt.PurchaseId].productId ~= receipt.ProductId then
				return false
			end
			return d.save(handle, function(snapshot: any)
				local entry = snapshot and snapshot.commerce and snapshot.commerce.receipts[receipt.PurchaseId]
				return entry ~= nil and entry.productId == receipt.ProductId
			end)
		end)
		self.busy[receipt.PlayerId] = nil
		if not ok then Log.warn(`receipt save failed: {saved}`) end
		return if ok and saved then Enum.ProductPurchaseDecision.PurchaseGranted else pending
	end

	function self:request(player: Player, payload: any): any
		if type(payload) ~= "table" then return { ok = false, reason = "Invalid store request." } end
		local now = os.clock()
		if now - (self.lastRequest[player.UserId] or -math.huge) < Catalog.config().requestCooldownSeconds then
			return { ok = false, reason = "Please wait a moment." }
		end
		self.lastRequest[player.UserId] = now
		if payload.action == "catalogue" then
			local handle = d.profileFor(player.UserId)
			return if handle then { ok = true, offers = Commerce.catalogueFor(handle) } else { ok = false }
		end
		if type(payload.id) ~= "string" then return { ok = false, reason = "Collection unavailable." } end
		if payload.action == "claim" then return self:claim(player, payload.id) end
		if payload.action == "prompt" then return self:prompt(player, payload.id) end
		return { ok = false, reason = "Invalid store action." }
	end

	function self:playerAdded(player: Player)
		self:policyFor(player)
		for _, id in ipairs(Catalog.config().order) do
			if not d.players:GetPlayerByUserId(player.UserId) then return end
			self:refreshPass(player, id)
		end
	end

	function self:forget(userId: number)
		self.policies[userId] = nil
		self.lastRequest[userId] = nil
	end

	function self:bind()
		assert(#Commerce.audit() == 0, table.concat(Commerce.audit(), "; "))
		d.marketplace.ProcessReceipt = function(receipt) return self:processReceipt(receipt) end
		d.marketplace.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
			if not wasPurchased then return end
			for id, offer in pairs(Catalog.config().offers) do
				if offer.kind == "pass" and offer.marketplaceId == passId then self:refreshPass(player, id) end
			end
		end)
	end
	return self
end

return Commerce
