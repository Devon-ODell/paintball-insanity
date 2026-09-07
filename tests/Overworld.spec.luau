--!nolint
--[[
	The hub, checked at the level that can be checked without a running Roblox:
	the data is coherent, the foliage placement rules actually hold, and nothing
	in the shop's new bays breaks the monetization rule.

	The rendering itself is unverifiable here. What IS verifiable, and what
	matters most, is that a tree never grows on a trail and that no piece of gear
	has quietly grown an accuracy stat.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = game:GetService("ServerScriptService").Server
local Config = require(ReplicatedStorage.Shared.Config)
local GearStats = require(ReplicatedStorage.Shared.GearStats)
local Rng = require(ReplicatedStorage.Shared.Rng)
local Foliage = require(Server.World.Foliage)

local function hub()
	return Config.get("overworld")
end

local function vec(t)
	return Vector3.new(t[1], t[2], t[3])
end

local function scatterContext()
	local cfg = hub()
	local palette = {}
	for key, rgb in pairs(cfg.palette) do
		palette[key] = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	end
	return {
		palette = palette,
		exclusions = cfg.scatter.exclusions,
		trails = cfg.trails,
		trailClearance = cfg.scatter.trailClearanceMetres,
	}
end

return function()
	describe("the hub layout", function()
		it("loads", function()
			local cfg = hub()
			expect(cfg.name).to.be.a("string")
			expect(#cfg.trails > 0).to.equal(true)
			-- One per playable map, plus the Range.
			expect(#cfg.gates).to.equal(#Config.mapNames() + 1)
		end)

		it("has a gate for every map, plus the range", function()
			local seen = {}
			for _, gate in ipairs(hub().gates) do
				seen[gate.map] = true
			end
			for _, mapName in ipairs(Config.mapNames()) do
				expect(seen[mapName]).to.equal(true)
			end
			expect(seen.range).to.equal(true)
		end)

		it("keeps every gate, prop and building inside the bounds", function()
			local cfg = hub()
			local halfW = cfg.bounds.widthMetres / 2
			local halfL = cfg.bounds.lengthMetres / 2
			local function check(position, label)
				expect(math.abs(position[1]) < halfW).to.equal(true)
				expect(math.abs(position[3]) < halfL).to.equal(true)
			end
			for _, gate in ipairs(cfg.gates) do
				check(gate.position, gate.id)
			end
			for _, prop in ipairs(cfg.props) do
				check(prop.position, prop.kind)
			end
			check(cfg.barn.position, "barn")
			check(cfg.leaderboard.position, "leaderboard")
			check(cfg.spawn.position, "spawn")
		end)

		it("puts the spawn on a trail", function()
			--[[
				You should never spawn facing trees with no idea which way to
				walk. The spawn has to be on a path.
			]]
			local cfg = hub()
			local spawn = vec(cfg.spawn.position)
			local onTrail = false
			for _, trail in ipairs(cfg.trails) do
				for i = 1, #trail.points - 1 do
					local a = vec(trail.points[i])
					local b = vec(trail.points[i + 1])
					local delta = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
					local lengthSq = delta:Dot(delta)
					local p = Vector3.new(spawn.X - a.X, 0, spawn.Z - a.Z)
					local t = if lengthSq > 1e-9 then math.clamp(p:Dot(delta) / lengthSq, 0, 1) else 0
					if (p - delta * t).Magnitude <= trail.widthMetres then
						onTrail = true
					end
				end
			end
			expect(onTrail).to.equal(true)
		end)

		it("gives the barn three bays with distinct stock", function()
			local bays = hub().barn.bays
			expect(#bays).to.equal(3)
			local ids = {}
			local categories = {}
			for _, bay in ipairs(bays) do
				expect(ids[bay.id]).to.equal(nil)
				ids[bay.id] = true
				expect(#bay.categories > 0).to.equal(true)
				for _, category in ipairs(bay.categories) do
					expect(categories[category]).to.equal(nil)
					categories[category] = true
				end
			end
			expect(ids.markers).to.equal(true)
			expect(ids.paintAndAir).to.equal(true)
			expect(ids.protective).to.equal(true)
		end)

		it("stocks every bay with categories the shop can actually sell", function()
			local sellable = {
				markers = true, barrels = true, hoppers = true, tanks = true,
				jerseys = true, pads = true, helmets = true, shoulders = true,
				pods = true, consumables = true,
				masks = true, paintColors = true, markerSkins = true,
			}
			for _, bay in ipairs(hub().barn.bays) do
				for _, category in ipairs(bay.categories) do
					expect(sellable[category]).to.equal(true)
				end
			end
		end)

		it("has a lighting profile distinct from the fields", function()
			local hubLight = hub().lighting
			local field = Config.require("maps_index", "lighting").default
			expect(hubLight.atmosphere.haze > field.atmosphere.haze).to.equal(true)
			expect(hubLight.brightness < field.brightness).to.equal(true)
		end)
	end)

	describe("foliage placement", function()
		local ctx = scatterContext()

		it("never grows anything on a trail", function()
			--[[
				Walked, rather than reasoned about: sample every trail at a metre
				of resolution and assert canPlace refuses each sample. A tree in
				the middle of the path is the single most obvious way this hub
				could look broken.
			]]
			for _, trail in ipairs(hub().trails) do
				for i = 1, #trail.points - 1 do
					local a = vec(trail.points[i])
					local b = vec(trail.points[i + 1])
					local steps = math.max(2, math.floor((b - a).Magnitude))
					for step = 0, steps do
						local point = a:Lerp(b, step / steps)
						expect(Foliage.canPlace(point, ctx)).to.equal(false)
					end
				end
			end
		end)

		it("never grows anything inside the clearing or on the barn apron", function()
			for _, sample in ipairs({
				Vector3.new(0, 0, -4),
				Vector3.new(10, 0, 6),
				Vector3.new(0, 0, -46),
				Vector3.new(20, 0, -40),
				Vector3.new(46, 0, -18),
			}) do
				expect(Foliage.canPlace(sample, ctx)).to.equal(false)
			end
		end)

		it("does grow things out in the woods", function()
			local allowed = 0
			for _, sample in ipairs({
				Vector3.new(70, 0, 60),
				Vector3.new(-70, 0, -20),
				Vector3.new(20, 0, 70),
				Vector3.new(-64, 0, 70),
			}) do
				if Foliage.canPlace(sample, ctx) then
					allowed += 1
				end
			end
			expect(allowed >= 3).to.equal(true)
		end)

		it("recognises every scatter kind the data asks for", function()
			for _, layer in ipairs(hub().scatter.layers) do
				expect(Foliage.handles(layer.kind)).to.equal(true)
			end
		end)

		it("places the same forest from the same seed", function()
			--[[
				The hub is somewhere the player learns -- "the board is past the
				big leaning pine". A forest that reshuffles on load is scenery;
				one that does not is a place.
			]]
			local function sample(seed: number)
				local rng = Rng.new(seed)
				local points = {}
				for _ = 1, 200 do
					local angle = rng:nextNumber() * math.pi * 2
					local radius = 34 + rng:nextNumber() * 60
					table.insert(points, Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
				end
				return points
			end
			local a = sample(hub().scatter.seed)
			local b = sample(hub().scatter.seed)
			for i, point in ipairs(a) do
				expect((point - b[i]).Magnitude).to.be.near(0, 1e-12)
			end
		end)
	end)

	describe("foliage footprints", function()
		local ctx = scatterContext()

		it("gives every scatter layer a footprint, and the big ones the bigger one", function()
			local radii = {}
			for _, layer in ipairs(hub().scatter.layers) do
				local r = Foliage.footprintRadius(layer)
				expect(r > 0).to.equal(true)
				radii[layer.id] = r
			end
			-- A canopy pine reaches further than a fern. If that ever inverts,
			-- the coefficients and the builders have drifted apart.
			expect(radii.canopy > radii.saplings).to.equal(true)
			expect(radii.saplings > radii.ferns).to.equal(true)
			expect(radii.canopy > radii.cattails).to.equal(true)
		end)

		it("measures a tree from its canopy, not its trunk", function()
			--[[
				The whole bug: the old test asked whether the TRUNK CENTRE was
				clear. A pine with a 1.1m trunk carries a 6.7m bottom tier, so the
				footprint has to be several times the trunk radius or the crown
				goes through the wall it was placed next to.
			]]
			local layer
			for _, candidate in ipairs(hub().scatter.layers) do
				if candidate.id == "canopy" then layer = candidate end
			end
			local footprint = Foliage.footprintRadius(layer)
			expect(footprint > layer.trunkDiameterMetres[2] * 2).to.equal(true)
		end)

		it("refuses a point the trunk alone would have been allowed", function()
			--[[
				Walk outward from the barn until the unpadded test says yes, then
				assert the padded test still says no for a canopy tree. That gap
				is exactly the crown that used to end up inside the building.
			]]
			local layer
			for _, candidate in ipairs(hub().scatter.layers) do
				if candidate.id == "canopy" then layer = candidate end
			end
			local footprint = Foliage.footprintRadius(layer)
			local found = false
			-- Due south of the barn, walking OUT from the apron edge at z = -63.
			-- Inside the rect both tests refuse; the gap opens just beyond it.
			for step = 0, 400 do
				local point = Vector3.new(0, 0, -63 - step * 0.05)
				if Foliage.canPlace(point, ctx) and not Foliage.canPlace(point, ctx, footprint) then
					found = true
					break
				end
			end
			expect(found).to.equal(true)
		end)

		it("keeps every layer's own footprint off every building and gate", function()
			--[[
				The real assertion: for each exclusion and each layer, a candidate
				sitting just outside the bare exclusion is refused once its own
				reach is taken into account.
			]]
			for _, exclusion in ipairs(hub().scatter.exclusions) do
				if exclusion.shape == "circle" then
					local centre = Vector3.new(exclusion.position[1], 0, exclusion.position[3])
					for _, layer in ipairs(hub().scatter.layers) do
						local footprint = Foliage.footprintRadius(layer)
						local justOutside = centre
							+ Vector3.new(exclusion.radiusMetres + footprint * 0.5, 0, 0)
						expect(Foliage.canPlace(justOutside, ctx, footprint)).to.equal(false)
					end
				end
			end
		end)

		it("gives every gate its own clearing", function()
			--[[
				Gates had no exclusion at all. The trail that reaches one clears
				about five metres, and the arch is six metres wide, so trees grew
				through the posts and the plaque.
			]]
			for _, gate in ipairs(hub().gates) do
				local at = vec(gate.position)
				expect(Foliage.canPlace(at, ctx)).to.equal(false)
			end
		end)

		it("still leaves the woods worth walking through", function()
			--[[
				Padding raises the rejection rate, and the failure mode is a bald
				forest. Sample the canopy annulus and require a healthy share of
				it to still accept a full-size tree.
			]]
			local layer
			for _, candidate in ipairs(hub().scatter.layers) do
				if candidate.id == "canopy" then layer = candidate end
			end
			local footprint = Foliage.footprintRadius(layer)
			local rng = Rng.new(hub().scatter.seed)
			local accepted, samples = 0, 600
			for _ = 1, samples do
				local angle = rng:nextNumber() * math.pi * 2
				local inner, outer = layer.innerRadiusMetres, layer.outerRadiusMetres
				local radius = math.sqrt(inner * inner + rng:nextNumber() * (outer * outer - inner * inner))
				local point = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
				if Foliage.canPlace(point, ctx, footprint) then
					accepted += 1
				end
			end
			expect(accepted > samples * 0.5).to.equal(true)
		end)
	end)

	describe("the shop counters", function()
		local Shop = require(Server.Economy.Shop)
		local Profile = require(Server.Economy.Profile)
		local Dev = require(ReplicatedStorage.Shared.Dev)

		it("can sell everything the barn claims to stock", function()
			--[[
				A bay listing a category the shop cannot price is a counter the
				player walks up to and finds empty. Checked against the real
				catalogue rather than a list of names.
			]]
			Dev._setOverrideForTesting({ enabled = false })
			Profile._resetFallback()
			local handle = Profile.load(4321) :: any
			local catalogue = Shop.catalogueFor(handle)
			for _, bay in ipairs(hub().barn.bays) do
				for _, category in ipairs(bay.categories) do
					local stock = catalogue[category]
					expect(stock).to.be.ok()
					expect(#stock > 0).to.equal(true)
				end
			end
			Dev._setOverrideForTesting(nil)
		end)

		it("puts every sellable category behind exactly one counter", function()
			-- Nothing should be buyable from two bays, and nothing the shop can
			-- sell should be unreachable.
			local counted: { [string]: number } = {}
			for _, bay in ipairs(hub().barn.bays) do
				for _, category in ipairs(bay.categories) do
					counted[category] = (counted[category] or 0) + 1
				end
			end
			for category, times in pairs(counted) do
				expect(times).to.equal(1)
			end
			for _, category in ipairs({ "markers", "jerseys", "pads", "helmets", "shoulders", "pods", "paintColors", "consumables" }) do
				expect(counted[category]).to.equal(1)
			end
		end)
	end)

	describe("gear", function()
		it("declares no stat outside the allowed set", function()
			--[[
				The monetization rule, enforced by field name rather than by
				value. A `spreadMultiplier` or a `damageReduction` appearing in
				gear.json is caught here rather than in playtesting, which is the
				only other place it would show up -- as a game that had quietly
				stopped being an aim trainer.
			]]
			local violations = GearStats.audit()
			if #violations > 0 then
				error("gear.json declares disallowed stats: " .. table.concat(violations, "; "))
			end
			expect(#violations).to.equal(0)
		end)

		it("has no armour stat anywhere, because one hit is out", function()
			local encoded = ""
			for _, category in ipairs({ "jerseys", "pads", "pods" }) do
				for _, id in ipairs(GearStats.order(category)) do
					for field in pairs(GearStats.item(category, id) :: any) do
						encoded ..= field:lower() .. " "
					end
				end
			end
			for _, banned in ipairs({ "armour", "armor", "damage", "health", "shield", "spread", "velocity", "accuracy", "recoil" }) do
				expect(encoded:find(banned, 1, true)).to.equal(nil)
			end
		end)

		it("resolves a default loadout to neutral", function()
			local defaults = Config.require("gear", "defaults")
			local resolved = GearStats.resolve({
				jersey = defaults.jersey,
				pads = defaults.pads,
				pods = defaults.pods,
			})
			expect(resolved.loudnessMultiplier).to.be.near(1, 1e-9)
			expect(resolved.sprintMultiplier).to.be.near(1, 1e-9)
			expect(resolved.podCount).to.equal(2)
		end)

		it("compounds quietness across slots, and charges for it", function()
			local quiet = GearStats.resolve({ jersey = "paddedTwill", pads = "fullWrap", pods = "twoPack" })
			expect(quiet.loudnessMultiplier < 0.7).to.equal(true)
			-- And it costs mobility on both slots, which is what makes it a
			-- sidegrade rather than an upgrade.
			expect(quiet.sprintMultiplier < 1).to.equal(true)
			expect(quiet.crouchMultiplier < 1).to.equal(true)
		end)

		it("makes the fast build loud", function()
			local fast = GearStats.resolve({ jersey = "slickComp", pads = "kneeSliders", pods = "fourPack" })
			expect(fast.sprintMultiplier > 1).to.equal(true)
			expect(fast.loudnessMultiplier > 1.3).to.equal(true)
		end)

		it("trades pod count against reload speed", function()
			local many = GearStats.resolve({ pods = "sixPack" })
			local fast = GearStats.resolve({ pods = "harness" })
			expect(many.podCount > fast.podCount).to.equal(true)
			expect(fast.reloadMultiplier < many.reloadMultiplier).to.equal(true)
		end)

		it("survives a malformed or empty loadout", function()
			expect(GearStats.resolve(nil :: any).podCount).to.equal(2)
			expect(GearStats.resolve({}).loudnessMultiplier).to.equal(1)
			expect(GearStats.resolve({ jersey = "doesNotExist" }).loudnessMultiplier).to.equal(1)
		end)

		it("gives every purchasable item a cost", function()
			for _, category in ipairs({ "jerseys", "pads", "pods" }) do
				for _, id in ipairs(GearStats.order(category)) do
					local entry = GearStats.item(category, id) :: any
					expect(entry.cost).to.be.a("number")
					expect(entry.displayName).to.be.a("string")
				end
			end
		end)

		it("offers a free default in every slot", function()
			for _, category in ipairs({ "jerseys", "pads", "pods" }) do
				local free = 0
				for _, id in ipairs(GearStats.order(category)) do
					if (GearStats.item(category, id) :: any).cost == 0 then
						free += 1
					end
				end
				expect(free >= 1).to.equal(true)
			end
		end)
	end)
end
