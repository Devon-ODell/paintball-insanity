--!nolint
--[[
	Phase 5 acceptance for the parts that can be decided without rendering:
	every map loads, every nav graph is fully connected (bots cannot strand),
	anchors reference real cover, and the three maps genuinely differ in
	engagement distance. If Woods and Speedball produce similar distance
	profiles the maps have failed at their purpose, so that is asserted here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MapGeometry = require(ReplicatedStorage.Shared.MapGeometry)
local Config = require(ReplicatedStorage.Shared.Config)
local Inflatables = require(game:GetService("ServerScriptService").Server.Match.Inflatables)

local function worldFor(name: string)
	return MapGeometry.build(Config.map(name), Config.get("maps_index"))
end

--- Median distance from each bot anchor to the player's spawn side, which is
--- the cheap proxy for where fights actually happen on a map.
local function anchorDistances(world: any): { number }
	local out = {}
	local spawn = Vector3.new(
		world.playerSpawn.position[1],
		world.playerSpawn.position[2],
		world.playerSpawn.position[3]
	)
	for _, anchor in ipairs(world.anchors) do
		local p = Vector3.new(anchor.position[1], anchor.position[2], anchor.position[3])
		table.insert(out, (p - spawn).Magnitude)
	end
	table.sort(out)
	return out
end

local function median(values: { number }): number
	local n = #values
	if n == 0 then
		return 0
	end
	if n % 2 == 1 then
		return values[(n + 1) // 2]
	end
	return (values[n // 2] + values[n // 2 + 1]) / 2
end

return function()
	local names = Config.mapNames()

	describe("every map", function()
		for _, name in ipairs(names) do
			describe(name, function()
				local world = worldFor(name)

				it("builds volumes and nav nodes", function()
					expect(#world.volumes > 0).to.equal(true)
					expect(#world.navNodes >= 20).to.equal(true)
				end)

				it("has a fully connected nav graph", function()
					expect(MapGeometry.isConnected(world)).to.equal(true)
				end)

				it("puts no nav node inside cover", function()
					-- A node buried in a bunker is a place a bot will path to
					-- and then be unable to stand. tools/map-validate reports
					-- these; this keeps them from coming back.
					local probe = Config.get("maps_index").assembly.coverProbeHeightMetres
					local buried = MapGeometry.nodesInsideCover(world, probe)
					expect(#buried).to.equal(0)
				end)

				it("can path between the two furthest nav nodes", function()
					local first = MapGeometry.nearestNavNode(world, Vector3.new(
						world.playerSpawn.position[1],
						world.playerSpawn.position[2],
						world.playerSpawn.position[3]
					))
					for i = 1, #world.navNodes do
						expect(MapGeometry.findPath(world, first, i)).to.be.ok()
					end
				end)

				it("gives every bot a spawn", function()
					--[[
						Enough authored spawns to open a round without the squad
						piling up, but NOT necessarily one per bot. Speedball
						fields twelve from six on purpose: every arrangement of
						twelve spawn points measurably damaged the field, either
						inverting how it punishes trading or flattening the
						difficulty curve at the top tier. MatchService fans reused
						spawns onto a ring rather than stacking them, and
						run-live-checks asserts no two bots start on top of each
						other.
					]]
					expect(#world.botSpawns >= 6).to.equal(true)
					local seen = {}
					for _, spawn in ipairs(world.botSpawns) do
						local key = `{spawn.position[1]},{spawn.position[3]}`
						expect(seen[key]).to.equal(nil)
						seen[key] = true
					end
				end)

				it("covers all three squad roles with its anchors", function()
					local seen = {}
					for _, anchor in ipairs(world.anchors) do
						for _, role in ipairs(anchor.roles) do
							seen[role] = (seen[role] or 0) + 1
						end
					end
					expect((seen.anchor or 0) >= 2).to.equal(true)
					expect((seen.flanker or 0) >= 2).to.equal(true)
					expect((seen.pressure or 0) >= 2).to.equal(true)
				end)

				it("only references cover volumes that exist", function()
					for _, anchor in ipairs(world.anchors) do
						if anchor.coverId then
							expect(MapGeometry.hasPiece(world, anchor.coverId)).to.equal(true)
						end
					end
				end)

				it("only pre-places from anchors that exist", function()
					local anchorIds: { [string]: boolean } = {}
					for _, a in ipairs(world.anchors) do
						anchorIds[a.id] = true
					end
					for _, p in ipairs(world.prePlacement) do
						expect(anchorIds[p.anchorId]).to.equal(true)
					end
				end)

				it("keeps every anchor inside the map bounds", function()
					local b = world.bounds
					for _, anchor in ipairs(world.anchors) do
						expect(math.abs(anchor.position[1]) <= b.widthMetres / 2 + 2).to.equal(true)
						expect(math.abs(anchor.position[3]) <= b.lengthMetres / 2 + 2).to.equal(true)
					end
				end)
			end)
		end
	end)

	describe("buildable shapes", function()
		--[[
			WorldBuilder dispatches on the JSON `shape` string. A typo there
			produces a silently wrong bunker at runtime rather than an error, so
			the whole vocabulary is pinned here instead.
		]]
		local PRIMITIVES = { box = true, cylinder = true, wedge = true }

		it("only uses shapes the builder knows", function()
			for _, name in ipairs(names) do
				local mapData = Config.map(name)
				for _, group in ipairs({ mapData.terrain, mapData.geometry }) do
					if not group then
						continue
					end
					for _, piece in ipairs(group) do
						local known = PRIMITIVES[piece.shape] or Inflatables.handles(piece.shape)
						if not known then
							error(`{name}: piece '{piece.id}' has unknown shape '{piece.shape}'`)
						end
					end
				end
			end
		end)

		it("builds Speedball entirely out of inflatables", function()
			-- Speedball is a tournament field. Every piece of cover on it is a
			-- pressurised bunker, and none of it is a concrete block.
			for _, piece in ipairs(Config.map("speedball").geometry) do
				expect(Inflatables.handles(piece.shape)).to.equal(true)
			end
		end)

		it("recognises every inflatable family", function()
			--[[
				The vocabulary of a speedball field, and only simple shapes.
				`temple` was a four-sided body with rounded corners and a domed
				top; it read as a turret at distance and there are no turrets on
				a paintball field. It is a BALL now, and STANDUP was added for
				the upright rectangle -- BRICK is the one lying down.
			]]
			for _, shape in ipairs({ "can", "dorito", "snake", "ball", "standup", "brick" }) do
				expect(Inflatables.handles("inflatable_" .. shape)).to.equal(true)
				expect(Inflatables.handles(shape)).to.equal(true)
			end
			expect(Inflatables.handles("inflatable_nonsense")).to.equal(false)
			-- The turret is gone and must not come back by accident.
			expect(Inflatables.handles("temple")).to.equal(false)
			expect(Inflatables.handles("box")).to.equal(false)
		end)

		it("gives every map a lighting profile", function()
			local lighting = Config.require("maps_index", "lighting")
			expect(lighting.default).to.be.ok()
			for _, name in ipairs(names) do
				expect(lighting.perMap[name]).to.be.ok()
			end
		end)
	end)

	describe("line of sight", function()
		local world = worldFor("speedball")

		it("is blocked by cover", function()
			-- Straight through the centre temple at chest height.
			local a = Vector3.new(0, 1.3, -8)
			local b = Vector3.new(0, 1.3, 8)
			expect(MapGeometry.hasLineOfSight(world, a, b)).to.equal(false)
		end)

		it("is clear down an open lane", function()
			-- Along the back of the player's half, clear of the home cans.
			local a = Vector3.new(-9, 1.3, -25)
			local b = Vector3.new(9, 1.3, -25)
			expect(MapGeometry.hasLineOfSight(world, a, b)).to.equal(true)
		end)

		it("lets paint through brush that blocks sight", function()
			local woods = worldFor("woods")
			-- brush_a sits at (-4, 1, 18) and is 9 x 2 x 5 m.
			local a = Vector3.new(-4, 1.2, 12)
			local b = Vector3.new(-4, 1.2, 24)
			expect(MapGeometry.hasLineOfSight(woods, a, b)).to.equal(false)
			expect(MapGeometry.paintCanReach(woods, a, b)).to.equal(true)
		end)
	end)

	describe("the curriculum", function()
		--[[
			BUILD_PLAN Phase 5: "If Woods and Speedball produce similar distance
			profiles, the maps have failed at their purpose."
		]]
		it("orders the maps by engagement distance", function()
			local previous = 0
			for _, name in ipairs(names) do
				local band = worldFor(name).engagementBand
				expect(band.targetMedianMetres > previous).to.equal(true)
				previous = band.targetMedianMetres
			end
		end)

		it("separates Speedball and Woods by more than a factor of two", function()
			local speedball = worldFor("speedball").engagementBand
			local woods = worldFor("woods").engagementBand
			expect(woods.targetMedianMetres / speedball.targetMedianMetres > 2.0).to.equal(true)
		end)

		it("backs the declared bands up with actual anchor geometry", function()
			for _, name in ipairs(names) do
				local world = worldFor(name)
				local med = median(anchorDistances(world))
				local band = world.engagementBand
				-- Anchors sit further out than the median fight, since fights
				-- happen as the player pushes in. Allow a generous window but
				-- catch a map whose geometry contradicts its own declared band.
				expect(med > band.minMetres).to.equal(true)
				expect(med < band.maxMetres * 1.6).to.equal(true)
			end
		end)

		--[[
			Per-field lighting, constrained by the two things it can break.

			A bot has to read as the most saturated thing on screen on every
			field, and a dim field breaks that before it looks moody -- so
			brightness lives in a narrow band. And haze has to scale with the
			field's own engagement band: distance haze sells scale at 46 m and
			just greys out the target at 16 m.
		]]
		it("lights every field differently, inside the band that keeps targets readable", function()
			local lighting = Config.require("maps_index", "lighting")
			local seenHours: { [string]: boolean } = {}
			for _, name in ipairs(names) do
				local profile = lighting.perMap[name]
				expect(profile).to.be.ok()

				local brightness = profile.brightness or lighting.default.brightness
				expect(brightness >= 2.3).to.equal(true)
				expect(brightness <= 2.8).to.equal(true)

				-- Two fields sharing an hour would be two fields sharing a look.
				local hour = tostring(profile.clockTime)
				expect(seenHours[hour]).to.equal(nil)
				seenHours[hour] = true
			end
		end)

		it("hazes a field in proportion to how far it asks you to shoot", function()
			local lighting = Config.require("maps_index", "lighting")
			local previousBand, previousHaze = -1, -1
			for _, name in ipairs(Config.mapNames()) do
				local world = worldFor(name)
				local profile = lighting.perMap[name]
				local haze = (profile.atmosphere or {}).haze or lighting.default.atmosphere.haze
				local band = world.engagementBand.targetMedianMetres
				if previousBand >= 0 then
					-- maps_index.order is the curriculum, ascending by distance.
					expect(band > previousBand).to.equal(true)
					expect(haze >= previousHaze).to.equal(true)
				end
				previousBand, previousHaze = band, haze
			end
		end)

		it("never blurs the distance on a field you have to shoot across", function()
			--[[
				Far depth of field looks wonderful and costs you the target you
				were about to shoot. On an aim trainer that is the one trade that
				is never worth making, so it stays off on every field.
			]]
			local lighting = Config.require("maps_index", "lighting")
			for _, name in ipairs(names) do
				local dof = (lighting.perMap[name] or {}).depthOfField or lighting.default.depthOfField
				expect(dof.farIntensity).to.equal(0)
			end
		end)

		it("gives every map at least one sightline near its maximum band", function()
			for _, name in ipairs(names) do
				local world = worldFor(name)
				local longest = 0
				for _, s in ipairs(world.sightlines) do
					if s.lengthMetres > longest then
						longest = s.lengthMetres
					end
				end
				expect(longest >= world.engagementBand.maxMetres * 0.85).to.equal(true)
			end
		end)
	end)
end
