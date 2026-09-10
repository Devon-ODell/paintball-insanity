--!strict
--[[
	Static analysis gate.

	    lune run tools/check-static

	The Power of 10 rules were written for C running on spacecraft, and applying
	all of them literally to Luau would be ceremony rather than safety -- there
	is no preprocessor, no pointer arithmetic, and no malloc to ban. What
	survives translation is checked here, plus the one rule this codebase
	actually needed and did not have.

	Rules checked, and why each earns its place:

	  1  no `goto`, and no unbounded recursion
	     Both make a stack bound unprovable. Recursion whose input is authored
	     data is allowed by exception below, and every exception is named.

	  2  no unbounded loop
	     `while true` in a task is idiomatic Roblox for a heartbeat and is
	     allowed only where it is a heartbeat with a wait in it.

	  4  function length -- ADVISORY under 150 lines, a failure above it
	     The literal rule is 60. This codebase builds Roblox scenes, and a
	     builder that lays out a character or a notice board is linear by
	     nature: splitting one into six helpers each called once makes it
	     harder to review, not easier, which is the opposite of what the rule
	     is for. So length is reported and not failed -- until 150, past which
	     no reading of the rule defends it.

	 10  every module compiles under `--!strict`
	     The project already does this everywhere. This stops it drifting.

	 --  every exported function has a call site
	     Not a Power of 10 rule, and the one that has caught the most real bugs
	     here: DialogueService.prescriptionFor was declared and never assigned,
	     so the coach said "not enough shots on record yet" forever, and
	     SeasonPass.summary shipped with no way for a client to ever see the
	     season track. Both were invisible to every other gate.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

--------------------------------------------------------------------------------
-- Exceptions, each with a reason. An exception without a reason is a bug.
--------------------------------------------------------------------------------

--- Recursion whose depth is bounded by data this project authors.
local RECURSION_ALLOWED: { [string]: string } = {
	["Profile.deepCopy"] = "only ever copies the authored profile template; never player data",
	["Campaign.goalMet"] = "recurses over authored goal nesting, which is depth 0 in shipped data",
	["Campaign.goalDescription"] = "same authored goal tree as goalMet",
}

--- Exports with no call site that are deliberately kept.
local UNCALLED_ALLOWED: { [string]: string } = {
	["Boss.forChapter"] = "Horde is specced and deferred; ship-check refuses to offer it",
	["Boss.hitTarget"] = "same deferred Horde rules module",
	["LagCompensation.rewind"] = "rewind is captured but not integrated; PUBLISH_READINESS says so",
	["LagCompensation.originIsPlausible"] = "unnecessary: MatchService discards the client origin entirely",
	["Config.clearCache"] = "test seam",
	["Rng.nextUnitVector2"] = "test seam",

	--[[
		Small accessors nothing currently reads. Kept rather than deleted in one
		sweep, but they are deletion candidates, not features waiting to be
		wired -- unlike Hub.isAtCounter, which WAS a feature waiting to be wired
		and turned out to be the reason the barn's proximity rule stopped
		applying after one visit. Each of these was checked for that.
	]]
	["BotController.canHear"] = "hearing is applied inside the controller's own update",
	["Campaign.gearRewards"] = "gear rewards are granted through the chapter record instead",
	["Chatter.bearingWord"] = "chatter picks lines by key; bearing wording is unused",
	["DialogueService.isTalking"] = "conversation state is owned by the client UI",
	["Fonts.ui"] = "UiTheme resolves fonts directly",
	["Hub.isBuilt"] = "build is idempotent; nothing needs to ask",
	["Leaderboard.personalBest"] = "the profile carries bests so the board needs no round trip",
	["MapGeometry.canPaintReachAt"] = "superseded by the projectile sim's own reach test",
	["MapGeometry.isSupported"] = "spawn validation moved into the map tools",
	["ProjectileSim.liveCount"] = "debug accessor",
	["ShotLog.shotCount"] = "the session summary carries the counts",
	["ShotLog.hitCount"] = "the session summary carries the counts",
	["SquadCoordinator.isFocusFiring"] = "focus fire is read from the bot's own order",
	["Units.speedToMetres"] = "kept for call-site readability; no current caller",
	["Wardrobe.setTransparency"] = "no current fade; kept with the dress/place pair",
	["WorldBuilder.projectileParams"] = "superseded: projectiles resolve against MapGeometry, never a raycast",
}

local ADVISORY_FUNCTION_LINES = 60
local MAX_FUNCTION_LINES = 150

--[[
	The long-function backlog, frozen at its measured length.

	Rule 4's detector never worked (see the rule below), so nothing here was
	ever reported. These are the real measurements taken the day it started
	working, 2026-09-09. Each may SHRINK freely; growing past its frozen number
	fails the gate. New functions still face the 150-line hard limit.

	Tightened as they shrink: MatchService.start and finish came down by 35 the
	day the payout rules moved into Match/Settlement, and their frozen numbers
	came down with them. A stale-high number would quietly re-authorise the
	growth that was just removed.

	It has already earned its keep. Integrating Horde pushed MatchService.start
	from 1,136 to 1,260 and this gate refused it, which is exactly the moment a
	God object usually gets a little worse and nobody notices. Placement,
	construction, the respawn point and the speaker lookup moved into
	Match/Squad, and the bearing arithmetic into Chatter where it belonged, and
	start came back down to 1,133 -- BELOW where it started. `step` and `finish`
	are each one line larger, which is the one line each of them needed to know
	horde exists; they are re-frozen there rather than pretended away.

	This is a ratchet rather than a pardon. Two of these -- MatchService.start
	at 1,136 lines and the two world builders -- are genuine architectural debt
	and are recorded as such in the change report. The rest are linear
	assemblies where splitting into helpers called once each would trade a
	readable sequence for a scatter, which is the case the 60-line advisory was
	already relaxed for.
]]
local KNOWN_LONG: { [string]: number } = {
	--[[
		1133 -> 1188 across two connections that had to happen inside the match.

		The resolved loadout: gear stats had specs, a shop and prices and no
		production caller at all, so sprint, reload, loudness and pod count
		reached nothing. And the server's own view of the player: position
		bounded by the speed their kit allows, crouch held as a state rather than
		asserted per shot, and a muzzle that follows the stance the server
		believes rather than standing chest height regardless.
	]]
	["MatchService.start"] = 1188,
	["PoleBarn.build"] = 742,
	["Overworld.build"] = 546,
	--- 413 -> 435 for the same reason, and it HAS to happen here too: a gear stat
	--- connected live and not in the simulator leaves every difficulty number in
	--- docs/PUBLISH_READINESS.md describing a different game.
	["runRound"] = 435,
	--- Was 407 and is now 138: the drill loop was one closure holding every
	--- piece of its own state in upvalues, and the Range's bugs lived at the
	--- edges of exactly that. Re-frozen at what it measures, not at what it was
	--- allowed.
	["RangeService.start"] = 138,
	["bayProp"] = 270,
	["Wardrobe.body"] = 242,
	["finish"] = 194,
	["ViewMarker.equip"] = 188,
	["step"] = 180,
	--- 167 -> 197 when a pass stopped being "a bag of cosmetics you either hold
	--- or do not". A free claim now writes the entitlement, requires it in its
	--- own save confirmation, and announces the pass changing hands the way a
	--- purchase does. Re-frozen at what it measures.
	["Commerce.new"] = 197,
	["SimMatch.run"] = 166,
	["BotAvatar.new"] = 162,
	["ShopUi.open"] = 158,
	--- 157 -> 197 when the board stopped having exactly one personal page and
	--- exactly one board per map. Times were separated by mode when WRITTEN and
	--- read back with no mode at all, so every page was the gauntlet one.
	["NoticeBoard.build"] = 197,
}

local ADVISORY_FUNCTION_LINES = 60
local MAX_FUNCTION_LINES = 150

--[[
	Builders allowed past the hard limit, with a reason each.

	BotAvatar.new was 214 lines and is now 168 after its marker rig and
	nameplate moved out -- and that split immediately broke every bot, because
	the barrel and hopper fell out of scope while setPosition still posed them.
	check-characters caught it on the next run. The remainder is a single linear
	assembly of one object and shredding it further would trade a readable
	sequence for a scatter of helpers called once each.
]]
local LONG_BUILDER_ALLOWED: { [string]: string } = {
	["BotAvatar.new"] = "one linear character assembly; rig and nameplate already extracted",
	["NoticeBoard.build"] = "one linear board assembly; splitting it would scatter the layout",
}

--------------------------------------------------------------------------------

type Finding = { rule: string, where: string, detail: string }

local advisories: { Finding } = {}
local function advise(rule: string, where: string, detail: string)
	table.insert(advisories, { rule = rule, where = where, detail = detail })
end

local findings: { Finding } = {}
local function fail(rule: string, where: string, detail: string)
	table.insert(findings, { rule = rule, where = where, detail = detail })
end

local files: { string } = {}
local function walk(path: string)
	for _, entry in ipairs(fs.readDir(path)) do
		local file = path .. "/" .. entry
		if fs.isDir(file) then
			walk(file)
		elseif entry:match("%.luau$") then
			table.insert(files, file)
		end
	end
end
walk("src")

local sources: { [string]: string } = {}
for _, file in ipairs(files) do
	sources[file] = fs.readFile(file)
end

--- Vendored code is not ours to restyle.
local function isOurs(file: string): boolean
	return not string.find(file, "Vendor", 1, true)
end

local function basename(file: string): string
	local name = string.match(file, "([^/]+)%.luau$")
	return name or file
end

--------------------------------------------------------------------------------
-- Rule 10: strict mode
--------------------------------------------------------------------------------
for file, text in pairs(sources) do
	if isOurs(file) and not string.match(text, "^%-%-!strict") then
		fail("10", file, "does not open with --!strict")
	end
end

--------------------------------------------------------------------------------
-- Rule 1: goto, and recursion
--------------------------------------------------------------------------------
for file, text in pairs(sources) do
	if isOurs(file) then
		-- `goto` as a statement, not a table field called goto.
		for line in string.gmatch(text, "[^\n]+") do
			if string.match(line, "^%s*goto%s+%a") then
				fail("1", file, "uses goto")
			end
		end
	end
end

for file, text in pairs(sources) do
	if isOurs(file) then
		for owner, name, body in string.gmatch(text, "\nfunction ([%a_][%w_]*)%.([%a_][%w_]*)%b()(.-)\nend") do
			local key = `{owner}.{name}`
			if string.find(body, `{owner}.{name}(`, 1, true) and not RECURSION_ALLOWED[key] then
				fail("1", file, `{key} recurses with no documented bound`)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Rule 2: unbounded loops
--------------------------------------------------------------------------------
for file, text in pairs(sources) do
	if isOurs(file) then
		local number = 0
		local previous = ""
		for line in string.gmatch(text, "[^\n]*") do
			number += 1
			if string.match(line, "while%s+true%s+do") then
				-- A heartbeat yields. A spin lock does not, and will hang a server.
				local window = string.sub(text, (string.find(text, line, 1, true) or 1), (string.find(text, line, 1, true) or 1) + 400)
				if not string.find(window, "task.wait", 1, true) and not string.find(window, ":Wait()", 1, true) then
					fail("2", `{file}:{number}`, "while true with no yield")
				end
			end
			previous = line
		end
	end
end

--------------------------------------------------------------------------------
-- Rule 4: function length
--------------------------------------------------------------------------------
--[[
	This rule measured nothing for the life of the project.

	Two bugs, and it reported "every rule holds" through both. It split lines
	with `gmatch("[^\n]*")`, which yields an empty match after every line and
	counted 2,666 lines in a 1,352-line file -- so every line number it printed
	was roughly doubled, and it happily reported a function at line 2280 of a
	file that ends at 1352. And it popped its function stack on ANY line that
	looked like an `end`, so the first `if` or `for` inside a function closed
	the function as far as this rule was concerned. It measured
	MatchService.start -- 1,171 lines -- as 82.

	Extent is taken from indentation now, which is what this codebase actually
	guarantees: a function's matching `end` sits at exactly the indent of its
	`function` keyword. That is immune to the `if x then a else b` expressions
	this project uses everywhere, which a keyword counter cannot tell from a
	block. Block comments are blanked first, preserving their newlines so line
	numbers stay true.
]]
local function stripBlockComments(text: string): string
	return (string.gsub(text, "%-%-%[%[.-%]%]", function(block: string): string
		local _, newlines = string.gsub(block, "\n", "")
		return string.rep("\n", newlines)
	end))
end

local function splitLines(text: string): { string }
	local out: { string } = {}
	for line in string.gmatch(text .. "\n", "(.-)\n") do
		table.insert(out, line)
	end
	return out
end

--- Where a function opens, and what it is called.
local function opensFunction(line: string): (string?, string?)
	local indent, label = string.match(line, "^(\t*)function%s+([%w_.:]+)")
	if indent then
		return indent, label
	end
	indent, label = string.match(line, "^(\t*)local function%s+([%w_]+)")
	if indent then
		return indent, label
	end
	indent = string.match(line, "^(\t*)[^%s].*=%s*function%s*%(")
	if indent then
		return indent, (string.match(line, "([%w_]+)%s*=%s*function") or "anonymous")
	end
	return nil, nil
end

local measured: { { length: number, label: string, file: string, at: number } } = {}
for file, text in pairs(sources) do
	if isOurs(file) then
		local lines = splitLines(stripBlockComments(text))
		for index, line in ipairs(lines) do
			local indent, label = opensFunction(line)
			if indent and label then
				for j = index + 1, #lines do
					if string.match(lines[j], "^" .. indent .. "end[,%)%s]*$") then
						table.insert(measured, { length = j - index + 1, label = label, file = file, at = index })
						break
					end
				end
			end
		end
	end
end

table.sort(measured, function(a, b): boolean
	return a.length > b.length
end)

for _, entry in ipairs(measured) do
	local where = `{entry.file}:{entry.at}`
	local frozen = KNOWN_LONG[entry.label]
	if frozen then
		--[[
			The ratchet. These were already over the limit when the rule started
			working, and each is frozen at the length it was measured at. They
			may shrink; they may not grow. That is what stops a fourteen-item
			backlog quietly becoming a fifteen-item one, without pretending the
			backlog is not there.
		]]
		if entry.length > frozen then
			fail("4", where, `{entry.label} grew to {entry.length} lines, over its frozen {frozen}`)
		end
	elseif entry.length > MAX_FUNCTION_LINES then
		fail("4", where, `{entry.label} is {entry.length} lines (hard limit {MAX_FUNCTION_LINES})`)
	elseif entry.length > ADVISORY_FUNCTION_LINES then
		advise("4", where, `{entry.label} is {entry.length} lines`)
	end
end

--------------------------------------------------------------------------------
-- Reachability: every export has a call site
--------------------------------------------------------------------------------
local corpus = {}
for _, dir in ipairs({ "src", "tools", "tests" }) do
	local scan: { string } = {}
	local function collect(path: string)
		for _, entry in ipairs(fs.readDir(path)) do
			local file = path .. "/" .. entry
			if fs.isDir(file) then
				collect(file)
			elseif entry:match("%.luau$") then
				table.insert(scan, fs.readFile(file))
			end
		end
	end
	collect(dir)
	for _, text in ipairs(scan) do
		-- Strip definition lines so a definition cannot count as its own call.
		for line in string.gmatch(text, "[^\n]+") do
			if not string.match(line, "^%s*function%s+[%a_][%w_]*[.:]") then
				table.insert(corpus, line)
			end
		end
	end
end
local haystack = table.concat(corpus, "\n")

for file, text in pairs(sources) do
	if isOurs(file) then
		for owner, name in string.gmatch(text, "\nfunction ([%a_][%w_]*)[.:]([%a_][%w_]*)%b()") do
			local key = `{owner}.{name}`
			if string.sub(name, 1, 1) ~= "_" and not UNCALLED_ALLOWED[key] then
				if not string.find(haystack, `.{name}`, 1, true) and not string.find(haystack, `:{name}`, 1, true) then
					fail("reach", basename(file), `{key} is exported and never called`)
				end
			end
		end
	end
end

--------------------------------------------------------------------------------

print("\27[1mcheck-static\27[0m  Power of 10 (the rules that translate) + reachability")
print(`  {#files} modules, {ADVISORY_FUNCTION_LINES}-line advisory, {MAX_FUNCTION_LINES}-line hard limit`)

if #advisories > 0 then
	print(`\n  {#advisories} function(s) over {ADVISORY_FUNCTION_LINES} lines (advisory, not a failure):`)
	table.sort(advisories, function(a: Finding, b: Finding): boolean
		return a.where < b.where
	end)
	for _, entry in ipairs(advisories) do
		print(`    {entry.where}  {entry.detail}`)
	end
end

if #findings == 0 then
	print("\n\27[32mevery rule holds.\27[0m")
	local allowed = 0
	for _ in pairs(RECURSION_ALLOWED) do
		allowed += 1
	end
	for _ in pairs(UNCALLED_ALLOWED) do
		allowed += 1
	end
	print(`  {allowed} documented exceptions, each with a stated reason.`)
	return
end

table.sort(findings, function(a: Finding, b: Finding): boolean
	if a.rule ~= b.rule then
		return a.rule < b.rule
	end
	return a.where < b.where
end)
print("")
for _, finding in ipairs(findings) do
	print(string.format("  \27[31mrule %-5s\27[0m %-46s %s", finding.rule, finding.where, finding.detail))
end
print(`\n\27[31m{#findings} finding(s).\27[0m`)
process.exit(1)
