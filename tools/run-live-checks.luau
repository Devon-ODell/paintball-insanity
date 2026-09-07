--!strict
-- Exercises the real MatchService with mocked engine and projectile boundaries.
local Harness = require("./Harness")
local roblox = require("@lune/roblox")
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
            OnServerEvent = signal(), sent = {},
            FireClient = function(self, _, payload) table.insert(self.sent, payload) end,
        }
    end
    return events[name]
end
replace(env.ReplicatedStorage.Net.Remotes, { event = event, validateFireRequest = actualRemotes.validateFireRequest })
local shopVenue = {
    exit = { Position = roblox.Vector3.zero, Interact = { Triggered = signal() } },
    enter = { Position = roblox.Vector3.zero, Interact = { Triggered = signal() } },
    counter = { Position = roblox.Vector3.zero, Interact = { Triggered = signal() } },
    spawn = roblox.Vector3.new(0, 0, -40), lookAt = roblox.Vector3.new(0, 1, -45),
}
replace(env.Server.Match.FieldDetails, { build = function() return shopVenue end })
replace(env.Server.Match.WorldBuilder, { build = function() return { Destroy = function() end } end })
replace(env.Server.Match.BotAvatar, { new = function() return { setPosition = function() end, splatter = function() end, destroy = function() end } end })
local ticks, fired = 0, 0
local botPositions = {}
local lastFire = nil
replace(env.Server.Bots.BotController, {
    new = function(options)
        botPositions[options.id] = options.position
        return {
            id = options.id, name = options.name, position = options.position, facing = options.facing,
            velocity = roblox.Vector3.zero, alive = true,
            tick = function() ticks += 1 end,
            eliminate = function(self) self.alive = false end,
        }
    end,
    pathTo = function() end, setState = function() end,
    asTarget = function(bot) return { id = bot.id, alive = bot.alive } end,
})
local queued = {}
replace(env.Server.Ballistics.ProjectileSim, { new = function()
    return {
        fire = function(_, params) fired += 1; lastFire = params end,
        clear = function() end,
        step = function() local result = queued; queued = {}; return result end,
    }
end })
replace(env.Server.Ballistics.LagCompensation, { new = function()
    return { originIsPlausible = function() return false end, capture = function() end }
end })
env.globals.Instance = { new = function() return {} end }
local humanoid = { HipHeight = 1.5 }
local root = { Position = roblox.Vector3.new(0, 3, 0), Size = roblox.Vector3.new(2, 2, 1), AssemblyLinearVelocity = roblox.Vector3.zero }
local character = { FindFirstChild = function() return root end, FindFirstChildOfClass = function() return humanoid end, WaitForChild = function(_, name) return if name == "Humanoid" then humanoid else root end }
local player = { UserId = 123, Name = "SmokeTest", Character = character, Parent = env.game:GetService("Players"), LoadCharacterAsync = function() end }
local service = env.require(env.Server.Match.MatchService)
assert(service.start(player, "speedball", "rec", 123))
assert(event("MatchStateChanged").sent[1].phase == "warmup")
local payload = { origin = roblox.Vector3.zero, direction = roblox.Vector3.new(0, 0, -1), stance = "standing", clientTime = 0 }
event("FireMarker").OnServerEvent:fire(player, payload)
heartbeat:fire(0.1)
assert(fired == 0 and ticks == 0, "warmup must block both player fire and bot ticks")
local matchData = env.require(env.Data.match)
heartbeat:fire(matchData.warmupSeconds)
payload.origin = roblox.Vector3.new(10000, 0, 0)
event("FireMarker").OnServerEvent:fire(player, payload)
assert(fired == 1, "live fire should be accepted")
assert(lastFire.origin.Magnitude < 100, "client origin must never position the authoritative projectile")
event("RequestReload").OnServerEvent:fire(player)
heartbeat:fire(1)
event("FireMarker").OnServerEvent:fire(player, payload)
assert(fired == 1, "server must reject shots during manual reload")
heartbeat:fire(10)
event("FireMarker").OnServerEvent:fire(player, payload)
assert(fired == 2, "server must accept shots after reload")
local function hit(team, target)
    local ground = botPositions[target] or roblox.Vector3.zero
    local height = env.require(env.Data.ballistics).hitbox.headTopMetres - env.require(env.Data.camos).headshot.centerBelowHeadTopMetres
    return { projectile = { team = team, id = 1 }, kind = "target", targetId = target, t = 15, position = ground + roblox.Vector3.new(0, height, 0), distance = 10 }
end
queued = { hit("player", "r1_bot1"), hit("player", "r1_bot1") }
heartbeat:fire(0.1)
assert(#event("BotEliminated").sent == 1, "one bot must only be eliminated once in a batch")
assert(event("BotEliminated").sent[1].headshot == true, "authoritative mask hit should be a headshot")
local profile = env.require(env.Server.Economy.Profile).get(player.UserId)
assert(profile.data.camoProgress.headshots == 1, "duplicate hits must never duplicate headshot progress")
queued = { hit("bot", "player"), hit("bot", "player") }
heartbeat:fire(0.1)
assert(#event("PlayerEliminated").sent == 1, "one batch must only charge one player elimination")
print("Live MatchService checks passed: warmup, reload, duplicate bot hits, duplicate player hits (mock engine boundaries).")

assert(not service.canShop(player), "cannot purchase while a match is live")
assert(service.visitShop(player), "can leave the field for the safe area")
assert(not service.isActive(player), "leaving must stop combat")
assert(event("MatchStateChanged").sent[#event("MatchStateChanged").sent].phase == "shop")
root.Position = shopVenue.counter.Position
assert(service.canShop(player), "can shop at the counter between rounds")
assert(service.shopData(player).catalogue.markers, "shop provides server catalogue")
root.Position = roblox.Vector3.new(1000, 0, 0)
assert(not service.canShop(player), "cannot purchase remotely from outside the counter")
print("Shop flow checks passed: exit, combat stopped, counter proximity and catalogue.")
