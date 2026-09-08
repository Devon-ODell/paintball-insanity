--!strict
local Shared = game:GetService("ReplicatedStorage").Shared
local Config = require(Shared.Config)
local Spread = require(Shared.Spread)
local function angle(direction: Vector3): number
	return math.deg(math.acos(math.clamp(direction:Dot(Vector3.zAxis), -1, 1)))
end
return function()
	local marker = Config.get("markers").markers.mechanical
	local player = Config.get("match").player
	local function newState()
		-- Same radial/azimuth samples isolate the spread envelope from luck.
		return Spread.new(marker, player, { nextNumber = function() return 0.5 end })
	end
	it("derives moving and sprinting spread from horizontal velocity", function()
		local state = newState()
		expect(state:stance(Vector3.new(0, 100, 0), false)).to.equal("standing")
		expect(state:stance(Vector3.zero, true)).to.equal("crouching")
		expect(state:stance(Vector3.new(player.walkSpeedMps, 0, 0), true)).to.equal("moving")
		expect(state:stance(Vector3.new(player.sprintSpeedMps, 0, 0), false)).to.equal("sprinting")
	end)
	it("remembers a sprint even when no shot was fired during it", function()
		local standing, recovery = newState(), newState()
		recovery:step(0.1, 1, Vector3.new(player.sprintSpeedMps, 0, 0))
		expect(angle(recovery:fire(Vector3.zAxis, 1.01, "standing")) > angle(standing:fire(Vector3.zAxis, 1.01, "standing"))).to.equal(true)
		recovery:step(2, 3, Vector3.zero)
		local fresh = newState()
		expect(angle(recovery:fire(Vector3.zAxis, 3, "standing"))).to.be.near(angle(fresh:fire(Vector3.zAxis, 3, "standing")), 1e-6)
	end)
	it("grows sustained spread and clears it at a new round", function()
		local state = newState()
		local first = angle(state:fire(Vector3.zAxis, 0, "standing"))
		expect(angle(state:fire(Vector3.zAxis, 0, "standing")) > first).to.equal(true)
		state:step(0, 100, Vector3.new(player.sprintSpeedMps, 0, 0))
		state:reset()
		expect(angle(state:fire(Vector3.zAxis, 0, "standing"))).to.be.near(first, 1e-6)
	end)
end
