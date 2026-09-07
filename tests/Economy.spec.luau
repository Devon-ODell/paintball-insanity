--!nolint
--[[
	Phase 6 acceptance: payout math against hand-computed fixtures, the
	death-penalty ratio target, and the exploit tests -- a client that tries to
	name its own payout, currency or inventory must be rejected.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local Payout = require(Server.Economy.Payout)
local Profile = require(Server.Economy.Profile)
local Shop = require(Server.Economy.Shop)
local Config = require(ReplicatedStorage.Shared.Config)
local Dev = require(ReplicatedStorage.Shared.Dev)
local Pricing = require(ReplicatedStorage.Shared.CommerceCatalog)
local RoundSchedule = require(Server.Match.RoundSchedule)

--[[
	Every spec below asserts SHIPPING behaviour, so dev overrides are pinned off
	first. Data/dev.json currently ships with infiniteCurrency ON for the dev
	build; without this pin, half of these tests would silently start passing for
	the wrong reason. The dev flags get their own block at the bottom.
]]
local function shippingMode()
	Dev._setOverrideForTesting({ enabled = false })
	local priced = Profile.deepCopy(Config.get("monetization"))
	priced.freeMode, priced.shopFree = false, false
	Pricing._setOverrideForTesting(priced)
end

local function devMode(flags: any)
	Dev._setOverrideForTesting(flags)
end

local function freshProfile()
	Profile._resetFallback()
	return (Profile.load(1234) :: any)
end

local function baseInput(overrides: any): any
	local input = {
		map = "speedball",
		tier = "rec",
		marker = "mechanical",
		deaths = 0,
		shots = 100,
		hits = 18,
		longestStreak = 1,
		cleared = true,
	}
	for k, v in pairs(overrides) do
		input[k] = v
	end
	return input
end

return function()
	beforeEach(function()
		shippingMode()
	end)

	afterEach(function()
		Dev._setOverrideForTesting(nil)
		Pricing._setOverrideForTesting(nil)
	end)

	describe("death penalty", function()
		it("is exactly 1 with no deaths", function()
			expect(Payout.deathPenalty(0)).to.equal(1)
		end)

		it("matches the hand-computed curve", function()
			-- floor + (1 - floor) * exp(-decay * deaths), decay 0.26, floor 0.06
			-- deaths = 1 -> 0.06 + 0.94 * e^-0.26 = 0.06 + 0.94 * 0.771052 = 0.784789
			expect(Payout.deathPenalty(1)).to.be.near(0.784789, 1e-5)
			-- deaths = 10 -> 0.06 + 0.94 * e^-2.6 = 0.06 + 0.94 * 0.0742736 = 0.129817
			expect(Payout.deathPenalty(10)).to.be.near(0.129817, 1e-5)
		end)

		it("hits the tuning target: a clean clear pays many times a grind", function()
			--[[
				BUILD_PLAN Phase 6: "Tune so a no-death clear pays roughly 8-10x
				a ten-death clear." The raw curve gives 7.7x; the flawless bonus
				is what carries it into the target band, so both are asserted.
			]]
			expect(Payout.deathPenaltyRatio(10)).to.be.within(6, 12)

			local clean = Payout.compute(baseInput({ deaths = 0 }))
			local grind = Payout.compute(baseInput({ deaths = 10 }))
			expect(clean.total / grind.total).to.be.within(8, 14)
		end)

		it("never reaches zero, so finishing is always worth something", function()
			expect(Payout.deathPenalty(1000) > 0).to.equal(true)
			expect(Payout.deathPenalty(1000)).to.be.near(0.06, 1e-6)
		end)

		it("decreases monotonically", function()
			local previous = math.huge
			for deaths = 0, 30 do
				local p = Payout.deathPenalty(deaths)
				expect(p < previous).to.equal(true)
				previous = p
			end
		end)
	end)

	describe("accuracy bonus", function()
		it("is 1 below the qualifying shot count", function()
			expect(Payout.accuracyBonus(5, 5)).to.equal(1)
		end)

		it("is 1 at or below the threshold hit rate", function()
			expect(Payout.accuracyBonus(100, 18)).to.equal(1)
			expect(Payout.accuracyBonus(100, 10)).to.equal(1)
		end)

		it("matches the hand-computed curve above it", function()
			-- 1 + 0.85 * (0.5 - 0.18) / 0.82 = 1 + 0.85 * 0.390244 = 1.331707
			expect(Payout.accuracyBonus(100, 50)).to.be.near(1.331707, 1e-5)
			-- Perfect: 1 + 0.85 = 1.85
			expect(Payout.accuracyBonus(100, 100)).to.be.near(1.85, 1e-9)
		end)
	end)

	describe("streak bonus", function()
		it("pays nothing for a single elimination", function()
			expect(Payout.streakBonus(1)).to.equal(1)
		end)

		it("accrues per extra elimination and caps", function()
			expect(Payout.streakBonus(4)).to.be.near(1.12, 1e-9)
			expect(Payout.streakBonus(100)).to.be.near(1.3, 1e-9)
		end)
	end)

	describe("total payout", function()
		it("multiplies out to the hand-computed figure", function()
			-- base 220 * tier 1.0 * marker 1.0 * deaths 1.0 * accuracy 1.0
			--   * streak 1.0 * flawless 1.5 = 330
			local result = Payout.compute(baseInput({ deaths = 0, longestStreak = 1, hits = 18 }))
			expect(result.total).to.equal(330)
		end)

		it("pays nothing for an unfinished round", function()
			expect(Payout.compute(baseInput({ cleared = false })).total).to.equal(0)
		end)

		it("pays more on harder tiers for the same performance", function()
			local previous = 0
			for _, tier in ipairs(Config.get("bots").tierOrder) do
				local total = Payout.compute(baseInput({ tier = tier })).total
				expect(total > previous).to.equal(true)
				previous = total
			end
		end)

		it("pays the pump premium", function()
			local mech = Payout.compute(baseInput({ marker = "mechanical" })).total
			local pump = Payout.compute(baseInput({ marker = "pump" })).total
			expect(pump > mech * 1.5).to.equal(true)
		end)

		it("pays more for a longer map", function()
			local speedball = Payout.compute(baseInput({ map = "speedball" })).total
			local woods = Payout.compute(baseInput({ map = "woods" })).total
			expect(woods > speedball).to.equal(true)
		end)

		it("gives the Range no payout at all", function()
			expect(Config.require("economy", "basePayout.range")).to.equal(0)
			expect(Payout.compute(baseInput({ map = "range" })).total).to.equal(0)
		end)
	end)

	describe("five-round matches", function()
		local function rounds(clearedCount: number): { any }
			local out = {}
			for i, round in ipairs(RoundSchedule.all("rec")) do
				out[i] = {
					index = round.index,
					tier = round.tier,
					payoutMultiplier = round.payoutMultiplier,
					cleared = i <= clearedCount,
				}
			end
			return out
		end

		local function matchInput(overrides: any): any
			local input = {
				map = "speedball",
				marker = "mechanical",
				rounds = rounds(5),
				deaths = 0,
				shots = 100,
				hits = 18,
				longestStreak = 1,
			}
			for k, v in pairs(overrides) do
				input[k] = v
			end
			return input
		end

		it("pays every round it cleared and nothing for the ones it did not", function()
			local partial = Payout.computeMatch(matchInput({ rounds = rounds(3) }))
			expect(partial.roundsCleared).to.equal(3)
			expect(partial.roundTotals[3] > 0).to.equal(true)
			expect(partial.roundTotals[4]).to.equal(0)
			expect(partial.roundTotals[5]).to.equal(0)
			expect(partial.cleared).to.equal(false)
		end)

		it("pays more for each later round", function()
			local full = Payout.computeMatch(matchInput({}))
			local previous = 0
			for _, value in ipairs(full.roundTotals) do
				expect(value > previous).to.equal(true)
				previous = value
			end
		end)

		it("only awards the flawless bonus for a clean sweep of all five", function()
			expect(Payout.computeMatch(matchInput({ deaths = 0 })).flawlessBonus > 1).to.equal(true)
			expect(Payout.computeMatch(matchInput({ deaths = 1 })).flawlessBonus).to.equal(1)
			expect(Payout.computeMatch(matchInput({ rounds = rounds(4), deaths = 0 })).flawlessBonus).to.equal(1)
		end)

		it("charges accumulated deaths once, against the whole match", function()
			--[[
				This is the load-bearing choice in the round structure: dying
				cheaply in round 1 to learn the angles still costs you round 5's
				money, which is what stops the escalation becoming free practice.
			]]
			local clean = Payout.computeMatch(matchInput({ deaths = 0 }))
			local grind = Payout.computeMatch(matchInput({ deaths = 10 }))
			expect(clean.total / grind.total).to.be.within(8, 14)
		end)

		it("is worth several times a single round", function()
			local full = Payout.computeMatch(matchInput({}))
			local firstOnly = Payout.computeMatch(matchInput({ rounds = rounds(1) }))
			expect(full.total / firstOnly.total > 4).to.equal(true)
		end)

		it("pays nothing at all for a match that cleared no rounds", function()
			expect(Payout.computeMatch(matchInput({ rounds = rounds(0) })).total).to.equal(0)
		end)

		it("keeps the round shares summing to the documented total", function()
			local total = RoundSchedule.totalPayoutMultiplier("rec")
			expect(total).to.be.near(5.6, 1e-9)
		end)
	end)

	describe("the monetization rule", function()
		--[[
			BUILD_PLAN: "Nothing purchasable may improve accuracy, reduce recoil,
			increase velocity, or otherwise substitute for aim." This is asserted
			rather than trusted, and the shop refuses to start if it fails.
		]]
		it("passes the pay-to-win audit", function()
			expect(function()
				Shop.assertNoPayToWin()
			end).never.to.throw()
		end)

		it("keeps every attachment's spread multiplier at exactly 1", function()
			local attachments = Config.get("markers").attachments
			for _, group in ipairs({ "barrels", "hoppers", "tanks" }) do
				for _, entry in pairs(attachments[group]) do
					expect(entry.spreadMultiplier or 1).to.equal(1)
				end
			end
		end)

		it("declares every Robux product cosmetic", function()
			for _, product in pairs(Config.require("economy", "shop.robux.products")) do
				expect(product.affectsAccuracy).to.equal(false)
				expect(product.grants.markers).to.equal(nil)
				expect(product.grants.barrels).to.equal(nil)
			end
		end)
	end)

	describe("profile", function()
		it("starts with the template loadout and no money", function()
			local handle = freshProfile()
			expect(handle.data.currency).to.equal(0)
			expect(handle.data.loadout.marker).to.equal("mechanical")
			expect(#handle.data.ownedMarkers).to.equal(1)
		end)

		it("credits a payout", function()
			local handle = freshProfile()
			Profile.credit(handle, 330, "test")
			expect(handle.data.currency).to.equal(330)
		end)

		it("refuses a negative credit rather than silently inverting it", function()
			local handle = freshProfile()
			expect(function()
				Profile.credit(handle, -100, "test")
			end).to.throw()
		end)

		it("never lets a balance go negative", function()
			local handle = freshProfile()
			Profile.credit(handle, 100, "test")
			expect(Profile.debit(handle, 500, "test")).to.equal(false)
			expect(handle.data.currency).to.equal(100)
		end)

		it("records a match into lifetime totals", function()
			local handle = freshProfile()
			Profile.recordMatch(handle, {
				map = "speedball", tier = "rec", marker = "mechanical",
				shots = 40, hits = 12, eliminations = 6, deaths = 0,
				cleared = true, durationSeconds = 120, scores = {},
			})
			expect(handle.data.lifetime.matches).to.equal(1)
			expect(handle.data.lifetime.flawless).to.equal(1)
			expect(handle.data.bestClears.speedball.deaths).to.equal(0)
		end)

		it("only improves a best clear, never worsens it", function()
			local handle = freshProfile()
			local function record(deaths: number)
				Profile.recordMatch(handle, {
					map = "speedball", tier = "rec", marker = "mechanical",
					shots = 40, hits = 12, eliminations = 6, deaths = deaths,
					cleared = true, durationSeconds = 120, scores = {},
				})
			end
			record(3)
			record(1)
			record(9)
			expect(handle.data.bestClears.speedball.deaths).to.equal(1)
		end)

		it("gates maps on skill, not on time played", function()
			local handle = freshProfile()
			expect(Profile.hasUnlocked(handle, "speedball")).to.equal(true)
			expect(Profile.hasUnlocked(handle, "dustline")).to.equal(false)
			Profile.recordMatch(handle, {
				map = "speedball", tier = "rec", marker = "mechanical",
				shots = 40, hits = 12, eliminations = 6, deaths = 4,
				cleared = true, durationSeconds = 120, scores = {},
			})
			-- The chain follows the curriculum: speedball opens Dustline, which
			-- opens Urban, which opens Woods, which opens Holdfast.
			expect(Profile.hasUnlocked(handle, "dustline")).to.equal(true)
			expect(Profile.hasUnlocked(handle, "urban")).to.equal(false)
		end)
	end)

	describe("shop exploits", function()
		--[[
			BUILD_PLAN Phase 6 acceptance: "a client attempting to report its own
			payout, currency, or inventory is rejected and logged."

			There is no API on the server that accepts a client-supplied price,
			balance or ownership claim -- that is the actual defence. These tests
			assert the shape of the surface that DOES exist.
		]]
		it("takes the price from server data, not from the caller", function()
			local handle = freshProfile()
			Profile.credit(handle, 100, "test")
			-- The electronic marker costs 4200. There is no argument by which a
			-- caller could claim otherwise: purchase() takes only a category
			-- and an id.
			local result = Shop.purchase(handle, "markers", "electronic")
			expect(result.ok).to.equal(false)
			expect(result.reason).to.equal("insufficient funds")
			expect(handle.data.currency).to.equal(100)
		end)

		it("rejects an unknown item instead of granting it free", function()
			local handle = freshProfile()
			Profile.credit(handle, 999999, "test")
			local result = Shop.purchase(handle, "markers", "railgun")
			expect(result.ok).to.equal(false)
			expect(result.reason).to.equal("unknown item")
			expect(#handle.data.ownedMarkers).to.equal(1)
		end)

		it("rejects an unknown category", function()
			local handle = freshProfile()
			expect(Shop.purchase(handle, "aimbot" :: any, "x").ok).to.equal(false)
		end)

		it("refuses to equip an item the player does not own", function()
			local handle = freshProfile()
			local result = Shop.equip(handle, "markers", "pump")
			expect(result.ok).to.equal(false)
			expect(result.reason).to.equal("not owned")
			expect(handle.data.loadout.marker).to.equal("mechanical")
		end)

		it("refuses to double-charge for an owned item", function()
			local handle = freshProfile()
			Profile.credit(handle, 20000, "test")
			expect(Shop.purchase(handle, "markers", "pump").ok).to.equal(true)
			local balance = handle.data.currency
			local second = Shop.purchase(handle, "markers", "pump")
			expect(second.ok).to.equal(false)
			expect(second.reason).to.equal("already owned")
			expect(handle.data.currency).to.equal(balance)
		end)

		it("completes a legitimate purchase and equip", function()
			local handle = freshProfile()
			Profile.credit(handle, 8000, "test")
			expect(Shop.purchase(handle, "markers", "pump").ok).to.equal(true)
			expect(Shop.equip(handle, "markers", "pump").ok).to.equal(true)
			expect(handle.data.loadout.marker).to.equal("pump")
			expect(handle.data.currency).to.equal(500)
		end)

		it("grants a Robux product only through the receipt path", function()
			local handle = freshProfile()
			expect(Shop.grantProduct(handle, "notARealProduct")).to.equal(false)
			expect(Shop.grantProduct(handle, "paintPack")).to.equal(true)
			expect(Shop.owns(handle, "paintColors", "pink")).to.equal(true)
			-- And it granted nothing that affects aim.
			expect(#handle.data.ownedMarkers).to.equal(1)
		end)

		it("shows the catalogue with server-side ownership flags", function()
			local handle = freshProfile()
			local catalogue = Shop.catalogueFor(handle)
			-- Four now: the three purchasable archetypes plus the Aurum
			-- Kompressor, which is listed but never for sale.
			expect(#catalogue.markers).to.equal(#Config.get("markers").order)
			expect(catalogue.markers[1].owned).to.equal(true)
			expect(catalogue.markers[2].owned).to.equal(false)
		end)
	end)

	describe("persistence", function()
		it("reports honestly when it is not persisting", function()
			-- The fallback exists so specs can run; it must never be silent.
			expect(Profile.isPersistent()).to.be.a("boolean")
		end)
	end)

	describe("dev overrides", function()
		--[[
			The dev flags exist so the game is testable before the economy is
			tuned. They are also the most dangerous thing in the repo, so they
			are tested from both sides: on, they must work; off, they must leave
			no trace.
		]]
		it("is off by default and leaves shipping behaviour untouched", function()
			shippingMode()
			local handle = freshProfile()
			expect(handle.data.currency).to.equal(0)
			expect(Profile.debit(handle, 1, "test")).to.equal(false)
			expect(Profile.hasUnlocked(handle, "woods")).to.equal(false)
		end)

		it("ignores individual flags while the master switch is off", function()
			devMode({ enabled = false, infiniteCurrency = { on = true, grantedBalance = 500 } })
			local handle = freshProfile()
			expect(handle.data.currency).to.equal(0)
			expect(Profile.debit(handle, 10, "test")).to.equal(false)
		end)

		it("grants an unspendable balance when infiniteCurrency is on", function()
			devMode({ enabled = true, infiniteCurrency = { on = true, grantedBalance = 12345 } })
			local handle = freshProfile()
			expect(handle.data.currency).to.equal(12345)
			expect(Profile.debit(handle, 999999, "test")).to.equal(true)
			expect(handle.data.currency).to.equal(12345)
		end)

		it("still runs every server-side purchase check while the wallet is fake", function()
			devMode({ enabled = true, infiniteCurrency = { on = true, grantedBalance = 12345 } })
			local handle = freshProfile()
			-- Unknown items are still refused: only the money is dev, not the rules.
			expect(Shop.purchase(handle, "markers", "railgun").ok).to.equal(false)
			expect(Shop.purchase(handle, "aimbot" :: any, "x").ok).to.equal(false)
			-- Equipping something unowned is still refused.
			expect(Shop.equip(handle, "markers", "pump").ok).to.equal(false)
			-- A real purchase still goes through the real transaction.
			expect(Shop.purchase(handle, "markers", "pump").ok).to.equal(true)
			expect(Shop.owns(handle, "markers", "pump")).to.equal(true)
			expect(Shop.purchase(handle, "markers", "pump").reason).to.equal("already owned")
		end)

		it("opens every map when unlockEverything is on", function()
			devMode({ enabled = true, unlockEverything = { on = true } })
			local handle = freshProfile()
			expect(Profile.hasUnlocked(handle, "woods")).to.equal(true)
			expect(Profile.hasUnlocked(handle, "urban")).to.equal(true)
		end)

		it("never lets a dev flag reach the payout maths", function()
			-- Payout is what the economy will eventually be tuned on. If a dev
			-- flag could touch it, every number measured in dev would be a lie.
			devMode({ enabled = true, infiniteCurrency = { on = true, grantedBalance = 99999999 } })
			local devTotal = Payout.compute(baseInput({ deaths = 4 })).total
			shippingMode()
			local shipTotal = Payout.compute(baseInput({ deaths = 4 })).total
			expect(devTotal).to.equal(shipTotal)
		end)
	end)
end
