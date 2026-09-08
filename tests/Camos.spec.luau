--!strict
local RS = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local Config = require(RS.Shared.Config)
local Rules = require(RS.Shared.Camos)
local Camos = require(Server.Progression.Camos)
local Profile = require(Server.Economy.Profile)
local Dev = require(RS.Shared.Dev)
local Ballistics = require(RS.Shared.Ballistics)
local ProjectileSim = require(Server.Ballistics.ProjectileSim)
local MapGeometry = require(RS.Shared.MapGeometry)

return function()
	local handle
	beforeEach(function()
		Dev._setOverrideForTesting({ enabled = false })
		Profile._resetFallback()
		handle = Profile.load(6543)
	end)
	afterEach(function() Dev._setOverrideForTesting(nil) end)

	describe("earned reactive camos", function()
		it("unlocks only on the exact milestone and auto equips the first finish", function()
			for _ = 1, 9 do Camos.recordHeadshot(handle) end
			expect(Rules.isUnlocked(handle.data, "citrusCircuit")).to.equal(false)
			local progress = Camos.recordHeadshot(handle)
			expect(progress.unlockedCamos[1]).to.equal("citrusCircuit")
			expect(handle.data.loadout.camo).to.equal("citrusCircuit")
			expect(progress.nextUnlock.remaining).to.equal(25)
		end)
		it("preserves the player's chosen finish at later milestones", function()
			for _ = 1, 34 do Camos.recordHeadshot(handle) end
			Camos.equip(handle, "factory")
			local progress = Camos.recordHeadshot(handle)
			expect(progress.unlockedCamos[1]).to.equal("tideShift")
			expect(handle.data.loadout.camo).to.equal("factory")
		end)
		it("records every milestone once, persists and reports full mastery", function()
			local earned = {}
			for _ = 1, 1005 do
				for _, id in ipairs(Camos.recordHeadshot(handle).unlockedCamos) do
					expect(earned[id]).to.equal(nil)
					earned[id] = true
				end
			end
			expect(#handle.data.ownedCamos).to.equal(8)
			expect(Rules.nextUnlock(handle.data)).to.equal(nil)
			Profile.release(6543)
			handle = Profile.load(6543)
			expect(handle.data.camoProgress.headshots).to.equal(1005)
			expect(Camos.equip(handle, "auroraFlux")).to.equal(true)
		end)
		it("refuses forged ownership and dev unlock flags", function()
			Dev._setOverrideForTesting({ enabled = true, unlockEverything = { on = true } })
			table.insert(handle.data.ownedCamos, "auroraFlux")
			expect(Camos.equip(handle, "auroraFlux")).to.equal(false)
			expect(Camos.equip(handle, "invented")).to.equal(false)
			expect(handle.data.loadout.camo).to.equal("factory")
		end)
		it("never changes marker statistics or economy", function()
			local original = Profile.deepCopy(Config.get("markers").markers.mechanical)
			Camos.recordHeadshot(handle)
			for key, value in pairs(original) do expect(Config.get("markers").markers.mechanical[key]).to.equal(value) end
			expect(handle.data.currency).to.equal(0)
		end)
		it("rejects stale sessions and sanitizes invalid old progress", function()
			handle.data.camoProgress.headshots = 0/0
			expect(Rules.headshots(handle.data)).to.equal(0)
			handle:release()
			expect(Camos.recordHeadshot(handle)).to.equal(nil)
			expect(Camos.equip(handle, "factory")).to.equal(false)
		end)
	end)

	describe("server mask classification", function()
		local height = Config.get("ballistics").hitbox.headTopMetres - Config.get("camos").headshot.centerBelowHeadTopMetres
		it("accepts mask center and rejects torso, shoulders and above-mask grazes", function()
			local ground = Vector3.new(13, 2, -17)
			expect(Rules.classifyHeadshot(ground + Vector3.new(0, height, 0), ground)).to.equal(true)
			for _, offset in ipairs({ Vector3.new(0, 1.1, 0), Vector3.new(0.28, height, 0), Vector3.new(0, 1.95, 0) }) do
				expect(Rules.classifyHeadshot(ground + offset, ground)).to.equal(false)
			end
		end)
		it("recognizes mask shots from real fixed-step capsule impacts", function()
			local data = Config.map("speedball")
			local world = MapGeometry.build(data, Config.get("maps_index"))
			local ground = Vector3.new(-10, 0, -25)
			local hitbox = Config.get("ballistics").hitbox
			local target = { id = "mask", team = "bot", position = ground, velocity = Vector3.zero,
				radius = hitbox.bodyWidthMetres / 2, height = hitbox.bodyHeightMetres, alive = true }
			-- Vary distance so the broad capsule is first reached at different
			-- points within the fixed simulation step.
			for _, distance in ipairs({ 2, 2.1, 2.25, 2.4, 2.6, 3, 3.3 }) do
				local sim = ProjectileSim.new(world, Config.get("ballistics"))
				local spec = Ballistics.specFromMarker(Config.get("markers").markers.mechanical, Config.get("ballistics"))
				sim:fire({ origin = ground + Vector3.new(0, height, -distance), direction = Vector3.zAxis,
					spec = spec, ownerId = "player", team = "player", t = 0 })
				local hit
				for step = 1, 60 do
					for _, event in ipairs(sim:step(1/120, (step-1)/120, { target })) do hit = event end
					if hit then break end
				end
				expect(hit ~= nil and hit.kind == "target").to.equal(true)
				expect(Rules.classifyHeadshot(hit.position, ground, hit.projectile.velocity)).to.equal(true)
			end
		end)
	end)
end
