# CLAUDE.md — PROJECT_LIVEROUND

Persistent instructions. Read fully before every session.

---

## What this is

A single-player Roblox PvE paintball shooter built as a **disguised aim trainer**.
One player against six bots per match. Low-poly, flat-shaded, saturated palette.

The game is deliberately hard. Losing a straight 1v6 is the expected outcome; the
player is meant to die repeatedly and improve. Death costs no progress — it costs
payout. You can brute-force any match with enough respawns and earn almost nothing
for it. That is the accessibility floor and the skill ceiling in one mechanic.

**Everything is paintball.** No firearms, no blood, no death. Enemies are hit,
splattered, and out for the round. This is a hard content constraint, not a
stylistic preference — see "Platform constraints" below.

Comedy lives in the enemy team's voice lines. They trash-talk you when they win and
degrade into blame and demoralized silence as you pick them apart. Write those lines
as a real design artifact.

---

## Stack

- **Roblox**, Luau, `--!strict` on every module. No untyped files.
- **Rojo** for filesystem↔Studio sync. All source is plain text in `src/`.
- **Wally** for package management.
- Studio is used only to run and observe. **Never author logic in Studio** — anything
  created there is invisible to you and unrecoverable. If it isn't in `src/`, it
  doesn't exist.

### Verify before you build

Do not assume API shape from memory. At session start, check current Roblox
documentation for anything you plan to use. The engine ships weekly; `Instance`
APIs, `ContentProvider`, and the Luau type system have all moved. Third-party
packages especially — confirm a package is still maintained before depending on it.

Record what you verified in `docs/PLATFORM_NOTES.md`.

---

## Platform constraints (non-negotiable)

Roblox rates violence by whether its *consequence* is realistic. A single realistic
consequence pushes an experience into moderate or strong. Restricted experiences
allow more but require ID verification, are unplayable in several countries, and get
filtered out of age-gated recommendations — which destroys discovery, the only thing
Roblox is actually for.

Therefore:

- Paint splatter only. No blood, no gore, no injury, no death.
- Hit players are eliminated for the round and walk off. They are fine.
- No real-world firearm models, names, or terminology. Markers, hoppers, barrels,
  air tanks, velocity, FPS.
- Target content maturity: **Mild**. Fill the Maturity & Compliance questionnaire
  honestly and design to stay inside it.

If a feature would push the rating up, don't build it. Ask first.

---

## Architecture rules

**Server is authoritative. Always.**

The client renders and predicts. The server decides. Every hit, every payout, every
purchase, every stat is validated server-side. Assume the client is compromised,
because on Roblox it eventually is.

```
Client                          Server
  input -> local projectile       <- authoritative projectile sim
  visual tracer                   <- hit validation + lag comp
  HUD prediction                  <- ProfileStore-backed player data
                                  <- telemetry writer
```

Never trust a client-reported hit. Never let the client compute a payout. Never
store currency anywhere but the server-side profile.

### Module layout

```
src/
  ReplicatedStorage/
    Shared/         types, constants, math (ballistics, lead calc)
    Net/            remote definitions, one typed wrapper per remote
  ServerScriptService/
    Match/          match state, round flow, scoring
    Ballistics/     authoritative projectile sim + hit validation
    Bots/           bot controller, aim model, squad coordination
    Economy/        profile data, shop transactions, payout calc
    Telemetry/      shot log, aggregation, session summary
  StarterPlayer/
    Client/         input, camera, prediction, HUD, tracers
Data/               JSON tuning — source of truth for every number
docs/
tests/
```

`Data/*.json` holds every tunable value. Nothing numeric is hardcoded in Luau.
Bot difficulty, marker stats, payout curves, and map layouts all live there so they
can be tuned without touching logic.

### Solo PvE on a multiplayer platform

Matches are single-player. Set `MaxPlayers = 1` on the match place, or use reserved
servers via `TeleportService`. Verify current best practice — this has changed.
Do not build lobby or party systems. There is no multiplayer in scope.

---

## Verification discipline

You cannot watch the game play. Build your own eyes:

- **TestEZ** specs for all pure logic: ballistics, lead calculation, payout math,
  bot aim error model, telemetry aggregation. These run headless and are your
  primary signal.
- **Headless match sim** (Phase 3). Runs a full match with a scripted player policy
  and dumps JSON. Build it before the bots, not after.
- Every bot state transition logs through a `LiveRound.Bots` logger at verbose.

Run `rojo build` and the test suite after every change set. Do not stack broken work.

---

## What you should push back on

You have editorial authority. If `BUILD_PLAN.md` specifies something wrong,
unbuildable, or rating-unsafe, say so and propose an alternative before implementing.
Do not silently deviate.

Flag specifically: anything requiring Studio GUI work, anything that would raise the
content maturity rating, anything where a Roblox API has moved, and anything that
would let a purchase improve the player's accuracy (see the monetization rule in
`BUILD_PLAN.md` — it is a design constraint, not a business one).
