# BUILD_PLAN.md — PROJECT_LIVEROUND

Ordered by dependency and by how much each phase de-risks the rest. Do not start a
phase until the previous one's acceptance criteria pass. Update `docs/CHANGE_REPORT.md`
at the end of every session.

---

## The design thesis

This is an aim trainer wearing a paintball game as a costume.

Paintballs are **slow arcing projectiles**, not hitscan. That single decision is the
whole design. It means the core skill is not flicking to a dot — it is **predicting
where a moving target will be, and compensating for drop over distance.** That is a
deeper and less-served skill than what most aim trainers drill, and it is the reason
this game has a reason to exist.

Six fundamentals, and where each is taught:

| Fundamental | Definition | Primary map |
|---|---|---|
| Reactivity | time from target visible to first shot | Speedball |
| Flicking | large-angle acquisition under time pressure | Speedball |
| Target switching | sequential acquisition, multiple threats | Speedball |
| Tracking | smooth pursuit of a laterally moving target | Urban |
| Crosshair placement | pre-aiming the angle before the target appears | Urban |
| Lead & drop | projectile prediction at range | Woods |

The three maps are a curriculum ordered by engagement distance. Each map's shop tier
unlocks the marker that map's skill requires. **The map order teaches the economy.**

---

## Difficulty philosophy

It is a meat grinder on purpose. Design targets:

- A competent FPS player should lose their first several 1v6 attempts on every map.
- Straight fights are unwinnable. Six markers beat one. The player must win *angles*,
  *timing*, and *isolation* — never trades.
- **Respawn is free. Payout is not.** Every death applies a multiplicative penalty to
  the round payout. A flawless clear pays many times what a grind-it-out clear pays.
  This lets anyone finish and makes only skill profitable.
- No health regeneration. One hit eliminates. Paintball rules — that is also why the
  stakes read as low while the difficulty reads as high.
- Bots do not cheat. Their advantage is numbers and coordination, never wallhacks or
  perfect aim. Every bot parameter must be something a human could match.

If the player can beat a map without improving at aiming, the tuning is wrong.

---

## Phase 0 — Environment truth

- Confirm Roblox Studio installed and Rojo syncing to a live session.
- Repo skeleton per `CLAUDE.md`. `wally.toml`, `default.project.json`, `.luaurc`
  with `--!strict` enforced.
- TestEZ wired and running from the command line with a trivial passing spec.
- Record engine version and every verified API in `docs/PLATFORM_NOTES.md`.

**Acceptance:** `rojo build` succeeds, tests run and report from the shell, and a
Rojo-synced script prints to the Studio output. If any step fails, stop and report —
everything downstream assumes this loop works.

---

## Phase 1 — Ballistics

The most important phase in the project. Get this wrong and nothing after it matters.

Implement in `Shared/Ballistics` as **pure functions with no Roblox dependencies** so
they are unit-testable:

- Projectile launch given origin, direction, muzzle velocity.
- Gravity integration with configurable drag. Paintballs decelerate noticeably;
  model it.
- `solveLead(shooterPos, targetPos, targetVelocity, muzzleVelocity)` returning the
  aim point. The bots use this; the player has to do it in their head.
- `timeOfFlight(distance)` — expose this to the HUD later as a teaching tool.

Server runs the authoritative simulation and owns all hit validation with lag
compensation. Client spawns a cosmetic tracer only. The client's tracer may
occasionally disagree with the server; the server wins, always.

Feel targets, tune later from `Data/markers.json`: at 10m the drop is negligible and
lead is small. At 40m a sprinting target requires roughly a body-width of lead and
visible holdover. Those two numbers define the entire skill curve — tune everything
else around them.

**Acceptance:** unit tests assert drop at 10/25/50m matches expected values, and that
`solveLead` fed back into the simulation actually intercepts a target moving at
constant velocity. Test the solver against itself; it's the only way to know it's right.

---

## Phase 2 — Player and markers

First-person controller. Movement, sprint, crouch, slide, lean if it fits the maps.
Movement must interact with shooting: **you cannot shoot accurately while sprinting.**
Stop-to-shoot timing is a fundamental and the game should enforce it.

Markers are **sidegrades, never upgrades.** Every marker trades along these axes:

- Muzzle velocity (lead required, drop, time of flight)
- Rate of fire
- First-shot accuracy vs sustained cone
- Hopper capacity and reload time
- Loudness — bots hear you

Three archetypes to start:

- **Mechanical** — balanced, low ROF, cheap. The starter.
- **Electronic** — high ROF, wide sustained cone, loud, expensive hopper feed.
- **Pump** — one shot per manual cycle, best accuracy and velocity, hardest to use.
  Highest payout multiplier of any marker. This is the hardcore hook.

All stats in `Data/markers.json`. No marker may increase the player's accuracy in a
way that substitutes for skill — a better marker changes *what* you have to be good
at, never *how good you have to be.*

**Acceptance:** tests assert each marker's spec loads correctly and that sustained
fire widens the cone per its curve. Manual check: pump marker is meaningfully harder
and meaningfully more rewarding.

---

## Phase 3 — Telemetry

Build this before the bots. It is both the aim-training product and your only way to
verify anything.

Every shot writes a record server-side:

```json
{
  "t": 84.21, "map": "speedball", "marker": "mechanical",
  "distance": 23.4, "hit": false,
  "angular_error_deg": 2.7,
  "lead_error_m": 0.9,
  "target_lateral_speed": 5.1,
  "time_to_acquire_ms": 412,
  "shooter_moving": true,
  "target_visible_ms_before_shot": 380
}
```

Aggregate per session into the six fundamentals from the design thesis. `lead_error_m`
signed and separated from `angular_error_deg` is the critical pair — it tells you
whether the player missed because they aimed at the wrong spot or because they didn't
lead enough. Those are different problems with different fixes, and no other aim
trainer distinguishes them well.

Post-match screen shows the six scores, the weakest one called out, and a one-line
prescription pointing at a specific range drill.

Also build `LiveRound.SimMatch(map, seed, policy)` — runs a full match headless with a
scripted player policy, dumps the same telemetry plus outcome JSON to `Saved/Sims/`.
Same seed must produce identical output.

**Acceptance:** ten seeded sims produce identical repeated output; telemetry
aggregation has unit tests with hand-computed fixtures; a deliberately bad policy
(never leads) shows high `lead_error_m` and normal `angular_error_deg`.

---

## Phase 4 — Bots

Six per match. Their difficulty comes from a small set of human-matchable parameters —
no cheating, ever.

Per-bot aim model, all from `Data/bots.json`:

| Parameter | Rec | Amateur | Semi-pro | Pro |
|---|---|---|---|---|
| Reaction time (ms) | 450 | 320 | 230 | 170 |
| Aim error (deg, 1σ) | 4.0 | 2.4 | 1.3 | 0.7 |
| Lead solution accuracy | 0.4 | 0.65 | 0.85 | 0.96 |
| Time-to-settle (ms) | 600 | 400 | 260 | 180 |
| Crosshair pre-placement | none | rough | good | excellent |
| Peek discipline | poor | fair | good | excellent |

`Lead solution accuracy` is the interesting one: it's how much of the correct
`solveLead` answer the bot actually applies. A rec bot shoots roughly where you are;
a pro bot shoots where you will be. That single parameter carries most of the felt
difficulty, and it's the same skill the player is learning.

Squad coordination via a `SquadCoordinator`: role assignment (anchor, flanker,
pressure), focus-fire targeting, and crossfire setup so the player gets punished for
holding one angle too long. Higher tiers coordinate more; rec-tier bots mostly don't.

Morale chatter tied to remaining count — cocky at 6, blaming each other at 3, quiet at
1. Trash talk on player death. This is the tone carrier; write real lines.

**Acceptance:** sim harness across 20 seeds shows monotonic win-rate decline across the
four tiers for a fixed player policy. Unit test asserts bot aim error distribution
matches its configured σ. No bot ever acquires a target it has no line of sight to —
test this explicitly.

---

## Phase 5 — Maps

Built from JSON layout descriptions in `Data/maps/`, assembled by code at runtime.
Low-poly flat-shaded, no textures, saturated palette, strong silhouettes.

**1. Speedball** — Rectangular field, symmetric, inflatable bunkers (snake, dorito,
can, temple). Deliberately a meat grinder: shallow cover, no real flank, short
sightlines. Trains reactivity, flicking, and target switching. This is where the
player learns that trading is death.

**2. Urban** — Sandy, two and three story buildings, beat-up cars, alleys. Verticality
and mid-range. Trains tracking, crosshair placement, and lead across elevation
changes — shooting down at a moving target is a distinct and underdrilled skill.

**3. Woods** — Hills, treelines, wooden structures and towers. Long sightlines,
elevation, concealment that isn't cover. Trains lead and drop at maximum range. Pump
marker's map.

Each map defines spawn points, bot patrol/anchor positions per tier, cover volumes,
and sightline annotations the bots use for pre-placement.

**Acceptance:** each map loads, bot navigation completes without stalling across 10
seeds, and the sim harness reports engagement-distance histograms that actually differ
between maps. If Woods and Speedball produce similar distance profiles, the maps have
failed at their purpose.

---

## Phase 6 — Economy

Currency earned per match: `base(map) × tier_multiplier × marker_multiplier ×
death_penalty × accuracy_bonus`. All curves in `Data/economy.json`, all computed
server-side.

`death_penalty` is the load-bearing term. Tune so a no-death clear pays roughly 8–10×
a ten-death clear. Finishing is always possible; profiting requires skill.

Shop sells: markers (sidegrades), hoppers, barrels, air tanks, and cosmetics (jerseys,
masks, paint colors, marker skins).

**Monetization rule, absolute:** Robux purchases may buy cosmetics and convenience
only. Nothing purchasable may improve accuracy, reduce recoil, increase velocity, or
otherwise substitute for aim. This is not a business preference — a pay-to-win aim
trainer produces meaningless telemetry and has no reason to exist. If a proposed item
would make the player shoot better, it does not ship.

Persistence via a session-locked profile store. Verify the current recommended
library; do not use raw `DataStoreService` without session locking or you will lose
player data on server migration.

**Acceptance:** payout math has unit tests against hand-computed fixtures. Exploit
test: a client attempting to report its own payout, currency, or inventory is rejected
and logged. Profile survives a simulated server restart.

---

## Phase 7 — The Range

The aim trainer, made explicit. Free, no payout, always available.

Drills, each targeting one fundamental and scored on the matching telemetry axis:

- **Pop-up** — targets appear at random angles, scored on reactivity and flick error.
- **Strafe** — single target moving laterally at fixed speed, scored on `lead_error_m`.
  Speed and distance both scale up.
- **Switch** — three simultaneous targets, scored on time between eliminations.
- **Holdover** — static targets at 20/35/50m, scored on vertical error. Teaches drop.
- **Peek** — target appears at a known angle after random delay, scored on crosshair
  placement at the moment of appearance.

The post-match prescription from Phase 3 links directly into the relevant drill.
That loop — play, get told exactly what you're bad at, drill it, play again — is the
product.

**Acceptance:** each drill produces a score reproducible under the sim harness, and
drill scores correlate with the corresponding match telemetry axis across sim runs.

---

## Phase 8 — Tuning

Only after everything above passes. In priority order:

1. Ballistics feel. Muzzle velocity and drag are the two numbers the whole game
   rests on. Tune from sim data, not intuition.
2. Bot tier curves against measured win rates. Target: a competent player clears
   Speedball rec-tier in 3–5 attempts, pro-tier in 20+.
3. Payout curve against measured death counts.
4. Chatter bank expansion. Highest comedy-per-hour of anything remaining, zero code.
5. Audio, hit feedback, paint splatter tuning.

---

## Out of scope

Do not build, and do not let these creep in:

- Multiplayer, lobbies, parties, matchmaking. Solo PvE only.
- Any progression that gates content behind time rather than skill.
- Loot boxes, gacha, randomized purchases of any kind.
- Blood, gore, injury, death, or real-world firearms. See `CLAUDE.md`.
- Procedural maps. Three hand-described maps, assembled from JSON.
- Anything authored in Studio rather than in `src/`.
