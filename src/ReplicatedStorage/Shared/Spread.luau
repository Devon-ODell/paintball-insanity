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

return Spread
