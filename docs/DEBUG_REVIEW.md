# Debugging review — 2026-09-06

**Follow-up:** the local demo work in [DEMO.md](DEMO.md) supersedes several findings below. Spread is now applied on the server, startup waits for client readiness and serializes match-start requests, mid-match equips are rejected, and live simulation uses fixed steps. A separate demo project now builds without Wally. The findings below describe the initial review, not the current demo status.

The project has substantial pure simulation logic and useful deterministic tests. The live Roblox integration is materially less complete than the simulation and several comments describe behavior that is not implemented. Passing headless tests does not establish that the game works in Studio.

## Changes made

- Connected manual and empty-hopper reloads to the server's existing `RequestReload` remote. Added shared, clock-driven `MarkerState` for ammo, reload timing, and fire-rate enforcement. Repeated reload requests cannot extend the timer; stale delayed callbacks cannot refill a later loadout.
- Blocked live bot simulation and player firing during warmup. Initial bot avatars are positioned before the first live tick. Phase subscribers receive the initial warmup state.
- Blocked player firing while waiting for respawn. Respawn invulnerability is renewed after character loading returns.
- Guarded duplicate bot/player elimination events within one projectile batch, in both the live service and headless match simulation.
- Rejected NaN/infinite shot origins, directions, and timestamps before they reach ballistics.
- Connected `Input.tick` so lean and pointer behavior run. Freed the pointer for the summary and connected its existing Play again button to the match-start remote.

## Remaining findings, in priority order

1. **High: displayed spread has no effect on real shots.** `MatchService.onFire` feeds `request.direction` directly into `projectiles:fire`. It does not apply the marker's first-shot, sustained, movement, or sprint-recovery spread. The client's `currentSpread()` only changes the crosshair. `Input.luau` incorrectly claims the server recomputes spread from velocity. Implement authoritative movement/spread rules before evaluating the aim-training mechanics.

2. **High: build and persistence are not ready.** The default Rojo project references absent `Packages` and `ServerPackages`; Wally cannot execute on this Mac. The profile fallback permits play without persistence. A compatible dependency toolchain and actual ProfileStore session tests are needed. Also, `tests.project.json` references a missing `tools/TestRunner.server.luau`, so the Studio test project needs repair independently of the headless runner.

3. **High: equip changes desynchronize active matches.** `Bootstrap` allows `RequestEquip` during a match and sends `LoadoutChanged`, immediately changing the client's marker and refilling its predicted hopper. `MatchService.start` captures the original marker/spec for the entire round. Either defer equips until the next round or update the authoritative match and reconcile ammo explicitly.

4. **High: asynchronous match/profile startup lacks an in-flight guard.** `MatchService.start` checks `active[player]` before yielding profile/character loading, but only assigns it at the end. Repeated match-start requests during those yields can overlap creation. `Profile.load` similarly caches sessions only after `StartSessionAsync` returns. Serialize startup per player and ensure pending startup is cancelled when the player leaves.

5. **Medium: lag compensation is recorded but unused.** Live code stores reported latency and captures target history, but never queries a rewind or uses `clientTime` to resolve a shot. The server always checks current targets. Comments asserting that latency compensation is active are misleading.

6. **Medium: client state has no reconciliation handshake.** Initial loadout/currency/phase delivery uses events, with no explicit client-ready snapshot request. There is also no authoritative ammo response to repair prediction when a shot is rejected. The reload fix connects both sides, but does not constitute full network reconciliation. Test delayed client startup, latency, rejected shots, and restart behavior in Studio.

7. **Medium: projectiles ignore their configured fixed step in live play.** `ProjectileSim.step` integrates directly using the supplied `dt`; its stored `fixedStep` option is unused. Live calls use variable Heartbeat deltas, while headless matches run fixed ticks. Frame stalls can therefore change trajectories and collision results. The closest-approach capsule test also uses the closest point as the collision time, rather than the first surface intersection; inspect cover-edge hits before relying on its claimed earliest-hit ordering.

8. **Coverage gap: some acceptance tests are weak.** The test named “never lets a bot fire at something it cannot see” only checks nonnegative player deaths and zero eliminations by a passive player. It does not assert line-of-sight at bot firing time. ProfileStore and actual client/engine behavior are not exercised by the pure suite.

## Verification

Commands run from the project root:

```sh
~/.local/bin/lune run tools/run-tests
~/.local/bin/lune run tools/run-tests LiveRules
~/.local/bin/lune run tools/run-live-checks
~/.local/bin/rojo build -o /tmp/paintball-debug.rbxlx
```

The original baseline passed all 163 tests. The full rerun passed 169 tests (including six new cases); the final focused run passed all seven new regression cases after adding the initial-phase notification check. These cover round phases, reload timing, rate limits, and nonfinite network inputs. `run-live-checks` also passed, exercising the actual MatchService against mocked engine/projectile boundaries for warmup, manual reload, and duplicate eliminations. It does not model asynchronous Roblox character loading or network delivery.

All 44 source/spec Luau files were syntax-compiled successfully. This is not static type checking. Rojo build remains blocked by missing dependencies, as recorded in PLATFORM_NOTES.md. No Studio playtest was performed. The workspace has no Git repository, so these are direct file edits with no commit or Git diff.

## Publish-prep re-verification — 2026-09-07

The original findings above are historical. Current source inspection and
`tools/run-live-checks` establish the following narrower status:

- **Equip/start:** Bootstrap's `starting[player]` guard serializes the live
  request route, including profile loading, and is cleared after `pcall`.
  RequestEquip rejects pending startup and requires an allowed hub counter or
  `MatchService.canShop`. Direct MatchService.start is not independently
  serialized; all current live calls use the Bootstrap gate. Async engine
  scheduling still needs Studio stress testing.
- **Profile startup:** `loading[userId]` serializes StartSessionAsync. The adapter
  refuses unavailable live DataStore access and releases late sessions after
  departure. `tools/run-profile-checks` verifies access denial, session reuse,
  release and departure with a fake backend; it does not test Roblox storage.
- **Shot origin/spread:** current MatchService uses its server muzzle and applies
  spread. It no longer rejects shots based on client-origin distance. Verify
  moving fire under replication delay in Studio.
- **Fixed step:** the live Heartbeat accumulator calls `step(fixedStep)` and thus
  ProjectileSim at the configured interval. ProjectileSim itself still accepts
  arbitrary dt; its standalone fixedStep option is not an internal accumulator.
- **Lag compensation remains open:** history is captured but not queried during
  collision resolution. Misleading live comments were corrected. Rewind is not
  claimed as a completed feature.
- **Build/persistence dependency:** the full Rojo build now includes the vendored
  ProfileStore. Studio intentionally mocks progress. Save/rejoin validation on
  a private published server is still a release gate.

See `PUBLISH_READINESS.md` for current scope and remaining manual acceptance.

Additional current findings: the trading-versus-holding acceptance ties at 5.33
mean eliminations over six seeds and fails. The simulator omits live marker
spread. Its impossible reload-completion condition was fixed with a short
no-respawn regression. The old spawn-count spec hardcoded six; it now checks
each actual map's botSpawns (all have twelve), instead of an obsolete constant.

## Shooting and progression follow-up — 2026-09-07

The trading failure described above is resolved by sharing Spread's stateful
rules between live MatchService and SimMatch. Pro error is now 0.6 degrees;
control-round difficulty increases across all four tiers, with a separate
seed sample confirming pro remains harder than semi-pro. Map sizes and squad
counts are unchanged. See PUBLISH_READINESS.md for measured values.

Live boundary checks also exposed two release bugs: the server retained an empty
hopper/stale reload across round transitions, while the client refilled; and
Payout treated a list containing one cleared round as a cleared match when the
player left early. Both are fixed with regression coverage, including checking
that the early exit cannot complete the Walk-On chapter.

---

## 2026-09-07 — the same lesson, from the other direction

The line at the top of this document ("passing headless tests does not establish
that the game works in Studio") got its clearest demonstration yet, and it is
worth recording as a pattern rather than an incident.

The Shoothouse mode shipped with **thirty passing unit assertions and no way for
a player to reach it**. `Bootstrap.requestMatch` refused every mode that was not
`gauntlet`, and nothing in `MatchService` referenced `Course` at all. The specs
were green because they called the pure module directly — which is what a unit
spec is supposed to do, and exactly why a unit spec cannot see this class of bug.

It had a second-order consequence that no test asserted in either direction:
three camos had already been gated on course gold medals, so they were
permanently unobtainable while the wardrobe displayed a countdown toward a mode
that did not exist. A feature can be *unreachable* rather than *broken*, and
nothing in a green suite distinguishes the two.

**The check that closes it:** `tools/run-live-checks` now drives a complete
course through `MatchService` the way a player does — start through the real
entry point, clear all four stages, assert the profile record is written. Every
mode added from here needs an equivalent front-door check before it is
considered done. A rules module plus specs is half a mode.

**Still open, same shape:** `Endless.luau` (Horde) and `CaptureTheFlag.luau` are
pure, spec-covered and wired to nothing. `Bootstrap.asMode` now refuses them by
name so a request gets an honest refusal instead of silently running a gauntlet,
but they remain two more instances of this exact pattern.

### Tooling that had rotted quietly

Two verification tools were themselves broken and reporting nothing:

- `tools/run-live-checks` stubbed `WorldBuilder.build` with a plain table. Once
  the harness began injecting a real `Instance`, `MatchService` parenting its bot
  folder to that table threw — the whole live check had been dying on its first
  match for some time.
- `tools/check-client-ui` had no stub for `UiNavigation` once `Hud` began
  requiring it, so it died with "attempt to index nil" before testing anything.
  It also needed `GetPropertyChangedSignal`, `BindActionAtPriority`, a
  `Destroying` signal, and proxy-unwrapping on `NextSelection*` properties.

A verification tool that fails to start looks a lot like a verification tool that
found nothing. Both now run in CI-shaped form and exit non-zero.
