--!strict
--[[
	AudioMix -- the mixing desk. One output, two buses, one listener.

	Everything audible in this game passes through here, which is the point: a
	game with sound scattered across modules has no way to say "music down,
	effects up" without touching all of them, and no single place to look when
	something is inaudible.

	    2D one-shots ─────────────┐
	                              ├─► sfx fader ──┐
	    3D emitters ─► listener ──┘               ├─► device output
	                                              │
	    music decks ─────────────► music fader ───┘

	Two things about this API are worth knowing before changing any of it.

	Nothing routes implicitly. An `AudioPlayer` with no `Wire` to something
	downstream is silent and reports no error at all, and so is an
	`AudioEmitter` with no `AudioListener` in the world to hear it. Every
	silent-by-default link in that diagram is built here, in one function, so
	there is one place to check rather than five.

	And the listener is the ear. It lives on the camera, so 3D audio is heard
	from where the player is LOOKING rather than where their feet are -- which
	matters in a game whose whole subject is working out which direction a shot
	came from. It has to follow the camera when the camera is replaced, which
	Roblox does on respawn, so `AudioMix.follow` is called every frame and does
	nothing on the frames where nothing changed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Config = require(ReplicatedStorage.Shared.Config)

local AudioMix = {}

local folder: Folder? = nil
local output: AudioDeviceOutput? = nil
local sfx: AudioFader? = nil
local music: AudioFader? = nil
local listener: AudioListener? = nil
local listenerParent: Instance? = nil

--- Connects a source to a target. The single most forgettable line in this API.
local function wire(source: Instance, target: Instance, parent: Instance)
	local link = Instance.new("Wire")
	link.SourceInstance = source
	link.TargetInstance = target
	link.Parent = parent
	return link
end

local function fader(name: string, volume: number, device: AudioDeviceOutput, parent: Instance): AudioFader
	local bus = Instance.new("AudioFader")
	bus.Name = name
	bus.Volume = volume
	bus.Parent = parent
	wire(bus, device, bus)
	return bus
end

local function build()
	if folder and folder.Parent then
		return
	end
	local created = Instance.new("Folder")
	created.Name = "LiveRoundMix"
	created.Parent = SoundService
	folder = created

	local device = Instance.new("AudioDeviceOutput")
	device.Name = "Output"
	device.Parent = created
	output = device

	local mix = Config.get("audio").mix
	sfx = fader("SfxBus", mix.sfx, device, created)
	music = fader("MusicBus", mix.music, device, created)
	listener, listenerParent = nil, nil
end

function AudioMix.sfxBus(): AudioFader
	build()
	return sfx :: AudioFader
end

function AudioMix.musicBus(): AudioFader
	build()
	return music :: AudioFader
end

--[[
	Puts the ear on the current camera.

	Called every frame from the presentation loop and cheap on the frames where
	the camera has not changed -- which is all of them except a respawn, when
	Roblox replaces the camera and a listener left on the old one goes wherever
	the old camera went. A game that quietly stops being able to hear where it
	is being shot from after one death is exactly the kind of bug that gets
	blamed on the map.
]]
function AudioMix.follow(camera: Camera)
	build()
	if listenerParent == camera and listener and listener.Parent == camera then
		return
	end
	if listener then
		(listener :: AudioListener):Destroy()
	end
	local ear = Instance.new("AudioListener")
	ear.Name = "Ear"
	ear.Parent = camera
	wire(ear, sfx :: AudioFader, ear)
	listener, listenerParent = ear, camera
end

--- Bus volume, 0 to 1. The music bus is also what ducking moves.
function AudioMix.setVolume(bus: string, volume: number)
	build()
	local target = if bus == "music" then music else sfx
	if target then
		(target :: AudioFader).Volume = math.clamp(volume, 0, 1)
	end
end

function AudioMix.clear()
	if listener then
		(listener :: AudioListener):Destroy()
	end
	if folder then
		(folder :: Folder):Destroy()
	end
	folder, output, sfx, music, listener, listenerParent = nil, nil, nil, nil, nil, nil
end

return AudioMix
