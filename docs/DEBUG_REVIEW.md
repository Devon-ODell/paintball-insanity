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
