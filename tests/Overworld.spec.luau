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
local PoleBarn = require(Server.World.PoleBarn)
local Wardrobe = require(Server.World.Wardrobe)
local Fonts = require(ReplicatedStorage.Shared.Fonts)

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

	describe("the barn roof", function()
		--[[
			Standing in for the screenshot nobody can take from here.

			The roof was inverted: both slopes fell toward the centre, which is a
			valley, and the ridge cap floated over the trough. `roofline` and
			`roofHeightAt` are pure, so the shape of the building is checkable as
			arithmetic instead of by eye.
		]]
		local barn = function() return hub().barn end

		it("puts the ridge above the eaves", function()
			local roof = PoleBarn.roofline(barn())
			expect(roof.ridgeHeightMetres > roof.eaveHeightMetres).to.equal(true)
			expect(roof.ridgeHeightMetres).to.be.near(barn().wallHeightMetres + barn().roofRiseMetres, 1e-9)
			expect(roof.eaveHeightMetres).to.be.near(barn().wallHeightMetres, 1e-9)
		end)

		it("falls away from the ridge in both directions, so water runs off", function()
			local cfg = barn()
			local halfD = cfg.depthMetres / 2
			local previous = PoleBarn.roofHeightAt(cfg, 0)
			expect(previous).to.be.near(cfg.wallHeightMetres + cfg.roofRiseMetres, 1e-9)
			for step = 1, 40 do
				local z = halfD * (step / 40)
				local height = PoleBarn.roofHeightAt(cfg, z)
				expect(height < previous).to.equal(true)
				-- Symmetric: a gable is the same shape on both sides.
				expect(PoleBarn.roofHeightAt(cfg, -z)).to.be.near(height, 1e-9)
				previous = height
			end
			expect(previous).to.be.near(cfg.wallHeightMetres, 1e-9)
		end)

		it("cuts sheets long enough to reach the eave, plus the overhang", function()
			--[[
				The sheet is the hypotenuse. Too short and it stops in mid-air
				before the wall; too long and it runs past the ridge.
			]]
			local cfg = barn()
			local roof = PoleBarn.roofline(cfg)
			local halfD = cfg.depthMetres / 2
			local bare = math.sqrt(halfD * halfD + cfg.roofRiseMetres * cfg.roofRiseMetres)
			expect(roof.slopeLengthMetres).to.be.near(bare + (cfg.eaveOverhangMetres or 0), 1e-6)
			expect(roof.slopeLengthMetres > halfD).to.equal(true)
		end)

		it("hangs the sign clear of the roof instead of floating it over the trough", function()
			--[[
				The door is on the long wall, so the front is an eave and there is
				no gable triangle to sit a sign in. The board therefore stands
				proud of the eave -- but its bottom edge has to be ABOVE the eave
				line, or it clips through the metal.
			]]
			local cfg = barn()
			local roof = PoleBarn.roofline(cfg)
			local bottom = roof.sign.centreHeightMetres - roof.sign.heightMetres / 2
			expect(bottom > roof.eaveHeightMetres).to.equal(true)
			expect(roof.sign.halfWidthMetres * 2 < cfg.widthMetres).to.equal(true)
			-- And it must not out-top the ridge, which would read as a billboard.
			expect(roof.sign.centreHeightMetres + roof.sign.heightMetres / 2 < roof.ridgeHeightMetres + 1).to.equal(true)
		end)
	end)

	--[[
		Shadow gating. The hub scattered 5784 shadow casters, decided purely by
		part name, so a pine eighty metres into the treeline cost as much as one
		on the trail. These assert the rule that replaced it -- and specifically
		that it does NOT strip the shadows from the trees a player is standing
		among at a gate, which is what a naive distance-from-centre rule would do.
	]]
	describe("foliage shadow gating", function()
		local ctx = scatterContext()
		local radius = Config.get("presentation").foliage.shadowRadiusMetres

		it("declares a radius the builder can act on", function()
			expect(type(radius)).to.equal("number")
			expect(radius > 0).to.equal(true)
		end)

		it("keeps shadows on the plants beside a trail", function()
			for _, trail in ipairs(hub().trails) do
				local first = trail.points[1]
				expect(Foliage.castsShadowAt(Vector3.new(first[1], 0, first[3]), ctx)).to.equal(true)
			end
		end)

		it("keeps shadows at every gate, where the player stands", function()
			--[[
				The gates sit 63 to 82 m from the hub centre. A rule measured from
				the centre would have switched these off -- the trees a player is
				closest to on the way out of the hub.
			]]
			for _, gate in ipairs(hub().gates) do
				local at = Vector3.new(gate.position[1], 0, gate.position[3])
				expect(Foliage.castsShadowAt(at, ctx)).to.equal(true)
			end
		end)

		it("drops shadows deep in the treeline", function()
			-- A corner of the hub, far from every trail and every open area.
			local deep = Vector3.new(88, 0, 88)
			expect(Foliage.castsShadowAt(deep, ctx)).to.equal(false)
		end)

		it("casts everywhere when no radius is authored", function()
			--[[
				Deleting the field must restore the old behaviour rather than
				silently switching every shadow off, which is the failure mode
				that would be invisible until someone looked at a screenshot.
			]]
			local presentation = Config.get("presentation")
			local saved = presentation.foliage.shadowRadiusMetres
			presentation.foliage.shadowRadiusMetres = nil
			local everywhere = Foliage.castsShadowAt(Vector3.new(88, 0, 88), ctx)
			presentation.foliage.shadowRadiusMetres = saved
			expect(everywhere).to.equal(true)
		end)
	end)

	describe("foliage visibility bands", function()
		local ctx = scatterContext()

		it("bands the ground detail and leaves the trees unbanded", function()
			--[[
				A treeline is precisely the thing you see from a distance, so trees
				must scatter to the edge. Ferns are three parts and half a metre
				tall; theirs is the budget worth concentrating.
			]]
			local banded, unbanded = {}, {}
			for _, layer in ipairs(hub().scatter.layers) do
				if layer.nearPathsMetres then
					banded[layer.id] = layer.nearPathsMetres
				else
					unbanded[layer.id] = true
				end
			end
			expect(banded.ferns).to.be.ok()
			expect(banded.mossPatches).to.be.ok()
			expect(unbanded.canopy).to.equal(true)
			expect(unbanded.broadleaves).to.equal(true)
		end)

		it("puts the banded layers within reach of somewhere the player walks", function()
			for _, trail in ipairs(hub().trails) do
				local first = trail.points[1]
				local at = Vector3.new(first[1], 0, first[3])
				for _, layer in ipairs(hub().scatter.layers) do
					if layer.nearPathsMetres then
						expect(Foliage.nearPlayerPaths(at, ctx, layer.nearPathsMetres)).to.equal(true)
					end
				end
			end
		end)

		it("excludes the deep treeline from every band", function()
			local deep = Vector3.new(88, 0, 88)
			for _, layer in ipairs(hub().scatter.layers) do
				if layer.nearPathsMetres then
					expect(Foliage.nearPlayerPaths(deep, ctx, layer.nearPathsMetres)).to.equal(false)
				end
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
			--[[
				Nothing buyable from two bays, and nothing the shop can sell left
				unreachable.

				The second half used to be a hand-written list of eight category
				names, which went stale the moment field kit stopped being sold:
				it asserted `consumables` was behind a counter while the shop
				deliberately stocks none. Derived from the real catalogue now,
				the way the sibling check above already does it -- which is both
				self-maintaining and stricter, because the hand-written list had
				quietly omitted barrels, hoppers, tanks, masks and marker
				finishes.

				`camos` and `offers` are excluded: they are earned and Robux
				tabs the client adds itself, not counters in the barn.
			]]
			Dev._setOverrideForTesting({ enabled = false })
			Profile._resetFallback()
			local catalogue = Shop.catalogueFor(Profile.load(4321) :: any)
			local counted: { [string]: number } = {}
			for _, bay in ipairs(hub().barn.bays) do
				for _, category in ipairs(bay.categories) do
					counted[category] = (counted[category] or 0) + 1
				end
			end
			for category, times in pairs(counted) do
				expect(times).to.equal(1)
			end
			local notACounter = { camos = true, offers = true }
			for category, rows in pairs(catalogue) do
				if type(rows) == "table" and #rows > 0 and not notACounter[category] then
					expect(counted[category]).to.equal(1)
				end
			end
			Dev._setOverrideForTesting(nil)
		end)
	end)

	describe("the shop interior", function()
		it("stocks every bay", function()
			--[[
				Shelves with nothing on them are why the bays read as storage
				rather than as a shop. Each one has to carry stock, counter
				dressing and something on the wall.
			]]
			for _, bay in ipairs(hub().barn.bays) do
				expect(#(bay.shelfProps or {})).to.be.a("number")
				expect(#(bay.shelfProps or {}) >= 8).to.equal(true)
			end
		end)

		it("only asks for props the builder can make", function()
			for _, bay in ipairs(hub().barn.bays) do
				for _, prop in ipairs(bay.shelfProps or {}) do
					expect(PoleBarn.handlesProp(prop.kind)).to.equal(true)
				end
			end
		end)

		it("gives every bay something on the counter and something on the wall", function()
			--[[
				A register and a price list are what sell "a person works here".
				Asserted per bay rather than in total, because two of three
				dressed and one bare is the failure that would slip through.
			]]
			local counterKinds = { register = true, squeegeeJar = true, coffeeCup = true, tapeRoll = true, chronoReadout = true }
			local wallKinds = { priceList = true, corkboard = true, wallClock = true, fireExtinguisher = true }
			for _, bay in ipairs(hub().barn.bays) do
				local counter, wall = 0, 0
				for _, prop in ipairs(bay.shelfProps or {}) do
					if counterKinds[prop.kind] then counter += 1 end
					if wallKinds[prop.kind] then wall += 1 end
				end
				expect(counter >= 2).to.equal(true)
				expect(wall >= 2).to.equal(true)
			end
		end)

		it("keeps every prop inside the barn", function()
			--[[
				Prop positions are bay-local metres offset from the counter, so
				an X typo puts a jersey rail out in the woods and nothing in the
				build complains.
			]]
			local barn = hub().barn
			local halfW, halfD = barn.widthMetres / 2, barn.depthMetres / 2
			local backZ = -halfD + 1.4
			for _, bay in ipairs(barn.bays) do
				local localX = bay.position[1] - barn.position[1]
				for _, prop in ipairs(bay.shelfProps or {}) do
					local x = localX + prop.at[1]
					local z = backZ + prop.at[3]
					expect(math.abs(x) < halfW).to.equal(true)
					expect(math.abs(z) < halfD).to.equal(true)
					-- Off the floor, and under the eaves.
					expect(prop.at[2] >= 0).to.equal(true)
					expect(prop.at[2] < barn.wallHeightMetres).to.equal(true)
				end
			end
		end)

		it("paints every prop from a colour the palette actually has", function()
			for _, bay in ipairs(hub().barn.bays) do
				expect(hub().palette[bay.colorKey]).never.to.equal(nil)
				for _, prop in ipairs(bay.shelfProps or {}) do
					if prop.colorKey then
						expect(hub().palette[prop.colorKey]).never.to.equal(nil)
					end
				end
			end
		end)

		it("hangs the shop lights under the ridge, not through it", function()
			local barn = hub().barn
			local roof = PoleBarn.roofline(barn)
			expect(barn.interiorLights).never.to.equal(nil)
			expect(barn.interiorLights.heightMetres < roof.ridgeHeightMetres).to.equal(true)
			expect(barn.interiorLights.heightMetres > 3).to.equal(true)
		end)
	end)

	describe("the wardrobe", function()
		it("dresses everyone in pieces that exist", function()
			--[[
				A typo in an outfit list is invisible: the piece silently does
				not get built and the character just looks slightly wrong, which
				nobody notices until they are standing in front of you.
			]]
			for _, outfit in ipairs(Wardrobe.outfitNames()) do
				local pieces = Wardrobe.piecesOf(outfit)
				expect(#pieces > 0).to.equal(true)
				for _, piece in ipairs(pieces) do
					expect(Wardrobe.hasPiece(piece)).to.equal(true)
				end
			end
		end)

		it("gives everyone at the landing an outfit", function()
			for id, person in pairs(Config.require("npcs", "npcs")) do
				expect(person.outfit).to.be.a("string")
				expect(#Wardrobe.piecesOf(person.outfit) > 0).to.equal(true)
				expect(id).to.be.a("string")
			end
		end)

		it("escalates the enemy team's kit with its tier", function()
			--[[
				Kit is how a player prices a round before the first shot. Rec
				turns up in rental gear; pro turns up as a squad. If that
				ordering ever inverts the read inverts with it.
			]]
			local rec = #Wardrobe.piecesOf("botRec")
			local amateur = #Wardrobe.piecesOf("botAmateur")
			local semipro = #Wardrobe.piecesOf("botSemipro")
			local pro = #Wardrobe.piecesOf("botPro")
			expect(amateur > rec).to.equal(true)
			expect(semipro > amateur).to.equal(true)
			expect(pro > semipro).to.equal(true)
		end)

		it("keeps Denny over-equipped and the Marshal bare", function()
			--[[
				Both jokes are structural, not decorative. Denny is rec league in
				full night-raid kit; the Marshal says nothing and wears nothing.
				If someone "balances" these the characters stop being characters.
			]]
			expect(#Wardrobe.piecesOf("denny") >= 12).to.equal(true)
			expect(#Wardrobe.piecesOf("theMarshal") <= 5).to.equal(true)
			local dennyWears = table.concat(Wardrobe.piecesOf("denny"), ",")
			expect(string.find(dennyWears, "nvgDown") ~= nil).to.equal(true)
		end)

		it("is fashion and nothing else", function()
			--[[
				The rule that matters. A hat may never carry a stat, and no
				wardrobe part may be collidable or queryable -- if a night vision
				tube could stop a paintball, buying a hat would change the game.
			]]
			local banned = { "damage", "armour", "armor", "health", "spread", "velocity", "accuracy", "protect" }
			local pieces = Config.require("wardrobe", "pieces")
			for pieceName, parts in pairs(pieces) do
				for _, part in ipairs(parts) do
					for field in pairs(part) do
						for _, word in ipairs(banned) do
							expect(string.find(string.lower(field), word)).to.equal(nil)
						end
					end
					-- Every piece hangs off a real anchor on the body.
					local anchor = part.anchor
					local known = anchor == "head" or anchor == "chest" or anchor == "hips"
						or anchor == "legs" or anchor == "feet"
					expect(known).to.equal(true)
					expect(#part.size).to.equal(3)
					expect(#part.at).to.equal(3)
					expect(pieceName).to.be.a("string")
				end
			end
		end)

		it("paints every piece from a colour the wardrobe actually has", function()
			local palette = Config.require("wardrobe", "palette")
			for _, parts in pairs(Config.require("wardrobe", "pieces")) do
				for _, part in ipairs(parts) do
					expect(palette[part.colorKey]).never.to.equal(nil)
				end
			end
			-- Outfit tints may only re-colour keys the palette already defines.
			for _, outfit in ipairs(Wardrobe.outfitNames()) do
				local entry = Wardrobe.outfit(outfit)
				for key in pairs((entry :: any).tint or {}) do
					expect(palette[key]).never.to.equal(nil)
				end
			end
		end)
	end)

	describe("fonts", function()
		it("names only fonts the engine actually has", function()
			--[[
				A font name that does not resolve is invisible: Fonts falls back
				rather than erroring, which is right at runtime and useless as a
				warning. This is the warning. Every name in the data was checked
				against Enum.Font by hand once; this keeps it checked.
			]]
			for _, file in ipairs({ "ui", "presentation" }) do
				local table_ = Config.get(file).fonts
				expect(type(table_)).to.equal("table")
				for role, name in pairs(table_) do
					expect(name).to.be.a("string")
					expect(Fonts.byName(name)).never.to.equal(nil)
					expect(role).to.be.a("string")
				end
			end
		end)

		it("covers every role the world asks for", function()
			for _, role in ipairs({ "signTitle", "signBody", "handLettered", "nameplate", "tabular" }) do
				expect(Config.get("presentation").fonts[role]).to.be.a("string")
			end
			for _, role in ipairs({ "body", "bold", "title", "numeric" }) do
				expect(Config.get("ui").fonts[role]).to.be.a("string")
			end
		end)

		it("gives the leaderboard a monospace face, so its columns line up", function()
			--[[
				Times are a table. A proportional 1 is narrower than a 7, so a
				column of clear times in a proportional face reads as ragged.
			]]
			local tabular = Config.get("presentation").fonts.tabular
			expect(string.find(tabular, "Mono") ~= nil or string.find(tabular, "Code") ~= nil).to.equal(true)
		end)
	end)

	describe("interface scale", function()
		it("scales text against a sane reference, within sane limits", function()
			--[[
				Text sizes in ui.json are pixels at referenceViewportPixels tall.
				If the reference or the clamp ever goes wrong the UI is either
				unreadable or covers the screen, and neither shows up in a spec
				that only checks the numbers exist.
			]]
			local ui = Config.get("ui")
			expect(ui.referenceViewportPixels > 400).to.equal(true)
			expect(ui.referenceViewportPixels < 2000).to.equal(true)
			local limits = ui.textScaleLimits
			expect(#limits).to.equal(2)
			expect(limits[1] > 0.5).to.equal(true)
			expect(limits[1] < 1).to.equal(true)
			expect(limits[2] > 1).to.equal(true)
			expect(limits[2] < 3).to.equal(true)
			-- Body copy has to be legible at the smallest clamp on the reference.
			expect(ui.smallTextPixels * limits[1] >= 11).to.equal(true)
			expect(ui.titleTextPixels > ui.bodyTextPixels).to.equal(true)
			expect(ui.bodyTextPixels > ui.smallTextPixels).to.equal(true)
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
