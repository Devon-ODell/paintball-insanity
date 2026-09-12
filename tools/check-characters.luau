--!nolint
--[[
	Builds every person in the game and counts what came out.

	    lune run tools/check-characters

	Constructs real Roblox instances through Lune's property database, so this
	catches a bad Enum, an unknown property or a missing wardrobe piece. It
	cannot tell you whether anyone looks good -- that still needs Studio.
]]
local roblox = require("@lune/roblox")
local Harness = require("./Harness")
local env = Harness.build()
local Config = env.require(env.ReplicatedStorage.Shared.Config)
local Wardrobe = env.require(env.ServerScriptService.Server.World.Wardrobe)
local Npc = env.require(env.ServerScriptService.Server.World.Npc)
local BotAvatar = env.require(env.ServerScriptService.Server.Match.BotAvatar)

local problems = 0

print("\27[1mwardrobe\27[0m")
for _, name in ipairs(Wardrobe.outfitNames()) do
	local missing = {}
	for _, piece in ipairs(Wardrobe.piecesOf(name)) do
		if not Wardrobe.hasPiece(piece) then
			table.insert(missing, piece)
			problems += 1
		end
	end
	local holder = roblox.Instance.new("Folder")
	local worn = Wardrobe.dress(name, holder, 1)
	local status = if #missing > 0 then `\27[31mMISSING {table.concat(missing, ", ")}\27[0m` else "ok"
	print(string.format("  %-12s %2d pieces  %3d parts   %s", name, #Wardrobe.piecesOf(name), #worn, status))
end

print("\n\27[1mthe landing\27[0m")
local palette = {}
for key, rgb in pairs(Config.get("overworld").palette) do
	palette[key] = roblox.Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end
local folder = roblox.Instance.new("Folder")
local people = Npc.buildAll(palette, folder)
local names = {}
for id in pairs(people) do table.insert(names, id) end
table.sort(names)
for _, id in ipairs(names) do
	local model = people[id].model
	local count = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then count += 1 end
	end
	if count < 12 then
		print(string.format("  %-12s \27[31m%d parts -- too few to read as a person\27[0m", id, count))
		problems += 1
	else
		print(string.format("  %-12s %3d parts", id, count))
	end
end

print("\n\27[1mthe enemy team\27[0m")
for _, tier in ipairs({ "rec", "amateur", "semipro", "pro", "marshal" }) do
	local parent = roblox.Instance.new("Folder")
	local avatar = BotAvatar.new(`probe_{tier}`, "Probe", parent, tier)
	avatar:setPosition(roblox.Vector3.new(0, 0, 0), roblox.Vector3.new(0, 0, -1))
	local count = 0
	for _, d in ipairs(avatar.model:GetDescendants()) do
		if d:IsA("BasePart") then count += 1 end
	end
	print(string.format("  %-10s %-12s %3d parts", tier, BotAvatar.outfitFor(tier), count))
	if count < 14 then problems += 1 end

	--[[
		The shove has to be visible on the body, not just in the rules.

		A bot at contact range used to take a player out while standing
		perfectly still: the commit delay exists so the swing can be seen coming,
		and a warning nobody can see is not a warning. Asserted here because it
		is the one animation that plays for a fraction of a second and then
		removes the thing that would have shown it.
	]]
	local rest = avatar.marker.CFrame
	avatar:setSwing(0.38)
	avatar:setPosition(roblox.Vector3.new(0, 0, 0), roblox.Vector3.new(0, 0, -1))
	if (avatar.marker.CFrame.Position - rest.Position).Magnitude < 0.1 then
		print(`          {tier}: the marker does not move during a shove`)
		problems += 1
	end
	avatar:setSwing(nil)
	avatar:setPosition(roblox.Vector3.new(0, 0, 0), roblox.Vector3.new(0, 0, -1))
	if (avatar.marker.CFrame.Position - rest.Position).Magnitude > 1e-4 then
		print(`          {tier}: the marker did not come back to rest after a shove`)
		problems += 1
	end
end

print("")
if problems > 0 then
	print(`\27[31m{problems} problem(s)\27[0m`)
	require("@lune/process").exit(1)
end
--[[
	Nobody casts a shadow. Twelve bodies at 72 parts each, all moving, would be
	the most expensive shadows in the game -- and a moving caster costs far more
	than a static one. Wardrobe sets this on the body and the kit; the marker,
	the barrel and the hopper are built in BotAvatar and were missing it, so a
	bot's body cast nothing while the thing it was holding cast three.
]]
do
	local casting = {}
	for _, tier in ipairs({ "rec", "amateur", "semipro", "pro", "marshal" }) do
		local folder = roblox.Instance.new("Folder")
		BotAvatar.new(`shadow_{tier}`, "Probe", folder, tier)
		for _, descendant in ipairs(folder:GetDescendants()) do
			if descendant:IsA("BasePart") and descendant.CastShadow then
				table.insert(casting, `{tier}/{descendant.Name}`)
			end
		end
	end
	assert(#casting == 0, `characters must cast no shadows, these do: {table.concat(casting, ", ")}`)
end

--[[
	Civilians have faces; the enemy team does not need one.

	Every head used to be a bare skin-coloured ball, which is what made the
	people at The Landing read as mannequins standing next to a squad whose mask
	lenses gave them something to look at. The bots still get none: a full mask
	covers the eyes exactly as it should, and building four parts a bot that
	nobody can see costs forty-eight across a squad that is rebuilt at every
	round boundary.
]]
do
	local faceless = {}
	for _, person in ipairs(people) do
		local found = 0
		for _, descendant in ipairs(person.model:GetDescendants()) do
			if descendant:IsA("BasePart") and (descendant.Name == "EyeL" or descendant.Name == "EyeR") then
				found += 1
			end
		end
		if found < 2 then
			table.insert(faceless, person.id)
		end
	end
	assert(#faceless == 0, `everyone at The Landing needs a face, these have none: {table.concat(faceless, ", ")}`)

	local masked = roblox.Instance.new("Folder")
	BotAvatar.new("face_probe", "Probe", masked, "pro")
	for _, descendant in ipairs(masked:GetDescendants()) do
		if descendant:IsA("BasePart") then
			assert(
				descendant.Name ~= "EyeL" and descendant.Name ~= "EyeR",
				"a bot builds eyes nobody can see behind its mask"
			)
		end
	end
end

print("\27[32mevery character builds, the civilians have faces, and none of them casts a shadow\27[0m")

-- Every sellable avatar slot builds on both native rig naming schemes.
local PlayerAppearance = env.require(env.Server.World.PlayerAppearance)
local appearance = Config.get("playerAppearance")
local gear = Config.get("gear")
local expected = {jersey = gear.protective.jerseys.items, pads = gear.protective.pads.items,
    helmet = gear.protective.helmets.items, shoulders = gear.protective.shoulders.items,
    pods = gear.paintAndAir.pods.items, mask = Config.get("economy").shop.cosmetics.masks}
for slot, items in pairs(expected) do
    for id in pairs(items) do assert(appearance.slots[slot][id], `no avatar visual for {slot}/{id}`) end
end
for _, r15 in ipairs({false, true}) do
    local character = roblox.Instance.new("Model")
    for _, name in ipairs(if r15 then {"Head", "UpperTorso", "LowerTorso", "LeftLowerLeg", "RightLowerLeg"}
        else {"Head", "Torso", "Left Leg", "Right Leg"}) do
        local part = roblox.Instance.new("Part")
        part.Name, part.Size, part.Parent = name, roblox.Vector3.new(2, 2, 1), character
    end
    for slot, items in pairs(appearance.slots) do
        for id in pairs(items) do
            PlayerAppearance.apply(character, {[slot] = id})
            local container = character:FindFirstChild("FieldKitAppearance")
            assert(container and #container:GetChildren() > 0)
            for _, part in ipairs(container:GetChildren()) do
                assert(not part.Anchored and part.Massless and not part.CanCollide and not part.CanQuery and not part.CanTouch)
                local weld = part:FindFirstChildOfClass("WeldConstraint")
                assert(weld and weld.Part0.Parent == character and weld.Part1 == part)
            end
        end
    end
    PlayerAppearance.apply(character, {})
    local count = 0
    for _, child in ipairs(character:GetChildren()) do
        if child.Name == "FieldKitAppearance" then count += 1 end
    end
    assert(count == 1, "equipping must replace overlays without accumulating parts")
    character:Destroy()
end
print("Player appearance: every slot builds on R6/R15, welded without collision or mass; re-equip replaces it.")

--[[
	The figure has to be a PERSON, and it has to move like one.

	This gate used to assert the opposite. It required `Head.Size.X /
	Torso.Size.X > 0.75` -- "the requested large-head silhouette" -- which pinned
	the skull at 3.9 heads to a body and would have failed any correction toward
	human proportions. A gate that enforces the defect is worse than no gate: it
	makes the defect look deliberate and reviewed.

	What a human silhouette actually needs, and all three are checkable without a
	renderer:

	  proportion   7.5 heads to a body, give or take. This is the single number
	               that separates a person from a bobblehead.
	  articulation limbs that ROTATE. The figure this replaces translated its
	               ellipsoids fore and aft and never turned one, which is a
	               floating sausage no matter how well the stride is timed.
	  containment  nothing outside the hit capsule. Paint that visibly lands on
	               a shoulder and does not register teaches the player that the
	               game is lying about their aim.
]]
do
    local holder = roblox.Instance.new("Model")
    local body = Wardrobe.body(holder, {
        build = { shoulders = 1, height = 1 }, torsoColour = roblox.Color3.new(1, 1, 1),
        limbColour = roblox.Color3.new(0, 0, 0), skinColour = roblox.Color3.new(0.8, 0.6, 0.4), face = true,
    })
    local Units = env.require(env.Shared.Units)
    local hitbox = Config.get("ballistics").hitbox
    body.pose(roblox.CFrame.identity)

    local headHeight = Units.studsToMetres(body.byName.Head.Size.Y)
    local heads = hitbox.bodyHeightMetres / headHeight
    assert(heads > 6.5 and heads < 8.5,
        `the figure is {string.format("%.1f", heads)} heads tall; a person is about 7.5 and a bobblehead is 4`)
    print(string.format("  proportion   %.1f heads tall, skull %.0f cm", heads, headHeight * 100))

    for _, name in ipairs({ "Head", "Chest", "Waist", "Pelvis", "ThighL", "ShinR",
                            "UpperArmL", "ForearmR", "FootL", "DeltoidR", "Nose", "EarL" }) do
        local part = body.byName[name]
        assert(part, `the figure has no {name}`)
        assert(part.Shape == roblox.Enum.PartType.Ball, `human anatomy regressed to a block: {name}`)
    end

    --[[
        Articulation. Walk the figure a metre and a half and check that the
        limbs TURNED rather than slid: a rigid translation leaves every segment
        pointing straight down, and that is the whole of what was wrong.
    ]]
    local turned = {}
    for _, name in ipairs({ "ThighL", "ThighR", "ShinL", "ShinR", "UpperArmL", "ForearmR" }) do
        turned[name] = 0
    end
    for i = 1, 60 do
        body.step(0.025, 3.2)
        body.pose(roblox.CFrame.identity)
        for name in pairs(turned) do
            --- How far this bone is from hanging straight down, in degrees.
            local up = body.byName[name].CFrame.UpVector
            local tilt = math.deg(math.acos(math.clamp(up.Y, -1, 1)))
            if tilt > turned[name] then turned[name] = tilt end
        end
    end
    for name, tilt in pairs(turned) do
        assert(tilt > 8,
            `{name} never rotated more than {string.format("%.1f", tilt)} deg through a full stride -- ` ..
            "it is sliding, not walking, which is what made the old figure a blob")
    end
    print(string.format("  articulation thigh swings %.0f deg, knee carries the shin to %.0f deg",
        turned.ThighL, turned.ShinL))

    --[[
        Nothing outside the capsule. Measured across a whole stride, because the
        widest moment of a walk is not the standing pose -- an arm swinging
        forward reaches further than one hanging.
    ]]
    local radius = hitbox.bodyWidthMetres / 2
    local function reach(): (number, string, number)
        local worst, worstName, top = 0, "", 0
        for _, part in ipairs(body.parts) do
            local at, half = part.CFrame.Position, part.Size * 0.5
            local out = math.sqrt(
                (math.abs(Units.studsToMetres(at.X)) + Units.studsToMetres(half.X)) ^ 2
                + (math.abs(Units.studsToMetres(at.Z)) + Units.studsToMetres(half.Z)) ^ 2)
            if out > worst then worst, worstName = out, part.Name end
            local crown = Units.studsToMetres(at.Y + half.Y)
            if crown > top then top = crown end
        end
        return worst, worstName, top
    end

    --[[
        Standing is the assertion. A bot holding an angle is the shape a player
        aims at, and every part of it has to be inside the capsule that decides
        whether their paint counted.
    ]]
    body.step(0, 0)
    for _ = 1, 30 do body.step(0, 0) end
    body.pose(roblox.CFrame.identity)
    local still, stillName, top = reach()
    assert(still <= radius + 1e-6,
        `standing, {stillName} reaches {string.format("%.0f", still * 100)} cm from the spine, outside the ` ..
        `{string.format("%.0f", radius * 100)} cm hit capsule -- paint would land on it and not register`)
    assert(top <= hitbox.bodyHeightMetres + 1e-6,
        `the figure stands {string.format("%.2f", top)} m, above the {hitbox.bodyHeightMetres} m capsule`)

    --[[
        Mid-stride is REPORTED, not asserted, and the distinction is the same one
        tools/probe-hitbox draws. A walking leg genuinely swings a foot in front
        of the body; a capsule is a vertical cylinder and cannot follow it. What
        would matter is a torso or a head outside the capsule, so those are held
        to the standing bound at every phase of the walk.
    ]]
    local core = { Head = true, Chest = true, Waist = true, Pelvis = true,
                   DeltoidL = true, DeltoidR = true, Neck = true }
    local stride, strideName = 0, ""
    for _ = 1, 48 do
        body.step(0.035, 3.2)
        body.pose(roblox.CFrame.identity)
        local out, name = reach()
        if out > stride then stride, strideName = out, name end
        for _, part in ipairs(body.parts) do
            if core[part.Name] then
                local at, half = part.CFrame.Position, part.Size * 0.5
                local far = math.sqrt(
                    (math.abs(Units.studsToMetres(at.X)) + Units.studsToMetres(half.X)) ^ 2
                    + (math.abs(Units.studsToMetres(at.Z)) + Units.studsToMetres(half.Z)) ^ 2)
                assert(far <= radius + 1e-6,
                    `{part.Name} leaves the hit capsule while walking, reaching ` ..
                    `{string.format("%.0f", far * 100)} cm of {string.format("%.0f", radius * 100)} cm`)
            end
        end
    end
    print(string.format("  containment  standing %.0f cm of %.0f cm (%s), crown %.2f m; mid-stride %.0f cm (%s)",
        still * 100, radius * 100, stillName, top, stride * 100, strideName))

    --[[
        The headshot ellipsoid scores where the head actually is.

        Measured standing. The walk bobs the whole figure, so a head sampled
        mid-stride is a few centimetres off its own scoring centre by design --
        what has to line up is the pose a bot holds when it is not moving.
    ]]
    for _ = 1, 40 do body.step(0, 0) end
    body.pose(roblox.CFrame.identity)
    local rule = Config.get("camos").headshot
    local center = hitbox.headTopMetres - rule.centerBelowHeadTopMetres
    assert(math.abs(Units.studsToMetres(body.byName.Head.CFrame.Position.Y) - center) < 0.001,
        "mask scoring center no longer follows the visible head")
    holder:Destroy()
end

--[[
	Every outfit, measured against the body it is worn on.

	The clothes were cut for a torso 0.56 m across. When the figure was rebuilt at
	human proportions the chest became 0.35 m, and thirty garments were suddenly
	hanging in the air outside the shape the game shoots at -- a jersey 0.66 m
	wide on a 0.35 m chest, a pod belt whose corners cleared the hit capsule by
	four centimetres, hair standing above the top of the head.

	None of that is cosmetic. Paint that visibly lands on a sleeve and does not
	register teaches a player that their aim is not what decides the hit, and this
	is a game that asks them to trust it.

	Hands are the documented exception, and only hands: a person holding a marker
	has them out in front of their chest, and no vertical capsule can contain that
	without the arms being wrong instead.
]]
do
	local hitbox = Config.get("ballistics").hitbox
	local radius = hitbox.bodyWidthMetres / 2
	local Units = env.require(env.Shared.Units)
	--[[
		Worn on the hands, or held in them -- the one documented exception.

		A person holding a marker, or a clipboard, has it out in front of their
		chest, and no vertical capsule can contain that without the arms being
		wrong instead. Decided by ANCHOR rather than by a list of part names, so
		a new prop put in a hand is exempt for the reason it is exempt.
	]]
	local function held(item: any): boolean
		return item.anchor == "hands"
	end
	local bad, checked = {}, 0

	for _, outfit in ipairs(Wardrobe.outfitNames()) do
		local holder = roblox.Instance.new("Model")
		local build = Wardrobe.buildOf(outfit)
		local isBot = string.sub(outfit, 1, 3) == "bot"
		local body = Wardrobe.body(holder, {
			build = build,
			torsoColour = roblox.Color3.new(1, 1, 1), limbColour = roblox.Color3.new(0, 0, 0),
			skinColour = roblox.Color3.new(0.8, 0.6, 0.4),
			handsForward = isBot, face = not isBot,
		})
		local worn = Wardrobe.dress(outfit, holder, build.height)
		Wardrobe.place(worn, body.anchors(roblox.CFrame.identity))
		for _, item in ipairs(worn) do
			--[[
				A cylinder's cross-section has to be round.

				Its length is the local X and the other two components are the
				circle. Authored with the length in Y instead, a 20 cm paintball
				pod renders as a 6 cm ellipse lying on its side -- which is
				exactly what every pod, both bandolier tubes, the beanie cuff and
				the headlamp band were doing. The two axes matching is the cheap
				way to catch it, because an elliptical cylinder is almost never
				what anyone meant.
			]]
			if item.part.Shape == roblox.Enum.PartType.Cylinder then
				local size = item.part.Size
				assert(math.abs(size.Y - size.Z) < 1e-4,
					`{outfit}/{item.part.Name} is an elliptical cylinder ({size}); ` ..
					"a Cylinder's length is its local X and the other two axes are the circle")
			end
			if held(item) then continue end
			checked += 1
			--[[
				The axis-aligned extent of a part that may be ROTATED.

				Reading `Size` straight off a rotated part measures a box that is
				not there: the headlamp band is a disc 24 cm across and 3 cm
				thick standing on its edge in local space, so its unrotated
				half-height says it reaches 12 cm above the skull when it reaches
				1.7. Projecting each local axis onto each world axis is what the
				part actually occupies.
			]]
			local cf, half = item.part.CFrame, item.part.Size * 0.5
			local right, up, look = cf.RightVector, cf.UpVector, cf.LookVector
			local function extent(axis: string): number
				return math.abs((right :: any)[axis]) * half.X
					+ math.abs((up :: any)[axis]) * half.Y
					+ math.abs((look :: any)[axis]) * half.Z
			end
			local at = cf.Position
			local out = math.sqrt(
				(math.abs(Units.studsToMetres(at.X)) + Units.studsToMetres(extent("X"))) ^ 2
				+ (math.abs(Units.studsToMetres(at.Z)) + Units.studsToMetres(extent("Z"))) ^ 2)
			local tall = extent("Y")
			local top = Units.studsToMetres(at.Y + tall)
			local bottom = Units.studsToMetres(at.Y - tall)
			if out > radius + 0.005 then
				table.insert(bad, string.format("%s/%s reaches %.0f cm, outside the %.0f cm capsule",
					outfit, item.part.Name, out * 100, radius * 100))
			elseif top > hitbox.bodyHeightMetres + 0.005 then
				table.insert(bad, string.format("%s/%s tops out at %.2f m, above the %.2f m capsule",
					outfit, item.part.Name, top, hitbox.bodyHeightMetres))
			elseif bottom < -0.03 then
				table.insert(bad, string.format("%s/%s reaches %.2f m, through the ground",
					outfit, item.part.Name, bottom))
			end
		end
		holder:Destroy()
	end
	if #bad > 0 then
		for _, line in ipairs(bad) do print(`          {line}`) end
	end
	assert(#bad == 0, `{#bad} worn part(s) do not fit the body they are on`)
	print(string.format("  clothing     %d worn parts across %d outfits, all inside the capsule",
		checked, #Wardrobe.outfitNames()))
end
print("Human proportion, articulation, containment, clothing fit and mask scoring passed.")
