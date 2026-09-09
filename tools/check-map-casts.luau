--!strict
-- Compare optimized collision queries with an independent exhaustive slab test.
-- Optional argument: pre-change MapGeometry source, for a same-process timing.
local r = require("@lune/roblox")
local env = require("./Harness").build()
local MG = env.require(env.Shared.MapGeometry)
local Config = env.require(env.Shared.Config)
local rng = env.require(env.Shared.Rng).new(91823)
local function reference(world, from, to, opts)
	local delta = to - from
	if delta.Magnitude < 1e-9 then return nil end
	local best, bestT = nil, math.huge
	for _, v in ipairs(world.volumes) do
		if not (v.cover or v.concealment) or (opts.ignoreConcealment and not v.cover)
			or (opts.ignore and opts.ignore[v.id]) then continue end
		local c, s = math.cos(v.rotationY), math.sin(v.rotationY)
		local axes = { r.Vector3.new(c, 0, s), r.Vector3.yAxis, r.Vector3.new(-s, 0, c) }
		local half = { v.halfSize.X, v.halfSize.Y, v.halfSize.Z }
		local low, high = 0, 1
		for i, axis in ipairs(axes) do
			local o, d = (from - v.center):Dot(axis), delta:Dot(axis)
			if math.abs(d) < 1e-9 then
				if math.abs(o) > half[i] then low, high = 1, 0; break end
			else
				local a, b = (-half[i] - o) / d, (half[i] - o) / d
				low = math.max(low, math.min(a, b))
				high = math.min(high, math.max(a, b))
			end
		end
		if low <= high and low < bestT then best, bestT = v.id, low end
	end
	return if best then { volumeId = best, distance = delta.Magnitude * bestT } else nil
end
local queries = {}
for _, name in ipairs(Config.mapNames()) do
	local world = MG.build(Config.map(name), Config.get("maps_index"))
	for i = 1, 1000 do
		local v = world.volumes[(i - 1) % #world.volumes + 1]
		local from = r.Vector3.new(rng:nextRange(-world.bounds.widthMetres / 2, world.bounds.widthMetres / 2),
			rng:nextRange(0, 8), rng:nextRange(-world.bounds.lengthMetres / 2, world.bounds.lengthMetres / 2))
		local to = v.center + r.Vector3.new(rng:nextRange(-10, 10), rng:nextRange(-2, 2), rng:nextRange(-10, 10))
		if i % 10 == 0 then from = v.center end -- inside starts
		if i % 17 == 0 then to = from end -- degenerate segment
		local opts = { ignoreConcealment = i % 2 == 0, ignore = if i % 3 == 0 then { [v.id] = true } else nil }
		local expected, actual = reference(world, from, to, opts), MG.cast(world, from, to, opts)
		assert((expected == nil) == (actual == nil), name .. ": missed or invented a blocker")
		if expected and actual then
			assert(expected.volumeId == actual.volumeId and math.abs(expected.distance - actual.distance) < 0.0001,
				name .. ": nearest impact changed")
		end
		assert(MG.hasLineOfSight(world, from, to, opts.ignore) == (reference(world, from, to, { ignore = opts.ignore }) == nil))
		assert(MG.paintCanReach(world, from, to) == (reference(world, from, to, { ignoreConcealment = true }) == nil))
		table.insert(queries, { world, from, to, opts })
	end
end
print(`Map queries: {#queries} rays / 15000 nearest-hit, visibility and paint-reach comparisons passed across five maps.`)
local baseline = require("@lune/process").args[1]
if baseline then
	local original = require("@lune/luau").load(require("@lune/fs").readFile(baseline), {
		environment = { script = { Parent = env.Shared }, require = env.require, Vector3 = r.Vector3 }, injectGlobals = true,
	})()
	local function benchmark(module)
		local times = {}
		for _ = 1, 3 do
			local start = os.clock()
			for _, q in ipairs(queries) do
				module.cast(q[1], q[2], q[3], q[4])
				module.hasLineOfSight(q[1], q[2], q[3], q[4].ignore)
				module.paintCanReach(q[1], q[2], q[3])
			end
			table.insert(times, os.clock() - start)
		end
		table.sort(times)
		return times[2]
	end
	local before, after = benchmark(original), benchmark(MG)
	print(string.format("Same-process 15000-query median: before %.3fs, after %.3fs (%.1f%% less CPU time; not game FPS)", before, after, (1 - after / before) * 100))
end
