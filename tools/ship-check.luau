--!nolint
--[[
	Pre-publish gate.

	    lune run tools/ship-check

	Fails if anything that is fine in development would be a problem live. Right
	now that is one thing and it is the important one: Data/dev.json giving the
	player infinite money. Run this before every publish; it exits non-zero so it
	can sit in CI.
]]

local process = require("@lune/process")
local Harness = require("./Harness")
local fs = require("@lune/fs")

local env = Harness.build()
local Config = env.require(env.ReplicatedStorage.Shared.Config)
local GearStats = env.require(env.ReplicatedStorage.Shared.GearStats)
local Consumables = env.require(env.ReplicatedStorage.Shared.Consumables)
local DialogueTree = env.require(env.ServerScriptService.Server.Dialogue.DialogueTree)

local problems: { string } = {}
local function check(ok: boolean, message: string)
	if ok then
		print(`  \27[32mok\27[0m    {message}`)
	else
		print(`  \27[31mFAIL\27[0m  {message}`)
		table.insert(problems, message)
	end
end

print("\27[1mship-check\27[0m")

local dev = Config.get("dev")
check(dev.enabled ~= true, "Data/dev.json has dev overrides disabled")
if dev.enabled == true then
	for name, entry in pairs(dev) do
		if type(entry) == "table" and entry.on == true then
			print(`          active flag: {name}`)
		end
	end
end

--[[
	Every mode offered to a player must have a live match loop.

	This used to assert "gauntlet and nothing else", which was true when it was
	written and became a lie the moment the Shoothouse was wired. Asserting the
	PROPERTY -- everything in `order` is integrated -- means the check keeps
	working as modes land instead of having to be edited alongside them.
]]
local modes = Config.get("gamemodes")
local unintegrated: { string } = {}
for _, name in ipairs(modes.order) do
	local mode = modes.modes[name]
	if not mode or mode.integrated ~= true then
		table.insert(unintegrated, name)
	end
end
for _, name in ipairs(unintegrated) do print(`          offered but not integrated: {name}`) end
check(#unintegrated == 0, "every mode the release offers has a live match loop")
check(modes.modes[modes.default] ~= nil and modes.modes[modes.default].integrated == true,
	"the default mode is integrated")
local reachableCamos = true
for _, camo in pairs(Config.get("camos").camos) do
	if camo.requires then reachableCamos = false end
end
check(reachableCamos, "release camos do not require unavailable course medals")

--[[
	Spawns per field.

	This used to demand one authored spawn per bot. Speedball cannot have that:
	twelve spawn points were tried twice and both arrangements measurably damaged
	the field -- one inverted how it punishes trading, the other flattened the top
	of the difficulty curve. It fields twelve from six and MatchService fans the
	reuses onto a small ring instead of stacking bodies.

	So the invariant is what actually has to hold: enough spawns to open a round
	without the fan-out spiralling, checked as "no more than two bots to a spawn".
	That the fan-out really does separate them is asserted in run-live-checks,
	which measures the positions MatchService produced.
]]
local RoundSchedule = env.require(env.Server.Match.RoundSchedule)
local squad = Config.require("match", "squadSize")
local spawnProblems: { string } = {}
for _, mapName in ipairs(Config.mapNames()) do
	local spawns = #Config.map(mapName).botSpawns
	if spawns < 6 then
		table.insert(spawnProblems, `{mapName} has only {spawns} spawns`)
	elseif squad > spawns * 2 then
		table.insert(spawnProblems, `{mapName} would put {math.ceil(squad / spawns)} bots on a spawn`)
	end
end
for _, problem in ipairs(spawnProblems) do print(`          {problem}`) end
check(#spawnProblems == 0, "every field has enough authored spawns for the squad it fields")

local reachableCampaign = true
for _, chapter in ipairs(Config.get("progression").chapters) do
	local kind = chapter.goal.kind
	if kind ~= "clearGauntlet" and kind ~= "clearGauntletAll" and kind ~= "flawlessGauntletAll" then
		reachableCampaign = false
	end
end
check(reachableCampaign, "release campaign requires only playable Gauntlet achievements")

local Commerce = env.require(env.Server.Economy.Commerce)
local Pricing = env.require(env.Shared.CommerceCatalog)
local commerceProblems = Commerce.audit()
for _, problem in ipairs(commerceProblems) do print(`          {problem}`) end
check(#commerceProblems == 0, "commerce IDs, cosmetic grants and disabled features pass audit")
check(fs.isFile("src/ServerScriptService/Vendor/ProfileStore.luau"), "pinned persistence dependency is included")
if Pricing.isFree() then
	check(Pricing.config().paidEnabled == false, "free mode has paid prompts explicitly disabled")
	local zero = true
	for _, product in pairs(Config.require("economy", "shop.robux.products")) do
		if product.robux ~= 0 then zero = false end
	end
	check(zero, "legacy Robux display prices are zero")
end

--[[
	The season track, checked as data.

	Three ways a battle pass becomes pay-to-win, all of them one edit away:

	  * a reward in a category that carries stats -- markers, pods, pads
	  * a reward that IS cosmetic but whose id also exists in gear.json with a
	    multiplier that is not 1, because jerseys share a namespace between
	    colour and sprint speed
	  * an offer that grants currency instead of an item, since Field Fees buy
	    the electronic marker and its 780rpm against the starting 350

	None of these is visible in review of the data alone, so none is trusted to
	it.
]]
do
	local Season = env.require(env.Shared.Season)
	local SeasonPass = env.require(env.Server.Progression.SeasonPass)
	local seasons = Config.get("seasons")
	local allowed = SeasonPass.allowedCategories()
	local cosmetics = Config.require("economy", "shop.cosmetics")
	local gear = Config.get("gear")

	local function statBearing(category: string, id: string): boolean
		for _, group in pairs(gear) do
			if type(group) == "table" then
				for name, slot in pairs(group) do
					if name == category and type(slot) == "table" and type(slot.items) == "table" then
						local entry = slot.items[id]
						if type(entry) == "table" then
							for key, value in pairs(entry) do
								if string.find(key, "Multiplier") and value ~= 1 then
									return true
								end
							end
						end
					end
				end
			end
		end
		return false
	end

	local rewardProblems = 0
	local rewardCount = 0
	for index, tier in ipairs(seasons.tiers) do
		for _, column in ipairs({ "free", "paid" }) do
			local reward = tier[column]
			if reward then
				rewardCount += 1
				if not allowed[reward.category] then
					print(`          tier {index} {column}: '{reward.category}' is not a colour-only category`)
					rewardProblems += 1
				elseif not (cosmetics[reward.category] and cosmetics[reward.category][reward.id]) then
					print(`          tier {index} {column}: unknown cosmetic '{reward.category}/{reward.id}'`)
					rewardProblems += 1
				elseif statBearing(reward.category, reward.id) then
					print(`          tier {index} {column}: '{reward.id}' carries a gear multiplier`)
					rewardProblems += 1
				end
			end
		end
	end
	check(rewardProblems == 0, `all {rewardCount} season rewards are cosmetic and carry no stats`)

	-- Marks must be reachable: a track whose last tier cannot be hit is a lie.
	local best = Season.marksFor({ eliminations = 40, cleared = true, deaths = 0, tier = "pro" }, seasons.scoring)
	check(best > 0 and seasons.tiers[#seasons.tiers].marks / best < 40,
		`the last tier is reachable ({math.ceil(seasons.tiers[#seasons.tiers].marks / best)} flawless pro clears)`)

	local currencyGrant = false
	for id, offer in pairs(Pricing.config().offers) do
		for category in pairs(offer.grants or {}) do
			if category == "currency" or category == "fieldFees" then
				print(`          offer '{id}' grants currency`)
				currencyGrant = true
			end
		end
	end
	check(not currencyGrant, "no commerce offer grants currency that could buy a marker")
end

-- The monetization rule, checked as data rather than trusted to review.
local attachments = Config.get("markers").attachments
local payToWin = false
for _, group in ipairs({ "barrels", "hoppers", "tanks" }) do
	for id, entry in pairs(attachments[group]) do
		if (entry.spreadMultiplier or 1) ~= 1 or (entry.velocityMultiplier or 1) > 1.05 then
			print(`          '{id}' affects accuracy`)
			payToWin = true
		end
	end
end
check(not payToWin, "no purchasable attachment improves accuracy")

--[[
	The axes that must stay inert, asserted against the source that would read
	them.

	The tolerance above accepts small authored velocity differences that nothing
	consumes. That was safe while NOTHING consumed any attachment stat; now that
	`Shared/Loadout` resolves the equipped kit into numbers the match actually
	runs on, "authored but unread" has to be a checked property rather than a
	fact about the day it was written. A flatter, more consistent arc is less
	lead to work out, which is substituting for aim.

	Read from the source of the one function that resolves a loadout, because
	that is the only place these could reach gameplay from.
]]
do
	local fs = require("@lune/fs")
	local source = fs.readFile("src/ReplicatedStorage/Shared/Loadout.luau")
	--- Strip comments first: this file NAMES these axes to explain why it does
	--- not read them, and a bare search would match the explanation.
	local code = source:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
	local forbidden = { "spreadMultiplier", "velocityMultiplier", "velocityConsistency" }
	local consumed = {}
	for _, field in ipairs(forbidden) do
		if string.find(code, field, 1, true) then
			table.insert(consumed, field)
		end
	end
	if #consumed > 0 then
		print(`          Loadout.resolve reads {table.concat(consumed, ", ")}`)
	end
	check(#consumed == 0, "no purchasable attachment reaches spread or velocity")
end

local robuxClean = true
for id, product in pairs(Config.require("economy", "shop.robux.products")) do
	if product.affectsAccuracy ~= false or product.grants.markers or product.grants.barrels then
		print(`          robux product '{id}' is not cosmetic-only`)
		robuxClean = false
	end
end
check(robuxClean, "every Robux product is cosmetic or convenience only")

-- Protective and Paint & Air stock, audited by field name. This is the check
-- that catches a damageReduction or a spreadMultiplier being added to gear.json.
local gearViolations = GearStats.audit()
for _, violation in ipairs(gearViolations) do
	print(`          {violation}`)
end
check(#gearViolations == 0, "no gear item declares a disallowed stat")

-- Single-use kit, audited by field name. This is where a damage term or a
-- full-map reveal on the drone would be caught.
check(Config.get("consumables").liveEnabled == false, "unintegrated field kit remains preview-only")

--[[
	The counter and the flag have to agree, in both directions.

	Field kit used to be listed in the barn's paint-and-air bay AND rendered in
	the shop as eight rows of "PREVIEW / Coming later" -- a whole tab of things
	the player cannot have, on the screen where they decide to spend money.
	Hiding the rows alone was not enough: the physical counter still advertised
	the category, which is a bay the player walks up to and finds empty, and
	Overworld.spec caught exactly that.

	So the bay listing is the switch's other half. Turning the flag on without
	restocking the counter would ship a purchasable item nobody can reach, and
	turning it off without unlisting it empties a counter. Both fail here.
]]
do
	local kitLive = Config.get("consumables").liveEnabled == true
	local stocked = false
	for _, bay in ipairs(Config.get("overworld").barn.bays) do
		for _, category in ipairs(bay.categories) do
			if category == "consumables" then
				stocked = true
			end
		end
	end
	check(stocked == kitLive,
		if kitLive
			then "field kit is live and a barn counter stocks it"
			else "field kit is off and no barn counter advertises it")
end
local kitViolations = Consumables.audit()
for _, violation in ipairs(kitViolations) do
	print(`          {violation}`)
end
check(#kitViolations == 0, "no consumable declares a disallowed stat")

-- Red and gold kit must never be buyable at any price.
local buyableTopTier = false
for _, id in ipairs(Consumables.order()) do
	local item = Consumables.item(id)
	if (item.tier == "red" or item.tier == "gold") and Consumables.isPurchasable(id) then
		print(`          '{id}' is {item.tier} tier and purchasable`)
		buyableTopTier = true
	end
end
check(not buyableTopTier, "red and gold kit drops rather than being sold")

-- Broken dialogue is invisible until someone walks up to the wrong npc.
local dialogueProblems = DialogueTree.validate()
for _, problem in ipairs(dialogueProblems) do
	print(`          {problem}`)
end
check(#dialogueProblems == 0, "the dialogue bank is structurally sound")

check(Config.require("range", "payout") == 0, "the Range pays nothing")
check(Config.require("economy", "basePayout.range") == 0, "the Range has no base payout")

print("")
if #problems > 0 then
	print(`\27[31m{#problems} blocker(s) before publishing.\27[0m`)
	process.exit(1)
end
print("\27[32mconfiguration checks passed; live service and Studio playtests are separate.\27[0m")
