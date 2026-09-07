--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarkerState = require(ReplicatedStorage.Shared.MarkerState)
local Remotes = require(ReplicatedStorage.Net.Remotes)
local RoundState = require(game:GetService("ServerScriptService").Server.Match.RoundState)
local Spread = require(ReplicatedStorage.Shared.Spread)
local Rng = require(ReplicatedStorage.Shared.Rng)

return function()
	describe("marker spread", function()
		it("widens sprint shots and restores standing accuracy after recovery", function()
			local marker = require(ReplicatedStorage.Data.markers).markers.mechanical
			local standing = Spread.angle(marker, 0, "standing", 0)
			local sprinting = Spread.angle(marker, 0, "sprinting", 0)
			expect(sprinting > standing).to.equal(true)
			expect(Spread.angle(marker, 0, "standing", 1)).to.be.near(sprinting, 1e-6)
			expect(Spread.angle(marker, 0, "standing", 0.5) > standing).to.equal(true)
		end)
		it("samples finite unit directions inside the cone, including vertical aim", function()
			local rng = Rng.new(123)
			for _, direction in ipairs({ Vector3.yAxis, -Vector3.yAxis, Vector3.zAxis }) do
				for _ = 1, 100 do
					local shot = Spread.sample(direction, 5, rng)
					expect(shot.Magnitude).to.be.near(1, 1e-6)
					expect(shot:Dot(direction) >= math.cos(math.rad(5)) - 1e-6).to.equal(true)
				end
			end
		end)
	end)
	describe("round phases", function()
		it("publishes warmup on subscription and enables shots only when live", function()
			local state = RoundState.new()
			local phases: { string } = {}
			state:onPhase(function(phase)
				table.insert(phases, phase)
			end)
			expect(phases[1]).to.equal("warmup")
			expect(state:shotsCount()).to.equal(false)
			state:step(state.warmupSeconds)
			expect(phases[2]).to.equal("live")
			expect(state:shotsCount()).to.equal(true)
			state:finish()
			expect(state:shotsCount()).to.equal(false)
		end)
	end)
	describe("marker reload and fire rules", function()
		local config = { hopperCapacity = 2, reloadSeconds = 3, roundsPerMinute = 60 }
		it("reloads a partially empty hopper and blocks shots until completion", function()
			local marker = MarkerState.new(config)
			expect(marker:fire(0)).to.equal(true)
			expect(marker:reload(1)).to.equal(true)
			expect(marker:fire(3.99)).to.equal(false)
			expect(marker:fire(4)).to.equal(true)
			expect(marker.ammo).to.equal(1)
		end)
		it("ignores repeated reload requests without extending the timer", function()
			local marker = MarkerState.new(config)
			marker:fire(0)
			marker:reload(1)
			expect(marker:reload(2)).to.equal(false)
			marker:update(4)
			expect(marker.ammo).to.equal(2)
			expect(marker.reloadUntil).to.equal(nil)
		end)
		it("enforces fire rate and empty hoppers independently of client input", function()
			local marker = MarkerState.new(config)
			expect(marker:reload(0)).to.equal(false)
			expect(marker:fire(0)).to.equal(true)
			expect(marker:fire(0.5)).to.equal(false)
			expect(marker:fire(1)).to.equal(true)
			expect(marker:fire(2)).to.equal(false)
			expect(marker:reload(2)).to.equal(true)
			expect(marker:fire(5)).to.equal(true)
		end)
	end)

	describe("fire request validation", function()
		local function request(): any
			return { origin = Vector3.zero, direction = Vector3.new(0, 0, -2), clientTime = 0, stance = "standing" }
		end
		it("normalises a valid direction", function()
			local result = Remotes.validateFireRequest(request())
			expect(result).to.be.ok()
			expect((result :: any).direction.Magnitude).to.be.near(1, 1e-6)
		end)
		it("rejects NaN and infinity in every vector component", function()
			for _, value in ipairs({ 0 / 0, math.huge, -math.huge }) do
				for _, field in ipairs({ "origin", "direction" }) do
					for axis = 1, 3 do
						local components = { 0, 0, -1 }
						components[axis] = value
						local payload = request()
						payload[field] = Vector3.new(components[1], components[2], components[3])
						expect(Remotes.validateFireRequest(payload)).to.equal(nil)
					end
				end
			end
		end)
		it("rejects nonfinite clocks and malformed payloads", function()
			for _, value in ipairs({ 0 / 0, math.huge, -math.huge }) do
				local payload = request()
				payload.clientTime = value
				expect(Remotes.validateFireRequest(payload)).to.equal(nil)
			end
			expect(Remotes.validateFireRequest(false)).to.equal(nil)
			local payload = request()
			payload.direction = Vector3.zero
			expect(Remotes.validateFireRequest(payload)).to.equal(nil)
		end)
	end)
end
