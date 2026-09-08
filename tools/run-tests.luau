--!nolint
--[[
	Headless spec runner.

	    lune run tools/run-tests            -- everything
	    lune run tools/run-tests Ballistics -- only specs whose name matches
	    lune run tools/run-tests Sim --case=spawns -- one matching test

	This is the primary verification signal for the project. Studio is used only
	to look at the game; correctness is decided here.
]]

local process = require("@lune/process")
local Harness = require("./Harness")
local Expect = require("./Expect")

local filter = if process.args[1] and process.args[1]:sub(1, 2) ~= "--" then process.args[1] else nil

local caseFilter: string? = nil
for _, argument in ipairs(process.args) do
	if argument:sub(1, 7) == "--case=" then caseFilter = argument:sub(8) end
end

local env = Harness.build()
local G = env.globals

-- Specs are the signal; gameplay logging is not. Pass --verbose to see it.
do
	local Log = env.require(env.ReplicatedStorage.Shared.Log)
	local verbose = false
	for _, a in ipairs(process.args) do
		if a == "--verbose" then
			verbose = true
		end
	end
	Log.setLevel(if verbose then "verbose" else "error")
end

local currentSuite: { any } = {}
local results = { passed = 0, failed = 0, skipped = 0 }
local failures: { { name: string, err: string } } = {}
-- A root frame so beforeEach/afterEach work at the top level of a spec file,
-- not only inside a describe block. TestEZ allows both.
local hooks: { { before: { any }, after: { any } } } = { { before = {}, after = {} } }

local function path(): string
	return table.concat(currentSuite, " > ")
end

local function runHooks(kind: string)
	for _, frame in ipairs(hooks) do
		for _, fn in ipairs(frame[kind]) do
			fn()
		end
	end
end

G.describe = function(name: string, body: () -> ())
	table.insert(currentSuite, name)
	table.insert(hooks, { before = {}, after = {} })
	local ok, err = pcall(body)
	if not ok then
		results.failed += 1
		table.insert(failures, { name = path(), err = tostring(err) })
	end
	table.remove(hooks)
	table.remove(currentSuite)
end

G.it = function(name: string, body: () -> ())
	table.insert(currentSuite, name)
	local label = path()
	if caseFilter and not label:find(caseFilter, 1, true) then
		results.skipped += 1
		table.remove(currentSuite)
		return
	end
	local ok, err = pcall(function()
		runHooks("before")
		body()
		runHooks("after")
	end)
	if ok then
		results.passed += 1
		print(`  \27[32mPASS\27[0m {label}`)
	else
		results.failed += 1
		table.insert(failures, { name = label, err = tostring(err) })
		print(`  \27[31mFAIL\27[0m {label}`)
	end
	table.remove(currentSuite)
end

G.itFIXME = function(name: string)
	results.skipped += 1
	print(`  \27[33mSKIP\27[0m {name}`)
end
G.itSKIP = G.itFIXME

G.beforeEach = function(fn: () -> ())
	table.insert(hooks[#hooks].before, fn)
end
G.afterEach = function(fn: () -> ())
	table.insert(hooks[#hooks].after, fn)
end
G.beforeAll = G.beforeEach
G.afterAll = G.afterEach

G.expect = Expect.expect
G.FOCUS = function() end
G.SKIP = function() end

local specs = {}
for _, node in ipairs((env.Tests :: any):GetDescendants()) do
	if node.ClassName == "ModuleScript" and node.Name:match("%.spec$") then
		table.insert(specs, node)
	end
end
table.sort(specs, function(a, b)
	return a:GetFullName() < b:GetFullName()
end)

local startClock = os.clock()
local ran = 0
for _, spec in ipairs(specs) do
	if filter and not spec.Name:lower():find(filter:lower(), 1, true) then
		continue
	end
	ran += 1
	print(`\27[1m{spec.Name:gsub("%.spec$", "")}\27[0m`)
	hooks = { { before = {}, after = {} } }
	local ok, body = pcall(env.require, spec)
	if not ok then
		results.failed += 1
		table.insert(failures, { name = spec.Name, err = tostring(body) })
		print(`  \27[31mLOAD FAIL\27[0m {body}`)
		continue
	end
	if type(body) ~= "function" then
		results.failed += 1
		table.insert(failures, { name = spec.Name, err = "spec module must return a function" })
		continue
	end
	local okRun, err = pcall(body)
	if not okRun then
		results.failed += 1
		table.insert(failures, { name = spec.Name, err = tostring(err) })
		print(`  \27[31mFAIL\27[0m {err}`)
	end
end

local elapsed = os.clock() - startClock

print("")
if #failures > 0 then
	print("\27[1mFailures\27[0m")
	for _, f in ipairs(failures) do
		print(`  \27[31m{f.name}\27[0m`)
		print(`    {f.err}`)
	end
	print("")
end

print(string.format(
	"%d spec file(s)  \27[32m%d passed\27[0m  %s%d failed\27[0m  %d skipped  (%.2fs)",
	ran,
	results.passed,
	if results.failed > 0 then "\27[31m" else "",
	results.failed,
	results.skipped,
	elapsed
))

if results.failed > 0 then
	process.exit(1)
end
