--!strict
--[[
	Season -- the pass track, as pure arithmetic.

	No Roblox, no player, no profile. Given a record and the season data it
	answers three questions: how many marks a match was worth, what tier that
	puts you on, and which rewards you are owed but have not been given. The
	server does the granting; this decides what is owed.

	WHY MARKS ARE NOT TIME

	Every battle pass has to decide what it rewards, and most reward hours. This
	game cannot: it is an aim trainer wearing a paintball costume, and its stated
	rule is that death costs no progress -- it costs payout. A track that paid
	out for showing up would argue with the entire design, and the player would
	feel it.

	So marks come from the things the game already treats as evidence of skill:
	bots eliminated, rounds cleared, and the tier they were cleared at. A pro
	clear is worth several rec clears because it is several rec clears.

	Deaths do not subtract. That is deliberate and it is the same rule the payout
	curve follows -- dying costs you the flawless bonus and nothing else. Taking
	marks away for dying would make the pass punish the exact experimentation the
	game is built to encourage.

	NOTHING HERE GRANTS CURRENCY

	Field Fees buy markers, and the electronic marker fires at 780 rpm against
	the starting marker's 350. A track that paid out Field Fees would therefore
	be a way to buy rate of fire with real money, one laundering step removed.
	Rewards are cosmetic ids only, and `tools/ship-check` refuses a commerce
	offer that grants currency so this cannot be reintroduced by editing data.
]]

local Season = {}

export type Reward = {
	--- Cosmetic category: jerseys, masks, paintColors, markerSkins.
	category: string,
	id: string,
}

export type Tier = {
	--- Cumulative marks needed to reach this tier.
	marks: number,
	--- Given to everyone who reaches the tier.
	free: Reward?,
	--- Given only to a player who owns the season pass.
	paid: Reward?,
}

export type Record = {
	--- Which season these marks belong to. A different id means a new season.
	id: string,
	marks: number,
	--- Tiers already granted, by index, so a grant never repeats.
	claimed: { [string]: boolean },
}

export type Summary = {
	eliminations: number?,
	cleared: boolean?,
	deaths: number?,
	tier: string?,
}

--- A fresh record for `seasonId`, with nothing earned.
function Season.emptyRecord(seasonId: string): Record
	return { id = seasonId, marks = 0, claimed = {} }
end

--[[
	The record to use for this season.

	A record from a previous season is replaced rather than migrated: marks do
	not carry over. Cosmetics already granted are untouched -- they live in the
	player's inventory, not here, so a new season cannot take back a jersey.
]]
function Season.recordFor(existing: Record?, seasonId: string): Record
	if existing and existing.id == seasonId then
		return existing
	end
	return Season.emptyRecord(seasonId)
end

--[[
	What a finished match was worth.

	`scoring.tierMultiplier` is the season's own table rather than the payout
	curve's, so tuning the pass cannot silently retune the economy.
]]
function Season.marksFor(summary: Summary, scoring: any): number
	local eliminations = math.max(summary.eliminations or 0, 0)
	local marks = eliminations * scoring.perElimination

	if summary.cleared == true then
		local multiplier = scoring.tierMultiplier[summary.tier or "rec"] or 1
		marks += scoring.clearBonus * multiplier
		-- Flawless is the only place deaths appear. They never subtract.
		if (summary.deaths or 0) == 0 then
			marks += scoring.flawlessBonus
		end
	end

	return math.floor(marks)
end

--- Highest tier index reached at `marks`. Zero means no tier yet.
function Season.tierFor(marks: number, tiers: { Tier }): number
	local reached = 0
	for index, tier in ipairs(tiers) do
		if marks >= tier.marks then
			reached = index
		else
			break
		end
	end
	return reached
end

--- Marks still needed for the next tier, or nil at the end of the track.
function Season.toNextTier(marks: number, tiers: { Tier }): number?
	local next_ = tiers[Season.tierFor(marks, tiers) + 1]
	return if next_ then math.max(next_.marks - marks, 0) else nil
end

--[[
	Rewards earned but not yet granted.

	`ownsPass` decides whether the paid column is included. A player who buys the
	pass halfway through a season is owed every paid reward up to the tier they
	have already reached -- that is what makes buying it mid-season honest rather
	than a punishment for not having bought it on day one.

	Claim keys carry the column, so the free reward of a tier can be granted
	while the paid one is still owed.
]]
function Season.rewardsDue(record: Record, tiers: { Tier }, ownsPass: boolean): { Reward }
	local due: { Reward } = {}
	local reached = Season.tierFor(record.marks, tiers)
	for index = 1, reached do
		local tier = tiers[index]
		if tier.free and not record.claimed[`{index}:free`] then
			table.insert(due, tier.free)
		end
		if ownsPass and tier.paid and not record.claimed[`{index}:paid`] then
			table.insert(due, tier.paid)
		end
	end
	return due
end

--- Marks every reward `rewardsDue` just returned as granted.
function Season.markClaimed(record: Record, tiers: { Tier }, ownsPass: boolean)
	local reached = Season.tierFor(record.marks, tiers)
	for index = 1, reached do
		local tier = tiers[index]
		if tier.free then
			record.claimed[`{index}:free`] = true
		end
		if ownsPass and tier.paid then
			record.claimed[`{index}:paid`] = true
		end
	end
end

return Season
