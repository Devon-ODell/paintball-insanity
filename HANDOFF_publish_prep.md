# HANDOFF — Publish prep: PC + console playability

Read `CLAUDE.md` first. This brief assumes it.

This is a pre-publish checklist, not a feature list. The goal is a build that
actually runs end-to-end in Studio, saves real progress, and is fully playable
with a gamepad — not just a build that passes headless tests. Work in the order
given: the two decision gates in Task 0 block almost everything after them.

**Ground rules restated, because the last pass broke them:**
- Commit per task, not one lump. Each task below is one commit.
- Do not expand scope beyond what's listed here. If a fix here seems to require
  touching something out of scope, stop and flag it — don't silently build it.
- Keep JSON formatting stable (don't let a formatter re-wrap every array onto
  its own line; it makes diffs unreviewable).
- Never author in Studio. Everything is `src/` + `Data/*.json`.

---

## Task 0 — Two decisions before anything else (blocking)

**0a. Shoothouse.** The co-op timed-course mode (`Course.luau`, `Courses.luau`,
`CourseProgress.luau`, `Data/course.json`) is built but never wired into
`MatchService`/`Bootstrap` — it's unreachable in play, and it gates some camo
unlocks behind a medal system nobody can ever earn.

Default action if not told otherwise: **pull it out of the publish build.**
Remove the `"shoothouse"` entry from `Data/gamemodes.json`, and remove or
neutralize the `requires` blocks in `Data/camos.json` that point at
`courseMedal`/`courseGold` so those finishes fall back to normal headshot
unlocks. Leave the Luau modules and tests in the repo (they're fine, just
disconnected) so the mode can be finished and re-enabled later without
redoing the work. **Do not** attempt to fully wire Shoothouse into
`MatchService` as part of this pass — that's a separate task with its own
scope (two-player match slot, shared clock/checkpoint sync).

**0b. Map scale.** Current maps are 88% of original footprint (~12% smaller),
not ~90% smaller. Confirm with me whether 88% ships as-is, or whether a
larger shrink is wanted — if it is, that needs fresh `tools/probe-trading`
balance passes per map (not just Speedball) before it ships, since the
existing 88% floor was chosen because trading balance inverted below it on
the one map that was tested. Don't push the scale further without new probe
data backing it.

---

## Task 1 — Get persistence actually working

**File/context:** `wally.toml`, `default.project.json`, `docs/PROGRESS.md`.

Per the project's own notes, Wally has never successfully run on this
machine (ARM Mac, no Rosetta 2), so `ProfileStore` — the package that saves
player progress, currency, and unlocks on a published server — has never
actually been fetched or built. Right now `Economy/Profile.luau` silently
falls back to an in-memory store whenever `ProfileStore` is absent, which
means **every published server today would lose all player progress on
restart**, with no visible error.

**Steps:**
1. Get a working Wally toolchain — either install Rosetta 2
   (`softwareupdate --install-rosetta`) so the existing x86_64 Wally binary
   runs, or fetch an ARM-native Wally release, or run `wally install` once
   on a different machine/CI runner and commit the resulting `Packages`/
   `ServerPackages` folders (check `.gitignore` isn't excluding them).
2. Confirm current best practice for this — verify against Wally's current
   docs/releases, since the brief already flags this pattern.
3. With `Packages` actually populated, do a real Studio playtest and confirm
   in the Output window that `Profile.load` connects to `ProfileStore`
   without the "temporary progress" warning.
4. Kill a test server (or use `game:BindToClose` testing) and rejoin —
   confirm currency/unlocks actually persisted.

**Acceptance:** a published (or Team Create) server saves and reloads real
player data without the in-memory fallback ever engaging.

---

## Task 2 — First real Studio playtest of the actual publish build

**Context:** every playtest on record was against `demo.project.json` (no
Wally, Speedball only, six bots, 2026-09-06) — the stripped-down demo, not
the current `default.project.json` build with 12 bots, rescaled maps, and
whatever survives Task 0. Per `docs/PROGRESS.md`'s own "Known gaps" section,
nothing in `src/StarterPlayer/Client/` or `MatchService.luau` has ever
actually been run.

**Steps:**
1. `rojo build` the full `default.project.json` place (with Packages from
   Task 1) and playtest it in Studio, not the demo launcher.
2. Walk every map, at full 12-bot squads, through a full round and a full
   match. Confirm the hub renders and performs (it's flagged as
   "unrendered and unwalked" with ~940 scattered props — this is the first
   time anyone will actually see it).
3. Confirm the two issues already surfaced by the one real playtest on
   record are still present and fix them:
   - **Intermittent origin-plausibility rejections while moving** — the
     server's shot-origin validation is rejecting legitimate shots during
     normal replication delay, not just spoofed ones. Loosen the check to
     tolerate replication lag without trusting client-reported positions
     outright.
   - **Payout line clips in a narrow viewport** — the results screen isn't
     responsive; fix with proper scale-based sizing (see Task 4).
4. Record the result in `docs/PROGRESS.md`, same format as the existing
   entries.

**Acceptance:** a full match, on the actual publish build, with real
persistence, completes without console errors and without visual clipping.

---

## Task 3 — Re-verify the still-open items from `docs/DEBUG_REVIEW.md`

That review's own follow-up note says the demo work "supersedes several
findings below," but not which ones, and it predates everything in this
handoff. Don't assume any of these are fixed — check each against current
code and record status:

1. Equip changes desyncing an active match (`RequestEquip` mid-round).
2. No in-flight guard on async match/profile startup (overlapping
   `MatchService.start` calls during yields).
3. Lag compensation data captured but never actually used to resolve a shot.
4. `ProjectileSim.step` ignoring its own configured fixed step in live play
   (vs. fixed-tick headless sim) — frame stalls can change trajectories.

Fix what's still broken; note in `docs/DEBUG_REVIEW.md` what's already
resolved and how it was verified (not just "should be fine").

---

## Task 4 — Console: complete gamepad input coverage

**File:** `src/StarterPlayer/Client/Input.luau`.

Fire (`ButtonR2`), reload (`ButtonX`), sprint (`ButtonL3`), and crouch
(`ButtonB`) all have gamepad bindings. **Slide (currently `C` only) and lean
left/right (currently `Q`/`E` only) have no gamepad equivalent at all** —
those actions are simply unavailable on a controller right now.

**Steps:**
1. Bind slide to an unused gamepad input (a bumper, or hold-crouch-while-
   sprinting if you'd rather fold it into an existing button than add one).
2. Bind lean left/right to the D-pad or the right stick's horizontal axis
   (check current Roblox convention for lean-style inputs — this is a
   common enough pattern that there's likely a documented best practice;
   verify rather than guessing).
3. Confirm nothing else in `init.client.luau` or `Hud.luau` assumes
   mouse/keyboard is present (e.g., cursor-only prompts, keyboard-only
   hotkey hints in HUD text).

**Acceptance:** every player action is reachable from a gamepad alone, with
no mouse or keyboard required at any point in a match.

---

## Task 5 — Console: gamepad-navigable menus

**Files:** `src/StarterPlayer/Client/ShopUi.luau`, `DialogueUi.luau`,
`Hud.luau` (results screen).

There is currently zero use of `GuiObject.Selectable`, `SelectionOrder`, or
`GuiService.SelectedObject` anywhere in the client code. On console, none of
these menus can currently be navigated with a controller — a player can walk
up to the shop, but the shop UI itself will be unusable without a mouse.

**Steps:**
1. Set `Selectable = true` and wire adjacency (`NextSelectionUp/Down/
   Left/Right`, or `SelectionOrder`) on every interactive button in the shop,
   dialogue, and results/play-again screens.
2. When each of those UIs opens, explicitly set
   `GuiService.SelectedObject` to a sensible default button so the gamepad
   cursor has something to start on — Roblox doesn't do this automatically.
3. Make sure the console "back" button (`ButtonB`) closes these menus where
   that's the expected convention, without colliding with the crouch binding
   from Task 4 (crouch is already on `ButtonB` — this needs a state check so
   `ButtonB` means "close menu" while a menu is open and "crouch" only
   in-match).
4. Verify against current Roblox documentation for gamepad UI navigation —
   the API surface here changes; don't build this from memory.

**Acceptance:** shop, dialogue, and results screens are fully usable start to
finish with only a gamepad — no mouse click ever required.

---

## Task 6 — Console: safe zones and resolution-independent UI

**Files:** `src/StarterPlayer/Client/Hud.luau`, `UiTheme.luau`.

`Hud.luau` sets `IgnoreGuiInset = true`, and roughly a fifth of its
`UDim2.new(...)` calls use fixed pixel offsets rather than scale. On a TV
with console-typical overscan, fixed-offset elements near the screen edge
risk landing outside the visible/safe area, and `IgnoreGuiInset` means the
HUD isn't getting Roblox's default inset protection either.

**Steps:**
1. Audit every offset-based `UDim2.new` in `Hud.luau` and convert HUD
   elements near the edges to scale-based positioning, or explicitly account
   for `GuiService:GetGuiInset()` / the console safe-zone API — check current
   docs for the right call, this has moved before.
2. Test the HUD using Studio's device emulator set to a TV/console profile
   and confirm nothing critical (ammo count, health/round state, the results
   payout line from Task 2) sits outside the safe area.
3. Confirm the shop and dialogue UIs scale sensibly across at least three
   aspect ratios (16:9 desktop, 16:9 TV at a lower base resolution, and
   whatever the narrow Studio viewport was that clipped the payout line).

**Acceptance:** no HUD or menu element is cut off or crowds the edge on a
simulated console/TV safe area.

---

## Task 7 — Performance pass at console/low-end budget

**Context:** the hub has ~940 scattered foliage/prop instances and has never
been profiled; `StreamingEnabled` is `false` in both project files, which is
fine for map sizes here but should be a deliberate choice, not an unverified
default, now that Holdfast is up to 176m on its long axis.

**Steps:**
1. With the hub actually rendered (Task 2), check Studio's performance
   stats: part count, triangle count, frame time, and memory.
2. Confirm `presentation.foliage.shadowParts` gating (already in the data)
   is actually reducing `CastShadow` parts as intended at scale, not just on
   paper.
3. Decide, with real numbers in hand, whether `StreamingEnabled` should stay
   off. Roblox's own current guidance is the source of truth here — verify
   rather than assuming last year's advice still holds.
4. Note actual frame time / part count in `docs/PROGRESS.md` against a
   console-tier budget, not just "seems fine on this Mac."

**Acceptance:** documented performance numbers from an actual render, not a
guess, and a stated decision on streaming.

---

## Task 8 — Pre-publish gate

**Files:** `Data/dev.json`, `tools/ship-check`.

`Data/dev.json` currently has `enabled: true` — the infinite-money dev flag
is live. `tools/ship-check` exists specifically to catch this and fail the
build.

**Steps:**
1. Set `Data/dev.json → enabled = false`.
2. Run `lune run tools/ship-check` and confirm a clean, zero-exit pass.
3. Run the full test suite one more time (`tools/run-tests`,
   `tools/run-live-checks`) against the final state of everything above.
4. Confirm `Monetization.md` and `monetizationDocumentation.pdf` still match
   what's actually in `Data/economy.json`/`Data/gear.json` after Task 0's
   camo changes — update whichever is now stale.
5. Fill the Maturity & Compliance questionnaire per `CLAUDE.md`'s target
   rating (Mild) before publishing, and confirm the published place's
   `MaxPlayers` setting (Studio place settings, not repo) is `2` — the
   Shoothouse exception from `CLAUDE.md`, if Task 0 keeps it enabled — or `1`
   otherwise.

**Acceptance:** `ship-check` passes clean, full test suite passes, and the
Studio place settings match what `CLAUDE.md` documents.

---

## Order of operations, summarized

0 (decisions) → 1 (persistence) → 2 (real playtest) → 3 (re-verify old
findings) → 4–6 (console input/nav/safe-zone) → 7 (performance) → 8 (ship
gate). Don't skip ahead to console work before Task 2 — there's no point
making an unplayed build gamepad-navigable.
