--!nolint
--[[
	Drives a real drill through RangeService with a scripted perfect shooter.

	    lune run tools/check-range

	The Range's pure halves -- the schedule and the scorer -- have had specs
	since before there was a hub. What had never been executed was the half that
	needs a player, which is exactly why pressing F at the gate did nothing for
	so long without any test noticing. This runs the live loop: it builds the
	range, ticks the schedule on a mocked heartbeat, fires a solved shot at every
	target that appears, and checks that a score comes back out the other end.
]]
local roblox = require("@lune/roblox")
local Harness = require("./Harness")
local env = Harness.build()

local function replace(node, value)
	node._loaded, node._result = true, value
end

local function signal()
	local listeners = {}
	return {
		Connect = function(_, fn)
			table.insert(listeners, fn)
			return { Disconnect = function() end }
		end,
		fire = function(_, ...)
			for _, fn in ipairs(listeners) do fn(...) end
		end,
	}
end

local heartbeat = signal()
env.game:GetService("RunService").Heartbeat = heartbeat

local actualRemotes = env.require(env.ReplicatedStorage.Net.Remotes)
local events = {}
local function event(name)
	if not events[name] then
		events[name] = {
			OnServerEvent = signal(),
			sent = {},
			FireClient = function(self, _, payload) table.insert(self.sent, payload) end,
		}
	end
	return events[name]
end
replace(env.ReplicatedStorage.Net.Remotes, {
	event = event,
	validateFireRequest = actualRemotes.validateFireRequest,
})

local Units = env.require(env.Shared.Units)
local Ballistics = env.require(env.Shared.Ballistics)
local Config = env.require(env.Shared.Config)
local Drills = env.require(env.Server.Range.Drills)
local RangeService = env.require(env.Server.Range.RangeService)

local cfg = Config.get("range")
local ballisticsData = Config.get("ballistics")
local chest = ballisticsData.hitbox.chestHeightMetres
local markerData = Config.require("markers", "markers.mechanical")
local spec = Ballistics.specFromMarker(markerData, ballisticsData)

--[[
	The shooter stands on the firing line.

	RangeService derives the muzzle from the character's feet, so the mock root
	has to sit half a torso plus a hip height above the line for the muzzle to
	land where a real player's would. Getting this wrong would make every
	scripted shot miss and the check would "pass" by asserting nothing.
]]
local hipHeight, rootHalf = 1.5, 1
local lineStuds = Units.vectorToStuds(
	roblox.Vector3.new(cfg.firingLine.position[1], cfg.firingLine.position[2], cfg.firingLine.position[3])
)
local humanoid = { HipHeight = hipHeight }
local root = {
	Position = lineStuds + roblox.Vector3.new(0, rootHalf + hipHeight, 0),
	Size = roblox.Vector3.new(2, rootHalf * 2, 1),
	AssemblyLinearVelocity = roblox.Vector3.zero,
	CFrame = roblox.CFrame.new(lineStuds),
}
local character = {
	FindFirstChild = function() return root end,
	FindFirstChildOfClass = function() return humanoid end,
	WaitForChild = function(_, name) return if name == "Humanoid" then humanoid else root end,
}
local player = {
	UserId = 4242,
	Name = "RangeProbe",
	Character = character,
	Parent = env.game:GetService("Players"),
	LoadCharacterAsync = function() end,
}

local muzzle = roblox.Vector3.new(
	cfg.firingLine.position[1],
	cfg.firingLine.position[2] + chest,
	cfg.firingLine.position[3]
)

-- No real Workspace in the harness; give the range somewhere to be built.
local stage = roblox.Instance.new("Folder")
RangeService.worldParent = stage

local finished = nil
RangeService.onFinished = function(_, result) finished = result end

local drill = Config.require("range", "drillOrder")[1]
assert(RangeService.isDrill(drill), "the first drill in drillOrder must be a real drill")
assert(not RangeService.isDrill("nonsense"), "isDrill must reject an unknown id")
assert(RangeService.start(player, drill, 99), "the drill must start")
assert(RangeService.isActive(player), "the drill must report itself active")

local state = event("MatchStateChanged").sent[1]
assert(state and state.phase == "live", "starting a drill must put the client in the live phase")
assert(state.drill == drill, "the client must be told which drill it is")

assert(not RangeService.start(player, drill, 99), "a second concurrent drill must be refused")

--[[
	Fire once per target, on the frame it appears, at the solved lead.

	One shot per target rather than a spray: DrillScoring counts every event as a
	shot, so spraying would measure trigger discipline instead of the aim this is
	checking. That is the same policy SimDrill uses.
]]
local schedule = Drills.schedule(drill, 99)
local engaged = {}
local t, frames = 0, 0
local dt = 1 / 30
local shotsTaken = 0

while not finished and frames < 6000 do
	for _, target in ipairs(Drills.activeAt(schedule, t)) do
		if not engaged[target.id] then
			engaged[target.id] = true
			local solved = Ballistics.solveLead(spec, muzzle, target.position, target.velocity)
			if solved then
				local direction = (solved - muzzle).Unit
				event("FireMarker").OnServerEvent:fire(player, {
					origin = Units.vectorToStuds(muzzle),
					direction = direction,
					stance = "standing",
					clientTime = t,
				})
				shotsTaken += 1
			end
		end
	end
	heartbeat:fire(dt)
	t += dt
	frames += 1
end

assert(finished, `the drill must finish on its own clock (ran {frames} frames)`)
assert(shotsTaken > 0, "the probe must actually have fired")
assert(finished.drill == drill, "the result must name the drill")
assert(finished.shots > 0, "the result must count shots")
assert(finished.hits > 0, `a solved shot at a stationary popup target must hit (got {finished.hits} hits of {finished.shots})`)
assert(finished.score > 0, `a hitting run must score above zero (got {finished.score})`)
assert(finished.rating >= 0 and finished.rating <= 100, "rating stays on the 0-100 curve")

local scored = event("DrillScore").sent[1]
assert(scored, "the client must be sent its score")
assert(scored.hits == finished.hits and scored.shots == finished.shots, "the client's score must match the server's")

assert(not RangeService.isActive(player), "the drill must clear itself when it ends")
assert(#stage:GetChildren() == 0, "the range must be torn down when the drill ends")

--- The Range is free. Data/range.json pays zero and ship-check asserts it; this
--- checks the live loop never invented a payout of its own.
assert(cfg.payout == 0, "the Range must not pay")
for _, sent in ipairs(event("MatchSummary").sent) do
	assert((sent.payout or 0) == 0, "a drill must never pay out")
end

print(string.format(
	"Range checks passed: %s ran %d targets, %d/%d hits, score %d, rating %d.",
	drill, #schedule.targets, finished.hits, finished.shots,
	finished.score, math.floor(finished.rating)
))
