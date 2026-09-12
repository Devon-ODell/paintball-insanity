--!nolint
--[[
	Walks a bot in a straight line and checks its legs actually move.

	    lune run tools/check-gait

	A sliding body reads as a prop no matter how good the kit on it is. The two
	properties that matter, and both are checkable without a renderer:

	  standing still   the legs must not move at all, or the bot marches on the
	                   spot -- which is what happens when a walk cycle runs off
	                   a clock instead of off distance travelled
	  walking          the legs must swing, and the two legs must swing in
	                   OPPOSITE directions. Two legs swinging together is not a
	                   walk, it is a hop, and it is the easy sign error to make.

	Swing amplitude deliberately does not grow with speed: the phase advances
	with distance, so moving faster raises cadence at a constant stride and the
	feet keep landing where the ground says they should.
]]
local roblox = require("@lune/roblox")
local process = require("@lune/process")
local Harness = require("./Harness")
local env = Harness.build()
local BotAvatar = env.require(env.ServerScriptService.Server.Match.BotAvatar)

local STUDS_PER_METRE = 3.5714286

--- Each thigh's fore-aft offset from the body, sampled along a straight walk.
local function sample(label: string, stepMetres: number, ticks: number)
	local parent = roblox.Instance.new("Folder")
	local avatar = BotAvatar.new("gait_" .. label, "Gait", parent, "pro")
	local forward = roblox.Vector3.new(0, 0, -1)
	local left, right = {}, {}
	for i = 0, ticks do
		local at = roblox.Vector3.new(0, 0, -stepMetres * i)
		avatar:setPosition(at, forward)
		local bodyZ = -stepMetres * i * STUDS_PER_METRE
		table.insert(left, avatar.model:FindFirstChild("ThighL").CFrame.Position.Z - bodyZ)
		table.insert(right, avatar.model:FindFirstChild("ThighR").CFrame.Position.Z - bodyZ)
	end
	return left, right
end

local function spread(values: { number }): number
	local low, high = math.huge, -math.huge
	for _, v in ipairs(values) do
		low, high = math.min(low, v), math.max(high, v)
	end
	return high - low
end

print("\27[1mgait\27[0m")
local problems = 0

local standL, standR = sample("stand", 0, 40)
print(string.format("  standing   swing left %.3f  right %.3f studs", spread(standL), spread(standR)))
if spread(standL) > 0.01 or spread(standR) > 0.01 then
	print("  \27[31mthe legs move while the bot is standing still\27[0m")
	problems += 1
end

local walkL, walkR = sample("walk", 0.08, 80)
print(string.format("  walking    swing left %.3f  right %.3f studs", spread(walkL), spread(walkR)))
if spread(walkL) < 0.2 or spread(walkR) < 0.2 then
	print("  \27[31mthe legs barely move while walking\27[0m")
	problems += 1
end

-- Antiphase: whenever one leg is forward the other must be back.
local opposed, samples = 0, 0
for i = 1, #walkL do
	local l, r = walkL[i], walkR[i]
	if math.abs(l) > 0.05 or math.abs(r) > 0.05 then
		samples += 1
		if (l > 0) ~= (r > 0) then
			opposed += 1
		end
	end
end
local ratio = if samples > 0 then opposed / samples else 0
print(string.format("  antiphase  %d of %d samples have the legs opposed (%.0f%%)", opposed, samples, ratio * 100))
if ratio < 0.98 then
	print("  \27[31mthe legs swing together -- that is a hop, not a walk\27[0m")
	problems += 1
end

print("")
if problems > 0 then
	print(`\27[31m{problems} problem(s)\27[0m`)
	process.exit(1)
end
print("\27[32mthe legs move with the ground, and against each other\27[0m")

-- Two identical simulation walks scheduled at very different wall-clock
-- intervals must produce the same pose during Heartbeat catch-up.
local now = 0
env.globals.os = table.clone(os)
env.globals.os.clock = function() return now end
local clockEnv = Harness.build()
clockEnv.globals.os = env.globals.os
local TimedAvatar = clockEnv.require(clockEnv.Server.Match.BotAvatar)
local parent = roblox.Instance.new("Folder")
local regular = TimedAvatar.new("regular", "Regular", parent, "pro")
local catchup = TimedAvatar.new("catchup", "Catchup", parent, "pro")
for i = 0, 40 do
    local at = roblox.Vector3.new(0, 0, -i * 0.01)
    now = i / 60
    regular:setPosition(at, roblox.Vector3.new(0, 0, -1), 1 / 60)
    now = 200 + i * 0.00001
    catchup:setPosition(at, roblox.Vector3.new(0, 0, -1), 1 / 60)
    for _, name in ipairs({ "ThighL", "ThighR", "ShinR", "Chest", "HandR", "Marker" }) do
        assert((regular.model[name].CFrame.Position - catchup.model[name].CFrame.Position).Magnitude < 0.0001,
            name .. ": animation used CPU elapsed time instead of simulation time")
    end
end
regular:destroy()
catchup:destroy()
print("Gait stays identical when fixed ticks run back-to-back")
