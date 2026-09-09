--!nolint
--[[
	Audio wiring gate.

	    lune run tools/check-audio

	Sound is the one system in this project that fails SILENTLY in every
	direction. A malformed id does not throw. A cue nobody plays makes no noise
	and neither does a cue played under a name that does not exist. An asset
	whose privacy forbids it plays perfectly in Studio and then is quiet in a
	published place. There is no error anywhere in any of that, which is exactly
	why it needs a gate rather than a playtest.

	So:

	  1  every id is either null or a well-formed rbxassetid:// string
	  2  volumes and pitch variances are inside sane ranges
	  3  every music context named by the client has a playlist
	  -  how much is still silent, reported and never failed

	Rule 1 is the one that will actually catch something. Pasting a bare number
	-- `"1234567890"` instead of `"rbxassetid://1234567890"` -- is the most
	likely mistake anybody will make with this file, and its symptom is silence
	that looks exactly like not having filled the cue in at all.

	Rule 4 is a report because silence is the SHIPPED state: this project
	supplies no audio ids, deliberately, and being noisy about that on every run
	would train everyone to ignore this gate.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local audio = serde.decode("json", fs.readFile("Data/audio.json"))

local problems: { string } = {}
local function fail(message: string)
	table.insert(problems, message)
end

--- null is "not supplied yet". Anything else has to be the full string, because
--- a bare number is accepted by the property and plays nothing.
local function checkId(where: string, id: any)
	if id == nil then
		return
	end
	if type(id) ~= "string" then
		fail(`{where}: id is a {type(id)}, expected a string or null`)
		return
	end
	if id == "" then
		fail(`{where}: empty string -- use null for "not supplied yet"`)
		return
	end
	local digits = string.match(id, "^rbxassetid://(%d+)$")
	if not digits then
		if string.match(id, "^%d+$") then
			fail(`{where}: '{id}' is a bare number. It must be 'rbxassetid://{id}' or it plays nothing, silently.`)
		else
			fail(`{where}: '{id}' is not a well-formed 'rbxassetid://<digits>' id`)
		end
	end
end

local function checkRange(where: string, value: any, low: number, high: number)
	if type(value) ~= "number" or value ~= value then
		fail(`{where}: expected a number, got {tostring(value)}`)
	elseif value < low or value > high then
		fail(`{where}: {value} is outside {low}..{high}`)
	end
end

--------------------------------------------------------------------------------
-- Cues
--------------------------------------------------------------------------------

local cueCount, cueSilent = 0, 0
for name, cue in pairs(audio.cues) do
	cueCount += 1
	checkId(`cues.{name}`, cue.soundId)
	checkRange(`cues.{name}.volume`, cue.volume, 0, 1)
	checkRange(`cues.{name}.pitchVariance`, cue.pitchVariance, 0, 0.5)
	--- The pooling hint. Zero would hand a voice back on the frame it started.
	checkRange(`cues.{name}.lengthSeconds`, cue.lengthSeconds, 0.05, 30)
	if type(cue.spatial) ~= "boolean" then
		fail(`cues.{name}.spatial must be true or false -- a cue has to say whether it happens somewhere`)
	elseif cue.spatial then
		--- How far this particular sound carries, as a multiple of the shared
		--- curve. A cue that happens somewhere has to say how far away it can
		--- still be heard, or every world sound carries exactly as far as
		--- gunfire and chatter becomes a map of the squad.
		checkRange(`cues.{name}.rangeScale`, cue.rangeScale, 0.05, 2)
	elseif cue.rangeScale ~= nil then
		fail(`cues.{name} is not spatial, so rangeScale does nothing -- remove it or set spatial`)
	end
	if cue.soundId == nil then
		cueSilent += 1
	end
end
checkRange("mix.sfx", audio.mix.sfx, 0, 1)
checkRange("mix.music", audio.mix.music, 0, 1)

--[[
	The distance curve, which is a gameplay decision rather than a polish one.

	It decides whether a marker forty metres away is information the player can
	act on or noise they learn to tune out. Three things have to hold or it
	stops being either: it must start audible at zero, it must never rise as
	distance grows, and it must reach silence -- a curve that bottoms out above
	zero means every shot on the field is permanently in your ears.
]]
do
	local distances: { number } = {}
	for key in pairs(audio.spatial.attenuation) do
		local metres = tonumber(key)
		if metres == nil then
			fail(`spatial.attenuation has a non-numeric distance '{key}'`)
		else
			table.insert(distances, metres)
		end
	end
	table.sort(distances)
	if #distances < 2 then
		fail("spatial.attenuation needs at least a near and a far point")
	else
		if distances[1] ~= 0 then
			fail(`spatial.attenuation starts at {distances[1]} m, not 0 -- nothing defines the volume up close`)
		end
		local previous = math.huge
		for _, metres in ipairs(distances) do
			local volume = audio.spatial.attenuation[tostring(metres)]
			checkRange(`spatial.attenuation[{metres}]`, volume, 0, 1)
			if type(volume) == "number" then
				if volume > previous then
					fail(`spatial.attenuation gets LOUDER with distance at {metres} m`)
				end
				previous = volume
			end
		end
		if previous ~= 0 then
			fail(`spatial.attenuation never reaches silence -- it bottoms out at {previous}, so every shot on the field stays audible forever`)
		end
	end
end
if type(audio.maxConcurrent) ~= "number" or audio.maxConcurrent < 1 then
	fail("maxConcurrent must be at least 1")
end

--------------------------------------------------------------------------------
-- Music
--------------------------------------------------------------------------------

local music = audio.music
checkRange("music.duckMultiplier", music.duckMultiplier, 0, 1)
checkRange("music.duckSeconds", music.duckSeconds, 0, 30)
if type(music.fadeSpeed) ~= "number" or music.fadeSpeed <= 0 then
	fail("music.fadeSpeed must be positive, or a crossfade never finishes")
end

--[[
	Situations map to playlists in the data, not in a branch in the client.

	This started as a scrape of `Music.setContext(...)` call sites, which is a
	bad idea and this gate proved it immediately: the one call site picks a
	context with an inline conditional on the phase, so the scrape read the
	PHASE names as context names and reported three playlists that do not exist.
	The mapping moved into audio.json instead. A situation pointing at a missing
	playlist and a playlist nothing points at are both silence somebody spent
	time on, and both are visible here now without reading Luau at all.
]]
local asked: { [string]: boolean } = {}
for situation, playlist in pairs(music.context) do
	if type(playlist) ~= "string" then
		fail(`music.context.{situation} is not a playlist name`)
	else
		asked[playlist] = true
		if music.playlists[playlist] == nil then
			fail(`music.context.{situation} names playlist '{playlist}', which does not exist`)
		end
	end
end

local trackCount, emptyLists = 0, 0
for name, list in pairs(music.playlists) do
	if not asked[name] then
		fail(`music.playlists.{name} is authored, but no situation in music.context uses it`)
	end
	if type(list) ~= "table" then
		fail(`music.playlists.{name} is not a list`)
	else
		if #list == 0 then
			emptyLists += 1
		end
		for index, id in ipairs(list) do
			trackCount += 1
			checkId(`music.playlists.{name}[{index}]`, id)
			if id == nil then
				fail(`music.playlists.{name}[{index}]: a playlist entry may not be null -- leave it out instead`)
			end
		end
	end
	if music.contextVolume[name] == nil then
		fail(`music.playlists.{name} has no matching music.contextVolume.{name}`)
	end
end


--------------------------------------------------------------------------------

print("\27[1mcheck-audio\27[0m  every id is real, every context has a list")

if #problems > 0 then
	print("")
	for _, message in ipairs(problems) do
		print(`  \27[31m{message}\27[0m`)
	end
	print(`\n\27[31m{#problems} audio problem(s).\27[0m`)
	process.exit(1)
end

local spatialCount = 0
for _, cue in pairs(audio.cues) do
	if cue.spatial == true then
		spatialCount += 1
	end
end
print(`\n\27[32maudio configuration is sound.\27[0m  {cueCount} cues ({spatialCount} positional), {trackCount} track(s).`)
if cueSilent > 0 or emptyLists > 0 then
	--[[
		Reported, never failed. This project supplies no ids on purpose --
		audio privacy makes somebody else's id a trap -- so silence is the
		shipped state and failing on it would train everyone to ignore this
		gate. It is here so that "the game has no sound" is a number rather
		than a surprise in a playtest.
	]]
	print(`  \27[33mstill silent:\27[0m {cueSilent}/{cueCount} cues, {emptyLists} empty playlist(s).`)
	print("  See assets/audio/README.md -- the Creator Store's free library needs no upload.")
end
