--!strict
--[[
	Audio -- one-shot sound effects, pooled.

	Every cue this game can make is named in Data/audio.json and every one of
	them is already called from the right moment below the client. What the data
	does NOT carry is asset ids: audio belongs to whoever uploaded it, and
	hardcoding somebody else's id ships a build that is either silent or
	moderated out from under you. So a cue with no id is a no-op, deliberately
	and quietly, and filling one in is the only step between here and sound.
	Data/overworld.json already handles the hub's ambience beds the same way.

	Pooled for the same reason the tracers are: a full-auto marker asks for a
	one-shot several times a second, and `Instance.new("Sound")` per shot is the
	allocation pattern this project has already had to remove once. Sounds are
	reclaimed when they finish rather than destroyed, and the pool is capped, so
	audio cannot become the thing that costs the frame.

	Nothing here decides anything. A cue is feedback for a decision the server
	has already made.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Config = require(ReplicatedStorage.Shared.Config)
local Rng = require(ReplicatedStorage.Shared.Rng)

local Audio = {}

local folder: Folder? = nil
local pool: { Sound } = {}
--- Voices currently out, with when they were handed out. Not a counter: see
--- the sweep in `reclaim`.
local active: { [Sound]: number } = {}
local rng = Rng.new(7717)

--- Longest a one-shot may hold a voice before it is taken back.
local MAX_VOICE_SECONDS = 8

local function container(): Folder
	if folder and folder.Parent then
		return folder :: Folder
	end
	local created = Instance.new("Folder")
	created.Name = "LiveRoundAudio"
	created.Parent = SoundService
	folder = created
	return created
end

--[[
	Takes back voices that have finished, and any that never will.

	`Ended` is the normal path, but it is not a guarantee: the ids in this
	project come from whoever is filling in Data/audio.json, and a Sound whose
	asset fails to load -- a wrong id, a deleted asset, audio that is not public
	and not yours -- may never fire it. A pure counter would then drift upward
	until it hit the concurrency cap and the game went permanently silent, with
	no error anywhere. So the pool is swept instead of trusted: a voice that has
	stopped, or has been out longer than any one-shot in a paintball game could
	possibly be, comes back.
]]
local function reclaim()
	local now = os.clock()
	for voice, startedAt in pairs(active) do
		if not voice.IsPlaying or now - startedAt > MAX_VOICE_SECONDS then
			active[voice] = nil
			table.insert(pool, voice)
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

--[[
	Plays a named cue.

	Unknown names and empty ids are both silent no-ops rather than errors: a cue
	nobody has supplied an id for is the normal state of this file, and a typo
	at a call site should not take down the frame that fired the marker.
]]
function Audio.play(name: string)
	local cfg = Config.get("audio")
	local cue = cfg.cues[name]
	if cue == nil or cue.soundId == nil or cue.soundId == "" then
		return
	end
	reclaim()
	if liveCount() >= cfg.maxConcurrent then
		return
	end

	local sound = table.remove(pool)
	if sound == nil then
		sound = Instance.new("Sound")
		;(sound :: Sound).Parent = container()
	end
	local voice = sound :: Sound
	voice.SoundId = cue.soundId
	voice.Volume = cue.volume
	--- Two shots that are bit-identical read as a loop, not as a marker.
	local variance = cue.pitchVariance or 0
	voice.PlaybackSpeed = 1 + (rng:nextNumber() * 2 - 1) * variance
	active[voice] = os.clock()
	voice:Play()
end

--- Drops every pooled voice. Called when a match ends, so a rebuilt client is
--- not holding sounds parented to a folder it no longer owns.
function Audio.clear()
	if folder then
		(folder :: Folder):Destroy()
		folder = nil
	end
	table.clear(pool)
	table.clear(active)
end

return Audio
