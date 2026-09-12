--!strict
--[[
	Remotes -- every wire between client and server, declared in one place.

	Each remote gets a typed wrapper so that a call site cannot quietly change
	the payload shape on one side only. The server creates the instances; the
	client waits for them.

	Read the direction of each remote below as a security statement. Client to
	server, the payload is always an INTENT ("I pulled the trigger, here is where
	I think my muzzle was") and never a RESULT ("I hit bot3", "my balance is
	9000"). The server answers with results. There is deliberately no remote by
	which a client can report a hit, a payout, a purchase price or a stat.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local Remotes = {}

local FOLDER_NAME = "LiveRoundNet"

export type FireRequest = {
	--- Where the client believes its muzzle was. Validated, never trusted.
	origin: Vector3,
	direction: Vector3,
	--- Client clock at the moment of firing, for lag compensation.
	clientTime: number,
	stance: Types.Stance,
}

--[[
	A swing of the marker's butt.

	The only thing the client is allowed to say is which way it was facing.
	Where the swinger stood, who was inside reach, and whether the cooldown had
	elapsed are all the server's, decided in Melee against the server's own
	position -- so this payload cannot name a victim any more than a fire
	request can.
]]
export type SwingRequest = {
	direction: Vector3,
	clientTime: number,
}

export type ShotResult = {
	shotId: number,
	hit: boolean,
	targetId: string?,
	impact: Vector3,
	--- The server's own measurement, so the HUD can teach rather than guess.
	holdoverErrorM: number?,
	leadErrorM: number?,
}

local DEFINITIONS = {
	-- Client -> server intents.
	FireMarker = "Event",
	SwingMarker = "Event",
	RequestReload = "Event",
	RequestPurchase = "Function",
	RequestCommerce = "Function",
	RequestSessionState = "Function",
	RequestEquip = "Function",
	RequestShopVisit = "Function",
	RequestShopCatalogue = "Function",
	ShopOpened = "Event",
	RequestMatchStart = "Function",
	RequestRangeDrill = "Function",
	ReportLatency = "Event",
	--[[
		Where the crosshair is pointing, streamed while a player is on a field
		or on the firing line.

		Crosshair placement is one of the six fundamentals this game grades and
		prescribes a drill for, and it is the only one that cannot be recovered
		from the shot itself: it asks where the player was already looking when
		the target appeared, which is a moment nobody pulled a trigger at. It
		was inferred from the previous shot's direction, which on Peek reports
		the swing between two known angles rather than the placement.

		Purely a telemetry input. Nothing authoritative reads it -- no hit, no
		payout and no objective depends on it -- so a client that lies about it
		is only lying to its own coach.
	]]
	ReportAim = "Event",
	--[[
		Crouch and lean, as INTENT rather than as a field on a fire request.

		Crouch reached `Spread` as a boolean on the shot itself, so a client
		could claim to be crouched while standing still and collect the tighter
		cone without ever crouching. Lean was not transmitted at all: the camera
		moved half a metre around a corner and the authoritative muzzle stayed in
		the middle of the body, so the player saw a clear shot and the ball hit
		the wall.

		Still not trusted as fact. `Match/PlayerState` holds it as a state,
		checks the crouch against the speed it actually observes, and clamps the
		lean to the offset the tuning file allows.
	]]
	ReportStance = "Event",

	-- Server -> client results and state.
	ShotResolved = "Event",
	MarkerFired = "Event",
	PlayerEliminated = "Event",
	MarkerRefilled = "Event",
	BotEliminated = "Event",
	MatchStateChanged = "Event",
	MatchSummary = "Event",
	ChatterLine = "Event",
	LoadoutChanged = "Event",
	CurrencyChanged = "Event",
	-- Presentation only; an asynchronous notification cannot change activity.
	Notice = "Event",
	DrillScore = "Event",
	--- Which bearing the next Peek target will appear at. The drill's angles are
	--- deliberately learnable; a cue nobody is told is not a cue.
	DrillCue = "Event",
	--[[
		The five drills, offered as a choice.

		Walking to the Range gate always started the FIRST drill in
		`drillOrder`, and the coach started whichever one his diagnosis pointed
		at. Holdover and Peek were therefore reachable only by being told to
		practise them; a player who knew perfectly well that their lead was the
		problem had no way to say so. Five authored drills with two selectable
		is four drills of content behind a door with no handle.
	]]
	DrillCatalogue = "Event",
	LeaderboardUpdated = "Event",
	DialogueOpened = "Event",
	DialogueChoice = "Event",
	CampaignUpdated = "Event",
	ConsumableUsed = "Event",
}

local folder: Folder? = nil

local function ensureFolder(): Folder
	if folder then
		return folder :: Folder
	end
	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if existing then
			folder = existing :: Folder
			return folder :: Folder
		end
		local created = Instance.new("Folder")
		created.Name = FOLDER_NAME
		for name, kind in pairs(DEFINITIONS) do
			local remote = Instance.new(if kind == "Event" then "RemoteEvent" else "RemoteFunction")
			remote.Name = name
			remote.Parent = created
		end
		created.Parent = ReplicatedStorage
		folder = created
		return created
	end
	folder = ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
	return folder :: Folder
end

--- Builds the remote instances. Server only, called once at boot.
function Remotes.init()
	assert(RunService:IsServer(), "Remotes.init is server-only")
	ensureFolder()
end

function Remotes.event(name: string): RemoteEvent
	assert(DEFINITIONS[name] == "Event", `no RemoteEvent named '{name}'`)
	return ensureFolder():WaitForChild(name) :: RemoteEvent
end

function Remotes.fn(name: string): RemoteFunction
	assert(DEFINITIONS[name] == "Function", `no RemoteFunction named '{name}'`)
	return ensureFolder():WaitForChild(name) :: RemoteFunction
end

--------------------------------------------------------------------------------
-- Typed wrappers
--------------------------------------------------------------------------------

--[[
	Validates a fire request off the wire.

	Everything a client sends is assumed hostile. A malformed or absurd payload
	is dropped rather than clamped, because a clamped exploit is still an
	exploit that reached the simulation.
]]
local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function finiteVector(value: Vector3): boolean
	return finite(value.X) and finite(value.Y) and finite(value.Z)
end

function Remotes.validateFireRequest(payload: any): FireRequest?
	if type(payload) ~= "table" then
		return nil
	end
	if typeof(payload.origin) ~= "Vector3" or typeof(payload.direction) ~= "Vector3" then
		return nil
	end
	if not finiteVector(payload.origin) or not finiteVector(payload.direction) then
		return nil
	end
	if type(payload.clientTime) ~= "number" or not finite(payload.clientTime) then
		return nil
	end
	local magnitude = payload.direction.Magnitude
	if magnitude < 1e-4 or magnitude > 1e4 then
		return nil
	end
	local stance = payload.stance
	if stance ~= "standing" and stance ~= "crouching" and stance ~= "moving" and stance ~= "sprinting" then
		return nil
	end
	return {
		origin = payload.origin,
		direction = payload.direction.Unit,
		clientTime = payload.clientTime,
		stance = stance :: Types.Stance,
	}
end

--[[
	Validates a swing off the wire.

	Deliberately thinner than a fire request, because a swing carries less: no
	origin worth reading (the server uses its own), no stance (a shove does not
	have a cone). Same rule though -- malformed is dropped, never clamped.
]]
function Remotes.validateSwingRequest(payload: any): SwingRequest?
	if type(payload) ~= "table" or typeof(payload.direction) ~= "Vector3" then
		return nil
	end
	if not finiteVector(payload.direction) then
		return nil
	end
	local magnitude = payload.direction.Magnitude
	if magnitude < 1e-4 or magnitude > 1e4 then
		return nil
	end
	if type(payload.clientTime) ~= "number" or not finite(payload.clientTime) then
		return nil
	end
	return { direction = payload.direction.Unit, clientTime = payload.clientTime }
end

return Remotes
