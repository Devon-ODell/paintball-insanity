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
local Profile = require(Server.Economy.Profile)
local Shop = require(Server.Economy.Shop)
local Commerce = require(Server.Economy.Commerce)
local Hub = require(Server.World.Hub)
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

Remotes.init()
Dev.announce()
Profile.init()
Shop.assertNoPayToWin()
MatchService.bindLatencyReporting()
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

	elseif action == "startDrill" or action == "recommendDrill" or action == "readPrescription" then
		-- The Range binding is still sim-only; the prescription text already
		-- reached the player through the dialogue token.
		Remotes.event("MatchStateChanged"):FireClient(player, {
			phase = "hub",
			notice = "The Range opens once the live drill binding ships.",
		})

	elseif action == "focusBoard" then
		Hub.refreshPersonal(player)
		Hub.refreshBoard()
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

local function startMatch(player: Player, mapName: string, tier: Types.BotTier): boolean
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
	local match = MatchService.start(player, mapName, tier)
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
	if type(payload) == "table" and payload.mode and payload.mode ~= "gauntlet" then
		starting[player] = nil
		return { ok = false, reason = "This mode is still in field preparation." }
	end
	if type(payload) == "table" then
		mapName = asMap(payload.map) or DEFAULT_MAP
		tier = asTier(payload.tier) or DEFAULT_TIER
	end
	MatchService.stop(player)
	local success, result = pcall(startMatch, player, mapName, tier)
	starting[player] = nil
	if not success then
		MatchService.stop(player)
		-- A half-built match must never leave the player with no world at all.
		Hub.restore()
		log.warn(`match startup failed: {result}`)
		return { ok = false, reason = "Could not start the match. Check Studio Output." }
	end
	return { ok = result, map = mapName, tier = tier }
end

Remotes.fn("RequestMatchStart").OnServerInvoke = requestMatch
MatchService.onReturnToField = function(player)
	requestMatch(player, nil)
end

--- Walking into a trailhead and holding the key starts that map's five rounds.
Hub.onGateEntered = function(player: Player, mapName: string)
	if mapName == "range" then
		Remotes.event("MatchStateChanged"):FireClient(player, {
			phase = "hub",
			notice = "The Range opens once the live drill binding ships.",
		})
		return
	end
	requestMatch(player, { map = mapName, tier = DEFAULT_TIER })
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
	}
end

Remotes.fn("RequestCommerce").OnServerInvoke = function(player: Player, payload: any): any
	if starting[player] then return { ok = false, reason = "Wait for the field to open." } end
	return commerce:request(player, payload)
end

Remotes.fn("RequestRangeDrill").OnServerInvoke = function(_player: Player, _drillId: any): any
	return { ok = false, reason = "range is sim-only until the live binding ships" }
end

local soloPlayer: Player? = nil
local function onPlayer(player: Player)
	if soloPlayer and soloPlayer ~= player then
		player:Kick("This demo is a solo field. Start a separate play session.")
		return
	end
	soloPlayer = player
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
	if soloPlayer == player then soloPlayer = nil end
	MatchService.stop(player)
	commerce:forget(player.UserId)
	Profile.release(player.UserId)
end)

log.info("server ready")
