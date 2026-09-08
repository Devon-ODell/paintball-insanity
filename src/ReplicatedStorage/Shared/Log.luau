--!strict
--[[
	Log -- scoped, level-filtered logging.

	CLAUDE.md requires every bot state transition to log through a
	`LiveRound.Bots` logger at verbose. Verbose is off by default so a live
	server is not writing a squad's worth of transitions to output every frame;
	the sim harness turns it on, which is where you actually want to read it.
]]

local Log = {}

export type Level = "verbose" | "info" | "warn" | "error" | "silent"

local ORDER: { [string]: number } = {
	verbose = 10,
	info = 20,
	warn = 30,
	error = 40,
	silent = 100,
}

local threshold = ORDER.info
local sink: ((level: Level, scope: string, message: string) -> ())? = nil

function Log.setLevel(level: Level)
	threshold = ORDER[level] or ORDER.info
end

function Log.getLevel(): number
	return threshold
end

--- Redirects output. The sim harness captures lines into its JSON dump instead
--- of printing them.
function Log.setSink(fn: ((level: Level, scope: string, message: string) -> ())?)
	sink = fn
end

export type Scope = {
	verbose: (message: string) -> (),
	info: (message: string) -> (),
	warn: (message: string) -> (),
	error: (message: string) -> (),
}

local function emit(level: Level, scopeName: string, message: string)
	if ORDER[level] < threshold then
		return
	end
	if sink then
		(sink :: any)(level, scopeName, message)
		return
	end
	local line = `[{scopeName}] {message}`
	if level == "warn" then
		warn(line)
	elseif level == "error" then
		warn("ERROR " .. line)
	else
		print(line)
	end
end

function Log.scope(name: string): Scope
	return {
		verbose = function(message: string)
			emit("verbose", name, message)
		end,
		info = function(message: string)
			emit("info", name, message)
		end,
		warn = function(message: string)
			emit("warn", name, message)
		end,
		error = function(message: string)
			emit("error", name, message)
		end,
	}
end

return Log
