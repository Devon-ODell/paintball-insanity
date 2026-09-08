# PROJECT_LIVEROUND

A single-player Roblox PvE paintball shooter, built as a disguised aim trainer.
One player against twelve bots per match. Low-poly, flat-shaded, saturated palette.

The game is deliberately hard. Losing a straight fight against the squad is the
expected outcome. Death costs no progress — it costs payout. You can brute-force
any match with enough respawns and earn almost nothing for it. That is the
accessibility floor and the skill ceiling in one mechanic.

**Status: pre-release.** No place has been published to Roblox. Every automated
gate passes; the manual Studio and live-service gates in
[`docs/PUBLISH_READINESS.md`](docs/PUBLISH_READINESS.md) are outstanding.

---

## Content constraint

Everything is paintball. No firearms, no blood, no injury, no death. Enemies are
hit, splattered, and out for the round. Markers, hoppers, barrels, air tanks,
velocity, FPS — never real-world firearm models, names or terminology.

This is a hard constraint, not a stylistic preference. Roblox rates violence by
whether its *consequence* is realistic, and a single realistic consequence pushes
an experience out of the **Mild** maturity target this project is designed to sit
inside. Features that would raise the rating do not get built.

---

## Toolchain

Managed by [Rokit](https://github.com/rojo-rbx/rokit); versions are pinned in
[`rokit.toml`](rokit.toml).

| Tool | Version | Role |
| --- | --- | --- |
| [Rojo](https://rojo.space) | 7.7.0 | Filesystem ↔ Studio sync, place builds |
| [Wally](https://wally.run) | 0.3.2 | Package management |
| [Lune](https://lune-org.github.io/docs) | 0.10.5 | Headless Luau runtime — runs the test suite and every check tool |

> **Apple Silicon note:** Wally 0.3.2 ships an x86_64-only macOS binary and needs
> Rosetta 2. This is not a build blocker — ProfileStore is vendored in-tree, so a
> Wally install is not required to build the place. See
> [`docs/PLATFORM_NOTES.md`](docs/PLATFORM_NOTES.md).

---

## Getting started

Everything below works on **Windows, macOS and Linux**. Nothing here needs a
Roblox account, and nothing here publishes anything.

```sh
git clone <this repo>
cd paintball

# Install the pinned toolchain (Rojo, Wally, Lune) and put it on PATH.
# Get Rokit itself from https://github.com/rojo-rbx/rokit
rokit install

# Everything: 13 gates, ending with the 469-spec suite. Takes ~8 minutes.
lune run tools/check-all
```

`rokit install` is the only setup step. There is **no `wally install`** — the one
runtime dependency, ProfileStore, is vendored in `src/ServerScriptService/Vendor/`
with its Apache-2.0 licence in `docs/licenses/`. A fresh clone builds and tests
with no package directory at all.

If `lune` is not on your PATH after `rokit install`, point at it explicitly:

```sh
LUNE=/path/to/lune lune run tools/check-all      # macOS / Linux
$env:LUNE="C:\path\to\lune.exe"; lune run tools/check-all   # Windows PowerShell
```

---

## Build and test

`tools/check-all` is the single entry point and the **only** place the gate list
lives. Individual gates, if you want one:

```sh
lune run tools/run-tests          # 469 specs across 19 files
lune run tools/ship-check         # release configuration gates
lune run tools/check-source       # Luau syntax across every module
lune run tools/run-live-checks    # MatchService against a mock engine
lune run tools/run-profile-checks # persistence adapter
lune run tools/check-budget       # part / shadow / alpha budgets per scene
lune run tools/check-zfight       # coplanar surfaces that shimmer in motion
lune run tools/check-client-ui    # HUD, shop, dialogue, tracers, input
lune run tools/check-characters   # every bot and civilian builds
```

Diagnostics that report but never fail a build:

```sh
lune run tools/probe-hitbox       # visible body vs the capsule the server shoots at
lune run tools/probe-ground       # what is seated on the floor and what hovers
lune run tools/probe-shadows      # shadow casters attributed by part name
lune run tools/foliage-report     # what the hub actually grows
```

Build the release place:

```sh
rojo build default.project.json -o build/paintball-release.rbxlx
```

Then open `build/paintball-release.rbxlx` in Roblox Studio and press **F5**.
Click the viewport to control the player.

On macOS only, `Check Release.command` runs `check-all` and then builds, and
`Play.command` rebuilds and opens Studio. Both are convenience wrappers — the
gate list they run is `tools/check-all.luau`, so no platform runs a different set.

There is a second project file, `tests.project.json`, for running the same specs
inside Studio via TestEZ. **It is currently incomplete** — it needs Wally packages
and a `tools/TestRunner.server.luau` that does not exist. Use the Lune runner.

---

## Layout

```
src/
  ReplicatedStorage/
    Shared/     types, constants, ballistics and lead maths
    Net/        remote definitions, one typed wrapper per remote
  ServerScriptService/
    Match/      match state, round flow, scoring
    Ballistics/ authoritative projectile sim + hit validation
    Bots/       bot controller, aim model, squad coordination
    Economy/    profile data, shop transactions, payout calc
    Telemetry/  shot log, aggregation, session summary
    Vendor/     third-party modules (ProfileStore)
  StarterPlayer/
    Client/     input, camera, prediction, HUD, tracers
Data/           JSON tuning — source of truth for every number
tools/          headless test runner, check tools, map probes
tests/          specs
docs/
```

Two rules govern this tree:

**`Data/*.json` holds every tunable value.** Nothing numeric is hardcoded in
Luau. Bot difficulty, marker stats, payout curves and map layouts all live there
so they can be tuned without touching logic.

**Nothing is authored in Studio.** If it is not in `src/`, it does not exist.
Anything created in Studio is invisible to source control and unrecoverable.

---

## Architecture

**The server is authoritative, always.** The client renders and predicts; the
server decides. Assume the client is compromised, because on Roblox it eventually
is.

Read the remote list in
[`src/ReplicatedStorage/Net/Remotes.luau`](src/ReplicatedStorage/Net/Remotes.luau)
as a security statement. Client to server, a payload is always an **intent** ("I
pulled the trigger, here is where I think my muzzle was") and never a **result**
("I hit bot3", "my balance is 9000"). There is deliberately no remote by which a
client can report a hit, a payout, a purchase price or a stat.

In practice that means the client's reported muzzle origin is discarded outright
— the server fires from its own muzzle, derived from the player's server-side
position.

### Monetization constraint

**Nothing purchasable may improve the player's accuracy**, reduce spread,
increase velocity, or otherwise substitute for aim. Cosmetics and convenience
only. This is a design constraint rather than a business one, and `ship-check`
asserts it against the catalogue on every run.

---

## What is playable

Whether a mode can be started is declared once, in
[`Data/gamemodes.json`](Data/gamemodes.json) as `integrated`, and nowhere else.

| Mode | Status |
| --- | --- |
| Gauntlet | Playable — five rounds, escalating squad |
| Shoothouse | Playable — timed course, solo |
| Horde | **Not playable.** Rules and specs exist; nothing starts them |
| Capture the Flag | **Not playable.** Rules and specs exist; nothing starts them |
| The Range | Playable — five aim drills, free, no payout |

Two-player co-op on the Shoothouse is authorized and **not yet built**. Every
co-op rule is implemented and specced, but the shared match is not: the
simulation identifies the player as a single entity, so two players on one course
requires two player capsules through `ProjectileSim`, `SquadCoordinator`,
`AimModel` and `ShotLog`. Until that lands the server refuses a second concurrent
match — without that guard, two matches would build two maps at the world origin.

`ship-check` refuses to publish a mode order containing an unintegrated mode, so
a deferred mode cannot return unnoticed.

---

## Verification

You cannot watch the game play, so the project builds its own eyes: TestEZ-style
specs for all pure logic, a headless match simulator that runs a full match with
a scripted player policy and dumps JSON, and structural check tools that assert
render budgets, character construction, gait, z-fighting and client UI behaviour.

None of these is a substitute for rendered performance or real DataStore
behaviour. What the automated suite cannot see is recorded honestly in
[`docs/PUBLISH_READINESS.md`](docs/PUBLISH_READINESS.md).

---

## Licence

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

Third-party components are attributed in `NOTICE`. ProfileStore
(`src/ServerScriptService/Vendor/ProfileStore.luau`) is vendored from MAD STUDIO
under Apache-2.0; its licence text is in
[`docs/licenses/ProfileStore.txt`](docs/licenses/ProfileStore.txt).
