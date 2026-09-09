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
local Units = require(ReplicatedStorage.Shared.Units)
local AudioMix = require(script.Parent.AudioMix)

local Audio = {}

export type Voice = {
	player: AudioPlayer,
	wire: Wire,
	--- Present only on positional voices: the part the emitter rides on.
	anchor: BasePart?,
	emitter: AudioEmitter?,
}

local folder: Folder? = nil
--- Separate pools: a positional voice carries an anchor part and an emitter,
--- and handing one out for a 2D cue would leave a silent part in the world.
local pool: { Voice } = {}
local spatialPool: { Voice } = {}
--- Voices currently out, with when they were handed out and how long their cue
--- is expected to run. Not a counter: see the sweep in `reclaim`.
local active: { [AudioPlayer]: { voice: Voice, startedAt: number, lengthSeconds: number, spatial: boolean } } = {}
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
			table.insert(if entry.spatial then spatialPool else pool, entry.voice)
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

local function connect(source: Instance, target: Instance): Wire
	--- The wire is the whole difference between audible and silent, so it is
	--- created with its player and never separately.
	local link = Instance.new("Wire")
	link.SourceInstance = source
	link.TargetInstance = target
	link.Parent = source
	return link
end

--- A flat 2D voice: straight into the effects bus, no position, no attenuation.
local function build(): Voice
	local reused = table.remove(pool)
	if reused then
		return reused
	end
	local voice = Instance.new("AudioPlayer")
	voice.Parent = container()
	return { player = voice, wire = connect(voice, AudioMix.sfxBus()) }
end

--[[
	A positional voice: player -> emitter, riding an anchored part.

	The emitter takes its position from its parent, so each of these carries its
	own invisible part which is moved to wherever the cue happened. The part is
	non-collidable, non-queryable and casts no shadow -- it is an ear-target, not
	an object in the world, and a projectile that could hit a speaker would be a
	very hard bug to find.

	Attenuation comes from Data/audio.json in METRES, like every other distance
	a designer reads in this project, and is converted once here. The engine
	wants a distance-to-volume curve; the shape of that curve is what decides
	whether a marker forty metres away is information or noise.
]]
local function buildSpatial(): Voice
	local reused = table.remove(spatialPool)
	if reused then
		return reused
	end
	local anchor = Instance.new("Part")
	anchor.Name = "AudioAnchor"
	anchor.Size = Vector3.one
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide, anchor.CanQuery, anchor.CanTouch, anchor.CastShadow = false, false, false, false
	anchor.Parent = container()

	local emitter = Instance.new("AudioEmitter")
	emitter.Parent = anchor

	local voice = Instance.new("AudioPlayer")
	voice.Parent = anchor
	return { player = voice, wire = connect(voice, emitter), anchor = anchor, emitter = emitter }
end

--[[
	Plays a named cue.

	Unknown names and empty ids are both silent no-ops rather than errors. A cue
	nobody has supplied an id for is the normal state of this file, and a typo at
	a call site should not take down the frame that fired the marker --
	`check-client-ui` is what catches the typo, at build time, where it belongs.
]]
local function start(name: string, at: Vector3?)
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

	local voice = if at then buildSpatial() else build()
	if at and voice.anchor and voice.emitter then
		(voice.anchor :: BasePart).Position = Units.vectorToStuds(at :: Vector3)
		--[[
			The curve is set per play, not once per emitter, because how far a
			cue carries is a design decision per cue rather than a property of
			the speaker. A voice does not carry as far as a marker's report
			does, and that difference is the whole reason squad chatter can be
			a directional tell without turning into a permanent map of where
			everyone is standing.
		]]
		local curve: { [number]: number } = {}
		local scale = cue.rangeScale or 1
		for metres, volume in pairs(cfg.spatial.attenuation) do
			curve[Units.metresToStuds((tonumber(metres) :: number) * scale)] = volume
		end
		(voice.emitter :: AudioEmitter):SetDistanceAttenuation(curve)
	end
	local sound = voice.player
	sound.Asset = cue.soundId
	sound.Volume = cue.volume
	--- Two shots that are bit-identical read as a loop, not as a marker.
	local variance = cue.pitchVariance or 0
	sound.PlaybackSpeed = 1 + (rng:nextNumber() * 2 - 1) * variance
	active[sound] = { voice = voice, startedAt = now, lengthSeconds = cue.lengthSeconds, spatial = at ~= nil }
	sound:Play()
end

--[[
	Plays a named cue flat, with no position.

	For things the player's own hands did -- their marker, their reload, their
	hit confirmation. Those do not come from a place in the world and should not
	get quieter when the player turns their head.
]]
function Audio.play(name: string)
	start(name, nil)
end

--[[
	Plays a named cue at a point in the world, in metres.

	This is the one that matters for how the game plays. A squad you cannot
	hear is a squad you can only find by looking, and "which direction did that
	come from" is the question this entire game is built around asking. Enemy
	fire, paint landing and a bot going down all happen somewhere, and the
	listener on the camera is what turns that into a direction.
]]
function Audio.playAt(name: string, at: Vector3)
	start(name, at)
end

--- Drops every voice and the device with them. Called when a match ends, so a
--- rebuilt client is not holding players parented to a folder it no longer owns.
function Audio.clear()
	if folder then
		(folder :: Folder):Destroy()
		folder = nil
	end
	table.clear(pool)
	table.clear(spatialPool)
	table.clear(active)
end

return Audio
