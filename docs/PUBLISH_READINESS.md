# First-release readiness — 2026-09-07

**Candidate prepared; public release still requires Studio and private-server
acceptance.** The automated balance failures have been resolved. The user chose
to continue without Studio testing in this session.

## Release decisions

**REVISED 2026-09-07 (later the same day).** The earlier decision was solo
Gauntlet with Shoothouse, Horde and Capture the Flag all deferred at
MaxPlayers = 1. On review it turned out the Shoothouse was deferred because it
was unreachable, not because it was unwanted -- Bootstrap refused every mode but
gauntlet and nothing in MatchService referenced it. It is now wired end to end
and verified through the real entry point, so the release is:

- **Gauntlet and Shoothouse**, both playable. Set the published place's
  **MaxPlayers to 2**.
- **Horde and Capture the Flag remain deferred.** Their rules modules and specs
  exist and nothing starts them. They are marked `integrated: false` in
  `Data/gamemodes.json`; `ship-check` refuses to publish an `order` containing an
  unintegrated mode, so they cannot return unnoticed.
- **Co-op is authorized and NOT yet built.** MaxPlayers = 2 is set and every
  co-op RULE is implemented and specced, but the shared match is not: two people
  on one course needs two player capsules through the simulation, which is an
  architectural change rather than a flag. The server refuses a second concurrent
  match until then -- without that guard two matches would build two maps at the
  world origin. A second player can join the server; they cannot yet join a run.
- Map dimensions changed: Dustline, Woods and Holdfast are at 88%; Speedball and
  Urban are at full size because shrinking them inverted how they punish trading.
- **The Range is live.** `RangeService` runs the drill schedule against the
  authoritative projectile sim and scores it with the same `DrillScoring` the
  simulation uses, so a drill run at the gate and a drill run headlessly differ
  only in who pulls the trigger. It pays nothing, and `ship-check` still asserts
  that. `tools/check-range` drives a full drill end to end.

Dev overrides are off. Free supply and cosmetic claims remain enabled; paid
prompts remain disabled. Former course finishes now require 250 (Chalkline),
500 (Shoothouse finish), and 1000 (Aurum finish) confirmed mask hits.
The marker now uses the release Gauntlet campaign: pro Speedball for the
Marshal chapter, flawless semi-pro across the four campaign fields for The Long
Afternoon, then flawless pro across those fields for Aurum. Gates select the
current chapter's tier; replay keeps the previous match tier.

`Monetization.md` is general reference material, not this build's product
catalogue. The implementation-specific record is `docs/MONETIZATION.md`.
The PDF contents were not extracted or verified in this session; it was left
unchanged.

## Prepared changes

- Release catalogue defaults to Gauntlet and exposes only that mode. Horde's
  NPC describes it as coming later. Ship-check prevents an unsupported default
  or course-gated camo from returning unnoticed.
- ProfileStore is already vendored, so Wally installation is not a publish-build
  prerequisite. The adapter now requires actual `DataStoreState == "Access"`
  outside Studio; unavailable access cannot become a temporary live save.
  A profile arriving after the player departs is released immediately.
- Field kit has no live activation/effects; it now displays as coming later
  and server purchase calls reject it. Existing inventory is preserved.
- Controller: R2 fire, X reload, L3 sprint, B crouch, R1 slide while sprinting,
  D-pad left/right lean. Roblox supplies the normal move/look/jump controls.
- Shop, dialogue and results establish controller selection, provide explicit
  navigation links, and clear focus on destruction. Shop/dialogue consume B at
  high priority while open. Results use their explicit action buttons.
- HUD/readouts and menus use core safe insets. Camera-centered aiming graphics
  use a separate full-screen layer. Payout text grows vertically when wrapping.

## Required Studio and private-server gates

1. Build `default.project.json` (not the demo) and open the resulting place.
   Start with a fresh profile. Walk the hub, visit every counter/NPC, claim and
   equip items, enter each unlocked Gauntlet field, finish all five rounds,
   replay, and return to the hub. Capture Output errors and video of failures.
   Rounds field 4/6/8/10/12 bots. Repeat with replication delay, moving fire,
   reloads, respawns, and rapid start/equip/menu actions.
2. On a **private published test experience**, earn currency and a camo or item,
   leave, shut down the server, and rejoin a new server. Verify the exact
   currency, inventory, loadout and progression reload. Ordinary Studio always
   uses `ProfileStore.Mock` and cannot satisfy this test. Use a separate test
   experience to avoid contaminating eventual production progress.
3. Use Studio's Controller Emulator or a physical controller for the entire
   loop. Test starting with a controller, switching from mouse mid-menu,
   scrolling all shop categories/results, purchase-driven list rebuilds,
   dialogue replacement, B close without crouching, and controls after respawn.
4. Inspect desktop 1920×1080, TV/console 1280×720 with safe areas, and a narrow
   600×800 viewport. Check payout wrapping, ammo/currency, text scaling, shop
   cards, dialogue options and crosshair alignment. These are pending visual
   checks, not claims of verified support. Do not enable phone/tablet support
   without touch controls and dedicated testing.
5. Record rendered hub/12-bot frame time, memory, part and triangle counts.
   A provisional 60 FPS goal is 16.7 ms/frame; report hardware and worst-case
   behavior. `tools/check-budget` prints the current structural counts and
   fails over budget, so read them from there rather than from this file --
   the figures quoted here have already gone stale once. At the time of
   writing: the hub is **8615 parts / 2548 shadow casters / 1745 m² of
   semi-transparent surface**, of which foliage is **1339 plants / 7579 parts
   / 2012 casters**; the largest field is Holdfast at 506 parts; a full pro
   squad is 864 parts and **zero** shadow casters.

   The hub is the heavy scene and it is also the first one a new player loads.
   It does not compound with a match: `Hub.park` reparents it to ServerStorage
   for the duration, so in-match a client holds roughly the field plus the
   squad (~1400 parts), not the hub as well.

   Streaming stays off provisionally: do not call that a measured performance
   decision. Profile first, then decide whether to reduce decoration/shadows or
   implement/test streaming with the client's instance assumptions.
6. In Creator Dashboard/Studio, verify **MaxPlayers=2** (co-op is authorized;
   CLAUDE.md sets the published place to 2, and the server refuses a second
   concurrent match rather than building two maps at the world origin),
   supported device settings,
   private testing access, and complete the Maturity & Compliance questionnaire
   honestly from the actual experience (design target: Mild). Review the whole
   campaign for references to deferred modes before writing public launch copy.

## Balance validation

Live MatchService and SimMatch now share the same stateful spread implementation:
movement/sprint classification, sprint recovery, sustained spread, decay and
round resets. Spread has an independent random stream, so adding a policy's
random decisions cannot change the marker's random samples. Tests inspect the
actual outgoing projectiles in both adapters.

The Speedball semi-pro six-seed probe now gives **holding 5.00 versus rushing
5.83 outs**. The previously tied trading acceptance passes without changing the
maps, bot count or assertion. Pro aim error was adjusted from 0.7° to 0.6° to
restore the difficulty ordering after adding the missing player spread:

| Sample | Rec | Amateur | Semi-pro | Pro |
| --- | ---: | ---: | ---: | ---: |
| Speedball seeds 1–6, mean outs | 0.50 | 2.17 | 5.00 | 6.50 |
| Independent seeds 7–12, mean outs | — | — | 5.83 | 8.33 |

All six semi-pro runs in the independent sample cleared; four of six pro runs
cleared within the 240-second control-round limit. These are deterministic
simulation samples, not measured player difficulty or proof of every map's
balance. Full live playtesting remains necessary.

New round-transition checks also found and fixed server hopper refill/reload
state disagreeing with the client. Payout now requires the complete scheduled
round count before awarding flawless bonuses or campaign clears. Quitting after
one cleared round still pays its ordinary share, but does not unlock a chapter.

## Explicit technical limitations

Live projectile collision still uses current server targets. Target history is
captured but rewind is **not integrated**. This can affect high-latency aim;
there is no verified lag-compensation claim. Implementing rewind for travelling
projectiles requires a tested time/collision policy, not merely substituting one
historical target position. Multiplayer startup/load/network behavior and real
DataStore writes are outside the mocked harness's evidence.

The separate `tests.project.json` still needs TestEZ packages and the missing
`tools/TestRunner.server.luau`. Use the headless runner below for the automated
suite; do not mistake that old Studio test project for the publish project.

A bump helmet's crown stands **5cm above the hitbox capsule** on `botPro` and
`botMarshal`. Bots are shot at as a capsule of radius 0.31m and height 1.80m
(`Data/ballistics.json` `hitbox`), and `bumpHelmet.HelmetShell` reaches 1.85m, so
paint landing on the top of a pro's helmet does not register. `tools/probe-hitbox`
measures this and every other disagreement between a visible body and its capsule.

It is **not** fixed, deliberately. Lowering the shell is one data line, but the
helmet is narrower than the paintball mask underneath it (0.36 x 0.38 against
0.38 x 0.40), so dropping it far enough to fit hides it inside the mask; keeping
it visible means widening it and changing the pro silhouette, which is exactly the
read the tier system depends on. Settle it in the Studio pass with the model on
screen, then turn `probe-hitbox` into a gate. The same probe records two accepted
deviations that are ordinary shooter design: hands holding a marker forward reach
outside the capsule, and a chest is 1cm wider than it.

Trails at The Landing sit **12-25cm above the forest floor**, and they do not
collide -- the player walks on the floor and the path is drawn up their shin. It
cannot currently be lowered further. A trail has to clear every zone slab it
crosses (the highest being `pondBank` at 0.108m), and the zone tops
0.072/0.084/0.096/0.108 are exactly one 12mm step apart, so a 12mm ladder either
lands on one or misses by 6mm -- under the 9.8mm `check-zfight` requires. The fix
is to fold the zone slabs into `Surfaces.assignLevels` alongside the trails, so
only surfaces that actually overlap need to differ; that would drop the whole
stack to a few millimetres. `tools/probe-ground` measures it.

Eight client-to-server remotes accept unlimited calls per second: `RequestReload`,
`RequestPurchase`, `RequestEquip`, `RequestSessionState`, `RequestShopVisit`,
`RequestShopCatalogue`, `ReportLatency` and `DialogueChoice`. Only
`RequestCommerce` carries an explicit cooldown; `FireMarker` is bounded by the
marker's own fire rate and `RequestMatchStart` by the one-match-at-a-time rule.

This is accepted for the first release and is **not** a release blocker. Every
one of those handlers is correctness-guarded -- none can be driven into granting
currency, items or progression -- so at `MaxPlayers = 2` on solo PvE the worst
case is a player degrading their own server's frame rate. It stops being
acceptable the moment player count rises: **add a shared per-player debounce
before raising `MaxPlayers` or shipping co-op.** The pattern to lift is already
in `Economy/Commerce.luau` (`self.lastRequest` against
`requestCooldownSeconds`). Reviewed 2026-09-08.

## Reproducible checks

```sh
~/.local/bin/lune run tools/ship-check
~/.local/bin/lune run tools/run-tests
~/.local/bin/lune run tools/run-live-checks
~/.local/bin/lune run tools/run-profile-checks
~/.local/bin/lune run tools/check-range
~/.local/bin/lune run tools/check-zfight
~/.local/bin/lune run tools/foliage-report
~/.local/bin/rojo build default.project.json -o /tmp/paintball-release.rbxlx
```

The full suite, source syntax check, live-service harness and profile-adapter
checks are recorded in `PROGRESS.md`. None is a substitute for rendered or
published-service acceptance.

The candidate is `build/paintball-release.rbxlx`, with a compatibility copy at
`/tmp/paintball-release.rbxlx`. No place has been uploaded or made public.

On this Mac, double-click `Play.command` to check configuration, rebuild, and
open the current source in Studio. Double-click `Check Release.command` to run
all automated gates before building (allow several minutes). Both launchers use
the installed tools in `~/.local/bin`; neither publishes to Roblox.
