--!nolint
--[[
	Shoothouse course validation.

	    lune run tools/course-report

	Re-checks every course against the map it is laid through, on disk -- not
	against the generator that produced it. The generator and the checker
	agreeing proves nothing; this reads what shipped.

	Exits non-zero on any problem so it can sit in CI alongside map-validate.
]]

local process = require("@lune/process")
local Vector3 = require("@lune/roblox").Vector3
local Harness = require("./Harness")
local env = Harness.build()
local RS = env.ReplicatedStorage
local Config = env.require(RS.Shared.Config)
local MG = env.require(RS.Shared.MapGeometry)
local Course = env.require(env.ServerScriptService.Server.Match.Course)

local index = Config.get("maps_index")
local rules = Config.get("course")
local minStandoff = rules.checkpoints.minStandoffMetres
local maxGround = rules.checkpoints.maxGroundHeightMetres

local problems = 0
local function fail(message: string)
	print(`  \27[31mFAIL\27[0m  {message}`)
	problems += 1
end
local function ok(message: string)
	print(`  \27[32mok\27[0m    {message}`)
end

print("\27[1mcourse-report\27[0m")

for _, name in ipairs(Config.mapNames()) do
	print(`\n\27[1m{name}\27[0m`)
	if not Course.hasCourse(name) then
		fail(`{name} has no course block`)
		continue
	end
	local map = Config.map(name)
	local world = MG.build(map, index)
	local stages = Course.all(name, "rec")

	if #stages ~= rules.stageCount then
		fail(`{#stages} stages, expected {rules.stageCount}`)
	end

	-- Anchors: every stage anchor must exist, and the course must use each of
	-- the map's anchors exactly once. A course is the map's own cover list.
	local anchorById: { [string]: any } = {}
	for _, anchor in ipairs(map.anchors) do
		anchorById[anchor.id] = anchor
	end
	local seen: { [string]: boolean } = {}
	local used = 0
	for _, stage in ipairs(stages) do
		for _, id in ipairs(stage.anchorIds) do
			if not anchorById[id] then
				fail(`stage {stage.id} holds unknown anchor {id}`)
			elseif seen[id] then
				fail(`anchor {id} is held by two stages`)
			else
				seen[id] = true
				used += 1
			end
		end
	end
	if used == #map.anchors then
		ok(`all {used} anchors used exactly once`)
	else
		fail(`{used} of {#map.anchors} anchors used`)
	end

	-- Escalation: concurrent count must never decrease, tier never regress.
	local previousConcurrent, regressed = 0, false
	for _, stage in ipairs(stages) do
		if stage.concurrent < previousConcurrent then
			regressed = true
		end
		previousConcurrent = stage.concurrent
	end
	if regressed then
		fail("a later stage fields fewer defenders than an earlier one")
	else
		ok(`stages escalate {stages[1].concurrent} -> {stages[#stages].concurrent} concurrent, {Course.totalBots(name)} defenders total`)
	end

	--[[
		Checkpoints. Each must stand clear of cover, sit on the ground rather
		than on a roof, advance on the one before it, and keep its distance from
		the stage it is the run-up to.
	]]
	local previousZ = -math.huge
	for i, stage in ipairs(stages) do
		local cp = stage.checkpoint.position
		local label = `{stage.id} checkpoint`

		--[[
			Tested at the PLAYER's chest, not at each volume's own centre. Testing
			at the volume height called Holdfast's spawn "inside cover" because a
			walkway passes 8 m overhead -- standing under a bridge is not being
			stuck in one. coverProbeHeightMetres is the height the rest of the
			project already reasons about cover at.
		]]
		local support = MG.supportHeightAt(world, cp)
		local chest = Vector3.new(cp.X, support + index.assembly.coverProbeHeightMetres, cp.Z)
		for _, volume in ipairs(world.volumes) do
			if volume.cover and MG.containsPoint(volume, chest) then
				fail(`{label} is inside cover volume {volume.sourceId}`)
				break
			end
		end

		if support > maxGround then
			fail(`{label} stands {string.format("%.1f", support)} m up, not on the ground`)
		end

		if i > 1 and cp.Z <= previousZ then
			fail(`{label} does not advance on the previous one ({cp.Z} <= {previousZ})`)
		end
		previousZ = cp.Z

		local front = math.huge
		for _, id in ipairs(stage.anchorIds) do
			local anchor = anchorById[id]
			if anchor then
				front = math.min(front, anchor.position[3])
			end
		end
		local standoff = front - cp.Z
		if standoff < minStandoff - 0.05 then
			fail(`{label} is only {string.format("%.1f", standoff)} m behind its nearest defender (min {minStandoff})`)
		end
	end
	ok("checkpoints clear of cover, on the ground, advancing and standing off")

	-- Par has to be ordered, or a silver run would score gold.
	local par = Course.parSeconds(name)
	if par.gold < par.silver and par.silver < par.bronze then
		ok(`par {par.gold} / {par.silver} / {par.bronze} s over {map.course.spanMetres} m`)
	else
		fail(`par is not ordered: {par.gold} / {par.silver} / {par.bronze}`)
	end

	-- The medal boundaries must actually award what they claim.
	if Course.medalFor(name, par.gold) ~= "gold"
		or Course.medalFor(name, par.silver) ~= "silver"
		or Course.medalFor(name, par.bronze) ~= "bronze"
		or Course.medalFor(name, par.bronze + 1) ~= nil then
		fail("medal boundaries do not award their own par times")
	end
end

print("")
if problems > 0 then
	print(`\27[31m{problems} problem(s)\27[0m`)
	process.exit(1)
end
print("\27[32mevery course is laid through its own map\27[0m")
