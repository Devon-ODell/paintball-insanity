--!strict
--[[
	Music -- one track at a time, crossfaded, never in the way.

	Two rules shape this, and both are about a game whose whole subject is
	hearing where somebody is.

	First, music ducks. A paintball match is an audio-information game: the
	marker's report, the squad's chatter and the direction a hit came from are
	all things the player is being asked to read. Music that competes with those
	is not atmosphere, it is a handicap. So a match track sits well under the
	hub track's level, and `Music.duck` pulls it down further while something
	louder is happening.

	Second, it crossfades rather than cutting. Rounds change every couple of
	minutes and a hard cut on every one of them would be the most irritating
	thing in the build.

	Built on `AudioPlayer` -> `Wire` -> `AudioDeviceOutput`, like `Audio`. Music
	is not positional; it should not get quieter when the player turns around.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Config = require(ReplicatedStorage.Shared.Config)
local Rng = require(ReplicatedStorage.Shared.Rng)

local Music = {}

type Deck = {
	player: AudioPlayer,
	wire: Wire,
	--- Where this deck's volume is heading, before ducking.
	target: number,
	current: number,
	track: string?,
}

local folder: Folder? = nil
local output: AudioDeviceOutput? = nil
local decks: { Deck } = {}
local playing = 1
local context: string? = nil
local duckUntil = -math.huge
local rng = Rng.new(4402)

local function settings(): any
	return Config.get("audio").music
end

local function build()
	if folder and folder.Parent then
		return
	end
	local created = Instance.new("Folder")
	created.Name = "LiveRoundMusic"
	created.Parent = SoundService
	folder = created

	local device = Instance.new("AudioDeviceOutput")
	device.Name = "Output"
	device.Parent = created
	output = device

	--[[
		Two decks, so a crossfade is a crossfade.

		One player cannot fade out of itself into something else -- the outgoing
		track has to keep playing while the incoming one comes up, or the
		"crossfade" is a gap with a ramp on each side.
	]]
	table.clear(decks)
	for index = 1, 2 do
		local voice = Instance.new("AudioPlayer")
		voice.Name = `Deck{index}`
		voice.Looping = true
		voice.Volume = 0
		voice.Parent = created
		local wire = Instance.new("Wire")
		wire.SourceInstance = voice
		wire.TargetInstance = device
		wire.Parent = voice
		table.insert(decks, { player = voice, wire = wire, target = 0, current = 0, track = nil })
	end
	playing = 1
end

--- The track list for a context, or an empty list for one nobody authored.
local function playlistFor(name: string): { string }
	local cfg = settings()
	local list = cfg.playlists[name]
	if type(list) ~= "table" then
		return {}
	end
	local usable: { string } = {}
	for _, id in ipairs(list) do
		if type(id) == "string" and id ~= "" then
			table.insert(usable, id)
		end
	end
	return usable
end

--[[
	Advances the crossfade. Driven from the client's presentation loop rather
	than a connection of its own: this project already has one per-frame place
	for client presentation, and a module that quietly opens a second one is a
	module whose teardown nobody can see.
]]
function Music.step(dt: number)
	local cfg = settings()
	local now = os.clock()
	--- Ducked while combat is louder than the music has any business being.
	local duck = if now < duckUntil then cfg.duckMultiplier else 1
	for _, deck in ipairs(decks) do
		local target = deck.target * duck * cfg.volume
		if math.abs(deck.current - target) > 1e-4 then
			--- Frame-rate independent, so a 30 Hz machine fades in the same
			--- wall time as a 144 Hz one.
			deck.current += (target - deck.current) * (1 - math.exp(-cfg.fadeSpeed * dt))
			deck.player.Volume = deck.current
		end
		if deck.current < 1e-3 and deck.target == 0 and deck.track ~= nil then
			deck.player:Stop()
			deck.track = nil
		end
	end
end

--[[
	Switches to a context's playlist: "hub", "match", "results".

	Idempotent. Being asked for the context already playing is the common case --
	every round change re-announces the phase -- and restarting the track there
	would make the music stutter once a round for no reason.
]]
function Music.setContext(name: string?)
	if name == context then
		return
	end
	context = name

	build()
	local outgoing = decks[playing]
	outgoing.target = 0

	local list = if name then playlistFor(name :: string) else {}
	if #list == 0 then
		-- No ids supplied for this context, which is the shipped state today.
		-- The outgoing deck still fades rather than cutting.
		return
	end

	playing = if playing == 1 then 2 else 1
	local incoming = decks[playing]
	local pick = list[rng:nextInt(1, #list)]
	incoming.player.Asset = pick
	incoming.track = pick
	incoming.player.Volume = 0
	incoming.current = 0
	incoming.target = settings().contextVolume[name] or 1
	incoming.player:Play()

end

--- Pulls the music down for a moment. Called where the game is saying something
--- with sound that matters more than the track does.
function Music.duck(seconds: number?)
	duckUntil = os.clock() + (seconds or settings().duckSeconds)
end

--- Stops everything and drops the graph.
function Music.clear()
	context = nil
	if folder then
		(folder :: Folder):Destroy()
		folder = nil
	end
	output = nil
	table.clear(decks)
	duckUntil = -math.huge
end

return Music
