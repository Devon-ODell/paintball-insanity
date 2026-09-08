--!strict
local RS = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local Config = require(RS.Shared.Config)
local Catalog = require(RS.Shared.CommerceCatalog)
local Dev = require(RS.Shared.Dev)
local Profile = require(Server.Economy.Profile)
local Shop = require(Server.Economy.Shop)
local Commerce = require(Server.Economy.Commerce)

return function()
	local handle, cfg, service, deps, state, player
	beforeEach(function()
		Dev._setOverrideForTesting({ enabled = false })
		Profile._resetFallback()
		cfg = Profile.deepCopy(Config.get("monetization"))
		Catalog._setOverrideForTesting(cfg)
		handle = Profile.load(1234)
		player = { UserId = 1234 }
		state = { persistent = true, save = true, present = true, policyCalls = 0, prompts = 0, saved = nil, owned = false }
		deps = {
			profileFor = function() return handle end,
			persistent = function() return state.persistent end,
			save = function(h, predicate)
				if state.save then state.saved = Profile.deepCopy(h.data) end
				return predicate(state.saved) == true
			end,
			players = { GetPlayerByUserId = function() return if state.present then player else nil end },
			policy = { GetPolicyInfoForPlayerAsync = function()
				state.policyCalls += 1
				if state.policyError then error("unavailable") end
				return { ArePaidRandomItemsRestricted = true }
			end },
			marketplace = {
				UserOwnsGamePassAsync = function() return state.owned end,
				GetProductInfoAsync = function() return { IsForSale = true, PriceInRobux = 13 } end,
				PromptGamePassPurchase = function() state.prompts += 1 end,
				PromptProductPurchase = function() state.prompts += 1 end,
			},
		}
		service = Commerce.new(deps)
	end)
	afterEach(function()
		Catalog._setOverrideForTesting(nil)
		Dev._setOverrideForTesting(nil)
	end)

	local function paidFixture()
		cfg.freeMode, cfg.paidEnabled = false, true
		cfg.offers.paintPack.marketplaceId = 123
	end
	local function receipt(id: string?): any
		cfg.offers.paintPack.marketplaceId = 123
		cfg.offers.paintPack.kind = "developerProduct"
		return { PlayerId = 1234, ProductId = 123, PurchaseId = id or "receipt-one" }
	end

	describe("free launch", function()
		it("keeps both real-money switches off and every offered shop price zero", function()
			expect(cfg.freeMode).to.equal(true)
			expect(cfg.paidEnabled).to.equal(false)
			for _, rows in pairs(Shop.catalogueFor(handle)) do
				if type(rows) == "table" then
					for _, row in ipairs(rows) do
						if row.cost ~= nil then expect(row.cost).to.equal(0) end
						if row.price ~= nil then expect(row.price).to.equal(0) end
					end
				end
			end
		end)
		it("claims gameplay stock without any funds and preserves balance", function()
			for _, id in ipairs({ "electronic", "pump", "yardTeal", "yardOchre", "yardOlive", "yardCobalt", "yardCoral" }) do
				expect(Shop.purchase(handle, "markers", id).ok).to.equal(true)
			end
			expect(handle.data.currency).to.equal(0)
		end)
		it("keeps challenge items earned-only at zero prices", function()
			expect(Shop.purchase(handle, "markers", "aurumKompressor").ok).to.equal(false)
			for _, row in ipairs(Shop.catalogueFor(handle).camos) do
				expect(Shop.purchase(handle, "camos", row.id).ok).to.equal(false)
				if row.requiredHeadshots > 0 then expect(Shop.equip(handle, "camos", row.id).ok).to.equal(false) end
			end
		end)
		it("refuses release consumables whose live effects are unavailable", function()
			for _, row in ipairs(Shop.catalogueFor(handle).consumables) do
				expect(row.comingSoon).to.equal(true)
				expect(row.purchasable).to.equal(false)
				expect(Shop.purchase(handle, "consumables", row.id).ok).to.equal(false)
			end
		end)
		it("bounds free consumable stock and still rejects red/gold items", function()
			local kit = Config.get("consumables")
			kit.liveEnabled = true
			local ok, err = pcall(function()
			for _, row in ipairs(Shop.catalogueFor(handle).consumables) do
				if row.purchasable then
					expect(Shop.purchase(handle, "consumables", row.id).ok).to.equal(true)
					handle.data.consumables[row.id] = cfg.maxConsumableStock
					expect(Shop.purchase(handle, "consumables", row.id).ok).to.equal(false)
				else expect(Shop.purchase(handle, "consumables", row.id).ok).to.equal(false) end
			end
			end)
			kit.liveEnabled = false
			assert(ok, tostring(err))
		end)
		it("claims cosmetic collections and saves inventory with the claim", function()
			expect(service:claim(player, "paintPack").ok).to.equal(true)
			expect(state.saved.commerce.claims.paintPack).to.equal(true)
			expect(table.find(state.saved.ownedPaintColors, "pink") ~= nil).to.equal(true)
			expect(handle.data.currency).to.equal(0)
		end)
		it("repeated free claims do not duplicate items", function()
			service:claim(player, "paintPack")
			local count = #handle.data.ownedPaintColors
			service:claim(player, "paintPack")
			expect(#handle.data.ownedPaintColors).to.equal(count)
		end)
		it("never opens a paid prompt in free mode, even with real IDs and the paid switch set", function()
			cfg.offers.paintPack.marketplaceId, cfg.paidEnabled = 123, true
			expect(service:prompt(player, "paintPack").ok).to.equal(false)
			expect(state.prompts).to.equal(0)
			expect(state.policyCalls).to.equal(0)
		end)
		it("allows free offline demo claims without calling a paid API", function()
			state.persistent, state.policyError = false, true
			expect(service:claim(player, "paintPack").ok).to.equal(true)
			expect(state.prompts).to.equal(0)
		end)
		it("refuses forged grants, unknown ids and malformed requests", function()
			expect(service:claim(player, "invented").ok).to.equal(false)
			expect(service:request(player, "paintPack").ok).to.equal(false)
			expect(service:request(player, { action = "grant", id = "paintPack", currency = 1e9 }).ok).to.equal(false)
			expect(handle.data.currency).to.equal(0)
		end)
	end)

	describe("paid framework stays fail-closed", function()
		it("refuses claims after free mode ends", function()
			paidFixture()
			expect(service:claim(player, "paintPack").ok).to.equal(false)
		end)
		it("requires persistence and policy success before prompting", function()
			paidFixture()
			state.persistent = false
			expect(service:prompt(player, "paintPack").ok).to.equal(false)
			state.persistent, state.policyError = true, true
			expect(service:prompt(player, "paintPack").ok).to.equal(false)
			expect(state.prompts).to.equal(0)
		end)
		it("opens only a deliberate valid prompt and grants nothing from it", function()
			paidFixture()
			expect(service:prompt(player, "paintPack").ok).to.equal(true)
			expect(state.prompts).to.equal(1)
			expect(#handle.data.ownedPaintColors).to.equal(1)
		end)
		it("rechecks pass ownership and saves it together with cosmetics", function()
			paidFixture()
			expect(service:refreshPass(player, "paintPack")).to.equal(false)
			state.owned = true
			expect(service:refreshPass(player, "paintPack")).to.equal(true)
			expect(state.saved.commerce.passes.paintPack).to.equal(123)
			expect(table.find(state.saved.ownedPaintColors, "violet") ~= nil).to.equal(true)
		end)
		it("never grants after a session is lost during ownership lookup", function()
			paidFixture()
			deps.marketplace.UserOwnsGamePassAsync = function() handle:release(); return true end
			expect(service:refreshPass(player, "paintPack")).to.equal(false)
			expect(#handle.data.ownedPaintColors).to.equal(1)
		end)
		it("audits real-money grants against a cosmetic allowlist", function()
			expect(#Commerce.audit()).to.equal(0)
			cfg.offers.paintPack.grants.markers = { "pump" }
			expect(#Commerce.audit() > 0).to.equal(true)
		end)
		it("catches unsupported features and placeholder IDs before paid activation", function()
			cfg.freeMode, cfg.paidEnabled = false, true
			cfg.features.ads = true
			expect(#Commerce.audit() >= 3).to.equal(true)
		end)
	end)

	describe("receipt durability", function()
		it("does not acknowledge until the inventory and purchase id are saved", function()
			local r = receipt()
			state.save = false
			expect(service:processReceipt(r)).to.equal(Enum.ProductPurchaseDecision.NotProcessedYet)
			expect(handle.data.commerce.receipts[r.PurchaseId] ~= nil).to.equal(true)
			local count = #handle.data.ownedPaintColors
			state.save = true
			expect(service:processReceipt(r)).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)
			expect(#handle.data.ownedPaintColors).to.equal(count)
			expect(state.saved.commerce.receipts[r.PurchaseId].productId).to.equal(123)
		end)
		it("records distinct purchases individually and tolerates replay", function()
			expect(service:processReceipt(receipt("first"))).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)
			expect(service:processReceipt(receipt("second"))).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)
			expect(service:processReceipt(receipt("first"))).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)
			expect(handle.data.commerce.receipts.first ~= nil).to.equal(true)
			expect(handle.data.commerce.receipts.second ~= nil).to.equal(true)
			expect(#handle.data.ownedPaintColors).to.equal(5)
		end)
		it("defers unknown, malformed, absent-player and temporary-store receipts", function()
			expect(service:processReceipt({})).to.equal(Enum.ProductPurchaseDecision.NotProcessedYet)
			local r = receipt(); r.ProductId = 999
			expect(service:processReceipt(r)).to.equal(Enum.ProductPurchaseDecision.NotProcessedYet)
			state.present = false
			expect(service:processReceipt(receipt())).to.equal(Enum.ProductPurchaseDecision.NotProcessedYet)
			state.present, state.persistent = true, false
			expect(service:processReceipt(receipt())).to.equal(Enum.ProductPurchaseDecision.NotProcessedYet)
			expect(#handle.data.ownedPaintColors).to.equal(1)
		end)
		it("fulfills already charged receipts even after an offer is disabled", function()
			local r = receipt()
			cfg.offers.paintPack.enabled = false
			expect(service:processReceipt(r)).to.equal(Enum.ProductPurchaseDecision.PurchaseGranted)
		end)
		it("defers concurrent callbacks and retries safely after a save error", function()
			local r = receipt()
			local nested
			deps.save = function()
				nested = service:processReceipt(r)
				error("storage unavailable")
			end
			expect(service:processReceipt(r)).to.equal(Enum.ProductPurchaseDecision.NotProcessedYet)
			expect(nested).to.equal(Enum.ProductPurchaseDecision.NotProcessedYet)
			expect(service.busy[player.UserId]).to.equal(nil)
		end)
	end)

	describe("economy integrity", function()
		it("reconciles old saves without losing balance, equipment or progress", function()
			local old = { version = 1, currency = 700, ownedMarkers = { "mechanical", "pump" }, loadout = { marker = "pump" } }
			Profile.reconcile(old)
			expect(old.currency).to.equal(700)
			expect(#old.ownedMarkers).to.equal(2)
			expect(old.loadout.marker).to.equal("pump")
			expect(old.loadout.camo).to.equal("factory")
			expect(old.camoProgress.headshots).to.equal(0)
			expect(old.commerce.receipts ~= nil).to.equal(true)
		end)
		it("rejects NaN, infinity and tiny negative debits without corrupting funds", function()
			for _, amount in ipairs({ 0/0, math.huge, -math.huge, -0.1 }) do
				expect(function() Profile.debit(handle, amount, "test") end).to.throw()
				expect(function() Profile.credit(handle, amount, "test") end).to.throw()
			end
			expect(handle.data.currency).to.equal(0)
		end)
		it("refuses mutations on released sessions", function()
			handle:release()
			expect(Shop.purchase(handle, "markers", "pump").ok).to.equal(false)
			expect(service:claim(player, "paintPack").ok).to.equal(false)
			expect(Profile.debit(handle, 0, "test")).to.equal(false)
		end)
	end)
end
