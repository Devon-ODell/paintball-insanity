--!strict
--[[
	Units -- the only place studs and metres are allowed to meet.

	Ballistics, telemetry, tuning data and every number a designer reads are in
	metres. Roblox is in studs. Convert here, at the boundary, and nowhere else.
]]

local Config = require(script.Parent.Config)

local Units = {}

local function factor(): number
	return Config.require("ballistics", "studsPerMetre")
end

function Units.metresToStuds(m: number): number
	return m * factor()
end

function Units.studsToMetres(s: number): number
	return s / factor()
end

function Units.vectorToStuds(v: Vector3): Vector3
	return v * factor()
end

function Units.vectorToMetres(v: Vector3): Vector3
	return v / factor()
end

--- Roblox reports character speed in studs/s; nearly every design conversation
--- about lead is in m/s. Named explicitly so call sites read correctly.
function Units.speedToMetres(studsPerSecond: number): number
	return studsPerSecond / factor()
end

return Units
