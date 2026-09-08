# PROGRESS

Updated at the end of every session, per `BUILD_PLAN.md`.

---

## Session — publish preparation, 2026-09-07

**Not cleared for public release.** Start with [PUBLISH_READINESS.md](PUBLISH_READINESS.md).
The handoffs were checked against current source; several claims were stale.

User decisions: solo Gauntlet for first release, current map sizes retained,
Shoothouse/Horde/CTF deferred, and the full campaign converted to Gauntlet goals.
Dev overrides are disabled. The Marshal requires pro Speedball, The Long
Afternoon a flawless semi-pro sweep, and Aurum a flawless pro sweep across the
four campaign fields. Gates now select the current campaign tier instead of
always rec. Former course camos require 250/500/1000 confirmed mask hits.
Field kit has no live activation and is now a non-claimable coming-later preview.

ProfileStore was already vendored and live missing-dependency fallback refused.
Added actual DataStore access verification and late-session departure cleanup.
New adapter checks cover unavailable access, session reuse/release and departure
with a fake backend. Studio remains intentionally non-persistent.

Controller slide/lean, explicit menu selection/navigation and high-priority B
close handling are implemented. HUD uses safe insets with a separate centered
aiming layer. Payout labels grow when wrapping. These changes compile but have
not been tested with Studio's renderer or Controller Emulator.

Verification:

- Full default Rojo place builds: `/tmp/paintball-release.rbxlx`.
- `ship-check`, live-service checks and new profile-adapter checks pass.
- 90 source/spec Luau files syntax-compile; this is not static type checking.
- The second complete suite reported 439 passed / 2 failed in 390.05 seconds.
  One failure was the old hardcoded six-spawn assertion, corrected while that
  run was in flight; its targeted rerun passes against all five authored maps.
  All 16 non-Sim spec files were then rerun against final files: **421 passed,
  zero failed**. The corrected spawn assertion also passes separately.
- **The trading/holding acceptance remains failing:** both policies average
  5.33 eliminations over six Speedball semi-pro seeds. No assertion was relaxed.
  Simulator reload completion was also impossible; fixed with a no-respawn
  regression. The trading tie persists after the fix. The simulator lacks the
  live player's spread model, limiting its usefulness for balance tuning.
- Foliage constructs 1559 models / 8069 parts, 5784 casting shadows and 2285
  with shadows off. These are structural counts, not frame times. Streaming
  remains off pending measured rendering performance.

Outstanding: balance/simulation parity, rendered full-match and controller/UI
acceptance, published save/rejoin/shutdown validation, performance measurements,
and actual place settings/questionnaire. No Studio playtest, public upload,
questionnaire submission or published-setting change was performed.

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

## Session — characters, spawns, FOV, and map flow

### The hub was standing inside every match

Interactable NPCs mid-round were a symptom, not the bug. Maps are built at the
world origin and The Landing is 190x190m **there** — so the field was being
assembled *inside* the hub. Holdfast is 150x200m and overlapped it almost
completely. Marge and Tildy were never "in the match"; the match was being built
on top of them, along with the barn, the pond, the trails and 900-odd trees.

`Hub.park()` / `Hub.restore()` move the root model to ServerStorage for the
duration. One Parent write, so every prompt and connection survives.

### Everyone spawns on the ground

Three maps started bots on rooftops (8.8m, 11m, 13m) — read as spawning in the
sky. All 15 elevated bot spawns were relocated to ground positions found by the
new `tools/ground-spawns`, and `MapGeometry.groundPoint` now drops every spawn
onto whatever actually supports it at runtime. Worst case is now "on the roof of
the thing under you", never "in the air".

### FOV 92 -> 78

At 92 a player-sized target at 40m — the range this whole game is about — was too
small to read. The fix for that is magnification, not a bigger hitbox. Targets are
~18% larger; the HUD scales off `camera.FieldOfView` so the crosshair and holdover
marks followed automatically.

### Characters

New `World/Wardrobe.luau` + `Data/wardrobe.json`: 45 pieces, 11 outfits, one
shared body with **arms** (a torso with no arms reads as a bollard at 40m, which
is a problem in a game about reading a silhouette at 40m). Both the hub people and
the enemy team dress from it.

Outfits are written against each character's `voice` field, so the clothes are the
same joke as the dialogue:

| | |
|---|---|
| Denny | Bump helmet, night vision flipped **down**, in daylight, for rec league. 53 parts. |
| The Marshal | A white armband. Nothing else. 9 parts. |
| Marge | Flannel, apron, readers on her head, clipboard. The only person dressed for a job. |
| Tildy | Goggles up, headphones down, a bandolier of pods she does not need. |
| Wheels | Coveralls, thigh tool roll, headlamp on in daylight, one boot untied. |
| Coach Ruiz | The nineties jersey, whistle, backwards cap, one knee brace older than the knee. |

Enemy kit escalates with tier — rec 13 parts of rental gear, pro 54 with the NVG
mount worn unused. A squad's difficulty is now readable before anyone fires.

`Instance` was added to the harness globals, so world builders are runnable
headlessly for the first time; `tools/check-characters` constructs every person in
the game and counts the result.

### Map flow

New `tools/flow-report` (spawn sight, worst clear lane standing **and** crouched,
distance to cover, reachability) and `tools/probe-map` (engagements and median for
one map, fast enough to A/B a single piece of geometry).

**What worked: spawn sight is now 0 on all five maps.** Three of them let an enemy
spawn see the player the moment they arrived -- dustline 65m, holdfast 78m, woods
89m. That is an enemy you cannot resolve shooting at you before you have moved,
and it was most of the "enemies are hard to see at range" complaint.

**What did not work: nearly everything else I tried.** Sixteen pieces of cover
were added to bring each map's longest lane inside its declared band. A/B measured
with `tools/probe-map`, per map, engagements over three seeds:

| map | before | after | median | verdict |
|---|---|---|---|---|
| urban | 29 | **0** | -- | reverted, all three pieces |
| speedball | 60 | 19 | 31.0 -> 31.1 | reverted, all three pieces |
| dustline | 51 | 29 | 12.7 -> 15.3 | reverted six of seven |
| woods | 48 | 48 | 56.3 -> 59.5 | kept |

Urban went to **zero engagements** -- a map that produces no fights is broken, and
a 16% band overshoot is a tuning note. Speedball lost 68% of its engagements and
its median did not move at all (31.0 -> 31.1), which is the clearest possible
evidence that lane length was not what was driving it. The whole exercise also
failed five specs in `Sim` and `Match` -- rounds stopped completing -- which is
how the damage surfaced.

What survives is the three spawn screens plus woods' and holdfast's cover, all of
which cost nothing measurable. Dustline's screen was then resized from 16m to 7m:
same spawn-sight fix, 6 engagements lost instead of 22.

**One finding was mine, not the map's.** The tool flagged speedball's snake wire
as a 43.8m open lane and I built two bunkers on it before reading the numbers
properly. A snake tops out at 1.30m against a 1.32m eye line: you *can* see down
the wire standing, and that is the entire point of a snake. Reverted, and the tool
now reports standing and crouched separately so "this map wants you low" stops
looking like "this map is empty".

`engagementBand` now drives bot posture rather than only documenting an
aspiration -- but posture barely moves the median either, for the same reason
geometry did not: engagement distance is decided by when line of sight first
exists, not by how eagerly anyone pushes. Every `postureBias` is still 1.0.

### Owed

- Still nothing rendered. All of it is arithmetic and headless construction.
- Speedball (36.0 vs 34) and dustline (49.3 vs 46) remain a few metres over band.
- Holdfast produces zero sim engagements — the sim never fights there. Real gap.
- Per-map `postureBias` is still 1.0 everywhere; posture alone barely moved the
  median, because engagement distance is decided by when line of sight first
  exists, not by how eagerly bots push. Geometry is the lever, and now measurable.

---

## Session — textures, characters that walk, and the shimmering ground

### The ground was fighting itself in seven places

"One texture placed inside another" while moving is z-fighting: two faces on the
same plane have no stable depth winner, so the renderer picks a different one per
pixel per frame. Invisible in a screenshot, unmissable in motion.

`tools/check-zfight` builds the hub and all five maps and finds coplanar
overlapping surfaces arithmetically. It found **168 in The Landing and 9 across
the maps**. All of them are fixed; the sweep now reports zero everywhere.

Causes, in order of how much ground they covered:

- Every hub trail segment was built at exactly y = 0.14, and segments overlap on
  purpose so bends do not notch. Every bend and every junction was a pair of
  identical planes.
- `hollow` on Woods and `hollow_mid` on Holdfast had their tops at exactly the
  ground slab's top -- 246 and 382 studs of shimmer through the middle of the two
  biggest maps.
- In-match ground markings (`FreightLane`, `MarketStreet`, `TimberTrail`) had the
  same overlapping-segment problem as the hub trails.

`Shared/Surfaces` now owns the fix for all of them. The obvious approach -- give
path N a lift of N steps -- fails in both directions, and both failures happened
here first: stacking upward puts a kerb across every junction, and sinking
downward eventually pushes a path below the ground it is drawn on. Only paths
that actually touch need to differ, so it is a greedy graph colouring. Three
levels covers every map in the game.

The detector needed three corrections of its own before it could be trusted:
oriented-box overlap rather than axis-aligned (the bridge's fourteen planks have
a real 11cm gap, but the deck is turned 8 degrees and the AABB version called all
fourteen broken), skipping parts that are not level (it was reporting the barn's
two roof panels as fighting where they simply meet at the ridge), and top faces
only, since a buried face cannot shimmer.

### Two bugs the sweep exposed on its own

- **The harness ran spawned threads inline.** `task.spawn` called the function
  directly, so `while running do ... task.wait() end` -- which is how NoticeBoard
  cycles the leaderboard pages -- never yielded and span forever. The first
  headless hub build wrote a **679MB log**. Spawned functions run on coroutines
  now and `wait` yields them, which is what the engine does.
- **A DataStore failure logged on every cycle, forever.** That was most of the
  679MB. Warn once per board, clear the latch on recovery.

### Characters walk now

Legs were a single box across both of them, which cannot take a stride, so bots
could only slide -- and a body that slides reads as a prop no matter how good the
kit on it is. Legs are per-side, and the walk cycle advances with **distance
travelled** rather than with the clock, so the feet land where the ground says
and a bot that stops mid-step stops mid-step. Arms counter-swing; the body bobs
at double frequency, because there are two footfalls per cycle.

The swing is translation, not joint rotation: these are box limbs with no knees,
and rotating them about a hip would shear them. Boots and knee pads take sided
anchors automatically -- any worn part whose name ends in L or R -- so kit travels
with the leg it is on.

`tools/check-gait` verifies the two properties that matter: zero movement when
standing (a clock-driven cycle marches on the spot) and 100% antiphase when
walking (legs swinging together is a hop, not a walk).

### Speedball looks like speedball

The centre bunker was a "temple" -- four-sided, heavily rounded corners, domed
top -- and at distance it read as a turret. The vocabulary is simple shapes now:
CAN, DORITO, SNAKE, BRICK lying down, STANDUP upright, and BALL. The ball is a
pressurised sphere with welded panel seams, squashed where it meets the ground; a
sphere on a perfect tangent looks like it is hovering. The standup is a welded
pillow with bulged faces, because without the bulge it is a flat board.

### Trees are not blobs

The comment claimed the canopy was "cones built from cylinders with a scaled
top". No such thing exists -- a Roblox Cylinder cannot taper -- so it was three
drums, a gap, and a ball. A conifer is a seven-tier stepped spire on a
three-section tapered trunk with a root flare, plus a new broadleaf with five
overlapping lobes, plus domed moss patches. Domed on purpose: a flat patch on the
floor is coplanar with it.

### Also

- Woods' timber stands came down from 12.7m decks to 7.7m. Engagements went up.
- Text scales with the viewport instead of being fixed pixels; fonts resolve by
  name from data through `Shared/Fonts`, with the leaderboard on a monospace face
  so its columns line up.
- **Cattails had been placing zero, all along** -- their annulus sits inside the
  pond exclusion. The per-layer shortfall report is what surfaced it.
- A failure in `Atmosphere` used to discard the entire built map: it ran before
  `root.Parent = parent`. Cosmetics can no longer take the field down with them.

### Owed

- Still nothing rendered. Every fix in this session is arithmetic or headless
  construction.
- Foliage is 8069 parts for 1559 instances. Fine for a solo hub, worth watching.
- **Engagement medians miss their bands on every map, and now the cause is
  known.** Both benchmark policies return `move = nil` the instant they acquire
  a target -- they plant and fire from wherever first contact happened. So the
  number the sim reports is the distance at which the player first SEES a bot,
  which is a property of sightlines and spawn separation and not of the fight the
  map is trying to produce. Two rounds of geometry and one of bot posture were
  spent on that number before this was understood; none moved it and all three
  were reverted. The fix is to keep closing while engaging in BOTH policies --
  they duplicate their decide loops, so editing one does nothing, which cost an
  hour on its own. Not done here: it moves every difficulty measurement at once.
- `Sim > puts Urban between the two` fails, and the reason is worth stating
  plainly. It asserts Urban's median exceeds Speedball's. It passed before only
  because Urban started two bots on rooftops, which inflated its first-contact
  distances; grounding those spawns -- which was the point -- removed the
  inflation. The real anomaly is Speedball at 29m against a 16m target, and that
  measured 28.99m before anything in this session was touched. Urban's back
  spawns were moved to z=34, taking it from 29 engagements at 24.0m to 34 at
  26.9m against a target of 27, which is the closest any map now sits to its own
  band. It still does not exceed Speedball, because Speedball is the broken one.

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

---

## The Shoothouse, and the modes that are still dead code (2026-09-07)

### What was wrong

The Shoothouse shipped as ~600 lines across `Course.luau`, `Courses.luau`,
`CourseProgress.luau`, `Data/course.json` and 30 passing specs — and was
**unreachable from an actual match**. Nothing in `Bootstrap` or `MatchService`
referenced any of it, and `Bootstrap.requestMatch` refused every mode that was
not `gauntlet` outright. An external review caught it, correctly, as the
headline defect of that commit.

It had a second-order consequence that is worth remembering, because it is the
kind of bug that unit tests structurally cannot see: `Shared/Camos.luau` had
already been wired to gate three finishes on course gold medals. Since no course
could be played, `data.courseRecords` was never written, so those three camos
were **permanently unobtainable** while the wardrobe cheerfully displayed
"3 more gold medals on the Shoothouse" for a mode that did not exist.

Thirty green assertions and a mode a player can never reach. `docs/DEBUG_REVIEW.md`
already flagged this exact risk: *passing headless tests does not establish that
the game works.*

### How it is wired now

The mode is expressed as **a schedule, not a second match loop**. A course is
flattened into the same round shape the gauntlet uses — each stage's cover
refills `wavesPerStage` times, so a four-stage course becomes eight rounds, each
carrying the anchors its defenders hold and the checkpoint the player respawns
on. Everything below that line — firing, hit validation, lag compensation,
telemetry, respawn — is one engine serving both modes, so a fix to the gauntlet
is a fix to the course and the two cannot drift.

Five touchpoints, and no more than five deliberately:

| Concern | Gauntlet | Shoothouse |
|---|---|---|
| Schedule | `RoundSchedule.all` | `Course.all`, flattened by wave |
| Bot spawns | `world.botSpawns`, cycled | the stage's own anchors |
| Player respawn | furthest respawn from the squad | the stage checkpoint |
| Intermission | 7 s | 0 — the clock never stops |
| Payout | `Payout.computeMatch` | `CourseProgress.record`, by medal |

A player reaches it from the same trailhead post: hold **F** for the five
rounds, hold **E** for the timed course. That is the only place a mode choice
can live in a game with no lobby, and this project does not have one on purpose.

### The check that would have caught it

`tools/run-live-checks` now runs a whole course through `MatchService` exactly as
a player does — 28 defenders over 4 stages — and asserts the record is written,
that defenders start on the anchors their stage names, and that a course clear
never counts as a gauntlet clear. The unit specs call `Course` directly and
always did; this one goes through the front door.

### Still dead code

**Horde and Capture the Flag remain unwired.** `Endless.luau` and
`CaptureTheFlag.luau` are pure, spec-covered rules modules that no match ever
starts, exactly as the Shoothouse was. `Bootstrap.asMode` now names the modes
that actually have a match loop and refuses the rest, so requesting Horde gets an
honest "still in field preparation" instead of silently running a gauntlet. Do
not add a fourth until one of those two is finished.

## Fields at 88%, and the probe that was only ever run on one map

Dustline, Urban, Woods and Holdfast were scaled to 88% of their footprint —
positions **and** plan-view sizes together, Y untouched. Scaling positions alone
was tried first and was wrong: it left cover at full size in a smaller field,
which pushed nav nodes into buildings and disconnected the nav graphs on Dustline
and Holdfast. Y is left alone because heights carry tuned see-over relationships
(a snake tops at 1.30 m against a 1.32 m crouched eye line) and shrinking them
would retune the game without saying so.

`navLinkRadiusMetres` is deliberately **not** scaled: it is a three-dimensional
reach and the rescale was horizontal only, so scaling it dropped tower and roof
nodes out of range and disconnected Holdfast outright.

**Speedball was not rescaled at all.** It is already the smallest field and the
only one built as a knife fight, and its core property — trading punished harder
than holding an angle — does not survive being shrunk while the squad doubles.
Measured at squad size 12: full size `+3.33`, 95% `-1.67` (trading becomes
*safer*, inverting the map), 88% `+0.00` (the two policies stop differing at
all).

That measurement was the hole. `tools/probe-trading` was hardcoded to Speedball,
so one map was measured and the resulting number was applied to four that were
not. It now walks the whole curriculum and fails non-zero on any field that does
not punish trading.

Running it across all five, and against the pre-rescale baseline where a field
had regressed:

| Field | Scale | Trading gap | Baseline | Verdict |
|---|---|---|---|---|
| Speedball | 100% | **+2.50** | — | never rescaled; see above |
| Dustline | 88% | −3.17 | **−7.83** | pre-existing failure, *improved* by the rescale |
| Urban | 100% | **+1.50** | +2.67 at full size, −0.33 at 88% | **rescale reverted** |
| Woods | 88% | **+5.17** | — | fine |
| Holdfast | 88% | 0.00 / 0.00 | — | degenerate: see below |

Two conclusions, both of which needed the baseline column to be honest about:

- **Urban was a genuine regression and is reverted.** At full size it punishes
  trading by +2.67; at 88% that inverts to −0.33, meaning trading became
  marginally *safer* than holding an angle. Two of five fields turn out not to
  survive a shrink while the squad doubles, and they are the two shortest.
- **Dustline's failure is not from the rescale.** It measured −7.83 before any
  of this and −3.17 after, so the shrink made it less wrong, not more. It is a
  standing problem with that field and predates this work; do not "fix" it by
  reverting a scale change that helped.

**Holdfast returns zero deaths for both policies**, which is not a pass — it is
the probe finding nothing to measure. Round 3 on a 132x176 m field with the
benchmark policy produces no player deaths at all, so the control round is
vacuous there. That is the same root cause as the long-standing note about
engagement distances: both sim policies plant on first contact (`move = nil`),
so on a large field they simply never meet. Fixing that moves every difficulty
measurement at once and is still deliberately deferred.

## Bugs found on the way

- **Three palette keys were never declared.** `brush`, `stone` and
  `containerRust` were used by Woods, Holdfast and Dustline but appeared in
  neither `maps_index.palette` nor `WorldBuilder.SURFACE`, so every thicket,
  copse, outcrop and rusted screen rendered as concrete-grey smooth plastic.
  Woods and Holdfast were drawing their treelines as pale grey boxes.
- **`tools/run-live-checks` had been silently broken** since the harness began
  injecting a real `Instance`: it stubbed `WorldBuilder.build` with a plain
  table, and `MatchService` parents its bot folder to whatever that returns.
- **`tools/check-client-ui` had been dead** since `Hud` started requiring
  `UiNavigation`, which the tool never stubbed. It also needed
  `GetPropertyChangedSignal`, `BindActionAtPriority`, a `Destroying` signal and
  proxy-unwrapping on `NextSelection*` — gamepad focus wiring assigns Instance
  refs to properties the stub only handled for `Parent`.
- **Two specs pinned the squad size at 6** rather than reading it, so doubling
  the squad failed them. They read `match.squadSize` now.


## What MaxPlayers = 2 and a second mode quietly broke

Shipping the Shoothouse turned up three things that were correct while the game
had one mode and one seat, and became wrong the moment it had two.

- **The leaderboard was keyed by map alone.** A course time would have
  overwritten the gauntlet personal best on the same field and outranked every
  entry on it -- a course is 28 defenders and a gauntlet is 40 over five rounds,
  so ranking them together is meaningless. Submissions carry their mode now and
  gauntlet keeps the bare map key, so no stored time is orphaned.
- **Bootstrap kicked the second player.** `soloPlayer` admitted exactly one and
  kicked anyone else with "this demo is a solo field", which was right at
  MaxPlayers = 1 and made MaxPlayers = 2 meaningless. The seat limit now comes
  from the largest `maxPlayers` among integrated modes.
- **Two matches would have collided.** Every map is built at the WORLD ORIGIN and
  `Hub.park` is global, so two concurrent matches would stack two maps on top of
  each other and park the hub out from under whoever stayed behind. That was
  unreachable at one seat. `requestMatch` refuses a second concurrent match until
  the shared-match plumbing exists.

## Speedball fields twelve from six spawns

Every other field has twelve authored bot spawns. Speedball has six, and this is
the most-measured decision in the project.

Twelve spawn points were tried twice. Extras placed in the defenders' half put
four of them at midfield and inverted how the map punishes trading, from +3.33
to -0.83 -- trading became *safer* than holding an angle on the one field built
as a knife fight. Extras crowded into the back third fixed that (+2.50) and
flattened the top of the difficulty curve instead: semipro cost 7.50 deaths
against pro's 6.17, so pro came out easier than semipro.

With the six authored spawns, both hold: trading +0.67, and deaths rise 1.00 /
2.33 / 6.50 / 8.17 across the tiers. `MatchService` fans reused spawns onto a
small deterministic ring so a twelve-bot round does not open as a pile of bodies
at six points, and `run-live-checks` asserts per round that no two bots start
within a metre of each other.

The invariant that used to be asserted -- one authored spawn per bot -- was
therefore wrong, and it was asserted in three places (`Maps.spec`, `Sim.spec`,
`ship-check`). All three now assert what actually has to hold: at least six
spawns, and no more than two bots to a spawn.


## Known divergence: the sim still stacks bots at spawn

`SimMatch.runRound` places bots with a plain `((i - 1) % #botSpawns) + 1`, which
is what `MatchService` used to do. `MatchService` now fans reused spawns onto a
small ring so a twelve-bot round does not open as a pile of bodies; the sim does
not, so on Speedball the sim opens every round with six pairs of bots standing
inside each other while the game opens with twelve separated ones.

This was left alone deliberately. Changing where the sim starts bots moves every
difficulty measurement in the project at once -- the tier curve, the trading
probe, the engagement bands -- and those were only just re-stabilised after the
rescale. It is a fidelity bug in the measuring instrument, not in the game, and
it should be fixed on its own with all four probes re-run against it:

    lune run tools/probe-trading
    lune run tools/probe-difficulty-curve <map>
    lune run tools/run-tests sim

## Not attempted: the course in the sim

`SimMatch` cannot run a Shoothouse. Its schedule comes from `RoundSchedule` and
its bots come from `world.botSpawns`, where a course needs `Course.schedule` and
the stage's anchors. `Course.schedule` is pure and already shared with
`MatchService`, so the schedule half is a one-line swap; the spawn half needs
`runRound` to take stage anchors and the checkpoint respawn.

That is worth doing, because it is the only way to find out whether the par times
are sane. Every par in `Data/maps/*.json` is derived from geometry -- span over
2.4 m/s plus 28 defenders times a per-defender figure scaled by the engagement
band -- and no human and no policy has ever run one. They are a defensible first
guess and nothing more.


## The render pass (2026-09-08)

Measurement first, because the totals were answering the wrong questions.
`tools/check-budget` builds every field and the hub and checks three numbers
against budgets in `presentation.json`, and `tools/foliage-report` now breaks the
hub down per layer. The three are not interchangeable: a shadow caster is worth
far more than a part under Future lighting with global shadows, and
semi-transparent geometry cannot early-out of the depth test, so its cost is
AREA on screen rather than part count.

**The hub was casting 5784 shadows.** Decided purely by part name, so a pine
eighty metres into the treeline cost exactly as much as one on the trail.
Shadows are now also gated per instance on proximity to somewhere a player can
stand -- a trail centreline, or one of the open areas the scatter already carves
out. Distance from the hub centre would have been simpler and wrong: the gates
sit 63 to 82 m out, so a centre-radius rule strips the shadows from precisely the
trees a player is standing among at the Back Forty. **5784 to 1993.**

**The largest render cost in the game was not the trees.** Holdfast's boundary
walls were 13220 square metres of semi-transparent surface and Woods' were 5729
-- four full-height slabs per field at 0.2 and 0.25 alpha. They were the worst of
both worlds: at 75-80% opacity you could barely see the treeline they were being
transparent for, and you paid the overdraw anyway. Both are opaque now, and
because the treelines are 24 m and 31 m against walls of 14 m and 20 m, ten and
eleven metres of spire still stand above the wall against the sky. **Woods to 308
m2, Holdfast to 900.** Speedball keeps 1246 -- that is its netting, and netting
has to be see-through. The hub's remaining 1745 m2 is the pond and the creek.

**Ground detail moved to where it can be seen.** Ferns are three parts each and
stand half a metre tall, and four hundred of them were scattered to the hub's
edge. Ground layers carry a `nearPathsMetres` band now, with counts brought down
to match the smaller area: denser cover where it reads, none where it does not,
8069 parts to 7579. Trees are deliberately unbanded -- a treeline is precisely
the thing you see from a distance.

**What was NOT done, and why.** Distant conifers were not put on an LOD. Dropping
them from seven tiers to four saves about 13% of the hub and risks exactly the
"trees are blobs" read this project already rebuilt the hub once to fix. That is
a bad trade for a silhouette change nobody here can look at.

### Graphics

- **Every field has its own hour.** All five were rendering under one profile --
  the same 15:20 sun, the same haze -- so five places with five themes read as one
  place with five layouts. `maps_index` had a `perMap` block for exactly this and
  it was empty. Two rules constrain it and both are specced: brightness stays
  between 2.3 and 2.8, because a bot has to read as the most saturated thing on
  screen and a dim field breaks that before it looks moody; and haze scales with
  the field's own engagement band. That second spec caught its own commit's first
  draft, which gave the 18 m freight yard more haze than the 27 m market quarter.
  Depth of field stays off everywhere -- far blur costs you the target you were
  about to shoot.
- **The field borders got the trees the hub already had.** Two spheres on a stick
  became a stepped spire of stacked cylinder discs, the same silhouette the hub's
  conifers use, authored in `presentation.treeLine` as data. Costs parts and no
  shadows, since border scenery never casts.
- **Five palette keys were undeclared and silently falling back to concrete.**
  `brush`, `stone` and `containerRust` were drawing Woods' and Holdfast's
  thickets and outcrops as pale grey boxes; `gravel` and `trail` were drawing
  every freight lane, market street and valley path in concrete. An undeclared key
  does not fail -- it falls back and keeps building. `MapsSpec` now walks every
  field's geometry, terrain, ground, walls and ground markings and names any
  colour the palette does not declare.


## Measured but not done: the squad is rebuilt from scratch every round

`clearSquad` destroys every avatar and `buildSquad` builds new ones, so a whole
squad's worth of parts is constructed at every round boundary. A pro bot is 72
parts (`tools/check-characters`), which makes it:

| | avatars rebuilt | parts constructed | worst single transition |
|---|---|---|---|
| Course, rec | 28 | 868 | 155 parts in one frame |
| Course, pro | 28 | 2016 | **360 parts in one frame** |
| Gauntlet, rec | 40 | 1240 | |
| Gauntlet, pro | 40 | 2880 | |

The course makes this worse than the gauntlet does, and it is the mode that was
just added. A gauntlet has a seven-second intermission to absorb the rebuild; a
course has **zero** -- `clockStopsBetweenStages` is false, so the field moves up
immediately and those 360 constructions land during live play.

The obvious saving is that wave 2 of a course stage is identical to wave 1 in
tier, count and anchors, so half of every course's rebuilds are rebuilding the
same squad.

**Not done, deliberately.** Reuse needs `BotAvatar` to gain a reset -- rename the
model, restore the nameplate, clear the splatter -- and needs bot ids stable
across waves, which the shot log and the telemetry both key off. That is live
match code, and the payoff is a frame hitch that cannot be measured headlessly:
there is no frame here to drop. It wants a Studio profile first, and then it is
worth doing.
