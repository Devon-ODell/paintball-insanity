--!strict
local Spread = {}

function Spread.angle(marker: any, sustained: number, stance: string, recovery: number): number
	local multiplier = 1
	if stance == "sprinting" then
		multiplier = marker.sprintingSpreadMultiplier
	elseif stance == "moving" then
		multiplier = marker.movingSpreadMultiplier
	elseif stance == "crouching" then
		multiplier = marker.crouchSpreadMultiplier
	end
	if stance ~= "sprinting" then
		multiplier += (marker.sprintingSpreadMultiplier - multiplier) * math.clamp(recovery, 0, 1)
	end
	return math.min((marker.firstShotSpreadDeg + sustained) * multiplier,
		marker.sustainedSpreadDeg * marker.sprintingSpreadMultiplier)
end

function Spread.sample(direction: Vector3, degrees: number, rng: any): Vector3
	local forward = direction.Unit
	local up = if math.abs(forward.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local right = forward:Cross(up).Unit
	up = right:Cross(forward).Unit
	local cosine = 1 - rng:nextNumber() * (1 - math.cos(math.rad(degrees)))
	local sine = math.sqrt(math.max(0, 1 - cosine * cosine))
	local azimuth = rng:nextNumber() * 2 * math.pi
	return (forward * cosine + (right * math.cos(azimuth) + up * math.sin(azimuth)) * sine).Unit
end

-- Authoritative state shared by live matches and the deterministic simulator.
function Spread.new(marker: any, player: any, rng: any)
	local sustained = 0
	local lastSprintAt = -math.huge
	local state = {}
	function state:reset()
		sustained = 0
		lastSprintAt = -math.huge
	end
	function state:stance(velocity: Vector3, crouching: boolean): string
		local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		return if speed > player.walkSpeedMps + 0.1 then "sprinting"
			elseif speed > 0.3 then "moving"
			elseif crouching then "crouching" else "standing"
	end
	function state:step(dt: number, now: number, velocity: Vector3)
		sustained = math.max(0, sustained - marker.spreadDecayPerSecondDeg * dt)
		if self:stance(velocity, false) == "sprinting" then lastSprintAt = now end
	end
	function state:fire(direction: Vector3, now: number, stance: string): Vector3
		if stance == "sprinting" then lastSprintAt = now end
		local recovery = math.clamp(1 - (now - lastSprintAt) / player.sprintToFireRecoverySeconds, 0, 1)
		local result = Spread.sample(direction, Spread.angle(marker, sustained, stance, recovery), rng)
		sustained = math.min(marker.sustainedSpreadDeg, sustained + marker.spreadGrowthPerShotDeg)
		return result
	end
	return state
end

return Spread
