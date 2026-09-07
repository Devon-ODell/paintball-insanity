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
	inscribed INSIDE that box, so the only discrepancy is the corner radius --
	about a quarter of a metre, and always in the player's favour.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Units = require(ReplicatedStorage.Shared.Units)

local Inflatables = {}

--- Vinyl. Glossy but not mirrored; enough reflectance to catch a highlight and
--- sell the pressurised surface without turning the field into chrome.
local VINYL_REFLECTANCE = 0.08
local SEAM_DARKEN = 0.72
local STRAP_DARKEN = 0.45

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
	A seam ring: the welded join around a tube. Slightly larger than the body it
	sits on and noticeably darker, which is what makes the shape read as several
	pressurised sections rather than one smooth lozenge.
]]
local function seam(parent: Instance, cf: CFrame, diameter: number, colour: Color3, axis: string?)
	local ring = tube(parent, "Seam", cf, Units.metresToStuds(0.05), diameter * 1.015, shade(colour, SEAM_DARKEN), axis)
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
	local capHeight = diameter * 0.45
	local bodyHeight = math.max(height - capHeight, height * 0.35)

	tube(model, "Body", CFrame.new(0, 0, 0), bodyHeight, diameter, colour, "y")

	-- Domed caps, squashed so the bunker keeps its declared height.
	blob(model, "TopCap", CFrame.new(0, bodyHeight / 2, 0), Vector3.new(diameter, capHeight * 2, diameter), colour)
	blob(model, "BottomCap", CFrame.new(0, -bodyHeight / 2, 0), Vector3.new(diameter, capHeight * 1.2, diameter), colour)

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
	local width = size.X
	local depth = size.Z
	local height = size.Y
	local edge = math.min(width, depth) * 0.24

	local core = newPart("Core", model)
	core.Shape = Enum.PartType.Block
	core.Size = Vector3.new(width * 0.82, height * 0.9, depth * 0.82)
	core.Color = colour
	core.CFrame = CFrame.new(0, 0, 0)

	-- Rounded vertical edges at the three corners of the triangle.
	local corners = {
		Vector3.new(0, 0, -depth / 2 + edge / 2),
		Vector3.new(-width / 2 + edge / 2, 0, depth / 2 - edge / 2),
		Vector3.new(width / 2 - edge / 2, 0, depth / 2 - edge / 2),
	}
	for i, offset in ipairs(corners) do
		tube(model, `Edge{i}`, CFrame.new(offset), height * 0.9, edge, colour, "y")
		blob(model, `EdgeTop{i}`, CFrame.new(offset + Vector3.new(0, height * 0.45, 0)), Vector3.new(edge, edge, edge), colour)
	end

	-- Inflated crown.
	blob(model, "Crown", CFrame.new(0, height * 0.42, 0), Vector3.new(width * 0.7, height * 0.24, depth * 0.7), colour)

	seam(model, CFrame.new(0, 0, 0), math.max(width, depth) * 0.9, colour, "y")
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
	TEMPLE -- the big centre bunker. A tall four-sided body with heavily rounded
	vertical edges and a domed top, so it holds a silhouette from every angle.
]]
local function buildTemple(model: Model, size: Vector3, colour: Color3)
	local width, height, depth = size.X, size.Y, size.Z
	local edge = math.min(width, depth) * 0.3

	local core = newPart("Core", model)
	core.Shape = Enum.PartType.Block
	core.Size = Vector3.new(width * 0.86, height * 0.82, depth * 0.86)
	core.Color = colour
	core.CFrame = CFrame.new()

	local hx, hz = width / 2 - edge / 2, depth / 2 - edge / 2
	local corners = {
		Vector3.new(hx, 0, hz),
		Vector3.new(-hx, 0, hz),
		Vector3.new(hx, 0, -hz),
		Vector3.new(-hx, 0, -hz),
	}
	for i, offset in ipairs(corners) do
		tube(model, `Edge{i}`, CFrame.new(offset), height * 0.82, edge, colour, "y")
		blob(model, `EdgeTop{i}`, CFrame.new(offset + Vector3.new(0, height * 0.41, 0)), Vector3.new(edge, edge, edge), colour)
	end

	blob(model, "Dome", CFrame.new(0, height * 0.38, 0), Vector3.new(width * 0.9, height * 0.36, depth * 0.9), colour)

	seam(model, CFrame.new(0, height * 0.12, 0), math.max(width, depth) * 0.92, colour, "y")
	seam(model, CFrame.new(0, -height * 0.18, 0), math.max(width, depth) * 0.92, colour, "y")
	anchorStrap(model, CFrame.new(0, -height / 2 + Units.metresToStuds(0.04), 0), width * 0.95, colour)
end

--[[
	BRICK -- a low rounded box. The beam and knuckle bunkers you slide behind.
]]
local function buildBrick(model: Model, size: Vector3, colour: Color3)
	local width, height, depth = size.X, size.Y, size.Z
	local radius = math.min(height, math.min(width, depth)) * 0.42

	local core = newPart("Core", model)
	core.Shape = Enum.PartType.Block
	core.Size = Vector3.new(width - radius, height, depth - radius)
	core.Color = colour
	core.CFrame = CFrame.new()

	-- Rounded ends along the long axis.
	local alongX = width >= depth
	local half = (if alongX then width else depth) / 2 - radius / 2
	local offset = if alongX then Vector3.new(half, 0, 0) else Vector3.new(0, 0, half)
	local axis = if alongX then "z" else "x"
	tube(model, "EndA", CFrame.new(offset), if alongX then depth else width, math.min(height, radius * 2), colour, axis)
	tube(model, "EndB", CFrame.new(-offset), if alongX then depth else width, math.min(height, radius * 2), colour, axis)

	-- Inflated top ridge.
	local ridge = newPart("Ridge", model)
	ridge.Shape = Enum.PartType.Cylinder
	ridge.Size = Vector3.new(if alongX then width * 0.94 else depth * 0.94, height * 0.55, height * 0.55)
	ridge.Color = colour
	ridge.CFrame = CFrame.new(0, height * 0.22, 0)
		* (if alongX then CFrame.new() else CFrame.Angles(0, math.pi / 2, 0))

	seam(model, CFrame.new(), math.max(width, depth) * 0.4, colour, if alongX then "x" else "z")
	anchorStrap(model, CFrame.new(0, -height / 2 + Units.metresToStuds(0.03), 0), width * 0.7, colour)
end

--------------------------------------------------------------------------------

local BUILDERS: { [string]: (Model, Vector3, Color3) -> () } = {
	can = buildCan,
	dorito = buildDorito,
	snake = buildSnake,
	temple = buildTemple,
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
