--!strict
--[[
	Config -- the single door to Data/*.json.

	Rojo turns every Data/*.json file into a ModuleScript that returns the decoded
	table, so this module never parses anything; it locates, caches and validates.

	Rule from CLAUDE.md: nothing numeric is hardcoded in Luau. If you find yourself
	writing a number literal in gameplay code, it belongs in Data/ and it belongs
	behind this module.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = {}

local dataRoot = ReplicatedStorage:WaitForChild("Data")
local cache: { [string]: any } = {}

--- Fetches a top-level data file by name, e.g. Config.get("markers").
function Config.get(name: string): any
	local hit = cache[name]
	if hit ~= nil then
		return hit
	end
	local module = dataRoot:FindFirstChild(name)
	if not module then
		error(`Config: no Data/{name}.json`, 2)
	end
	local value = require(module :: ModuleScript)
	cache[name] = value
	return value
end

--- Fetches a map layout, e.g. Config.map("speedball").
function Config.map(name: string): any
	local hit = cache["maps/" .. name]
	if hit ~= nil then
		return hit
	end
	local maps = dataRoot:FindFirstChild("maps")
	if not maps then
		error("Config: Data/maps is missing", 2)
	end
	local module = maps:FindFirstChild(name)
	if not module then
		error(`Config: no Data/maps/{name}.json`, 2)
	end
	local value = require(module :: ModuleScript)
	cache["maps/" .. name] = value
	return value
end

--- Names of every map on disk, in the curriculum order declared by maps/index.
function Config.mapNames(): { string }
	return Config.get("maps_index").order
end

--- Reads a dotted path out of a data file and errors loudly if it is absent.
--- Config.require("markers", "markers.pump.muzzleVelocity")
function Config.require(file: string, path: string): any
	local node: any = Config.get(file)
	for segment in path:gmatch("[^%.]+") do
		if type(node) ~= "table" then
			error(`Config: {file}.json -> {path} ran off a non-table at '{segment}'`, 2)
		end
		node = node[segment]
		if node == nil then
			error(`Config: {file}.json is missing {path}`, 2)
		end
	end
	return node
end

--- Test seam. The sim harness and specs call this after mutating tuning tables.
function Config.clearCache()
	table.clear(cache)
end

return Config
