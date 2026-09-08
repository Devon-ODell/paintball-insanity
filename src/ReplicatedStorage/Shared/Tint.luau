--!strict
--[[
	Tint -- per-instance colour variation, from position alone.

	Roblox gives a part one flat colour and no vertex colour, no per-instance
	material and no way to break up a surface without spending another part. So
	the only variation available on a budget is the colour itself.

	That matters more than it sounds. Holdfast places twenty-two rocks from one
	palette entry and Woods places twelve timbers from another; the hub grows
	three hundred and forty canopies from three. Identical colour repeated at
	that count does not read as twenty-two rocks, it reads as one rock stamped
	twenty-two times, and no amount of lighting fixes it because the lighting is
	the same on each.

	Two axes, because brightness alone still reads as one material under an
	overcast sky:

	  value    lifts or drops the whole colour -- some rocks catch more light
	  warmth   pushes red against blue -- some timber is weathered grey, some
	           still has sap in it

	Driven by POSITION, not by a random generator. That is the important part:
	a generator would have to be threaded through every builder and would
	re-order the streams that place the trees, moving a forest that is
	deliberately stable across restarts. A hash of where the thing stands is just
	as varied, needs no plumbing, and gives the same object the same colour on
	every server forever.
]]

local Tint = {}

--[[
	The classic shader hash: multiply by irrational-looking constants, take a
	sine, keep the fraction. Not a good random number and does not need to be --
	it needs to be cheap, stateless, and to decorrelate two nearby positions,
	which it does.
]]
local function hash01(x: number, z: number, salt: number): number
	local v = math.sin(x * 127.1 + z * 311.7 + salt * 74.7) * 43758.5453
	return v - math.floor(v)
end

--[[
	`colour` varied by where it stands.

	`valueSpread` and `warmthSpread` are fractions -- 0.16 means up to 16%
	either way. Both default to no change, so a caller that has not tuned
	anything gets exactly the colour it passed in.
]]
function Tint.at(colour: Color3, position: Vector3, valueSpread: number?, warmthSpread: number?): Color3
	local value = 1 + (hash01(position.X, position.Z, 1) * 2 - 1) * (valueSpread or 0)
	local warmth = 1 + (hash01(position.X, position.Z, 2) * 2 - 1) * (warmthSpread or 0)
	return Color3.new(
		math.clamp(colour.R * value * warmth, 0, 1),
		math.clamp(colour.G * value, 0, 1),
		math.clamp(colour.B * value / warmth, 0, 1)
	)
end

--- Every colour in a palette shifted together, so one plant's parts agree.
function Tint.palette(
	palette: { [string]: Color3 },
	position: Vector3,
	valueSpread: number?,
	warmthSpread: number?
): { [string]: Color3 }
	local out: { [string]: Color3 } = {}
	for key, colour in pairs(palette) do
		out[key] = Tint.at(colour, position, valueSpread, warmthSpread)
	end
	return out
end

return Tint
