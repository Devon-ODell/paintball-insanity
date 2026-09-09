--!nolint
--[[
	Harness.luau -- a miniature Roblox module runtime for Lune.

	Builds a virtual Instance tree out of the filesystem the same way Rojo builds
	the real one, then implements `require(instance)` on top of luau.load. This is
	what lets every spec in tests/ run headless from the shell against the exact
	same source that Rojo syncs into Studio.

	Mapping rules (matching default.project.json):
	  src/ReplicatedStorage/Shared -> ReplicatedStorage.Shared
	  src/ReplicatedStorage/Net    -> ReplicatedStorage.Net
	  Data                         -> ReplicatedStorage.Data
	  src/ServerScriptService      -> ServerScriptService.Server
	  tests                        -> ReplicatedStorage.Tests

	File rules (matching Rojo 7):
	  Foo.luau        -> ModuleScript "Foo"
	  Foo.server.luau -> Script "Foo"
	  Foo.client.luau -> LocalScript "Foo"
	  Foo.json        -> ModuleScript "Foo" returning the decoded table
	  init.luau       -> the directory itself becomes the ModuleScript
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")

local Harness = {}

export type Node = any

local ROOT = (function()
	-- Resolve the repo root from this file's location so the harness works
	-- regardless of the shell's working directory.
	local cwd = require("@lune/process").cwd
	return (cwd:gsub("/$", ""))
end)()

--------------------------------------------------------------------------------
-- Virtual instance
--------------------------------------------------------------------------------

local NodeMT = {}

local function newNode(name: string, className: string): Node
	local node = {
		Name = name,
		ClassName = className,
		Parent = nil,
		_children = {} :: { [string]: Node },
		_order = {} :: { Node },
		_source = nil :: string?,
		_json = nil :: any,
		_loaded = false,
		_result = nil :: any,
	}
	return setmetatable(node, NodeMT)
end

local function addChild(parent: Node, child: Node)
	if parent._children[child.Name] then
		error(`duplicate instance name '{child.Name}' under '{parent.Name}'`)
	end
	parent._children[child.Name] = child
	table.insert(parent._order, child)
	child.Parent = parent
end

local NodeMethods = {}

function NodeMethods.FindFirstChild(self: Node, name: string): Node?
	return self._children[name]
end

function NodeMethods.WaitForChild(self: Node, name: string): Node
	local c = self._children[name]
	if not c then
		error(`WaitForChild('{name}') would block forever under '{self:GetFullName()}'`)
	end
	return c
end

function NodeMethods.GetChildren(self: Node): { Node }
	local out = {}
	for i, c in ipairs(self._order) do
		out[i] = c
	end
	return out
end

function NodeMethods.GetDescendants(self: Node): { Node }
	local out = {}
	local function walk(n: Node)
		for _, c in ipairs(n._order) do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(self)
	return out
end

function NodeMethods.IsA(self: Node, className: string): boolean
	if self.ClassName == className then
		return true
	end
	if className == "LuaSourceContainer" then
		return self.ClassName == "ModuleScript"
			or self.ClassName == "Script"
			or self.ClassName == "LocalScript"
	end
	return className == "Instance"
end

function NodeMethods.GetFullName(self: Node): string
	local parts = { self.Name }
	local p = self.Parent
	while p do
		table.insert(parts, 1, p.Name)
		p = p.Parent
	end
	return table.concat(parts, ".")
end

function NodeMT.__index(self: Node, key: string): any
	local m = NodeMethods[key]
	if m then
		return m
	end
	return rawget(self, "_children")[key]
end

function NodeMT.__tostring(self: Node): string
	return self.Name
end

--------------------------------------------------------------------------------
-- Tree construction
--------------------------------------------------------------------------------

local function classForFile(fileName: string): (string?, string?)
	local base = fileName:match("^(.*)%.server%.luau$")
	if base then
		return base, "Script"
	end
	base = fileName:match("^(.*)%.client%.luau$")
	if base then
		return base, "LocalScript"
	end
	base = fileName:match("^(.*)%.luau$")
	if base then
		return base, "ModuleScript"
	end
	base = fileName:match("^(.*)%.json$")
	if base then
		return base, "JsonModule"
	end
	base = fileName:match("^(.*)%.rbxmx$")
	if base then return base, "ArtModel" end
	return nil, nil
end

local buildDir

function buildDir(diskPath: string, name: string): Node
	local initPath = diskPath .. "/init.luau"
	local node: Node
	if fs.isFile(initPath) then
		node = newNode(name, "ModuleScript")
		node._source = fs.readFile(initPath)
		node._diskPath = initPath
	else
		node = newNode(name, "Folder")
	end

	local entries = fs.readDir(diskPath)
	table.sort(entries)
	for _, entry in ipairs(entries) do
		if entry == "init.luau" then
			continue
		end
		local full = diskPath .. "/" .. entry
		if fs.isDir(full) then
			addChild(node, buildDir(full, entry))
		else
			local base, class = classForFile(entry)
			if base and class == "ArtModel" then
				local roots = roblox.deserializeModel(fs.readFile(full))
				assert(#roots == 1, "Art files must contain one root: " .. full)
				roots[1].Name = base
				-- Actual Instances retain mesh content and SurfaceAppearance data.
				node._children[base] = roots[1]
				table.insert(node._order, roots[1])
				continue
			end
			if base and class then
				local child = newNode(base, if class == "JsonModule" then "ModuleScript" else class)
				child._diskPath = full
				if class == "JsonModule" then
					child._json = serde.decode("json", fs.readFile(full))
				else
					child._source = fs.readFile(full)
				end
				addChild(node, child)
			end
		end
	end
	return node
end

--------------------------------------------------------------------------------
-- DataModel assembly + require
--------------------------------------------------------------------------------

export type Env = {
	game: Node,
	ReplicatedStorage: Node,
	ServerScriptService: Node,
	require: (Node) -> any,
	Shared: Node,
	Data: Node,
	Server: Node,
	Tests: Node?,
	globals: { [string]: any },
}

function Harness.build(repoRoot: string?): Env
	local root = repoRoot or ROOT

	local dataModel = newNode("game", "DataModel")

	local rs = newNode("ReplicatedStorage", "ReplicatedStorage")
	addChild(dataModel, rs)
	addChild(rs, buildDir(root .. "/src/ReplicatedStorage/Shared", "Shared"))
	addChild(rs, buildDir(root .. "/src/ReplicatedStorage/Net", "Net"))
	addChild(rs, buildDir(root .. "/Data", "Data"))
	-- Headless runs deliberately use the same temporary-data switch as the demo.
	local demoMode = newNode("DemoMode", "BoolValue")
	demoMode.Value = true
	addChild(rs, demoMode)

	local sss = newNode("ServerScriptService", "ServerScriptService")
	addChild(dataModel, sss)
	addChild(sss, buildDir(root .. "/src/ServerScriptService", "Server"))

	local tests: Node? = nil
	if fs.isDir(root .. "/tests") then
		tests = buildDir(root .. "/tests", "Tests")
		addChild(rs, tests :: Node)
	end

	local services: { [string]: Node } = {
		ReplicatedStorage = rs,
		ServerScriptService = sss,
	}

	function NodeMethods.GetService(self: Node, serviceName: string): Node
		local existing = services[serviceName]
		if existing then
			return existing
		end
		--[[
			Lighting is real, because world builders parent real instances into
			it. Handing back an inert stub made every map builder unrunnable
			headlessly -- Atmosphere.apply threw on `created.Parent = Lighting`
			and took the whole build with it.
		]]
		--[[
			SoundService joins them for the same reason: the audio graph is
			built out of real AudioPlayer, Wire and AudioDeviceOutput instances
			and parented into the service, and `realInstance.Parent = <table>`
			throws. Lune's API dump knows all of those classes, so the gate can
			assert the actual wiring rather than a stub of it -- which matters,
			because an AudioPlayer with no Wire is silent and reports nothing.
		]]
		if serviceName == "Lighting" or serviceName == "MaterialService"
			or serviceName == "SoundService" then
			local lighting = roblox.Instance.new(serviceName)
			services[serviceName] = lighting :: any
			return lighting :: any
		end

		-- Services a pure module should never touch still need to resolve so that
		-- a module can require-and-branch. They are inert stubs; touching one from
		-- a spec is a bug in the module, not the harness.
		local stub = newNode(serviceName, serviceName)
		addChild(dataModel, stub)
		services[serviceName] = stub
		return stub
	end

	local env: Env
	local sharedGlobals: { [string]: any } = {}

	local function harnessRequire(target: Node): any
		if type(target) ~= "table" or getmetatable(target) ~= NodeMT then
			error(`require() expects an Instance, got {typeof(target)}`, 2)
		end
		if target._loaded then
			return target._result
		end
		if target._json ~= nil then
			target._loaded = true
			target._result = target._json
			return target._result
		end
		if not target._source then
			error(`attempt to require a {target.ClassName}: {target:GetFullName()}`, 2)
		end

		-- Guard against require cycles, which Roblox also rejects.
		if target._loading then
			error(`require cycle detected at {target:GetFullName()}`, 2)
		end
		target._loading = true

		local chunkEnv = {
			script = target,
			game = dataModel,
			workspace = env and env.workspace or nil,
			require = harnessRequire,
			Vector3 = roblox.Vector3,
			Vector2 = roblox.Vector2,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			Region3 = roblox.Region3,
			Ray = roblox.Ray,
			-- Lune ships the real Roblox enum tree, so modules that reference
			-- Enum.Material or Enum.PartType at module scope load headlessly.
			Enum = roblox.Enum,
			--[[
				Real Roblox instances, backed by Lune's property database.

				Without this every world builder -- the barn, the foliage, the
				avatars, the wardrobe -- was unrunnable headlessly and could only
				be checked by reading it. It is the difference between "this
				compiles" and "this actually constructs", which for geometry code
				is most of the bugs.
			]]
			Instance = roblox.Instance,
			UDim = roblox.UDim,
			UDim2 = roblox.UDim2,
			Vector2int16 = roblox.Vector2int16,
			NumberSequence = roblox.NumberSequence,
			ColorSequence = roblox.ColorSequence,
			NumberRange = roblox.NumberRange,
			BrickColor = roblox.BrickColor,
			typeof = typeof,
			--[[
				Threads, emulated with coroutines rather than run inline.

				`spawn` used to just call the function, so a `while ... do
				task.wait() end` loop -- which is a perfectly ordinary way to
				drive a repeating job, and what NoticeBoard uses to cycle the
				leaderboard pages -- never yielded and span forever. The first
				tool to build the hub headlessly wrote a 679MB log before anyone
				noticed.

				A spawned function now runs on its own coroutine and `wait`
				yields it, which is what the engine does. The scheduler never
				resumes anything, so a repeating job runs up to its first wait
				and then stops -- exactly the amount of it a headless tool wants.
			]]
			task = {
				wait = function(n: number?)
					if coroutine.isyieldable() then
						coroutine.yield()
					end
					return n or 0
				end,
				spawn = function(fn: any, ...)
					local thread = coroutine.create(fn)
					local ok, err = coroutine.resume(thread, ...)
					if not ok then
						error(err, 2)
					end
					return thread
				end,
				defer = function(fn: any, ...)
					local thread = coroutine.create(fn)
					local ok, err = coroutine.resume(thread, ...)
					if not ok then
						error(err, 2)
					end
					return thread
				end,
				delay = function(_: number, fn: any, ...)
					local thread = coroutine.create(fn)
					local ok, err = coroutine.resume(thread, ...)
					if not ok then
						error(err, 2)
					end
					return thread
				end,
			},
			tick = os.clock,
			warn = function(...)
				local parts = {}
				for i = 1, select("#", ...) do
					parts[i] = tostring((select(i, ...)))
				end
				print("[warn] " .. table.concat(parts, " "))
			end,
		}

		-- luau.load does not honour a metatable on the environment table, so
		-- injected globals (the spec runner's describe/it/expect) are copied in
		-- at require time. Specs are required after the runner populates them.
		for key, value in pairs(sharedGlobals) do
			if chunkEnv[key] == nil then
				chunkEnv[key] = value
			end
		end

		local chunk = luau.load(target._source, {
			debugName = target._diskPath or target:GetFullName(),
			environment = chunkEnv,
			injectGlobals = true,
		})
		local result = chunk()
		target._loading = false
		target._loaded = true
		target._result = result
		return result
	end

	env = {
		game = dataModel,
		ReplicatedStorage = rs,
		ServerScriptService = sss,
		require = harnessRequire,
		Shared = rs.Shared,
		Data = rs.Data,
		Server = sss.Server,
		Tests = tests,
		globals = sharedGlobals,
	} :: any

	--[[
		Every gate asserts SHIPPING behaviour.

		Data/dev.json is a developer's local switch -- infinite money, an
		unkillable player, skipped rounds -- and a gate that read it would
		quietly stop testing the game the moment somebody turned it on. That is
		exactly what happened: with `invulnerable` on, run-live-checks' "one
		batch must only charge one player elimination" failed, because nothing
		could charge an elimination at all.

		So the overrides are pinned off here, once, for every tool the harness
		builds. A check that wants to test a flag turns it on itself, the way
		check-persistence and the Economy specs already do -- and the flag then
		reads as the subject of that check rather than as ambient state.
	]]
	harnessRequire(rs.Shared.Dev)._setOverrideForTesting({ enabled = false })

	return env
end

return Harness
