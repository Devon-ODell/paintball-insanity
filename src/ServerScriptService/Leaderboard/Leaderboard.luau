--!strict
--[[
	Leaderboard -- fastest full clears of a map.

	A "time" here means one specific thing: all five rounds of a map cleared in a
	single match, timed by the server's own round clock. A partial clear is not a
	time and never reaches the board.

	Two stores, because OrderedDataStore only holds numbers:

	    LiveRoundTimes_v2_<map>   OrderedDataStore, value = centiseconds
	    LiveRoundTimeMeta_v2      DataStore, the tier/deaths/marker for a run

	The validation and formatting halves are pure and unit-tested. The DataStore
	halves are thin and are the only part that needs a live server.

	Dev runs write to a separate set of keys. Testing with infinite money and
	skipped rounds must never be able to touch the real board -- a leaderboard is
	the one place in this game where a bad number is permanent.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)
local Dev = require(ReplicatedStorage.Shared.Dev)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.scope("LiveRound.Leaderboard")

local Leaderboard = {}

export type Submission = {
	userId: number,
	displayName: string,
	map: string,
	tier: Types.BotTier,
	marker: string,
	--- Total seconds across all five rounds, from the server's round clock.
	seconds: number,
	--- Which mode produced this time. Boards are per map AND per mode: a
	--- Shoothouse run is 28 defenders and a gauntlet is 40 over five rounds, so
	--- ranking them against each other would let a course time erase a gauntlet
	--- personal best on the same field. Absent means gauntlet, which is what
	--- every stored time was before the Shoothouse existed.
	mode: string?,
	deaths: number,
	eliminations: number,
	roundsCleared: number,
	roundsPlayed: number,
	--[[
		Waves survived, on a board that ranks on depth rather than time.

		Horde never finishes, so `breakdown.cleared` is always false and the
		submission was gated on it -- the declared wave leaderboard never wrote a
		single row in its life. A depth is not a time and cannot share a board
		with one: bigger is better, and the five-round validation below describes
		a gauntlet.
	]]
	depth: number?,
}

export type Entry = {
	rank: number,
	userId: number,
	displayName: string,
	seconds: number,
	--- Waves survived, on a depth board. Absent on a time board.
	depth: number?,
	tier: Types.BotTier?,
	marker: string?,
	deaths: number?,
}

--------------------------------------------------------------------------------
-- Pure: validation
--------------------------------------------------------------------------------

--[[
	Is this run allowed onto the board?

	Returns ok plus a reason when it is not. Every rejection is a reason string
	rather than a silent false, because the only way to find out that a legitimate
	run was being refused is to have logged why.
]]
--- How a mode's board is ranked. Absent means a time board, which is what every
--- stored row was before there was more than one mode.
function Leaderboard.boardRules(mode: string?): any
	local boards = Config.get("leaderboard").boards or {}
	return boards[mode or "gauntlet"] or { rankBy = "time", ascending = true }
end

function Leaderboard.validate(submission: Submission, expectedEliminations: number): (boolean, string?)
	local rules = Config.require("leaderboard", "validation")

	--[[
		A depth board has its own rules, because the time board's cannot apply.

		"All rounds cleared" is meaningless in a mode with no last round, and
		"eliminations match the schedule" is meaningless when the schedule is
		written one wave at a time as the player survives them. What IS checkable
		is that the depth is a real, positive, whole number of waves that were
		actually played.
	]]
	if Leaderboard.boardRules(submission.mode).rankBy == "depth" then
		local depth = submission.depth
		if type(depth) ~= "number" or depth ~= depth then
			return false, "depth is not a number"
		end
		if depth <= 0 then
			return false, "no waves were survived"
		end
		if depth ~= math.floor(depth) then
			return false, "depth is not a whole number of waves"
		end
		if depth > submission.roundsPlayed then
			return false, `survived {depth} of {submission.roundsPlayed} waves played`
		end
		return true, nil
	end

	if rules.requireAllRoundsCleared and submission.roundsCleared < submission.roundsPlayed then
		return false, `only cleared {submission.roundsCleared} of {submission.roundsPlayed} rounds`
	end
	if submission.roundsPlayed <= 0 then
		return false, "no rounds were played"
	end

	if rules.requireEliminationsToMatchSchedule and submission.eliminations ~= expectedEliminations then
		return false, `eliminated {submission.eliminations}, expected {expectedEliminations}`
	end

	local floor = rules.minimumSecondsPerRound * submission.roundsPlayed
	if submission.seconds < floor then
		return false, `{string.format("%.1f", submission.seconds)}s is below the {floor}s floor`
	end
	if submission.seconds > rules.maximumSecondsTotal then
		return false, "over the maximum recordable time"
	end
	if submission.seconds ~= submission.seconds then
		return false, "time is not a number"
	end

	return true, nil
end

--- Seconds to the integer the OrderedDataStore actually sorts on. Centiseconds
--- keeps a hundredth of a second of resolution and stays well inside the
--- 64-bit signed range OrderedDataStore requires.
function Leaderboard.toCentiseconds(seconds: number): number
	return math.floor(seconds * 100 + 0.5)
end

function Leaderboard.fromCentiseconds(value: number): number
	return value / 100
end

--- "4:07.32". Times are read at a glance off a board in the woods, so the
--- format has to be legible from further away than a raw seconds count.
function Leaderboard.formatTime(seconds: number): string
	if seconds ~= seconds or seconds < 0 then
		return "--:--"
	end
	local minutes = math.floor(seconds / 60)
	local remainder = seconds - minutes * 60
	return string.format("%d:%05.2f", minutes, remainder)
end

--- Sorts submissions ascending by time and assigns ranks. Ties keep the run
--- with fewer deaths ahead, which is the tiebreak the rest of the game uses.
function Leaderboard.rank(entries: { any }): { Entry }
	local sorted = table.clone(entries)
	--- A depth board ranks on waves, deepest first. Ties go to the run that
	--- spent fewer respawns getting there, which is the same tiebreak a time
	--- board uses and the same rule the whole game is balanced on.
	local byDepth = #sorted > 0 and sorted[1].depth ~= nil
	table.sort(sorted, function(a, b)
		if byDepth then
			if (a.depth or 0) ~= (b.depth or 0) then
				return (a.depth or 0) > (b.depth or 0)
			end
			return (a.deaths or 0) < (b.deaths or 0)
		end
		if math.abs(a.seconds - b.seconds) > 1e-9 then
			return a.seconds < b.seconds
		end
		return (a.deaths or 0) < (b.deaths or 0)
	end)

	local out: { Entry } = {}
	for i, entry in ipairs(sorted) do
		out[i] = {
			rank = i,
			userId = entry.userId,
			displayName = entry.displayName,
			seconds = entry.seconds,
			depth = entry.depth,
			tier = entry.tier,
			marker = entry.marker,
			deaths = entry.deaths,
		}
	end
	return out
end

--------------------------------------------------------------------------------
-- Store access
--------------------------------------------------------------------------------

local readFailed: { [string]: boolean } = {}
local timesStores: { [string]: OrderedDataStore } = {}
local metaStore: DataStore? = nil

--- Dev runs are quarantined onto their own keys.
local function suffix(): string
	if Dev.isEnabled() then
		return Config.require("leaderboard", "store.devSuffix")
	end
	return ""
end

local function timesFor(map: string, mode: string?): OrderedDataStore
	--[[
		Gauntlet keeps the bare map key it has always had, so no stored time is
		orphaned by this change. Every other mode gets its own board.
	]]
	local scope = if mode == nil or mode == "gauntlet" then map else `{map}_{mode}`
	local key = scope .. suffix()
	local existing = timesStores[key]
	if existing then
		return existing
	end
	local prefix = Config.require("leaderboard", "store.timesPrefix")
	local store = DataStoreService:GetOrderedDataStore(prefix .. key)
	timesStores[key] = store
	return store
end

--[[
	The metadata key for one player's row on one board.

	Gauntlet keeps the bare `{map}_{userId}` key it has always had, so no stored
	decoration is orphaned; every other mode gets its own, which is what stops a
	course best from overwriting a gauntlet best's tier and marker.
]]
function Leaderboard.metaKey(map: string, mode: string?, userId: number): string
	if mode == nil or mode == "gauntlet" then
		return `{map}_{userId}`
	end
	return `{map}_{mode}_{userId}`
end

local function meta(): DataStore
	if metaStore then
		return metaStore :: DataStore
	end
	local name = Config.require("leaderboard", "store.metaStore") .. suffix()
	metaStore = DataStoreService:GetDataStore(name)
	return metaStore :: DataStore
end

--------------------------------------------------------------------------------

--[[
	Submits a run, if it is faster than that player's existing best.

	Returns whether it was written and why not if it was not. Writing only on an
	improvement keeps the DataStore call count proportional to personal records
	rather than to matches played, which matters on a game where a session is
	dozens of matches.
]]
function Leaderboard.submit(submission: Submission, expectedEliminations: number): (boolean, string?)
	local ok, reason = Leaderboard.validate(submission, expectedEliminations)
	if not ok then
		log.info(`rejected {submission.displayName} on {submission.map}: {reason}`)
		return false, reason
	end

	if Dev.isEnabled() then
		log.warn(`dev mode: {submission.map} time written to the quarantined board only`)
	end

	--[[
		What this board stores, and which direction is better.

		A time board keeps centiseconds and small wins. A depth board keeps
		whole waves and BIG wins, so the improvement test flips -- writing the
		time comparison against a depth would have kept the shallowest run
		anybody ever managed.
	]]
	local board = Leaderboard.boardRules(submission.mode)
	local depthBoard = board.rankBy == "depth"
	local value = if depthBoard
		then math.floor(submission.depth :: number)
		else Leaderboard.toCentiseconds(submission.seconds)
	local key = tostring(submission.userId)

	local wrote = false
	local success, err = pcall(function()
		timesFor(submission.map, submission.mode):UpdateAsync(key, function(existing: number?)
			if existing then
				local better = if depthBoard then value > existing else value < existing
				if not better then
					return nil
				end
			end
			wrote = true
			return value
		end)
	end)
	if not success then
		log.warn(`times store write failed for {submission.map}: {err}`)
		return false, "datastore error"
	end

	if not wrote then
		return false, "not a personal best"
	end

	--[[
		Metadata is per BOARD, not per map.

		The times themselves were already separated by mode -- `timesFor` scopes
		the store by `{map}_{mode}` -- but the decoration next to each name was
		keyed on `{map}_{userId}` alone. So a Shoothouse personal best
		overwrote the tier, marker and out count shown against that player's
		gauntlet time on the same field, and vice versa: two boards, one row of
		metadata, whichever mode posted last.
	]]
	local metaSuccess, metaErr = pcall(function()
		meta():SetAsync(Leaderboard.metaKey(submission.map, submission.mode, submission.userId), {
			displayName = submission.displayName,
			tier = submission.tier,
			marker = submission.marker,
			deaths = submission.deaths,
			seconds = submission.seconds,
			depth = submission.depth,
			at = os.time(),
		})
	end)
	if not metaSuccess then
		-- The time itself landed; only the decoration is missing, so the run
		-- still counts and the board just shows less about it.
		log.warn(`meta store write failed for {submission.map}: {metaErr}`)
	end

	if depthBoard then
		log.info(`{submission.displayName} reached wave {value} on {submission.map}`)
	else
		log.info(`{submission.displayName} set {Leaderboard.formatTime(submission.seconds)} on {submission.map}`)
	end
	return true, nil
end

--- The top N for a map, newest data fetched fresh. Returns an empty list rather
--- than erroring when the store is unreachable, so a DataStore outage makes the
--- board go blank instead of taking the server down.
--- `mode` defaults to gauntlet, which is the board every caller wanted before
--- there was more than one.
function Leaderboard.top(map: string, count: number?, mode: string?): { Entry }
	local limit = count or Config.require("leaderboard", "display.topCount")

	--- Ascending on a time board, where small is good; descending on a depth
	--- board, where the deepest run is the one anybody wants to see.
	local board = Leaderboard.boardRules(mode)
	local rows: { any } = {}
	local success, err = pcall(function()
		local pages = timesFor(map, mode):GetSortedAsync(board.ascending ~= false, limit)
		for _, row in ipairs(pages:GetCurrentPage()) do
			table.insert(rows, row)
		end
	end)
	if not success then
		--[[
			Warn once per board, then stay quiet until it works again.

			The notice board re-reads on a timer, so an outage -- or a studio
			session with no DataStore access at all -- used to write the same
			line every cycle forever. A headless run of the world builder wrote
			679MB of it before anyone noticed. A failure is worth saying; saying
			it a thousand times buries everything else in the log.
		]]
		--- Keyed per BOARD, not per map: a map has up to three of them now, and
		--- keying on the map alone let one board's success clear another's
		--- suppression flag, which put the warning back to once a cycle forever.
		local boardKey = `{map}|{mode or "gauntlet"}`
		if not readFailed[boardKey] then
			readFailed[boardKey] = true
			log.warn(`could not read the {boardKey} board: {err}`)
		end
		return {}
	else
		-- Recovered: allow the next failure to be reported.
		readFailed[`{map}|{mode or "gauntlet"}`] = nil
	end

	local depthBoard = board.rankBy == "depth"
	local entries: { any } = {}
	for _, row in ipairs(rows) do
		local detail: any = nil
		pcall(function()
			--- Per board, so a course best cannot overwrite the tier and marker
			--- shown against a gauntlet best on the same field.
			detail = meta():GetAsync(Leaderboard.metaKey(map, mode, tonumber(row.key) or 0))
		end)
		table.insert(entries, {
			userId = tonumber(row.key) or 0,
			displayName = (detail and detail.displayName) or `Player {row.key}`,
			seconds = if depthBoard then (detail and detail.seconds) or 0 else Leaderboard.fromCentiseconds(row.value),
			depth = if depthBoard then row.value else nil,
			tier = detail and detail.tier,
			marker = detail and detail.marker,
			deaths = detail and detail.deaths,
		})
	end

	return Leaderboard.rank(entries)
end

--- One player's best on a map, or nil if they have never cleared it.
function Leaderboard.personalBest(userId: number, map: string, mode: string?): number?
	local value: number? = nil
	local success = pcall(function()
		value = timesFor(map, mode):GetAsync(tostring(userId)) :: number?
	end)
	if not success or not value then
		return nil
	end
	return Leaderboard.fromCentiseconds(value :: number)
end

--- Test seam: drops cached store handles so a spec can flip dev mode and get a
--- fresh set of keys rather than the ones cached under the old mode.
function Leaderboard._resetStores()
	table.clear(timesStores)
	metaStore = nil
end

return Leaderboard
