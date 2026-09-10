--!strict
--[[
	AimHistory -- where the crosshair was, a moment ago.

	Crosshair placement is a fundamental this game grades and prescribes a drill
	for, and until this existed nothing measured it. `ShotMeasure` approximated
	"where was the crosshair when the target appeared" with "where was the
	crosshair on the player's PREVIOUS SHOT", which is a different question with
	a different answer -- on Peek, whose three known angles are sixty degrees
	apart, a player who was parked perfectly on the reveal angle still read as
	sixty degrees off because that is where their last shot went. The rating was
	not merely noisy; it was measuring the wrong thing, and it drove the
	post-match prescription.

	So the client streams its aim direction and the server keeps a short ring of
	it. A target's reveal time is a server time the server already knows, so the
	offset at reveal is a lookup rather than an inference.

	The clock is the SERVER's, stamped on arrival. That folds one network trip
	into the sample time, which is why `latencySeconds` exists: a caller that
	knows the player's round trip can shift its query back by half of it and get
	closer. It is still an estimate under load, and it is a far better one than
	asking what the player's last shot was aimed at.
]]

local AimHistory = {}
AimHistory.__index = AimHistory

export type Sample = { t: number, direction: Vector3 }

export type History = typeof(setmetatable({} :: {
	samples: { Sample },
	--- Oldest sample kept, in seconds. Older ones are dropped on write.
	windowSeconds: number,
	--- Most samples retained, so a misbehaving client cannot grow this.
	maxSamples: number,
}, AimHistory))

function AimHistory.new(windowSeconds: number, maxSamples: number): History
	return setmetatable({
		samples = {},
		windowSeconds = windowSeconds,
		maxSamples = maxSamples,
	}, AimHistory)
end

--[[
	Records one aim direction at server time `t`.

	Rejects anything that is not a usable direction rather than storing it, so a
	forged or degenerate sample cannot poison a later lookup. There is nothing to
	exploit here in either direction -- the history only ever makes the player's
	own telemetry more or less flattering -- but a NaN in the ring would come
	back out as a NaN rating.
]]
function AimHistory.record(self: History, t: number, direction: Vector3)
	if t ~= t then
		return
	end
	local magnitude = direction.Magnitude
	if magnitude ~= magnitude or magnitude < 1e-6 or magnitude > 1e6 then
		return
	end
	table.insert(self.samples, { t = t, direction = direction.Unit })

	local cutoff = t - self.windowSeconds
	local firstKept = 1
	while firstKept <= #self.samples and self.samples[firstKept].t < cutoff do
		firstKept += 1
	end
	local surplus = #self.samples - self.maxSamples
	if surplus > 0 and firstKept <= surplus then
		firstKept = surplus + 1
	end
	if firstKept > 1 then
		local kept: { Sample } = {}
		for i = firstKept, #self.samples do
			table.insert(kept, self.samples[i])
		end
		self.samples = kept
	end
end

--[[
	The aim direction at server time `t`, or nil if the ring does not cover it.

	Nil rather than the nearest sample on purpose: "we were not looking" and "we
	have no record" are different, and a measurement built on a sample from
	before the player existed is worse than no measurement. `toleranceSeconds`
	is how stale a sample may be and still answer for `t`.
]]
function AimHistory.at(self: History, t: number, toleranceSeconds: number): Vector3?
	local best: Sample? = nil
	for _, sample in ipairs(self.samples) do
		if sample.t <= t and (best == nil or sample.t > (best :: Sample).t) then
			best = sample
		end
	end
	if best == nil then
		--- Before the first sample: only answer if the ring starts close enough
		--- that the player's aim cannot have moved far.
		local first = self.samples[1]
		if first and first.t - t <= toleranceSeconds then
			return first.direction
		end
		return nil
	end
	if t - (best :: Sample).t > toleranceSeconds then
		return nil
	end
	return (best :: Sample).direction
end

function AimHistory.clear(self: History)
	self.samples = {}
end

return AimHistory
