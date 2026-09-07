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

	-- Server -> client results and state.
	ShotResolved = "Event",
	MarkerFired = "Event",
	PlayerEliminated = "Event",
	BotEliminated = "Event",
	MatchStateChanged = "Event",
	MatchSummary = "Event",
	ChatterLine = "Event",
	LoadoutChanged = "Event",
	CurrencyChanged = "Event",
	DrillScore = "Event",
	LeaderboardUpdated = "Event",
	DialogueOpened = "Event",
	DialogueChoice = "Event",
	CampaignUpdated = "Event",
	ConsumableUsed = "Event",
	FlagEvent = "Event",
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

return Remotes
