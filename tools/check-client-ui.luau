--!strict
-- Builds client visuals against Lune's real Roblox property database.
-- Engine events, services and remotes are mocked; this cannot validate rendered layout or first-person feel.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local root = require("@lune/process").cwd:gsub("/$", "")
local env = require("./Harness").build(root)
for _, name in ipairs(fs.readDir(root .. "/src/StarterPlayer/Client")) do
	if name:sub(-5) == ".luau" then
		luau.load(fs.readFile(root .. "/src/StarterPlayer/Client/" .. name), { debugName = name })
	end
end
print("All client modules compiled")
local function signal()
	local callbacks = {}
	return { Connect = function(_, fn) table.insert(callbacks, fn); return { Disconnect = function() end } end,
		fire = function(_, ...) for _, fn in ipairs(callbacks) do fn(...) end end }
end
local wrappers = {}
--- raw instance -> how many property writes it has taken.
local writeCount = {}
local trailClears = 0
--- proxy -> raw, so any Ref property can be unwrapped on assignment.
local raws = {}
local wrap
wrap = function(raw)
	if wrappers[raw] then return wrappers[raw] end
	local events = {}
	local proxy = setmetatable({}, {
		__index = function(_, key)
			if key == "_raw" then return raw end
			if key == "Clear" and raw:IsA("Trail") then return function() trailClears += 1 end end
			if key == "GetPropertyChangedSignal" then return function() return signal() end end
			if key == "Activated" or key == "MouseEnter" or key == "MouseLeave" then
				if not events[key] then events[key] = signal() end
				return events[key]
			end
			if key == "GetChildren" or key == "GetDescendants" then return function()
				local out = {}; for _, child in ipairs(raw[key](raw)) do table.insert(out, wrap(child)) end; return out
			end end
			if key == "FindFirstChild" or key == "WaitForChild" then return function(_, name)
				local found = raw:FindFirstChild(name); return if found then wrap(found) else nil
			end end
			if key == "IsA" then return function(_, class) return raw:IsA(class) end end
			if key == "Destroy" or key == "ClearAllChildren" then return function() raw[key](raw) end end
			if key == "Parent" then return if raw.Parent then wrap(raw.Parent) else nil end
			if key == "AbsoluteSize" then return roblox.Vector2.new(390, 800) end
			--[[
				Signals the engine has and Lune's Instance does not. UiNavigation
				releases gamepad focus on Destroying, and without a stub the whole
				check died on "Destroying is not a valid member".
			]]
			if key == "Destroying" or key == "AncestryChanged" or key == "ChildAdded" then
				events[key] = events[key] or signal()
				return events[key]
			end
			--[[
				Transport the engine has and Lune's dump does not. Lune knows the
				AudioPlayer class and its properties but carries no methods, so
				Play and Stop are no-ops here. That is the right trade: what this
				gate needs to assert is the GRAPH -- an AudioPlayer with no Wire
				to an output is silent and reports nothing, and that is the
				failure worth catching -- not whether Lune can make a noise.
			]]
			if key == "Play" or key == "Stop" then return function() end end
			return raw[key]
		end,
		--[[
			Unwrap on EVERY Instance-reference property, not just Parent.
			UiNavigation wires gamepad focus with NextSelectionUp/Down/Left/Right,
			which are Refs like Parent is -- assigning a proxy to one failed with
			"Failed to convert from 'table' into 'Ref'".
		]]
		--[[
			Counting every property write is what makes "this readout caches"
			testable. A cache is a claim about WRITES, and the widget cannot
			show you one: Size is quantised to whole offset pixels and Text is
			the same string either way, so reading the widget back passes
			whether the cache works or not. Three readouts skip the write when
			nothing changed and none of that was ever asserted.
		]]
		__newindex = function(_, key, value)
			writeCount[raw] = (writeCount[raw] or 0) + 1
			raw[key] = if raws[value] then raws[value] else value
		end,
	})
	wrappers[raw] = proxy
	raws[proxy] = raw
	return proxy
end
local Instance = { new = function(class) return wrap(roblox.Instance.new(class)) end }
local playerGui = Instance.new("Folder")
local players = { LocalPlayer = { WaitForChild = function() return playerGui end, CharacterAdded = signal() } }
-- PreferredInput is watched by the HUD so the control hint follows touch vs
-- keyboard. The stub needs the signal accessor or Hud.build dies on it.
local input = { InputBegan = signal(), InputEnded = signal(), WindowFocusReleased = signal() }
input.GetPropertyChangedSignal = function() return signal() end
local actions = {}
local contextActions = {
	BindAction = function(_, name, callback) actions[name] = callback end,
	-- UiNavigation binds the gamepad Back button at a priority and unbinds it
	-- when the menu closes; both have to exist or menu construction dies.
	BindActionAtPriority = function(_, name, callback) actions[name] = callback end,
	UnbindAction = function(_, name) actions[name] = nil end,
}
local clientWorld = Instance.new("Workspace")
local shared = env.ReplicatedStorage.Shared
local client = {}
-- Every client module, not a hand-listed subset. Hud started requiring
-- UiNavigation and this tool had no stub for it, so the whole check died on
-- "attempt to index nil" instead of reporting anything -- a list that has to be
-- edited by hand is a list that goes stale silently.
-- ...and it went stale anyway: Audio was added and this list was not. Read the
-- directory instead, so a new client module is stubbed the moment it exists.
for _, entry in ipairs(fs.readDir(root .. "/src/StarterPlayer/Client")) do
	local name = string.match(entry, "^([%w_]+)%.luau$")
	if name and name ~= "init" then
		client[name] = { name = name, Parent = client }
	end
end
local cache = {}
local loaded
local latestSnapshot
local requests = {}
local remoteFns = { fn = function(name) return { InvokeServer = function(_, ...)
	table.insert(requests, { name = name, args = { ... } })
	if name == "RequestShopCatalogue" then return latestSnapshot end
	return { ok = true }
end } end, event = function() return { FireServer = function() end } end }
loaded = function(target)
	if target == env.ReplicatedStorage.Net.Remotes then return remoteFns end
	if not target.name then return env.require(target) end
	if cache[target.name] then return cache[target.name] end
	local globals = { game = { GetService = function(_, name)
		if name == "Players" then return players end
		if name == "UserInputService" then return input end
		if name == "ContextActionService" then return contextActions end
		return env.game:GetService(name)
	end }, require = loaded, script = target, Instance = Instance,
		Vector2 = roblox.Vector2, Vector3 = roblox.Vector3, Color3 = roblox.Color3, CFrame = roblox.CFrame,
		UDim = roblox.UDim, UDim2 = roblox.UDim2, Enum = roblox.Enum,
		-- Tracers build a Trail out of these; without them the module loads and
		-- dies on its first shot with "attempt to index nil with 'new'".
		NumberSequence = roblox.NumberSequence, ColorSequence = roblox.ColorSequence,
		NumberRange = roblox.NumberRange,
		task = { delay = function() end }, workspace = clientWorld }
	local result = luau.load(fs.readFile(root .. "/src/StarterPlayer/Client/" .. target.name .. ".luau"), { environment = globals, injectGlobals = true })()
	cache[target.name] = result
	return result
end
--- Property writes taken by the instance behind a proxy.
local function writesTo(proxy: any): number
	return writeCount[raws[proxy]] or 0
end
local Hud = loaded(client.Hud)
Hud.build()
Hud.setMarker("mechanical")
Hud.setPhase("hub")
Hud.setPhase("warmup")
Hud.setRound(1, 5, 2)
Hud.setRemaining(1, 2)
Hud.setSpread(0.35, 80, 900)
local Config = env.require(shared.Config)
local Ballistics = env.require(shared.Ballistics)
Hud.setRange(25, Ballistics.specFromMarker(Config.get("markers").markers.mechanical, Config.get("ballistics")), 80, 900)
Hud.setHopper(18, 180, false)
--[[
	The per-frame readouts, and the caching that keeps them from writing the same
	string sixty times a second. Called twice with the same input on purpose: the
	second call must be a no-op, and a cache that silently stopped caching would
	otherwise look exactly like one that works.
]]
do
	local rangeSpec = Ballistics.specFromMarker(Config.get("markers").markers.mechanical, Config.get("ballistics"))
	Hud.setRange(25, rangeSpec, 80, 900)
	Hud.setRange(25, rangeSpec, 80, 900)
	Hud.setRange(nil, rangeSpec, 80, 900)
	Hud.setRange(nil, rangeSpec, 80, 900)

	--[[
		The crosshair is written every frame from RenderStepped, so it is the
		one that matters most. Counted rather than read back: Size is quantised
		to whole offset pixels, so an uncached write and a cached skip leave the
		widget looking identical.
	]]
	local aim = playerGui:FindFirstChild("LiveRoundAim")
	local ring = assert(aim and aim:FindFirstChild("SpreadRing"), "no crosshair to measure")
	Hud.setSpread(0.8, 80, 900)
	local before = writesTo(ring)
	Hud.setSpread(0.8, 80, 900)
	assert(writesTo(ring) == before, "the crosshair rewrote itself for an unchanged spread")
	Hud.setSpread(0.2, 80, 900)
	assert(writesTo(ring) > before, "a real spread change did not resize the crosshair")

	--[[
		The other two per-frame readouts. setHopper has cached since it was
		written and setRange was fixed to; neither claim was ever checked, and
		both are invisible in the widget because the cached and uncached paths
		assign the same string.
	]]
	local hopper = assert(playerGui:FindFirstChild("LiveRoundHud"), "no HUD")
	local range = assert(playerGui:FindFirstChild("LiveRoundAim"):FindFirstChild("Range"), "no range readout")
	Hud.setRange(25, rangeSpec, 80, 900)
	local rangeWrites = writesTo(range)
	Hud.setRange(25, rangeSpec, 80, 900)
	assert(writesTo(range) == rangeWrites, "the range readout rewrote the same string")
	Hud.setRange(60, rangeSpec, 80, 900)
	assert(writesTo(range) > rangeWrites, "a real range change did not reach the readout")

	local function findDeep(root, name)
		for _, d in ipairs(root:GetDescendants()) do
			if d.Name == name then return d end
		end
		return nil
	end
	local hopperLabel = assert(findDeep(hopper, "Hopper"), "no hopper readout")
	Hud.setHopper(18, 180, false)
	local hopperWrites = writesTo(hopperLabel)
	Hud.setHopper(18, 180, false)
	assert(writesTo(hopperLabel) == hopperWrites, "the hopper readout rewrote the same string")
	Hud.setHopper(17, 180, false)
	assert(writesTo(hopperLabel) > hopperWrites, "a real hopper change did not reach the readout")

	Hud.setStage("Their Half", 3, 4)
	local par = { gold = 145, silver = 195, bronze = 270 }
	Hud.setClock(0, par)
	Hud.setClock(12.34, par)
	Hud.setClock(12.34, par)
	-- Past bronze, past silver, past gold and inside gold: every colour branch.
	Hud.setClock(300, par)
	Hud.setClock(200, par)
	Hud.setClock(150, par)
	Hud.setClock(90, par, true)
	Hud.setClock(nil, nil)
end
--[[
	Rebuilding must hand back a clean HUD. Every cached readout skips the write
	when the value has not changed, and build creates new labels and a new
	crosshair -- so a cache surviving a rebuild would leave the fresh widgets
	showing their placeholders until the underlying value happened to move.
]]
do
	Hud.build()
	local aim = playerGui:FindFirstChild("LiveRoundAim")
	local ring = assert(aim and aim:FindFirstChild("SpreadRing"), "no crosshair after rebuild")
	local fresh = ring.Size
	Hud.setSpread(0.8, 80, 900)
	assert(ring.Size ~= fresh, "the crosshair cache survived a rebuild and left the new ring at its placeholder size")
	Hud.setHopper(18, 180, false)
	Hud.setMarker("mechanical")
end
Hud.setCurrency(99999999)
Hud.setDeaths(2, 0.63)
Hud.flashHit(true)
Hud.setCamoProgress({ headshots = 12, nextUnlock = { displayName = "Tide Shift", requiredHeadshots = 35 }, unlockedCamos = { "citrusCircuit" } })
Hud.showChatter({ speaker = "Crew", text = "See you on the field." })
Hud.showSummary({ cleared = true, map = "speedball", marker = "mechanical", eliminations = 20, deaths = 1, headshots = 5, hitRate = 0.5, scores = {}, prescription = { line = "Track your target through the turn.", drill = "tracking" } }, { total = 420, deathPenalty = 0.8, roundsCleared = 5, roundsPlayed = 5 }, function() return { ok = true } end, function() return { ok = true } end)
print("HUD construction / combat / summary methods passed against Roblox property database")
print("Per-frame readouts verified by counted property writes: crosshair, range and hopper all skip an unchanged value, and a rebuild comes back clean")
local ShopUi = loaded(client.ShopUi)
latestSnapshot = { ok = true, balance = 0, freeMode = true, categories = { "markers", "paintColors" }, catalogue = {
	markers = { { id = "mechanical", displayName = "Ridgeline Mech", cost = 0, owned = false } },
	camos = { { id = "factory", displayName = "Factory", cost = 0, purchasable = false, owned = true, requiredHeadshots = 0 }, { id = "citrusCircuit", displayName = "Citrus Circuit", cost = 0, purchasable = false, owned = false, requiredHeadshots = 10 } },
	offers = { { id = "collection", displayName = "Field Collection", free = true, price = 0, owned = false } },
} }
ShopUi.open(latestSnapshot, function() end)
local shopGui = playerGui:FindFirstChild("PitStopShop")
local function buttonNamed(parent, value)
	for _, child in ipairs(parent:GetDescendants()) do if child:IsA("TextButton") and child.Text == value then return child end end
	error("No button " .. value)
end
buttonNamed(shopGui, "Claim free").Activated:fire()
assert(requests[1].name == "RequestPurchase" and requests[2].name == "RequestEquip")
buttonNamed(shopGui, "Headshot camos").Activated:fire()
buttonNamed(shopGui, "Equip").Activated:fire()
assert(requests[#requests - 1].name == "RequestEquip" and requests[#requests - 1].args[1] == "camos")
buttonNamed(shopGui, "Collection").Activated:fire()
buttonNamed(shopGui, "Claim free").Activated:fire()
assert(requests[#requests - 1].name == "RequestCommerce" and requests[#requests - 1].args[1].action == "claim")
ShopUi.close()
print("Shop construction / free claim / earned camo equip / free commerce routing passed")
local DialogueUi = loaded(client.DialogueUi)
DialogueUi.setOnClose(function() end)
DialogueUi.show({ speaker = "Parsons", lines = { "Welcome to the field.", "Pick your next chapter." }, options = { { text = "Tell me about the field." }, { text = "Show me the markers." } } }, function() end)
DialogueUi.close()
print("Dialogue construction and cleanup passed")

local Input = loaded(client.Input)
Input.bind()
local fireInput = { UserInputType = roblox.Enum.UserInputType.MouseButton1, KeyCode = roblox.Enum.KeyCode.Unknown }
input.InputBegan:fire(fireInput, false)
assert(Input.state().firing)
Input.setPointerFree(true)
input.InputBegan:fire(fireInput, false)
actions.LR_Reload(nil, roblox.Enum.UserInputState.Begin)
assert(not Input.state().firing and not Input.consumeReload(), "menus must suppress fire and reload")
Input.setPointerFree(false)
input.InputBegan:fire(fireInput, false)
input.WindowFocusReleased:fire()
assert(not Input.state().firing, "focus loss must stop held fire")
-- Grounded movement gates slides; elapsed slides restore speed and camera.
do
    local h = { WalkSpeed = 0, CameraOffset = roblox.Vector3.zero, MoveDirection = roblox.Vector3.zero, FloorMaterial = roblox.Enum.Material.Grass }
    players.LocalPlayer.Character = { FindFirstChildOfClass = function() return h end }
    actions.LR_Sprint(nil, roblox.Enum.UserInputState.Begin)
    actions.LR_Slide(nil, roblox.Enum.UserInputState.Begin)
    assert(not Input.state().sliding, "stationary slide accepted")
    h.MoveDirection = roblox.Vector3.new(0, 0, -1)
    h.FloorMaterial = roblox.Enum.Material.Air
    actions.LR_Slide(nil, roblox.Enum.UserInputState.Begin)
    assert(not Input.state().sliding, "airborne slide accepted")
    h.FloorMaterial = roblox.Enum.Material.Grass
    actions.LR_Slide(nil, roblox.Enum.UserInputState.Begin)
    assert(Input.state().sliding, "grounded sprint did not slide")
    Input.tick(1)
    assert(h.CameraOffset.Y < 0, "slide did not lower eye height")
    Input.state().slideEndsAt = -1
    Input.tick(1)
    assert(not Input.state().sliding and math.abs(h.CameraOffset.Y) < 0.02, "slide expiry did not restore eye height")
    input.WindowFocusReleased:fire()
    players.LocalPlayer.Character = nil
end
print("Input modal and focus-loss checks passed")

do
    local begin, cancel, finish = roblox.Enum.UserInputState.Begin, roblox.Enum.UserInputState.Cancel, roblox.Enum.UserInputState.End
    actions.LR_Sprint(nil, begin)
    actions.LR_Sprint(nil, cancel)
    assert(not Input.state().sprinting and Input.sprintRecovery(os.clock()) > 0.9, "cancelled sprint stuck or lost recovery")
    actions.LR_Sprint(nil, begin)
    actions.LR_Crouch(nil, begin)
    assert(not Input.state().sprinting and Input.sprintRecovery(os.clock()) > 0.9, "crouch bypassed sprint recovery")
    actions.LR_Crouch(nil, cancel)
    assert(not Input.state().crouching, "cancelled crouch stayed held")
    actions.LR_LeanLeft(nil, begin)
    actions.LR_LeanRight(nil, begin)
    assert(Input.state().lean == 0, "opposed lean inputs should cancel")
    actions.LR_LeanRight(nil, finish)
    assert(Input.state().lean == -1, "releasing right lost the still-held left lean")
    actions.LR_LeanLeft(nil, cancel)
    assert(Input.state().lean == 0)
    local h = { CameraOffset = roblox.Vector3.zero, WalkSpeed = 0 }
    local rootPart = { AssemblyLinearVelocity = roblox.Vector3.new(0, 50, 0) }
    players.LocalPlayer.Character = { FindFirstChild = function() return rootPart end, FindFirstChildOfClass = function() return h end }
    assert(Input.stance() == "standing", "vertical velocity inflated the horizontal movement spread")
    actions.LR_LeanLeft(nil, begin)
    for _ = 1, 30 do Input.tick(1 / 30) end
    local at30 = h.CameraOffset
    h.CameraOffset = roblox.Vector3.zero
    for _ = 1, 120 do Input.tick(1 / 120) end
    assert((at30 - h.CameraOffset).Magnitude < 0.0001, "lean response depends on frame rate")
    input.WindowFocusReleased:fire()
    players.LocalPlayer.Character = nil
end
print("Input cancellation, overlapping lean keys, sprint recovery and 30/120 Hz smoothing passed")

--[[
    A ceiling, not a target. The viewmodel is rebuilt on every equip and on
    every camo change, and rebuildPanels removes and re-adds panels each time --
    a leak there grows the model one camo swap at a time and would otherwise
    only show up as a slow frame-rate slide nobody could attribute.
]]
local viewModelPartBudget = 64
local ViewMarker = loaded(client.ViewMarker)
local camera = Instance.new("Camera")

--[[
	The rest pose, checked against the data rather than against itself.

	step used to rebuild this transform from markers.json every frame; the
	offset and tilt are constant between equips, so they are baked once at
	equip now. A refactor like that fails silently -- a dropped or reordered
	multiplication leaves the marker somewhere off the screen edge, which
	nothing headless would notice and which no assertion about part counts or
	shadows can see.

	Independently recomputed here, from the same JSON, against a camera that is
	deliberately not at the origin: with an identity camera a dropped
	`camera.CFrame *` would still pass.
]]
do
	camera.CFrame = roblox.CFrame.new(roblox.Vector3.new(120, 14, -37))
		* roblox.CFrame.Angles(math.rad(-11), math.rad(63), 0)
	ViewMarker.equip("mechanical", "factory")
	ViewMarker.step(camera, true, 1 / 60, { sprinting = false, sliding = false }, 0, nil, 2)
	local built = assert(camera:FindFirstChild("LocalPaintballMarker"), "no viewmodel")
	local receiver = assert(built:FindFirstChild("Receiver"), "no receiver")
	local vm = Config.get("markers").viewModel
	local o, tilt = vm.offsetStuds, vm.tiltDegrees
	-- The receiver sits at the model's origin, so at rest it IS the pose.
	local expected = camera.CFrame * roblox.CFrame.new(o[1], o[2], o[3])
		* roblox.CFrame.Angles(math.rad(tilt[2]), math.rad(tilt[3]), math.rad(tilt[1]))
	--[[
		Position AND orientation. The tilt is applied after the translation, so
		it cannot move the origin -- an earlier version of this check compared
		positions only, and swapping the three tilt axes passed it. The pose is
		a CFrame; comparing a third of one is not comparing it.
	]]
	local drift = (receiver.CFrame.Position - expected.Position).Magnitude
	assert(drift < 1e-3, `the viewmodel rest pose moved {drift} studs from what markers.json describes`)
	for _, axis in ipairs({ "LookVector", "UpVector", "RightVector" }) do
		local turned = (receiver.CFrame[axis] - expected[axis]).Magnitude
		assert(turned < 1e-3, `the viewmodel rest pose {axis} is {turned} off what markers.json describes`)
	end
	-- Recoil must still displace it, or the kick branch is dead.
	ViewMarker.fire()
	ViewMarker.step(camera, true, 1 / 60, { sprinting = false, sliding = false }, 0, nil, 2)
	assert((receiver.CFrame.Position - expected.Position).Magnitude > 1e-4,
		"firing did not move the viewmodel: the recoil branch is unreachable")
end

-- Reload hardware must move and return, and sprint must not bob at rest.
do
    ViewMarker.equip("mechanical", "factory")
    local idle = { sprinting = false, sliding = false }
    ViewMarker.step(camera, true, 1, idle, 0, nil, 2)
    local marker = camera:FindFirstChild("LocalPaintballMarker")
    local receiver, lid, pod = marker:FindFirstChild("Receiver"), marker:FindFirstChild("HopperLid"), marker:FindFirstChild("ReloadPod")
    local rest, closed = receiver.CFrame, lid.CFrame
    ViewMarker.step(camera, true, 1, idle, 0, os.clock() + 1, 2)
    assert(pod.Transparency == 0, "reload pod missing during pour")
    assert((lid.CFrame.UpVector - closed.UpVector).Magnitude > 0.1, "hopper lid did not open")
    assert((receiver.CFrame.Position - rest.Position).Magnitude > 0.1, "reload pose did not lift marker")
    ViewMarker.step(camera, true, 1, idle, 0, nil, 2)
    assert(pod.Transparency == 1 and (lid.CFrame.Position - closed.Position).Magnitude < 0.001, "reload hardware failed to reset")
    ViewMarker.step(camera, true, 1, { sprinting = true }, 0, nil, 2)
    assert((receiver.CFrame.Position - rest.Position).Magnitude < 0.001, "stationary sprint moved marker")
    ViewMarker.step(camera, true, 1, { sprinting = true }, 20, nil, 2)
    assert((receiver.CFrame.Position - rest.Position).Magnitude > 0.1, "sprint pose missing")
    ViewMarker.step(camera, true, 1, { sliding = true }, 20, nil, 2)
    assert((receiver.CFrame.UpVector - rest.UpVector).Magnitude > 0.1, "slide pose missing")
    ViewMarker.step(camera, false, 1, idle, 0, nil, 2)
    ViewMarker.step(camera, true, 1, idle, 0, nil, 2)
    assert((receiver.CFrame.Position - rest.Position).Magnitude < 0.001, "hidden marker retained motion")
end
--[[
    The swing.

    Cosmetic, but it is the animation that plays while the server is deciding
    an elimination, so it has to be exactly as long as the rule says and it has
    to hand the marker back afterwards. It also has to OUTRANK a reload on
    screen: somebody has walked into you and the pod can wait. A swing that
    quietly lost to the reload pose would leave the player watching a pour
    while the shove they pressed resolved invisibly.
]]
do
    ViewMarker.equip("mechanical", "factory")
    local idle = { sprinting = false, sliding = false }
    ViewMarker.step(camera, true, 1, idle, 0, nil, 2)
    local marker = camera:FindFirstChild("LocalPaintballMarker")
    local receiver, glove = marker:FindFirstChild("Receiver"), marker:FindFirstChild("LeftGlove")
    local rest, restHand = receiver.CFrame, glove.CFrame

    local rules = Config.require("match", "hitRules.melee")
    ViewMarker.swing()
    assert(ViewMarker.isSwinging(), "a swing that is not swinging")
    --[[
        The swing reads the wall clock, the same as recoil does, so the only
        way to sample it part-way through is to actually be part-way through.
        Held to the contact frame: a tenth of a second in a gate, in exchange
        for checking the pose the player is looking at when the hit resolves
        rather than the rest frame it opens on.
    ]]
    local until_ = os.clock() + rules.swingSeconds * rules.contactFraction
    while os.clock() < until_ do end
    ViewMarker.step(camera, true, 1 / 60, idle, 0, nil, 2)
    local swung = receiver.CFrame
    assert((swung.Position - rest.Position).Magnitude > 0.05, "the swing did not move the marker")
    assert((glove.CFrame.Position - restHand.Position).Magnitude > 0.01, "the left hand stayed on the foregrip")

    -- A reload underneath must not win the marker back mid-swing.
    ViewMarker.step(camera, true, 1 / 60, idle, 0, os.clock() + 1, 2)
    assert((receiver.CFrame.Position - swung.Position).Magnitude < 0.2,
        "a reload overrode a swing in progress")

    -- And the hopper lid keeps following the reload underneath, so a swing
    -- interrupting a pour does not strand it open.
    local lid = marker:FindFirstChild("HopperLid")
    assert(lid ~= nil, "no hopper lid")

    local Melee = env.require(shared.Melee)
    assert(Melee.contactDelay(rules) < rules.swingSeconds, "a swing that lands after it ends")
end
print("Reload, sprint, slide, swing and animation reset checks passed")

--[[
    Audio: every cue is named by something, and every name is a cue.

    Sound ids are deliberately empty in Data/audio.json -- audio belongs to
    whoever uploaded it, and hardcoding an id ships a build that is silent or
    moderated out from under you. That makes the whole system quiet by design,
    which is exactly the condition under which a typo at a call site would never
    be noticed. So both directions are checked: a cue nobody plays is dead data,
    and a call naming a cue that does not exist is permanent silence.
]]
do
    local SoundService = env.game:GetService("SoundService")
    local Audio = loaded(client.Audio)
    local Music = loaded(client.Music)
    local cues = Config.get("audio").cues

    local sources = ""
    for _, entry in ipairs(fs.readDir(root .. "/src/StarterPlayer/Client")) do
        if string.match(entry, "%.luau$") then
            sources ..= fs.readFile(root .. "/src/StarterPlayer/Client/" .. entry)
        end
    end

    -- Every quoted name inside an Audio.play(...) call, not just the simple
    -- form: one call site picks between "headshot" and "hit" inline, and a
    -- pattern that only matched Audio.play("x") reported the branch it could
    -- not read as an unplayed cue.
    local played: { [string]: boolean } = {}
    for call in string.gmatch(sources, "Audio%.play%b()") do
        for name in string.gmatch(call, '"([%w_]+)"') do
            played[name] = true
            assert(cues[name] ~= nil, `Audio.play names '{name}', which is no cue in Data/audio.json`)
        end
    end
    for name in pairs(cues) do
        assert(played[name], `audio cue '{name}' is authored and never played`)
    end

    -- And with no ids supplied, playing every cue is a silent no-op rather
    -- than an error, which is the shipped state of this file today.
    for name in pairs(cues) do
        Audio.play(name)
    end
    Audio.play("notACue")
    Audio.clear()

    --[[
        And the graph itself.

        Nothing routes implicitly in the current audio API: an AudioPlayer with
        no Wire to an AudioDeviceOutput is silent and reports nothing. That is
        the failure this project would not otherwise notice for a whole
        playtest, so the wiring is asserted rather than assumed -- with a real
        id, since a null one is skipped before a voice is ever built.
    ]]
    local probeCues = Config.get("audio").cues
    probeCues.fire.soundId = "rbxassetid://1"
    Audio.play("fire")
    local built = SoundService:FindFirstChild("LiveRoundAudio")
    assert(built, "playing a supplied cue built no audio folder")
    local voice = built:FindFirstChildOfClass("AudioPlayer")
    local device = built:FindFirstChildOfClass("AudioDeviceOutput")
    assert(voice and device, "a cue produced no AudioPlayer/AudioDeviceOutput pair")
    local wire = voice:FindFirstChildOfClass("Wire")
    assert(wire, "the AudioPlayer has no Wire -- it would play silently forever")
    assert(wire.SourceInstance == voice and wire.TargetInstance == device,
        "the Wire does not connect the player to the output")
    probeCues.fire.soundId = nil
    Audio.clear()
    assert(not SoundService:FindFirstChild("LiveRoundAudio"), "audio teardown left its folder behind")

    -- Music: same graph, two decks so a crossfade has something to fade into.
    local contexts = Config.get("audio").music
    contexts.playlists.hub = { "rbxassetid://2" }
    Music.setContext(contexts.context.hub)
    local musicFolder = SoundService:FindFirstChild("LiveRoundMusic")
    assert(musicFolder, "setting a music context built no music folder")
    local decks = 0
    for _, child in ipairs(musicFolder:GetChildren()) do
        if child:IsA("AudioPlayer") then
            decks += 1
            assert(child:FindFirstChildOfClass("Wire"), `music deck {child.Name} has no Wire`)
            assert(child.Looping, `music deck {child.Name} does not loop`)
        end
    end
    assert(decks == 2, `expected two music decks for crossfading, found {decks}`)
    -- The fade has to actually move, or the crossfade is a cut with extra code.
    Music.step(0.5)
    Music.duck(0.1)
    Music.step(0.5)
    Music.setContext(contexts.context.results)
    Music.clear()
    assert(not SoundService:FindFirstChild("LiveRoundMusic"), "music teardown left its folder behind")
    contexts.playlists.hub = {}
    print(`Audio checked: {(function() local n = 0 for _ in pairs(cues) do n += 1 end return n end)()} cues all played and none named by typo; graph wired player -> wire -> output; two music decks crossfade and tear down`)
end

for _, id in ipairs(Config.get("markers").order) do
    ViewMarker.equip(id, "factory")
    for _, skin in ipairs({ "raw", "duracoat", "splitDust" }) do
        ViewMarker.setSkin(skin)
        ViewMarker.step(camera, true, 1 / 60, { sprinting = false, sliding = false }, 0, nil, 2)
    end
    for _, camo in ipairs(Config.get("camos").order) do
        ViewMarker.setCamo(camo)
        ViewMarker.reactHeadshot()
        ViewMarker.fire()
        ViewMarker.step(camera, true, 1 / 60, { sprinting = false, sliding = false }, 0, nil, 2)
        local marker = camera:FindFirstChild("LocalPaintballMarker")
        assert(marker and #marker:GetDescendants() > 0)
        --[[
            #descendants > 0 is not a shape check. It passes for a viewmodel
            that has quietly doubled, which is the specific hazard the comment
            above rebuildPanels warns about: a layout authored for one side and
            then mirrored lands every panel on top of its own twin. Two coplanar
            faces at identical depth have no stable winner, so the marker
            shimmers -- on the object the player looks at for a whole match, and
            only while the camera moves, which is never in a screenshot.

            Same offset and same size is that failure exactly, so compare the
            placed CFrame rather than trusting the mirroring arithmetic.
        ]]
        local seen: { [string]: string } = {}
        local count = 0
        for _, part in ipairs(marker:GetDescendants()) do
            if part:IsA("BasePart") then
                count += 1
                assert(not part.CanQuery and not part.CanCollide and not part.CanTouch, "viewmodels must never affect shots or collision")
                -- The bot's marker cast a shadow while the bot did not; the
                -- viewmodel is parented to the camera, where a caster is pure
                -- cost for a shadow nobody can be positioned to see.
                assert(not part.CastShadow, `{id}/{camo}: viewmodel part {part.Name} casts a shadow`)
                local at, size = part.CFrame.Position, part.Size
                local key = string.format("%.3f,%.3f,%.3f/%.3f,%.3f,%.3f",
                    at.X, at.Y, at.Z, size.X, size.Y, size.Z)
                assert(seen[key] == nil,
                    `{id}/{camo}: {part.Name} is stacked exactly on {seen[key]} -- these two will z-fight`)
                seen[key] = part.Name
            end
        end
        assert(count <= viewModelPartBudget,
            `{id}/{camo}: {count} viewmodel parts, over the budget of {viewModelPartBudget}`)
    end
    ViewMarker.step(camera, false, 1 / 60, {}, 0, nil, 2)
    assert(not camera:FindFirstChild("LocalPaintballMarker"))
end
print("All marker/skin/camo combinations constructed: no collidable, queryable or shadow-casting geometry, no stacked panels, all inside the part budget")

--------------------------------------------------------------------------------
-- Tracers: the only thing in the game that allocates per shot.
--------------------------------------------------------------------------------

local Tracers = loaded(client.Tracers)
-- The real marker spec, not a hand-made one: Ballistics.step reads fields a
-- stub will not have, and a tracer that flies on invented physics is not the
-- tracer the player sees.
local Ballistics = env.require(env.Shared.Ballistics)
local spec = Ballistics.specFromMarker(
    env.require(env.Data.markers).markers.mechanical,
    env.require(env.Data.ballistics)
)
local function shoot(n: number)
    for _ = 1, n do
        Tracers.fire(roblox.Vector3.zero, roblox.Vector3.new(0, 0, -1), spec)
    end
end

shoot(5)
assert(Tracers.stats().live == 5, "five shots should be five tracers in flight")
assert(Tracers.stats().pooledTracers == 0, "nothing should be pooled while every tracer is flying")

-- Past the three-second life, every tracer retires into the pool rather than
-- being destroyed.
Tracers.step(4)
local retired = Tracers.stats()
assert(retired.live == 0, `tracers should expire, {retired.live} still flying`)
assert(retired.pooledTracers == 5, `expired tracers should be pooled, pool holds {retired.pooledTracers}`)

-- The next five shots must come out of the pool, not out of Instance.new.
shoot(5)
local reused = Tracers.stats()
assert(reused.live == 5 and reused.pooledTracers == 0,
    `pool should have been drained, live {reused.live} pooled {reused.pooledTracers}`)

--[[
    A resolved shot retires the tracer nearest the impact. This used to draw the
    splat and leave the ball flying through whatever the server said it hit.
]]
Tracers.resolve(roblox.Vector3.zero)
assert(Tracers.stats().live == 4, "resolving a shot should retire the tracer that landed it")
Tracers.resolve(roblox.Vector3.new(0, 0, 9999))
assert(Tracers.stats().live == 4, "a distant impact must not retire an unrelated tracer")

-- Splats are capped, so a long burst cannot leave hundreds of parts on a field.
for _ = 1, 300 do
    Tracers.splat(roblox.Vector3.zero)
end
local splats = Tracers.stats().liveSplats
assert(splats <= 120, `splats should be capped at 120, found {splats}`)
print(`Tracer checks passed: pooling, expiry, resolve-retires-its-own, and splats capped at {splats}.`)

Tracers.clear()
local effectCfg = env.require(env.Data.clientEffects)
for _ = 1, effectCfg.splatCap do Tracers.splat(roblox.Vector3.zero) end
Tracers.step(effectCfg.splatSeconds - 1)
Tracers.splat(roblox.Vector3.zero) -- Recycles the oldest still-live part.
Tracers.step(2)
assert(Tracers.stats().liveSplats == 1, "old expiry reclaimed a recycled splat before its new lifetime elapsed")
Tracers.step(effectCfg.splatSeconds)
assert(Tracers.stats().liveSplats == 0, "paint did not expire")
shoot(effectCfg.tracerCap + 10)
assert(Tracers.stats().live == effectCfg.tracerCap, "tracer storm exceeded the hard budget")
assert(trailClears > 0, "recycled trails kept previous flight history")
Tracers.clear()
local pooled = Tracers.stats().pooledTracers
Tracers.clear()
assert(Tracers.stats().pooledTracers == pooled and Tracers.stats().live == 0, "clear duplicated pooled effects")
assert(#clientWorld:FindFirstChild("LiveRoundTracers"):GetChildren() == 0, "cleared effects remained in the scene")
print("Paint recycling lifetime, trail clearing, burst cap and round cleanup passed")
