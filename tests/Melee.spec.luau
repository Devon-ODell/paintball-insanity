--!strict
--[[
	The butt of the marker.

	Pure geometry and one interpolation, so both are asserted directly. What
	these guard is not the arithmetic -- it is that a shove cannot quietly
	become a ranged attack, cannot reach behind the person swinging it, and
	cannot land on the frame the button was pressed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Melee = require(ReplicatedStorage.Shared.Melee)
local CombatMotion = require(ReplicatedStorage.Shared.CombatMotion)
local Config = require(ReplicatedStorage.Shared.Config)

return function()
	local rules: Melee.Rules = {
		rangeMetres = 2.4,
		reachHeightMetres = 2.0,
		arcDegrees = 110,
		cooldownSeconds = 1.0,
		swingSeconds = 0.45,
		contactFraction = 0.38,
	}
	local origin = Vector3.new(0, 0, 0)
	local forward = Vector3.new(0, 0, -1)

	describe("reach", function()
		it("reaches somebody standing in front of it", function()
			expect(Melee.reaches(origin, forward, Vector3.new(0, 0, -2), rules)).to.equal(true)
		end)

		it("stops at the declared range", function()
			expect(Melee.reaches(origin, forward, Vector3.new(0, 0, -2.39), rules)).to.equal(true)
			expect(Melee.reaches(origin, forward, Vector3.new(0, 0, -2.41), rules)).to.equal(false)
		end)

		--[[
			The one that matters. If the arc ever opened to 360 the mechanic
			would stop being a shove and start being an aura.
		]]
		it("cannot reach behind the swinger", function()
			expect(Melee.reaches(origin, forward, Vector3.new(0, 0, 1.5), rules)).to.equal(false)
			expect(Melee.reaches(origin, forward, Vector3.new(1.5, 0, 0.6), rules)).to.equal(false)
		end)

		it("reaches to the edge of the arc and not past it", function()
			local half = math.rad(rules.arcDegrees / 2)
			local inside = math.rad(rules.arcDegrees / 2 - 2)
			expect(Melee.reaches(origin, forward,
				Vector3.new(math.sin(inside) * 2, 0, -math.cos(inside) * 2), rules)).to.equal(true)
			local outside = half + math.rad(2)
			expect(Melee.reaches(origin, forward,
				Vector3.new(math.sin(outside) * 2, 0, -math.cos(outside) * 2), rules)).to.equal(false)
		end)

		--- Crouching, or standing a little downhill, must not save anybody.
		it("ignores height inside the reach bound and rejects it outside", function()
			expect(Melee.reaches(origin, forward, Vector3.new(0, 1.4, -2), rules)).to.equal(true)
			expect(Melee.reaches(origin, forward, Vector3.new(0, 3.5, -2), rules)).to.equal(false)
		end)

		it("cannot be aimed by a zero-length facing", function()
			expect(Melee.reaches(origin, Vector3.zero, Vector3.new(0, 0, -2), rules)).to.equal(false)
		end)
	end)

	describe("target selection", function()
		it("takes the nearest reachable target and skips the dead", function()
			local far = { position = Vector3.new(0, 0, -2.2), alive = true }
			local near = { position = Vector3.new(0, 0, -1.1), alive = true }
			local corpse = { position = Vector3.new(0, 0, -0.5), alive = false }
			local picked = Melee.pick(origin, forward, { far, corpse, near }, rules)
			expect(picked).to.equal(near)
		end)

		it("returns nothing when the swing hits air", function()
			expect(Melee.pick(origin, forward, { { position = Vector3.new(0, 0, -9), alive = true } }, rules))
				.to.equal(nil)
		end)
	end)

	describe("the swing itself", function()
		--[[
			The swing is committed rather than instant, and that delay is the
			only warning a player gets before a bot's butt arrives. A contact
			fraction of 0 would make every bot at contact range an unavoidable
			elimination.
		]]
		it("lands part-way through the swing, never on the first frame", function()
			local delay = Melee.contactDelay(rules)
			expect(delay > 0).to.equal(true)
			expect(delay < rules.swingSeconds).to.equal(true)
		end)

		it("starts and ends at rest so it can blend out of any pose", function()
			local start, finish = CombatMotion.swing(0), CombatMotion.swing(1)
			expect(start.marker.Position.Magnitude).to.be.near(0, 1e-6)
			expect(finish.marker.Position.Magnitude).to.be.near(0, 1e-6)
		end)

		it("actually moves the marker at contact", function()
			local contact = CombatMotion.swing(rules.contactFraction)
			expect(contact.marker.Position.Magnitude > 0.2).to.equal(true)
		end)

		--[[
			The frame the butt arrives on screen and the frame the server
			resolves the hit are the same moment on purpose. If somebody retunes
			one without the other, the animation starts lying about when it hit.
		]]
		it("animates contact on the frame the rules resolve it", function()
			local shipped = Config.require("match", "hitRules.melee")
			local frames = Config.get("combatAnimations").melee
			local matched = false
			for _, frame in ipairs(frames) do
				if math.abs(frame.t - shipped.contactFraction) < 1e-6 then
					matched = true
				end
			end
			expect(matched).to.equal(true)
		end)
	end)

	describe("recoil", function()
		it("is full on the frame of the shot and spent by the end", function()
			expect(CombatMotion.recoil(0, 0.16)).to.be.near(1, 1e-6)
			expect(CombatMotion.recoil(0.16, 0.16)).to.equal(0)
			expect(CombatMotion.recoil(-1, 0.16)).to.equal(0)
		end)

		--- A spring, not a ramp: it must cross past rest once on the way back.
		it("settles past rest instead of sliding home in a straight line", function()
			local crossed = false
			for step = 1, 99 do
				if CombatMotion.recoil(0.16 * step / 100, 0.16) < 0 then
					crossed = true
				end
			end
			expect(crossed).to.equal(true)
		end)
	end)

	describe("the shipped rules", function()
		--[[
			A shove is a contact mechanic. If its range ever grew towards the
			engagement bands the maps are tuned for, it would stop being the
			cost of closing and start being a second weapon -- and no marker,
			purchasable or otherwise, may out-range aim.
		]]
		it("stays inside contact range", function()
			local shipped = Config.require("match", "hitRules.melee")
			expect(shipped.rangeMetres > 0 and shipped.rangeMetres <= 3).to.equal(true)
			expect(shipped.arcDegrees > 0 and shipped.arcDegrees < 360).to.equal(true)
			expect(shipped.cooldownSeconds > 0).to.equal(true)
		end)
	end)
end
