--!nolint
--[[
	The campaign, the dialogue bank, horde scaling and the boss target model.

	The load-bearing assertions here are the ones about GATING: horde must not
	open early, chapters must not be skippable, and no escalation anywhere may
	produce a bot that a human could not be.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local Config = require(ReplicatedStorage.Shared.Config)
local Campaign = require(Server.Progression.Campaign)
local DialogueTree = require(Server.Dialogue.DialogueTree)
local Endless = require(Server.Match.Endless)
local Boss = require(Server.Match.Boss)
local Consumables = require(ReplicatedStorage.Shared.Consumables)

local function record(): Campaign.Record
	return Campaign.emptyRecord()
end

local function clear(r: Campaign.Record, map: string, tier: string, deaths: number?)
	r.clears[map] = r.clears[map] or {}
	r.clears[map][tier] = deaths or 3
end

--- Every GAUNTLET map. Holdfast is capture-the-flag only and has no five-round
--- gauntlet, so "clear every field" must not include it.
local function clearAll(r: Campaign.Record, tier: string, deaths: number?)
	for _, map in ipairs(Campaign.gauntletMaps()) do
		clear(r, map, tier, deaths)
	end
end

return function()
	describe("chapters", function()
		it("is a linear chain with no gaps", function()
			local chapters = Campaign.chapters()
			expect(#chapters >= 9).to.equal(true)
			expect(chapters[1].requires).to.equal(nil)
			for i = 2, #chapters do
				expect(chapters[i].requires).to.equal(chapters[i - 1].id)
				expect(chapters[i].index).to.equal(i)
			end
		end)

		it("starts on the first chapter", function()
			local current = Campaign.current(record())
			expect((current :: any).id).to.equal("walkOn")
		end)

		it("advances only when the goal is actually met", function()
			local r = record()
			expect(#Campaign.newlyCompleted(r)).to.equal(0)
			clear(r, "speedball", "rec")
			local done = Campaign.newlyCompleted(r)
			expect(#done).to.equal(1)
			expect(done[1].id).to.equal("walkOn")
			expect((Campaign.current(r) :: any).id).to.equal("yardSale")
		end)

		it("counts a higher tier as satisfying a lower-tier goal", function()
			local r = record()
			clear(r, "speedball", "pro")
			expect(Campaign.goalMet({ kind = "clearGauntlet", map = "speedball", tier = "rec" }, r)).to.equal(true)
		end)

		it("never skips a chapter, even if a later goal is already met", function()
			--[[
				Someone who somehow cleared pro first must still walk the chain.
				Prerequisites are strict, or the campaign stops being a campaign.
			]]
			local r = record()
			clearAll(r, "pro", 0)
			local done = Campaign.newlyCompleted(r)
			expect(done[1].id).to.equal("walkOn")
			-- Already-met goals still complete in prerequisite order.
			for index, chapter in ipairs(Campaign.chapters()) do
				expect(done[index].id).to.equal(chapter.id)
			end
		end)

		it("requires a pro Speedball clear before the pro circuit", function()
			local r = record()
			clearAll(r, "semipro")
			Campaign.newlyCompleted(r)
			expect(r.completed.regional).to.equal(true)
			expect(r.completed.theMarshal).to.equal(nil)
			clear(r, "speedball", "pro")
			Campaign.newlyCompleted(r)
			expect(r.completed.theMarshal).to.equal(true)
		end)

		it("describes every goal kind", function()
			for _, chapter in ipairs(Campaign.chapters()) do
				local text = Campaign.goalDescription(chapter.goal)
				expect(text).to.be.a("string")
				expect(text).never.to.equal("?")
			end
		end)
	end)

	describe("the gauntlet map set", function()
		it("excludes the capture-the-flag map", function()
			--[[
				Holdfast has no five-round gauntlet. If "clear every field" ever
				started including it, the campaign would be asking for something
				that cannot be done and the chain would dead-end at Local League.
			]]
			local gauntlet = Campaign.gauntletMaps()
			expect(table.find(gauntlet, "holdfast")).to.equal(nil)
			expect(table.find(gauntlet, "speedball")).to.be.ok()
			expect(table.find(gauntlet, "dustline")).to.be.ok()
		end)

		it("covers every map a chapter names", function()
			for _, chapter in ipairs(Campaign.chapters()) do
				if chapter.goal.kind == "clearGauntlet" then
					expect(table.find(Campaign.gauntletMaps(), chapter.goal.map)).to.be.ok()
				end
			end
		end)
	end)

	it("selects a playable tier for every release campaign chapter", function()
		local r = record()
		for _, chapter in ipairs(Campaign.chapters()) do
			expect(Campaign.recommendedTier(r)).to.equal(chapter.goal.tier)
			r.completed[chapter.id] = true
		end
		expect(Campaign.recommendedTier(r)).to.equal("pro")
	end)

	describe("horde gating", function()
		--[[
			The load-bearing gate. Horde has no curriculum in it -- it is a
			victory lap and a leaderboard -- so handing it out early would let a
			player skip the part that actually teaches them.
		]]
		it("is locked at the start", function()
			expect(Campaign.hordeUnlocked(record())).to.equal(false)
		end)

		it("stays locked through the whole gauntlet ladder until pro", function()
			local r = record()
			for _, tier in ipairs({ "rec", "amateur", "semipro" }) do
				clearAll(r, tier)
				Campaign.newlyCompleted(r)
				expect(Campaign.hordeUnlocked(r)).to.equal(false)
			end
		end)

		--[[
			This asserted the opposite until horde was integrated: it was named
			"keeps deferred Horde closed even after the pro sweep", and what it
			pinned was the DEFERRAL, not the gate. The deferral was lifted
			deliberately; the gate below is the part that always mattered and it
			is unchanged. The three checks around this one still assert that
			nothing short of a full pro sweep opens it.
		]]
		it("opens once the pro circuit is swept, and not before", function()
			local r = record()
			clearAll(r, "rec")
			Campaign.newlyCompleted(r)
			clearAll(r, "amateur")
			Campaign.newlyCompleted(r)
			clearAll(r, "semipro")
			Campaign.newlyCompleted(r)
			r.bosses.marshal = true
			Campaign.newlyCompleted(r)
			clearAll(r, "pro")
			Campaign.newlyCompleted(r)
			expect(r.completed.proCircuit).to.equal(true)
			expect(Campaign.hordeUnlocked(r)).to.equal(true)
		end)

		it("does not open on a partial pro sweep", function()
			local r = record()
			clearAll(r, "semipro")
			r.bosses.marshal = true
			Campaign.newlyCompleted(r)
			clear(r, "speedball", "pro")
			Campaign.newlyCompleted(r)
			expect(Campaign.hordeUnlocked(r)).to.equal(false)
		end)
	end)

	describe("the Aurum Kompressor", function()
		it("is the last chapter and cannot be bought", function()
			local chapters = Campaign.chapters()
			local last = chapters[#chapters]
			expect(last.id).to.equal("aurum")
			expect(last.rewards.gear[1]).to.equal("aurumKompressor")

			local marker = Config.require("markers", "markers.aurumKompressor")
			expect(marker.purchasable).to.equal(false)
			expect(marker.cost).to.equal(nil)
		end)

		it("is a sidegrade, not an upgrade", function()
			--[[
				The ultimate reward in an aim trainer cannot make you shoot
				better, or the game stops measuring anything. So it is a pump:
				twelve rounds, one shot per cycle, and it pays the most.
			]]
			local aurum = Config.require("markers", "markers.aurumKompressor")
			local mech = Config.require("markers", "markers.mechanical")
			expect(aurum.hopperCapacity < mech.hopperCapacity).to.equal(true)
			expect(aurum.roundsPerMinute < mech.roundsPerMinute).to.equal(true)
			expect(aurum.autoFire).to.equal(false)
			expect(aurum.payoutMultiplier > mech.payoutMultiplier).to.equal(true)
			-- And it is harder to shoot on the move than anything else.
			expect(aurum.movingSpreadMultiplier > mech.movingSpreadMultiplier).to.equal(true)
		end)

		it("requires a flawless pro sweep without unavailable modes", function()
			local chapter = Campaign.chapter("aurum") :: any
			expect(chapter.goal.kind).to.equal("flawlessGauntletAll")
			local r = record()
			r.hordeBestWave = 40
			expect(Campaign.goalMet(chapter.goal, r)).to.equal(false)
			clearAll(r, "pro", 0)
			expect(Campaign.goalMet(chapter.goal, r)).to.equal(true)
		end)

		it("does not accept a pro sweep that took hits", function()
			local r = record()
			r.hordeBestWave = 40
			clearAll(r, "pro", 1)
			expect(Campaign.goalMet((Campaign.chapter("aurum") :: any).goal, r)).to.equal(false)
		end)
	end)

	describe("dialogue", function()
		it("is structurally sound", function()
			local problems = DialogueTree.validate()
			if #problems > 0 then
				error("dialogue problems: " .. table.concat(problems, "; "))
			end
			expect(#problems).to.equal(0)
		end)

		it("opens every npc on a root node", function()
			for npcId in pairs(Config.require("npcs", "npcs")) do
				local node = DialogueTree.start(npcId, DialogueTree.emptyState())
				expect(node).to.be.ok()
				expect(#(node :: any).lines > 0).to.equal(true)
			end
		end)

		it("hides gated options until they are earned", function()
			local locked = DialogueTree.emptyState()
			local node = DialogueTree.start("tildy", locked) :: any
			local sawDrone = false
			for _, option in ipairs(node.options) do
				if option.text:find("drone") then
					sawDrone = true
				end
			end
			expect(sawDrone).to.equal(false)

			local unlocked = DialogueTree.emptyState()
			unlocked.unlocked.consumables = true
			local open = DialogueTree.start("tildy", unlocked) :: any
			for _, option in ipairs(open.options) do
				if option.text:find("drone") then
					sawDrone = true
				end
			end
			expect(sawDrone).to.equal(true)
		end)

		it("opens Marge on the Aurum offer once it is earned", function()
			local state = DialogueTree.emptyState()
			expect((DialogueTree.start("marge", state) :: any).id).to.equal("root")
			state.completed.theLongAfternoon = true
			expect((DialogueTree.start("marge", state) :: any).id).to.equal("aurumOffer")
		end)

		it("substitutes tokens and leaves unknown ones visible", function()
			local state = DialogueTree.emptyState()
			state.tokens.chapterBrief = "Go and clear Speedball."
			local node = DialogueTree.node("marge", "brief", state) :: any
			expect(node.lines[1]).to.equal("Go and clear Speedball.")

			local bare = DialogueTree.node("marge", "brief", DialogueTree.emptyState()) :: any
			expect(bare.lines[1]).to.equal("{chapterBrief}")
		end)

		it("walks a conversation to an end node", function()
			local state = DialogueTree.emptyState()
			local node = DialogueTree.start("denny", state) :: any
			local steps = 0
			while node and not node.isEnd and steps < 20 do
				node = (DialogueTree.choose("denny", node, 1, state))
				steps += 1
			end
			expect(steps < 20).to.equal(true)
		end)

		it("uses only actions the game knows how to perform", function()
			--[[
				Bootstrap.server.luau has a branch per action. If a new line adds
				an action nobody handles, pressing that option would silently do
				nothing -- so the list is pinned here and must be updated
				alongside the handler.
			]]
			local known = {
				openShop = true, acceptChapter = true, claimAurum = true,
				readPrescription = true, recommendDrill = true, startDrill = true,
				focusBoard = true, startHorde = true,
			}
			for _, action in ipairs(DialogueTree.actions()) do
				if not known[action] then
					error(`dialogue uses unhandled action '{action}'`)
				end
			end
		end)

		it("gives every npc in the roster a body position and a dialogue tree", function()
			for id, npc in pairs(Config.require("npcs", "npcs")) do
				expect(npc.displayName).to.be.a("string")
				expect(#npc.position).to.equal(3)
				expect(#npc.lookAt).to.equal(3)
				expect(DialogueTree.treeFor(id)).to.be.ok()
			end
		end)

		it("keeps the campaign brief reachable from Marge", function()
			-- The chapter brief is delivered by a person, not a menu. If that
			-- path ever breaks, the campaign becomes invisible.
			local state = DialogueTree.emptyState()
			state.tokens.chapterBrief = "TESTBRIEF"
			local root = DialogueTree.start("marge", state) :: any
			local found = false
			for index in ipairs(root.options) do
				local next_ = DialogueTree.choose("marge", root, index, state)
				if next_ and table.concat(next_.lines, " "):find("TESTBRIEF") then
					found = true
				end
			end
			expect(found).to.equal(true)
		end)
	end)

	describe("horde waves", function()
		it("grows the field and caps it", function()
			local previous = 0
			for wave = 1, 60 do
				local count = Endless.botCountFor(wave)
				expect(count >= previous).to.equal(true)
				previous = count
			end
			expect(previous).to.equal(Config.require("endless", "waves.botsMax"))
		end)

		it("climbs the tier ladder and stops at pro", function()
			expect(Endless.tierFor(1)).to.equal("rec")
			expect(Endless.tierFor(5)).to.equal("amateur")
			expect(Endless.tierFor(10)).to.equal("semipro")
			expect(Endless.tierFor(15)).to.equal("pro")
			expect(Endless.tierFor(500)).to.equal("pro")
		end)

		it("never produces a bot a human could not be", function()
			--[[
				BUILD_PLAN: "Bots do not cheat. Every bot parameter must be
				something a human could match." Horde does not get an exemption,
				so the veterancy curve is clamped and the clamps are asserted at
				an absurd depth.
			]]
			local floors = Config.require("endless", "waves.veterancy.floors")
			local proTier = Config.require("bots", "tiers.pro")
			for _, waveIndex in ipairs({ 15, 30, 60, 200, 1000 }) do
				local applied = Endless.applyVeterancy(proTier, Endless.wave(waveIndex))
				expect(applied.reactionTimeMs >= floors.reactionTimeMs).to.equal(true)
				expect(applied.aimErrorDeg >= floors.aimErrorDeg).to.equal(true)
				expect(applied.leadSolutionAccuracy <= floors.leadSolutionAccuracy).to.equal(true)
			end
		end)

		it("does not mutate the shared tier data", function()
			local proTier = Config.require("bots", "tiers.pro")
			local before = proTier.reactionTimeMs
			Endless.applyVeterancy(proTier, Endless.wave(400))
			expect(proTier.reactionTimeMs).to.equal(before)
		end)

		it("leaves early waves entirely unmodified", function()
			local proTier = Config.require("bots", "tiers.pro")
			local applied = Endless.applyVeterancy(proTier, Endless.wave(1))
			expect(applied.reactionTimeMs).to.equal(proTier.reactionTimeMs)
			expect(applied.aimErrorDeg).to.equal(proTier.aimErrorDeg)
		end)

		it("schedules breathers and bosses", function()
			expect(Endless.isBreather(5)).to.equal(true)
			expect(Endless.isBreather(6)).to.equal(false)
			expect(Endless.isBoss(7)).to.equal(true)
			expect(Endless.isBoss(14)).to.equal(true)
			expect(Endless.bossFor(7)).to.be.a("string")
			expect(Endless.bossFor(8)).to.equal(nil)
		end)

		it("cycles through the boss roster", function()
			local seen: { [string]: boolean } = {}
			for occurrence = 1, 5 do
				seen[Endless.bossFor(occurrence * 7) :: string] = true
			end
			local count = 0
			for _ in pairs(seen) do
				count += 1
			end
			expect(count >= 3).to.equal(true)
		end)

		it("pays superlinearly for depth", function()
			--[[
				Wave 30 must beat three runs to wave 10, or the optimal play is
				farming the easy waves -- the opposite of what endless is for.
			]]
			local deep = Endless.payoutFor(30, 4)
			local shallow = Endless.payoutFor(10, 1) * 3
			expect(deep > shallow).to.equal(true)
		end)

		it("gates the drop tiers by depth", function()
			expect(Endless.dropTierFor(5)).to.equal(nil)
			expect(Endless.dropTierFor(12)).to.equal("red")
			expect(Endless.dropTierFor(30)).to.equal("gold")
		end)
	end)

	describe("bosses", function()
		it("defines every boss the schedules reference", function()
			for _, id in ipairs(Config.require("bosses", "schedule.hordeCycle")) do
				expect(Boss.definition(id)).to.be.ok()
			end
			for _, id in pairs(Config.require("bosses", "schedule.gauntlet")) do
				expect(Boss.definition(id)).to.be.ok()
			end
		end)

		it("has no health, only a small target", function()
			--[[
				The whole boss design. If a `health` or `hits` field ever appears
				in bosses.json the one-hit rule is gone and so is the reason this
				game rates Mild.
			]]
			local encoded = ""
			for _, raw in pairs(Config.require("bosses", "bosses")) do
				for field in pairs(raw) do
					encoded ..= field:lower() .. " "
				end
			end
			for _, banned in ipairs({ "health", "hits", "hitpoints", "damage", "armour", "armor", "shield" }) do
				expect(encoded:find(banned, 1, true)).to.equal(nil)
			end
		end)

		it("makes the hopper a genuinely small target at range", function()
			local marshal = Boss.definition("marshal") :: any
			-- Under a degree at 25 m: a real precision test, not a body shot.
			expect(Boss.angularSizeDeg(marshal, 25) < 1.0).to.equal(true)
			-- But not impossible up close.
			expect(Boss.angularSizeDeg(marshal, 6) > 3.0).to.equal(true)
		end)

		it("gets harder to hit further away, monotonically", function()
			local marshal = Boss.definition("marshal") :: any
			local previous = math.huge
			for distance = 5, 60, 5 do
				local size = Boss.angularSizeDeg(marshal, distance)
				expect(size < previous).to.equal(true)
				previous = size
			end
		end)

		it("gives the Aurum Marshal the smallest target of all", function()
			local aurum = Boss.definition("aurumMarshal") :: any
			local marshal = Boss.definition("marshal") :: any
			expect(aurum.hopperRadiusMetres < marshal.hopperRadiusMetres).to.equal(true)
		end)

		it("builds marshals from real tiers rather than inventing aim", function()
			for _, id in ipairs(Boss.ids()) do
				local definition = Boss.definition(id) :: any
				local params = Boss.parametersFor(definition)
				local tierData = Config.require("bots", "tiers." .. definition.tier)
				-- Aim error and reaction come straight from an existing tier.
				expect(params.aimErrorDeg).to.equal(tierData.aimErrorDeg)
				expect(params.reactionTimeMs).to.equal(tierData.reactionTimeMs)
				-- Only discipline is overridden.
				expect(params.peekDiscipline).to.equal(definition.peekDiscipline)
			end
		end)

		it("only exposes the hopper when they move or shoot", function()
			expect(Boss.hopperExposed({ peeking = false, firing = false, repositioning = false })).to.equal(false)
			expect(Boss.hopperExposed({ peeking = true, firing = false, repositioning = false })).to.equal(true)
			expect(Boss.hopperExposed({ peeking = false, firing = true, repositioning = false })).to.equal(true)
		end)
	end)

	describe("consumables", function()
		it("declares no stat outside the allowed set", function()
			local violations = Consumables.audit()
			if #violations > 0 then
				error("consumables.json violations: " .. table.concat(violations, "; "))
			end
			expect(#violations).to.equal(0)
		end)

		it("has no damage, health or accuracy term anywhere", function()
			local encoded = ""
			for _, id in ipairs(Consumables.order()) do
				for field in pairs(Consumables.item(id) :: any) do
					encoded ..= field:lower() .. " "
				end
			end
			for _, banned in ipairs({ "damage", "health", "spread", "accuracy", "recoil", "velocitymultiplier" }) do
				expect(encoded:find(banned, 1, true)).to.equal(nil)
			end
		end)

		it("never lets red or gold kit be bought at any price", function()
			--[[
				Drops only. Being able to buy the good fill would let a player
				spend their way past the part where they get good, which is the
				whole thing the economy is designed to prevent.
			]]
			expect(Consumables.isPurchasable("emberfill")).to.equal(false)
			expect(Consumables.isPurchasable("chillfill")).to.equal(false)
			expect(Consumables.isPurchasable("marshalsWhistle")).to.equal(false)
			expect(Consumables.isPurchasable("paintGrenade")).to.equal(true)
		end)

		it("keeps the drone from being a wallhack", function()
			--[[
				The drone only surfaces bots that have FIRED recently -- an
				amplified version of a signal already in the world. If it ever
				grows a field that reveals everyone, crosshair placement stops
				being measurable and the aim trainer stops working.
			]]
			local drone = Consumables.item("spotterDrone") :: any
			expect(drone.revealsWhoFiredWithinSeconds).to.be.a("number")
			expect(drone.revealsWhoFiredWithinSeconds < 6).to.equal(true)
			expect((drone :: any).revealsAll).to.equal(nil)
			expect((drone :: any).revealsThroughWalls).to.equal(nil)
			-- And it is the loudest thing in the game, which is the cost.
			expect(drone.loudness > 1.5).to.equal(true)
		end)

		it("makes smoke block sight both ways", function()
			-- A one-way smoke would be a wallhack with extra steps.
			expect((Consumables.item("smokeCanister") :: any).blocksSightBothWays).to.equal(true)
		end)

		it("limits the carry to two slots", function()
			expect(Consumables.maxSlots()).to.equal(2)
			local stock = { paintGrenade = 5, smokeCanister = 5 }
			expect(Consumables.validateCarry({ "paintGrenade", "smokeCanister" }, stock)).to.equal(true)
			expect(Consumables.validateCarry({ "paintGrenade", "smokeCanister", "podPatch" }, stock)).to.equal(false)
		end)

		it("allows doubling up on one item", function()
			expect(Consumables.validateCarry({ "paintGrenade", "paintGrenade" }, { paintGrenade = 2 })).to.equal(true)
			expect(Consumables.validateCarry({ "paintGrenade", "paintGrenade" }, { paintGrenade = 1 })).to.equal(false)
		end)

		it("refuses an unknown item", function()
			expect(Consumables.validateCarry({ "nuke" }, { nuke = 99 })).to.equal(false)
		end)

		it("consumes without mutating the original stock", function()
			local stock = { paintGrenade = 3 }
			local after = Consumables.consume(stock, { "paintGrenade" })
			expect(stock.paintGrenade).to.equal(3)
			expect(after.paintGrenade).to.equal(2)
		end)

		it("never drives stock negative", function()
			expect(Consumables.consume({}, { "paintGrenade" }).paintGrenade).to.equal(0)
		end)
	end)
end
