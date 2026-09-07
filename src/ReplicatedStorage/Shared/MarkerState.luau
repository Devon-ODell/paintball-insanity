--!strict
-- Clock-driven ammo state shared by server authority and client prediction.
local MarkerState = {}
MarkerState.__index = MarkerState

export type State = typeof(setmetatable({} :: {
	capacity: number,
	ammo: number,
	reloadSeconds: number,
	shotInterval: number,
	reloadUntil: number?,
	lastShotAt: number,
}, MarkerState))

function MarkerState.new(marker: any): State
	return setmetatable({
		capacity = marker.hopperCapacity,
		ammo = marker.hopperCapacity,
		reloadSeconds = marker.reloadSeconds,
		shotInterval = 60 / marker.roundsPerMinute,
		reloadUntil = nil :: number?,
		lastShotAt = -math.huge,
	}, MarkerState)
end

function MarkerState.update(self: State, now: number)
	if self.reloadUntil and now >= self.reloadUntil then
		self.ammo = self.capacity
		self.reloadUntil = nil
	end
end

function MarkerState.reload(self: State, now: number): boolean
	self:update(now)
	if self.reloadUntil or self.ammo == self.capacity then
		return false
	end
	self.reloadUntil = now + self.reloadSeconds
	return true
end

function MarkerState.fire(self: State, now: number): boolean
	self:update(now)
	if self.reloadUntil or self.ammo <= 0 or now - self.lastShotAt < self.shotInterval then
		return false
	end
	self.lastShotAt = now
	self.ammo -= 1
	return true
end

return MarkerState
