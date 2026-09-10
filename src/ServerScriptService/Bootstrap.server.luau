--!strict
--[[
	Server entry. Everything else in this tree is a ModuleScript; without this
	file a player joins a place that has no remotes, no profile, and no match.

	Solo PvE: one player, start Speedball/rec immediately. No lobby.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loadout = require(ReplicatedStorage.Shared.Loadout)
local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Net.Remotes)

local Server = script.Parent
local FlagMatch = require(script.Parent.Match.FlagMatch)
local MatchService = require(Server.Match.MatchService)
local Course = require(Server.Match.Course)
local CourseProgress = require(Server.Progression.CourseProgress)
local Profile = require(Server.Economy.Profile)
local Shop = require(Server.Economy.Shop)
local Commerce = require(Server.Economy.Commerce)
local SeasonPass = require(Server.Progression.SeasonPass)
local Activity = require(Server.World.Activity)
local Hub = require(Server.World.Hub)
local RangeService = require(Server.Range.RangeService)
local DialogueService = require(Server.Dialogue.DialogueService)
local Campaign = require(Server.Progression.Campaign)
local Dev = require(ReplicatedStorage.Shared.Dev)

local log = Log.scope("LiveRound.Boot")
local demo = ReplicatedStorage:FindFirstChild("DemoMode")
if demo and (demo :: BoolValue).Value and not game:GetService("RunService"):IsStudio() then
	error("This demo uses temporary progress and runs only in Roblox Studio.")
end
local starting: { [Player]: boolean } = {}
local startDrill: (Player, string?) -> boolean
local offerDrills: (Player) -> ()
--[[
	The lease each player currently holds on the world at the origin.

	Kept here rather than only inside Activity because the delayed return
	callback needs to ask "is the lease I was fired for still the current one",
	and that question cannot be answered by re-reading mutable service state --
	which is exactly what `returnTokens` was doing, and why a REJECTED replay
	request could invalidate a pending automatic return: the token incremented
	before the mode was validated.
]]
local leases: { [Player]: Activity.Lease } = {}

--[[
	Puts a player back in The Landing, having first taken down whatever was
	standing at the origin.

	The order is the entire point. `Hub.restore` and `Hub.placePlayer` rebuild
	the hub at the world origin, and a finished match's map root and a finished
	drill's range are both still there until something disposes of them. This is
	the one place that transition happens.
]]
local function returnToHub(player: Player, at: Vector3?, keepResults: boolean?)
	local lease = leases[player]
	if lease then
		leases[player] = nil
		Activity.release(lease)
	end
	MatchService.disposeVenue(player)
	--[[
		The Landing comes back only when the origin is genuinely idle.

		A second player finishing while the first is still on a field would
		otherwise restore the hub into that field. They get put back in the hub
		when the world is theirs to have; until then they are told, not moved.
	]]
	if Activity.isHeld() then
		local holder = select(1, Activity.holder())
		Remotes.event("MatchStateChanged"):FireClient(player, {
			phase = "hub",
			notice = if holder
				then `{holder.DisplayName} is still on the field. Hold tight.`
				else "The field is still coming down.",
		})
		return
	end
	Hub.placePlayer(player, at, keepResults)
	Hub.refreshBoard()
end

Remotes.init()
Dev.announce()
Profile.init()
Shop.assertNoPayToWin()
MatchService.bindLatencyReporting()
RangeService.bind()
local commerce = Commerce.new()
commerce:bind()

local DEFAULT_MAP = Config.mapNames()[1]
local requestMatch: (Player, any) -> any

--[[
	The Landing. Built once, up front, and never torn down -- it is the game's
	home, not a menu. Players spawn into it, walk to a gate to play, and come
	back to it when a match ends.
]]
-- Forward-declared: DialogueService.onAction below is defined before the shop
-- helper but calls it at run time.
local bayCatalogue

Hub.profileFor = function(player: Player)
	return Profile.load(player.UserId)
end
Hub.build()

--------------------------------------------------------------------------------
-- Conversations and the campaign
--------------------------------------------------------------------------------

DialogueService.profileFor = function(player: Player)
	return Profile.load(player.UserId)
end

--[[
	Every action a dialogue option can fire. DialogueTree.actions() lists what
	the bank uses and CampaignSpec asserts this table covers all of them, so
	adding a line with a new action fails a test rather than silently doing
	nothing when someone presses it.
]]
DialogueService.onAction = function(player: Player, action: string, arg: string?)
	local handle = Profile.load(player.UserId)
	if not handle then
		return
	end

	if action == "openShop" then
		local categories: { string } = {}
		for _, bay in ipairs(Config.require("overworld", "barn.bays")) do
			if bay.id == arg then
				categories = bay.categories
			end
		end
		Remotes.event("ShopOpened"):FireClient(player, bayCatalogue(player, arg, categories))

	elseif action == "acceptChapter" then
		local card = Campaign.card(Campaign.recordFromProfile(handle.data))
		Remotes.event("CampaignUpdated"):FireClient(player, card)

	elseif action == "claimAurum" then
		--[[
			The end of the campaign. Granted server-side off the campaign record,
			never off the client asking -- this is the single most valuable thing
			in the game and the only path to it is the goal actually being met.
		]]
		local record = Campaign.recordFromProfile(handle.data)
		local chapter = Campaign.chapter("aurum")
		if chapter and Campaign.goalMet(chapter.goal, record) then
			if not table.find(handle.data.ownedMarkers, "aurumKompressor") then
				table.insert(handle.data.ownedMarkers, "aurumKompressor")
			end
			handle.data.loadout.marker = "aurumKompressor"
			Remotes.event("LoadoutChanged"):FireClient(player, handle.data.loadout, Loadout.resolve(handle.data))
			log.info(`{player.Name} claimed the Aurum Kompressor`)
		else
			log.warn(`{player.Name} asked for the Aurum without meeting the goal`)
		end

	elseif action == "startHorde" then
		--[[
			The Long Afternoon.

			This branch used to refuse -- and refuse SILENTLY to anyone who had
			not unlocked it, because the message sat inside the unlock check, so
			the one route to the mode said nothing at all to the players it was
			gated against. Both halves are answered now: it starts the run for
			anyone who has swept the pro circuit, and tells everyone else what
			they are missing.
		]]
		--[[
			The gate is `requestMatch`, not a second copy of it here.

			This branch checked `Campaign.hordeUnlocked` and the public remote
			did not, so the NPC was stricter than the wire -- which is the wrong
			way round. It also threw away the result, so a busy field or any
			other refusal closed the dialogue in silence.
		]]
		local result = requestMatch(player, { map = DEFAULT_MAP, tier = DEFAULT_TIER, mode = "horde" })
		if not result.ok then
			Remotes.event("MatchStateChanged"):FireClient(player, {
				phase = "hub", notice = result.reason,
			})
		end

	elseif action == "startDrill" then
		--[[
			"Set it up." The coach has just named the fundamental you are worst
			at; this puts you on the drill for it.

			The Range is live -- RangeService runs it and the hub gate has
			started drills for a while -- but this branch still refused, so the
			one NPC whose entire job is to send you to the Range was the one
			route that could not. Falls back to the first drill when the profile
			has no diagnosis yet, which is the same thing walking to the gate
			does.
		]]
		local coaching = handle.data.coaching
		local wanted = coaching and coaching.drill
		startDrill(player, if wanted ~= nil and wanted ~= "" then wanted else nil)

	elseif action == "recommendDrill" or action == "readPrescription" then
		-- The diagnosis itself is substituted into the line through the
		-- `prescription` dialogue token; there is nothing to do but let the
		-- conversation continue to it.

	elseif action == "focusBoard" then
		Hub.refreshPersonal(player)
		Hub.refreshBoard()
	end
end

--[[
	What the coach says when asked how you are doing.

	The hook existed and nothing ever filled it, so `stateFor` fell through to
	its "not enough shots on record yet" default on every conversation, forever,
	regardless of how many matches were behind the player. Telemetry was being
	measured, scored and thrown away.
]]
DialogueService.prescriptionFor = function(player: Player): string?
	local handle = Profile.load(player.UserId)
	local coaching = handle and handle.data.coaching
	if not coaching or coaching.line == "" then
		return nil
	end
	return coaching.line
end

--[[
	The season track, granted the moment pass ownership is known.

	Two callers, and the second is the one that matters: join, and the instant a
	purchase completes. Without the second the player pays for the pass, sees
	nothing happen, and only receives the rewards they already earned after
	finishing a whole match. Awarding at match end alone was the bug.

	Safe to run repeatedly -- Season.claimed makes every reward grant once.
]]
Commerce.onPassResolved = function(player: Player)
	local handle = Profile.load(player.UserId)
	if not handle then
		return
	end
	local granted = SeasonPass.grantDue(handle)
	if #granted > 0 and player.Parent == Players then
		Remotes.event("LoadoutChanged"):FireClient(player, handle.data.loadout, Loadout.resolve(handle.data))
		Remotes.event("Notice"):FireClient(player, {
			text = `Season rewards unlocked: {#granted}`,
		})
	end
end

DialogueService.bind()

local DEFAULT_TIER: Types.BotTier = "rec"

local function asMap(value: any): string?
	if type(value) ~= "string" then
		return nil
	end
	for _, name in ipairs(Config.mapNames()) do
		if name == value then
			return name
		end
	end
	return nil
end

local function asTier(value: any): Types.BotTier?
	if value == "rec" or value == "amateur" or value == "semipro" or value == "pro" then
		return value
	end
	return nil
end

--[[
	Modes a player may actually start.

	The answer lives in Data/gamemodes.json as `integrated`, and nowhere else. A
	hardcoded list here would be a second source of truth that can disagree with
	the data -- which is precisely how the Shoothouse ended up specced, tested
	and unreachable. Horde and Capture the Flag have rules modules and specs but
	no match loop, so they are refused by name rather than quietly running as a
	gauntlet.
]]
local function asMode(value: any): string?
	if type(value) ~= "string" then
		return nil
	end
	local mode = Config.get("gamemodes").modes[value]
	if not mode or mode.integrated ~= true then
		return nil
	end
	return value
end

--[[
	Why this player may not start this mode on this map, or nil.

	Returns the SENTENCE, not a boolean: every refusal in this game is something
	the player is told, and a gate whose message lives at the call site is a gate
	that gets copied without its message. The Horde dialogue action and
	`Hub.onCourseEntered` both used to discard the reason.
]]
local function modeRefusal(player: Player, mode: string, mapName: string): string?
	local modes = Config.get("gamemodes").modes
	local rules = modes[mode]
	if not rules or rules.integrated ~= true then
		return "This mode is still in field preparation."
	end
	--- `maps` is authored per mode and was enforced nowhere.
	if type(rules.maps) == "table" and not table.find(rules.maps, mapName) then
		return `That field does not run {mode}.`
	end
	local handle = Profile.load(player.UserId)
	if not handle then
		return "Field pass unavailable."
	end
	if mode == "captureTheFlag" and not FlagMatch.canStart(mapName, handle.data) then
		return "Capture the Flag opens on Holdfast after the Back Forty chapter."
	end
	if mode == "horde" and not Campaign.hordeUnlocked(Campaign.recordFromProfile(handle.data)) then
		return "The Long Afternoon opens when you have swept the pro circuit."
	end
	if mode == "shoothouse" and not Course.hasCourse(mapName) then
		return "That field has no Shoothouse course."
	end
	if not Profile.hasUnlocked(handle, mapName) then
		return "That field is not open to you yet."
	end
	return nil
end

local function startMatch(player: Player, mapName: string, tier: Types.BotTier, mode: string?): boolean
	local handle = Profile.load(player.UserId)
	if not handle then
		log.warn(`refusing match for {player.Name}: no profile session`)
		return false
	end
	if not Profile.hasUnlocked(handle, mapName) then
		log.warn(`{player.Name} asked for locked map {mapName}`)
		mapName = DEFAULT_MAP
	end
	--[[
		Park The Landing before the field is built.

		Maps are built at the world origin and the hub is 190x190 metres there,
		so without this the match is assembled INSIDE the hub -- which is why
		Marge and Tildy were standing on the field with live prompts. Parked
		first, restored by Hub.placePlayer on the way back out.
	]]
	Hub.park()
	local match = MatchService.start(player, mapName, tier, nil, mode)
	if not match then
		Hub.restore()
	end
	return match ~= nil
end

requestMatch = function(player: Player, payload: any): any
	if starting[player] then
		return { ok = false, reason = "Match is already starting." }
	end
	--[[
		Validate the whole request BEFORE claiming anything.

		`returnTokens` used to be incremented right here, at the top, before the
		mode and map had been checked -- so a REJECTED replay request
		invalidated the automatic return that was already pending, and a player
		who asked for something unavailable at the summary screen was left
		standing on a dead field with nothing coming to collect them. Nothing is
		claimed, parked or torn down until the request is known to be one the
		server will honour.
	]]
	starting[player] = true
	local mapName = DEFAULT_MAP
	local tier = DEFAULT_TIER
	--[[
		Mode routing. Gauntlet and the Shoothouse are both live; Horde and
		Capture the Flag have rules modules and specs but are still not wired to
		a match, so they are refused here rather than starting something that
		would silently run as a gauntlet.
	]]
	local mode = "gauntlet"
	if type(payload) == "table" and payload.mode then
		local requested = asMode(payload.mode)
		if not requested then
			starting[player] = nil
			return { ok = false, reason = "This mode is still in field preparation." }
		end
		mode = requested
	end
	if type(payload) == "table" then
		mapName = asMap(payload.map) or DEFAULT_MAP
		tier = asTier(payload.tier) or DEFAULT_TIER
	end
	--[[
		One place that decides whether a mode may be started on a map.

		There were three, and they disagreed. The NPC who starts The Long
		Afternoon checked `Campaign.hordeUnlocked`; the public
		`RequestMatchStart` remote did not, so an empty chapter record reached
		the horde start call by simply asking for it. `asMode` checked only
		`integrated`, and only Capture the Flag had an explicit unlock check --
		so `modes[mode].maps` was authored and never enforced, and a direct
		request could run a mode on a field it was never designed for.

		Every route -- the gate, the NPC, the summary's Play again, the remote
		-- goes through this. A gate that one caller can walk around is not a
		gate.
	]]
	local refusal = modeRefusal(player, mode, mapName)
	if refusal then
		starting[player] = nil
		return { ok = false, reason = refusal }
	end
	--[[
		One field at a time. The place is MaxPlayers = 2 so a course can take a
		second player, but the shared-match plumbing for that is not built yet --
		and two matches at once would build two maps at the world origin and park
		the hub out from under whoever stayed behind. Refuse plainly rather than
		producing that.
	]]
	--[[
		One scene at the origin, and one owner of it.

		This used to be `MatchService.currentHost()`, which sees ACTIVE matches
		and nothing else -- not a Range session, not a venue retained after the
		final whistle so the player could shop, not the window while a character
		load was yielding. So a match could start on top of somebody's drill, and
		a drill could start on top of somebody's field.

		Claimed before `MatchService.stop`, before `Hub.park` and before anything
		that yields. The same player re-claiming is a handover: pressing Play
		again arrives while they still own the venue they just finished on.
	]]
	local lease, heldBy = Activity.claim(player, "match")
	if not lease then
		starting[player] = nil
		return { ok = false, reason = `{(heldBy :: Player).DisplayName} is on the field. One field at a time.` }
	end
	leases[player] = lease :: Activity.Lease

	--[[
		A drill and a match cannot share a player.

		Nothing stopped the Range when a match started. Both loops connect to
		`FireMarker` and `RequestReload`, so both consumed every trigger pull,
		and both built geometry at the origin. Releasing the lease above does not
		reach into RangeService, so it is stopped explicitly here.
	]]
	if RangeService.isActive(player) then
		RangeService.stop(player)
	end
	MatchService.stop(player)
	MatchService.disposeVenue(player)

	Activity.onRelease(lease :: Activity.Lease, function()
		MatchService.stop(player)
		MatchService.disposeVenue(player)
	end)

	local success, result = pcall(startMatch, player, mapName, tier, mode)
	starting[player] = nil
	if not success or not result then
		--[[
			A half-built match must never leave the player with no world at all.

			Releasing the lease runs the teardown registered above, so the field
			comes down before The Landing goes back up rather than being
			restored on top of it.
		]]
		leases[player] = nil
		Activity.release(lease :: Activity.Lease)
		Hub.restore()
		if not success then
			log.warn(`match startup failed: {result}`)
			return { ok = false, reason = "Could not start the match. Check Studio Output." }
		end
		return { ok = false, reason = "Could not start the match." }
	end
	return { ok = result, map = mapName, tier = tier, mode = mode }
end

Remotes.fn("RequestMatchStart").OnServerInvoke = requestMatch
MatchService.onReturnToField = function(player)
	requestMatch(player, nil)
end

--[[
	Opening the Range.

	The Range is built at the world origin exactly as a match map is, so the hub
	has to be parked first or the drill assembles inside The Landing -- the same
	trap MatchService documents. It is put back when the drill ends.

	No unlock gate and no payout: Data/range.json pays zero and ship-check
	asserts it. The Range is free because charging for practice on an aim
	trainer would be charging for the game.
]]
function startDrill(player: Player, drillId: string?): boolean
	if starting[player] or RangeService.isActive(player) then
		return false
	end
	local wanted = drillId or Config.require("range", "drillOrder")[1]
	if not RangeService.isDrill(wanted) then
		Remotes.event("MatchStateChanged"):FireClient(player, {
			phase = "hub", notice = "No such drill.",
		})
		return false
	end

	--[[
		The Range is a scene at the origin like any other, so it takes the lease.

		`startDrill` checked activity for THIS player only, so a second player
		could open the Range during the first player's match -- building a range
		inside their field, at the same origin, with both loops consuming the
		same FireMarker events. It also never set `starting`, which is what let
		Bootstrap's CharacterAdded handler decide a Range player was eligible for
		the hub and restore The Landing on top of the firing line mid-drill.

		Claimed before `Hub.park` and before `RangeService.start`, which yields
		on `LoadCharacterAsync`.
	]]
	local lease, heldBy = Activity.claim(player, "range")
	if not lease then
		Remotes.event("MatchStateChanged"):FireClient(player, {
			phase = "hub",
			notice = `{(heldBy :: Player).DisplayName} is on the field. One field at a time.`,
		})
		return false
	end
	leases[player] = lease :: Activity.Lease
	Activity.onRelease(lease :: Activity.Lease, function()
		RangeService.stop(player)
	end)

	--- A match's field and its retained venue are both still at the origin.
	MatchService.stop(player)
	MatchService.disposeVenue(player)

	Hub.park()
	local ok = RangeService.start(player, wanted)
	if not ok then
		leases[player] = nil
		Activity.release(lease :: Activity.Lease)
		Hub.restore()
		Remotes.event("MatchStateChanged"):FireClient(player, {
			phase = "hub", notice = "The Range could not open. Check Studio Output.",
		})
	end
	return ok
end

--[[
	The Range gate offers all five drills.

	It used to start `drillOrder[1]` -- Pop-Up, always -- and the coach started
	whichever drill his diagnosis named. So Holdover and Peek were reachable
	only by being TOLD to practise them, and a player who knew their lead was
	the problem had no route to the drill for it. Five drills were authored,
	scored and tuned; two were selectable.

	Sent as a catalogue rather than started immediately, so the choice is the
	player's. Each entry carries what the drill trains and what this player has
	previously managed on it, because "which of these do I need" is the question
	being asked at the gate.
]]
function offerDrills(player: Player)
	if starting[player] or MatchService.isActive(player) or RangeService.isActive(player) then
		return
	end
	local handle = Profile.load(player.UserId)
	if not handle or player.Parent ~= Players then
		return
	end
	local practice = handle.data.practice or {}
	local coaching = handle.data.coaching
	local entries = {}
	for _, drillId in ipairs(Config.require("range", "drillOrder")) do
		local cfg = Config.require("range", "drills." .. drillId)
		local record = practice[drillId]
		table.insert(entries, {
			drill = drillId,
			displayName = cfg.displayName,
			fundamental = cfg.fundamental,
			secondaryFundamental = cfg.secondaryFundamental,
			durationSeconds = cfg.durationSeconds,
			bestScore = record and record.bestScore,
			bestRating = record and record.bestRating,
			runs = record and record.runs,
			--- The drill the last match's diagnosis pointed at, so the coach's
			--- advice is visible here too rather than only at the barn.
			prescribed = coaching ~= nil and coaching.drill == drillId,
		})
	end
	Remotes.event("DrillCatalogue"):FireClient(player, { drills = entries })
end

RangeService.onFinished = function(player: Player, _result)
	if player.Parent ~= Players then
		local lease = leases[player]
		if lease then
			leases[player] = nil
			Activity.release(lease)
		end
		return
	end
	--[[
		The score panel arrives on its own remote and stays until dismissed.

		This used to send a `hub` phase carrying a one-line notice with the hit
		count, and the client's hub handling calls `Hud.hideSummary` -- so the
		result was destroyed by the very message that announced it. The rating,
		the fundamental and the accuracy were never shown at all. `DrillScore`
		now carries the whole result and the client renders it; the player walks
		back to The Landing either way.
	]]
	returnToHub(player, Hub.gateReturnPosition("range"))
end

--- Walking into a trailhead and holding the key starts that map's five rounds.
Hub.onGateEntered = function(player: Player, mapName: string)
	if mapName == "range" then
		offerDrills(player)
		return
	end
	local handle = Profile.load(player.UserId)
	if not handle or player.Parent ~= Players then return end
	local tier = Campaign.recommendedTier(Campaign.recordFromProfile(handle.data))
	local result = requestMatch(player, { map = mapName, tier = tier, mode = if Config.map(mapName).captureTheFlag then "captureTheFlag" else "gauntlet" })
	if not result.ok then Remotes.event("MatchStateChanged"):FireClient(player, { phase = "hub", notice = result.reason }) end
end

--- The other prompt on the same post: the timed course.
Hub.onCourseEntered = function(player: Player, mapName: string)
	local handle = Profile.load(player.UserId)
	if not handle or player.Parent ~= Players then return end
	local tier = Campaign.recommendedTier(Campaign.recordFromProfile(handle.data))
	--- The result was discarded, so a refused course closed the prompt and said
	--- nothing at all. Every refusal in this game is something the player is told.
	local result = requestMatch(player, { map = mapName, tier = tier, mode = "shoothouse" })
	if not result.ok then
		Remotes.event("MatchStateChanged"):FireClient(player, { phase = "hub", notice = result.reason })
	end
end

--[[
	Walking up to a counter in the barn opens that bay, and only that bay.

	The snapshot is assembled here rather than through MatchService.shopData,
	because that one gates on being at a match venue and the barn is not a match.
	Ownership and prices still come from Shop.catalogueFor -- the client is told
	what things cost, never asked.
]]
function bayCatalogue(player: Player, bayId: string?, categories: { string }?): any
	local handle = Profile.load(player.UserId)
	if not handle then
		return { ok = false, reason = "Field pass unavailable." }
	end
	local bayName = "FIELD SUPPLY"
	for _, bay in ipairs(Config.require("overworld", "barn.bays")) do
		if bay.id == bayId then
			bayName = bay.displayName
		end
	end
	return {
		ok = true,
		bay = bayId,
		bayName = bayName,
		categories = categories,
		freeMode = require(ReplicatedStorage.Shared.CommerceCatalog).isFree(),
		balance = handle.data.currency,
		catalogue = Shop.catalogueFor(handle),
		--[[
			The season track goes with the shop payload, not only with session
			state. The barn is where a player stands when they think about
			spending anything, and a pass whose progress is invisible at the
			counter is a pass nobody buys -- the whole track shipped with no way
			for a client to see it at all.
		]]
		season = SeasonPass.summary(handle),
	}
end

Hub.onNpcTalk = function(player: Player, npcId: string)
	-- Belt and braces. A parked hub's prompts cannot fire, but nobody at The
	-- Landing is reachable from inside a match and this says so out loud.
	if not Hub.isOpen() then
		return
	end
	DialogueService.open(player, npcId)
end

Hub.onBayOpened = function(player: Player, bayId: string, categories: { string })
	Remotes.event("ShopOpened"):FireClient(player, bayCatalogue(player, bayId, categories))
end

--[[
	Back to the woods when a match ends. The player reappears at the gate they
	came out of rather than at the entrance -- walking the whole trail again
	after every match would stop being peaceful and start being a chore.
]]
MatchService.onMatchEnded = function(player: Player, mapName: string)
	--[[
		The lease this return belongs to.

		Asked for by identity, not by re-reading whatever mutable state happens
		to be true in two and a half seconds. `returnTokens` incremented at the
		TOP of `requestMatch`, before the request was validated, so a rejected
		replay invalidated the pending return and left the player on a dead field
		with nothing coming for them. A lease that is no longer current means
		something else already owns the origin, and moving this player would put
		The Landing on top of it.
	]]
	local lease = leases[player]
	task.delay(2.5, function()
		if player.Parent ~= Players or starting[player] or MatchService.isActive(player) then
			return
		end
		if lease and not Activity.isCurrent(lease) then
			return
		end
		--- The results panel stays up. The player walks back to The Landing
		--- while still reading what the match told them about their shooting.
		returnToHub(player, Hub.gateReturnPosition(mapName), true)
	end)
end
Remotes.fn("RequestShopVisit").OnServerInvoke = function(player)
	if starting[player] then return { ok = false, reason = "Wait for the field to open." } end
	return { ok = MatchService.visitShop(player) }
end
Remotes.fn("RequestShopCatalogue").OnServerInvoke = function(player: Player): any
	local stocked = Hub.allowedCategories(player)
	if #stocked > 0 then
		local bay = nil
		for _, entry in ipairs(Config.require("overworld", "barn.bays")) do
			if table.find(stocked, entry.categories[1]) then
				bay = entry.id
			end
		end
		return bayCatalogue(player, bay, stocked)
	end
	return MatchService.shopData(player)
end

Remotes.fn("RequestPurchase").OnServerInvoke = function(player: Player, category: any, id: any): any
	if starting[player] then
		return { ok = false, reason = "Wait for the field to open." }
	end
	--[[
		The counter you are standing at decides what you can buy. A client asking
		the markers counter for a jersey is refused here rather than trusted --
		the bay list is server-side and the client never names a price.
	]]
	local stocked = Hub.allowedCategories(player)
	if #stocked == 0 and not MatchService.canShop(player) then
		return { ok = false, reason = "Walk up to a counter in the barn." }
	end
	if #stocked > 0 and not table.find(stocked, category) and not (category == "camos" and table.find(stocked, "markers")) then
		return { ok = false, reason = "Not stocked at this counter." }
	end
	if not Shop.isCategory(category) or type(id) ~= "string" then
		return { ok = false, reason = "malformed" }
	end
	local handle = Profile.load(player.UserId)
	if not handle then
		return { ok = false, reason = "no profile" }
	end
	local result = Shop.purchase(handle, category :: Shop.Category, id)
	if result.ok then
		Remotes.event("CurrencyChanged"):FireClient(player, handle.data.currency)
	end
	return result
end

Remotes.fn("RequestEquip").OnServerInvoke = function(player: Player, category: any, id: any): any
	if starting[player] then
		return { ok = false, reason = "Wait for the field to open." }
	end
	if #Hub.allowedCategories(player) == 0 and not MatchService.canShop(player) then
		return { ok = false, reason = "Change equipment at the barn." }
	end
	if not Shop.isCategory(category) or type(id) ~= "string" then
		return { ok = false, reason = "malformed" }
	end
	local handle = Profile.load(player.UserId)
	if not handle then
		return { ok = false, reason = "no profile" }
	end
	local result = Shop.equip(handle, category :: Shop.Category, id)
	if result.ok then
		Remotes.event("LoadoutChanged"):FireClient(player, handle.data.loadout, Loadout.resolve(handle.data))
	end
	return result
end

Remotes.fn("RequestSessionState").OnServerInvoke = function(player: Player): any
	local handle = Profile.load(player.UserId)
	if not handle then return { ok = false, reason = "Your field pass is loading." } end
	local rules = require(ReplicatedStorage.Shared.Camos)
	return {
		ok = true, loadout = handle.data.loadout, balance = handle.data.currency,
		kit = if RangeService.isActive(player) then Loadout.forRange(handle.data) else Loadout.resolve(handle.data),
		phase = if MatchService.isActive(player) then "live" else "hub",
		camoProgress = { headshots = rules.headshots(handle.data), unlockedCamos = {},
			equippedCamo = handle.data.loadout.camo, nextUnlock = rules.nextUnlock(handle.data) },
		--[[
			Shoothouse records: best time, best medal, runs and clears per field,
			with that field's par alongside so the client can show what is left to
			beat. A timed mode whose times are written and never shown is a
			leaderboard nobody can read, which is most of the reason to run one
			twice.
		]]
		courses = CourseProgress.summary(handle.data),
		--[[
			The season track. Sent with session state rather than on its own
			remote because the client needs it at exactly the moments it already
			asks for this: on join, and after the shop changes something.
		]]
		season = SeasonPass.summary(handle),
	}
end

Remotes.fn("RequestCommerce").OnServerInvoke = function(player: Player, payload: any): any
	if starting[player] then return { ok = false, reason = "Wait for the field to open." } end
	return commerce:request(player, payload)
end

Remotes.fn("RequestRangeDrill").OnServerInvoke = function(player: Player, drillId: any): any
	if starting[player] then
		return { ok = false, reason = "Wait for the field to open." }
	end
	if RangeService.isActive(player) then
		return { ok = false, reason = "You are already on the line." }
	end
	if MatchService.isActive(player) then
		return { ok = false, reason = "Finish the field first." }
	end
	if drillId ~= nil and not RangeService.isDrill(drillId) then
		return { ok = false, reason = "No such drill." }
	end
	local started = startDrill(player, drillId)
	return { ok = started, drills = Config.require("range", "drillOrder") }
end

--[[
	Seats on this server.

	It used to admit exactly one player and kick the second, which was correct
	while the place was MaxPlayers = 1 and made MaxPlayers = 2 meaningless. The
	Shoothouse is authorized for two, so the seat exists.

	What a second player CANNOT yet do is join a run: the shared-match plumbing
	is unbuilt and requestMatch refuses a second concurrent match. So the second
	seat is a real seat -- the hub, the barn, the shop, the notice board -- and
	the field is one at a time until co-op lands. Kicking them would be worse
	than telling them to wait, and letting them start their own match would build
	a second map on top of the first.
]]
local function seatLimit(): number
	local modes = Config.get("gamemodes").modes
	local most = 1
	for name, mode in pairs(modes) do
		if mode.integrated == true and type(mode.maxPlayers) == "number" and mode.maxPlayers > most then
			most = mode.maxPlayers
		end
	end
	return most
end

local function onPlayer(player: Player)
	if #Players:GetPlayers() > seatLimit() then
		player:Kick(`This field seats {seatLimit()}. Try another server.`)
		return
	end
	local handle = Profile.load(player.UserId)
	if not handle then player:Kick("Your field pass could not load. Please rejoin."); return end
	task.spawn(function() commerce:playerAdded(player) end)
	--[[
		A new character is routed to whoever owns the world, not to the hub.

		This used to wait 0.2 s and then place the player in The Landing unless
		they had a `starting` flag or an active match. Three things were wrong
		with inferring hub eligibility from "no match":

		  - `startDrill` never set the flag, so a player whose drill was loading
		    got The Landing restored on top of the firing line. The exact
		    ordering against the yielding character load is engine-dependent,
		    which is a description of a race, not a defence.
		  - A SECOND player receiving CharacterAdded during someone else's match
		    restored the entire hub inside that match's field.
		  - A player whose match was still being built was not "active" yet.

		The lease answers all three with one question. If somebody owns the
		origin, the hub is not standing and this player does not get put in it --
		if it is their own activity, that activity places them; if it is
		somebody else's, they are told to wait rather than being dropped into a
		field they are not playing on.
	]]
	local function routeCharacter()
		if player.Parent ~= Players or starting[player] then
			return
		end
		local mine = Activity.kindFor(player)
		if mine ~= nil then
			--- Their own activity owns their character: RangeService puts them
			--- on the firing line, MatchService on its spawn. Nothing to do.
			return
		end
		if Activity.isHeld() then
			local holder = select(1, Activity.holder())
			Remotes.event("MatchStateChanged"):FireClient(player, {
				phase = "hub",
				notice = if holder
					then `{holder.DisplayName} is on the field. You are up next.`
					else "The field is busy.",
			})
			return
		end
		Hub.placePlayer(player)
	end

	player.CharacterAdded:Connect(function()
		task.wait(0.2)
		routeCharacter()
	end)

	--[[
		Reset, falling out of the world, and a character that simply vanishes.

		`Players.CharacterAutoLoads` is false in default.project.json, which
		Roblox documents as meaning the game must load characters itself. The
		only place that happened was the paintball elimination path calling
		LoadCharacterAsync -- so the native reset button, walking off the edge of
		a map and any character removed for any other reason left the player with
		NO character at all, indefinitely, until a timeout or a rejoin. For
		non-CTF the gameplay step just returns early each frame while the round
		clock keeps running; CTF holds the last known position.

		Routed through the activity owner, so a reset during a drill puts the
		player back on the firing line and a reset in the hub puts them in the
		hub. An activity that owns the origin and wants to handle its own
		respawn -- a match charging an out for it -- says so by taking the
		character back before this fires.
	]]
	local reloading = false
	local function recoverCharacter(lostCharacter: Model?)
		if reloading or player.Parent ~= Players or starting[player] then
			return
		end
		reloading = true
		task.delay(Config.require("match", "recoveryDelaySeconds"), function()
			reloading = false
			-- Died leaves Character assigned. Only a replacement character, not
			-- the existence of the old model, cancels this recovery.
			if player.Parent ~= Players or (player.Character and player.Character ~= lostCharacter) then
				return
			end
			--[[
				Recovery belongs to whoever owns the world.

				Dropping a plain character at the default spawn would put a
				player who reset mid-match onto a field they are not spawned
				into, at the origin, without charging the out that leaving a
				fight and coming back somewhere safe is supposed to cost. The
				activity that owns them knows where they go and what it costs.
			]]
			local kind = Activity.kindFor(player)
			if kind == "match" and MatchService.recover(player) then
				return
			end
			if kind == "range" and RangeService.recover(player) then
				return
			end
			--[[
				A load that fails must not leave the player without a world.

				The startup path wraps this in a pcall; the recovery path had no
				equivalent, so a spawn failure during a delayed respawn was
				unrecoverable.
			]]
			local ok, err = pcall(function()
				player:LoadCharacterAsync()
			end)
			if not ok then
				log.warn(`could not reload a character for {player.Name}: {err}`)
			end
		end)
	end

	player.CharacterRemoving:Connect(recoverCharacter)
	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(function() recoverCharacter(character) end)
		end
	end)

	player:LoadCharacter()
end

Players.PlayerAdded:Connect(onPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayer, player)
end

Players.PlayerRemoving:Connect(function(player)
	starting[player] = nil
	leases[player] = nil
	Activity.releaseFor(player)
	MatchService.stop(player)
	commerce:forget(player.UserId)
	Hub.forgetPersonal(player.UserId)
	Profile.release(player.UserId)
end)

log.info("server ready")
