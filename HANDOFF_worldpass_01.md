# HANDOFF — World pass 01: barn roof, foliage clipping, marker viewmodel, shop interior

Read `CLAUDE.md` first. This brief assumes it.

Four defects/improvements found by playtesting the current build. Work them in the
order given — the roof and foliage fixes are cheap and unblock judging the art
pass, the marker and shop work is subjective and should be reviewed with fresh
screenshots before you go deep.

---

## Ground rules for this pass

Restating the ones this work will tempt you to break:

- **Terminology.** These are *markers*, not guns/weapons/firearms. Never name a
  part, variable, sign, or comment with firearm vocabulary. "Weapons shop" in the
  request means *pro-shop / field supply counter* — the paintball-store read, not
  the gun-store read. Hoppers, barrels, air tanks, regulators, velocity, FPS.
- **Never author in Studio.** Everything is `src/` + `Data/*.json`. If it isn't in
  the repo it doesn't exist.
- `--!strict` on every file. No untyped modules.
- Geometry that is *data* belongs in `Data/*.json`. Geometry that is *construction
  logic* belongs in the builder module. Don't hardcode positions in Luau that the
  existing JSON already parameterises.
- Verify Roblox API shape against current docs before using anything you're not
  certain of. Record what you checked in `docs/PLATFORM_NOTES.md` (note: that file
  and the whole `docs/` directory are missing from the repo — create them).

## How to run and verify

```bash
rojo serve                    # in repo root
# Studio: Plugins > Rojo > Connect, then F5
```

Every task below needs a **before/after screenshot** in the same spot. Take the
"before" first.

---

## Task 1 — The barn roof is inverted (highest confidence, smallest fix)

**File:** `src/ServerScriptService/World/PoleBarn.luau`, the "Gable roof on exposed
rafters" section (~line 204).

**Hypothesis — verify before fixing.** The two roof sheets are rotated with
`CFrame.Angles(side * -pitch, 0, 0)`. Working through it: for `side = -1` the
rotation is `+pitch`, which maps the part's local `+Z` to `(0, -sin θ, cos θ)`.
The sheet sits at `z = -halfD/2`, so travelling toward the ridge at `z = 0` the
height *decreases*. Same result mirrored on the other side. Both slopes fall
toward the centre — that's a valley, not a gable. The `RidgeCap` and `RidgeBeam`
are still placed at `wallH + rise`, so they float in the air above the trough,
which matches the stray beam visible over the barn in the screenshots.

The rafters at ~line 239 use the identical convention, so they're inverted
consistently with the sheets — the whole assembly is upside down rather than the
sheets disagreeing with the frame.

**Steps:**

1. Confirm it visually first. Run, then in the Explorer find the barn model and
   select `Roof_1` and `Roof_-1`. Check whether their inner edges sit below or
   above their outer edges. Do not fix on my say-so.
2. If confirmed, drop the negation: `CFrame.Angles(side * pitch, 0, 0)` in **both**
   the roof sheet block and the rafter block.
3. Re-check `RidgeCap`, `RidgeBeam`, and the `Tie_{i}` collar ties still land where
   they should relative to the corrected slopes.
4. Check the `Fascia` at `wallH + rise * 0.52` — with a corrected roofline its
   height may now read wrong against the eave.

**Note there are two shop structures** and the screenshots are ambiguous about
which one is which:

- `PoleBarn.luau` builds "PARSONS FIELD SUPPLY" from `overworld.json → barn`.
- `FieldDetails.luau` builds a model named `FieldSupply` from `venue.json → props`,
  whose fascia reads "FIELD SUPPLY • MARKERS SAFE BEYOND THIS POINT". Its `Roof`
  prop is a flat slab with no rotation applied.

Identify which one the player is standing in by model name in the Explorer before
you touch anything. If the `FieldSupply` slab roof also reads wrong, that's a
separate issue — a flat slab can't be "upside down", so it would be a fascia or
sign-face problem instead.

**Acceptance:** ridge is the highest point of the barn; water would run off the
eaves; no floating ridge parts.

---

## Task 2 — Trees intersecting buildings

**Files:** `src/ServerScriptService/World/Foliage.luau` (`insideExclusion`,
`accepts`), `Data/overworld.json → scatter`.

**Root cause.** `insideExclusion` tests only the trunk's **centre point** against
the exclusion rect/circle. It applies no padding for the instance's own footprint.
A canopy tree whose trunk centre lands one metre outside the barn's exclusion rect
puts its entire crown — several metres of radius — straight through the wall.

Secondary: only five exclusions exist in `scatter.exclusions`, covering the
clearing, the barn, one circle east, the west trail corridor, and one small
circle. The gates, the props in `overworld.json → props` (trucks, air rack, pallet
stacks, chrono stand, dock), and the leaderboard have **no exclusion at all**.

**Steps:**

1. Extend `ScatterContext` and `accepts` to take a per-instance **footprint
   radius**, and pad both the circle and rect tests by it. Circle:
   `magnitude <= radius + footprint`. Rect: expand `half` by `footprint` on both
   axes.
2. Derive the footprint from the layer's own dimensions rather than a magic
   number. For `kind == "tree"` the crown radius is the right value, not the trunk
   diameter — look at how `scatterLayer` sizes the canopy and reuse that.
3. Add the missing exclusions to `Data/overworld.json`, not to Luau. One per
   structure. Keep them tight; over-large exclusions will strip the clearing bare.
4. Raise `trailClearanceMetres` only if step 1–3 doesn't resolve the trail
   overhang. Prefer the padded test.
5. Re-run and walk the whole hub. `scatter.seed` is fixed (`20260907`), so the
   layout is deterministic and your before/after screenshots are comparable.

**Watch for:** the layer counts are tuned (260 canopy, 120 saplings, 340 ferns).
Padding raises the rejection rate, so fewer instances will place. If the woods
thin out noticeably, raise counts to compensate — and check whether the rejection
sampler has an attempt cap that will silently under-place.

**Acceptance:** no trunk or crown geometry intersecting any building, gate, or
prop; the treeline still reads as dense forest.

---

## Task 3 — Marker viewmodel design

**Files:** `src/StarterPlayer/Client/ViewMarker.luau`,
`Data/markers.json → viewModel`, `Data/venue.json → markerModels`.

The parts list in `markers.json → viewModel.pieces` is actually complete — grip,
feed neck, hopper, hopper lid, air tank, regulator, trigger guard, valve cap,
accent stripes. The problem is how they render, not what's missing.

**Two concrete bugs:**

1. **`Hopper` and `AirTank` are both `"shape": "Ball"`.** A Roblox Ball part
   renders as a sphere regardless of its three size values, so `[0.22, 0.14, 0.29]`
   becomes a plain sphere and `[0.15, 0.15, 0.35]` becomes another one. In-game
   that reads as a black ball stuck on a green box. The air tank should be a
   **Cylinder** rotated along its long axis (there's already a working example of
   this — the `airRack` tanks in `Overworld.luau` do exactly this rotation). The
   hopper wants a squat cylinder or a small stack of boxes, not a sphere.

2. **Scale/offset mismatch.** Part sizes and part offsets go through
   `Units.vectorToStuds` (metres → studs), but `viewModel.offsetStuds` is consumed
   raw in `ViewMarker.step`. It is genuinely in studs, as the name says — but that
   means the camera offset and the model dimensions are being tuned in different
   units, and the marker currently fills a large share of the frame with the barrel
   pushed off-centre. Re-tune `offsetStuds` against the actual model extents and
   leave a comment stating the unit, because the mixed convention will bite the
   next person.

**Then the design pass:**

3. Give the three archetypes in `venue.json → markerModels` silhouettes that read
   apart at a glance. Right now they differ only in body dimensions by a few
   centimetres and in colour. `pump` should read as a pump — it needs a visible
   pump handle under the barrel, which is what makes the archetype legible.
   `electronic` should read as compact and squared. Add archetype-specific pieces
   rather than one shared `viewModel.pieces` list applied to everything.
4. Barrel should have a visible bore and a porting/shroud break near the muzzle.
   It's currently one smooth cylinder.
5. Keep every change data-driven. Adding a `pieces` override per archetype in
   `venue.json → markerModels` is the right shape for this; hardcoding into
   `ViewMarker.equip` is not.

**Do not** change anything that affects `GearStats` — the marker is cosmetic only
and `Shop.assertNoPayToWin` plus the Economy specs enforce that.

**Acceptance:** three archetypes distinguishable in first person without reading
the HUD; no spheres standing in for cylindrical hardware; marker occupies a
sensible fraction of the frame.

---

## Task 4 — Shop interior: make it read as a pro shop

**Files:** `src/ServerScriptService/World/PoleBarn.luau` (bays section, ~line 280),
`Data/overworld.json → barn.bays`, `Data/venue.json → props`.

The three bays (`markers`, `paintAndAir`, `protective`) currently get a back-wall
panel, a counter, a countertop, and three empty shelves each. Shelves with nothing
on them are why it doesn't read as a shop.

**Steps:**

1. **Stock the shelves.** Build actual props on the shelf slabs, per bay:
   - `markers` bay — marker bodies displayed on racks or hooks, loose barrels in a
     barrel bin, barrel socks.
   - `paintAndAir` bay — stacked paint cases, loose pods in a pod rack, air tanks
     standing in a row (reuse the `airRack` cylinder pattern), a fill station with
     a gauge.
   - `protective` bay — masks on a shelf, jerseys hung on a rail, pads and gloves.
2. Drive this from data. Add a `shelfProps` array per bay in
   `overworld.json → barn.bays[]` and a small prop-builder switch in `PoleBarn.luau`
   mirroring the `buildProp` pattern already in `Overworld.luau`. Don't invent a
   second architecture.
3. **Counter dressing** — a register or card reader, a squeegee jar, a roll of
   tape, a chrono readout on the markers counter, a coffee cup. These are what sell
   "a person works here".
4. **Wall dressing** — a pegboard behind each counter, a hand-lettered price list,
   a corkboard with field flyers, a wall clock, a fire extinguisher by the door.
   `NoticeBoard.luau` already has working SurfaceGui text rendering — reuse it
   rather than writing a third sign implementation.
5. **Lighting.** The interior is dark in the current screenshots. Hang shop lights
   off the (corrected) rafters. `Overworld.luau`'s `firepit` shows the PointLight
   pattern. Keep part count reasonable — check `presentation.foliage.shadowParts`
   for how the project already gates `CastShadow`.
6. Every bay's colourKey (`sheetMetalRust`, `tarp`, `beam`) is already distinct.
   Lean into that so a player learns "rust wall = markers" without reading signs.

**Budget:** these are set-dressing boxes. Keep them `CanCollide = false`,
`CanQuery = false`, `CastShadow = false` unless there's a reason. Watch total part
count — check it in the Studio performance stats before and after.

**Acceptance:** each bay is visually distinct and obviously stocked; a player can
tell which counter sells what before triggering the prompt.

---

## Out of scope for this pass

Do not touch: ballistics, bot AI, the economy or shop transaction path, telemetry,
`Data/dev.json` flags, or anything under `src/ServerScriptService/Sim/`. If a fix
here appears to require touching those, stop and ask.

## Before you finish

- `--!strict` clean, no new lint errors.
- Run the spec suite. `tests/Overworld.spec.luau` and `tests/Maps.spec.luau` are the
  relevant ones; add coverage for the foliage padding logic since it's now
  non-trivial arithmetic.
- Note: `rokit.toml` references a `tools/ship-check`, and `Data/gear.json` and
  `Data/dev.json` both reference it too, but **there is no `tools/` directory in the
  repo**. Nothing is currently enforcing the pay-to-win audit or the dev-flag ship
  gate. Flag this; don't silently build it as part of this pass.
- Commit per task, not one lump. Screenshots in the PR description.
