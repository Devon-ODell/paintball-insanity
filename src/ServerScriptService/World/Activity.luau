--!strict
--[[
	Activity -- who owns the world at the origin, right now.

	Every scene this game builds is built at the world origin: The Landing, each
	match map, the Range. `Hub.park` and `Hub.restore` are global. That makes the
	origin a single shared resource, and until this module existed nothing owned
	it. What existed instead were three partial guards that did not know about
	each other:

	  - a per-player `starting` flag in Bootstrap,
	  - `MatchService.currentHost()`, over ACTIVE matches only,
	  - `RangeService.isActive`, over that player only.

	None of them covered a Range session, a match venue retained after the final
	whistle so the player can walk to the supply counter, or the window while a
	character load is yielding. So: a drill could start during someone else's
	match and assemble a second range inside their field; a match could start
	while the same player's drill was still running, with both loops consuming
	the same FireMarker events; and a second player receiving CharacterAdded
	during a match restored the entire hub on top of it, because the routing
	asked "is this player in a match?" and inferred hub eligibility from no.

	The lease is the answer to all of those, because it is one question with one
	answer: WHO owns the origin, and for WHAT. It is claimed before anything is
	allocated and before anything yields, it spans preparation, play, the
	retained venue and teardown, and it is released exactly once.

	It is not co-op and it is not a queue. It is the thing that makes "someone
	else is using the world" a fact the server can state, rather than a
	collision it discovers afterwards.
]]

local Log = require(game:GetService("ReplicatedStorage").Shared.Log)

local log = Log.scope("LiveRound.Activity")

local Activity = {}

--- What a lease is for. The Range and a match are both scenes at the origin;
--- naming which one is holding it is what lets character routing dispatch to
--- the owner instead of guessing.
export type Kind = "match" | "range"

export type Lease = {
	player: Player,
	kind: Kind,
	--[[
		Monotonic, so a stale release cannot drop a newer lease.

		Two of these arrive late in practice: a delayed return callback fired
		2.5 s after a match, and a teardown from a match the player already
		replaced by pressing Play again. Both used to be guarded by re-reading
		mutable state and hoping it had not changed.
	]]
	serial: number,
	claimedAt: number,
	--- Unwound in reverse on release. Registered at ALLOCATION time, so a
	--- failure part-way through construction still cleans up what got built.
	cleanups: { () -> () },
	released: boolean,
}

local current: Lease? = nil
local nextSerial = 1

--- Who owns the origin, and for what. Nil when the world is idle -- which is
--- the only state in which The Landing may be standing.
function Activity.holder(): (Player?, Kind?)
	if current == nil then
		return nil, nil
	end
	return (current :: Lease).player, (current :: Lease).kind
end

--- What this player is doing at the origin, if anything.
function Activity.kindFor(player: Player): Kind?
	if current ~= nil and (current :: Lease).player == player then
		return (current :: Lease).kind
	end
	return nil
end

function Activity.isHeld(): boolean
	return current ~= nil
end

--[[
	Claims the origin, or returns nil and who is holding it.

	A DIFFERENT player holding it is a refusal: the second player has to be told
	something, and "one field at a time" is a sentence the server can say. The
	SAME player holding it is a handover -- pressing Play again at the summary
	arrives while that player still owns the retained venue, and making them
	release and re-claim across a yield would open exactly the window this
	module exists to close. The old lease's cleanups run first, in reverse.

	Call this BEFORE allocating anything and BEFORE anything that yields.
]]
function Activity.claim(player: Player, kind: Kind): (Lease?, Player?)
	if current ~= nil and (current :: Lease).player ~= player then
		return nil, (current :: Lease).player
	end
	if current ~= nil then
		Activity.release(current :: Lease)
	end
	local lease: Lease = {
		player = player,
		kind = kind,
		serial = nextSerial,
		claimedAt = os.clock(),
		cleanups = {},
		released = false,
	}
	nextSerial += 1
	current = lease
	log.verbose(`{player.Name} claimed the origin for {kind} (lease {lease.serial})`)
	return lease, nil
end

--[[
	Registers something to unwind when this lease ends.

	Called at the moment of allocation rather than at the end of construction.
	The Range installed its fire, reload and aim listeners before registering the
	session that owned them, so a character load that failed in between left
	three live listeners answering for a drill that no longer existed and nothing
	that knew to disconnect them.
]]
function Activity.onRelease(lease: Lease, cleanup: () -> ())
	if lease.released then
		--- Already over: run it now rather than storing it somewhere nothing
		--- will ever walk again.
		cleanup()
		return
	end
	table.insert(lease.cleanups, cleanup)
end

--[[
	Releases a lease, running its cleanups in reverse.

	Safe to call on a lease that is already released or has been superseded --
	both are ordinary, and both used to be handled by re-reading whatever mutable
	state the caller happened to have. A cleanup that throws does not stop the
	rest from running; the world getting most of the way torn down beats it
	getting none of the way.
]]
function Activity.release(lease: Lease)
	if lease.released then
		return
	end
	lease.released = true
	for index = #lease.cleanups, 1, -1 do
		local ok, err = pcall(lease.cleanups[index])
		if not ok then
			log.warn(`cleanup {index} of lease {lease.serial} failed: {err}`)
		end
	end
	table.clear(lease.cleanups)
	if current == lease then
		current = nil
		log.verbose(`origin released (lease {lease.serial})`)
	end
end

--- Releases whatever this player holds. For disconnects, where there is no
--- lease value to hand back.
function Activity.releaseFor(player: Player)
	if current ~= nil and (current :: Lease).player == player then
		Activity.release(current :: Lease)
	end
end

--- True while this exact lease is still the one that owns the origin. Delayed
--- callbacks ask this instead of re-deriving it from mutable service state.
function Activity.isCurrent(lease: Lease?): boolean
	return lease ~= nil and current == lease and not (lease :: Lease).released
end

--- Test seam. The lease is process-wide by nature, so a spec that claims one
--- has to be able to put the world back.
function Activity._resetForTesting()
	if current ~= nil then
		Activity.release(current :: Lease)
	end
	current = nil
end

return Activity
