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
	["CaptureTheFlag.roleFor"] = "CTF is specced and deferred",
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
for file, text in pairs(sources) do
	if isOurs(file) then
		local lines: { string } = {}
		for line in string.gmatch(text, "[^\n]*") do
			table.insert(lines, line)
		end
		local open: { { number: number, label: string } } = {}
		for index, line in ipairs(lines) do
			if string.match(line, "^%s*function%s") or string.match(line, "^%s*local function%s")
				or string.match(line, "=%s*function%s*%(") then
				table.insert(open, { number = index, label = (string.match(line, "function%s+([%w_.:]+)") or "anonymous") })
			end
			if string.match(line, "^%s*end%s*$") or string.match(line, "^%s*end[,)%s]") then
				local entry = table.remove(open)
				if entry then
					local length = index - entry.number + 1
					if length > MAX_FUNCTION_LINES and not LONG_BUILDER_ALLOWED[entry.label] then
						fail("4", `{file}:{entry.number}`, `{entry.label} is {length} lines (hard limit {MAX_FUNCTION_LINES})`)
					elseif length > ADVISORY_FUNCTION_LINES then
						advise("4", `{file}:{entry.number}`, `{entry.label} is {length} lines`)
					end
				end
			end
		end
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
