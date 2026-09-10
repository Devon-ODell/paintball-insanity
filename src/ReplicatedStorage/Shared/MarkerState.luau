--!strict
--[[
	Clock-driven ammo state shared by server authority and client prediction.

	A round now has a finite amount of paint in it. `podCount` was authored on
	every pod harness in the shop, priced, described as the tradeoff the harness
	exists for -- and nothing read it, so a reload was free and infinite and the
	four-pack and the six-pack were the same item at different prices.

	`reloadSeconds` comes from the resolved loadout rather than straight off the
	marker for the same reason: gear that speeds up a reload was authored and
	reached nothing.
]]
local MarkerState = {}
MarkerState.__index = MarkerState

export type State = typeof(setmetatable({} :: {
	capacity: number,
	ammo: number,
	reloadSeconds: number,
	shotInterval: number,
	reloadUntil: number?,
	lastShotAt: number,
	--- Refills left. Nil means unlimited, which is what the Range wants: a drill
	--- grades aim, and running a player dry mid-drill would grade their kit.
	pods: number?,
}, MarkerState))

--[[
	`overrides` carries the resolved loadout's reload time and pod count. Absent,
	the marker's own reload time is used and pods are unlimited -- which is the
	behaviour every existing caller had, so nothing silently gains a limit it was
	not built to expect.
]]
function MarkerState.new(marker: any, overrides: any?): State
	local capacity = (overrides and overrides.hopperCapacity) or marker.hopperCapacity
	local rpm = (overrides and overrides.roundsPerMinute) or marker.roundsPerMinute
	return setmetatable({
		capacity = capacity,
		ammo = capacity,
		reloadSeconds = (overrides and overrides.reloadSeconds) or marker.reloadSeconds,
		--- Capped by what the hopper can feed: a force-fed hopper is what lets a
		--- high-rate marker actually run at its rate.
		shotInterval = 60 / rpm,
		reloadUntil = nil :: number?,
		lastShotAt = -math.huge,
		pods = overrides and overrides.podCount,
	}, MarkerState)
end

function MarkerState.update(self: State, now: number)
	if self.reloadUntil and now >= self.reloadUntil then
		self.ammo = self.capacity
		self.reloadUntil = nil
	end
end

--[[
	Starts a reload, if there is a pod left to load.

	Returns false when there is nothing to do -- already reloading, already full,
	or out of paint. The caller distinguishes those by asking `pods`; from here
	they are all "no".
]]
function MarkerState.reload(self: State, now: number): boolean
	self:update(now)
	if self.reloadUntil or self.ammo == self.capacity then
		return false
	end
	if self.pods ~= nil then
		if (self.pods :: number) <= 0 then
			return false
		end
		self.pods = (self.pods :: number) - 1
	end
	self.reloadUntil = now + self.reloadSeconds
	return true
end

--- Whether there is any paint left to reload with. False means this round is
--- over for this player unless they can finish it on what is in the hopper.
function MarkerState.isDry(self: State): boolean
	return self.pods ~= nil and (self.pods :: number) <= 0 and self.ammo <= 0 and self.reloadUntil == nil
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
