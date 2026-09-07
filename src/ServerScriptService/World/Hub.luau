--!strict
--[[
	Hub -- owns The Landing and routes the player through it.

	The hub is the game's home. You spawn in it, you walk to a gate to play, you
	walk to the barn to spend, and when a match ends you come back to it. That
	loop is the only pacing the design has against being a deliberate meat
	grinder, so the walk is never skipped and never shortened.

	This file is the seam between the built world (Overworld/PoleBarn/NoticeBoard)
	and the game's services (MatchService, Shop, Leaderboard). The builders know
	nothing about players; the services know nothing about trees.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)
local Units = require(ReplicatedStorage.Shared.Units)
local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Net.Remotes)

local Overworld = require(script.Parent.Overworld)
local Leaderboard = require(script.Parent.Parent.Leaderboard.Leaderboard)

local log = Log.scope("LiveRound.Hub")

local Hub = {}

local hub: any = nil
--- Which bay each player last walked up to. The shop only ever sells what the
--- counter in front of them stocks, so a client cannot ask the markers counter
--- for a jersey.
local openBay: { [Player]: { id: string, categories: { string } } } = {}

--- Hooks the bootstrap fills in, so this module does not have to know about
--- match startup or profiles.
Hub.onGateEntered = nil :: ((Player, string) -> ())?
Hub.onBayOpened = nil :: ((Player, string, { string }) -> ())?
Hub.onNpcTalk = nil :: ((Player, string) -> ())?
Hub.profileFor = nil :: ((Player) -> any)?

--------------------------------------------------------------------------------

function Hub.isBuilt(): boolean
	return hub ~= nil
end

function Hub.model(): Model?
	return hub and hub.model
end

--- Builds the hub, once. Safe to call again; it returns the existing one.
function Hub.build(): any
	if hub then
		return hub
	end
	hub = Overworld.build(Workspace)

	for _, gate in ipairs(hub.gates) do
		gate.prompt.Triggered:Connect(function(player: Player)
			if Hub.onGateEntered then
				(Hub.onGateEntered :: any)(player, gate.map)
			end
		end)
	end

	for _, bay in ipairs(hub.bays) do
		bay.prompt.Triggered:Connect(function(player: Player)
			openBay[player] = { id = bay.id, categories = bay.categories }
			if Hub.onBayOpened then
				(Hub.onBayOpened :: any)(player, bay.id, bay.categories)
			end
		end)
	end

	for id, person in pairs(hub.people or {}) do
		person.prompt.Triggered:Connect(function(player: Player)
			if Hub.onNpcTalk then
				(Hub.onNpcTalk :: any)(player, id)
			end
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		openBay[player] = nil
	end)

	log.info("the landing is open")
	return hub
end

--------------------------------------------------------------------------------
-- Parking the hub for the duration of a match
--------------------------------------------------------------------------------

--[[
	The Landing is 190x190 metres and every map is built at the world origin, so
	while a match is running the field is standing INSIDE the hub. Holdfast is
	150x200 -- it overlaps The Landing almost completely.

	That is why interactable people were showing up mid-round: nothing was ever
	hiding them. They were never "in the match", the match was being built on top
	of them, along with the barn, the trees, the pond and every trail.

	Parking is a single Parent write on the root model rather than a rebuild.
	Every prompt, connection and reference survives, so coming back is another
	single write. Prompts are disabled explicitly too: a ProximityPrompt outside
	the DataModel cannot fire, but the cost of being sure is one boolean.
]]
local parked: Folder? = nil

function Hub.park()
	if not hub or not hub.model or hub.model.Parent ~= Workspace then
		return
	end
	for _, person in pairs(hub.people or {}) do
		person:setAvailable(false)
	end
	local holder = parked
	if not holder then
		holder = Instance.new("Folder")
		;(holder :: Folder).Name = "LandingParked"
		;(holder :: Folder).Parent = game:GetService("ServerStorage")
		parked = holder
	end
	hub.model.Parent = holder
	log.info("the landing is parked for the match")
end

function Hub.restore()
	if not hub or not hub.model or hub.model.Parent == Workspace then
		return
	end
	hub.model.Parent = Workspace
	for _, person in pairs(hub.people or {}) do
		person:setAvailable(true)
	end
	log.info("the landing is open again")
end

--- True when the hub is currently standing in the world.
function Hub.isOpen(): boolean
	return hub ~= nil and hub.model ~= nil and hub.model.Parent == Workspace
end

--------------------------------------------------------------------------------

--- The categories the counter in front of this player actually stocks, or an
--- empty list if they are not at a counter. This is the server-side gate on
--- what a purchase request is allowed to name.
function Hub.allowedCategories(player: Player): { string }
	local bay = openBay[player]
	return if bay then bay.categories else {}
end

function Hub.isAtCounter(player: Player): boolean
	local bay = openBay[player]
	if not bay then
		return false
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	for _, entry in ipairs(hub.bays) do
		if entry.id == bay.id then
			local radius = Units.metresToStuds(Config.require("venue", "interactionRadiusMetres"))
			return ((root :: BasePart).Position - entry.counter.Position).Magnitude <= radius * 1.5
		end
	end
	return false
end

function Hub.closeCounter(player: Player)
	openBay[player] = nil
end

--------------------------------------------------------------------------------

--[[
	Puts a player on the ground at the hub.

	Called on join and after every match. `at` lets a returning player be placed
	at the gate they came out of rather than back at the entrance -- walking the
	whole trail again after every single match would stop being peaceful and
	start being a chore.
]]
function Hub.placePlayer(player: Player, at: Vector3?)
	-- Putting a player into a parked hub would drop them through the world.
	Hub.restore()
	if not hub then
		Hub.build()
	end
	local character = player.Character
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		return
	end

	local target = at or hub.spawn
	local position = Units.vectorToStuds(target) + Vector3.new(0, root.Size.Y / 2 + humanoid.HipHeight + 1, 0)
	root.CFrame = CFrame.lookAt(position, Units.vectorToStuds(hub.lookAt) + Vector3.new(0, position.Y, 0))
	root.AssemblyLinearVelocity = Vector3.zero

	Remotes.event("MatchStateChanged"):FireClient(player, { phase = "hub", map = "landing" })
	Hub.refreshPersonal(player)
end

--- Where a player should reappear after finishing a match on `mapName`: at that
--- map's own gate, facing back into the clearing.
function Hub.gateReturnPosition(mapName: string): Vector3?
	if not hub then
		return nil
	end
	for _, gate in ipairs(hub.gates) do
		if gate.map == mapName then
			-- A couple of metres back from the arch, so you are not standing in it.
			return gate.position * 0.9
		end
	end
	return nil
end

--------------------------------------------------------------------------------

--[[
	Fills the notice board's personal page for whoever is here.

	Read from the profile rather than the DataStore, so walking past the board
	does not cost a request per page turn. The profile copy is written whenever a
	run actually sets a personal best.
]]
function Hub.refreshPersonal(player: Player)
	if not hub or not hub.board or not hub.board.setPersonal then
		return
	end
	local bests: { [string]: number } = {}

	local handle = if Hub.profileFor then (Hub.profileFor :: any)(player) else nil
	if handle and handle.data and handle.data.bestTimes then
		for mapName, seconds in pairs(handle.data.bestTimes) do
			bests[mapName] = seconds
		end
	end

	hub.board.setPersonal(player.DisplayName, bests)
end

--- Forces the board to re-read the live boards. Called after a submission, so a
--- new record shows up without waiting for the refresh timer.
function Hub.refreshBoard()
	if hub and hub.board then
		hub.board:refresh()
	end
end

function Hub.destroy()
	if hub then
		hub:destroy()
		hub = nil
	end
	table.clear(openBay)
end

return Hub
