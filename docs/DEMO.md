# Play the local demo

Double-click **Play Demo.command** in the project folder. It rebuilds `build/LiveRoundDemo.rbxlx` from source and opens it in Roblox Studio. Sign in to Studio if prompted, then choose **Test** and click **Play** (F5; Fn-F5 on some Mac keyboards). Use Test, rather than the server-only Run mode, because this game needs a local player.

The edit viewport is initially empty: the server constructs the map when your client joins. After pressing Play, expect The Landing, a wooded hub with NPCs, shop counters and five field gates. Walk to a gate and hold its prompt to start a gauntlet; the first round has two bots and the fifth has six. Visit Field Supply for free markers, cosmetics and headshot camo progress. Click the viewport to control your player.

| Control | Action |
| --- | --- |
| WASD / mouse | Move / aim |
| Left mouse | Fire; hold for the default mechanical marker |
| R | Reload |
| Left Shift | Sprint; release to recover accuracy |
| Left Control | Crouch |
| C while sprinting | Slide |
| Q / E | Lean |
| Escape | Roblox menu / release control |
| Shift-F5 | Stop the Studio test |

One paint mark eliminates a bot. Getting marked sends you back into play after a short delay; progress against the squad remains. Clear the field for a result summary and use **Play again** to restart. The round also ends at its configured time limit.

## Current build (2026-09-07)

All shop stock and both cosmetic collections are free. Nine paintball markers
include five new Yardline colorways. Headshot camos unlock at 10, 35, 75 and 150
confirmed mask tags and pulse on subsequent headshots. The maps have distinct
surface/landmark treatments and the HUD, shop and dialogue layouts are updated.
See [MONETIZATION.md](MONETIZATION.md) for free-mode controls and later setup.

The launcher rebuilds the latest demo. Current validation includes the pure
spec suite, live MatchService with mocked engine boundaries, UI construction and
all nine marker/camo combinations, all five map constructions, nav validation
and the persistence adapter with mock writes. Actual Studio appearance remains
to be playtested for this update. The older playtest record below describes an
earlier build.

## Earlier demo baseline

- Code-built Speedball field and six visible AI opponents.
- Server-authoritative paintball flight, hits, ammo, reloads, and sampled spread.
- Bot paintball tracers, local player tracers, hit feedback, crouch/lean camera motion, and controls help.
- Startup after client readiness, warmup, respawns, round summaries, and replay.
- Local session economy and telemetry. Progress resets when the Studio play session stops.

`demo.project.json` deliberately has no Wally dependencies. It includes a DemoMode flag; the server refuses to run this build outside Studio. The full `default.project.json` now bundles ProfileStore for published-server saves and uses its temporary Mock store in Studio. Shop/range interfaces, online lag compensation, production movement security, and polished marker visuals/audio remain outside this demo.

## Rebuild and verify

```sh
./"Play Demo.command" --build-only
~/.local/bin/lune run tools/run-tests
~/.local/bin/lune run tools/run-live-checks
~/.local/bin/lune run tools/check-demo-world
```

The demo build succeeded. All 172 headless specs passed. The actual MatchService passed mocked-engine checks for warmup, reloads, and duplicate eliminations. All three maps and bot avatars constructed successfully against Lune's Roblox datatype database. These checks do not replace an actual Studio playtest.

**Studio playtest confirmed:** on 2026-09-06 the demo ran in Studio and completed two rounds (six eliminations each), including a flawless clear. The results screen and replay flow were visible, and server logs recorded payouts of 233 and 397. The log also exposed intermittent origin-plausibility rejections while moving; the fixed-distance validation needs adjustment to accommodate replication delay without trusting client-provided firing positions. The summary's payout line clips in a narrow Studio viewport and needs responsive layout work.

If the game fails to start, open Studio's Output window and look for the first red error. The expected yellow ProfileStore warning just means this local build uses temporary progress. If source changes are made, stop the test, rerun the launcher, and reopen the rebuilt place; Studio does not automatically reload files changed on disk. Do not save game logic edits from Studio over the generated place—source remains in `src/` and `Data/`.

Official references: [Studio installation](https://create.roblox.com/docs/studio/setup), [Studio testing modes](https://create.roblox.com/docs/studio/testing-modes).
