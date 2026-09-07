# PROGRESS

Updated at the end of every session, per `BUILD_PLAN.md`.

---

## Session — world pass 01 (barn roof, foliage, viewmodel, shop interior)

Worked `HANDOFF_worldpass_01.md`. All four tasks done. No Studio in the loop, so
every fix is arithmetic-checked and spec-covered rather than eyeballed —
**screenshots are still owed on all four.**

**Task 1 — the barn roof was inverted, and also crashed.**
The brief's hypothesis was right and the derivation is in `docs/PLATFORM_NOTES.md`:
`side * -pitch` dropped both slopes toward the centre, making a valley, with
`RidgeCap` and `RidgeBeam` left floating at the height the ridge should have been.
Dropped the negation in the sheets and the rafters.

Found a second, worse bug in the same block: the roof called a local `rotated`
helper whose fifth parameter is `rollRadians: number`, passing `true`. That
reaches `CFrame.Angles(true, 0, 0)`, which throws — **the barn was failing to
build at all.** The helper had exactly one caller and the caller overwrote the
CFrame on the next line anyway, so it is gone.

Also, with the roof the right way up the two short walls became open holes into
the attic, so they now get stepped gable infill. The ridge runs along X, which
means the door wall is an **eave**, not a gable — there is no triangle above the
door to hang a sign in, and the fascia was floating 1.1m above the eave line on
nothing. It now stands proud of the eave on two braced brackets. `eaveOverhangMetres`
lengthens the sheets past the wall so water runs off rather than down the panels.

New pure `PoleBarn.roofline(cfg)` and `PoleBarn.roofHeightAt(cfg, z)` derive every
roof number without a running Roblox, and `OverworldSpec` asserts the ridge is the
high point from there. That is deliberately the substitute for the screenshot.

**Task 2 — foliage footprints.**
`insideExclusion` tested the trunk's centre point with no allowance for the
instance's own size, so a pine one metre outside the barn rect put three metres of
crown through the wall. Added `Foliage.footprintRadius(layer)`, which reads the
layer's own dimensions, and padded the circle test, the rect test and the trail
clearance by it.

The shape coefficients are now hoisted and **shared with the builders** rather
than duplicated — the padding is only correct while it matches the geometry that
actually gets drawn, and two copies of "the bottom canopy tier is 6.1 trunk
diameters wide" would drift the first time someone retuned a tree.

The six gates had no exclusion at all; they have one now. The rejection sampler's
attempt cap was a hardcoded 12, which with padding would have under-placed
silently — it is `scatter.placementAttempts` (40) now, layer counts are raised to
compensate, and `Foliage.scatter` returns a per-layer report so a crowded-out
layer gets logged instead of just looking like a thin forest.

**Task 3 — marker viewmodel.**
Both bugs in the brief confirmed. `Hopper` and `AirTank` were both `shape: "Ball"`,
so a hopper and an air tank rendered as two spheres. They are cylinders with
explicit rotations now, which required teaching the data-driven piece list about
`rotationDeg` at all.

`offsetStuds` is genuinely in studs while every other length in the file is metres
through `Units.vectorToStuds`; retuned it against the real model extents and left
a note at both ends stating the unit, because the mixed convention will bite again.
Added `tiltDegrees` — the cant walks the (genuinely large) hopper off the crosshair
and yaws the muzzle back toward it.

Barrel is a rear section, a ported shroud and a visible bore instead of one smooth
tube. The three archetypes now carry their own hardware via `markerModels[].pieces`
and `.hide`, layered over the shared list: a bolt handle and valve tube on the
mechanical, a board rail and eye covers on the squared electronic, and a sliding
forend on twin rods for the pump — which is the whole archetype.

**Task 4 — shop interior.**
Empty shelves were why the bays read as storage. Stock is `barn.bays[].shelfProps`
in the data, built by a switch mirroring `buildProp` in `Overworld.luau`. Nineteen
prop kinds; `PoleBarn.handlesProp` makes the set authoritative so a typo fails a
spec instead of silently building nothing. Pegboard behind each counter, shelves
moved forward to clear it, counter dressing, chalk price lists, corkboards, a
clock, extinguishers, and shop lights hung off the (now correct) rafters.

Folded the two existing inline `SurfaceGui` blocks into one `signFace` helper
rather than adding a third. Moved the bay signs up to 5.6m — they were intersecting
the top shelf.

### Owed

- Screenshots for all four tasks. Nothing here has been rendered.
- The `Enum.PartType` `Size` semantics this leans on are **not documented** on the
  pages that should carry them; the Cylinder-axis convention is corroborated only
  by two working call sites already in the repo. See `docs/PLATFORM_NOTES.md`.
- Foliage counts were raised by estimate. Check the `crowded out` warnings on
  first boot and retune from what actually placed.

---

## Verification

```
lune run tools/run-tests          # 377 specs, headless, ~4 min
lune run tools/run-tests Maps     # filter by spec file
rojo build default.project.json -o build/liveround.rbxl
lune run tools/ship-check         # pre-publish gate (currently FAILS by design)
```

Supporting tools:

| Tool | What it is for |
|---|---|
| `tools/sim` | Run headless matches. `--rounds true` prints the per-round breakdown, `--single 3` isolates one round. |
| `tools/tune-report` | Ballistics curve per marker. Run after touching `markers.json` or `ballistics.json`. |
| `tools/map-validate` | Nav-graph connectivity and nav nodes buried in cover. Run after any map edit. |
| `tools/nav-report` | Nav graph component breakdown, for diagnosing a disconnected map. |

---

## Session: free commerce, reactive camos and visual/QoL pass — 2026-09-07

**377 specs pass across 15 files (227.89 seconds).** Both default and demo Rojo
builds succeed. All 95 Luau files compile. Separate checks pass for the actual
persistent-profile adapter with mocked saves, live MatchService flow with mocked
engine boundaries, client UI/input/transactions, all nine marker/skin/camo
combinations, map construction and every navigation graph. Ship-check has one
expected failure: the pre-existing enabled development overrides. All commerce,
free-mode and content audits pass. No publishing or live purchase happened.

Read `docs/MONETIZATION.md` for product selection, free-mode controls, receipt
semantics, dependency provenance, copy review and later activation requirements.
The optional Paint Locker and Workshop Finishes collections grant real cosmetic
inventory for free. Every current equipment/consumable shop price is also zero;
earned-only items remain earned. Paid prompts are protected by two independent
flags and zero marketplace IDs. ProfileStore is bundled instead of depending on
the unavailable Wally binary; old saves reconcile without losing their contents.

Five new Yardline blowback markers provide teal, ochre, olive, cobalt and coral
colorways with varied feed, reload, capacity and velocity tradeoffs. The Aurum
view/world display now has a valid model fallback. Four reactive camos unlock at
10/35/75/150 server-confirmed headshots. Thresholds, replay-resistant live grants,
selection persistence, invalid-progress handling and actual projectile-based
mask classification are covered by tests. Paint/marker finish grants are visible
in tracers, splats and the first-person model.

Map graphics now match their settings: tournament stripes only on Speedball,
industrial/desert markings on Dustline and Urban, trail/landmark dressing and
perimeter silhouettes on Woods/Holdfast. Collision and navigation geometry are
preserved. Hub foliage retains 852 plants / 2756 parts but reduces shadow casters
from 2756 to 1496; small foliage receives no touches. Constructed map totals
(including venue and one avatar): Speedball 401, Dustline 159, Urban 145, Woods
264, Holdfast 346 parts. These are structural counts, not measured frame rates.

HUD, shop and dialogue now use consistent readable panels, scrolling content,
free/earned labels, ammo/camo progress and calmer feedback. Input releases held
fire on focus loss and blocks combat behind menus. Range raycasts/readouts run
at 10 Hz. Startup requests a session snapshot and arrives in the hub rather than
auto-starting a match. Camo unlock messages no longer refill predicted ammo.

Fixed undefined HUD labels, skipped first-round warmup, hub teleport on every
respawn, stale delayed hub returns, broken forward references in NPC mode
routing, and match duration counting only the final round. The unsupported Horde
request now reports preparation status instead of silently launching Gauntlet.
Live Horde/CTF/bosses/Range and consumable effects remain pre-existing gaps.

Studio is installed, but this update has not been visually playtested. Published
DataStore/Marketplace behavior requires live validation before monetization is
activated. Current Studio/demo sessions intentionally use temporary progress.

---

## Session: campaign, NPCs, two maps, CTF, horde, bosses

New agents should read `docs/AGENT_HANDOFF.md` first — it holds the durable
state, the enforced constraints, and the honest list of what is unverified.

**343 specs pass.** Twelve spec files. `rojo build` succeeds.

### The campaign
Ten chapters, `walkOn` → `aurum`, in `Data/progression.json`, resolved by
`Progression/Campaign.luau`. Strictly linear — prerequisites are enforced, so
clearing pro first does not skip the chain. Every gate is a skill gate.

The end of it is the **Aurum Kompressor**: a gold pump marker, twelve-round
hopper, one shot per manual cycle, highest payout multiplier in the game. It
abbreviates to AK, which preserves the joke, and it is deliberately the *hardest*
marker on the field — the ultimate reward in an aim trainer cannot be an aim
upgrade, so it is a statement that you do not need one.

### Six people at The Landing
`Data/npcs.json`: Marge (owns the field), Tildy (chrono and the fun stuff),
Wheels (marker tech), Coach Ruiz (the Range), Denny (rec league, delighted to be
here), and the Marshal (never speaks, unlocks horde by holding a gate open).
37 dialogue nodes with campaign-state gating. `Dialogue/DialogueTree.luau` is a
pure engine; `DialogueService` runs it server-side so a client cannot talk its
way into an unlocked chapter.

### Two new maps
- **Dustline** — desert freight yard. Tactical shells, jackknifed semi trailers,
  three gutted school buses, shipping containers, all at hard angles to each
  other. Teaches crosshair placement: too many corners to hold, so you learn to
  pre-aim the one that matters. Band 21 m.
- **Holdfast** — the big one. 150×200 m wooded valley with a timber keep at each
  end: walls with crenellations, wall-walks, corner towers, a gate, and a
  footbridge over the hollow between them. Longest lane in the game at 111 m.
  Band 52 m. Built for CTF.

Curriculum re-threaded to stay monotonic by engagement distance: Speedball 16 →
Dustline 21 → Urban 27 → Woods 44 → Holdfast 52. A `yardSale` chapter was
inserted for Dustline, and unlock chains follow the same order.

### Three modes
- **Gauntlet** — the five fixed rounds. Always open.
- **Horde** — `Match/Endless.luau`. Waves scale by bodies, tier and comms speed;
  breather every 5th, marshal every 7th. Veterancy past pro is clamped at 120 ms
  reaction and 0.45° error, so no wave ever produces a bot a human could not be.
  Locked behind `proCircuit`.
- **Capture the flag** — `Match/CaptureTheFlag.luau`. Solo runner against a squad
  that must split between defending and attacking; the split shifts with the
  score, and reading that shift is the mode. Locked behind `backForty`.

### Bosses without a health bar
`Match/Boss.luau`. Marshals are padded head to foot — paint on the body does
nothing. Only the **hopper** counts: 18 cm across, at hopper height, exposed only
when they lean out to shoot. Still one hit, just a very small one, which turns
the boss fight into a precision test. Four marshals, escorted, cycling in horde.

### Kit
`Data/consumables.json` — paint grenades (a real thing scenario players throw),
smoke that blocks sight both ways, the Spotter Drone, Emberfill and Chillfill,
pod patches, a squeegee, and the Marshal's Whistle. Two carry slots.
`Data/gear.json` gained helmets and shoulder rigs.

Red and gold kit **cannot be bought at any price** — it drops from marshals and
deep horde waves, so nobody spends their way past the part where they get good.

### Enforcement added
- `Shared/GearStats.luau` and `Shared/Consumables.luau` both carry an
  `ALLOWED_FIELDS` list and an `audit()`. Anything outside it fails the specs,
  `Shop.assertNoPayToWin()` at boot, and `tools/ship-check`.
- Specs grep every gear, consumable and boss field name for `armour`, `damage`,
  `health`, `spread`, `velocity`, `accuracy`, `recoil`.
- `tools/fix-nav-nodes.py` is now a checked-in authoring tool rather than a
  scratch script.

---

## Session: the overworld, the barn, the board

### The Landing

A woodsy hub you actually walk around, built from `Data/overworld.json` by
`World/Overworld.luau`. Spawn in it, walk a trail to a gate to play, walk to the
barn to spend, come back to it when a match ends.

It exists for a specific reason. This game is a deliberate meat grinder — you are
*meant* to lose repeatedly — and a grinder with no let-up is just unpleasant. The
walk back from a bad match is the only pacing device the design has, so it is
quiet, it is slow, and there is nothing in it to fight.

- 190 m square: clearing, gravel spine trail, dirt side trails, creek with a
  plank footbridge, pond with a dock and a canoe, firepit and picnic tables.
- Four signed trailhead gates — Speedball, Urban, Woods, and the Range.
- `World/Foliage.luau` scatters ~940 trees, saplings, ferns, rocks, deadfall and
  cattails, **deterministically**. Same seed, same forest, every server and every
  restart. The hub is somewhere you learn — "the board is past the big leaning
  pine" — and a forest that reshuffles on load is scenery, not a place.
- Placement is rejection-sampled against trail segments and exclusion zones, so
  nothing ever grows on a path. There is a spec that walks every trail at one-metre
  resolution and asserts it.
- Its own lighting profile: dimmer, warmer, hazier than any field. Late afternoon
  under a canopy.
- Ambience emitters are placed and configured but have **no sound ids** — audio is
  uploaded per experience and hardcoding someone else's id ships a broken build.
  Drop ids into `Data/overworld.json` and they play.

### Parsons Field Supply

`World/PoleBarn.luau`. Built the way a real pole barn is: posts on a gravel
apron, girts spanning between them, corrugated sheet metal hung outside with
mismatched rusted panels, a gable roof on exposed rafters and collar ties, and a
rolling door parked open above the header. Three bays across the back wall, each
with a counter, shelving, a hanging work light and a prompt:

| Bay | Stocks |
|---|---|
| **MARKERS** | markers, barrels |
| **PAINT & AIR** | hoppers, tanks, pods, paint colours |
| **PROTECTIVE** | jerseys, pads, masks, marker skins |

The counter you stand at decides what you can buy — the bay list is server-side,
so a client asking the markers counter for a jersey is refused, not trusted.

### Two changes from what was asked, and why

1. **"Armor upgrades" became PROTECTIVE, with no damage stat.** One hit is out,
   always. That is the paintball rule, the content-rating constraint and the
   entire difficulty design at once. Jerseys and pads instead trade *noise*
   against *mobility*: a padded jersey and full wrap put you at 0.63× hearing
   radius and cost you sprint and crouch speed, which is a real decision and is
   not an aim upgrade.
2. **"Weapon upgrades" became MARKERS.** Firearm terminology is a hard rating
   constraint in `CLAUDE.md`.

`Shared/GearStats.luau` is the single place a loadout resolves into multipliers,
and it carries `ALLOWED_FIELDS` — the complete set of axes gear may touch. Any
item declaring anything else fails `GearStats.audit()`, which runs in the specs,
in `Shop.assertNoPayToWin` at server boot, and in `tools/ship-check`. There is
also a spec that greps every gear field name for "armour", "damage", "spread",
"velocity", "accuracy" and "recoil" and fails if any of them appear.

### Leaderboard

`Leaderboard/Leaderboard.luau` plus `World/NoticeBoard.luau`.

A *time* means one specific thing: **all five rounds of a map cleared in a single
match**, timed by the server's own round clock. A partial clear is not a time and
never reaches the board.

- OrderedDataStore per map, value in centiseconds, sorted ascending. Run metadata
  (tier, marker, deaths) lives in a companion DataStore, since OrderedDataStore
  only holds numbers.
- Submissions are gated hard: all rounds cleared, elimination count matching what
  the schedule should have produced (20 for a five-round match), a per-round time
  floor, a maximum, and a NaN check. Every rejection logs its reason.
- Writes only on a personal best, so DataStore calls scale with records rather
  than with matches played.
- **Dev runs are quarantined onto separate keys.** Testing with infinite money
  and skipped rounds can never touch the real board — a leaderboard is the one
  place in this game where a bad number is permanent.
- Times are **not** normalised by tier. A rec clear and a pro clear sit on the
  same board with the tier shown beside the name, because the interesting
  question is not "who is fastest" but "who was fastest against what".
- In-world it is a covered timber notice board beside the main trail that cycles
  a page per map plus a personal-bests page. Cycling on a timer rather than on
  input is deliberate: a board you have to operate is a board nobody reads.

---

## Session: five rounds, inflatables, dev money

### Matches are now five rounds

A match is five rounds and the field fills up as you go — two bots in round 1,
the full six by round 5, with the tier stepping up for the last two. Schedule
lives in `Data/match.json` under `rounds`; `Match/RoundSchedule.luau` resolves
it. Both `SimMatch` and the live `MatchService` run the same structure.

| Round | Bots | Tier | Payout share |
|---|---|---|---|
| 1 | 2 | selected | 0.5 |
| 2 | 3 | selected | 0.7 |
| 3 | 4 | selected | 1.0 |
| 4 | 5 | +1 step | 1.4 |
| 5 | 6 | +1 step | 2.0 |

Two design choices worth stating:

- **Deaths accumulate across all five rounds and are charged once, at the end.**
  Dying cheaply in round 1 to learn the angles still costs you round 5's money.
  Without this the escalation would just be free practice.
- **Failing a round ends the match.** Respawns are unlimited, so failing means
  the clock beat you; walking the player into the next, larger round after that
  would hand out the escalation for nothing.

Round 3 is the control round — four bots, no tier offset — and it is what the
tier-curve specs measure against, since rounds 4 and 5 escalate by design and
would collapse semipro and pro into the same fight.

Measured on Speedball with the calibrated `human` policy, round 3 only:

| Tier | Mean deaths |
|---|---|
| rec | 0.2 |
| amateur | 0.9 |
| semipro | 2.8 |
| pro | 4.4 |

Full five-round matches now genuinely fail at the top tiers (semipro clears
4.2/5 rounds, pro 3.9/5), which is the first time the difficulty target from
BUILD_PLAN has been observable rather than asserted.

### The field looks like a field

- `Match/Inflatables.luau` builds real speedball bunker shapes — can, dorito,
  snake, temple, brick — as rounded, seamed, strapped models with a vinyl sheen,
  instead of coloured boxes. All eleven Speedball pieces are now inflatables.
- **Collision contract:** each bunker gets one invisible collision box matching
  the oriented box in the map JSON, and every visual part is `CanCollide = false,
  CanQuery = false`. `MapGeometry` reasons about that same OBB for bot
  line-of-sight and the server's projectile sim, so player collision, bot vision
  and paint blocking remain one shape. The only discrepancy is the corner radius,
  ~0.25 m, always in the player's favour.
- `WorldBuilder` now maps each palette key to a real material — grass, sand,
  concrete, timber, slate, corroded metal — instead of uniform SmoothPlastic.
- `Match/Atmosphere.luau` applies per-map lighting from `maps_index.json`:
  Future technology, atmosphere haze, bloom, sun rays, colour correction, and a
  very weak depth of field. The haze is load-bearing rather than decorative — a
  70 m sightline in Woods has to *look* like 70 m or the player cannot judge the
  holdover it needs.
- Bot avatars rebuilt from rounded primitives: jersey, padded shoulders, full
  mask with a tinted lens that faces where the bot is looking, hopper, marker
  and barrel. The lens direction is deliberate — it lets the player read a bot's
  facing at a glance, which is what makes peeking a decision rather than a coin
  flip.

### Development overrides

`Data/dev.json`, gated through `Shared/Dev.luau`. **Currently ON:**
`infiniteCurrency` (99,999,999 FF, unspendable) and `unlockEverything`.

- Purchases still run every server-side check — ownership, category, and the
  server's own price lookup. Only the wallet is fake, so the shop code being
  exercised in dev is the code that ships.
- No dev flag can reach the payout maths. There is a spec asserting it, because
  the economy will eventually be tuned on those numbers and a flag touching them
  would make every measurement a lie.
- Every flag is off if the file is missing or malformed, and off unless the
  master `enabled` switch is also on.
- The server prints a loud banner at boot naming every active flag.
- `tools/ship-check` **fails while dev mode is on.** That is intended: it is the
  thing that stops this shipping by accident. Set `enabled: false` to clear it.

---

## Phase status

| Phase | State |
|---|---|
| 0 — Environment | **Partial.** See "Deviations" below. |
| 1 — Ballistics | Done. 23 specs. |
| 2 — Player and markers | Built; live behaviour unverified without Studio. |
| 3 — Telemetry | Done. 20 specs + the sim harness. |
| 4 — Bots | Done. 20 aim-model specs + sim curve. |
| 5 — Maps | Done. 38 specs. Now inflatable-built. |
| 6 — Economy | Done. 48 specs, including the five-round payout. |
| 7 — The Range | Done. 17 specs. |
| 8 — Tuning | Started. Round schedule tuned from sim data. |

Beyond the plan: the overworld hub, the three-bay pole barn, and the full-clear
leaderboard. None of these are in `BUILD_PLAN.md`; they were asked for directly.

---

## Deviations from BUILD_PLAN, and why

These are flagged rather than silently taken, per the editorial-authority clause
in `CLAUDE.md`.

1. **Phase 0 cannot fully pass on this machine.** Roblox Studio is not installed,
   so "a Rojo-synced script prints to the Studio output" is unverified. `rojo
   build` succeeds and the test suite runs from the shell.

2. **Wally cannot run here.** Its macOS binary is x86_64-only and this machine is
   Apple Silicon without Rosetta 2. `wally.toml` is written and correct;
   `Packages` paths in the project file are marked optional so the place builds
   without it. `Economy/Profile.luau` falls back to a loud in-memory store when
   ProfileStore is absent.

3. **TestEZ is superseded.** Roblox now uses jest-roblox. More to the point,
   neither runs headless without a Roblox runtime. `tools/Harness.luau` is a
   miniature Roblox module runtime on Lune — it builds the same instance tree
   Rojo does and implements `require(instance)` — so specs run genuinely headless
   from the shell. They are written in TestEZ's syntax and still run under TestEZ
   in Studio.

4. **"A body-width of lead at 40 m" is not achievable alongside "visible
   holdover".** Those two targets are inconsistent under Earth gravity: a body
   width of lead at 40 m implies ~400 m/s, at which drop is 5 cm and invisible.
   Holdover was chosen, since lead-and-drop prediction is the design thesis.
   Tuned result at 40 m: 66 cm of drop and 3.8 body widths of lead. At 10 m,
   3 cm and 0.8 body widths — negligible and small, as specified.

5. **Muzzle velocity is above real paintball.** 130 m/s versus a real field's
   300 fps (91 m/s). At real velocity a 40 m moving target is genuinely
   unhittable, and the game needs those engagements to be winnable. Documented
   in `markers.json`.

6. **"Monotonic win-rate decline across tiers" is not measurable as written.**
   Phase 1 also specifies unlimited free respawns, so before the round structure
   existed the player always eventually cleared and win rate was 100% at every
   tier by construction. Deaths per round were asserted instead. With five rounds
   this is now *partly* recoverable — rounds-cleared does decline at the top
   tiers — but deaths on the control round remain the cleaner signal.

7. **Low-poly / flat-shaded has been softened.** `CLAUDE.md` specifies flat
   shading; the inflatables are rounded, glossy and seamed, and surfaces now use
   real materials. The saturated palette and the silhouette-first rule are
   unchanged, and the rounding is what makes a bunker read as a bunker. Flagging
   it as a deliberate departure from the brief rather than drift.

---

## Known gaps

- Nothing in `src/StarterPlayer/Client/` or `Match/MatchService.luau` has been
  run. They are structurally sound and the place builds, but every live-runtime
  behaviour — first-person feel, the HUD holdover ladder, the round banner, hit
  registration against a real character — is unverified.
- Engagement distances under the benchmark policy run long against the declared
  bands (Speedball median 27 m against a 16 m target). The policy is a
  stop-and-shoot sniper; a movement-heavier policy would bring it down. Revisit
  in Phase 8.
- `Sim.spec` takes ~3.5 minutes. It is the slowest thing in the suite by far.
- The hub is unrendered and unwalked. Trail widths, gate placement, how long the
  walk from spawn to the barn actually feels, and whether ~940 scattered models
  cost too much on a low-end device are all guesses until someone loads it.
- Ambience has no audio assets. See above — that is deliberate, not unfinished.
- The Range gate is signed and standing but returns a "not yet" notice; the live
  drill binding is still sim-only.
