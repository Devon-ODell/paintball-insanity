--!strict
--[[
	Inflatables -- speedball bunkers that actually look inflated.

	A real speedball field is welded PVC: pressurised tubes with visible seams,
	webbing straps and D-rings staking them down, glossy enough to catch the sun
	and read at distance. A box with a colour on it does not look like that, so
	these are built as rounded, capped, seamed bodies out of primitives. No
	assets, no meshes, nothing authored in Studio -- per CLAUDE.md it all comes
	from code and Data/maps/*.json.

	COLLISION CONTRACT. Every bunker gets exactly one invisible collision box
	matching the oriented box declared in the map JSON, and every visual part is
	CanCollide = false, CanQuery = false. That is deliberate: MapGeometry reasons
	about the same OBB for bot line-of-sight and the server's projectile
	simulation, so what the player bumps into, what the bots can see through and
	what stops paint are guaranteed to be one shape. The rounded visual is
	inscribed INSIDE that box. The visual/collision discrepancy is
	small for pillows and cans. Tapered doritos and balls leave larger empty
	corner regions: the authored box still stops paint there.

	The BALL is the exception worth knowing about: a sphere inscribed in a square
	footprint leaves the box's corners empty, so the centre bunker blocks roughly
	0.3m wider than it looks. That is the cost of a round bunker on a square
	collision box, and it is why the box itself must never be retuned to "fit"
	the visual -- see the note on speedball's centreBall, where doing exactly
	that inverted the map's core property.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Units = require(ReplicatedStorage.Shared.Units)

local Config = require(ReplicatedStorage.Shared.Config)
local tuning = Config.get("inflatables")
local Inflatables = {}

--- Vinyl. Glossy but not mirrored; enough reflectance to catch a highlight and
--- sell the pressurised surface without turning the field into chrome.
local VINYL_REFLECTANCE = tuning.vinylReflectance
local SEAM_DARKEN = tuning.seamDarken
local STRAP_DARKEN = tuning.strapDarken

local function shade(colour: Color3, factor: number): Color3
	return Color3.new(colour.R * factor, colour.G * factor, colour.B * factor)
end

local function newPart(name: string, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	-- Visuals never collide and are never raycast against. The single invisible
	-- collision box below is the only authoritative shape.
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.SmoothPlastic
	part.Reflectance = VINYL_REFLECTANCE
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CastShadow = true
	part.Parent = parent
	return part
end

--- A cylinder whose length runs along the given local axis. Roblox cylinders
--- run along X, so everything else is a rotation of that.
local function tube(
	parent: Instance,
	name: string,
	cf: CFrame,
	length: number,
	diameter: number,
	colour: Color3,
	axis: string?
): Part
	local part = newPart(name, parent)
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(length, diameter, diameter)
	part.Color = colour
	local orientation = if axis == "y" then CFrame.Angles(0, 0, math.pi / 2)
		elseif axis == "z" then CFrame.Angles(0, math.pi / 2, 0)
		else CFrame.new()
	part.CFrame = cf * orientation
	return part
end

local function blob(parent: Instance, name: string, cf: CFrame, size: Vector3, colour: Color3): Part
	local part = newPart(name, parent)
	part.Shape = Enum.PartType.Ball
	part.Size = size
	part.Color = colour
	part.CFrame = cf
	return part
end

--[[
	Marks a part as trim and hands it back.

	Trim is geometry that rounds, welds or caps a body it sits on: a seam ring
	1.5% proud of its tube, the rounded edge running up a dorito panel, the weld
	along its base. Under Future lighting every caster is paid for, and trim's
	shadow falls inside -- or within a few centimetres of -- the shadow of the
	body it wraps. It costs a shadow caster and changes nothing on screen.

	The body casts; the trim does not. Anything that changes the silhouette a
	player reads from across the field is a body, not trim.
]]
local function trim(part: Part): Part
	part.CastShadow = false
	return part
end

--[[
	A seam ring: the welded join around a tube. Slightly larger than the body it
	sits on and noticeably darker, which is what makes the shape read as several
	pressurised sections rather than one smooth lozenge.
]]
local function seam(parent: Instance, cf: CFrame, diameter: number, colour: Color3, axis: string?)
	local ring = trim(tube(parent, "Seam", cf, Units.metresToStuds(0.05), diameter * 1.015, shade(colour, SEAM_DARKEN), axis))
	ring.Reflectance = 0.02
end

--- Webbing strap and stake ring at the base. Small, but it is the detail that
--- makes a bunker look staked to a field rather than dropped on one.
local function anchorStrap(parent: Instance, cf: CFrame, width: number, colour: Color3)
	local strap = newPart("Strap", parent)
	strap.Size = Vector3.new(width, Units.metresToStuds(0.05), Units.metresToStuds(0.12))
	strap.Color = shade(colour, STRAP_DARKEN)
	strap.Reflectance = 0
	strap.Material = Enum.Material.Fabric
	strap.CFrame = cf
	-- Sits on the ground under the bunker; its shadow is inside the bunker's.
	trim(strap)
end

--------------------------------------------------------------------------------
-- Bunker shapes
--------------------------------------------------------------------------------

--[[
	CAN -- a vertical pressurised tube with domed caps. The most common bunker
	on a speedball field and the one people hide behind standing up.
]]
local function buildCan(model: Model, size: Vector3, colour: Color3)
	local diameter = math.min(size.X, size.Z)
	local height = size.Y
	local capHeight = math.min(diameter * tuning.capFraction, height / 2)
	local bodyHeight = height - capHeight * 2

	tube(model, "Body", CFrame.new(0, 0, 0), bodyHeight, diameter, colour, "y")

	-- Domed caps, squashed so the bunker keeps its declared height.
	blob(model, "TopCap", CFrame.new(0, bodyHeight / 2, 0), Vector3.new(diameter, capHeight * 2, diameter), colour)
	blob(model, "BottomCap", CFrame.new(0, -bodyHeight / 2, 0), Vector3.new(diameter, capHeight * 2, diameter), colour)

	-- Three sections, so two seams.
	seam(model, CFrame.new(0, bodyHeight / 6, 0), diameter, colour, "y")
	seam(model, CFrame.new(0, -bodyHeight / 6, 0), diameter, colour, "y")

	anchorStrap(model, CFrame.new(0, -height / 2 + Units.metresToStuds(0.04), 0), diameter * 1.05, colour)
end

--[[
	DORITO -- the triangular bunker. Rounded vertical edges and a rounded apex;
	the flat faces are what make it read as a wedge from across the field.
]]
local function buildDorito(model: Model, size: Vector3, colour: Color3)
	local width, height, depth = size.X, size.Y, size.Z
	local edge = math.min(width, height, depth) * tuning.edgeFraction
	local innerWidth, innerHeight = width - edge, height - edge
	-- Two opposing wedges meet at a ridge. Unlike the old rectangular core,
	-- this silhouette narrows all the way up to the inflatable crown.
	for _, side in ipairs({ -1, 1 }) do
		local panel = newPart(`Panel{side}`, model)
		panel.Shape = Enum.PartType.Wedge
		panel.Size = Vector3.new(depth * tuning.panelDepthFraction, innerHeight, innerWidth / 2)
		panel.Color = colour
		panel.CFrame = CFrame.new(side * innerWidth / 4, 0, 0) * CFrame.Angles(0, -side * math.pi / 2, 0)
	end
	-- Soft sloping welds and rounded corners, contained in the authored box.
	for _, z in ipairs({ -(depth - edge) / 2, (depth - edge) / 2 }) do
		local apex = Vector3.new(0, innerHeight / 2, z)
		for _, side in ipairs({ -1, 1 }) do
			local base = Vector3.new(side * innerWidth / 2, -innerHeight / 2, z)
			local middle = (base + apex) / 2
			trim(tube(model, "SlopedWeld", CFrame.lookAt(middle, apex), (apex - base).Magnitude, edge, colour, "z"))
			trim(blob(model, "BaseCorner", CFrame.new(base), Vector3.new(edge, edge, edge), colour))
		end
		trim(blob(model, "Apex", CFrame.new(apex), Vector3.new(edge, edge, edge), colour))
		trim(tube(model, "BaseWeld", CFrame.new(0, -innerHeight / 2, z), innerWidth, edge, shade(colour, SEAM_DARKEN), "x"))
	end
	--[[
		The two wedge panels are the dorito's silhouette and they still cast. The
		rounding around them is trim: at edgeFraction of the smallest dimension it
		is a few centimetres proud of a panel that is already casting. Leaving all
		of it casting put Speedball 24 shadow casters over budget the day the
		tapered wedges landed.
	]]
	trim(tube(model, "Crown", CFrame.new(0, innerHeight / 2, 0), depth - edge, edge, colour, "z"))
	anchorStrap(model, CFrame.new(0, -height / 2 + Units.metresToStuds(0.04), 0), width * 0.9, colour)
end

--[[
	SNAKE -- a long low tube you play prone or crouched behind. Runs along its
	longest horizontal axis, capped at both ends.
]]
local function buildSnake(model: Model, size: Vector3, colour: Color3)
	local alongX = size.X >= size.Z
	local length = if alongX then size.X else size.Z
	local diameter = math.min(if alongX then size.Z else size.X, size.Y)
	local axis = if alongX then "x" else "z"
	local bodyLength = math.max(length - diameter, length * 0.4)

	tube(model, "Body", CFrame.new(), bodyLength, diameter, colour, axis)

	local half = bodyLength / 2
	local offsetA = if alongX then Vector3.new(half, 0, 0) else Vector3.new(0, 0, half)
	blob(model, "CapA", CFrame.new(offsetA), Vector3.new(diameter, diameter, diameter), colour)
	blob(model, "CapB", CFrame.new(-offsetA), Vector3.new(diameter, diameter, diameter), colour)

	-- Seams every couple of metres along the run.
	local sections = math.max(2, math.floor(bodyLength / Units.metresToStuds(1.6)))
	for i = 1, sections - 1 do
		local along = -bodyLength / 2 + (bodyLength / sections) * i
		local at = if alongX then Vector3.new(along, 0, 0) else Vector3.new(0, 0, along)
		seam(model, CFrame.new(at), diameter, colour, axis)
	end

	anchorStrap(model, CFrame.new(0, -size.Y / 2 + Units.metresToStuds(0.03), 0), length * 0.5, colour)
end

--[[
	BALL -- the big round one. A pressurised sphere with welded panel seams,
	squashed very slightly where it sits on the ground.

	This replaced a "temple" bunker that had a domed top on a four-sided body
	with heavily rounded corners: at distance it read as a turret, which is not
	what is on a paintball field. A speedball field is simple shapes -- tubes,
	wedges, blocks and balls -- and the read should be immediate.
]]
local function buildBall(model: Model, size: Vector3, colour: Color3)
	local diameter = math.min(size.X, size.Z)
	local height = size.Y

	local body = blob(model, "Body", CFrame.new(), Vector3.new(diameter, height * 0.98, diameter), colour)
	body.Reflectance = VINYL_REFLECTANCE * 1.4

	--[[
		Panel seams. A beach ball's whole read is its panels, so it gets a ring
		around the equator and two over the top at right angles -- the same
		welded-seam trick the tubes use, wrapped around a sphere.
	]]
	seam(model, CFrame.new(), diameter * 0.99, colour, "y")
	seam(model, CFrame.Angles(0, 0, math.pi / 2), diameter * 0.99, colour, "y")
	seam(model, CFrame.Angles(math.pi / 2, 0, 0), diameter * 0.99, colour, "y")

	-- Flattened contact patch: an inflated ball spreads a little under its own
	-- weight, and a sphere sitting on a perfect tangent looks like it is hovering.
	local base = tube(model, "Base", CFrame.new(0, -height * 0.44, 0), Units.metresToStuds(0.08), diameter * 0.55, shade(colour, 0.9), "y")
	base.Reflectance = 0.02
	-- Tucked under the ball at 55% of its diameter: its shadow cannot fall
	-- anywhere the ball's does not already cover.
	base.CastShadow = false
	anchorStrap(model, CFrame.new(0, -height / 2 + Units.metresToStuds(0.04), 0), diameter * 0.6, colour)
end

--[[
	STANDUP -- an upright rectangle. The tall flat one you shoot around rather
	than over, built as a pressurised pillow: bulged faces, rounded edges, and a
	seam across the middle where the two panels are welded together.
]]
local function buildStandup(model: Model, size: Vector3, colour: Color3)
	local width, height, depth = size.X, size.Y, size.Z
	local edge = math.min(width, height, depth) * tuning.pillowCornerFraction

	local core = newPart("Core", model)
	core.Shape = Enum.PartType.Block
	core.Size = Vector3.new(width - edge, height - edge, depth * 0.86)
	core.Color = colour
	core.CFrame = CFrame.new()

	-- Rounded vertical edges down both sides.
	local hx = width / 2 - edge / 2
	for i, x in ipairs({ -hx, hx }) do
		tube(model, `Edge{i}`, CFrame.new(x, 0, 0), height - edge, math.min(edge, depth * 0.86), colour, "y")
	end
	-- Rounded top and bottom rails.
	for i, y in ipairs({ -(height / 2 - edge / 2), height / 2 - edge / 2 }) do
		tube(model, `Rail{i}`, CFrame.new(0, y, 0), width - edge, math.min(edge, depth * 0.86), colour, "x")
	end
	-- Corner blobs, so the outline is continuous rather than four tubes meeting.
	for i, corner in ipairs({
		Vector3.new(-hx, -(height / 2 - edge / 2), 0), Vector3.new(hx, -(height / 2 - edge / 2), 0),
		Vector3.new(-hx, height / 2 - edge / 2, 0), Vector3.new(hx, height / 2 - edge / 2, 0),
	}) do
		blob(model, `Corner{i}`, CFrame.new(corner), Vector3.new(edge, edge, math.min(edge, depth * 0.86)), colour)
	end

	--[[
		The bulge. A welded pillow is fattest in the middle of each face, and
		without this the shape reads as a flat board with rounded edges rather
		than as something with air in it.
	]]
	for i, z in ipairs({ -depth * 0.5, depth * 0.5 }) do
		blob(model, `Bulge{i}`, CFrame.new(0, 0, z * 0.55),
			Vector3.new(width * 0.82, height * 0.86, depth * 0.45), colour)
	end

	anchorStrap(model, CFrame.new(0, -height / 2 + Units.metresToStuds(0.04), 0), width * 0.9, colour)
end

--[[
	BRICK -- a low rounded box. The beam and knuckle bunkers you slide behind.
]]
local function buildBrick(model: Model, size: Vector3, colour: Color3)
	-- A low pillow uses the same continuous rounded perimeter as a standup.
	buildStandup(model, size, colour)
end

--------------------------------------------------------------------------------

local BUILDERS: { [string]: (Model, Vector3, Color3) -> () } = {
	can = buildCan,
	dorito = buildDorito,
	snake = buildSnake,
	ball = buildBall,
	standup = buildStandup,
	brick = buildBrick,
}

--- Shapes this module knows how to build, keyed by the JSON `shape` value.
function Inflatables.handles(shape: string): boolean
	return BUILDERS[(shape:gsub("^inflatable_", ""))] ~= nil
end

--[[
	Builds one bunker.

	`cf` and `sizeStuds` describe the oriented box from the map JSON. The visual
	is inscribed in that box; the caller supplies the invisible collision part
	that matches it exactly.
]]
function Inflatables.build(shape: string, cf: CFrame, sizeStuds: Vector3, colour: Color3, name: string, parent: Instance): Model
	local kind = (shape:gsub("^inflatable_", ""))
	local builder = BUILDERS[kind]
	if not builder then
		error(`Inflatables: no builder for shape '{shape}'`, 2)
	end

	local model = Instance.new("Model")
	model.Name = name

	builder(model, sizeStuds, colour)

	-- Position every visual part relative to the bunker's own frame.
	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("BasePart") then
			child.CFrame = cf * child.CFrame
		end
	end

	local primary = model:FindFirstChild("Body") or model:FindFirstChild("Core")
	if primary and primary:IsA("BasePart") then
		model.PrimaryPart = primary
	end

	model.Parent = parent
	return model
end

return Inflatables
