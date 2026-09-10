# LiveRound — consolidated change report

Updated 2026-09-10. This is the single current update list and AI handoff. It supersedes the previous world-pass, publish-prep, Shoothouse, agent, progress and debug handoffs, including the historical paintball-insanity review. Older narratives and their superseded numbers remain in Git history; they are not current instructions.

## Tenth pass, 2026-09-10 — Handoff 003 repairs

Working against `Claude Handoff 003.md`, which found that the gates were green
and the game was not. Everything below is fixed, with a gate that fails on the
old behaviour. Findings still open are listed at the end; nothing here is
reported as done that was not run.

### The Range was pointing at the wrong place (findings 03, 04, 05)

`Drills` authors targets relative to the firing line with -Z forward, and the
live Range used those numbers as WORLD coordinates while standing the player at
z=-40 facing +Z. Holdover's 50 m target sat ten metres BEHIND the shooter; the
far Strafe lane was outside the floor. `check-range` solved its shots against
the same wrong numbers, hit 22 of 74, and passed.

There is now one local-to-world boundary, built from explicit basis vectors --
Lune's `CFrame.lookAt` returns an identity rotation for this very firing line,
and a transform the gates cannot check is one that will be wrong again.

Found while making the gate real:

| What was wrong | Now |
| --- | --- |
| The Range fired through `Spread` and never called `Spread.step`, so the cone grew on every trigger pull and never decayed. Within ten shots every drill was pegged at `sustainedSpreadDeg`. | Stepped every frame, as `MatchService` and `SimMatch` both do. Pop-Up went 19/48 -> 47/48. |
| Targets were spheres tested as capsules rooted at their centre: the hittable column ran from y-r to y+3r. | Zero-height capsule about the centre, which is a sphere. Grazing shots outside the visible ball now miss. |
| Switch's "three simultaneous targets" was three per lane with nothing expiring: **54 alive at 59 s**. | Each target expires when its lane's replacement appears. Bounded at three by construction. |
| `MarkerFired` from the Range carried no `spec`, and the client indexed `spec.muzzleVelocity` on every accepted shot. | A self event is an acknowledgement that reconciles the hopper. Only the squad's shots render. |
| `onFire` accepted shots past the deadline, so firing upward held a 60 s drill open past 80 s. | Deadline plus a bounded `shotDrainSeconds` window. |
| Switch graded time-since-reveal on a drill whose subject is the swing between targets. | `timeBetweenEliminationsMs`, measured from the previous elimination. |
| Expired targets counted as shots, making "accuracy" the fraction of opportunities taken. | Separate `shots` and `missedOpportunities`. |
| Pop-Up and Strafe declared a `secondaryFundamental` nothing measured. | Measured, on the same curve. |
| Peek's `announcedBearingDeg` was never sent, and placement was inferred from the previous SHOT -- on three angles sixty degrees apart, a perfectly parked player scored **zero**. | Clients stream aim (`ReportAim`), `Shared/AimHistory` answers reveal-time placement, and the cue arrives `cueLeadSeconds` ahead. Parked on the cue rates **99**; ignoring it rates **20**. |
| `DrillScore` had no client listener and nothing persisted a drill result. | A result panel, and a `practice` record kept deliberately apart from the match estimate. |
| The Range gate started `drillOrder[1]`, always. Holdover and Peek were reachable only by being told to practise them. | All five offered, with what each trains and what this player has managed on it. |

`RangeService.start` was a 600-line closure; it is a session context with named
phases, re-frozen at 138 lines. `check-range` now drives all five drills,
asserts announced range, forward hemisphere and berm containment for every
target position, and includes a control case proving crosshair placement
discriminates.

### One owner of the world at the origin (findings 01, 02, 10, part of 11)

Every scene is built at the world origin and `Hub.park`/`restore` are global.
Nothing owned that. Three partial guards existed and none covered a Range
session, a venue retained after the whistle, or the window while a character
load was yielding.

`World/Activity` is a lease over the origin, claimed before anything is
allocated and before anything yields, spanning preparation, play, the retained
venue and teardown, with cleanups registered at allocation time.

- A character load during a drill no longer restores The Landing on top of the
  firing line; routing dispatches to the **owner** rather than inferring hub
  eligibility from "no match".
- A second player joining mid-match is told who has the field instead of having
  the hub rebuilt around them.
- A match and a drill can no longer run at once for one player, both consuming
  `FireMarker`.
- `finish` kept the venue so the player could shop, and kept the **map root**
  too. Nothing destroyed it, and The Landing was restored at the same origin 2.5
  s later, on top of it. `MatchService.disposeVenue` is the boundary now.
- `returnTokens` incremented at the top of `requestMatch`, before validation, so
  a **rejected** replay invalidated a pending return. Lease identity replaces it.
- `CharacterAutoLoads` is off and only paint elimination reloaded a character,
  so native reset and falling out of the world left the player with none,
  indefinitely. Recovery routes through the activity owner: a match charges the
  out, the Range puts them back on the line.
- The results panel was destroyed 2.5 s after appearing. It survives the walk
  home now (`keepResults`).

**`tools/check-activity` drives `Bootstrap.server.luau` itself** against a
scheduler this repo controls, character loads it can interleave, and signals
that really disconnect. Fourteen transitions, asserting world parentage,
ownership, listener counts and where each player ends up. Reverting the routing
fix fails it on the exact symptom the audit reproduced.

### Season pass, audio, Horde and records (findings 07, 08, 12, 13)

- **`Commerce.owns` looped over an offer's grants**, and `seasonPassS1` grants
  nothing on purpose -- it unlocks a track. Zero iterations, returns true. Every
  fresh player was told they had already collected it while `SeasonPass.ownsPass`
  said false. Ownership is split by kind; both sides read the same field; a free
  claim writes the entitlement, requires it in its own save confirmation, and
  announces through `onPassResolved` as a purchase does.
- **`MatchSummary` played `matchCleared` then called `Audio.clear()`** on the
  same frame, which destroys the folder every voice is parented to. The one cue
  that says you won was silenced the instant it started, on every clear, without
  an error or a bad id. `check-client-ui` now asserts the sequence and fails on
  the old ordering.
- **Horde**: `Endless.payoutFor(depth, 0)` meant `bossBonus` was multiplied by a
  literal zero; no writer ever set `hordeBest` or `bossesBeaten`, so The Long
  Afternoon's own chapter goals could not be met by playing it; settlement
  omitted `deathPenalty`, so a run that lost half its payout reported x1; and the
  declared wave leaderboard was gated on `cleared`, which horde never is. All
  four fixed, with a **depth board** that ranks deepest-first and has its own
  validation. The HUD says WAVE n rather than a fraction whose denominator grew
  to meet its numerator.
- **Entry authorization** was three disagreeing checks: the NPC checked
  `hordeUnlocked` and the public remote did not, `modes[mode].maps` was authored
  and enforced nowhere. One `modeRefusal` path now, returning the sentence rather
  than a boolean, and the gate and NPC both show it instead of closing in silence.
- **Records leaked across modes**: leaderboard metadata was keyed `{map}_{userId}`
  so a course best overwrote a gauntlet best's tier and marker; `bestTimes[map]`
  was written by whichever mode posted last and stored the raw clock even for a
  course ranked on the death-penalised time; the notice board read every page
  with no mode, so course boards had no browsing route; and the personal page was
  one shared closure replaced by whoever refreshed last. All separated.
- **A Shoothouse clear opened the next map.** `hasUnlocked` read `bestClears`
  (which keeps the cleanest clear whatever produced it) while the campaign
  chapter gating the same progression read `gauntletClears`. `gauntletClears` has
  one writer now and is the single unlock authority; clears recorded before they
  named their mode still count.

### The kit does something now (finding 06)

`GearStats.resolve` had specs, a shop, prices, chapter rewards -- and **no
production caller.** `Shared/Loadout` is the snapshot both the server and the
client's prediction consume: loudness, sprint, crouch, slide duration and
cooldown, reload, pod count, hopper capacity and feed rate.

- **A reload was free and infinite**, so the four-pack and the six-pack were the
  same item at different prices. `podCount` is a finite per-round budget now, and
  the HUD shows it.
- **Ordinary marker loudness was disconnected.** `playerLoudness` was set only
  for a CTF flag carrier, and `BotController` enters its hearing branch only when
  it has a value -- so a squad could not hear an ordinary player at all, and
  every quiet/loud tradeoff in the barn bought nothing.
- **The carrier movement cost was a "sprint multiplier" applied to every kind of
  locomotion**, including crouching. It applies to sprinting.
- **Barrels, hoppers and tanks** now reach loudness, reload, capacity and feed
  rate. `spreadMultiplier`, `velocityMultiplier` and `velocityConsistency` are
  deliberately **not** read, and `ship-check` asserts `Loadout.resolve` does not
  consume them: a flatter, more consistent arc is less lead to work out, which is
  substituting for aim.

**This changed the difficulty, and the change is real.** Connecting the squad's
hearing makes the game harder. Measured on `probe-difficulty`, Speedball, six
seeds, mean outs:

| Tier | Before | After |
| --- | --- | --- |
| rec | 0.83 | 1.00 |
| amateur | 2.17 | 2.33 |
| semipro | 7.17 (6/6 clears) | 9.33 (5/6 clears) |
| pro | 11.50 | 12.67 |

That is the consequence of a feature that was advertised and dead becoming
live, not a tuning change. **It is the user's call whether to retune against it.**
`SimMatch` was connected at the same time and by the same function, so the
simulator and the live game cannot describe different games.

### Where the gates stand, 2026-09-10

`lune run tools/check-all`: **21 of 23 gates pass.** The spec suite is
**555 passed, 1 failed, 0 skipped across 24 spec files** (the audit measured 526
passed / 2 failed across 24).

The two failures are both known and neither is new:

- **`ship-check`** — `Data/dev.json` still has invulnerability, infinite currency
  and `unlockEverything` on. This is the release blocker the audit named and it
  is deliberately still on for playtesting. Every other ship-check item passes,
  including the new "no purchasable attachment reaches spread or velocity".
- **`run-tests`** — `the difficulty curve > punishes trading harder than holding
  angles` still fails, exactly as it did at the audit. The other balance failure
  the audit reported, `orders Speedball below Woods by a wide margin`, now
  passes. No assertion was weakened; the difference is the squad being able to
  hear the player, which is measured above.

### Still open from Handoff 003

- **Finding 06, appearance half.** Purchased jerseys, helmets, shoulders and
  masks still do not appear on the player's own avatar. `Wardrobe` dresses
  authored NPC and bot outfits; a composable per-slot system attached to a real
  Roblox character is a separate piece of work and cannot be verified headlessly.
- **Finding 09, stance and muzzle coherence.** Crouch, slide and lean still move
  the camera while the server uses a standing capsule and a chest muzzle, no
  lean intent is transmitted, and crouch is partly inferred from a client
  boolean. Movement and CTF capture positions are still taken from the replicated
  root without displacement validation.
- **Finding 11, delayed commerce notices** can still put the client into hub
  phase while server combat is live.
- **The two balance acceptance specs** (`punishes trading harder than holding
  angles`, `orders Speedball below Woods by a wide margin`) still fail, as they
  did at the audit. They were not touched, and the difficulty change above is
  measured separately rather than being used to explain them away.
- **Rendered validation remains open** exactly as the audit left it: meshes,
  audio delivery, first-person sight picture, frame time, safe areas, real
  DataStore persistence.

## Capture the Flag integration, 2026-09-09

**CTF now runs through the live MatchService.** Enter **THE VALLEY / Holdfast** at the hub's primary prompt; the other prompt remains Shoothouse. The production gate requires the Back Forty chapter. The existing dev `unlockEverything` setting permits temporary playtesting without writing chapter progress or cosmetic ownership.

| Area | Implemented behavior | Verification |
| --- | --- | --- |
| Entry and replay | Holdfast gate dispatches CTF, rejects unsupported maps/locked profiles on the server, preserves the selected mode on Play Again. One field remains active at a time. | Live service gate checks; client replay payload includes mode. |
| Flag rules | Touch pickup, exact-position drops on elimination/disconnect, friendly touch return, 22-second idle return, own-flag-home capture requirement, first to three, ten-minute score/draw limit. | 36 CTF specs; live pickup/capture/denial/recovery/victory/timeout checks. |
| Opponents | Six bots split between defense and attack, change the split with the score, pursue a stolen flag, return home as carriers and escort runners. Existing sight, reaction, melee and stop-to-shoot rules remain in BotController. | **Actual bot controllers completed three autonomous captures in 153.2 seconds of simulated match time**, with no player target. This proves objective routing; it is not a difficulty or FPS measurement. |
| Arena access | CTF-only prepared map data puts flags/spawns on supported keep decks and adds 152 physical stair/landing parts at both keeps and the bridge. Navigation checks body clearance, slope and support, and finishes at the flag rather than stopping at the nearest nav node. Terrain solids also block authoritative paint in CTF. Original Shoothouse data is unchanged. | Full route traversed in both directions; real WorldBuilder built all 152 collidable approach pieces; static `build/ctf-review.rbxlx` available. |
| Respawn and cleanup | Players return after four seconds; tagged bots return after nine, in their own keep with fresh IDs. Wiping the squad does not end CTF. Pending player respawns cannot revive a stopped match; objective visuals and bots are removed on finish. | Live service tests include timed delayed callbacks, whole-squad replacement, carrier elimination and stopping during a pending respawn. |
| Feedback | Blue/orange flags and world labels, score, countdown, flag state, capture instructions and event banners. Carrying slows movement and makes movement audible to nearby bots. Objective snapshots avoid restarting music/round effects. | UI construction, blocked-capture explanation, countdown, result display and slowdown/restore checks. |
| Results and progression | Captures/returns/win bonus use server counters with the configured death and accuracy multipliers. Summary distinguishes player win, bot win and draw. Settlement happens once; CTF cannot write Gauntlet/campaign clear records or enter the time leaderboard. | Live objective payout and repeated-stop checks, zero-pay idle draw and bot win, clear-table isolation. |
| Shared code | Persistent match rewards moved to `MatchProgress`; visibility bookkeeping extracted from the step. Function-length limits were retained, and Gauntlet/Shoothouse/Horde smoke flows still pass. | Static gate and existing live smoke tests. |

**Validation:** CTF-specific specs, live lifecycle tests, autonomous navigation, client UI, source/static/config checks and Rojo playtest build pass. The full 22-gate debug run is recorded below once complete. Studio's actual rendered gameplay and handling still need the user's playtest; automated engine-boundary checks do not establish visual approval.

**Builds:** `build/paintball-ctf-playtest.rbxlx` is the playable project build. `build/ctf-review.rbxlx` is a static inspection scene. The current `Data/dev.json` master override is **on**, as left by the earlier playtest pass; this intentionally fails the release gate and allows invulnerability/free-wallet behavior. It was not disabled or published by this CTF pass. Automated checks explicitly run with overrides off.

## Ninth pass, 2026-09-09 — Horde runs

Horde did not work. Its rules were complete and spec-covered from the start --
wave scaling, tier ladder, breathers, bosses, veterancy, payout, drop tiers --
and **nothing started them.** It runs now, and `run-live-checks` proves it by
playing one: six waves appended and cleared through the ordinary `MatchService`
loop, 52 bodies fielded including reinforcements.

**The architecture already supported it, which is why this was tractable.** A
mode here is a *schedule*, not a second match loop. The gauntlet lays out five
rounds and the Shoothouse lays out its stages; horde lays out wave 1 and appends
the next each time one is cleared. Firing, hit validation, lag compensation,
telemetry and respawn are one engine serving all three.

**Its failure condition already existed too.** In a game with free unlimited
respawns and no health, what ends an endless run is the ordinary 200-second
round limit: clear the wave inside it, or the run ends at the depth you reached.
"It does not have an end, only a depth you stopped at" turns out to be the round
clock said out loud. No new failure state was invented.

| Area | Before | Current behavior | Verification |
| --- | --- | --- | --- |
| The wave loop | `Endless` was pure and nothing ran it. | `Endless.round(index)` expresses a wave as a round the ordinary loop executes, and the schedule appends the next wave on each clear. `integrated: true`, in `order`, still gated behind the pro circuit by `progression.modeUnlocks.horde` — integrated means it runs, not that everyone can reach it. | New Horde block in `run-live-checks`; 10 new specs in `tests/Endless.spec.luau`. |
| Reinforcements | Rounds fielded their whole bot count at once. | A wave totals up to 28 but only 12 stand on the field at once; the rest arrive one-for-one as bots are taken out. Twelve is what every difficulty number in this project was measured against, so reinforcing keeps that true at wave 40. Fed by paint **and** the melee. | `run-live-checks` fields and clears 52 bodies across six waves. |
| Veterancy | `applyVeterancy` existed and nothing called it. | Each bot gets a **copy** of its tier parameters, adjusted per wave and clamped at human floors (120 ms reaction, 0.45°). A copy because wave 30 must not permanently ruin wave 1 — the existing spec asserts exactly that. | `Campaign.spec` horde-wave assertions, unchanged and passing. |
| Bosses | `Boss.luau` existed; nothing fielded one. | A boss wave fields a marshal as its first unit. `bosses.json` says a marshal is still one hit — *"paint on the body does not count, only the hopper"*, because a boss with three thousand health would be a bullet sponge in an aim trainer — and that needs **no new hit model at all**: a marshal simply presents a different target. Its capsule is a 0.18 m sphere at hopper height instead of a body, so body shots miss because there is nothing there. | `Endless.spec` asserts the marshal's target is the hopper, is less than half an ordinary bot's height, and still dies to one mark. |
| Breathers and milestones | — | The per-wave pause: 22 seconds every fifth wave, none otherwise. Milestone lines ride the intermission notice. | `Endless.spec`, `run-live-checks`. |
| Payout | — | Paid once, for depth, superlinearly — three runs to wave 10 must not beat one to wave 30, or farming the shallow end becomes optimal, which is the opposite of what an endless mode is for. The ordinary death penalty still applies. | `Endless.spec`; a live run paid 746. |
| The one route in | The `startHorde` dialogue branch refused — and refused **silently** to anyone who had not unlocked it, because the message sat inside the unlock check. The one NPC whose job was to send you to Horde said nothing at all to exactly the players it was gated against. | Starts the run for anyone who has swept the pro circuit, and tells everyone else what they are missing. | `run-live-checks`. |

**The length ratchet earned its keep immediately.** Integrating Horde pushed
`MatchService.start` from 1,136 lines to **1,260**, and the gate built one pass
earlier refused it — which is exactly the moment a God object usually gets a
little worse and nobody notices. The frozen number was not raised. Placement,
construction, the respawn point and the speaker lookup moved into a new
`Match/Squad`, and the bearing arithmetic moved into `Chatter` where it belonged;
`MatchService.start` came back to **1,133, below where it started**. `step` and
`finish` are one line larger each — the one line each needed to know horde
exists — and are re-frozen there rather than pretended away.

**Two specs pinned the deferral rather than the rule**, and both were updated
deliberately now the owner has asked for the mode. `Course.spec`'s "does not
pretend Horde or Capture the Flag are playable" was split: CTF's half is
unchanged, and Horde's was replaced by **"offers exactly the modes something can
start"**, which checks the property in both directions instead of naming modes
and so cannot go stale the next time this happens. `Campaign.spec`'s "keeps
deferred Horde closed even after the pro sweep" became "opens once the pro
circuit is swept, and not before"; the three assertions around it — locked at
start, locked through the whole ladder, not open on a partial sweep — are
untouched and passing.

**Still open in Horde.** Kit drops on breathers and boss waves are wired in the
data and do nothing, because `consumables.liveEnabled` is false — the field kit
withheld from the shop in the eighth pass. Horde runs fine without them; the drop
table is inert. And `bosses.json`'s `hopperRadiusMetres: 0.18` is *named* a
radius while the prose beside it says "about eighteen centimetres across", which
would make it a diameter; it is read as named — the more forgiving reading — and
flagged here rather than silently halved.

**Debug rerun: 19 of 21 gates pass, 521 specs pass, 2 fail.** The known pair
only: `ship-check` (dev mode on by request) and the two balance specs. Spec count
510 -> 521.

## Eighth pass, 2026-09-09 — a gate that was measuring nothing

Nothing was left over from the merge and push: every branch was already
contained in `main`, so no merge commits existed to clean up.

| Area | Before | Current behavior | Verification |
| --- | --- | --- | --- |
| **Every callout said "front"** | `Chatter.bearingWord` — a written, carefully commented function mapping an angle to "left / front right / behind" — **was never called from anywhere.** `context.bearing` fell through to its `"front"` default every time, and five authored callouts interpolate it. Every contact in the game was reported as "Contact! front!" regardless of where the player was, and "I'm rotating front." is not even English. | Wired, measured from the **speaker's** facing: a bot saying "left" means you are on its left, which tells you where it is pointed. Pairs with the positional chatter from the seventh pass — the bot says which way and you hear which way. | New `tests/Chatter.spec.luau`: boundary words, wrapping past a full turn, exactly six words (a squad calling exact degrees is a wallhack), and a bank scan asserting no line interpolates a placeholder nothing fills. Arithmetic verified in seven orientations including a rotated speaker. |
| **Rule 4 measured nothing** | `check-static`'s function-length rule had two bugs and reported "every rule holds" through both. It split lines with `gmatch("[^\n]*")`, which yields an empty match after every line — 2,666 lines counted in a 1,352-line file, so it reported a function at **line 2280 of a file that ends at 1352**. And it popped its function stack on *any* line that looked like an `end`, so the first `if` inside a function closed it. **It measured `MatchService.start` — 1,171 lines — as 82.** | Extent taken from indentation, which is what this codebase actually guarantees and which is immune to the `if x then a else b` expressions a keyword counter cannot distinguish from a block. Block comments are blanked with their newlines preserved so line numbers stay true. | 22 advisories now appear with correct line numbers. The 15 functions already over the hard limit are **frozen at their measured length** — a ratchet, so debt can shrink but not grow. Both halves verified by sabotage: growing a frozen function fails, and a new 163-line function fails. |
| Match settlement | `finish` was 228 lines inside that 1,136-line closure, carrying both payout rules inline. | `Match/Settlement` owns the one piece with a single responsibility and no engine surface: what the match was worth, and by which of the two rules — per round for a gauntlet, per medal for a course whose clock already charges deaths at ten seconds each. `finish` 228 → 193; `MatchService.start` 1,171 → 1,136, and both frozen numbers came down with them. | `run-live-checks` payouts are **identical to the digit** before and after (0 / 110 / 1142), which is what makes this behaviour-preserving rather than hopeful. |
| Shop bloat | Eight field-kit rows rendered as "PREVIEW / Coming later" — a whole tab of things the player cannot have, on the screen where they decide to spend money. That reads as an unfinished game at exactly the wrong moment. | The server omits the category until `consumables.liveEnabled` is true, and the client drops any category that arrives empty, the way the `offers` tab always has. **The first version of this was wrong and the suite caught it:** hiding the rows left the barn's physical counter still advertising field kit, which `Overworld.spec` names exactly — "a bay listing a category the shop cannot price is a counter the player walks up to and finds empty". The bay listing came out too, and `ship-check` now requires the flag and the counter to agree **in both directions**, so turning field kit on without restocking the counter fails as loudly as turning it off without unlisting it. | `check-client-ui`, `ship-check` (both directions verified by sabotage), `Overworld.spec`. |
| Dead remote | `FlagEvent` was declared, created on the server at boot, and had no sender or handler anywhere. | Removed. An unused `RemoteEvent` in a server-authoritative game is a wire a client can fire into that nothing validates — harmless today, and not worth keeping for a mode nothing starts. | `check-static` reachability, `run-live-checks`. |

**A stale assertion, found on the way.** `Overworld.spec`'s "puts every sellable
category behind exactly one counter" checked a hand-written list of eight
category names. It went stale the moment field kit stopped being sold — it
asserted `consumables` sat behind a counter while the shop deliberately stocks
none — and it had quietly omitted barrels, hoppers, tanks, masks and marker
finishes all along. It derives from the real catalogue now, like its sibling
check already did: self-maintaining, and stricter than the list it replaced.

**Deferred modes: reported, not deleted.** Horde, Capture the Flag and the boss
rules are 707 lines of Luau, 201 of JSON and a spec file for modes nothing can
start. That is real bloat and it is the obvious thing to cut — but Capture the
Flag's data includes **authored flag positions inside `Data/maps/holdfast.json`**,
which is hand-made level design, and `Campaign.spec`'s horde-gating assertions
are what currently guarantee Horde *stays* unreachable. Deleting the modes would
also delete that guarantee. They cost nothing at runtime. This is a call for the
owner rather than one to make unilaterally, so it is flagged here instead.

**Debug rerun: 19 of 21 gates pass, 510 specs pass, 2 fail.** The known pair only: `ship-check` (dev mode on by request) and the two balance specs. The two regressions this pass introduced were both caught by the suite and fixed at the source. Spec count 504 -> 510.

## Seventh pass, 2026-09-09 — sound design: the squad becomes audible

The sixth pass built the plumbing. This one makes it a design rather than a set
of noises: a mixing desk, a listener, and — the part that changes how the game
plays — **positional enemy fire**.

| Area | Before | Current behavior | Verification |
| --- | --- | --- | --- |
| Enemy fire | Silent. Every cue was flat 2D, so the squad made no sound at all and could only be found by looking. | `MarkerFired` has carried the origin of every enemy shot since the tracers were built — the client was rendering from it and not listening to it. Enemy fire, paint landing and a bot going down now play at their point in the world. **This is the gameplay change in this pass:** "which direction did that come from" is the question this entire game is built around asking, and until now it had no answer that was not visual. | `check-client-ui` asserts the anchor part is moved to where the cue happened, since a sound in the wrong place is worse than no sound. |
| The mixing desk | Each module built its own output. | `Client/AudioMix`: one `AudioDeviceOutput`, an `AudioFader` for effects and one for music, and the listener. Everything audible passes through it, so "music down, effects up" is two numbers in `audio.json` rather than an edit in every module that makes a noise. | `check-client-ui` asserts both buses reach the output and that 2D cues reach the effects bus. |
| The listener | None existed, so an emitter would have played to nobody. | An `AudioListener` on the **camera** — 3D audio is heard from where the player is looking, not where their feet are. Roblox replaces the camera on respawn, so it is re-parented every frame and does nothing on the frames where nothing changed. Without that the game would quietly lose its hearing after the first death, which is the kind of bug that gets blamed on the map. | `check-client-ui` replaces the camera and asserts the ear follows and the old camera keeps nothing. |
| Ducking | Applied per-deck, against the crossfade. | Moved to the music bus. A duck per deck is three ramps arguing about one volume while two decks head for different levels; on the bus it is one gain over whatever the decks are doing, which is what a mixing desk does and what the ear expects. | `check-client-ui`. |
| Distance curve | — | `spatial.attenuation` in `audio.json`, in metres like every other distance a designer reads here. This is a **gameplay** decision, not a polish one: it decides whether a marker forty metres away is information the player can act on or noise they learn to tune out. It reaches silence at 140 m so nothing audible outlives its own paintball. | `check-audio` asserts it starts at 0 m, never gets *louder* with distance, and actually reaches zero — a curve bottoming out above zero leaves every shot on the field permanently in your ears. Verified by planting a rising curve. |
| Hub ambience | The last user of the legacy `Sound` object. | Migrated: each bed is an `AudioPlayer` → `Wire` → `AudioEmitter`, with its own radius-based curve — a creek should be something you walk into and out of, not a thing audible across the whole landing. **Nothing in the project uses `Sound` any more.** | `check-budget` caught the migration breaking the hub build outright: Lune carries `AudioEmitter` but none of its methods. Guarded the way `Atmosphere` guards `Clouds`, and it logs rather than swallowing. |

**A pre-existing bug this pass surfaced.** `MarkerFired` is sent by two
services and they disagreed about units and about meaning. `RangeService` sent
`Units.vectorToStuds(muzzle)` while `Tracers.fire` takes metres and converts them
itself, so every tracer on the range began three and a half times further from
the player than the muzzle it claimed to come from — nothing failed, nothing
logged, it just looked slightly wrong in the way that gets blamed on the tracer
effect. Worse for this pass: `MatchService` sends that remote only for shots the
*squad* took, and the range sends it for the player's *own*, so wiring enemy-fire
audio to it would have played a threat sound at the player every time they fired
on the range. Both fixed — metres, and an explicit `source` field. `check-range`
now asserts the origin's height is chest-high in metres rather than four in
studs, which are not confusable; verified by reintroducing the bug.

**Squad chatter has a direction now.** `ChatterLine` carries where the voice came
from — looked up by speaker name in the one place that has the roster, rather
than threaded through every `ctx.chatter` call site. People shouting on a
paintball field give their position away, which is both realistic and a skill
signal. It is deliberately not a free map of the squad: `rangeScale` shrinks the
shared curve per cue, and chatter is scaled to about a third of a marker's
report, so it is a close-quarters tell and nothing more. How far a sound carries
is a property of the sound, not of the speaker, so the curve is applied per play
rather than baked into the pooled emitter.

Three cues added, all positional: `enemyFire`, `paintImpact` and `chatter`.
Fourteen cues now, four of them world-positioned; every cue declares whether it
happens *somewhere* or in the player's own hands, because your own marker is not
a place — and `check-audio` rejects a `rangeScale` on a cue that is not
positional, since it would do nothing.

**Debug rerun: 19 of 21 gates pass, 504 specs pass, 2 fail.** The known pair: `ship-check` (dev mode on by request) and the two balance specs. No new failure.

## Sixth pass, 2026-09-09 — sound, on the API that actually exists now

**There has never been sound in this project.** Checking the history rather than
guessing: every mention of audio in every commit is a note saying the ids are
deliberately absent. What exists, and what is easy to remember as "there were
some sfx", is the hub's four *ambience emitters* — forest, creek, pond, barn hum
— placed, positioned and configured since the world pass, with `soundId: null`
on each. They are real objects in the world that have never made a noise.

A correction to something said earlier in this project's notes: this repository
is **not** free of uploaded assets. The environment art `.rbxmx` files carry
`rbxassetid://` references for meshes and textures. The constraint on audio was
never a project rule about uploads — it is Roblox's **audio privacy** rule, and
that rule has a documented way around it.

| Area | Before | Current behavior | Verification |
| --- | --- | --- | --- |
| The audio API | `Client/Audio` was written on `Sound`, and so is the hub ambience. | Checked the docs before building, per CLAUDE.md: **`Sound`, `SoundGroup` and `SoundEffect` are discouraged.** The current objects are `AudioPlayer` → `Wire` → `AudioDeviceOutput` for 2D, plus `AudioEmitter`/`AudioListener` for 3D. Nothing routes implicitly — an `AudioPlayer` with no `Wire` is silent and reports no error, which is the easiest way there is to lose an afternoon. Both new modules are on the current API. Findings recorded in `docs/PLATFORM_NOTES.md`. | `check-client-ui` builds the real graph and asserts the wire connects player to output, because that is the failure that would otherwise survive a whole playtest. |
| Sound effects | Eleven cues wired, on the discouraged API, reclaiming voices via `Ended`. | Rebuilt on `AudioPlayer`. Voices are reclaimed by a per-cue `lengthSeconds` hint rather than by `Ended` or `IsPlaying` — an asset that fails to load may never fire `Ended`, and anything waiting on it would leak voices until the concurrency cap was hit and the game went permanently silent with no error to explain it. | `check-client-ui`, `check-audio`. |
| Music | None. | `Client/Music`: two decks so a crossfade has something to fade into, one track picked per context, ducking, and a fade that is frame-rate independent. It is driven from the client's existing presentation loop rather than opening a render connection of its own. **Music ducks on purpose** — this game is an audio-information game, and a track competing with the report of a marker or the direction of a hit is a handicap, not atmosphere. The match playlist sits at 0.55 against the hub's 1.0. | `check-client-ui` asserts two looping decks, the wiring, that the fade moves, and that teardown leaves nothing behind. |
| Phase → track mapping | — | In `audio.json`, not in a branch in the client. This was not the first design: the gate scraped `Music.setContext(...)` call sites and immediately reported three playlists that do not exist, because the one call site chose its context with an inline conditional and the scrape read the *phase* names. Moving the mapping into data fixed the gate and the client at once. | `check-audio`. |
| Silent-failure gate | Nothing checked the audio data. | `tools/check-audio`, gate 4 of 21. Every id is null or a well-formed `rbxassetid://<digits>`; volumes and lengths are in range; every situation maps to a playlist that exists and every playlist is used. **The one it will actually catch:** a bare number pasted instead of the full string — the most likely mistake anybody will make with this file, whose symptom is silence indistinguishable from not having filled it in. Verified by planting one. How much is still silent is *reported and never failed*, because silence is the shipped state and a gate that cries every run is a gate everyone ignores. | Gate passes; reports 11/11 cues and 3 playlists still empty. |
| Where to put music | Nowhere. | `assets/audio/` with `music/` and `sfx/`, a README carrying the verified upload limits (mp3/ogg/wav/flac, under 20 MB, under 7 minutes, ≤48 kHz; 2,000 free uploads per 30 days ID-verified, 100 unverified), the licence warning that "free to download" and "free to publish inside a product that earns Robux" are different permissions, and the audio-privacy trap: someone else's private id plays in Studio and is silent once published. Media files are gitignored — the structure is tracked, the binaries are not. | — |

**The game is still silent, and now that is a two-minute job rather than a
project.** Roblox's Creator Store carries over 100,000 free-to-use sound effects
and music tracks that need no upload at all: Studio → View → Toolbox →
Marketplace → Audio, right-click → Copy Asset ID, paste into `Data/audio.json`.
Every cue is already called from the right moment.

**Debug rerun: 19 of 21 gates pass, 504 specs pass, 2 fail.** The two gate failures are the known pair: `ship-check` fails because dev mode is on by request, and the same two balance specs fail. No new failure introduced.

## Fifth pass, 2026-09-09 — dev mode on, and the things a playtest would have hit

**`Data/dev.json` `enabled` is now `true`.** That is deliberate and it is the
user's call for playtesting: infinite currency, everything earned unlocked, and
an unkillable player. `ship-check` fails while it is on, by name, listing every
active flag — that failing gate **is** the reminder to set `enabled: false`
before publishing. Nothing else needs to be undone.

| Area | Before | Current behavior | Verification |
| --- | --- | --- | --- |
| Invulnerability | The only dev flags were currency, unlocks, round skip and tier pinning. There was no way to stay on the field. | `dev.invulnerable`: paint still hits you, bots still call it, the round carries on — you are simply not taken out. Refused at `eliminatePlayer`, the one place a life ends, so a body shot, a headshot and a shove are all refused identically. Deliberately **not** health: this game has no health bar, and giving a dev flag a hit-point pool would mean shipping rules nobody plays. `SimMatch` never reads a dev flag, or every balance number would start describing a player who cannot die. | New `run-live-checks` block turns the flag on, fires a hit batch, asserts nothing was charged, and turns it off. |
| Gates vs. dev flags | Every gate read the developer's local `Data/dev.json`. Turning `invulnerable` on immediately broke `run-live-checks` — "one batch must only charge one player elimination" failed because nothing could charge one. | The harness pins all overrides off once, for every tool. Gates measure the shipping game; a check that wants a flag turns it on itself, so the flag reads as that check's subject rather than as ambient state. | `run-live-checks`, `check-persistence` and the full spec suite are now independent of the local dev file. |
| Dev mode visibility | The server printed a banner at boot. The person who forgets a flag is the one playing, who never reads the server log. | A HUD badge naming the active flags, so an unlocked wallet and an unkillable player are distinguishable at a glance. | `check-client-ui`. |
| Fixed-step catch-up | The Heartbeat loop ran as many 16.7 ms steps as elapsed time asked for. One long frame — an asset load, a breakpoint, a hitching client — asked for sixty steps of twelve bots and every projectile inside a single frame, which takes longer than a frame, which makes the next dt larger. One hitch becomes a freeze. This was a known gap and is now closed. | `ballistics.simulation.maxStepsPerFrame: 5`. Surplus time is **dropped**, not carried, because carrying it is the same spiral written differently — a stall costs simulated time instead of the server, and the first drop in a match is logged so a real performance problem cannot hide behind the cap. | `run-live-checks` now delivers real 1/60 frames instead of single ten-second Heartbeats, which no engine ever sends; every live check passes against the bounded loop. |
| Bots shoving | A bot at contact range took a player out while standing perfectly still. | The marker actually swings, off the same timeline the first-person swing reads, on the controller's own clock. The commit delay exists to be seen; a warning nobody can see is not a warning. | `check-characters` asserts the marker moves at the contact frame and returns to rest for all five tiers. |
| Melee hit confirmation | A shove fires no shot, so it produced no hit marker — the one attack that happens at arm's length was the only one with no confirmation on screen. | The hit marker flashes on a melee elimination. | `check-client-ui`. |
| Sound | The game made none, and there was no plumbing for any. The hub's ambience beds were the only audio code in the project. | `Data/audio.json` names all eleven combat cues — fire, dry fire, reload start and end, hit, headshot, both eliminations, the shove, round start, match cleared — and every one is already called from the right moment in the client, through a pooled `Audio` module capped at twelve concurrent voices. **The ids are empty and the game is still silent.** Audio belongs to whoever uploaded it; hardcoding an id ships a build that is either silent or moderated out from under you, which is the same reasoning `Data/overworld.json` already applies to the hub's ambience. Paste a Creator Store id into a cue and it plays — there is nothing else to wire. The file carries the instructions for finding one, including the audio-privacy trap: a sound that is not yours or not public will play in Studio and not in a published place. | New `check-client-ui` block: every authored cue is played by something, every played name is an authored cue (it immediately caught a call site the first pattern could not read), and playing all eleven with no ids supplied is a silent no-op rather than an error. |
| Stale module list | `check-client-ui` stubbed client modules from a hand-written list whose own comment warned that a hand-edited list goes stale silently. It had gone stale: `Audio` was not in it. | Read from the directory. | The gate stubs any new client module the moment the file exists. |
| Earned cosmetics in dev | `unlockEverything` opened map-clear gates only, so a playtest cannot see the camo ladder or the season's paid column. | **Unchanged, after an attempt to extend it was reverted.** `Camos.spec` turns that exact flag on and asserts the camo stays locked, and the Aurum route asserts the same for course medals — a deliberate invariant: those ladders are earned, they write into the saved profile, and a flag that could forge them would turn the one thing in this game you cannot buy into something you switch on. The spec caught it; the reasoning is now recorded in `dev.json` beside the flag so the next person does not retry it. | 502 specs; the two camo invariants pass again. |

**Debug rerun: 18 of 20 gates pass, 504 specs pass, 2 fail.** Both failures are known and named: `ship-check` fails because dev mode is on by request and lists every active flag, and the same two balance specs fail as before. No new failure introduced.

## Fourth pass, 2026-09-09 — the butt of the marker, and what it is attached to

The barrel tag from the third pass is gone. It was a rule that asked the squad to
decline a shot at four metres, which reads as the bots refusing to play. In its
place is the thing anyone who has held a marker actually does at contact range,
and the marker itself got the pass it needed to be worth swinging.

| Area | Before | Current behavior | Verification |
| --- | --- | --- | --- |
| Melee | The barrel tag: a bot inside 4 m stopped shooting and tagged you out. The player had no contact-range option at all. | `hitRules.melee` — 2.4 m, a 110° arc, a 1.0 s cooldown, and a 0.45 s swing that lands at 38% of the way through. Both sides have it: the player shoves with `V` / right-stick click, bots commit to a swing, stop, say something, and connect a moment later. The geometry lives in one shared `Melee` module so the live server, the bots and the headless sim cannot drift apart. | 14 new specs in `tests/Melee.spec.luau`; new server-side melee block in `run-live-checks` covering reach, arc, cooldown and payload validation. |
| Melee authority | — | The client sends one thing: which way it was facing. Where the player stood, who was in reach and whether the cooldown had elapsed are all decided server-side against the server's own position, so the payload cannot name a victim and mashing the key cannot beat the cooldown. A whiff spends the cooldown too. | `run-live-checks` asserts a swing at nothing, a swing behind the player, a payload carrying a `targetId`, and a malformed payload all eliminate nobody. |
| Melee and telemetry | — | A shove counts as an elimination and pays out, but it logs **no shot** and **no headshot**. Aim statistics stay aim statistics, and contact range is not a way to grind camos. | Deliberate; recorded here because it is invisible in the code. |
| Combat animation | `CombatMotion` interpolated one timeline (the reload) and recoil was a straight line from full displacement to zero — which reads as the marker being dragged backwards rather than kicked. | Keyframe sampling is shared, so the reload and the new six-frame swing interpolate identically. Recoil is now a damped spring: full on the frame of the shot, fast recovery, one small overshoot past rest. A swing outranks a reload on screen while the hopper lid keeps following the reload underneath, so an interrupted pour does not strand the lid open. | `check-client-ui` holds through the contact frame and asserts the marker and the left hand both move, that a reload cannot override a swing in progress, and that everything returns to rest. Two recoil specs. |
| Balance | — | **The shove does not move the balance numbers.** `probe-trading` is identical to the digit after it: Speedball -1.67, Dustline -6.50, Urban +0.33, Woods +0.17, Holdfast -4.17. A rusher is shot well before it reaches 2.4 m, exactly as it was before it reached the barrel tag's 4 m. This is a mechanic and a joke, not a fix for the trading inversion. | `probe-trading`, 6 seeds, round 3, semipro. |
| Marker model | Fourteen pieces, four materials assigned by tint, and no trigger inside the trigger guard. | Ten new pieces and per-piece surfaces: a translucent hopper with paint visible inside it, the macroline and its two fittings running from the regulator into the body, a rubber butt cap (the surface a shove lands on), grip panels, a trigger blade and a feedneck clamp. Anodized tank, milled trigger, matte grip — separated by material and reflectance, because this project uploads no assets and at a third of a stud across a tiled texture covers the grip four times over. Bots' markers gained the air tank, which is what makes the silhouette read as paintball at forty metres. | `check-client-ui` (24 parts of a 64 budget, no collidable, queryable or shadow-casting geometry, nothing stacked), `check-zfight`, `check-budget` (squad 876/1000), `check-characters`. |

## Third pass, 2026-09-09 — five more

Found by sweeping `Data/*.json` for keys nothing reads. That pattern has been the most productive bug-finder in this codebase, so it is now a gate.

| Area | Before | Current behavior | Verification |
| --- | --- | --- | --- |
| Barrel tag (**superseded by the fourth pass above**) | `match.hitRules.surrenderBarrelTagRangeMetres: 4.0` had been declared since the rules were written -- "inside this range a bot offers a barrel tag instead of shooting; it is a paintball courtesy and it reads as comedy rather than mercy" -- and nothing implemented it. The only way to take a player out was a ball. | At contact range a bot tags you out with its barrel instead of firing, and says so. Player elimination is extracted from the projectile branch so paint and a tag end a life the same way. Live and simulated. | `run-live-checks` and `check-client-ui` pass. **It does not move the balance numbers** -- `probe-trading` is identical -- because a rusher is usually shot before it reaches 4 m. This is authenticity and comedy, not a balance fix. |
| Lead solver tuning | Both solver call sites carried a literal `4` while `ballistics.leadSolver.iterations` already declared 4. Two places to change one tuning value. | Read from the data. Same number, so behaviour is unchanged. | 489 specs unchanged. |
| Shoothouse defender count | `course.stageBots: [2,3,4,5]` -- fourteen defenders -- against the twenty-eight `Course` derives from stage anchors. Two opinions about how many people are in the building, and the data one had never been read. | Removed, with the reason recorded in place. The derivation is the rule. | `run-live-checks` still reports 28 defenders over 4 stages. |
| Bot chatter | No line existed for a barrel tag. | Five, in the callouts bank. | `ship-check` dialogue check passes. |
| Unread configuration | Nothing checked whether an authored tunable was reachable. One manual sweep found a rule never built, a contradictory defender count and a duplicated solver constant. | `tools/check-config-read` gates it, top-level keys only -- going deeper produced a hundred false alarms from registries like `wardrobe.pieces`. Six documented exemptions. | Gate 3 of 20; passes. |

**Debug rerun: 19 of 20 gates pass, 489 specs pass, the same 2 balance specs fail** (357.42 s). No new failure introduced.

## Second pass, 2026-09-09 — five more

Separate from the five below, which were a different session's. Nothing here changed a balance threshold.

| Area | Before | Current behavior | Verification |
| --- | --- | --- | --- |
| Bot silhouette vs hitbox | A pro's bump helmet reached 1.850 m and stowed night vision 1.805 m, against a hit capsule that stops at 1.800. Paint landing on the crown of a helmet the player could see did not register. | The shell is lowered to y=0.065 and widened to 0.42 x 0.44 so it still reads as a helmet over the narrower mask beneath it; the NVG tubes drop to y=0.165. Every combatant now tops out at 1.795 m. Nothing on a body stands outside the shape the server shoots at. | `tools/probe-hitbox`: botPro and botMarshal both 1.850 -> 1.795. `check-characters` passes. |
| Trading benchmark | `Policies.human` — the *holding* policy `probe-trading` measures — still walked to the world origin and idled, while only `competent` had been fixed. Once the movement freeze was lifted, "holding an angle" meant walking into the middle of the map and standing in the open, and rushing beat holding on **four of five fields**. | One `advanceToContact` shared by every policy, so `human` and `rusher` reach contact identically and the probe measures the fight rather than the walk. | `probe-trading`: Urban (-3.67 -> +0.33) and Woods (-7.50 -> +0.17) restored. Three fields still invert; see Known gaps. |
| Season track visibility | The Season 1 pass shipped with no way for a client to see it. `SeasonPass.summary` was called on the server and the value reached nothing. | The track goes out with the shop payload and the barn draws it: season name, tier x/20, marks to the next tier, and whether the paid column is unlocked. The barn is where a player stands when they think about spending. | `check-client-ui` passes with the new label. |
| Bot chatter pacing | `maxLinesPerMinute` was 9 while the rec tier declared 11, and `Chatter` takes `math.min` of the two — so rec was silently clamped to amateur's rate and the two tiers sounded identical. | Ceiling raised to 11 so the per-tier table is the actual control. A rec squad will not shut up; a pro squad barely speaks, which is the design the table was written for. | `ship-check` and `run-live-checks` pass. |
| Handoff documents | Six separate handoff, progress and debug narratives with overlapping and contradictory numbers. | All superseded by this file; each old path is a stub pointing here. | Stub check on all six. |

**Debug rerun after these changes: 18 of 19 gates pass, 489 specs pass, the same 2 balance specs fail** (373.30 s). No new failure introduced.

## Latest five improvements

| Area | Before | Current behavior | Verification |
| --- | --- | --- | --- |
| First-person render order | Input camera offsets, the marker and HUD shared an unordered RenderStepped callback with Roblox's camera. | Input updates immediately before the default camera; marker/HUD/automatic fire use the updated camera immediately afterward. This removes the ordering risk behind one-frame marker lag. | Current Roblox render-priority API checked; source compiles. Final camera feel needs playtesting. |
| Movement input | Cancel events could leave sprint/crouch active; crouching out of sprint skipped recovery; releasing one lean key forgot the other; jumping counted as horizontal movement. | End and Cancel release held actions, all sprint exits preserve recovery, opposing lean keys compose correctly, and stance uses horizontal speed. Respawn waits for the actual Humanoid. Exponential camera smoothing behaves consistently across frame rates. | Cancellation, overlap, recovery, vertical velocity and matched 30/120 Hz smoothing checks pass. |
| Paint effects | A recycled splat's old delayed callback could remove new paint early. Disabling a Trail left old history behind. Effects could carry into another round. | One expiry clock replaces per-splat delayed tasks; recycled splats get a fresh lifetime; Trail history is explicitly cleared. Pools cap at 120 splats and 96 flying tracers. Round changes, respawns and summaries clear effects. The effects folder lives independently of camera replacement. | Long-burst recycling, expiry, trail clearing, hard cap and repeated cleanup checks pass. |
| Bot animation timing | Gait speed divided distance by CPU elapsed time. Multiple fixed simulation ticks in one Heartbeat could look like a speed spike. | Avatar posing receives the simulation timestep. Identical movement produces identical poses whether ticks arrive normally or back-to-back. Character designs and collision rules are unchanged by this fix. | Opposed-leg gait checks and normal-vs-catch-up pose comparisons pass. |
| Map collision queries | Every visibility ray searched for the nearest hit, recomputed rotation trigonometry and allocated axis tables. | Visibility stops at the first blocker; projectile impacts still find the nearest. Static volume rotations are cached, irrelevant volumes are rejected early, and scalar clipping removes per-axis tables. | 5,000 seeded rays / 15,000 comparisons against an exhaustive reference pass across all five maps, including ignored cover, concealment and inside/zero-length segments. |

A same-process benchmark of those 15,000 queries measured a median **1.292 s before / 0.858 s after: 33.6% less query CPU time**. This is a Lune microbenchmark, not a measured in-game FPS improvement. No balance assertions or thresholds were changed.

Key implementation files: `Client/init.client.luau`, `Client/Input.luau`, `Client/Tracers.luau`, `Match/BotAvatar.luau`, `Match/MatchService.luau`, `Shared/MapGeometry.luau`, and `Data/clientEffects.json`.

## Debug result and builds

The full debug rerun completed: **18 of 19 gates passed; 489 specs passed and the same two balance specs failed** (332.99 seconds for the spec suite). New input, paint, gait, collision, map and live-service checks pass. The follow-up rerun against the concurrently updated simulator policy also finished: **22 passed / the same two failed** across Sim, SimReload and SimSpread (358.07 seconds). No new failure was introduced by the five fixes.

- `build/paintball-release.rbxlx`: current full project for Studio playtesting; built successfully.
- `build/paintball-demo.rbxlx`: explicit temporary-progress demo; built successfully.
- `build/environment-review.rbxlx`: static, generated Landing for inspecting actual environment assets; no game scripts.
- `build/debug-results.txt`: complete full-run output plus the current-policy follow-up and collision benchmark.
- `tools/check-all.luau`: one authoritative list of 19 automated gates, including the new collision comparison gate.

The current environment review was opened in Studio, but the captured viewport remained blank in this automation session. There is no rendered approval, controller acceptance or device FPS claim for these changes. The user's next full playtest remains necessary. No place was published.

## Current game and release decisions

- **Paintball throughout:** one mark is out, no health/damage/armour system, no realistic injury. Server code decides hits, ammo, rewards and progression. Cosmetics cannot improve accuracy.
- **Gauntlet, Shoothouse, Horde and Capture the Flag have live solo integrations.** `Data/gamemodes.json` is authoritative; the default is Gauntlet, while Holdfast's primary gate starts CTF. See the two newest passes for current mode behavior and validation.
- **Five Gauntlet rounds:** 4, 6, 8, 10 and 12 bots; the final two raise tier by one, capped at pro. Outs accumulate across the match. A partial clear earns only its ordinary round share; it cannot earn full-match/flawless progression.
- **Shoothouse:** four stages, two waves per stage, checkpoint respawns, one run clock, medal records and a time penalty for getting marked. The live-service check drives its entry point through completion and confirms the profile record.
- **Two-player co-op is authorized but not implemented.** The intended place setting is MaxPlayers=2; the server currently refuses a second simultaneous match. A second seat is not a shared course. Do not describe co-op as playable.
- **Map scale:** Speedball/Urban remain full size; Dustline/Woods/Holdfast are at 88%. Speedball cycles six authored spawns for larger squads. Live repeated spawns fan out; simulator spawn stacking remains a parity limitation.
- **Free supply remains active.** `freeMode=true`, `shopFree=true`, `paidEnabled=false`; marketplace IDs stay zero. Effective prices are zero. `Data/dev.json` has `enabled=false`; nested override switches have no effect while the master switch is off. Earned camos and campaign milestones remain skill-gated.
- **Saves:** pinned, licensed ProfileStore is vendored. Published servers require actual DataStore access and session ownership. Ordinary Studio uses ProfileStore.Mock; DemoMode uses explicit temporary storage and is refused outside Studio. Wally is not required merely to build the vendored release.
- **Field kit/consumables:** catalogued previews with retained inventory, but live effects/activation are not implemented. Server purchasing/claiming of unavailable kit is refused.
- **The Range is live.** It runs authoritative drills/scoring and intentionally pays nothing. It is no longer a sign leading to a missing feature.

## Accumulated visual and feel changes

### Combat, markers and controls

- Procedural first-person reload lifts/cants the marker, opens the hopper, brings in a pod, pours, withdraws and closes the lid. Timing follows the equipped marker's reload duration; no uploaded animation is required.
- Sprint tucks the marker and drives bob from distance travelled. A stationary held sprint does not bob. Slide adds a grounded sprint-gated marker pose and eased eye drop using existing speed/duration/cooldown. Slide does not shrink the authoritative hitbox or add clearance under obstacles.
- Marker archetypes have distinct hardware: mechanical stack/bolt details, compact electronic components and a pump forend. Cylindrical tanks/hoppers, barrel steps, porting and a visible bore replace the original blobs.
- Nine marker variants, including five Yardline colourways and the Aurum Kompressor, share audited baseline accuracy. Reactive panels pulse only on confirmed mask tags; first camo auto-equip preserves later player choices.
- Four early reactive camo milestones are 10/35/75/150 confirmed mask tags; later finishes use 250/500/1000. Campaign rewards remain separate earned milestones. Reload/ammo prediction does not refill merely because a cosmetic changes.
- Vertical FOV is 78 degrees. HUD spread and holdover graphics derive from the actual camera FOV/viewport; range readouts are throttled rather than raycast/formatted every rendered frame.
- Shop, dialogue and results use responsive scrolling layouts, safe insets, explicit controller selection/navigation, and close handling that releases gameplay input. Timer generations prevent older banners/hit flashes/chatter from erasing newer ones.

| Action | Keyboard/mouse | Controller |
| --- | --- | --- |
| Move / aim | WASD / mouse | Sticks |
| Fire | Left mouse | R2 |
| Reload | R | X |
| Sprint | Left Shift | L3 |
| Crouch | Left Control | B |
| Slide during grounded sprint | C | R1 |
| Lean | Q / E | D-pad left / right |

### Vehicles, props, shop and characters

- Urban's four cover cars carry sedan assemblies; the Landing's trucks carry pickup bodies with open beds. Sloped windows, separate pillars, wheel arches, tires/rims, bumpers, grilles, lights, mirrors and trim replace block silhouettes.
- Sedan: 120 visual parts. Pickup: 125. Windows are opaque; only major panels/tires cast shadows. Vehicles are static props. Gameplay retains the authored simple car/bed/cab colliders, including the filled rectangular space under a car.
- Picnic tables, pallet stacks and air racks now use boards/braces, tank valves, retention bands, gauges and cargo straps.
- The barn roof/rafters now rise to a proper ridge. Gable infill, overhangs, sign brackets and bay signs follow the corrected roofline. The three supply bays have racks, stocked shelves, pegboards, paint/pods/air equipment, protective gear, counter tools, register, signs and lights.
- Shared Wardrobe construction provides NPC outfits, tier-specific bot kit, masks and distance-driven legs/boots. The separate concurrent character pass lowered/widened the pro helmet and lowered stowed night-vision tubes to fit the top of the hit capsule; see the current `probe-hitbox` output for geometry evidence. The current diagnostic still reports five bot body/capsule deviations: a roughly 1 cm chest-width mismatch and woodland camo panels reaching up to 10 cm beyond the capsule. Hands/marker reach also extend outside the simple gameplay hull. These remain visual/hit-registration review items.

![Source-geometry sedan and pickup preview](previews/vehicle-props.png)

The vehicle preview is an orthographic software rendering of generated parts, not a Roblox screenshot. Reproduce with `lune run tools/check-props /tmp/paintball-vehicles.json`, then `python3 tools/render-props.py /tmp/paintball-vehicles.json docs/previews/vehicle-props.png`.

### Environment and lighting

- Authored redwoods, beech trees, saplings, ferns, rocks, fallen logs and leaf litter replace stacks of primitive parts. Templates preserve their UVs/PBR surfaces and proportions, fit inside reserved circular footprints, and retain size variation. Static tree trunks use simple separate colliders; decorative meshes do not enter collision, queries or touches.
- Perimeter trees use the source pack's distant redwood variant and automatic mesh render fidelity. Ferns/ground detail stay near player routes; shadow casting is limited to useful nearby plants.
- Moss, stone, board-formed concrete and metal-panel material variants add surface texture. Palette tint is lightened when applied to textured albedo. Both project files select Realistic lighting and the 2022 material set; a managed sky supplies the reflection environment alongside per-map atmosphere/clouds. Combat depth of field stays disabled.
- Local wind moves only the nearest 48 tagged leaf meshes within 28 m, at 20 Hz, refreshing selection every 1.5 s. Leaving range, removing tags, parking the hub and teardown restore resting transforms. Trunks do not animate or replicate movement.
- Ground zones, trail segments and joins share one overlap plan, reserve existing barn floor planes and reuse low heights where disjoint. The maximum stack dropped from 0.252 m to 0.12 m. Water clears its bank instead of disappearing below it. Buried field markings remain level.
- The z-fighting checker fails on build errors instead of passing an incomplete scene. It checks actual primitive faces and skips fictitious flat faces inferred from MeshPart bounding boxes.
- Speedball dressing follows inflatable paintball references: soft pillow/brick forms, tapered doritos, domed cans, seams and glossy vinyl. The existing OBB gameplay hulls still fill visually empty rounded/tapered corners.
- Hub/map overlap is prevented by parking the entire Landing in ServerStorage while a field is active. Grounded spawn placement and foliage exclusions keep buildings/routes clear.

| Foliage measurement | Before authored assets | Current |
| --- | ---: | ---: |
| Placed plants | 1,339 | 1,340 |
| BaseParts | 7,579 | 2,926 |
| Shadow casters | 2,012 | 382 |

The complete hub measures 4,343 parts / 1,018 casters. Budgets cap foliage at 3,400 / 500 and the full hub at 5,100 / 1,250. These are structural counts, not FPS. Texture alpha, triangles and GPU memory are not measured by the Part.Transparency area budget. Woods/Holdfast boundary opacity previously removed large unnecessary transparent surfaces; Speedball keeps its netting.

## Authoritative gameplay and reliability fixes already landed

- Manual/empty-hopper reloads share MarkerState between client prediction, server and simulator. Reload duration, fire rate, sustained spread, movement spread and recovery have dedicated boundary checks.
- Warmup/respawn suppress shooting; duplicate elimination events cannot grant duplicate progression. Round transitions agree on hopper/reload resets. Full-match live duration accumulates across rounds.
- Client readiness/session snapshots and serialized startup prevent lost join events and overlapping starts. Mid-match equipment swaps are refused. Session departures release profiles, including loads that finish after the player leaves.
- Server origin/direction/timestamp validation rejects malformed/nonfinite requests; actual shots originate from the server's player position. Client-reported hit results cannot award currency or camos.
- Free commerce shares ownership/price rules; receipt handling requires durable save acknowledgement. Published access failure cannot silently degrade into temporary memory.
- Campaign/NPC dialogue, maps, free shop stock, leaderboard eligibility and record formatting have automated checks. The Range and Shoothouse have live entry-point tests, not just tests of unreachable rules modules.
- SimMatch now lets its player step over walkable terrain and deflect around cover. This fixed the frozen-player benchmark, particularly on Holdfast, and invalidated old balance claims. The two failures below were retained deliberately.

## Known gaps and balance failures

**Trading, as measured 2026-09-09** after the shared advance-to-contact fix. The design premise is that a straight fight is unwinnable and the player must win angles rather than trade, so `trading` must cost more deaths than `holding`:

| Field | Holding | Trading | |
| --- | ---: | ---: | --- |
| Urban | 2.17 | 2.50 | ok |
| Woods | 15.17 | 15.33 | ok |
| Speedball | 7.17 | 5.50 | rushing is safer |
| Dustline | 14.00 | 7.50 | rushing is safer |
| Holdfast | 14.50 | 10.33 | rushing is safer |

Two of five now behave, up from one. The remaining three are a genuine tuning problem rather than a benchmark artefact: the holding policy already crouches and holds once engaged, so the gap is in map cover and bot behaviour, not in how the benchmark walks. Every band and difficulty figure in this project was originally derived against a player that could not move, and re-deriving them is the outstanding work. The two failing specs are deliberately left failing so it cannot be forgotten; making them green by moving thresholds would rubber-stamp tuning taken from a bug.


**Two baseline acceptance failures remain open; their assertions are not weakened.**

1. `the difficulty curve > punishes trading harder than holding angles`: Speedball's rushing policy currently costs fewer outs than the holding policy.
2. `the maps produce different fights > orders Speedball below Woods by a wide margin`: measured sightline/engagement distributions miss the required 1.6× separation.

The prior six-seed control-round measurements after fixing simulated movement, before the concurrently edited policy refactor, were:

| Field | Holding outs | Rushing outs | Result |
| --- | ---: | ---: | --- |
| Speedball | 6.83 | 4.67 | Rushing favored |
| Dustline | 12.33 | 10.00 | Rushing favored |
| Urban | 14.17 | 10.50 | Rushing favored |
| Woods | 21.33 | 13.83 | Rushing favored |
| Holdfast | 10.50 | 16.33 | Intended ordering |

Prior measured medians were Speedball 26.7 m / Woods 40.9 m: Woods would need to exceed 42.7 m for that assertion. These are deterministic benchmark samples from the movement fix, not fresh human measurements. Recalibrate policy assumptions and then tune fields with `probe-trading`; do not resize all maps from one field's result or rubber-stamp old frozen-player numbers.

A concurrent session refactored benchmark approach-to-contact into a shared policy helper. It is outside the five fixes above; the follow-up simulator run still fails the same two acceptance checks. Earlier numeric balance samples are retained as history and are not measurements of that updated policy.

Other current limitations:

- Target history is captured, but projectile rewind/lag compensation is not integrated. High-latency hit registration needs real testing and a travelling-projectile time policy.
- Co-op needs a shared match/player-target architecture. SimMatch still lacks Shoothouse scheduling and does not fan repeated spawns exactly like live play. Bots follow navigation without a full character-collision controller.
- Bot avatars rebuild each round/wave. Course wave transitions may hitch; measure before choosing reuse/reset or client interpolation. (Corrected 2026-09-10: server fixed-step catch-up **is** capped, at `ballistics.simulation.maxStepsPerFrame` = 5, with the surplus dropped rather than carried. This line previously said it was uncapped.)
- Paint tracer matching still uses proximity rather than a shared predicted-shot ID. Splats retain their simple geometry; exact surface attachment/orientation is not implemented.
- Several non-fire remotes have correctness guards but no shared per-player rate limiter. Add one before expanding multiplayer/co-op load.
- Live consumable effects remain unimplemented. The earlier deferred-mode statement is superseded by the Horde and CTF passes above; see the sound passes for current audio status.
- `tests.project.json` is an old, incomplete Studio test setup; use the Lune checks. Source syntax checks are not a full Roblox engine type analysis.

## Playtest and release

Use `Play.command` for the current full project, or open `build/paintball-release.rbxlx` and choose **Test → Play (F5)**. Runtime-built worlds appear after the client joins; Run/F8 has no local player. Stop the test and rebuild/reopen after source changes.

1. Walk the Landing, inspect the trees/materials/trails/vehicles/barn, and visit every counter/NPC. Check mesh delivery, missing textures and Output errors. The static environment-review place can be inspected without starting gameplay.
2. Fire/reload repeatedly; sprint into crouch/slide; overlap and release both lean keys; tab away while holding actions. Turn the camera quickly and compare 30/60/120 FPS. Check respawn and round changes leave no old paint/trails or held controls.
3. Complete/replay a Gauntlet and Shoothouse; verify wave progression, checkpoints, medals, rewards and return-to-hub. Pay special attention to the four maps whose benchmark favors rushing.
4. Play the full loop with a controller, switch input mid-menu, scroll/rebuild shop lists, close dialogue with B, and check controls after respawn. Check 1920×1080, 1280×720 safe areas and a narrow 600×800 viewport. Touch support is not established.
5. Profile hub and full-squad frame time, triangle/texture memory and leaf overdraw on actual target hardware. Record worst-case effects/wave transitions. Streaming remains off pending evidence and lifecycle testing.
6. In a separate private published test experience, earn progress, shut down, rejoin a new server and verify currency/inventory/loadout/camos. Studio Mock does not prove saves. Confirm place device/access/player-count settings and the actual content questionnaire before any public release.

Build and debug commands:

```sh
lune run tools/check-all
lune run tools/map-validate
lune run tools/probe-hitbox
lune run tools/foliage-report
lune run tools/probe-trading all 6
lune run tools/build-environment-review
rojo build default.project.json -o build/paintball-release.rbxlx
rojo build demo.project.json -o build/paintball-demo.rbxlx
```

`Check Release.command` runs the same gate list and intentionally stops when any gate fails, including the existing balance failures. `Play.command` is the local playtest launcher; neither publishes.

## Environment asset provenance

The imported meshes/textures are Roblox-authored assets, not original art created for this repository. Their use remains subject to applicable Creator Store terms; the project does not relicense them as standalone art.

- [Roblox Forest Pack, asset 6432306802](https://create.roblox.com/store/asset/6432306802), also described in [Roblox's Duvall Drive environment documentation](https://create.roblox.com/docs/resources/the-mystery-of-duvall-drive/develop-a-moving-world).
- [Environment Art Asset Library, asset 14447738661](https://create.roblox.com/store/asset/14447738661), supplied with the [environmental art curriculum](https://create.roblox.com/docs/tutorials/curriculums/environmental-art/construct-your-world).
- Sky textures are bundled `rbxasset://textures/sky/sky512_*.tex` resources.

`World/ArtAssets/*.rbxmx` holds ten normalized mesh templates and four material variants. The offline importer copies selected MeshParts/SurfaceAppearances, removes nested dressing/soil and behavior, and records model names/pack ID. No imported scripts execute and no runtime InsertService download is used. Roblox resolves referenced texture/mesh IDs; unauthenticated direct downloads returned HTTP 401, so offline rendering could not validate delivery.

Decompressed source download SHA-256:

```text
Forest: fdaf7b1be91d276f25aaf4a7fe2626d5bfe427341df9b0316d66cac62a1ab4cd
Environment: 23ccecbc941703a23b3c8ce368583ef0af19eef617d9ae5b4fa51f5ca1505e7a
```

Re-import: `lune run tools/import-environment-art /tmp/roblox-forest.rbxm /tmp/roblox-environment.rbxm` using decompressed `.rbxm` files. Source provenance and this notice must remain with the templates.

## Guidance for the next code pass

Read this report, `CLAUDE.md`, and the current source/data. `BUILD_PLAN.md` describes intent and includes older milestones. `docs/MONETIZATION.md` retains the detailed free-commerce/product policy; `docs/PLATFORM_NOTES.md` retains API verification references.

All gameplay authoring lives in `src/` and `Data/`; generated places are disposable outputs. Keep pure simulation in metres/seconds and use Shared/Units at engine boundaries. Treat Config data and built collision volumes as immutable; rebuild to change their geometry/rotation caches. Respect authored OBB gameplay hulls when changing decorative art. Gate every newly integrated mode through the actual service entry point.

The Lune harness can build real instance properties and verify transforms but is not Roblox's renderer/network scheduler. In Lune 0.10.5, a lookAt orientation discrepancy was observed; ground paths use an explicit matrix basis to match their overlap geometry. Do not confuse a headless transform/property check with visible mesh triangles or real network behavior.

Concurrent agents have edited this shared workspace. Preserve unrelated changes; do not use broad resets or treat an old handoff's file ownership as current authorization. Update this report instead of adding another AI handoff.
