--!strict
-- Persistent rewards from the server match result; kept outside the simulation.
local RS = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local Profile = require(Server.Economy.Profile)
local SeasonPass = require(Server.Progression.SeasonPass)
local Campaign = require(Server.Progression.Campaign)
local Loadout = require(RS.Shared.Loadout)
local Remotes = require(RS.Net.Remotes)
local Log = require(RS.Shared.Log)
local log = Log.scope("LiveRound.Match")
local MatchProgress = {}

--[[
	What a horde run leaves behind.

	`Campaign.recordFromProfile` has read `hordeBest.wave` and `bossesBeaten`
	since the campaign was written, and NO production writer ever set either
	one. So The Long Afternoon's own chapter goals -- reach a depth, beat a
	marshal -- could not be met by playing it. The mode ran, the waves escalated,
	the bosses showed up, and the profile recorded that none of it had happened.

	Depth is a personal best: it only ever goes up. Bosses are a set of ids,
	because a chapter asks WHICH marshal you beat, not how many.
]]
local function recordHorde(handle: any, summary: any, breakdown: any)
	local depth = breakdown.wavesSurvived or 0
	local best = handle.data.hordeBest or {}
	handle.data.hordeBest = best
	if depth > (best.wave or 0) then
		best.wave = depth
		best.bossesBeaten = breakdown.bossesBeaten or 0
		best.marker = summary.marker
		best.map = summary.map
	end
	--- Always kept, even on a run that did not go as deep as a previous one:
	--- beating a marshal is a thing you have done, not a high score.
	local beaten = handle.data.bossesBeaten or {}
	handle.data.bossesBeaten = beaten
	for _, id in ipairs(summary.bossesBeaten or {}) do
		if not table.find(beaten, id) then
			table.insert(beaten, id)
		end
	end
end

function MatchProgress.record(handle: any, player: Player, summary: any, breakdown: any, mapName: string, tier: string, deaths: number, isGauntlet: boolean, grantGear: (any, string) -> ())
	if handle:isActive() then
		Profile.recordMatch(handle, summary)
		if breakdown.wavesSurvived ~= nil then
			recordHorde(handle, summary, breakdown)
		end

		--[[
			Season marks, off the same summary the payout used. Awarded from
			eliminations and the clear, never from time on the field -- see
			Shared/Season. Granting immediately after means a player who
			crosses a tier sees the reward on the results screen rather than
			on next join.
		]]
		SeasonPass.award(handle, summary)
		local seasonRewards = SeasonPass.grantDue(handle)
		if #seasonRewards > 0 then
			Remotes.event("LoadoutChanged"):FireClient(player, handle.data.loadout, Loadout.resolve(handle.data))
		end

		--[[
			Record the clear against the campaign, then see which chapters
			that just finished. Written server-side off numbers the server
			counted -- a chapter is never completed because a client said so.
		]]
		--[[
			A course clear is emphatically NOT a gauntlet clear: the campaign
			chapters gate on five rounds against a squad, not on a timed run.

			The write itself moved into `Profile.recordMatch`, called above,
			because `gauntletClears` is also what decides whether the next field
			is open -- and an authority with two writers is two authorities. It
			was written here off `isGauntlet` and read by `hasUnlocked` from a
			DIFFERENT field, which is how a Shoothouse run came to open a map.
		]]
		local record = Campaign.recordFromProfile(handle.data)
		local finished = Campaign.newlyCompleted(record)
		if #finished > 0 then
			handle.data.chaptersCompleted = handle.data.chaptersCompleted or {}
			for _, chapter in ipairs(finished) do
				table.insert(handle.data.chaptersCompleted, chapter.id)
				if chapter.rewards.currency and chapter.rewards.currency > 0 then
					Profile.credit(handle, chapter.rewards.currency, `chapter {chapter.id}`)
				end
				--[[
					Chapter gear is how the unbuyable items reach the player.
					Nothing here is for sale at any price.
				]]
				for _, id in ipairs(chapter.rewards.gear or {}) do
					grantGear(handle, id)
				end
				log.info(`{player.Name} completed chapter {chapter.id}`)
			end
			Remotes.event("CurrencyChanged"):FireClient(player, handle.data.currency)
			Remotes.event("CampaignUpdated"):FireClient(
				player,
				Campaign.card(Campaign.recordFromProfile(handle.data))
			)
		end
	end
end

return MatchProgress
