--!strict
-- Persistent rewards from the server match result; kept outside the simulation.
local RS = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local Profile = require(Server.Economy.Profile)
local SeasonPass = require(Server.Progression.SeasonPass)
local Campaign = require(Server.Progression.Campaign)
local Remotes = require(RS.Net.Remotes)
local Log = require(RS.Shared.Log)
local log = Log.scope("LiveRound.Match")
local MatchProgress = {}

function MatchProgress.record(handle: any, player: Player, summary: any, breakdown: any, mapName: string, tier: string, deaths: number, isGauntlet: boolean, grantGear: (any, string) -> ())
	if handle:isActive() then
		Profile.recordMatch(handle, summary)

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
			Remotes.event("LoadoutChanged"):FireClient(player, handle.data.loadout)
		end

		--[[
			Record the clear against the campaign, then see which chapters
			that just finished. Written server-side off numbers the server
			counted -- a chapter is never completed because a client said so.
		]]
		-- A course clear is emphatically NOT a gauntlet clear: the campaign
		-- chapters gate on five rounds against a squad, not on a timed run.
		if breakdown.cleared and isGauntlet then
			handle.data.gauntletClears = handle.data.gauntletClears or {}
			local byTier = handle.data.gauntletClears[mapName] or {}
			local previous = byTier[tier]
			if previous == nil or deaths < previous then
				byTier[tier] = deaths
			end
			handle.data.gauntletClears[mapName] = byTier
		end

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
