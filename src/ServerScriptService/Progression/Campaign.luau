--!strict
--[[
	Campaign -- the linear run from a loaner marker to the Aurum Kompressor.

	Pure. Given a profile's completed-chapter list and its match history, it
	answers: which chapter is current, is this goal met, what unlocks now, and is
	horde open yet.

	Every gate is a SKILL gate -- clear this map, at this tier, this cleanly.
	Nothing is gated on time played, per BUILD_PLAN's out-of-scope list. That
	list exists because time gates are how a game stops being about the thing it
	claims to be about.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)

local Campaign = {}

export type Chapter = {
	id: string,
	index: number,
	title: string,
	subtitle: string,
	brief: string,
	closer: string,
	goal: any,
	rewards: any,
	requires: string?,
}

--- A snapshot of everything the campaign needs to judge progress.
export type Record = {
	completed: { [string]: boolean },
	--- clears[map][tier] = fewest deaths in a full five-round clear, or nil.
	clears: { [string]: { [string]: number } },
	--- Bosses beaten, by id.
	bosses: { [string]: boolean },
	--- Deepest horde wave reached.
	hordeBestWave: number,
}

function Campaign.emptyRecord(): Record
	return { completed = {}, clears = {}, bosses = {}, hordeBestWave = 0 }
end

--- Builds a Record from a profile's stored data.
function Campaign.recordFromProfile(data: any): Record
	local record = Campaign.emptyRecord()
	if type(data) ~= "table" then
		return record
	end
	for _, id in ipairs(data.chaptersCompleted or {}) do
		record.completed[id] = true
	end
	for map, byTier in pairs(data.gauntletClears or {}) do
		record.clears[map] = {}
		for tier, deaths in pairs(byTier) do
			record.clears[map][tier] = deaths
		end
	end
	for _, id in ipairs(data.bossesBeaten or {}) do
		record.bosses[id] = true
	end
	record.hordeBestWave = (data.hordeBest and data.hordeBest.wave) or 0
	return record
end

--------------------------------------------------------------------------------

function Campaign.chapters(): { Chapter }
	return Config.require("progression", "chapters")
end

function Campaign.chapter(id: string): Chapter?
	for _, chapter in ipairs(Campaign.chapters()) do
		if chapter.id == id then
			return chapter
		end
	end
	return nil
end

--------------------------------------------------------------------------------

local TIER_ORDER = { "rec", "amateur", "semipro", "pro" }

--[[
	Maps the gauntlet is actually played on.

	Not every map in the index: Holdfast exists for capture the flag and has no
	five-round gauntlet, so "clear every field" must mean every GAUNTLET field
	or the campaign would ask for something that cannot be done.
]]
function Campaign.gauntletMaps(): { string }
	return Config.require("gamemodes", "modes.gauntlet.maps")
end

--- Has the player cleared this map's gauntlet at this tier or better?
local function hasClear(record: Record, map: string, tier: string): boolean
	local byTier = record.clears[map]
	if not byTier then
		return false
	end
	local required = table.find(TIER_ORDER, tier) or 1
	for index = required, #TIER_ORDER do
		if byTier[TIER_ORDER[index]] ~= nil then
			return true
		end
	end
	return false
end

--- ...and did they do it without being marked once?
local function hasFlawless(record: Record, map: string, tier: string): boolean
	local byTier = record.clears[map]
	if not byTier then
		return false
	end
	local required = table.find(TIER_ORDER, tier) or 1
	for index = required, #TIER_ORDER do
		local deaths = byTier[TIER_ORDER[index]]
		if deaths ~= nil and deaths == 0 then
			return true
		end
	end
	return false
end

--[[
	Is a goal satisfied?

	Kinds:
	    clearGauntlet         one map, at or above a tier
	    clearGauntletAll      every map, at or above a tier
	    flawlessGauntletAll   every map, at or above a tier, no deaths
	    beatBoss              a named boss
	    surviveWaves          a horde depth
	    composite             every sub-goal in `all`
]]
function Campaign.goalMet(goal: any, record: Record): boolean
	if type(goal) ~= "table" then
		return false
	end

	if goal.kind == "clearGauntlet" then
		return hasClear(record, goal.map, goal.tier)
	elseif goal.kind == "clearGauntletAll" then
		for _, map in ipairs(Campaign.gauntletMaps()) do
			if not hasClear(record, map, goal.tier) then
				return false
			end
		end
		return true
	elseif goal.kind == "flawlessGauntletAll" then
		for _, map in ipairs(Campaign.gauntletMaps()) do
			if not hasFlawless(record, map, goal.tier) then
				return false
			end
		end
		return true
	elseif goal.kind == "beatBoss" then
		return record.bosses[goal.boss] == true
	elseif goal.kind == "surviveWaves" then
		return record.hordeBestWave >= goal.waves
	elseif goal.kind == "composite" then
		for _, sub in ipairs(goal.all or {}) do
			if not Campaign.goalMet(sub, record) then
				return false
			end
		end
		return true
	end
	return false
end

--- Human-readable progress on a goal, for the chapter card.
function Campaign.goalDescription(goal: any): string
	if goal.kind == "clearGauntlet" then
		return `Clear all five rounds of {goal.map} at {goal.tier}`
	elseif goal.kind == "clearGauntletAll" then
		return `Clear all five rounds of every field at {goal.tier}`
	elseif goal.kind == "flawlessGauntletAll" then
		return `Clear every field at {goal.tier} without being marked once`
	elseif goal.kind == "beatBoss" then
		return `Mark the hopper of {goal.boss}`
	elseif goal.kind == "surviveWaves" then
		return `Reach wave {goal.waves} in horde`
	elseif goal.kind == "composite" then
		local parts: { string } = {}
		for _, sub in ipairs(goal.all or {}) do
			table.insert(parts, Campaign.goalDescription(sub))
		end
		return table.concat(parts, ", and ")
	end
	return "?"
end

--------------------------------------------------------------------------------

--- The chapter the player is on: the first incomplete one whose prerequisite is
--- met. Returns nil when the campaign is finished.
function Campaign.current(record: Record): Chapter?
	for _, chapter in ipairs(Campaign.chapters()) do
		if record.completed[chapter.id] then
			continue
		end
		if chapter.requires == nil or record.completed[chapter.requires] then
			return chapter
		end
	end
	return nil
end

--[[
	Chapters that just became complete given this record.

	Returns them in order, so a single match that satisfies two chapters at once
	awards both -- which can happen when a flawless pro sweep completes both the
	pro chapter and part of a composite.
]]
function Campaign.newlyCompleted(record: Record): { Chapter }
	local out: { Chapter } = {}
	for _, chapter in ipairs(Campaign.chapters()) do
		if record.completed[chapter.id] then
			continue
		end
		if chapter.requires ~= nil and not record.completed[chapter.requires] then
			-- Prerequisites are strict: you cannot skip a chapter by
			-- accidentally satisfying a later one first.
			continue
		end
		if Campaign.goalMet(chapter.goal, record) then
			table.insert(out, chapter)
			record.completed[chapter.id] = true
		end
	end
	return out
end

--------------------------------------------------------------------------------

--- Everything unlocked by the chapters completed so far.
function Campaign.unlocks(record: Record): { [string]: boolean }
	local unlocked: { [string]: boolean } = {}
	for _, chapter in ipairs(Campaign.chapters()) do
		if not record.completed[chapter.id] then
			continue
		end
		for _, id in ipairs(chapter.rewards.unlocks or {}) do
			unlocked[id] = true
		end
	end

	-- Mode unlocks are declared separately so a mode can be gated on a chapter
	-- without that chapter having to list it as a reward.
	for mode, rule in pairs(Config.require("progression", "modeUnlocks")) do
		if rule.requires == nil or record.completed[rule.requires] then
			unlocked[mode] = true
		end
	end
	return unlocked
end

--- Is horde open? The one gate worth asking about by name.
function Campaign.hordeUnlocked(record: Record): boolean
	if Config.get("gamemodes").modes.horde.enabled == false then return false end
	local rule = Config.require("progression", "modeUnlocks.horde")
	return rule.requires == nil or record.completed[rule.requires] == true
end

--- Gear a chapter awards, which is how the unbuyable items reach the player.
function Campaign.gearRewards(record: Record): { string }
	local out: { string } = {}
	for _, chapter in ipairs(Campaign.chapters()) do
		if record.completed[chapter.id] then
			for _, id in ipairs(chapter.rewards.gear or {}) do
				table.insert(out, id)
			end
		end
	end
	return out
end

--- Gates select the current campaign challenge so later tiers are playable
--- without requiring a client to forge a tier in RequestMatchStart.
function Campaign.recommendedTier(record: Record): string
	local chapter = Campaign.current(record)
	return if chapter and chapter.goal.tier then chapter.goal.tier else "pro"
end

--- A card for the current chapter: what to do, and how far along you are.
function Campaign.card(record: Record): any
	local chapter = Campaign.current(record)
	if not chapter then
		return {
			complete = true,
			title = "Nothing left on the shelf",
			subtitle = "You have the marker. Go and use it.",
		}
	end
	return {
		complete = false,
		id = chapter.id,
		index = chapter.index,
		total = #Campaign.chapters(),
		title = chapter.title,
		subtitle = chapter.subtitle,
		brief = chapter.brief,
		goal = Campaign.goalDescription(chapter.goal),
		rewardCurrency = chapter.rewards.currency,
	}
end

return Campaign
