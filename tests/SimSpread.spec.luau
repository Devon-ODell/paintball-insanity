--!strict
local Shared = game:GetService("ReplicatedStorage").Shared
local Server = game:GetService("ServerScriptService").Server
local Config = require(Shared.Config)
local Spread = require(Shared.Spread)
local Rng = require(Shared.Rng)
local SimMatch = require(Server.Sim.SimMatch)
local Projectiles = require(Server.Ballistics.ProjectileSim)
return function()
	it("applies authoritative spread to simulated paint using an independent random stream", function()
		local first: Vector3? = nil
		local fire = Projectiles.fire
		Projectiles.fire = function(self, request)
			if request.team == "player" and not first then first = request.direction end
			return fire(self, request)
		end
		local ok, result = pcall(SimMatch.run, {
			map = "speedball", seed = 1, tier = "rec", maxSeconds = 0.5, singleRound = 1,
			policy = { name = "spread-check", decide = function(ctx)
				-- Policy randomness must not consume the marker's spread samples.
				for _ = 1, 7 do ctx.rng:nextNumber() end
				return { move = nil, sprint = false, crouch = true, aim = Vector3.yAxis, fire = true }
			end },
		})
		Projectiles.fire = fire
		assert(ok, tostring(result))
		assert(first ~= nil)
		local marker = Config.get("markers").markers.mechanical
		local expected = Spread.sample(Vector3.yAxis, Spread.angle(marker, 0, "crouching", 0), Rng.new(1):fork(500))
		expect((first :: Vector3 - expected).Magnitude).to.be.near(0, 1e-6)
		expect((first :: Vector3 - Vector3.yAxis).Magnitude > 0).to.equal(true)
	end)
end
