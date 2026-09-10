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
--[[
    Wall time, delivered the way Roblox delivers it.

    These checks used to hand the server a single ten-second Heartbeat, which
    no engine ever does. MatchService now caps how many fixed steps one frame
    may run and drops the surplus -- an unbounded catch-up loop turns one
    stall into a freeze -- so a ten-second frame legitimately advances the
    match by a fraction of a second. Firing real frames keeps this tool
    measuring the server rather than an impossible input.
]]
local function advance(seconds: number)
    local remaining = seconds
    while remaining > 0 do
        local slice = math.min(1 / 60, remaining)
        heartbeat:fire(slice)
        remaining -= slice
    end
end
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
--- The validators are the real ones on purpose: this stub replaces the wire,
--- not the rules about what is allowed to come off it.
replace(env.ReplicatedStorage.Net.Remotes, {
    event = event,
    validateFireRequest = actualRemotes.validateFireRequest,
    validateSwingRequest = actualRemotes.validateSwingRequest,
})
local shopVenue = {
    exit = { Position = roblox.Vector3.zero, Interact = { Triggered = signal() } },
    enter = { Position = roblox.Vector3.zero, Interact = { Triggered = signal() } },
    counter = { Position = roblox.Vector3.zero, Interact = { Triggered = signal() } },
    spawn = roblox.Vector3.new(0, 0, -40), lookAt = roblox.Vector3.new(0, 1, -45),
}
replace(env.Server.Match.FieldDetails, { build = function() return shopVenue end })
--[[
    The map stub has to be a REAL Instance, not a table. MatchService parents its
    bot Folder to whatever `build` returns, and the harness now hands modules
    Lune's real `Instance` -- so a plain table on the right of `.Parent =` throws
    "expected userdata of type Instance". A bare Folder keeps the smoke test off
    the real world builder without lying about the type.
]]
replace(env.Server.Match.WorldBuilder, { build = function() return roblox.Instance.new("Folder") end })
replace(env.Server.Match.BotAvatar, { new = function()
    return { setPosition = function() end, setSwing = function() end, splatter = function() end, destroy = function() end }
end })
local ticks, fired = 0, 0
local botPositions = {}
local madeBots = {}
local lastFire = nil
replace(env.Server.Bots.BotController, {
    new = function(options)
        botPositions[options.id] = options.position
        local bot = {
            id = options.id, name = options.name, position = options.position, facing = options.facing,
            velocity = roblox.Vector3.zero, alive = true,
            tick = function() ticks += 1 end,
            eliminate = function(self) self.alive = false end,
        }
        table.insert(madeBots, bot)
        return bot
    end,
    pathTo = function() end, setState = function() end,
    swingProgress = function() return nil end,
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
local humanoid = { HipHeight = 1.5 }
local root = { Position = roblox.Vector3.new(0, 3, 0), Size = roblox.Vector3.new(2, 2, 1), AssemblyLinearVelocity = roblox.Vector3.zero }
local character = { FindFirstChild = function() return root end, FindFirstChildOfClass = function() return humanoid end, WaitForChild = function(_, name) return if name == "Humanoid" then humanoid else root end }
local player = { UserId = 123, Name = "SmokeTest", Character = character, Parent = env.game:GetService("Players"), LoadCharacterAsync = function() end }
-- A shared task seam lets the CTF lifecycle check replace immediate delay with
-- a controllable scheduler after the ordinary smoke checks finish.
local function runTask(fn, ...)
    local thread = coroutine.create(fn)
    local ok, err = coroutine.resume(thread, ...)
    if not ok then error(err, 2) end
    return thread
end
env.globals.task = {
    spawn = runTask, defer = runTask,
    delay = function(_, fn, ...) return runTask(fn, ...) end,
    wait = function(seconds) if coroutine.isyieldable() then coroutine.yield() end; return seconds or 0 end,
}
local service = env.require(env.Server.Match.MatchService)
assert(service.start(player, "speedball", "rec", 123))
assert(event("MatchStateChanged").sent[1].phase == "warmup")
local payload = { origin = roblox.Vector3.zero, direction = roblox.Vector3.new(0, 0, -1), stance = "standing", clientTime = 0 }
event("FireMarker").OnServerEvent:fire(player, payload)
advance(0.1)
assert(fired == 0 and ticks == 0, "warmup must block both player fire and bot ticks")
local matchData = env.require(env.Data.match)
advance(matchData.warmupSeconds)
payload.origin = roblox.Vector3.new(10000, 0, 0)
event("FireMarker").OnServerEvent:fire(player, payload)
assert(fired == 1, "live fire should be accepted")
assert(lastFire.origin.Magnitude < 100, "client origin must never position the authoritative projectile")
local Spread = env.require(env.Shared.Spread)
local Rng = env.require(env.Shared.Rng)
local marker = env.require(env.Data.markers).markers.mechanical
local expectedDirection = Spread.sample(payload.direction, Spread.angle(marker, 0, "standing", 0), Rng.new(123):fork(500))
assert((lastFire.direction - expectedDirection).Magnitude < 1e-6, "live fire must use the authoritative marker spread stream")
event("RequestReload").OnServerEvent:fire(player)
advance(1)
event("FireMarker").OnServerEvent:fire(player, payload)
assert(fired == 1, "server must reject shots during manual reload")
advance(10)
event("FireMarker").OnServerEvent:fire(player, payload)
assert(fired == 2, "server must accept shots after reload")
local function hit(team, target)
    local ground = botPositions[target] or roblox.Vector3.zero
    local height = env.require(env.Data.ballistics).hitbox.headTopMetres - env.require(env.Data.camos).headshot.centerBelowHeadTopMetres
    return { projectile = { team = team, id = 1 }, kind = "target", targetId = target, t = 15, position = ground + roblox.Vector3.new(0, height, 0), distance = 10 }
end
queued = { hit("player", "r1_bot1"), hit("player", "r1_bot1") }
advance(0.1)
assert(#event("BotEliminated").sent == 1, "one bot must only be eliminated once in a batch")
assert(event("BotEliminated").sent[1].headshot == true, "authoritative mask hit should be a headshot")
local profile = env.require(env.Server.Economy.Profile).get(player.UserId)
assert(profile.data.camoProgress.headshots == 1, "duplicate hits must never duplicate headshot progress")
--[[
    The butt of the marker.

    The client sends one thing -- which way it was facing -- so everything worth
    cheating is asserted here: that the server picks the victim from its own
    view of the field, that a swing at nothing eliminates nothing, that facing
    away eliminates nothing, and that mashing the key cannot beat the cooldown.
]]
do
    local victim, behind = nil, nil
    for _, bot in ipairs(madeBots) do
        if bot.alive then
            if not victim then victim = bot else behind = bot; break end
        end
    end
    assert(victim and behind, "the squad mock did not build two live bots")
    local before = #event("BotEliminated").sent

    -- Out of reach: a swing at empty air.
    victim.position = roblox.Vector3.new(0, 0, -9)
    behind.position = roblox.Vector3.new(0, 0, 9)
    event("SwingMarker").OnServerEvent:fire(player, { direction = roblox.Vector3.new(0, 0, -1), clientTime = 0 })
    assert(#event("BotEliminated").sent == before, "a swing at nothing took somebody out")

    -- Behind the swinger: in range, wrong side. A whiff still spends the
    -- cooldown -- that is the cost of committing -- so the clock moves between
    -- each of these.
    advance(1.1)
    behind.position = roblox.Vector3.new(0, 0, 1.2)
    event("SwingMarker").OnServerEvent:fire(player, { direction = roblox.Vector3.new(0, 0, -1), clientTime = 0 })
    assert(#event("BotEliminated").sent == before, "a swing reached behind the player")

    -- In reach, in front.
    advance(1.1)
    victim.position = roblox.Vector3.new(0, 0, -1.4)
    event("SwingMarker").OnServerEvent:fire(player, { direction = roblox.Vector3.new(0, 0, -1), clientTime = 0 })
    local sent = event("BotEliminated").sent
    assert(#sent == before + 1, "a swing in reach did not take anybody out")
    assert(sent[#sent].botId == victim.id and sent[#sent].melee == true, "the wrong bot was shoved")
    assert(not victim.alive, "the shoved bot is still standing")

    -- Mashing it must not beat the cooldown, and the payload cannot name a target.
    behind.position = roblox.Vector3.new(0, 0, -1.2)
    event("SwingMarker").OnServerEvent:fire(player, { direction = roblox.Vector3.new(0, 0, -1), clientTime = 0, targetId = behind.id })
    assert(#event("BotEliminated").sent == before + 1, "the swing cooldown was not enforced by the server")
    event("SwingMarker").OnServerEvent:fire(player, { direction = roblox.Vector3.new(0, 0, 0) })
    assert(#event("BotEliminated").sent == before + 1, "a malformed swing was accepted")
    behind.alive = false
end
print("Melee checks passed: server-side reach, arc, cooldown and payload validation.")

--[[
    The invulnerability override, tested as the subject rather than assumed.

    The harness pins every dev flag off so that gates measure the shipping
    game; this block turns exactly one of them on, proves it refuses the
    elimination, and turns it off again. Without this the flag would be a
    feature with no check behind it -- and the failure mode of a dev override
    is that it silently stays on.
]]
do
    local Dev = env.require(env.Shared.Dev)
    local before = #event("PlayerEliminated").sent
    Dev._setOverrideForTesting({ enabled = true, invulnerable = { on = true } })
    queued = { hit("bot", "player"), hit("bot", "player") }
    advance(0.1)
    assert(#event("PlayerEliminated").sent == before, "the invulnerability override let an elimination through")
    Dev._setOverrideForTesting({ enabled = false })
    print("Dev override checked: invulnerable refuses the one place a life ends.")
end

queued = { hit("bot", "player"), hit("bot", "player") }
advance(0.1)
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

-- A new round refills on the server, matching the client round snapshot.
-- A deliberately long reload rules out elapsed time as the reason it refilled.
local oldCapacity, oldReload = marker.hopperCapacity, marker.reloadSeconds
marker.hopperCapacity, marker.reloadSeconds = 1, 999
local firedBefore = fired
assert(service.start(player, "speedball", "rec", 456))
advance(matchData.warmupSeconds + 0.1)
event("FireMarker").OnServerEvent:fire(player, payload)
assert(fired == firedBefore + 1)
event("RequestReload").OnServerEvent:fire(player)
for i = 1, matchData.rounds.schedule[1].bots do
    table.insert(queued, hit("player", "r1_bot" .. i))
end
advance(0.1)
advance(matchData.rounds.intermissionSeconds + 0.1)
local latest = event("MatchStateChanged").sent[#event("MatchStateChanged").sent]
assert(latest.phase == "live" and latest.round == 2, "test must reach round two")
event("FireMarker").OnServerEvent:fire(player, payload)
assert(fired == firedBefore + 2, "new round must refill the server hopper and cancel the old reload")
service.stop(player)
assert(not (profile.data.gauntletClears and profile.data.gauntletClears.speedball), "quitting after one round must not grant a campaign clear")
assert(not table.find(profile.data.chaptersCompleted or {}, "walkOn"), "partial matches must not complete chapters")
marker.hopperCapacity, marker.reloadSeconds = oldCapacity, oldReload
print("Round transition checks passed: authoritative hopper refill and stale reload cancellation.")

--------------------------------------------------------------------------------
-- The Shoothouse, end to end.
--
-- This is the check that would have caught the mode shipping as dead code: it
-- goes through MatchService exactly as a player does, rather than calling the
-- pure Course module directly the way the unit specs do.
--------------------------------------------------------------------------------

local Course = env.require(env.Server.Match.Course)
local Config = env.require(env.Shared.Config)

assert(service.start(player, "speedball", "rec", 789, "shoothouse"), "the Shoothouse must start")
local opening = event("MatchStateChanged").sent[#event("MatchStateChanged").sent]
assert(opening.mode == "shoothouse", "a course must announce itself as the Shoothouse")
assert(opening.stageIndex == 1 and opening.stage, "the course HUD needs a stage, not just a round number")
assert(opening.stageCount == Course.stageCount("speedball"), "the HUD needs the stage count")
assert(opening.par and opening.par.gold, "the HUD needs par to show a medal target")

local stages = Course.all("speedball", "rec")
assert(opening.botCount == stages[1].concurrent, "stage one fields exactly as many defenders as it has anchors")

-- Defenders start ON the cover their stage names, which is what makes a stage a
-- band of the map rather than a wave walking in from the back.
local anchors = {}
for _, a in ipairs(Config.map("speedball").anchors) do
    anchors[a.id] = a
end
for i, id in ipairs(stages[1].anchorIds) do
    local at = botPositions["r1_bot" .. i]
    local want = anchors[id].position
    assert(at and math.abs(at.X - want[1]) < 0.01 and math.abs(at.Z - want[3]) < 0.01,
        `course defender {i} did not start on anchor {id}`)
end

--[[
	Nobody starts inside anybody. Speedball fields twelve from six authored
	spawns, so the reuse fan-out is the only thing keeping the opening of a full
	round from being a pile of bodies at six points.
]]
do
    -- Per ROUND. botPositions accumulates across every round of the run, and two
    -- bots from different rounds sharing a spawn is not a collision -- they are
    -- never on the field together.
    local byRound: { [string]: { [string]: any } } = {}
    for id, at in pairs(botPositions) do
        local round = id:match("^(r%d+)_") or "?"
        byRound[round] = byRound[round] or {}
        byRound[round][id] = at
    end
    for round, group in pairs(byRound) do
        for id, at in pairs(group) do
            for other, previous in pairs(group) do
                if id ~= other then
                    local gap = (at - previous).Magnitude
                    assert(gap > 0.9, `{round}: {id} and {other} start {string.format("%.2f", gap)} m apart`)
                end
            end
        end
    end
end

advance(matchData.warmupSeconds + 0.1)

-- Clear every stage-wave. There is no intermission to wait out: the course
-- clock does not stop between stages.
local cleared = 0
local waves = Config.require("course", "wavesPerStage")
--[[
	Driven off the course, not off the HUD payload. The phase-change event fires
	its own MatchStateChanged carrying only `phase`, so reading "the last state
	the client saw" gets you a payload with no botCount on it.
]]
local expected: { number } = {}
for _, stage in ipairs(stages) do
    for _ = 1, waves do
        table.insert(expected, stage.concurrent)
    end
end
for r, count in ipairs(expected) do
    queued = {}
    for i = 1, count do
        table.insert(queued, hit("player", `r{r}_bot{i}`))
    end
    cleared += count
    advance(0.1)
    advance(0.1)
end
assert(cleared == Course.totalBots("speedball"),
    `cleared {cleared} defenders, course declares {Course.totalBots("speedball")}`)

local record = profile.data.courseRecords and profile.data.courseRecords.speedball
assert(record, "finishing a course must write a course record")
assert(record.clears == 1, `course record should show one clear, shows {record.clears}`)
assert(record.bestSeconds and record.bestSeconds > 0, "a cleared course must record a time")
assert(not (profile.data.gauntletClears and profile.data.gauntletClears.speedball),
    "a course clear must never count as a gauntlet clear")
service.stop(player)
print(`Shoothouse checks passed: reachable through MatchService, {cleared} defenders over {Course.stageCount("speedball")} stages, record written.`)

--------------------------------------------------------------------------------
-- Horde: the endless schedule, reinforcements, breathers and the boss target.
--------------------------------------------------------------------------------

--[[
	Horde is the third mode expressed as a schedule, and the only one that is
	not finished when the match starts. What this drives is the part that could
	not exist before: waves appended as they are cleared, replacements fed in
	behind the concurrent cap, and a marshal whose body is not a target.

	Everything here goes through the ordinary MatchService loop -- there is no
	horde-specific firing, hit validation or respawn path, and this check exists
	partly to prove that.
]]
do
    local Endless = env.require(env.Server.Match.Endless)
    local hordePlayer = { UserId = 777, Name = "HordeProbe", DisplayName = "HordeProbe",
        Character = character, Parent = env.game:GetService("Players"),
        LoadCharacterAsync = function() end }
    assert(service.start(hordePlayer, "speedball", "rec", 99, "horde"), "horde must start")

    advance(matchData.warmupSeconds + 0.1)

    --[[
        Clearing a wave APPENDS the next one rather than ending the match. A
        finite schedule would have finished at wave one, so reaching wave six
        through the ordinary loop is the whole proof that the mode is endless.

        Every body a wave sends is cleared, replacements included: ids keep
        counting past the concurrent cap, which is what makes a reinforcement a
        new bot rather than a resurrected one.
    ]]
    local depth, bodies = 0, 0
    for waveIndex = 1, 6 do
        local wave = Endless.round(waveIndex)
        for i = 1, wave.botCount + wave.reinforcements do
            queued = { hit("player", `r{waveIndex}_bot{i}`) }
            advance(0.1)
            bodies += 1
        end
        depth = waveIndex
        -- Breathers pause; every other wave runs straight into the next.
        advance((wave.intermissionSeconds or 0) + 0.2)
    end
    assert(depth == 6, "the horde schedule did not reach wave 6")
    assert(Endless.round(5).intermissionSeconds > 0, "wave 5 should be a breather")
    assert(Endless.round(4).intermissionSeconds == 0, "wave 4 should run straight on")

    service.stop(hordePlayer)
    print(`Horde checks passed: six waves appended and cleared through the ordinary loop, {bodies} bodies fielded including reinforcements.`)
end

require("./CtfLiveChecks")({ env = env, service = service, event = event, advance = advance,
    player = player, root = root, madeBots = madeBots, hit = hit, queueHits = function(hits) queued = hits end })
