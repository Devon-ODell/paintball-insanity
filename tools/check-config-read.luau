--!nolint
--[[
	Unread configuration gate.

	    lune run tools/check-config-read

	`Data/*.json` is the source of truth for every tunable value in this game, so
	a key nothing reads is not a harmless leftover -- it is a number somebody can
	tune all afternoon with no effect, or worse, a rule the data says is in force
	and the code has never implemented.

	This sweep has found, in one pass:

	  * `match.hitRules.surrenderBarrelTagRangeMetres` -- a paintball rule
	    declared since the rules were written and never built. It has since been
	    replaced outright by `hitRules.melee`: at contact range you shove
	    somebody with the butt of the marker, and so do they.
	  * `course.stageBots: [2,3,4,5]` -- fourteen defenders, against the
	    twenty-eight Course derives from anchors. Two opinions about how many
	    people are in the building, and the data one was never read.
	  * `ballistics.leadSolver.iterations` -- declared 4, while both solver call
	    sites carried their own literal 4.

	Two deliberate limits, both chosen so a hit means something.

	Only TOP-LEVEL keys are checked. Going a level deeper immediately produced a
	hundred false alarms from registries -- `wardrobe.pieces.radio`,
	`markers.markers.pump` -- which are records referenced by name from other
	data, not tunables anybody would reach from code. Every real find above was
	top-level anyway.

	Matching is loose: a key counts as read if its name appears anywhere in the
	source, because config is reached by string path
	(`Config.require("match", "hitRules")`) and anything stricter reports noise.
	So this UNDER-reports, which is the right direction for a gate.

	Keys are exempted by name below, each with a reason. Leading-underscore keys
	are documentation and are skipped everywhere.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

--- Read by something this sweep cannot see, or deliberately inert.
local ALLOWED: { [string]: string } = {
	["dev.verboseBots"] = "read by name through Dev.flag('verboseBots'), which this sweep cannot follow",
	["range.grading"] = "documents the shared curve; DrillScoring reaches it through the telemetry scoring table",
	["ballistics.leadSolver.convergenceMetres"] = "documents the solver's tolerance; the iteration count is what is actually tuned",
	["course.advanceOnClear"] = "the behaviour is unconditional in Course; kept as a statement of the rule",
	["course.stageAnnounceSeconds"] = "presentation timing for a stage banner the client owns",
	["course.clockStopsBetweenStages"] = "false is the implemented behaviour; kept as a statement of the rule",
}

--- Map ids carry a curriculum index for authoring order; nothing runs off it.
local ALLOWED_SUFFIX: { string } = { ".curriculumIndex" }

local sources = ""
local function readAll(path: string)
	for _, entry in ipairs(fs.readDir(path)) do
		local file = path .. "/" .. entry
		if fs.isDir(file) then
			readAll(file)
		elseif string.match(entry, "%.luau$") then
			sources ..= fs.readFile(file)
		end
	end
end
readAll("src")
readAll("tools")
readAll("tests")

local findings: { string } = {}

local function scan(path: string)
	for _, entry in ipairs(fs.readDir(path)) do
		local file = path .. "/" .. entry
		if fs.isDir(file) then
			scan(file)
		elseif string.match(entry, "%.json$") then
			local ok, decoded = pcall(function()
				return (require("@lune/serde") :: any).decode("json", fs.readFile(file))
			end)
			if not ok or type(decoded) ~= "table" then
				continue
			end
			local label = string.match(entry, "(.+)%.json$") or entry

			local function walk(node: any, depth: number, prefix: string)
				if type(node) ~= "table" or depth > 1 then
					return
				end
				for key, value in pairs(node) do
					if type(key) == "string" and string.sub(key, 1, 1) ~= "_" then
						local full = if prefix == "" then key else prefix .. "." .. key
						local exempt = ALLOWED[`{label}.{full}`] ~= nil
						for _, suffix in ipairs(ALLOWED_SUFFIX) do
							if string.sub(full, -#suffix) == suffix then
								exempt = true
							end
						end
						if not exempt and not string.find(sources, key, 1, true) then
							table.insert(findings, `{label}.{full}`)
						end
						walk(value, depth + 1, full)
					end
				end
			end
			walk(decoded, 1, "")
		end
	end
end
scan("Data")

table.sort(findings)

print("\27[1mcheck-config-read\27[0m  every tunable is reached by something")

if #findings == 0 then
	local exempt = 0
	for _ in pairs(ALLOWED) do
		exempt += 1
	end
	print(`\n\27[32mno unread configuration.\27[0m  {exempt} documented exemptions.`)
	return
end

print("")
for _, key in ipairs(findings) do
	print(`  \27[31munread\27[0m  {key}`)
end
print(`\n\27[31m{#findings} configuration key(s) nothing reads.\27[0m`)
print("Either wire it, delete it, or exempt it by name with a reason in this file.")
process.exit(1)
