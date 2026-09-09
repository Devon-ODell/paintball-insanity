--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local r = require("@lune/roblox")
local env = require("./Harness").build()
local Config = env.require(env.Shared.Config)
local cfg = Config.get("environmentArt").wind
local function signal()
	local listeners = {}
	return {
		Connect = function(_, fn)
			listeners[fn] = true
			return { Disconnect = function() listeners[fn] = nil end }
		end,
		fire = function(_, ...)
			for fn in pairs(listeners) do fn(...) end
		end,
		count = function()
			local n = 0
			for _ in pairs(listeners) do n += 1 end
			return n
		end,
	}
end
local beat, added, removed = signal(), signal(), signal()
local world = r.Instance.new("Workspace")
local camera = r.Instance.new("Camera")
camera.CFrame = r.CFrame.new()
camera.Parent = world
world.CurrentCamera = camera
local leaves, rest = {}, {}
for i = 1, cfg.maxParts + 12 do
	local p = r.Instance.new("MeshPart")
	p.CFrame = r.CFrame.new(i * 0.2, 1, 0)
	p.Parent = world
	leaves[i], rest[p] = p, p.CFrame
end
local collection = {
	GetInstanceAddedSignal = function() return added end,
	GetInstanceRemovedSignal = function() return removed end,
	GetTagged = function() return leaves end,
}
local services = {
	CollectionService = collection, RunService = { Heartbeat = beat }, ReplicatedStorage = env.ReplicatedStorage,
}
local wind = luau.load(fs.readFile("src/StarterPlayer/Client/FoliageWind.luau"), {
	debugName = "FoliageWind", environment = {
		game = { GetService = function(_, name) return services[name] end }, workspace = world,
		require = env.require, CFrame = r.CFrame, Vector3 = r.Vector3,
	},
})()
local function moved(): number
	local count = 0
	for p, frame in pairs(rest) do
		if (p.CFrame.UpVector - frame.UpVector).Magnitude > 0.00001 then count += 1 end
	end
	return count
end
local stop = wind.start()
beat:fire(cfg.intervalSeconds / 2)
assert(moved() == 0, "wind ignored update frequency cap")
beat:fire(cfg.intervalSeconds)
assert(moved() == cfg.maxParts, "wind must animate exactly the nearest capped set")
removed:fire(leaves[1])
assert((leaves[1].CFrame.UpVector - rest[leaves[1]].UpVector).Magnitude < 0.00001, "removed leaf stayed bent")
added:fire(leaves[1])
camera.CFrame = r.CFrame.new(10000, 0, 0)
beat:fire(cfg.refreshSeconds)
assert(moved() == 0, "distant leaves were not restored")
camera.CFrame = r.CFrame.new()
beat:fire(cfg.refreshSeconds)
assert(moved() == cfg.maxParts)
-- Reparenting the hub during a match must restore leaves immediately.
local parked = r.Instance.new("Folder")
leaves[2].Parent = parked
beat:fire(cfg.intervalSeconds)
assert((leaves[2].CFrame.UpVector - rest[leaves[2]].UpVector).Magnitude < 0.00001)
leaves[2].Parent = world
stop()
assert(moved() == 0 and beat.count() == 0 and added.count() == 0 and removed.count() == 0, "wind teardown leaked state")
wind.start()
local stopAgain = wind.start()
assert(beat.count() == 1 and added.count() == 1, "repeated startup doubled the animation loop")
stopAgain()
print(`Foliage wind: nearest {cfg.maxParts}, update cap, range culling, tag removal, hub reparenting and teardown passed.`)
