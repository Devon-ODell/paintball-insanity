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
local wrap
wrap = function(raw)
	if wrappers[raw] then return wrappers[raw] end
	local events = {}
	local proxy = setmetatable({}, {
		__index = function(_, key)
			if key == "_raw" then return raw end
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
			return raw[key]
		end,
		__newindex = function(_, key, value) raw[key] = if key == "Parent" and value then value._raw else value end,
	})
	wrappers[raw] = proxy
	return proxy
end
local Instance = { new = function(class) return wrap(roblox.Instance.new(class)) end }
local playerGui = Instance.new("Folder")
local players = { LocalPlayer = { WaitForChild = function() return playerGui end, CharacterAdded = signal() } }
local input = { InputBegan = signal(), InputEnded = signal(), WindowFocusReleased = signal() }
local actions = {}
local contextActions = { BindAction = function(_, name, callback) actions[name] = callback end }
local shared = env.ReplicatedStorage.Shared
local client = {}
for _, name in ipairs({ "UiTheme", "Hud", "ShopUi", "DialogueUi", "ViewMarker", "Input" }) do client[name] = { name = name, Parent = client } end
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
		task = { delay = function() end }, workspace = {} }
	local result = luau.load(fs.readFile(root .. "/src/StarterPlayer/Client/" .. target.name .. ".luau"), { environment = globals, injectGlobals = true })()
	cache[target.name] = result
	return result
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
Hud.setCurrency(99999999)
Hud.setDeaths(2, 0.63)
Hud.flashHit(true)
Hud.setCamoProgress({ headshots = 12, nextUnlock = { displayName = "Tide Shift", requiredHeadshots = 35 }, unlockedCamos = { "citrusCircuit" } })
Hud.showChatter({ speaker = "Crew", text = "See you on the field." })
Hud.showSummary({ cleared = true, map = "speedball", marker = "mechanical", eliminations = 20, deaths = 1, headshots = 5, hitRate = 0.5, scores = {}, prescription = { line = "Track your target through the turn.", drill = "tracking" } }, { total = 420, deathPenalty = 0.8, roundsCleared = 5, roundsPlayed = 5 }, function() return { ok = true } end, function() return { ok = true } end)
print("HUD construction / combat / summary methods passed against Roblox property database")
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
print("Input modal and focus-loss checks passed")

local ViewMarker = loaded(client.ViewMarker)
local camera = Instance.new("Camera")
for _, id in ipairs(Config.get("markers").order) do
    ViewMarker.equip(id, "factory")
    for _, skin in ipairs({ "raw", "duracoat", "splitDust" }) do
        ViewMarker.setSkin(skin)
        ViewMarker.step(camera, true)
    end
    for _, camo in ipairs(Config.get("camos").order) do
        ViewMarker.setCamo(camo)
        ViewMarker.reactHeadshot()
        ViewMarker.fire()
        ViewMarker.step(camera, true)
        local marker = camera:FindFirstChild("LocalPaintballMarker")
        assert(marker and #marker:GetDescendants() > 0)
        for _, part in ipairs(marker:GetDescendants()) do
            if part:IsA("BasePart") then
                assert(not part.CanQuery and not part.CanCollide and not part.CanTouch, "viewmodels must never affect shots or collision")
            end
        end
    end
    ViewMarker.step(camera, false)
    assert(not camera:FindFirstChild("LocalPaintballMarker"))
end
print("All marker/skin/camo combinations constructed and reacted without collidable or queryable geometry")
