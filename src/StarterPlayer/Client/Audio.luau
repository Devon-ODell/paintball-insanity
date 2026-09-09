--!strict
--[[
	Audio -- one-shot sound effects, pooled, on the current audio API.

	Built on `AudioPlayer` -> `Wire` -> `AudioDeviceOutput`, which is what
	Roblox documents today; `Sound` and `SoundGroup` are discouraged. Nothing
	routes implicitly in this API: an AudioPlayer with no Wire to anything is
	silent and reports no error, which is the easiest way there is to spend an
	afternoon on audio that was never connected. So the wire is built with the
	voice, in one place, and every voice keeps its own.

	These cues are 2D on purpose. A hit confirmation, a dry fire and a reload
	are things the marker in your hands did; they do not come from a location in
	the world and should not get quieter when you turn your head. The hub's
	ambience beds are the positional ones, and they still use the legacy object
	-- see docs/PLATFORM_NOTES.md.

	Pooled for the same reason the tracers are: a full-auto marker asks for a
	one-shot several times a second, and an instance per shot is the allocation
	pattern this project has already had to remove once.

	Nothing here decides anything. A cue is feedback for a decision the server
	has already made.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Config = require(ReplicatedStorage.Shared.Config)
local Rng = require(ReplicatedStorage.Shared.Rng)

local Audio = {}

export type Voice = {
	player: AudioPlayer,
	wire: Wire,
}

local folder: Folder? = nil
local output: AudioDeviceOutput? = nil
local pool: { Voice } = {}
--- Voices currently out, with when they were handed out and how long their cue
--- is expected to run. Not a counter: see the sweep in `reclaim`.
local active: { [AudioPlayer]: { voice: Voice, startedAt: number, lengthSeconds: number } } = {}
local rng = Rng.new(7717)

--- Longest a one-shot may hold a voice before it is taken back. Nothing in a
--- paintball game is a one-shot for eight seconds.
local MAX_VOICE_SECONDS = 8

local function container(): Folder
	if folder and folder.Parent then
		return folder :: Folder
	end
	local created = Instance.new("Folder")
	created.Name = "LiveRoundAudio"
	created.Parent = SoundService
	folder = created
	output = nil
	return created
end

--- The speakers. One per client, reused by every voice.
local function device(): AudioDeviceOutput
	local existing = output
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("AudioDeviceOutput")
	created.Name = "Output"
	created.Parent = container()
	output = created
	return created
end

--[[
	Takes back voices whose cue has had time to finish.

	Reclaimed by the clock rather than by `Ended` or `IsPlaying`, and that is a
	deliberate choice rather than a workaround. An asset that fails to load --
	a wrong id, a deleted asset, or audio that is private and not yours, all of
	which this file invites by asking somebody to paste ids in -- may never fire
	`Ended` at all. Anything waiting on that event would leak voices until it hit
	the concurrency cap and the game went permanently silent, with no error
	anywhere to explain it.

	So each cue declares `lengthSeconds`, and a voice comes back when that has
	elapsed. It is a hint for pooling only: reclaiming a voice does not stop it,
	and a cue whose hint is short simply gets reused sooner. MAX_VOICE_SECONDS is
	the backstop for a hint somebody sets absurdly high.
]]
local function reclaim(now: number)
	for voice, entry in pairs(active) do
		if now - entry.startedAt >= math.min(entry.lengthSeconds, MAX_VOICE_SECONDS) then
			active[voice] = nil
			table.insert(pool, entry.voice)
		end
	end
end

local function liveCount(): number
	local count = 0
	for _ in pairs(active) do
		count += 1
	end
	return count
end

local function build(): Voice
	local reused = table.remove(pool)
	if reused then
		return reused
	end
	local parent = container()
	local voice = Instance.new("AudioPlayer")
	voice.Parent = parent
	--- The wire is the whole difference between audible and silent, so it is
	--- created here with its player and never separately.
	local wire = Instance.new("Wire")
	wire.SourceInstance = voice
	wire.TargetInstance = device()
	wire.Parent = voice
	return { player = voice, wire = wire }
end

--[[
	Plays a named cue.

	Unknown names and empty ids are both silent no-ops rather than errors. A cue
	nobody has supplied an id for is the normal state of this file, and a typo at
	a call site should not take down the frame that fired the marker --
	`check-client-ui` is what catches the typo, at build time, where it belongs.
]]
function Audio.play(name: string)
	local cfg = Config.get("audio")
	local cue = cfg.cues[name]
	if cue == nil or cue.soundId == nil or cue.soundId == "" then
		return
	end
	local now = os.clock()
	reclaim(now)
	if liveCount() >= cfg.maxConcurrent then
		return
	end

	local voice = build()
	local sound = voice.player
	sound.Asset = cue.soundId
	sound.Volume = cue.volume * cfg.sfxVolume
	--- Two shots that are bit-identical read as a loop, not as a marker.
	local variance = cue.pitchVariance or 0
	sound.PlaybackSpeed = 1 + (rng:nextNumber() * 2 - 1) * variance
	active[sound] = { voice = voice, startedAt = now, lengthSeconds = cue.lengthSeconds }
	sound:Play()
end

--- Drops every voice and the device with them. Called when a match ends, so a
--- rebuilt client is not holding players parented to a folder it no longer owns.
function Audio.clear()
	if folder then
		(folder :: Folder):Destroy()
		folder = nil
	end
	output = nil
	table.clear(pool)
	table.clear(active)
end

return Audio
