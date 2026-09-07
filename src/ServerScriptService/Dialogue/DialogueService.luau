--!strict
--[[
	DialogueService -- runs conversations, server-side.

	The tree, the gating and every action live here. The client is told what to
	draw and reports which option was pressed; it is never trusted with what an
	option DOES. That matters because half the actions unlock content.

	One live conversation per player. Walking away, dying, or starting a match
	ends it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Net.Remotes)

local DialogueTree = require(script.Parent.DialogueTree)
local Campaign = require(script.Parent.Parent.Progression.Campaign)

local log = Log.scope("LiveRound.Dialogue")

local DialogueService = {}

type Session = { npcId: string, node: DialogueTree.Node, state: DialogueTree.State }

local sessions: { [Player]: Session } = {}

--- Hooks the bootstrap fills in. Keeping them as hooks means this module never
--- has to know about matches, shops or the hub.
DialogueService.profileFor = nil :: ((Player) -> any)?
DialogueService.onAction = nil :: ((Player, string, string?) -> ())?
DialogueService.prescriptionFor = nil :: ((Player) -> string?)?

--------------------------------------------------------------------------------

--[[
	Builds the conversation state for a player: what they have completed, what is
	unlocked, and the tokens the lines substitute.

	Read fresh every time a conversation opens, so an NPC's opinion is always
	current rather than whatever it was when they spawned.
]]
function DialogueService.stateFor(player: Player): DialogueTree.State
	local state = DialogueTree.emptyState()

	local handle = if DialogueService.profileFor then (DialogueService.profileFor :: any)(player) else nil
	local record = Campaign.recordFromProfile(handle and handle.data)

	state.completed = record.completed
	state.unlocked = Campaign.unlocks(record)

	local card = Campaign.card(record)
	state.tokens.chapterBrief = card.brief or card.subtitle or "Nothing on the board today."
	state.tokens.chapterTitle = card.title or ""
	state.tokens.chapterGoal = card.goal or ""

	local prescription = if DialogueService.prescriptionFor
		then (DialogueService.prescriptionFor :: any)(player)
		else nil
	state.tokens.prescription = prescription
		or "Not enough shots on record yet. Go and take some and come back."

	return state
end

--------------------------------------------------------------------------------

local function send(player: Player, npcId: string, node: DialogueTree.Node?)
	if not node then
		sessions[player] = nil
		Remotes.event("DialogueOpened"):FireClient(player, nil)
		return
	end
	local npc = Config.require("npcs", "npcs." .. npcId)
	Remotes.event("DialogueOpened"):FireClient(player, {
		npc = npcId,
		speaker = npc.displayName,
		lines = node.lines,
		options = node.options,
	})
end

--- Opens a conversation.
function DialogueService.open(player: Player, npcId: string)
	local state = DialogueService.stateFor(player)
	local node = DialogueTree.start(npcId, state)
	if not node then
		log.warn(`no opening node for {npcId}`)
		return
	end
	sessions[player] = { npcId = npcId, node = node, state = state }
	send(player, npcId, node)
end

function DialogueService.close(player: Player)
	if sessions[player] then
		sessions[player] = nil
		Remotes.event("DialogueOpened"):FireClient(player, nil)
	end
end

function DialogueService.isTalking(player: Player): boolean
	return sessions[player] ~= nil
end

--[[
	Handles a choice.

	Index 0 means the player stepped away. Anything out of range is ignored
	rather than erroring -- a malformed index is either a stale click or someone
	poking the remote, and neither deserves a crash.
]]
function DialogueService.choose(player: Player, index: any)
	local session = sessions[player]
	if not session then
		return
	end
	if type(index) ~= "number" or index ~= index then
		return
	end
	if index == 0 then
		DialogueService.close(player)
		return
	end

	local nextNode, action, arg = DialogueTree.choose(session.npcId, session.node, index, session.state)

	if action and DialogueService.onAction then
		--[[
			The action runs BEFORE the next node is sent, so a line that reacts
			to what just happened -- Marge handing over the marker -- reads
			correctly rather than a beat late.
		]]
		local ok, err = pcall(DialogueService.onAction :: any, player, action, arg)
		if not ok then
			log.warn(`dialogue action '{action}' failed: {err}`)
		end
		-- The action may have changed the world, so re-read the state.
		session.state = DialogueService.stateFor(player)
	end

	if not nextNode then
		DialogueService.close(player)
		return
	end
	session.node = nextNode
	send(player, session.npcId, nextNode)
end

--------------------------------------------------------------------------------

function DialogueService.bind()
	Remotes.event("DialogueChoice").OnServerEvent:Connect(function(player, index)
		DialogueService.choose(player, index)
	end)
	Players.PlayerRemoving:Connect(function(player)
		sessions[player] = nil
	end)

	local problems = DialogueTree.validate()
	for _, problem in ipairs(problems) do
		log.warn(`dialogue: {problem}`)
	end
	if #problems == 0 then
		log.info("dialogue bank validated")
	end
end

return DialogueService
