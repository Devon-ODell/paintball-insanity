--!strict
--[[
	DialogueTree -- the conversation engine.

	Pure and side-effect free: it walks nodes, filters options against campaign
	state, and substitutes tokens. It never touches a player, an Instance or a
	DataStore. The caller decides what an `action` actually does, which is what
	lets the same tree run in a spec and in the world.

	Gating is the whole reason this exists rather than being a table of strings.
	The same NPC has to say different things as the campaign moves, or the hub
	stops being a place with people in it and becomes a menu with faces.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local DialogueTree = {}

export type State = {
	--- Chapter ids the player has finished.
	completed: { [string]: boolean },
	--- Feature ids the campaign has unlocked ("horde", "consumables", "bosses").
	unlocked: { [string]: boolean },
	--- Token values for substitution: chapterBrief, prescription, and so on.
	tokens: { [string]: string },
}

export type Option = {
	index: number,
	text: string,
	goto_: string?,
	action: string?,
	arg: string?,
}

export type Node = {
	id: string,
	lines: { string },
	options: { Option },
	isEnd: boolean,
}

function DialogueTree.emptyState(): State
	return { completed = {}, unlocked = {}, tokens = {} }
end

--------------------------------------------------------------------------------

--[[
	Does the player meet a `requires` clause?

	Supported forms, all optional and all ANDed:
	    { chapterComplete = "proCircuit" }
	    { unlocked = "consumables" }
	    { notComplete = "walkOn" }

	An absent clause always passes -- most lines are ungated and having to
	declare that would make the data unreadable.
]]
function DialogueTree.meets(requires: any, state: State): boolean
	if requires == nil then
		return true
	end
	if type(requires) ~= "table" then
		return false
	end
	if requires.chapterComplete and not state.completed[requires.chapterComplete] then
		return false
	end
	if requires.notComplete and state.completed[requires.notComplete] then
		return false
	end
	if requires.unlocked and not state.unlocked[requires.unlocked] then
		return false
	end
	return true
end

--- Replaces {token} with the state's value, leaving unknown tokens visible so a
--- missing substitution shows up in testing rather than silently vanishing.
function DialogueTree.substitute(line: string, state: State): string
	return (line:gsub("{(%w+)}", function(key)
		return state.tokens[key] or ("{" .. key .. "}")
	end))
end

--------------------------------------------------------------------------------

--- The raw tree for an NPC.
function DialogueTree.treeFor(npcId: string): any
	local trees = Config.require("npcs", "dialogue")
	local tree = trees[npcId]
	if not tree then
		error(`DialogueTree: no dialogue for '{npcId}'`, 2)
	end
	return tree
end

--[[
	Resolves a node: substitutes its lines and filters its options.

	Returns nil when the node itself is gated out, so a caller that jumps
	straight to a locked node gets nothing rather than a leak.
]]
function DialogueTree.node(npcId: string, nodeId: string, state: State): Node?
	local raw = DialogueTree.treeFor(npcId)[nodeId]
	if not raw then
		return nil
	end
	if not DialogueTree.meets(raw.requires, state) then
		return nil
	end

	local lines: { string } = {}
	for i, line in ipairs(raw.lines) do
		lines[i] = DialogueTree.substitute(line, state)
	end

	local options: { Option } = {}
	for _, option in ipairs(raw.options or {}) do
		if not DialogueTree.meets(option.requires, state) then
			continue
		end
		--[[
			An option pointing at a node the player cannot reach yet is dropped
			as well. Otherwise the tree would show a live choice that dead-ends,
			which reads as a bug rather than as a lock.
		]]
		if option.goto then
			local target = DialogueTree.treeFor(npcId)[option.goto]
			if target and not DialogueTree.meets(target.requires, state) then
				continue
			end
		end
		table.insert(options, {
			index = #options + 1,
			text = DialogueTree.substitute(option.text, state),
			goto_ = option.goto,
			action = option.action,
			arg = option.arg,
		})
	end

	return {
		id = nodeId,
		lines = lines,
		options = options,
		isEnd = #options == 0,
	}
end

--[[
	The opening node for an NPC.

	Prefers the most specific gated entry point available -- so Marge opens on
	the Aurum offer once you have earned it and on `root` otherwise, without the
	caller needing to know which chapters exist.
]]
function DialogueTree.start(npcId: string, state: State): Node?
	local tree = DialogueTree.treeFor(npcId)

	--[[
		An alternate opening must be marked `entry` in the data, not merely
		gated. Plenty of nodes are gated and are still ordinary sub-nodes you
		reach by asking -- Tildy's drone talk is locked behind a chapter but you
		still get to it by bringing it up. Treating every gated node as an
		opening would have her lead with it.
	]]
	local entries: { string } = {}
	for nodeId, raw in pairs(tree) do
		if raw.entry == true and DialogueTree.meets(raw.requires, state) then
			table.insert(entries, nodeId)
		end
	end
	-- Alphabetical, so a tie is deterministic. The data is authored so that an
	-- npc with several entry nodes has them mutually exclusive.
	table.sort(entries)

	for _, nodeId in ipairs(entries) do
		local node = DialogueTree.node(npcId, nodeId, state)
		if node then
			return node
		end
	end
	return DialogueTree.node(npcId, "root", state)
end

--- Follows an option by index. Returns the next node, plus the action and
--- argument the caller should perform. A nil node means the conversation ended.
function DialogueTree.choose(npcId: string, node: Node, optionIndex: number, state: State): (Node?, string?, string?)
	local option = node.options[optionIndex]
	if not option then
		return nil, nil, nil
	end
	local nextNode: Node? = nil
	if option.goto_ then
		nextNode = DialogueTree.node(npcId, option.goto_ :: string, state)
	end
	return nextNode, option.action, option.arg
end

--------------------------------------------------------------------------------

--[[
	Structural validation of the whole dialogue bank.

	Every `goto` must land on a node that exists, every NPC needs a root, and no
	node may be unreachable. Broken dialogue is invisible until someone walks up
	to the wrong NPC in the wrong state, so it is checked here instead.
]]
function DialogueTree.validate(): { string }
	local problems: { string } = {}
	local trees = Config.require("npcs", "dialogue")
	local npcs = Config.require("npcs", "npcs")

	for npcId, tree in pairs(trees) do
		if not npcs[npcId] then
			table.insert(problems, `dialogue for unknown npc '{npcId}'`)
		end
		if not tree.root then
			table.insert(problems, `{npcId} has no root node`)
		end

		local reachable: { [string]: boolean } = { root = true }
		for nodeId, raw in pairs(tree) do
			if raw.entry == true then
				-- An alternate opening is reached by definition.
				reachable[nodeId] = true
			end
			for _, option in ipairs(raw.options or {}) do
				if option.goto then
					if not tree[option.goto] then
						table.insert(problems, `{npcId}.{nodeId} points at missing node '{option.goto}'`)
					else
						reachable[option.goto] = true
					end
				end
				if type(option.text) ~= "string" or #option.text == 0 then
					table.insert(problems, `{npcId}.{nodeId} has an option with no text`)
				end
			end
			if type(raw.lines) ~= "table" or #raw.lines == 0 then
				table.insert(problems, `{npcId}.{nodeId} has no lines`)
			end
		end

		for nodeId in pairs(tree) do
			if not reachable[nodeId] then
				table.insert(problems, `{npcId}.{nodeId} is unreachable`)
			end
		end
	end

	for npcId in pairs(npcs) do
		if not trees[npcId] then
			table.insert(problems, `npc '{npcId}' has no dialogue`)
		end
	end

	return problems
end

--- Every action name the bank uses, so the caller can assert it handles them all.
function DialogueTree.actions(): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, tree in pairs(Config.require("npcs", "dialogue")) do
		for _, raw in pairs(tree) do
			for _, option in ipairs(raw.options or {}) do
				if option.action and not seen[option.action] then
					seen[option.action] = true
					table.insert(out, option.action)
				end
			end
		end
	end
	table.sort(out)
	return out
end

return DialogueTree
