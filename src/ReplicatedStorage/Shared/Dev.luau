--!strict
--[[
	Dev -- the single gate for every development override.

	No module reads Data/dev.json directly. They ask here, and here is the one
	place that checks the master `enabled` switch, so switching a shipping build
	back to honest behaviour is one boolean rather than an audit.

	Every flag defaults to OFF if the file is missing or malformed. A dev
	convenience that fails open would be a live exploit.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.scope("LiveRound.Dev")

local Dev = {}

local announced = false
local testOverride: any = nil

local function data(): any
	if testOverride ~= nil then
		return testOverride
	end
	local ok, value = pcall(function()
		return Config.get("dev")
	end)
	if not ok or type(value) ~= "table" then
		return { enabled = false }
	end
	return value
end

--[[
	Test seam. Specs assert SHIPPING behaviour by default, so the suite pins the
	overrides off and then turns individual flags on in the one block that is
	actually about them. Without this, leaving a flag on in Data/dev.json would
	quietly rewrite what the economy specs mean.
]]
function Dev._setOverrideForTesting(config: any?)
	testOverride = config
end

--- True when the master switch is on AND this specific flag is on.
function Dev.flag(name: string): boolean
	local cfg = data()
	if cfg.enabled ~= true then
		return false
	end
	local entry = cfg[name]
	return type(entry) == "table" and entry.on == true
end

--- A value from a flag's config block, or `fallback` when the flag is off.
function Dev.value(name: string, key: string, fallback: any): any
	if not Dev.flag(name) then
		return fallback
	end
	local entry = data()[name]
	local value = entry[key]
	if value == nil then
		return fallback
	end
	return value
end

function Dev.isEnabled(): boolean
	return data().enabled == true
end

--[[
	Prints the banner once at server boot.

	Deliberately loud and deliberately unconditional on the flag list: the whole
	risk with dev overrides is forgetting one is on, so the server says exactly
	which ones are active every single time it starts.
]]
function Dev.announce()
	if announced then
		return
	end
	announced = true
	if not Dev.isEnabled() then
		log.info("dev overrides: none (shipping behaviour)")
		return
	end

	local active: { string } = {}
	for name, entry in pairs(data()) do
		if type(entry) == "table" and entry.on == true then
			table.insert(active, name)
		end
	end
	table.sort(active)

	log.warn("================================================")
	log.warn("  DEVELOPMENT OVERRIDES ARE ACTIVE")
	if #active == 0 then
		log.warn("  (master switch on, no individual flags set)")
	end
	for _, name in ipairs(active) do
		log.warn(`    - {name}`)
	end
	log.warn("  Set Data/dev.json enabled = false before shipping.")
	log.warn("================================================")
end

return Dev
