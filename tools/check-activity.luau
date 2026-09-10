--!nolint
--[[
	Drives the real Bootstrap against a controllable scheduler.

	    lune run tools/check-activity

	Every other gate in this project exercises a service in isolation with the
	engine mocked around it. That is valuable and it is not sufficient, because
	the Range's and the hub's worst failures were not inside any one service --
	they were at the boundaries between Bootstrap, MatchService, RangeService and
	the hub, where three partial guards each covered a different subset of "is
	the world busy" and none of them covered the gaps:

	  - a per-player `starting` flag that `startDrill` never set,
	  - `MatchService.currentHost()`, over ACTIVE matches only,
	  - `RangeService.isActive`, over that one player.

	So this loads `Bootstrap.server.luau` itself, with a scheduler whose delays
	fire when this file says so, character loads that yield when this file says
	so, and signal connections that actually disconnect. Then it asks the
	questions a manual playtest cannot: who owns the world, what is parented
	where, how many listeners are attached, and where does a second player end up.
]]
local roblox = require("@lune/roblox")
local Harness = require("./Harness")
local env = Harness.build()

local V3 = roblox.Vector3

--------------------------------------------------------------------------------
-- A scheduler this file drives
--------------------------------------------------------------------------------

--[[
	`task.delay` queues instead of running inline.

	The stock harness runs a delayed function immediately, which is the opposite
	of what the interesting cases need: the two-and-a-half-second return after a
	match, and a request arriving DURING that window, only exist as bugs because
	of the gap in between.
]]
local pending: { { at: number, fn: any, args: any } } = {}
local clock = 0

local function advance(seconds: number)
	clock += seconds
	local due = {}
	local kept = {}
	for _, entry in ipairs(pending) do
		if entry.at <= clock then table.insert(due, entry) else table.insert(kept, entry) end
	end
	pending = kept
	table.sort(due, function(a, b) return a.at < b.at end)
	for _, entry in ipairs(due) do
		local thread = coroutine.create(entry.fn)
		local ok, err = coroutine.resume(thread, table.unpack(entry.args, 1, entry.args.n))
		if not ok then error(err) end
	end
end

--[[
	`task.wait` suspends its own thread and is resumed by `advance`.

	The stock harness's wait yields whatever thread happens to be running, which
	on this gate is the gate itself: Bootstrap's CharacterAdded handler waits
	0.2 s before deciding where a player belongs, and that handler runs
	synchronously from a character load, which runs from a join. A wait that
	stops the file cannot be used to test what happens DURING the wait, which is
	the whole reason the routing bug survived.
]]
env.globals.task = {
	wait = function(n)
		local thread = coroutine.running()
		if not coroutine.isyieldable() then return n or 0 end
		table.insert(pending, {
			at = clock + (n or 0),
			fn = function() coroutine.resume(thread) end,
			args = table.pack(),
		})
		coroutine.yield()
		return n or 0
	end,
	spawn = function(fn, ...)
		local thread = coroutine.create(fn)
		local ok, err = coroutine.resume(thread, ...)
		if not ok then error(err) end
		return thread
	end,
	defer = function(fn, ...)
		local thread = coroutine.create(fn)
		local ok, err = coroutine.resume(thread, ...)
		if not ok then error(err) end
		return thread
	end,
	delay = function(seconds, fn, ...)
		table.insert(pending, { at = clock + (seconds or 0), fn = fn, args = table.pack(...) })
		return nil
	end,
}

--------------------------------------------------------------------------------
-- Signals that really disconnect
--------------------------------------------------------------------------------

--[[
	`run-live-checks` uses signal mocks whose Disconnect is a no-op, which is
	fine for the questions it asks and useless for "did teardown actually let
	go". A listener that survives its own drill is one of the failures being
	checked here, so the count has to be real.
]]
local function signal()
	local listeners = {}
	local self
	self = {
		listeners = listeners,
		count = function() 
			local n = 0
			for _ in pairs(listeners) do n += 1 end
			return n
		end,
		Connect = function(_, fn)
			local key = {}
			listeners[key] = fn
			return {
				Disconnect = function() listeners[key] = nil end,
				Connected = true,
			}
		end,
		--[[
			Each listener on its own thread, as the engine does.

			A handler that yields -- Bootstrap's CharacterAdded waits 0.2 s --
			must not suspend whatever fired the signal. Errors are re-raised
			rather than swallowed: a gate that quietly loses a callback failure
			is worse than no gate.
		]]
		fire = function(_, ...)
			local args = table.pack(...)
			for _, listener in pairs(listeners) do
				local thread = coroutine.create(listener)
				local ok, err = coroutine.resume(thread, table.unpack(args, 1, args.n))
				if not ok then error(err, 0) end
			end
		end,
	}
	return self
end

local heartbeat = signal()
local runService = env.game:GetService("RunService")
runService.Heartbeat = heartbeat
runService.IsStudio = function() return true end

--------------------------------------------------------------------------------
-- Remotes, captured
--------------------------------------------------------------------------------

local function replace(node, value)
	node._loaded, node._result = true, value
end

local actualRemotes = env.require(env.ReplicatedStorage.Net.Remotes)
local events, fns = {}, {}
local function event(name)
	if not events[name] then
		events[name] = {
			OnServerEvent = signal(),
			sent = {},
			FireClient = function(self, player, payload)
				table.insert(self.sent, { player = player, payload = payload })
			end,
			FireAllClients = function(self, payload)
				table.insert(self.sent, { player = nil, payload = payload })
			end,
		}
	end
	return events[name]
end
local function fn(name)
	if not fns[name] then fns[name] = { OnServerInvoke = nil } end
	return fns[name]
end
local function resetSent()
	for _, e in pairs(events) do e.sent = {} end
end
--- Every payload this player was sent on `name`, newest last.
local function sentTo(name, player)
	local out = {}
	for _, entry in ipairs(event(name).sent) do
		if entry.player == player then table.insert(out, entry.payload) end
	end
	return out
end
local function lastTo(name, player)
	local all = sentTo(name, player)
	return all[#all]
end

replace(env.ReplicatedStorage.Net.Remotes, {
	init = function() end,
	event = event,
	fn = fn,
	validateFireRequest = actualRemotes.validateFireRequest,
})

--------------------------------------------------------------------------------
-- Players, with character loads this file controls
--------------------------------------------------------------------------------

local Players = env.game:GetService("Players")
local roster = {}
local playerAdded = signal()
local playerRemoving = signal()
Players.PlayerAdded = playerAdded
Players.PlayerRemoving = playerRemoving
Players.GetPlayers = function() return roster end
Players.GetPlayerByUserId = function(_, id)
	for _, p in ipairs(roster) do if p.UserId == id then return p end end
	return nil
end

--[[
	When `LoadCharacterAsync` returns is a parameter, not a constant.

	Bootstrap's CharacterAdded handler waits 0.2 s and then decides where the
	player belongs; RangeService and MatchService both load a character inside
	their own start path. The ordering between those is exactly where the routing
	bug lived, so this gate has to be able to put a request in the middle of one.
]]
local function newPlayer(userId: number, name: string)
	local added = signal()
	local removing = signal()
	local player
	player = {
		UserId = userId,
		Name = name,
		DisplayName = name,
		Parent = Players,
		Character = nil,
		CharacterAdded = added,
		CharacterRemoving = removing,
		--- Set to true to make a load fail the way a real one can.
		failLoad = false,
		Kick = function(_, reason) player.kicked = reason end,
	}
	local function build()
		if player.failLoad then error("character load failed") end
		--[[
			A table character, not a real Model.

			Lune's Instance is backed by the real property database and refuses
			an overridden `FindFirstChild`, which is how every service on the
			server locates a root part. The root part itself IS a real Part,
			because the services write a CFrame to it and this gate wants those
			writes to be the real thing.
		]]
		local hrp = roblox.Instance.new("Part")
		hrp.Name = "HumanoidRootPart"
		hrp.Size = V3.new(2, 2, 1)
		local character = { Name = name }
		--[[
			A table Humanoid, not a real one.

			Lune's Humanoid is backed by the real property database and refuses
			an assignment to `Died`, which the recovery path has to be able to
			fire. Nothing here reads a humanoid for anything but HipHeight and
			that signal.
		]]
		local died = signal()
		local humanoid = {
			Health = 100,
			HipHeight = 1.5,
			ClassName = "Humanoid",
			Died = died,
			IsA = function(_, className) return className == "Humanoid" end,
		}
		player.died = died
		player.humanoid = humanoid
		character.FindFirstChild = function(_, childName)
			if childName == "HumanoidRootPart" then return hrp end
			return nil
		end
		character.FindFirstChildOfClass = function(_, className)
			if className == "Humanoid" then return humanoid end
			return nil
		end
		character.WaitForChild = function(_, childName)
			if childName == "Humanoid" then return humanoid end
			return hrp
		end
		local previous = player.Character
		if previous then removing:fire(previous) end
		player.Character = character
		player.root = hrp
		added:fire(character)
		return character
	end
	player.LoadCharacter = build
	player.LoadCharacterAsync = build
	--- Drops the character without loading a new one: the native reset button,
	--- or walking off the edge of the world.
	player.loseCharacter = function()
		local previous = player.Character
		player.Character = nil
		if previous then removing:fire(previous) end
	end
	return player
end

local function join(player)
	table.insert(roster, player)
	playerAdded:fire(player)
end
local function leave(player)
	for index, entry in ipairs(roster) do
		if entry == player then table.remove(roster, index) break end
	end
	player.Parent = nil
	playerRemoving:fire(player)
end

--------------------------------------------------------------------------------
-- Boundaries the harness cannot supply
--------------------------------------------------------------------------------

local stage = roblox.Instance.new("Folder")
stage.Name = "Origin"

--[[
	A map build is a Folder, as in run-live-checks.

	The question here is not what a map looks like -- five other gates cover
	that -- it is WHERE IT IS PARENTED and WHEN IT IS DESTROYED. A named Folder
	answers that exactly and builds in microseconds.
]]
local builtMaps = {}
replace(env.Server.Match.WorldBuilder, {
	--- Parented into the observed origin, because WHERE the field is and when
	--- it stops being there is the entire question this gate asks.
	build = function(_name, parent, _data)
		local folder = roblox.Instance.new("Folder")
		folder.Name = "MapRoot"
		folder.Parent = stage
		table.insert(builtMaps, folder)
		return folder
	end,
	materialFor = function() return roblox.Enum.Material.LeafyGrass end,
})

--- The supply venue at the edge of a field, stubbed the same way
--- `run-live-checks` stubs it: this gate asks when it is DISPOSED of, not what
--- it looks like.
local shopVenue = {
	exit = { Position = V3.zero, Interact = { Triggered = signal() } },
	enter = { Position = V3.zero, Interact = { Triggered = signal() } },
	counter = { Position = V3.zero, Interact = { Triggered = signal() } },
	spawn = V3.new(0, 0, -40), lookAt = V3.new(0, 1, -45),
}
replace(env.Server.Match.FieldDetails, { build = function() return shopVenue end })
replace(env.Server.Match.BotAvatar, { new = function()
	return { setPosition = function() end, setSwing = function() end, splatter = function() end, destroy = function() end }
end })

--[[
	The marketplace, inert.

	Bootstrap binds commerce on the way up, and commerce connects to a real
	purchase signal. Nothing here buys anything -- the free launch is checked in
	Commerce.spec -- but the signal has to exist for the server to finish
	starting, which is the whole point of driving the real Bootstrap.
]]
local marketplace = env.game:GetService("MarketplaceService")
marketplace.PromptGamePassPurchaseFinished = signal()
marketplace.PromptProductPurchaseFinished = signal()
marketplace.UserOwnsGamePassAsync = function() return false end
marketplace.GetProductInfoAsync = function() return { IsForSale = false } end
local policy = env.game:GetService("PolicyService")
policy.GetPolicyInfoForPlayerAsync = function() return { ArePaidRandomItemsRestricted = true } end

--- What is standing at the origin right now, by name.
local function standing()
	local out = {}
	for _, child in ipairs(stage:GetChildren()) do
		out[child.Name] = (out[child.Name] or 0) + 1
	end
	return out
end
local function totalStanding()
	return #stage:GetChildren()
end

--------------------------------------------------------------------------------

print("check-activity  who owns the world at the origin")

local Activity = env.require(env.Server.World.Activity)
local MatchService = env.require(env.Server.Match.MatchService)
local RangeService = env.require(env.Server.Range.RangeService)
local Hub = env.require(env.Server.World.Hub)
local Profile = env.require(env.Server.Economy.Profile)

RangeService.worldParent = stage

--[[
	The hub, stubbed to a folder at the origin.

	Building the real Landing takes seconds and check-demo-world already proves
	it constructs. What this gate needs from the hub is the one property that
	made it dangerous: it occupies the SAME origin every scene is built at, and
	park/restore are global rather than per player.
]]
local hubModel = roblox.Instance.new("Folder")
hubModel.Name = "TheLanding"
hubModel.Parent = stage
local hubOpen = true
local placements = {}
replace(env.Server.World.Hub, {
	build = function() end,
	park = function()
		hubOpen = false
		hubModel.Parent = nil
	end,
	restore = function()
		hubOpen = true
		hubModel.Parent = stage
	end,
	isOpen = function() return hubOpen end,
	placePlayer = function(player, at, keepResults)
		hubOpen = true
		hubModel.Parent = stage
		table.insert(placements, { player = player, at = at, keepResults = keepResults })
		event("MatchStateChanged"):FireClient(player, {
			phase = "hub", map = "landing", keepResults = keepResults == true,
		})
	end,
	gateReturnPosition = function() return V3.new(1, 0, 1) end,
	refreshBoard = function() end,
	refreshPersonal = function() end,
	forgetPersonal = function() end,
	allowedCategories = function() return {} end,
	onGateEntered = nil,
	onCourseEntered = nil,
	onNpcTalk = nil,
	onBayOpened = nil,
	profileFor = nil,
})
--- Bootstrap assigns the callbacks above; read them back off the same table.
local hub = env.require(env.Server.World.Hub)

env.require(env.Server.Bootstrap)
assert(fn("RequestMatchStart").OnServerInvoke, "Bootstrap did not bind RequestMatchStart")
assert(fn("RequestRangeDrill").OnServerInvoke, "Bootstrap did not bind RequestRangeDrill")

local function requestMatch(player, payload)
	return fn("RequestMatchStart").OnServerInvoke(player, payload)
end
local function requestDrill(player, drillId)
	return fn("RequestRangeDrill").OnServerInvoke(player, drillId)
end

local alice = newPlayer(101, "Alice")
local bob = newPlayer(102, "Bob")

--------------------------------------------------------------------------------
-- Joining puts you in the hub, and only when the hub is yours to be in
--------------------------------------------------------------------------------

join(alice)
advance(1)
assert(#placements > 0 and placements[#placements].player == alice,
	"a joining player must be put in The Landing")
assert(hubOpen, "The Landing must be standing for a player who is only standing in it")
assert(Activity.kindFor(alice) == nil, "standing in the hub is not an activity")
print("  join            Alice is in The Landing, nothing owns the origin")

-- The session snapshot must recover equipment even when the join-time event
-- reached the client before it subscribed.
do
 local handle = Profile.load(alice.UserId)
 handle.data.loadout.pods = "sixPack"
 local snapshot = fn("RequestSessionState").OnServerInvoke(alice)
 assert(snapshot.kit and snapshot.kit.podCount == 6, "session snapshot lost the equipped pod budget")
 handle.data.loadout.pods = "twoPack"
end

-- Died does not imply Player.Character is nil. Retain the old model exactly
-- as the engine can with CharacterAutoLoads disabled.
do
 local old = alice.Character
 alice.humanoid.Health = 0
 alice.died:fire()
 advance(10)
 assert(alice.Character ~= old, "a dead but still assigned character must be replaced")
 advance(1)
end


--------------------------------------------------------------------------------
-- A drill takes the lease, and the hub comes down
--------------------------------------------------------------------------------

resetSent()
placements = {}
local drill = requestDrill(alice, "popup")
assert(drill.ok, `a drill must start: {tostring(drill.reason)}`)
assert(Activity.kindFor(alice) == "range", "a running drill must own the origin")
assert(not hubOpen, "The Landing must be parked while a drill is on the origin")
assert(RangeService.isActive(alice), "the drill must be running")

--[[
	`startDrill` never set `starting`, so Bootstrap's CharacterAdded handler
	checked only `MatchService.isActive` -- false during a drill -- and called
	`Hub.placePlayer`, which RESTORES THE ENTIRE HUB and sends phase='hub'.
	A drill could be overwritten by the very character load that started it.
]]
placements = {}
alice.CharacterAdded:fire(alice.Character)
advance(1)
assert(#placements == 0,
	"a character load during a drill must not be routed to the hub -- that restores The Landing on top of the firing line")
assert(not hubOpen, "The Landing came back during a drill")
print("  drill           owns the origin; a character load does not restore the hub")

--------------------------------------------------------------------------------
-- The second seat
--------------------------------------------------------------------------------

resetSent()
placements = {}
join(bob)
advance(1)
--[[
	Bob joining during Alice's drill used to restore the whole hub -- at the same
	origin, on top of her range. He is told to wait instead.
]]
assert(#placements == 0,
	"a second player joining during someone's activity must not restore The Landing on top of it")
assert(not hubOpen, "a joining player restored The Landing into a running drill")
local told = lastTo("MatchStateChanged", bob)
assert(told and told.notice and string.find(told.notice, "Alice"),
	"the second player must be TOLD why they are waiting, not silently left nowhere")
print("  second seat     Bob is told Alice has the field, and does not restore it")

--[[
	`startDrill` checked activity for THAT PLAYER only, so Bob could open the
	Range during Alice's -- two ranges at the same origin, both consuming the
	same FireMarker events.
]]
local bobDrill = requestDrill(bob, "popup")
assert(not bobDrill.ok, "a second player must not start a drill on someone else's origin")
local bobMatch = requestMatch(bob, { map = "speedball", tier = "rec" })
assert(not bobMatch.ok, "a second player must not start a match on someone else's origin")
assert(Activity.kindFor(alice) == "range", "Alice must still own the origin")
assert(RangeService.isActive(alice), "Alice's drill must have survived Bob's attempts")
print("  contention      Bob cannot start a drill or a match while Alice owns the origin")

--------------------------------------------------------------------------------
-- A match cannot start on top of the same player's drill
--------------------------------------------------------------------------------

local fireListeners = event("FireMarker").OnServerEvent.count()
assert(fireListeners > 0, "the drill must be listening for fire")
local aliceMatch = requestMatch(alice, { map = "speedball", tier = "rec" })
assert(aliceMatch.ok, `Alice's own match must take over from her own drill: {tostring(aliceMatch.reason)}`)
assert(not RangeService.isActive(alice),
	"starting a match must stop that player's drill -- both loops consume FireMarker and both build at the origin")
assert(Activity.kindFor(alice) == "match", "the match must own the origin now")
assert(totalStanding() >= 1, "the match must have built something")
assert(standing()["TheLanding"] == nil, "The Landing must be parked during a match")
print("  handover        Alice's match stops her own drill and takes the lease")

-- An asynchronously resolved entitlement must not manufacture a hub phase.
do
 local SeasonPass = env.require(env.Server.Progression.SeasonPass)
 local Commerce = env.require(env.Server.Economy.Commerce)
 local original = SeasonPass.grantDue
 SeasonPass.grantDue = function() return { { id = "testReward" } } end
 local before = #sentTo("MatchStateChanged", alice)
 Commerce.onPassResolved(alice)
 SeasonPass.grantDue = original
 assert(#sentTo("MatchStateChanged", alice) == before, "season rewards changed the live activity phase")
 assert(lastTo("Notice", alice).text ~= nil, "season rewards need visible feedback")
end


--------------------------------------------------------------------------------
-- Finishing: the field comes DOWN before The Landing goes back up
--------------------------------------------------------------------------------

resetSent()
placements = {}
MatchService.stop(alice)
assert(not MatchService.isActive(alice), "the match must be over")
--[[
	`finish` clears the active match but deliberately keeps the venue so the
	player can spend what they earned at the supply counter. The MAP ROOT was
	kept too, and nothing ever destroyed it -- Bootstrap restored The Landing at
	the same origin 2.5 s later, on top of it. Old geometry went away only when
	that same player started another match or left the server.
]]
advance(3)
assert(#placements > 0, "the player must be walked back to The Landing")
assert(MatchService.hasVenue(alice) == false,
	"the field must be disposed of before The Landing is restored, not left standing under it")
assert(standing()["MapRoot"] == nil,
	`a map root is still at the origin with The Landing restored on top of it`)
assert(hubOpen and standing()["TheLanding"] == 1, "The Landing must be back, exactly once")
assert(Activity.kindFor(alice) == nil, "the origin must be free once the player is home")
print("  return          the field is taken down BEFORE The Landing comes back")

--[[
	The results panel survives the walk home. Bootstrap returns the player 2.5 s
	after the summary arrives, and the client hides the summary whenever it
	enters `hub` -- so the six fundamental scores, the diagnosis and the payout
	breakdown were destroyed two and a half seconds after appearing.
]]
local home = lastTo("MatchStateChanged", alice)
assert(home and home.keepResults == true,
	"returning from a match must tell the client to KEEP the results panel")
print("  results         the report survives the return to The Landing")

--------------------------------------------------------------------------------
-- Bob gets the world once Alice is out of it
--------------------------------------------------------------------------------

local bobNow = requestMatch(bob, { map = "speedball", tier = "rec" })
assert(bobNow.ok, `Bob must get the field once it is free: {tostring(bobNow.reason)}`)
assert(Activity.kindFor(bob) == "match", "Bob must own the origin")
assert(standing()["MapRoot"] == 1,
	`exactly one field may stand at the origin, found {tostring(standing()["MapRoot"])}`)
MatchService.stop(bob)
advance(3)
assert(standing()["MapRoot"] == nil, "Bob's field must come down too")
print("  succession      Bob plays, and exactly one field stands at a time")

--------------------------------------------------------------------------------
-- Duplicate requests during the load, and a load that fails
--------------------------------------------------------------------------------

resetSent()
local first = requestMatch(alice, { map = "speedball", tier = "rec" })
assert(first.ok, "the first request must be honoured")
local duplicate = requestMatch(alice, { map = "speedball", tier = "rec" })
assert(duplicate.ok ~= nil, "a duplicate request must answer, not throw")
assert(standing()["MapRoot"] == 1,
	`a duplicate request built a second field: {tostring(standing()["MapRoot"])}`)
MatchService.stop(alice)
advance(3)

alice.failLoad = true
local failed = requestMatch(alice, { map = "speedball", tier = "rec" })
alice.failLoad = false
assert(not failed.ok, "a match whose character load fails must report failure")
--[[
	A half-built match must leave nothing behind. Releasing the lease runs the
	teardown registered at allocation time, so the field comes down before The
	Landing goes back up rather than being restored on top of it.
]]
assert(standing()["MapRoot"] == nil,
	"a failed start left a field standing at the origin")
assert(Activity.isHeld() == false, "a failed start must release the origin")
assert(hubOpen, "a failed start must leave the player somewhere to stand")
print("  failure         a start that fails leaves no field and no lease behind")

--------------------------------------------------------------------------------
-- A stale return callback must not move anybody
--------------------------------------------------------------------------------

resetSent()
placements = {}
local one = requestMatch(alice, { map = "speedball", tier = "rec" })
assert(one.ok, "the match must start")
MatchService.stop(alice)
--- Inside the 2.5 s return window, Alice starts something else.
local two = requestMatch(alice, { map = "speedball", tier = "rec" })
assert(two.ok, "starting again inside the return window must be allowed")
placements = {}
advance(5)
--[[
	The first match's delayed return is now stale. It used to be guarded by a
	token incremented at the TOP of requestMatch -- before the request was
	validated -- so a REJECTED replay invalidated a pending return, and an
	ACCEPTED one could still let a stale callback fire against the new match.
	Identity, not a counter.
]]
assert(standing()["MapRoot"] ~= nil or #placements == 0,
	"a stale return callback pulled the player out of the match they had just started")
MatchService.stop(alice)
advance(3)
print("  stale callback  a superseded return does not disturb the activity that replaced it")

--------------------------------------------------------------------------------
-- Reset, and falling out of the world
--------------------------------------------------------------------------------

resetSent()
--- In the hub: Players.CharacterAutoLoads is off, so nothing reloads a
--- character on its own and a reset used to leave the player with none at all.
assert(alice.Character ~= nil, "Alice must have a character to lose")
alice.loseCharacter()
assert(alice.Character == nil, "the character is gone")
advance(10)
assert(alice.Character ~= nil,
	"a character lost in the hub must be replaced -- CharacterAutoLoads is off and nothing else will")
print("  reset in hub    a lost character comes back")

--- On the firing line: the Range has nothing that shoots back, so it had no
--- respawn path at all and the drill went on presenting targets to nobody.
local onLine = requestDrill(alice, "popup")
assert(onLine.ok, "the drill must start")
alice.loseCharacter()
advance(10)
assert(alice.Character ~= nil, "a character lost during a drill must be put back on the line")
assert(RangeService.isActive(alice), "the drill must still be running")
RangeService.stop(alice)
advance(3)
print("  reset on range  the drill survives and the player is put back on the line")

--------------------------------------------------------------------------------
-- Disconnecting releases everything
--------------------------------------------------------------------------------

resetSent()
local last = requestMatch(alice, { map = "speedball", tier = "rec" })
assert(last.ok, "the match must start")
assert(Activity.kindFor(alice) == "match", "Alice owns the origin")
leave(alice)
assert(Activity.isHeld() == false, "a disconnect must release the origin")
assert(not MatchService.isActive(alice), "a disconnect must stop the match")
assert(standing()["MapRoot"] == nil, "a disconnect must take the field down")
print("  disconnect      the origin is released and the field is taken down")

--- And Bob, who has been waiting the whole time, can have it.
local bobFinally = requestMatch(bob, { map = "speedball", tier = "rec" })
assert(bobFinally.ok, `Bob must get the field after Alice leaves: {tostring(bobFinally.reason)}`)
MatchService.stop(bob)
advance(3)

--------------------------------------------------------------------------------
-- Nothing was left listening
--------------------------------------------------------------------------------

--[[
	Real Disconnect, really counted.

	The Range installed its fire, reload and aim listeners BEFORE registering the
	session that owned them, so a character load that failed in between left
	three live listeners answering for a drill that no longer existed -- and
	`RangeService.stop` had no session to unwind them from.
]]
leave(bob)
advance(5)
local leftListening = event("FireMarker").OnServerEvent.count()
assert(leftListening == 0,
	`{leftListening} fire listener(s) survived every activity ending -- teardown is not unwinding what it allocated`)
assert(event("RequestReload").OnServerEvent.count() == 0, "reload listeners survived teardown")
assert(event("ReportAim").OnServerEvent.count() == 0, "aim listeners survived teardown")
assert(totalStanding() <= 1, `{totalStanding()} things are standing at the origin with nobody playing`)
print("  teardown        no listener and no scene outlived the activity that made it")

print("Activity checks passed: one owner of the origin, across every transition.")
