--!nolint
--[[
	A TestEZ-compatible expect()/describe()/it() implementation for the headless
	runner. Deliberately mirrors TestEZ's surface so that every file in tests/
	runs unmodified both here and under TestEZ inside Studio.
]]

local Expect = {}

local function fmt(v: any): string
	if type(v) == "number" then
		return string.format("%.6g", v)
	end
	return tostring(v)
end

local Matchers = {}

function Matchers.equal(ctx, expected)
	local ok = ctx.value == expected
	ctx:assert(ok, `expected {if ctx.negated then "not " else ""}{fmt(expected)}, got {fmt(ctx.value)}`)
	return ctx.chain
end

function Matchers.near(ctx, expected, limit)
	limit = limit or 1e-7
	local ok = type(ctx.value) == "number" and math.abs(ctx.value - expected) <= limit
	ctx:assert(
		ok,
		`expected {fmt(ctx.value)} to {if ctx.negated then "not " else ""}be within {fmt(limit)} of {fmt(expected)}`
			.. (if type(ctx.value) == "number" then ` (off by {fmt(math.abs(ctx.value - expected))})` else "")
	)
	return ctx.chain
end

function Matchers.ok(ctx)
	ctx:assert(ctx.value ~= nil, `expected a value, got nil`)
	return ctx.chain
end

function Matchers.a(ctx, typeName)
	local actual = typeof(ctx.value)
	ctx:assert(actual == typeName, `expected type {typeName}, got {actual}`)
	return ctx.chain
end

Matchers.an = Matchers.a

function Matchers.throw(ctx, substring)
	local ok, err = pcall(ctx.value)
	local threw = not ok
	if threw and substring then
		threw = tostring(err):find(substring, 1, true) ~= nil
	end
	ctx:assert(threw, `expected the function to {if ctx.negated then "not " else ""}throw`
		.. (if substring then ` containing '{substring}'` else "")
		.. (if not ok then ` (threw: {tostring(err)})` else ""))
	return ctx.chain
end

function Matchers.within(ctx, low, high)
	local ok = type(ctx.value) == "number" and ctx.value >= low and ctx.value <= high
	ctx:assert(ok, `expected {fmt(ctx.value)} to {if ctx.negated then "not " else ""}be within [{fmt(low)}, {fmt(high)}]`)
	return ctx.chain
end

function Expect.expect(value: any)
	local ctx = { value = value, negated = false }

	function ctx:assert(passed, message)
		if self.negated then
			passed = not passed
		end
		if not passed then
			error(message, 3)
		end
	end

	local chain
	-- Forward-declared: the __index closure below refers to `terminal` itself,
	-- and in Lua a `local x = ...` is not in scope inside its own initialiser.
	local terminal
	terminal = setmetatable({}, {
		__index = function(_, key)
			local m = Matchers[key]
			if m then
				return function(...)
					return m(ctx, ...)
				end
			end
			if key == "be" or key == "to" or key == "have" then
				return terminal
			end
			error(`unknown matcher '{key}'`, 2)
		end,
	})

	chain = setmetatable({}, {
		__index = function(_, key)
			if key == "never" then
				ctx.negated = not ctx.negated
				return chain
			end
			if key == "to" or key == "be" or key == "have" then
				return terminal
			end
			local m = Matchers[key]
			if m then
				return function(...)
					return m(ctx, ...)
				end
			end
			error(`unknown matcher '{key}'`, 2)
		end,
	})
	ctx.chain = chain
	return chain
end

return Expect
