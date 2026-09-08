--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local Config = require(ReplicatedStorage.Shared.Config)
local SimMatch = require(Server.Sim.SimMatch)
return function()
	it("resumes simulated fire after an empty hopper reload without a respawn", function()
		local marker = Config.get("markers").markers.mechanical
		local capacity, duration = marker.hopperCapacity, marker.reloadSeconds
		marker.hopperCapacity, marker.reloadSeconds = 1, 0.1
		local ok, result = pcall(SimMatch.run, {
			map = "speedball", seed = 1, tier = "rec", maxSeconds = 2, singleRound = 1,
			policy = { name = "reload-check", decide = function()
				return { move = nil, sprint = false, crouch = true,
					aim = Vector3.new(0, 1, 0), fire = true }
			end },
		})
		marker.hopperCapacity, marker.reloadSeconds = capacity, duration
		assert(ok, tostring(result))
		expect(result.outcome.deaths).to.equal(0)
		expect(result.outcome.shots > 1).to.equal(true)
	end)
end
