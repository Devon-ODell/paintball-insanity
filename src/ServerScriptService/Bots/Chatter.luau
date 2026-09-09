--!strict
--[[
	Chatter -- the enemy squad's voice.

	Deterministic: every line is drawn through the match's own generator, so a
	replayed seed produces the same trash talk in the same order. Lines are drawn
	WITHOUT replacement inside a bank so nobody repeats until the bank is
	exhausted, which is the difference between a comedy bank and a soundboard.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)
local Rng = require(ReplicatedStorage.Shared.Rng)

local Chatter = {}
Chatter.__index = Chatter

export type Line = { text: string, speaker: string, t: number, kind: string }

export type Bank = typeof(setmetatable(
	{} :: {
		rng: Rng.Generator,
		data: any,
		tier: Types.BotTier,
		names: { string },
		_drawn: { [string]: { number } },
		_lastLineT: number,
		_lineTimes: { number },
		history: { Line },
	},
	Chatter
))

function Chatter.new(tier: Types.BotTier, rng: Rng.Generator): Bank
	local data = Config.get("chatter")
	local roster = table.clone(data.roster)

	-- Shuffle the roster so the same six names are not always the squad.
	for i = #roster, 2, -1 do
		local j = rng:nextInt(1, i)
		roster[i], roster[j] = roster[j], roster[i]
	end

	local squadSize = Config.require("bots", "squad.size")
	local names = {}
	for i = 1, squadSize do
		names[i] = roster[i]
	end

	return setmetatable({
		rng = rng,
		data = data,
		tier = tier,
		names = names,
		_drawn = {},
		_lastLineT = -math.huge,
		_lineTimes = {},
		history = {},
	}, Chatter) :: any
end

function Chatter.squadNames(self: Bank): { string }
	return self.names
end

--- Draws an index from a bank without replacement, refilling when exhausted.
local function drawIndex(self: Bank, key: string, size: number): number
	local pool = self._drawn[key]
	if not pool or #pool == 0 then
		pool = {}
		for i = 1, size do
			pool[i] = i
		end
		self._drawn[key] = pool
	end
	local at = self.rng:nextInt(1, #pool)
	local index = pool[at]
	table.remove(pool, at)
	return index
end

local function fill(template: string, values: { [string]: string }): string
	return (template:gsub("{(%w+)}", function(k)
		return values[k] or ("{" .. k .. "}")
	end))
end

--- Morale bucket for a given number of living bots.
function Chatter.moraleFor(aliveCount: number): Types.MoraleState
	local thresholds = Config.require("bots", "morale.thresholds")
	for _, entry in ipairs(thresholds) do
		if aliveCount >= entry.atLeast then
			return entry.state
		end
	end
	return "broken"
end

--[[
	Rate limiting. Pros barely talk; rec bots will not shut up. Both are capped
	so a busy moment cannot produce a wall of overlapping lines.
]]
local function allowed(self: Bank, t: number, kind: string): boolean
	local cooldown = self.data.cooldownSeconds
	local voice = self.data._tierVoice[self.tier]
	local minGap = cooldown.min
	if t - self._lastLineT < minGap then
		return false
	end

	-- Rolling one-minute window.
	local kept = {}
	for _, time in ipairs(self._lineTimes) do
		if t - time < 60 then
			table.insert(kept, time)
		end
	end
	self._lineTimes = kept
	if #kept >= math.min(voice.linesPerMinute, self.data.maxLinesPerMinute) then
		return false
	end

	local weight = if kind == "taunt" then voice.tauntWeight else voice.calloutWeight
	return self.rng:nextNumber() <= weight
end

export type Context = {
	t: number,
	aliveCount: number,
	speaker: string?,
	subject: string?,
	bearing: string?,
	--- Set for lines that must always play, e.g. the squad wipe.
	force: boolean?,
}

--[[
	Picks a line for an event, or nil if the squad should stay quiet.

	`kind` is one of: matchStart, playerEliminated, botEliminated, taunt,
	squadWipe, flawlessWipe, or a callouts.* key.
]]
function Chatter.say(self: Bank, kind: string, context: Context): Line?
	local force = context.force == true
	if not force and not allowed(self, context.t, kind) then
		return nil
	end

	local pool: { string }?
	if kind == "matchStart" then
		pool = self.data.banks.matchStart
	elseif kind == "squadWipe" then
		pool = self.data.squadWipe
	elseif kind == "flawlessWipe" then
		pool = self.data.flawlessWipe
	elseif self.data.callouts[kind] then
		pool = self.data.callouts[kind]
	else
		local morale = Chatter.moraleFor(context.aliveCount)
		local bank = self.data.banks[morale]
		pool = bank and bank[kind]
	end

	if not pool or #pool == 0 then
		return nil
	end

	local key = kind .. ":" .. tostring(Chatter.moraleFor(context.aliveCount))
	local text = (pool :: { string })[drawIndex(self, key, #pool)]

	local speaker = context.speaker or self.names[self.rng:nextInt(1, #self.names)]
	local subject = context.subject
	if not subject then
		-- Name someone other than the speaker, so blaming has a target.
		for _ = 1, 6 do
			local candidate = self.names[self.rng:nextInt(1, #self.names)]
			if candidate ~= speaker then
				subject = candidate
				break
			end
		end
	end

	local line: Line = {
		text = fill(text, {
			name = subject or speaker,
			alive = tostring(context.aliveCount),
			bearing = context.bearing or "front",
		}),
		speaker = speaker,
		t = context.t,
		kind = kind,
	}

	self._lastLineT = context.t
	table.insert(self._lineTimes, context.t)
	table.insert(self.history, line)
	return line
end

--- Compass-ish bearing word for callouts. Coarse on purpose: a squad calling
--- "left side, mid" is a squad, and a squad calling exact degrees is a wallhack.
function Chatter.bearingWord(bearingDeg: number): string
	local a = ((bearingDeg + 180) % 360) - 180
	if a >= -22.5 and a <= 22.5 then
		return "front"
	elseif a > 22.5 and a <= 67.5 then
		return "front right"
	elseif a > 67.5 and a <= 112.5 then
		return "right"
	elseif a > 112.5 or a < -157.5 then
		return "behind"
	elseif a < -22.5 and a >= -67.5 then
		return "front left"
	else
		return "left"
	end
end

--[[
	The bearing word for a target seen from a facing, or nil.

	The arithmetic that turns two vectors into "front left" belongs beside the
	table that names the words, not in the match loop -- MatchService only wants
	to know what the speaker would say. Signed about Y and negated so positive
	reads as the speaker's right, which is what bearingWord expects.

	Returns nil rather than a word when there is no meaningful bearing: standing
	on the target, or facing nowhere. A callout that interpolated "nil" would be
	worse than one that says "front".
]]
function Chatter.bearingFrom(facing: Vector3, toTarget: Vector3): string?
	local forward = Vector3.new(facing.X, 0, facing.Z)
	local target = Vector3.new(toTarget.X, 0, toTarget.Z)
	if forward.Magnitude < 1e-3 or target.Magnitude < 1e-3 then
		return nil
	end
	forward, target = forward.Unit, target.Unit
	local cross = forward.Z * target.X - forward.X * target.Z
	return Chatter.bearingWord(math.deg(math.atan2(-cross, forward:Dot(target))))
end

return Chatter
