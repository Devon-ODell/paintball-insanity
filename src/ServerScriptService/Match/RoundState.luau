--!strict
--[[
	RoundState -- the round's phase machine, kept separate from the simulation.

	warmup -> live -> summary -> done

	Small on purpose. The interesting behaviour is in the bots and the ballistics;
	round flow just needs to be unambiguous about when shots count, when the
	clock runs and when payouts are computed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local RoundState = {}
RoundState.__index = RoundState

export type Phase = "warmup" | "live" | "summary" | "done"

export type State = typeof(setmetatable(
	{} :: {
		phase: Phase,
		elapsed: number,
		liveElapsed: number,
		roundIndex: number,
		warmupSeconds: number,
		timeLimit: number,
		listeners: { (Phase) -> () },
	},
	RoundState
))

function RoundState.new(): State
	local matchData = Config.get("match")
	return setmetatable({
		phase = "warmup" :: Phase,
		elapsed = 0,
		liveElapsed = 0,
		roundIndex = 0,
		warmupSeconds = matchData.warmupSeconds,
		timeLimit = matchData.roundTimeLimitSeconds,
		listeners = {},
	}, RoundState) :: any
end

function RoundState.onPhase(self: State, fn: (Phase) -> ())
	table.insert(self.listeners, fn)
	fn(self.phase)
end

local function setPhase(self: State, phase: Phase)
	if self.phase == phase then
		return
	end
	self.phase = phase
	for _, fn in ipairs(self.listeners) do
		fn(phase)
	end
end

RoundState.setPhase = setPhase

--[[
	Starts a fresh round inside the same match.

	A match is five rounds; the phase machine tracks the CURRENT one. Match-level
	elapsed time keeps running so the summary can report how long the whole thing
	took, while the round clock -- the one the time limit is measured against --
	restarts.
]]
function RoundState.beginRound(self: State, timeLimit: number?)
	self.liveElapsed = 0
	self.roundIndex += 1
	if timeLimit then
		self.timeLimit = timeLimit
	end
	setPhase(self, "live")
end

--- Advances the clock. Returns true while the round should keep simulating.
function RoundState.step(self: State, dt: number): boolean
	self.elapsed += dt
	if self.phase == "warmup" then
		if self.elapsed >= self.warmupSeconds then
			setPhase(self, "live")
		end
		return true
	elseif self.phase == "live" then
		self.liveElapsed += dt
		if self.liveElapsed >= self.timeLimit then
			setPhase(self, "summary")
			return false
		end
		return true
	end
	return false
end

--- Shots only count once the round is live. A warmup shot is a warmup shot.
function RoundState.shotsCount(self: State): boolean
	return self.phase == "live"
end

function RoundState.finish(self: State)
	setPhase(self, "summary")
end

function RoundState.close(self: State)
	setPhase(self, "done")
end

return RoundState
