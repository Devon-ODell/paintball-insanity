--!strict
--[[
	ShotLog -- the per-session record of every authoritative shot.

	Pure: it holds data and computes derived measurements, but it never touches a
	service, a clock or an Instance. The caller supplies `t`. That is what lets
	the headless sim produce byte-identical telemetry to a live match.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)

local ShotLog = {}
ShotLog.__index = ShotLog

export type Log = typeof(setmetatable(
	{} :: {
		map: Types.MapId,
		marker: string,
		tier: Types.BotTier,
		shots: { Types.ShotRecord },
		eliminations: { Types.EliminationRecord },
		deaths: { number },
		nextShotId: number,
		truncated: number,
		_lastEliminationT: number?,
		_streak: number,
		_longestStreak: number,
	},
	ShotLog
))

function ShotLog.new(map: Types.MapId, marker: string, tier: Types.BotTier): Log
	return setmetatable({
		map = map,
		marker = marker,
		tier = tier,
		shots = {},
		eliminations = {},
		deaths = {},
		nextShotId = 1,
		truncated = 0,
		_lastEliminationT = nil,
		_streak = 0,
		_longestStreak = 0,
	}, ShotLog) :: any
end

export type ShotInput = {
	t: number,
	stance: Types.Stance,
	distance: number,
	hit: boolean,
	eliminated: boolean,
	targetId: string?,
	angularErrorDeg: number,
	leadErrorM: number?,
	holdoverErrorM: number?,
	targetLateralSpeed: number,
	timeToAcquireMs: number?,
	targetVisibleMsBeforeShot: number?,
	crosshairOffsetDegAtReveal: number?,
	priorAimSwingDeg: number?,
}

--- Records one shot. Returns the record so callers can attach it to a replay.
function ShotLog.record(self: Log, input: ShotInput): Types.ShotRecord
	local cap = Config.require("telemetry", "session.maxShotRecords")

	local record: Types.ShotRecord = {
		shotId = self.nextShotId,
		t = input.t,
		map = self.map,
		marker = self.marker,
		stance = input.stance,
		shooterMoving = input.stance == "moving" or input.stance == "sprinting",
		distance = input.distance,
		hit = input.hit,
		eliminated = input.eliminated,
		targetId = input.targetId,
		angularErrorDeg = input.angularErrorDeg,
		leadErrorM = input.leadErrorM,
		holdoverErrorM = input.holdoverErrorM,
		targetLateralSpeed = input.targetLateralSpeed,
		timeToAcquireMs = input.timeToAcquireMs,
		targetVisibleMsBeforeShot = input.targetVisibleMsBeforeShot,
		crosshairOffsetDegAtReveal = input.crosshairOffsetDegAtReveal,
		priorAimSwingDeg = input.priorAimSwingDeg,
	}
	self.nextShotId += 1

	if #self.shots >= cap then
		-- Drop the oldest rather than refusing the newest: a long grind should
		-- still report accurately on how it ended.
		table.remove(self.shots, 1)
		self.truncated += 1
	end
	table.insert(self.shots, record)

	if input.eliminated and input.targetId then
		local previous = self._lastEliminationT
		table.insert(self.eliminations, {
			t = input.t,
			targetId = input.targetId,
			distance = input.distance,
			msSincePreviousElimination = if previous then (input.t - previous) * 1000 else nil,
		})
		self._lastEliminationT = input.t
		self._streak += 1
		if self._streak > self._longestStreak then
			self._longestStreak = self._streak
		end
	end

	return record
end

--- Records a player elimination. Breaks the streak; costs payout, not progress.
function ShotLog.recordDeath(self: Log, t: number)
	table.insert(self.deaths, t)
	self._streak = 0
	-- A death also breaks the elimination cadence, so target-switching timing
	-- does not get credited across a respawn.
	self._lastEliminationT = nil
end

function ShotLog.hitCount(self: Log): number
	local n = 0
	for _, s in ipairs(self.shots) do
		if s.hit then
			n += 1
		end
	end
	return n
end

function ShotLog.shotCount(self: Log): number
	return #self.shots + self.truncated
end

function ShotLog.longestStreak(self: Log): number
	return self._longestStreak
end

--- Plain-table form for JSON dumps out of the sim harness.
function ShotLog.toTable(self: Log): any
	return {
		map = self.map,
		marker = self.marker,
		tier = self.tier,
		shots = self.shots,
		eliminations = self.eliminations,
		deaths = self.deaths,
		truncated = self.truncated,
		longestStreak = self._longestStreak,
	}
end

return ShotLog
