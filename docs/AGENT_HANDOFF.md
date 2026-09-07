# AGENT HANDOFF

For the next AI agent working on PROJECT_LIVEROUND. Read this before `BUILD_PLAN.md`
— that document describes the plan, this one describes what actually exists.

---

## Current update — free commerce, Yardline markers and visual polish (2026-09-07)

This section supersedes older state claims below. Read `docs/MONETIZATION.md`
before changing commerce. The user explicitly wants everything free for now.
`Data/monetization.json` has `freeMode=true`, `paidEnabled=false`, `shopFree=true`
and marketplace IDs of zero. Effective prices are zero everywhere, including
physical marker plaques; raw Field Fee costs remain tuning for later. Do not
activate paid products, subscriptions, ads or paid access without the user's
new instruction. Earned camos and campaign rewards still need skill milestones.

- Two free cosmetic collections are integrated into every supply shop:
  Paint Locker and Workshop Finishes. Shared pricing policy, server claims,
  ownership checks, policy-service caching, pass verification and a durable
  developer-product receipt handler are implemented. The repeat-product path
  is tested but no useless repeat sale of a permanent finish is exposed.
- Official ProfileStore is now vendored, pinned and licensed. Live servers use
  session locks; Studio uses ProfileStore.Mock; DemoMode/headless uses explicit
  temporary memory. Version-2 profile reconciliation retains old inventory.
  Paid acknowledgements require confirmed LastSavedData, never just Save().
- Five free classic blowback markers: yardTeal, yardOchre, yardOlive, yardCobalt,
  yardCoral. Original paintball silhouettes, separate colors/feed/reload/capacity
  tradeoffs, shared baseline first-shot spread. Nine total marker models now
  construct, including the previously broken Aurum display/view model.
- Four reactive headshot camos at 10/35/75/150 confirmed mask tags. Progress is
  persistent, no remote reports hits, no purchase or dev bypass. First camo
  auto-equips; later choices are preserved. View panels pulse on headshots.
- All five maps have distinct ground dressing, marked landmarks and routes;
  Woods/Holdfast gain perimeter tree silhouettes. Decorative parts stay out
  of collision/query/touch work. Hub foliage shadow casters drop 2756→1496.
  All navigation graphs remain connected and no node is buried in cover.
- HUD/shop/dialogue rebuilt with responsive scrolling layouts, readable ammo
  and camo progress, free/earned labels, calm collection actions, input modal
  safety and a session-state handshake. Range ray/readout updates run at 10 Hz.
- Fixed skipped first-round warmup, every-respawn hub teleport, stale hub-return
  callbacks, undefined HUD labels, undefined horde callback references,
  duplicate headshot grants, predicted-ammo refill on camo equip, and live
  match duration counting only the last round. Unsupported modes return a
  preparation notice rather than silently starting a gauntlet.

Final verification: **377 specs pass**; both places build; all 95 Luau files
compile. UI/marker, persistence-adapter, live-flow, map and nav checks pass.

New verification commands:

```
~/.local/bin/lune run tools/check-source       # compile all Luau, not typecheck
~/.local/bin/lune run tools/check-persistence  # actual adapter, mock storage
~/.local/bin/lune run tools/check-client-ui    # UI, input and all marker/camo combinations
~/.local/bin/lune run tools/check-demo-world   # all maps, visuals and foliage
~/.local/bin/lune run tools/run-live-checks    # actual MatchService, mock engine
```

`Data/dev.json` remains enabled with the prior infinite-money and map-unlock
flags. This is the sole current ship-check failure; free mode itself is valid.
Roblox Studio is installed. This update was verified headlessly; live purchases,
DataStore traffic, actual rendering and first-person feel were not playtested.
The previously documented live Horde/CTF/boss/Range/consumable-effect gaps remain.

## 1. Get oriented in 60 seconds

```bash
lune run tools/run-tests          # 377 specs, ~4 min, headless. THE signal.
lune run tools/run-tests Campaign # filter by spec filename
rojo build default.project.json -o build/liveround.rbxl
lune run tools/ship-check         # pre-publish gate. FAILS ON PURPOSE right now.
lune run tools/map-validate       # nav graphs + nodes buried in cover
python3 tools/fix-nav-nodes.py    # authoring assist: pushes buried nodes out
lune run tools/sim -- --map dustline --tier pro --policy human --seeds 8 --rounds true
lune run tools/tune-report        # ballistics curve per marker
lune run tools/nav-report         # nav component breakdown when a map disconnects
```

**Roblox Studio is installed; this verification workflow runs headlessly.** `tools/Harness.luau` is a miniature
Roblox module runtime on Lune: it builds the same instance tree Rojo does and
implements `require(instance)`, so specs run genuinely headless. It injects the
real Roblox `Enum`, `Vector3`, `CFrame`, `UDim2` etc. from `@lune/roblox`. If a
module needs a datatype the harness doesn't inject, add it there.

**Wally cannot run here** — its macOS binary is x86_64-only, no Rosetta. `Packages`
paths in `default.project.json` are marked `optional` so the place builds without
it. `Economy/Profile.luau` now uses the bundled pinned ProfileStore dependency;
DemoMode explicitly selects temporary memory.

---

## 2. The five rules you must not break

These are from `CLAUDE.md` and `BUILD_PLAN.md`. Every one of them has automated
enforcement, listed so you know what will catch you.

| Rule | Why | Enforced by |
|---|---|---|
| **One hit is out. No health, anywhere.** | Paintball rule *and* the Mild content rating *and* the whole difficulty design, simultaneously. | `Campaign.spec` greps bosses.json and gear.json for `health`/`damage`/`armour`; `Overworld.spec` does the same for gear |
| **Nothing purchasable improves accuracy.** | A pay-to-win aim trainer produces meaningless telemetry and has no reason to exist. | `GearStats.audit()`, `Consumables.audit()`, `Shop.assertNoPayToWin()` at boot, `tools/ship-check` |
| **No real-world firearm names or models.** | Pushes content maturity up, which destroys discovery. | Human review — *no automated check*. Be careful. |
| **Bots never cheat.** | Every bot parameter must be something a human could match. | `Campaign.spec` asserts horde veterancy clamps at 120 ms / 0.45° |
| **Progression gates on skill, never time.** | `BUILD_PLAN` out-of-scope list. | `Campaign.spec` |

### Requests that arrive violating these

The user has asked for several things that collide with the above. Each was
**built**, translated rather than refused. Do not "fix" these back:

- **"Golden AK"** → the **Aurum Kompressor**, a gold pump marker. Abbreviates to
  AK, preserving the joke. Twelve-round hopper, one shot per manual cycle,
  highest payout multiplier. It is deliberately *the hardest marker in the game*,
  because the ultimate reward in an aim trainer cannot be an aim upgrade.
- **"Dragon's breath / freezing"** → **Emberfill** (red) and **Chillfill** (gold)
  paint fills. No fire, no damage-over-time, no slow. Emberfill fogs nearby bots'
  lenses; Chillfill steps the squad's morale down through the *existing* morale
  system. Both require a landed hit first — the effect is downstream of the shot,
  never on whether it lands.
- **"Armor upgrades"** → the **PROTECTIVE** bay. Jerseys, pads, helmets and
  shoulder rigs that trade *noise* against *mobility*. No damage reduction.
- **"UAV drone showing enemy positions"** → the **Spotter Drone**, which only
  reveals bots that have **fired in the last 4 seconds** — an amplified version
  of a signal already in the world. It is the loudest item in the game, and shots
  taken while it is up are flagged `droneAssisted` and excluded from
  crosshair-placement and reactivity scoring. A full-reveal drone would be a
  purchasable wallhack against two of the six fundamentals the game *measures*.
- **"Boss with more health"** → **field marshals**. Padded head to foot; paint on
  the body does nothing. Only the **hopper** counts — 18 cm across, exposed only
  when they lean out to shoot. Still one hit; just a very small one. This turns
  the boss fight into a precision test, which is what the game trains anyway.
- **"Increase enemies/health in endless"** → more bodies, better tiers, tighter
  comms, and smaller boss targets. Never durability.

---

## 3. Architecture

```
Data/*.json          EVERY tunable number. Nothing numeric is hardcoded in Luau.
  ballistics markers bots economy telemetry match chatter range
  maps_index maps/{speedball,dustline,urban,woods,holdfast}
  overworld venue gear consumables progression npcs endless bosses
  gamemodes leaderboard dev

src/ReplicatedStorage/Shared/   pure, no services: Ballistics, MapGeometry, Rng,
                                Units, GearStats, Consumables, Types, Config,
                                Log, Dev, Spread, MarkerState
src/ReplicatedStorage/Net/      Remotes — one typed definition table
src/ServerScriptService/
  Ballistics/   ProjectileSim (authoritative flight), LagCompensation
  Bots/         AimModel, BotController, SquadCoordinator, Chatter
  Match/        MatchService (live), RoundState, RoundSchedule, WorldBuilder,
                Inflatables, Atmosphere, BotAvatar, FieldDetails,
                Endless, Boss, CaptureTheFlag
  Economy/      Payout, Profile, Shop
  Telemetry/    ShotLog, ShotMeasure, Aggregate, Prescription
  Range/        Drills, DrillScoring
  Sim/          SimMatch, SimDrill, Policies      <- headless, deterministic
  World/        Overworld, PoleBarn, Foliage, NoticeBoard, Npc, Hub
  Dialogue/     DialogueTree (pure), DialogueService
  Progression/  Campaign
  Leaderboard/  Leaderboard
src/StarterPlayer/Client/       init.client, Input, Hud, Tracers, ShopUi,
                                ViewMarker, DialogueUi
```

**The load-bearing property:** gameplay decisions live in pure modules that the
headless harness exercises. `MatchService.luau` is plumbing. `SimMatch.luau` runs
the same bots, ballistics, telemetry and payout with no Roblox at all — which is
why the difficulty curve can be *measured* rather than guessed.

**Units:** everything is **metres and seconds**. `Shared/Units.luau` is the only
place studs and metres meet. Do not introduce studs into `Shared/Ballistics`.

---

## 4. What exists, by system

### Ballistics (done, 23 specs)
Quadratic drag, `v(s) = v0·e^(-k·s)`. Closed forms for time-of-flight and drop;
RK4 for the authoritative flight. **Drop uses a damped closed form** —
`(g·t²/u)·(1 - (1-e^(-u))/u)` where `u = k·s` — because naive `½gt²` over-predicts
by 20% at 50 m. Tracks RK4 within 2%. `solveLead` is tested by feeding its answer
back into the simulation and asserting interception.

Tuned: at 10 m, 3 cm drop and 0.8 body widths of lead. At 40 m, 66 cm and 3.8.

### Matches
- **Gauntlet** — five rounds, 2→3→4→5→6 bots, tier +1 for rounds 4-5. Deaths
  accumulate across all five and are charged **once** at the end.
- **Horde** — endless waves, breather every 5th, marshal every 7th. Locked behind
  `proCircuit`.
- **Capture the flag** — Holdfast only. Solo runner vs a squad that must split
  between defend and attack; the split shifts with the score.

### Telemetry (done, 20 specs)
Six fundamentals. The critical pair is **signed** `leadErrorM` separated from
`angularErrorDeg` — that is what distinguishes "you missed" from "you didn't
lead", which no other aim trainer does well. `Prescription` turns the weakest
confident axis into one line naming one drill.

### Campaign (done, 52 specs)
Ten chapters, `walkOn` → `aurum`. Strictly linear: prerequisites are enforced, so
clearing pro first does not skip the chain. Six NPCs with 37 gated dialogue nodes
carry the briefs.

### World
The Landing: 190 m woodsy hub, ~940 deterministically-scattered plants, gravel
trails, creek and footbridge, pond, a three-bay pole barn, six NPCs, and a
covered leaderboard that cycles a page per map.

---

## 5. Traps and gotchas

1. **`Config.require` errors on a missing key.** JSON `null` decodes as *absent*
   in Lua. Use `Config.get(file).path.to.thing` for optional values.
2. **Nav nodes must not sit inside cover.** `tools/map-validate` reports them,
   `python3 tools/fix-nav-nodes.py` fixes them. `Maps.spec` fails if any exist.
3. **Nav link radius is per-map.** Big maps need a bigger `navLinkRadiusMetres`.
   Vertical connections (ladders, towers) must be hand-declared in `navLinks`
   (zero-based indices) — the automatic linker correctly refuses to connect a
   rooftop to the ground under it.
4. **`{ nil, x }` truncates in Lua.** This silently dropped all Speedball geometry
   once. Build arrays with `table.insert` when an element may be nil.
5. **`local x = setmetatable({}, {__index = function() ... x ... end})`** — the
   `x` inside is *not* the local being defined. Forward-declare.
6. **Never mutate `Config` tables.** `Endless.applyVeterancy` clones, because
   wave 400 would otherwise permanently ruin wave 1.
7. **`Sim.spec` takes ~3.5 min** and is 90% of suite runtime. Use
   `singleRound = N` in sim options to keep new specs fast.
8. **Tier curve must be measured on round 3.** Rounds 4-5 escalate the tier, which
   collapses semipro and pro into the same fight.
9. **Dialogue entry points need `entry: true`.** A node with only `requires` is a
   gated *sub-node*, not an alternate opening.
10. **Inflatable bunkers** have one invisible `CollisionHull` matching the map
    JSON's OBB; all visual parts are `CanCollide = false, CanQuery = false`. That
    keeps player collision, bot line-of-sight and projectile blocking as one
    shape. Do not make the visuals collidable.

---

## 6. State of the build

**343 specs pass. `rojo build` succeeds. `ship-check` fails on one item, by design.**

`Data/dev.json` currently has `enabled: true` with `infiniteCurrency` (99,999,999
FF, unspendable) and `unlockEverything` on, at the user's request for dev testing.
`tools/ship-check` **blocks publishing while this is true** — that is the intended
behaviour and the thing stopping it shipping by accident. Set `enabled: false`
to clear it. No dev flag can reach the payout maths; there is a spec asserting it.

### Verified by measurement

Speedball, calibrated `human` policy, round 3 isolated (no tier escalation):

| Tier | Mean deaths |
|---|---|
| rec | 0.2 |
| amateur | 0.9 |
| semipro | 2.8 |
| pro | 4.4 |

Full five-round matches genuinely fail at the top tiers — semipro clears 4.2/5
rounds, pro 3.9/5.

Engagement distances (declared band → measured median): Speedball 16→27,
Dustline 21→22, Woods 44→55, Holdfast 52→unmeasured.

### NOT verified — the honest list

- **Nothing in `src/StarterPlayer/Client/` or `Match/MatchService.luau` has ever
  been run.** No Studio. The place builds and the structure is sound, but
  first-person feel, the HUD holdover ladder, hit registration against a real
  character, the dialogue panel and the shop UI are all unverified.
- **The hub is unrendered and unwalked.** Trail widths, how long the walk to the
  barn *feels*, and whether ~940 scattered models cost too much on a low-end
  device are guesses.
- **Horde, CTF and bosses have pure logic + specs but no live binding.**
  `Endless`, `CaptureTheFlag` and `Boss` are complete and tested; `MatchService`
  does not yet dispatch to them. **This is the biggest single gap.**
- **The Range is sim-only.** `SimDrill` works; the live drill binding does not
  exist. The gate is signed and returns a "not yet" notice.
- **Consumables have data, catalogue, audit and shop plumbing but no in-match
  effects.** Nothing throws a grenade yet.
- **Ambience has no audio ids**, deliberately — hardcoding someone else's asset
  id ships a broken build. Drop ids into `Data/overworld.json` and they play.
- **Leaderboard DataStore paths are untested** (no live server). Validation,
  formatting and ranking are pure and covered.

---

## 7. Suggested next moves, in order

1. **Get it into Studio and walk the hub.** Everything unverified above is
   unverified for the same reason. This unblocks the most.
2. **Bind horde and CTF in `MatchService`.** The rules modules are done and
   tested; they need a `mode` parameter on match start and a dispatch.
3. **In-match consumable effects.** `ProjectileSim` already resolves segments;
   grenades and smoke need volume queries against the same world model.
4. **Live Range drills.** `SimDrill` proves the scoring; it needs target actors.
5. **Boss encounters.** `Boss.hitTarget` returns a capsule `ProjectileSim`
   already understands — wire it as an extra target with the body excluded.
6. **Tune from sim data, not intuition** (BUILD_PLAN Phase 8). `tools/sim` and
   `tools/tune-report` exist for exactly this.

---

## 8. Working style that has held up

- Every constraint that matters gets an **automated check**, not a comment. The
  checks caught real regressions repeatedly during this build.
- Specs assert **shipping** behaviour and pin dev overrides off; dev flags get
  their own block.
- When a request collides with a constraint, **build the translation and flag it**
  — do not refuse and do not silently comply.
- `docs/PROGRESS.md` holds the session-by-session narrative; this file holds the
  durable state.

---

## Tools added in the world/character passes

| Tool | What it answers |
|---|---|
| `lune run tools/flow-report` | Can an enemy spawn see the player on arrival? What is the longest clear lane, standing and crouched? How far is the average step from cover? Is every nav node reachable from spawn? |
| `lune run tools/ground-spawns` | Where would each elevated bot spawn go if it had to be on the ground? Reports only; never writes a map. |
| `lune run tools/probe-spawns` | Is every declared spawn actually supported by geometry, or is it in the air? |
| `lune run tools/check-characters` | Does every NPC and every bot tier actually construct, and how many parts is each? |
| `lune run tools/engagement-report` | Median engagement distance per map against the band that map declares, with a suggested correction. |

`tools/Harness.luau` now injects `Instance`, so **server world builders are
runnable headlessly**. Before this, anything that called `Instance.new` could only
be checked by reading it. `check-characters` is the first thing to use it; the
barn, the foliage and the map builders are all now testable the same way and are
not yet covered.

### Traps found the hard way

- **Maps are built at the world origin, and so is the hub.** They occupy the same
  space. `Hub.park()` is what keeps them apart; if you add another world, park it.
- **A snake is supposed to be see-over-able.** 1.30m of cover against a 1.32m eye
  line is deliberate. Measure crouched before calling a lane empty.
- **Concealment volumes do not affect the nav graph**; cover volumes do. If a sight
  screen keeps severing your graph, it probably wants to be concealment.
- **Nav nodes sit on the bunker line.** Dropping cover onto a wire buries nodes and
  disconnects the graph. Put it in the gaps between node z-values, or outboard so
  it breaks the sightline without closing the walk line.

---

## Tools added in the texture/character pass

| Tool | What it answers |
|---|---|
| `lune run tools/check-zfight` | Do any two surfaces share a plane? That is the shimmering, "one texture inside another" look when the camera moves — invisible in a screenshot. Must stay at zero. |
| `lune run tools/check-gait` | Do the bots' legs actually move with the ground, and do the two legs oppose each other? |
| `lune run tools/foliage-report` | What did each scatter layer actually place, what does it reach, and what does the forest cost in parts? |
| `lune run tools/probe-map <map>` | Engagements and median for one map. Fast enough to A/B a single piece of geometry. |

### Things that are true and not obvious

- **`Shared/Surfaces` exists because the obvious fix fails twice.** Lifting path
  N by N steps puts a kerb across every junction; sinking it pushes the path
  below the ground it is drawn on. Both were tried. Only paths that *touch* need
  different levels — it is a graph colouring, and three levels covers every map.
- **A snake bunker is supposed to be see-over-able.** 1.30m of cover against a
  1.32m eye line is deliberate. Measure crouched before calling a lane empty.
- **Adding cover to Speedball has been tried twice and measured twice.** Both
  times it cost fights (60 engagements to 19, and to 8) and moved the median by
  0.1m. Engagement distance is set by when line of sight first exists. If you
  want to move it, look at the sim's player policy, which appears to fire on
  first sight.
- **The harness runs spawned threads on coroutines.** It used to call them
  inline, so any `while ... task.wait()` loop span forever. If you add a
  scheduler-driven job, it will run to its first `wait` and stop under test.
- **`Instance` and `Lighting` are real in the harness.** World builders are
  runnable headlessly; `check-characters` and `check-zfight` rely on it.
- **Cosmetics must not be able to take the field down.** `WorldBuilder` parents
  the world before applying `Atmosphere`, and guards it. It used to be the other
  way round, and a lighting error discarded the entire built map.
