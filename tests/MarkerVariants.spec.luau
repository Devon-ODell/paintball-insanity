--!strict
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS.Shared.Config)
local MarkerState = require(RS.Shared.MarkerState)
local Ballistics = require(RS.Shared.Ballistics)
local Payout = require(game:GetService("ServerScriptService").Server.Economy.Payout)

local function viewModel()
	return Config.get("markers").viewModel
end

local function archetypes()
	return Config.get("venue").markerModels
end

return function()
	describe("the marker viewmodel", function()
		it("never uses a Ball for something that is not a ball", function()
			--[[
				The bug this replaced: Hopper and AirTank were both shape "Ball".
				A Roblox Ball renders as a sphere off its SMALLEST axis, so
				[0.22, 0.14, 0.29] and [0.15, 0.15, 0.35] both came out as plain
				spheres -- a black ball stuck on a green box. Any piece whose
				sides differ meaningfully must not be a Ball.
			]]
			for _, piece in ipairs(viewModel().pieces) do
				if piece.shape == "Ball" then
					local size = piece.size
					local biggest = math.max(size[1], size[2], size[3])
					local smallest = math.min(size[1], size[2], size[3])
					expect(biggest / smallest < 1.25).to.equal(true)
				end
			end
		end)

		it("builds the hopper and the air tank out of cylinders", function()
			local shapes = {}
			for _, piece in ipairs(viewModel().pieces) do
				shapes[piece.name] = piece.shape
			end
			expect(shapes.HopperBody).to.equal("Cylinder")
			expect(shapes.AirTank).to.equal("Cylinder")
		end)

		it("declares a well-formed rotation wherever it declares one", function()
			--[[
				Cylinders are the reason this exists: a Roblox cylinder's axis is
				its local X, so an air tank lying along Z and a hopper standing
				along Y both need an explicit rotation or they point the wrong way.
			]]
			local rotated = 0
			for _, piece in ipairs(viewModel().pieces) do
				if piece.rotationDeg then
					expect(#piece.rotationDeg).to.equal(3)
					for _, angle in ipairs(piece.rotationDeg) do
						expect(angle).to.be.a("number")
					end
					rotated += 1
				end
			end
			expect(rotated > 0).to.equal(true)
		end)

		it("cuts a barrel that has room for its own muzzle shroud", function()
			--[[
				The barrel is split into a rear section, a ported shroud and a
				bore. If the shroud is ever longer than the barrel the rear
				section inverts and the muzzle ends up behind the receiver.
			]]
			local tuning = viewModel()
			for id, spec in pairs(archetypes()) do
				if type(spec) == "table" and spec.barrel then
					local shroud = math.min(tuning.muzzleShroudMetres, spec.barrel * 0.4)
					expect(shroud < spec.barrel).to.equal(true)
					expect(spec.barrel - shroud > 0).to.equal(true)
					expect(id).to.be.a("string")
				end
			end
			expect(tuning.boreDepthMetres < tuning.muzzleShroudMetres).to.equal(true)
			expect(tuning.shroudDiameterScale > 1).to.equal(true)
		end)
	end)

	describe("the three archetypes", function()
		it("gives each one hardware the others do not have", function()
			--[[
				They used to differ only by a few centimetres of body and a
				colour, which is not a silhouette. The acceptance test for this
				is "tell them apart in first person without the HUD", and the
				closest thing to that available headlessly is: no two archetypes
				share a piece list.
			]]
			local seen = {}
			for _, id in ipairs({ "mechanical", "electronic", "pump" }) do
				local spec = archetypes()[id]
				expect(#(spec.pieces or {}) > 0).to.equal(true)
				local names = {}
				for _, piece in ipairs(spec.pieces) do
					table.insert(names, piece.name)
				end
				table.sort(names)
				local key = table.concat(names, ",")
				expect(seen[key]).to.equal(nil)
				seen[key] = id
			end
		end)

		it("gives the pump a pump handle, because that is the archetype", function()
			local names = {}
			for _, piece in ipairs(archetypes().pump.pieces) do
				names[piece.name] = true
			end
			expect(names.PumpHandle).to.equal(true)
			-- And rods to slide it on, or it reads as a lump under the barrel.
			expect(names.PumpRodL and names.PumpRodR).to.equal(true)
		end)

		it("only hides shared pieces that exist", function()
			local shared = {}
			for _, piece in ipairs(viewModel().pieces) do
				shared[piece.name] = true
			end
			for id, spec in pairs(archetypes()) do
				if type(spec) == "table" then
					for _, name in ipairs(spec.hide or {}) do
						expect(shared[name]).to.equal(true)
						expect(id).to.be.a("string")
					end
				end
			end
		end)

		it("changes nothing a shot cares about", function()
			--[[
				The marker's look is cosmetic. If a silhouette pass ever grew a
				spread or velocity term this is where it gets caught, next to the
				thing that would have grown it.
			]]
			local banned = { "spread", "velocity", "accuracy", "damage", "recoil", "range" }
			for _, spec in pairs(archetypes()) do
				if type(spec) == "table" then
					for field in pairs(spec) do
						for _, word in ipairs(banned) do
							expect(string.find(string.lower(field), word)).to.equal(nil)
						end
					end
				end
			end
		end)
	end)

	describe("five Yardline paintball markers", function()
		local ids = { "yardTeal", "yardOchre", "yardOlive", "yardCobalt", "yardCoral" }
		it("provides five distinct colors and handling combinations", function()
			local colors, handling = {}, {}
			for _, id in ipairs(ids) do
				local marker = Config.get("markers").markers[id]
				expect(table.find(Config.get("markers").order, id) ~= nil).to.equal(true)
				expect(marker.archetype).to.equal("mechanical")
				local color = table.concat(marker.model.color, ",")
				local stats = `{marker.roundsPerMinute}/{marker.hopperCapacity}/{marker.reloadSeconds}`
				expect(colors[color]).to.equal(nil); colors[color] = true
				expect(handling[stats]).to.equal(nil); handling[stats] = true
				expect(marker.firstShotSpreadDeg).to.equal(Config.get("markers").markers.mechanical.firstShotSpreadDeg)
			end
		end)
		it("uses functioning marker state, ballistics and payout paths for every variant", function()
			for _, id in ipairs(ids) do
				local marker = Config.get("markers").markers[id]
				local state = MarkerState.new(marker)
				expect(state:fire(0)).to.equal(true)
				expect(state.ammo).to.equal(marker.hopperCapacity - 1)
				expect(state:fire(0)).to.equal(false)
				local spec = Ballistics.specFromMarker(marker, Config.get("ballistics"))
				expect(spec.muzzleVelocity > 0).to.equal(true)
				local result = Payout.compute({ map = "speedball", tier = "rec", marker = id,
					deaths = 0, shots = 100, hits = 20, longestStreak = 2, cleared = true })
				expect(result.total > 0).to.equal(true)
			end
		end)
	end)
end
