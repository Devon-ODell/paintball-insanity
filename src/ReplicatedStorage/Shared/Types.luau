--!strict
--[[
	Types -- shared vocabulary. Everything that crosses a module boundary or a
	remote is declared here so that the server, the client predictor and the
	headless sim cannot quietly disagree about a shape.
]]

export type MapId = string
export type BotTier = "rec" | "amateur" | "semipro" | "pro"
export type BotRole = "anchor" | "flanker" | "pressure"
export type MoraleState = "cocky" | "rattled" | "blaming" | "broken"
export type Fundamental =
	"reactivity"
	| "flicking"
	| "targetSwitching"
	| "tracking"
	| "crosshairPlacement"
	| "leadAndDrop"

--- The stance the shooter was in. Drives the spread multiplier and is recorded
--- on every shot, because "you cannot shoot accurately while sprinting" is only
--- a real rule if the telemetry can see you breaking it.
export type Stance = "standing" | "crouching" | "moving" | "sprinting"

export type Loadout = {
	marker: string,
	barrel: string,
	hopper: string,
	tank: string,
	jersey: string,
	mask: string,
	paintColor: string,
	markerSkin: string,
}

--- One authoritative shot, as recorded by the server. This is the raw material
--- of the entire aim-training product; every field is measured, none inferred
--- from a client claim.
export type ShotRecord = {
	shotId: number,
	t: number,
	map: MapId,
	marker: string,
	stance: Stance,
	shooterMoving: boolean,

	distance: number,
	hit: boolean,
	eliminated: boolean,
	targetId: string?,

	angularErrorDeg: number,
	leadErrorM: number?,
	holdoverErrorM: number?,

	targetLateralSpeed: number,
	timeToAcquireMs: number?,
	targetVisibleMsBeforeShot: number?,
	crosshairOffsetDegAtReveal: number?,
	priorAimSwingDeg: number?,
}

export type EliminationRecord = {
	t: number,
	targetId: string,
	distance: number,
	msSincePreviousElimination: number?,
}

export type FundamentalScore = {
	fundamental: Fundamental,
	score: number,
	samples: number,
	rawMean: number,
	confident: boolean,
}

export type SessionSummary = {
	map: MapId,
	marker: string,
	tier: BotTier,
	durationSeconds: number,
	shots: number,
	hits: number,
	hitRate: number,
	eliminations: number,
	deaths: number,
	cleared: boolean,
	scores: { [Fundamental]: FundamentalScore },
	weakest: Fundamental?,
	prescription: { line: string, drill: string }?,
	leadBiasM: number?,
	payout: number,
}

export type BotSnapshot = {
	id: string,
	position: Vector3,
	velocity: Vector3,
	alive: boolean,
	tier: BotTier,
	role: BotRole,
	anchorId: string?,
	name: string,
}

export type PlayerSnapshot = {
	position: Vector3,
	velocity: Vector3,
	stance: Stance,
	alive: boolean,
	aimDirection: Vector3,
}

export type MatchOutcome = {
	cleared: boolean,
	deaths: number,
	eliminations: number,
	durationSeconds: number,
	shots: number,
	hits: number,
	longestStreak: number,
}

return {}
