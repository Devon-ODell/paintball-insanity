--!nolint
--[[
	The season track.

	The arithmetic is pure, so it is asserted directly rather than through a
	match. What matters here is not that the numbers are right in isolation but
	that the track cannot become a way to buy an advantage or to punish the
	player for dying, both of which are one careless edit away.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Season = require(ReplicatedStorage.Shared.Season)
local Config = require(ReplicatedStorage.Shared.Config)

return function()
	local scoring = {
		perElimination = 10,
		clearBonus = 100,
		flawlessBonus = 150,
		tierMultiplier = { rec = 1.0, amateur = 1.6, semipro = 2.6, pro = 4.2 },
	}

	local tiers = {
		{ marks = 100, free = { category = "paintColors", id = "ember" } },
		{ marks = 250, paid = { category = "jerseys", id = "ironworks" } },
		{ marks = 500, free = { category = "masks", id = "chromeLens" }, paid = { category = "markerSkins", id = "emberwork" } },
	}

	describe("marks", function()
		it("pays for eliminations whether or not the match was cleared", function()
			expect(Season.marksFor({ eliminations = 6, cleared = false }, scoring)).to.equal(60)
		end)

		it("pays more for a clear at a harder tier", function()
			local rec = Season.marksFor({ eliminations = 40, cleared = true, deaths = 3, tier = "rec" }, scoring)
			local pro = Season.marksFor({ eliminations = 40, cleared = true, deaths = 3, tier = "pro" }, scoring)
			expect(pro > rec).to.equal(true)
		end)

		--[[
			The game's own rule is that death costs payout, not progress. A track
			that took marks away for dying would punish exactly the
			experimentation the difficulty is built to encourage.
		]]
		it("never subtracts for deaths -- they only forfeit the flawless bonus", function()
			local clean = Season.marksFor({ eliminations = 40, cleared = true, deaths = 0, tier = "rec" }, scoring)
			local messy = Season.marksFor({ eliminations = 40, cleared = true, deaths = 9, tier = "rec" }, scoring)
			expect(clean - messy).to.equal(scoring.flawlessBonus)
			expect(messy > 0).to.equal(true)
		end)

		it("cannot be driven negative by a nonsense summary", function()
			expect(Season.marksFor({ eliminations = -50, cleared = false }, scoring)).to.equal(0)
		end)
	end)

	describe("tiers", function()
		it("reports the highest tier reached, and none below the first", function()
			expect(Season.tierFor(0, tiers)).to.equal(0)
			expect(Season.tierFor(99, tiers)).to.equal(0)
			expect(Season.tierFor(100, tiers)).to.equal(1)
			expect(Season.tierFor(499, tiers)).to.equal(2)
			expect(Season.tierFor(9999, tiers)).to.equal(3)
		end)

		it("counts down to the next tier and stops at the end of the track", function()
			expect(Season.toNextTier(0, tiers)).to.equal(100)
			expect(Season.toNextTier(9999, tiers)).to.equal(nil)
		end)
	end)

	describe("rewards", function()
		it("gives a free player the free column and nothing else", function()
			local record = { id = "s1", marks = 600, claimed = {} }
			local due = Season.rewardsDue(record, tiers, false)
			expect(#due).to.equal(2)
			for _, reward in ipairs(due) do
				expect(reward.id ~= "ironworks" and reward.id ~= "emberwork").to.equal(true)
			end
		end)

		it("grants each reward once", function()
			local record = { id = "s1", marks = 600, claimed = {} }
			Season.markClaimed(record, tiers, true)
			expect(#Season.rewardsDue(record, tiers, true)).to.equal(0)
		end)

		--[[
			Buying the pass halfway through a season has to hand over everything
			already earned. The alternative is charging someone and giving them
			less than a player who bought earlier for the same money.
		]]
		it("back-pays the paid column when the pass is bought mid-season", function()
			local record = { id = "s1", marks = 600, claimed = {} }
			Season.markClaimed(record, tiers, false)
			expect(#Season.rewardsDue(record, tiers, false)).to.equal(0)

			local afterPurchase = Season.rewardsDue(record, tiers, true)
			expect(#afterPurchase).to.equal(2)
		end)
	end)

	describe("rollover", function()
		it("keeps a record from the current season", function()
			local existing = { id = "s1", marks = 900, claimed = { ["1:free"] = true } }
			expect(Season.recordFor(existing, "s1").marks).to.equal(900)
		end)

		it("resets marks and claims when the season changes", function()
			local existing = { id = "s1", marks = 900, claimed = { ["1:free"] = true } }
			local next_ = Season.recordFor(existing, "s2")
			expect(next_.marks).to.equal(0)
			expect(next_.claimed["1:free"]).to.equal(nil)
		end)
	end)

	describe("the shipped season", function()
		it("is reachable and every reward is colour only", function()
			local cfg = Config.get("seasons")
			local best = Season.marksFor(
				{ eliminations = 40, cleared = true, deaths = 0, tier = "pro" },
				cfg.scoring
			)
			local clears = cfg.tiers[#cfg.tiers].marks / best
			expect(clears > 3 and clears < 40).to.equal(true)

			local colourOnly = { paintColors = true, markerSkins = true, jerseys = true, masks = true }
			for _, tier in ipairs(cfg.tiers) do
				for _, column in ipairs({ "free", "paid" }) do
					local reward = tier[column]
					if reward then
						expect(colourOnly[reward.category]).to.equal(true)
					end
				end
			end
		end)

		it("gives a player who never pays something to finish with", function()
			local cfg = Config.get("seasons")
			local free = 0
			for _, tier in ipairs(cfg.tiers) do
				if tier.free then
					free += 1
				end
			end
			expect(free > 0).to.equal(true)
		end)
	end)
end
