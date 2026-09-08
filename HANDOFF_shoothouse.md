# HANDOFF — The Shoothouse is wired, and what it cost to find out

Branch: `shoothouse-wiring`, off `a61fe64`, pushed to origin.

Read `docs/PROGRESS.md` for the long version and `docs/PUBLISH_READINESS.md` for
the release state. This is the short one.

---

## What was actually wrong

The external review was right about the headline: the Shoothouse was ~600 lines
and thirty passing assertions that **no player could reach**. `Bootstrap` refused
every mode but `gauntlet` and nothing in `MatchService` referenced `Course`.

It had a consequence nobody had noticed: three camos were already gated on course
gold medals, so they were **permanently unobtainable** while the wardrobe counted
down toward a mode that did not exist.

Two corrections to that review, both checkable:

- **The JSON reformat claim is mostly wrong.** The five map files were already
  one-value-per-line at the true baseline `89efc37` — verified by byte-identical
  round-trip before editing. Only `maps_index.json` was compact and got expanded;
  that is fixed, and its diff went from 88 lines to 5.
- **"90% smaller" was never the instruction in this conversation.** The ask here
  was "make the maps a little smaller." 88% is a faithful reading of that. A
  genuinely 90%-smaller arena is a different, larger job.

The review's fair hit was that `probe-trading` only ever measured Speedball. That
is fixed and it immediately found real problems.

---

## Run these first

```bash
export PATH="$HOME/.rokit/bin:$PATH"
lune run tools/run-tests            # ~7 min, the whole suite
lune run tools/ship-check           # publish gate
lune run tools/run-live-checks      # drives a full course through MatchService
lune run tools/course-report        # every course against its own map
lune run tools/map-validate         # nav graphs, buried nodes
lune run tools/check-zfight         # shimmering surfaces
lune run tools/probe-trading        # ~10 min, all five fields
lune run tools/probe-difficulty-curve speedball
lune run tools/check-budget         # parts, shadow casters, transparent m2
lune run tools/foliage-report       # the hub, per layer
```

---

## The three decisions worth arguing with

**1. Speedball fields twelve bots from six spawns.** Every other field has
twelve. Twelve was tried on Speedball twice and both arrangements measurably
damaged it — extras in the defenders' half inverted how the map punishes trading
(+3.33 to −0.83), extras crowded into the back third flattened the top of the
difficulty curve instead (semipro 7.50 deaths vs pro 6.17, so pro came out
*easier*). With six, both hold. `MatchService` fans reused spawns onto a small
ring so nobody starts inside anybody.

**2. Speedball and Urban were not shrunk; Dustline, Woods and Holdfast are at
88%.** Urban measured +2.67 at full size and −0.33 at 88% — trading became
*safer* than holding an angle, so the rescale is reverted there. Dustline fails
the same probe at −3.17 but measured **−7.83 before any of this**, so that
failure is pre-existing and the shrink made it less wrong. Do not "fix" Dustline
by reverting its scale.

**3. Co-op is authorized and not built.** You chose to ship with 2P co-op knowing
the join plumbing was unbuilt. Every co-op *rule* is implemented and specced.
The shared *match* is not: `MatchService` runs one closure per player and the
simulation identifies the player as a single entity (`id = "player"`), so two
people on one course means two player capsules through `ProjectileSim`,
`SquadCoordinator`, `AimModel` and `ShotLog`. I did not half-land that overnight
on a game that currently works.

What I did instead: the second **seat** is real (hub, barn, shop, board), and the
server refuses a second concurrent match. That guard is not optional — every map
builds at the world origin and `Hub.park` is global, so two matches at once would
stack two maps and park the hub out from under whoever stayed behind.

---

## Next, in the order I would do it

1. **Studio playtest.** Nothing here has been rendered or walked. Hold **E** at a
   trailhead for the course, **F** for the five rounds.
2. **Retune par.** Every par time is derived from geometry and no human has run
   one. They are a defensible first guess and nothing more.
3. **The course in the sim.** `SimMatch` cannot run a Shoothouse — schedule half
   is a one-line swap to `Course.schedule`, spawn half needs `runRound` to take
   stage anchors. This is the only way to check par without playing five courses.
4. **The sim stacks bots at spawn** where the game now fans them out. Fixing that
   moves every difficulty measurement at once, so do it alone and re-run all
   probes.
5. **Co-op join**, if still wanted. Genuinely architectural.
6. **Horde and CTF are still dead code**, exactly as the Shoothouse was. They are
   marked `integrated: false` and refused by name, and `ship-check` will not let
   an unintegrated mode into the release catalogue. Wire one properly or leave
   them alone.

---

## The render pass

Measured, not guessed — `tools/check-budget` builds every field and the hub and
checks parts, shadow casters and semi-transparent area against budgets in
`presentation.json`.

- **The hub was casting 5784 shadows**, decided purely by part name, so a pine
  eighty metres into the treeline cost as much as one on the trail. Now gated on
  proximity to somewhere a player can stand. **5784 → 1993.**
- **The biggest render cost was not the trees.** Holdfast's boundary walls were
  13220 m² of semi-transparent surface and Woods' 5729 — and at 0.2 alpha you
  could barely see the treeline they were transparent *for*. Both opaque now;
  the trees are taller than the walls, so ten metres of spire still stands above
  them. **Woods → 308 m², Holdfast → 900.** Speedball's 1246 is its netting.
- **Five palette keys were undeclared** and silently rendering as concrete: the
  thickets and outcrops on Woods and Holdfast, and *every* trail, freight lane
  and market street on four fields. A spec names any undeclared key now.
- Each field has its own hour and its own air, constrained by two specced rules:
  brightness stays 2.3–2.8 so bots stay the most saturated thing on screen, and
  haze scales with the field's engagement band.

I did **not** LOD the distant conifers. It saves ~13% of the hub and risks the
"trees are blobs" read this project already rebuilt the hub once to fix — a bad
trade for a silhouette change nobody here can look at. That one wants eyes on it.

---

## The lesson worth keeping

A rules module plus passing specs is **half a mode**. Unit specs call the pure
module directly — that is what they are for, and it is exactly why they cannot
see an unreachable feature. Every mode from here needs a front-door check like
the one now in `tools/run-live-checks`, which starts a course the way a player
does and asserts the record lands.

Two verification tools had themselves been broken for a while and were reporting
nothing, which looks identical to reporting no problems. Both are fixed and both
now exit non-zero.
