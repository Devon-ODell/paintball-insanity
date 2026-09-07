--!strict
--[[
	Rng -- deterministic, platform-independent pseudo-random numbers.

	Roblox's Random and Lune's math.random are not guaranteed to agree, and the
	sim harness requires that the same seed produces byte-identical output in
	both. So the generator is implemented here in pure Luau (xorshift32) and is
	the ONLY source of randomness anywhere in gameplay code.
]]

local Rng = {}

export type Generator = {
	state: number,
	nextInt: (self: Generator, min: number, max: number) -> number,
	nextNumber: (self: Generator) -> number,
	nextRange: (self: Generator, min: number, max: number) -> number,
	nextGaussian: (self: Generator) -> number,
	nextUnitVector2: (self: Generator) -> (number, number),
	fork: (self: Generator, salt: number) -> Generator,
	clone: (self: Generator) -> Generator,
}

local Generator = {}
Generator.__index = Generator

local UINT32 = 4294967296

local function step(self: Generator): number
	local x = self.state
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	self.state = x
	return x
end

--- Uniform in [0, 1).
function Generator.nextNumber(self: Generator): number
	return step(self) / UINT32
end

--- Uniform in [min, max].
function Generator.nextRange(self: Generator, min: number, max: number): number
	return min + (max - min) * self:nextNumber()
end

--- Uniform integer in [min, max] inclusive.
function Generator.nextInt(self: Generator, min: number, max: number): number
	local span = max - min + 1
	return min + (step(self) % span)
end

--- Standard normal, mean 0 sigma 1, via Box-Muller. Both variates are consumed
--- rather than cached so that a given call index always consumes exactly two
--- draws -- caching would make output depend on call history.
function Generator.nextGaussian(self: Generator): number
	local u1 = self:nextNumber()
	local u2 = self:nextNumber()
	if u1 < 1e-12 then
		u1 = 1e-12
	end
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

--- A uniformly distributed 2D unit vector, returned as a pair.
function Generator.nextUnitVector2(self: Generator): (number, number)
	local a = self:nextNumber() * 2 * math.pi
	return math.cos(a), math.sin(a)
end

--- A child generator whose stream is independent of the parent's future draws.
--- Used so that e.g. bot 3's aim jitter never shifts because the ballistics
--- sim consumed a different number of draws this frame.
function Generator.fork(self: Generator, salt: number): Generator
	return Rng.new(bit32.bxor(self.state, salt * 2654435761))
end

function Generator.clone(self: Generator): Generator
	local g = setmetatable({ state = self.state }, Generator)
	return (g :: any) :: Generator
end

--- Creates a generator. Seed 0 is remapped because xorshift is degenerate there.
function Rng.new(seed: number): Generator
	local s = bit32.band(math.floor(math.abs(seed)), 0xFFFFFFFF)
	if s == 0 then
		s = 0x9E3779B9
	end
	local g = setmetatable({ state = s }, Generator)
	-- Discard the first few draws so that adjacent seeds do not produce
	-- visibly correlated first values.
	for _ = 1, 8 do
		step((g :: any) :: Generator)
	end
	return (g :: any) :: Generator
end

return Rng
