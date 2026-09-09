--!strict
--[[
	Server entry. Everything else in this tree is a ModuleScript; without this
	file a player joins a place that has no remotes, no profile, and no match.

	Solo PvE: one player, start Speedball/rec immediately. No lobby.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Net.Remotes)

local Server = script.Parent
local MatchService = require(Server.Match.MatchService)
local Course = require(Server.Match.Course)
local CourseProgress = require(Server.Progression.CourseProgress)
local Profile = require(Server.Economy.Profile)
local Shop = require(Server.Economy.Shop)
local Commerce = require(Server.Economy.Commerce)
local SeasonPass = require(Server.Progression.SeasonPass)
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
local returnTokens: { [Player]: number } = {}
local startDrill: (Player, string?) -> boolean

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
			Remotes.event("LoadoutChanged"):FireClient(player, handle.data.loadout)
			log.info(`{player.Name} claimed the Aurum Kompressor`)
		else
			log.warn(`{player.Name} asked for the Aurum without meeting the goal`)
		end

	elseif action == "startHorde" then
		local record = Campaign.recordFromProfile(handle.data)
		if Campaign.hordeUnlocked(record) then
			Remotes.event("MatchStateChanged"):FireClient(player, { phase = "hub", notice = "Horde field preparation is still underway. Gauntlet gates are open." })
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
		Remotes.event("LoadoutChanged"):FireClient(player, handle.data.loadout)
		Remotes.event("MatchStateChanged"):FireClient(player, {
			phase = "hub",
			notice = `Season rewards unlocked: {#granted}`,
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
	starting[player] = true
	returnTokens[player] = (returnTokens[player] or 0) + 1
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
	if mode == "shoothouse" and not Course.hasCourse(mapName) then
		starting[player] = nil
		return { ok = false, reason = "That field has no Shoothouse course." }
	end
	--[[
		One field at a time. The place is MaxPlayers = 2 so a course can take a
		second player, but the shared-match plumbing for that is not built yet --
		and two matches at once would build two maps at the world origin and park
		the hub out from under whoever stayed behind. Refuse plainly rather than
		producing that.
	]]
	local host = MatchService.currentHost()
	if host and host ~= player then
		starting[player] = nil
		return { ok = false, reason = `{host.DisplayName} is on the field. One field at a time.` }
	end
	MatchService.stop(player)
	local success, result = pcall(startMatch, player, mapName, tier, mode)
	starting[player] = nil
	if not success then
		MatchService.stop(player)
		-- A half-built match must never leave the player with no world at all.
		Hub.restore()
		log.warn(`match startup failed: {result}`)
		return { ok = false, reason = "Could not start the match. Check Studio Output." }
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
	if starting[player] or MatchService.isActive(player) or RangeService.isActive(player) then
		return false
	end
	local wanted = drillId or Config.require("range", "drillOrder")[1]
	if not RangeService.isDrill(wanted) then
		Remotes.event("MatchStateChanged"):FireClient(player, {
			phase = "hub", notice = "No such drill.",
		})
		return false
	end
	Hub.park()
	local ok = RangeService.start(player, wanted)
	if not ok then
		Hub.restore()
		Remotes.event("MatchStateChanged"):FireClient(player, {
			phase = "hub", notice = "The Range could not open. Check Studio Output.",
		})
	end
	return ok
end

RangeService.onFinished = function(player: Player, result)
	Hub.restore()
	if player.Parent ~= Players then
		return
	end
	Remotes.event("MatchStateChanged"):FireClient(player, {
		phase = "hub",
		notice = `{result.drill}: {result.hits}/{result.shots} -- {result.score} pts`,
	})
	Hub.placePlayer(player, Hub.gateReturnPosition("range"))
	Hub.refreshBoard()
end

--- Walking into a trailhead and holding the key starts that map's five rounds.
Hub.onGateEntered = function(player: Player, mapName: string)
	if mapName == "range" then
		startDrill(player, nil)
		return
	end
	local handle = Profile.load(player.UserId)
	if not handle or player.Parent ~= Players then return end
	local tier = Campaign.recommendedTier(Campaign.recordFromProfile(handle.data))
	requestMatch(player, { map = mapName, tier = tier })
end

--- The other prompt on the same post: the timed course.
Hub.onCourseEntered = function(player: Player, mapName: string)
	local handle = Profile.load(player.UserId)
	if not handle or player.Parent ~= Players then return end
	local tier = Campaign.recommendedTier(Campaign.recordFromProfile(handle.data))
	requestMatch(player, { map = mapName, tier = tier, mode = "shoothouse" })
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
	local token = returnTokens[player]
	task.delay(2.5, function()
		if player.Parent ~= Players or returnTokens[player] ~= token or starting[player] or MatchService.isActive(player) then
			return
		end
		Hub.placePlayer(player, Hub.gateReturnPosition(mapName))
		Hub.refreshBoard()
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
		Remotes.event("LoadoutChanged"):FireClient(player, handle.data.loadout)
	end
	return result
end

Remotes.fn("RequestSessionState").OnServerInvoke = function(player: Player): any
	local handle = Profile.load(player.UserId)
	if not handle then return { ok = false, reason = "Your field pass is loading." } end
	local rules = require(ReplicatedStorage.Shared.Camos)
	return {
		ok = true, loadout = handle.data.loadout, balance = handle.data.currency,
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
		You start in the woods, not in a match. The first thing the game does is
		put you on a trail and let you walk to a gate.
	]]
	player.CharacterAdded:Connect(function()
		task.wait(0.2)
		if player.Parent == Players and not starting[player] and not MatchService.isActive(player) then
			Hub.placePlayer(player)
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
	returnTokens[player] = nil
	MatchService.stop(player)
	commerce:forget(player.UserId)
	Profile.release(player.UserId)
end)

log.info("server ready")
