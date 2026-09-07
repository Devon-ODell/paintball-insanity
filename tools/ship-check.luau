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
