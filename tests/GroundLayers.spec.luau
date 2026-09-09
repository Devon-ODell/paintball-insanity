--!strict
local RS = game:GetService("ReplicatedStorage")
local GroundLayers = require(RS.Shared.GroundLayers)
local Config = require(RS.Shared.Config)

return function()
	describe("ground surface planning", function()
		it("reuses low levels for disjoint surfaces and separates crossings", function()
			local function trail(z: number): any
				return { widthMetres = 2, points = { { -5, 0, z }, { 5, 0, z } } }
			end
			local plan = GroundLayers.plan({}, { trail(0), trail(20), trail(0) }, 0.01)
			expect(plan.trails[1].segments[1]).to.equal(plan.trails[2].segments[1])
			expect(plan.trails[1].segments[1] ~= plan.trails[3].segments[1]).to.equal(true)
			expect(plan.trails[1].segments[1] ~= plan.trails[1].joins[1]).to.equal(true)
		end)
		it("keeps paths above overlapping zones in painter order", function()
			local zones = {
				{ shape = "circle", radiusMetres = 8, position = { 0, 0, 0 } },
				{ shape = "box", size = { 4, 4 }, position = { 0, 0, 0 } },
			}
			local plan = GroundLayers.plan(zones, {
				{ widthMetres = 1, points = { { -5, 0, 0 }, { 5, 0, 0 } } },
			}, 0.01)
			expect(plan.zones[2] > plan.zones[1]).to.equal(true)
			expect(plan.trails[1].segments[1] > plan.zones[2]).to.equal(true)
		end)
		it("reserves fixed building floors without raising unrelated trails", function()
			local barn = { position = { 0, 0, 0 }, widthMetres = 10, depthMetres = 10,
				groundSurfaces = { Floor = { centerY = 0, thickness = 0.04, overhang = 0 } } }
			local plan = GroundLayers.plan({}, {
				{ widthMetres = 1, points = { { -2, 0, 0 }, { 2, 0, 0 } } },
				{ widthMetres = 1, points = { { -2, 0, 20 }, { 2, 0, 20 } } },
			}, 0.012, barn)
			expect(math.abs(plan.trails[1].segments[1] - 0.02) >= 0.012).to.equal(true)
			expect(plan.trails[2].segments[1]).to.equal(0.012)
		end)
		it("separates the first and last join of a closed path", function()
			local plan = GroundLayers.plan({}, {
				{ widthMetres = 2, points = { { 0, 0, 0 }, { 5, 0, 0 }, { 5, 0, 5 }, { 0, 0, 0 } } },
			}, 0.01)
			expect(plan.trails[1].segments[1] ~= plan.trails[1].joins[3]).to.equal(true)
		end)
		it("aligns a buried slab with its path in every quadrant without pitching", function()
			for _, x in ipairs({ -7, 7 }) do
				for _, z in ipairs({ -6, 6 }) do
					local delta = Vector3.new(x, 0, z)
					local centre = Vector3.new(2, -0.2, 4)
					local frame = GroundLayers.frame(centre, delta)
					expect(math.abs(frame.LookVector:Dot(delta.Unit)) > 0.9999).to.equal(true)
					expect(frame.UpVector:Dot(Vector3.yAxis) > 0.9999).to.equal(true)
					expect((frame.Position - centre).Magnitude < 0.0001).to.equal(true)
				end
			end
		end)
		it("keeps the authored hub surface stack below thirteen centimetres", function()
			local cfg = Config.get("overworld")
			local plan = GroundLayers.plan(cfg.zones, cfg.trails, cfg.surfaceLayerMetres.alternateMetres, cfg.barn)
			expect(plan.maxHeight < 0.13).to.equal(true)
		end)
	end)
end
