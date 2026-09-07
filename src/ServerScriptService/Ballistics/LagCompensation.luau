--!strict
--[[
	LagCompensation -- rewinds the world to when the shooter actually saw it.

	The client renders the past. If the server validates a shot against the
	present, a player with 120 ms of latency has to lead their own connection on
	top of leading the target, which would corrupt every lead measurement the
	telemetry takes. So the server keeps a short history of every target and
	rewinds it by the shooter's measured latency before testing a shot.

	The rewind window is deliberately short (Data/ballistics.json). Beyond it
	the server refuses to rewind rather than trusting a large claimed latency,
	which is the standard exploit against naive lag compensation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LagCompensation = {}
LagCompensation.__index = LagCompensation

export type Snapshot = {
	t: number,
	positions: { [string]: Vector3 },
	velocities: { [string]: Vector3 },
}

export type History = typeof(setmetatable(
	{} :: {
		snapshots: { Snapshot },
		maxRewind: number,
		rateHz: number,
		tolerance: number,
		_lastCaptureT: number,
	},
	LagCompensation
))

function LagCompensation.new(ballisticsData: any): History
	local cfg = ballisticsData.lagCompensation
	return setmetatable({
		snapshots = {},
		maxRewind = cfg.maxRewindSeconds,
		rateHz = cfg.snapshotRateHz,
		tolerance = cfg.positionToleranceMetres,
		_lastCaptureT = -math.huge,
	}, LagCompensation) :: any
end

--- Records the world state. Rate-limited internally, so callers may call this
--- every frame without thinking about it.
function LagCompensation.capture(self: History, t: number, targets: { any })
	local interval = 1 / self.rateHz
	if t - self._lastCaptureT < interval then
		return
	end
	self._lastCaptureT = t

	local positions: { [string]: Vector3 } = {}
	local velocities: { [string]: Vector3 } = {}
	for _, target in ipairs(targets) do
		positions[target.id] = target.position
		velocities[target.id] = target.velocity
	end
	table.insert(self.snapshots, { t = t, positions = positions, velocities = velocities })

	while #self.snapshots > 0 and t - self.snapshots[1].t > self.maxRewind * 2 do
		table.remove(self.snapshots, 1)
	end
end

--[[
	Positions as they were `latency` seconds ago, linearly interpolated between
	the two bracketing snapshots.

	`latency` is clamped to the configured window. A client claiming half a
	second of lag gets rewound by the maximum and no further; the shot is still
	validated, it is just validated against a world the server is willing to
	vouch for.
]]
function LagCompensation.rewind(self: History, now: number, latency: number): { [string]: Vector3 }
	local clamped = math.clamp(latency, 0, self.maxRewind)
	local target = now - clamped

	local count = #self.snapshots
	if count == 0 then
		return {}
	end
	if target >= self.snapshots[count].t then
		return self.snapshots[count].positions
	end
	if target <= self.snapshots[1].t then
		return self.snapshots[1].positions
	end

	for i = count - 1, 1, -1 do
		local a = self.snapshots[i]
		local b = self.snapshots[i + 1]
		if target >= a.t and target <= b.t then
			local span = b.t - a.t
			local alpha = if span > 1e-9 then (target - a.t) / span else 0
			local out: { [string]: Vector3 } = {}
			for id, positionA in pairs(a.positions) do
				local positionB = b.positions[id]
				out[id] = if positionB then positionA:Lerp(positionB, alpha) else positionA
			end
			return out
		end
	end
	return self.snapshots[count].positions
end

--[[
	Sanity check on a client-reported firing origin.

	The client tells the server where its muzzle was. The server believes it only
	if it is within tolerance of where the server thinks the player was. This is
	the difference between "the client predicts" and "the client decides".
]]
function LagCompensation.originIsPlausible(self: History, claimed: Vector3, authoritative: Vector3): boolean
	return (claimed - authoritative).Magnitude <= self.tolerance
end

return LagCompensation
