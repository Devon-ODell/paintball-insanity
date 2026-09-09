--!nolint
--[[
	Every automated gate, in one command, on any operating system.

	    lune run tools/check-all

	`Check Release.command` is a macOS shell script and was the only thing that
	knew the full list of gates. Anyone cloning this on Windows or Linux had to
	read that script and translate it, which is exactly the kind of thing that
	gets a gate quietly skipped -- check-budget was already missing from it once,
	and a shadow regression shipped through the gap.

	Lune runs identically on all three platforms, so the list lives here now and
	the shell script just calls this.

	Exits non-zero if any gate fails, and prints a summary rather than dumping
	every gate's output -- a failing gate's own output is shown in full, the
	passing ones are one line each.
]]

local process = require("@lune/process")

type Gate = { id: string, why: string }

--[[
	Ordered cheapest-first, so a syntax error surfaces in two seconds rather
	than after the seven-minute spec suite.
]]
local GATES: { Gate } = {
	{ id = "check-source", why = "Luau syntax across every module" },
	{ id = "check-static", why = "Power of 10 rules that translate, plus reachability" },
	{ id = "ship-check", why = "release configuration: dev flags, modes, monetization" },
	{ id = "check-budget", why = "part, shadow and alpha budgets per scene" },
	{ id = "check-zfight", why = "coplanar surfaces that shimmer in motion" },
	{ id = "check-characters", why = "every bot and civilian builds" },
	{ id = "check-gait", why = "the walk cycle moves with the ground" },
	{ id = "check-inflatables", why = "speedball bunker geometry and budgets" },
	{ id = "check-client-ui", why = "HUD, shop, dialogue, tracers, input" },
	{ id = "check-range", why = "drives a full aim drill end to end" },
	{ id = "check-demo-world", why = "all five maps, lighting and decoration" },
	{ id = "check-persistence", why = "profile migration, saves, session loss" },
	{ id = "run-profile-checks", why = "persistence adapter against a mock store" },
	{ id = "run-live-checks", why = "MatchService against a mock engine" },
	{ id = "run-tests", why = "the spec suite -- slowest, run last" },
}

--[[
	Where lune is.

	Rokit puts it on PATH, which is the documented setup and the common case.
	The fallback is the path this project's own shell scripts have always used,
	so a machine set up before Rokit still works. LUNE overrides both.
]]
local function luneBinary(): string
	local override = process.env.LUNE
	if override and #override > 0 then
		return override
	end
	local probe = process.exec("lune", { "--version" })
	if probe.ok then
		return "lune"
	end
	local home = process.env.HOME or process.env.USERPROFILE or ""
	return home .. "/.local/bin/lune"
end

local lune = luneBinary()

print("\27[1mcheck-all\27[0m  " .. #GATES .. " gates on " .. process.os .. "/" .. process.arch)
print("  using: " .. lune)
print("")

local failed: { { id: string, output: string } } = {}

for index, gate in ipairs(GATES) do
	local label = string.format("  [%2d/%d] %-22s", index, #GATES, gate.id)
	local result = process.exec(lune, { "run", "tools/" .. gate.id })
	if result.ok then
		print(label .. "\27[32mok\27[0m   " .. gate.why)
	else
		print(label .. "\27[31mFAILED\27[0m")
		table.insert(failed, { id = gate.id, output = result.stdout .. result.stderr })
	end
end

print("")

if #failed == 0 then
	print("\27[32mevery automated gate passed.\27[0m")
	print("The Studio and published-service gates in docs/PUBLISH_READINESS.md are")
	print("separate and none of them is covered by anything above.")
	return
end

for _, entry in ipairs(failed) do
	print("\27[1m--- " .. entry.id .. " ---\27[0m")
	print(entry.output)
end

print(string.format("\27[31m%d of %d gates failed.\27[0m", #failed, #GATES))
process.exit(1)
