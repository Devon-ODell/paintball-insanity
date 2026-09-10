# Claude Handoff 003

## Verdict and scope

**The current game does not pass an “every written feature is connected and working” audit. Do not treat a successful Rojo build or the existing green component gates as release acceptance.** There are reproducible failures at the boundaries between Bootstrap, the live services, the client, and persistent progression. Several substantial features are implemented only as rules/catalogue data.

Audit date: 2026-09-10. Base HEAD: `49af9738d182f6c8c478e17dfdcf91a64724614b`. This audit includes the existing dirty working tree, notably the recent CTF integration and untracked `MatchProgress.luau`, `CtfLiveChecks.luau`, `check-ctf.luau`, and `build-ctf-review.luau`. Preserve those changes. This is an investigation/handoff, not an implementation pass; production code and tuning were not changed.

The user explicitly requested this separately named handoff, superseding CLAUDE.md's ordinary instruction to consolidate handoffs into CHANGE_REPORT. Read this alongside the current source. Historical comments and reports are not reliable feature inventories.

Evidence labels below:

- **Reproduced:** executed production functions under the Lune harness with the relevant inputs. Engine boundaries are mocked; this is not a rendered Studio playtest.
- **Source-confirmed:** producer, consumer, or lifecycle paths demonstrably disagree in the source. Concrete runtime consequences are identified, with engine-dependent details qualified.
- **Unverified:** requires Studio, real network conditions, asset delivery, or published services. No such validation is claimed here.

## Verification results

`rojo build default.project.json -o /tmp/paintball-audit-release.rbxlx` succeeded. `rojo build demo.project.json -o /tmp/paintball-audit-demo.rbxlx` also succeeded. These prove packaging, not runtime correctness or publishing readiness.

Full 22-gate result: **20 passed, 2 failed; exit code 1**.

- `ship-check`: one release blocker, development overrides enabled (invulnerable, unlockEverything, infiniteCurrency).
- `run-tests`: **526 passed, 2 failed, 0 skipped across 24 spec files**, reported duration 373.42 s. The failing acceptance tests are `the difficulty curve > punishes trading harder than holding angles` and `the maps produce different fights > orders Speedball below Woods by a wide margin`. Both reported `expected true, got false`; assertions were not changed.
- All other gates passed: source, static, config-read, audio, map-casts, budget, zfight, spawns, characters, gait, inflatables, environment-art, foliage-wind, client-ui, range, demo-world, persistence, profile adapter, CTF and live MatchService.

These are fresh results from this working tree. Earlier numeric balance samples in CHANGE_REPORT were not rerun as a separate multi-seed balance study. The passing component gates coexist with the additional integration failures reproduced below.

The targeted audit probes additionally reproduced:

```text
Actual Bootstrap callbacks, with service boundaries mocked:
  CharacterAdded routes an active range player to Hub.placePlayer
  RequestMatchStart accepts a player with an active drill
  RequestRangeDrill accepts B while A owns a match
  B's CharacterAdded restores the hub while A owns a match
  RequestMatchStart accepts Horde with empty chapter progress

Actual RangeService shot payload: spec is absent
Actual Tracers.fire with that payload shape:
  attempt to index nil with 'muzzleVelocity'

Actual Drills schedules against the configured firing line:
  Holdover nominal 20 / 35 / 50 m => forward distances +20 / +5 / -10 m
  Strafe nominal 18 / 26 / 34 / 45 / 58 m => +22 / +14 / +6 / -5 / -18 m
  Switch activeAt(59 s) => 54 targets; configured simultaneousTargets => 3

Actual RangeService under continued upward fire:
  still active at 80.033 s for a 60 s Pop-Up drill

Actual Profile.recordMatch:
  fresh profile: Dustline locked
  record a cleared Speedball Shoothouse: Dustline unlocked

Actual Commerce and SeasonPass:
  fresh seasonPassS1 catalogue entry: owned=true
  actual SeasonPass.ownsPass: false
  free claim returns ok=true; actual ownsPass remains false
```

Temporary reproduction sources and outputs during this session are `/tmp/audit-bootstrap.luau`, `/tmp/audit-pure.luau`, `/tmp/audit-check-range.luau`, `/tmp/audit-check-client-ui.luau`, `/tmp/audit-run-live-checks.luau`, and `/tmp/audit-{range,client,live}.log`. These are disposable; the causes, fixtures and acceptance criteria below are sufficient to reconstruct the checks. Do not commit the temporary scripts verbatim: some inherit the existing harness's weak disconnect/scheduling mocks. The full gate log is `/tmp/paintball-audit-check-all.log`.

## Working architecture and feature coverage

Runtime graph:

```text
Bootstrap -> Remotes / Profile / Commerce / Hub / Dialogue
  field gate / RequestMatchStart -> MatchService
    Gauntlet: RoundSchedule + RoundState
    Shoothouse: Course schedule + CourseProgress
    Horde: Endless schedule + Squad reinforcements + Boss target rules
    CTF: FlagArena + FlagMatch + CaptureTheFlag + FlagNavigation + FlagVisuals
    all: BotController / SquadCoordinator / AimModel / ProjectileSim
    results: Settlement -> Profile / MatchProgress / Campaign / SeasonPass
  range gate / coach / RequestRangeDrill -> RangeService -> Drills / DrillScoring
  barn -> Shop / Commerce -> profile loadout and inventory
Client init -> Input / ViewMarker / Tracers / Hud / DialogueUi / ShopUi / Audio / Music
```

| Feature family | Current state and evidence |
| --- | --- |
| Join/profile/backend selection | Live Bootstrap path exists; ProfileStore vendored; Studio uses Mock. Persistence adapters pass headless checks. Real service saves and disconnect ordering remain unverified. |
| Hub, gates, barn, NPCs, board | Built and connected. Global hub parking/restoration is incompatible with the current lifecycle and second seat. |
| Gauntlet, round escalation, outs, payout | Live implementation exists and service checks run it. Return cleanup, movement authority and teaching feedback need correction. Balance acceptance remains a separate gate. |
| Shoothouse stages/checkpoints/medals | Live solo schedule and result record exist. Co-op rules are not a co-op match. Course records are not comprehensively exposed, and map-unlock semantics leak across modes. |
| Horde, waves, reinforcements, veterancy, marshal targets | Combat integration exists. Remote unlock bypass; depth/boss records, drops, boss bonus and leaderboard are incomplete. Do not call the whole mode complete. |
| CTF flags, split squad, navigation, captures, drops, returns, timed respawns | Live solo implementation and dedicated arena/lifecycle checks exist. Preserve this work. Shared-world cleanup, movement enforcement, and rendered multiplayer behavior remain unresolved. |
| Range: Pop-Up/Strafe/Switch/Holdover/Peek | Service and schedules exist, but lifecycle, wire contract, geometry, target population, scoring semantics and discoverability are broken/incomplete. |
| Fire/reload/melee/projectiles | Server validates fire/swing payloads, owns ammo and outcomes, uses swept projectile checks and authoritative payout. No client-reported hit remote. Stance/muzzle/body coherence and movement trust remain gaps. |
| Bots, sight, crossfire, morale, chatter | Shared production/simulation implementation exists. Ordinary player noise is not connected to bot hearing; CTF carrier movement noise is. |
| Marker choice/camos/skins/paint colors | Actual client loadout consumers exist. Headshots drive camo progress. This is distinct from the largely inert attachment/gear inventory. |
| Barrels/hoppers/tanks/protective gear/pods/masks | Purchases/equip/profile fields exist. No complete live stat or player appearance application path. |
| Consumables | Explicitly deferred: `liveEnabled=false`, catalogue hidden, purchase rejected. Carry/effect/drop rules are not live. This is not presently a purchasing exploit. |
| Campaign/coach/Aurum | Gauntlet chapter recording, earned gear grants, diagnosis persistence, coach drill action, Aurum goal check exist. Unlock inconsistencies, inert reward gear and inadequate feedback interrupt the loop. |
| Season and commerce | Free launch is configured; paid prompts disabled. Grant/receipt/session checks exist. Season pass ownership contract is broken. Actual paid flows need private published validation before enabling. |
| Leaderboards | Gauntlet and course ordered-time stores exist. Metadata/profile/UI lose the mode distinction; Horde submission is absent. |
| Audio/music/environment/foliage/props | Actual consumers and extensive construction/budget checks exist; mesh/audio delivery and rendered performance were not observed. Audio clear ordering needs correction. |
| Touch/gamepad | Controller bindings/navigation have component checks. Touch gameplay controls are not implemented to parity; do not infer support from responsive UI. |
| Simulation/tooling | Valuable shared pure logic and regression gates, but component mocks and textual reachability do not establish end-to-end reachability. |

## Required corrections, ordered by impact

### 01 — World ownership, Range startup, and the second player are unsafe [P1; reproduced/source-confirmed]

Locations: `Bootstrap.server.luau:279` (`requestMatch`), `:358` (`startDrill`), `:470` (`onMatchEnded`), `:634` (CharacterAdded); `World/Hub.luau:124,142,222`; `Range/RangeService.luau:245,608`; `Match/MatchService.luau:1272`.

There is only a **per-player match-start flag** and a `currentHost()` over active matches. Range sessions, pending construction, retained match venues, and hub occupants are outside that ownership model.

1. `RangeService.start` calls `LoadCharacterAsync`. Bootstrap's CharacterAdded callback waits 0.2 s, then checks only `starting[player]` and `MatchService.isActive(player)`. `startDrill` does not set the starting flag. Consequently it calls `Hub.placePlayer` for a Range player; that restores the entire hub and sends `phase='hub'`. Exact ordering against the yielding character load is engine-dependent, but the wrong routing branch was reproduced with an active Range session. A normal drill launch can be interrupted or overwritten.
2. `requestMatch` never checks or stops the player's Range session. Both services can consume the same `FireMarker`/reload events and create geometry at the origin.
3. `startDrill` checks activity only for that player. B can start a drill during A's match; two players can also run drills together at the same origin.
4. A's match parks the hub globally, removing B's floor and interactions. B joining or receiving CharacterAdded during A's run restores the hub into A's arena. The second seat is not actually a safe waiting seat.
5. Range registers `sessions[player]` only **after** character loading, although it has already installed fire/reload listeners. Requests during that yield can start multiple sessions. Early load failure calls `RangeService.stop` before a session exists, so the already-created listeners have no registered cleanup owner.
6. Range leave cleanup destroys its world but never invokes the normal hub-restoration callback. Match return callbacks check only their player's activity, not a global owner or active drill.

**Fix direction:** introduce one server-owned activity/world lease, acquired before any yield or world mutation, spanning preparation, play, results/venue and teardown. Make the hub spatially independent if the second player is retained. Character routing must dispatch to the owning activity, not infer hub eligibility from “no match.” Add cleanup registrations immediately on allocation and unwind them on failure. Do not pretend that denying two simultaneous matches fixes two-player presence.

**Acceptance:** drive the real Bootstrap with a controllable scheduler and actual service adapters: drill start/respawn, reset, load failure, disconnect, B joining A's activity, A ending while B requests another, duplicate requests during load, and stale return callbacks. Assert world parentage, phase, character placement, number of listeners, and ownership throughout—not just returned `ok`.

### 02 — Completed maps remain when the hub returns [P1; source-confirmed]

Locations: `MatchService.luau:181-185`, `:1117-1133`, `:1309-1330`; Bootstrap's delayed return; `Hub.placePlayer`.

`finish` disconnects combat and clears `active[player]`, but does not destroy/unparent `mapWorlds[player]` or clear its venue. CTF destroys flag visuals and squad, not the arena root. Bootstrap later restores the hub at the same origin. Old map geometry is destroyed only when **that same player** starts another match or leaves. Retaining a field for its supply venue may be intentional, but retaining it while restoring the hub is not a safe transition. A drill after a match inherits the old map too. B starting after A finishes can leave both players' map roots present.

A modified live checker tracking built Folder roots retained two at the end; this supports the ownership issue but is not a rendered overlap test.

**Fix:** define an explicit venue state versus return-to-hub teardown. Keep a venue only while it owns the world, and dispose the map before restoring the hub. Test every origin scene transition, including failed start and different players.

### 03 — Range target coordinates and collision shapes do not match what is presented [P1; reproduced/source-confirmed]

Locations: `Range/Drills.luau:38` (`bearingPosition`), `RangeService` target construction and `simTargets` construction; `Data/range.json:7`; `Ballistics/ProjectileSim.luau:199`.

Drills declares positions relative to the firing line but returns `(sin(angle)*distance, height, -cos(angle)*distance)`. The live Range places the player at z=-40 facing +Z and uses those schedule positions directly as world coordinates. The numeric reproduction above establishes the error: Holdover 35 m is only 5 m away; Holdover 50 m is behind the player. The far Strafe lanes are behind the line, and z=-58 is outside the 90 m floor. All five drill generators share this coordinate convention. A scripted shooter solving against the erroneous positions cannot detect this.

The visible targets are spheres centered at `target.position` with radius r. The projectile target uses that center as the **bottom** of a vertical capsule with height 2r. Its hittable extent is y-r through y+3r, whereas the visible ball ends at y+r. Shots through empty space above the target can count. Merely subtracting r still leaves the wrong shape/extent; use an actual sphere query or a supported zero-length capsule centered at the sphere, with a degeneracy test.

**Acceptance:** for each drill/seed, assert true player-to-target range, forward hemisphere, floor/berm containment and announced distance. Test grazing shots immediately outside every side of the visible sphere. Transform at one explicit local-to-world boundary; keep pure simulation and live Range aligned.

### 04 — Range wire contract throws on every accepted shot; initialization is incomplete [P1; reproduced]

Locations: `RangeService.luau:454` (`MarkerFired`), `Client/init.client.luau:229` (listener), `Client/Tracers.luau:126-137`.

Range emits `{origin,direction,ammo,source='self'}` without `spec`. Client unconditionally calls `Tracers.fire(payload.origin,payload.direction,payload.spec)`, which indexes `spec.muzzleVelocity`. The exact nil-index failure was reproduced. This is a callback error, not proof the entire client terminates; the local predicted tracer may still appear and disguise it.

Adding `spec` alone produces a second tracer for the player's already-predicted shot. Decide whether a self event acknowledges/reconciles or renders; do not render both. The `ammo` field is also unused.

Range entry sends `phase='live',mode='range'` without a warmup/round. Client resets hopper/spread/deaths in warmup or round branches, not this entry path, so an old match/drill's local ammo and HUD state can survive into a fresh server marker state.

**Acceptance:** deliver captured production Range payloads to the actual client dispatcher, fire/reload twice across drill re-entry, assert no callback errors, one cosmetic shot per accepted intent, coherent hopper state, and a dedicated Range presentation state.

### 05 — Range scheduling and diagnosis do not implement the authored drills [P1/P2; reproduced/source-confirmed]

Locations: `Drills.luau:95` (`switch`), `RangeService.luau:382-405,566-608`, `DrillScoring.luau:68-95`, `Telemetry/ShotMeasure.luau:140-151`, `Data/range.json`, `Data/telemetry.json`.

- Switch's “three simultaneous targets” is actually three new targets every 3.35 s, all expiring at the end of the drill. With no hits there are **54 at 59 s**. Hit targets disappear in Range, but replacements are unrelated to those hits. Correct the live scheduler to replenish a bounded population after elimination, or author a bounded deterministic schedule with matching semantics.
- `onFire` continues to accept shots after `durationSeconds`; finish requires an empty projectile list. Continuing to fire upward kept a 60 s drill active beyond 80 s. Stop accepting new shots at the deadline and drain in-flight shots with a finite timeout. Avoid spawning targets after the cutoff (Peek can schedule a reveal beyond duration).
- Switch grades `timeToAcquireMs`, elapsed since reveal, rather than time between eliminations, despite the config's `scoredOn` and match metric. Quick successive hits on targets that have been visible for seconds are penalized incorrectly.
- Peek authors `announcedBearingDeg` but the Range/client never communicates that cue. Its offset is approximated from the **previous fired shot**, not sampled when the next target appears. Match telemetry shares that approximation. Treat it as an approximation, or collect the needed aim history; do not state that true reveal-time placement was measured.
- Pop-Up declares flicking as a secondary fundamental, but its rating/points do not consume angular error. Strafe is prescribed for tracking but reports only leadAndDrop. Sharing an exponential curve does not make different input measurements comparable.
- Expired unengaged targets are inserted into `events`, and `shots=#events`; the reported “shots/accuracy” is an event score denominator, not actual trigger count. Separate missed opportunities from fired shots.
- No client listener consumes `DrillScore`. The finish banner carries only hit count/score; rating/fundamental/accuracy are discarded. No live Range record persists its result into practice history. Do not overwrite match skill estimates blindly; define an explicit practice record.
- Gate entry always chooses the first drill, and the coach chooses a diagnosis. There is no general client caller for `RequestRangeDrill` offering all five drills or the prescribed short-distance Strafe selection. Holdover/Peek are conditionally reachable through prescriptions, not independently selectable practice.

**Acceptance:** scripted outcomes with known acquisition/switch/lead/placement metrics, bounded target population, no-fire/continuous-fire deadline tests, cue delivery, five-drill selection and visible result/history. A score merely greater than zero is insufficient.

### 06 — Purchasable/equippable gear and attachments are inventory-only [P1; source-confirmed]

Locations: `Shared/GearStats.luau:105`, `Economy/Shop.luau` ownership/loadout mappings; `MatchService.luau:167-170,366`; `Client/Input.luau:99`; `Client/init.client.luau:383`; `Shared/MarkerState.luau`.

`GearStats.resolve` has test callers but **no production caller**. Sprint, crouch, slide duration/cooldown, reload multipliers, loudness and pod counts therefore never reach live movement/ammo/bots. `MarkerState.new` receives only base marker data; reloads have no finite pod budget. Barrels/hoppers/tanks are looked up for catalogue/audit purposes, not applied to combat or the viewmodel. Client loadout handling consumes marker, camo, marker skin and paint color, not the other slots. Wardrobe dresses NPC/bot outfits; it does not apply the player's purchased jersey/helmet/shoulders/mask to their avatar.

The shop advertises movement/noise tradeoffs. Chapter reward gear is granted but can be mechanically and visually inert. Shop prices are currently zero by explicit launch policy, so this is misleading feature behavior, not evidence users are currently charged money for it.

Ordinary marker loudness is likewise disconnected: MatchService passes `playerLoudness` only for a CTF flag carrier, and BotController's hearing branch requires that value and movement. Silent/quiet marker variants do not gain the promised hearing tradeoff; ordinary shooting noise does not enter this hearing path.

**Fix:** create a resolved loadout snapshot consumed consistently by server mechanics, validated client prediction and appearance. Explicitly decide which authored stats should ship; do not blindly enable velocity changes contrary to project policy. Keep unimplemented slots unavailable or accurately labeled until connected.

**Acceptance:** equip two contrasting supported loadouts through the real shop and demonstrate measured differences in movement/reload/noise/pods and visible appearance, while protected accuracy/velocity constraints hold. Verify respawn and round changes retain the snapshot.

### 07 — Season pass catalogue ownership disagrees with actual entitlement [P1; reproduced]

Locations: `Economy/Commerce.luau:55-88,118-134,151-179`; `Progression/SeasonPass.luau:69-74`; `Client/ShopUi.luau:185-189`; `Data/monetization.json:29-42`.

`seasonPassS1.grants={}` because it unlocks a track. `Commerce.owns` loops over grants and returns true for the empty table. A fresh user sees “Collected,” and ShopUi disables the offer. `SeasonPass.ownsPass` separately checks `commerce.passes[passOfferId]`, which is absent. A direct free claim returns success but only writes `commerce.claims`, never this entitlement, and does not notify `onPassResolved`.

This also threatens future paid mode: if refreshPass reports non-ownership, `prompt` subsequently calls `owns` and can return `owned=true` before opening the purchase prompt. Paid mode is disabled today; do not enable it with this contract.

**Fix:** distinguish collection inventory from pass/season entitlements. Define explicit free-claim ownership for the free build, invoke reward reconciliation after acquisition, and derive catalogue state from the same source SeasonPass reads. Test fresh, owned, claimed, reconnect and already-earned tiers, plus paid non-owner behavior under mocks.

### 08 — Horde integration stops before unlock enforcement and persistent rewards [P1/P2; reproduced/source-confirmed]

Locations: Bootstrap `startHorde` dialogue action versus `requestMatch`; `MatchService` settlement/progress branch; `Match/Settlement.luau:100-113`; `Match/Endless.luau:200-215`; `Campaign.recordFromProfile`; `Data/gamemodes.json`.

The NPC checks `Campaign.hordeUnlocked`; the public match-start remote does not. `asMode` only checks `integrated`, and only CTF has an explicit mode unlock check. Empty chapter progress reaches the Horde start call. General map membership is also not enforced against `modes[mode].maps`, allowing unsupported mode/map combinations through direct requests when other map checks permit them.

Combat waves and marshals are live, but:

- `Settlement.payout` calls `Endless.payoutFor(depth, 0)`, so the authored per-boss bonus is always zero.
- No production writer records `hordeBest` or `bossesBeaten`. Campaign can read those fields, but live victories do not populate them.
- `Endless.dropTierFor` and boss drop tiers have no live reward consumer. Consumables are deliberately disabled; do not promise drops on that basis.
- Horde sets `breakdown.cleared=false`; leaderboard submission is gated by `breakdown.cleared`, so the declared wave leaderboard never submits. The existing leaderboard stores rank seconds, not depth.
- HUD renders ordinary round wording and the dynamically growing schedule count. Horde settlement omits `deathPenalty`, so the summary defaults to displaying ×1 even when deaths reduced the total.

**Acceptance:** all entry routes use a single mode/map/unlock validation path. Complete a boss wave and exit/timeout/rejoin: depth, boss count, payout and any advertised drops/board update must agree. Keep unsupported rewards explicitly deferred rather than fabricating completion.

### 09 — Movement, stance and visible aiming are not fully authoritative/coherent [P1/P2; source-confirmed; exploit/play-feel validation pending]

Locations: `Client/Input.luau:99-118,268-291`; `MatchService.luau:104-125,595-620,899-913`; `Shared/Spread.luau`; CTF pickup logic.

The server owns projectile outcomes but takes the character's replicated root position and velocity as the player state. There is no movement-displacement/bounds validation here. CTF captures depend on proximity to flags/home, so position tampering is a distinct risk from forging a hit. The carrier movement cost is applied by the client to WalkSpeed; it scales **all** locomotion despite being named a sprint multiplier. Validate legitimate movement/teleports and authoritative objectives instead of claiming server-owned hit tests secure position-based scoring.

Crouch/slide/lean move the camera and change client movement, while the server still uses a full standing capsule and a center/chest muzzle. No lean intent is transmitted; crouch is inferred partly from a client-reported boolean passed to Spread. Consequently leaning around cover can show a clear shot while the authoritative muzzle remains behind the wall, and crouching does not shrink the actual target. A forged stationary crouch request can obtain crouch spread without an authoritative crouch state. Distinguish acceptable presentation approximation from promised cover mechanics.

**Acceptance:** validated stance transitions, explicit shared muzzle/body rules, wall-edge/low-cover shot tests, finite/bounded movement inputs, and impossible-displacement CTF capture tests. Do not trust client-provided origins as a shortcut.

### 10 — Reset/fall/character failure has no complete recovery path [P1; source-confirmed, Studio reproduction needed]

`default.project.json` sets `Players.CharacterAutoLoads=false`. There is no player Humanoid.Died or CharacterRemoving recovery handler. Normal paintball elimination manually calls LoadCharacterAsync, but native reset, falling out of world, or a character disappearing is outside that route. For non-CTF, a missing root causes the gameplay step to return after advancing the round clock; CTF can retain the last position. The user can remain without a controllable character until timeout or rejoin. A spawn failure during delayed respawn also lacks the startup pcall's recovery.

Roblox documents that disabling CharacterAutoLoads requires manual character loading, and RespawnTime only governs automatic loading: [Players reference](https://create.roblox.com/docs/reference/engine/classes/Players#CharacterAutoLoads). Character loading emits CharacterAdded: [Player reference](https://create.roblox.com/docs/reference/engine/classes/Player#LoadCharacterAsync). These API facts were checked during this audit; visible reset behavior was not observed.

**Acceptance:** native reset and world fall in hub, Range and each mode; character-load error and timeout; no duplicate outs/rewards and no indefinite missing-character state. Route recovery through the activity owner from finding 01.

### 11 — Results disappear before they can be read; delayed notices can overwrite gameplay [P2; source-confirmed]

Bootstrap returns the player to the hub **2.5 seconds** after MatchSummary. `Hub.placePlayer` emits hub phase; client hub handling calls `Hud.hideSummary`. This hides the six fundamental scores, diagnosis, payout explanation and replay buttons without user dismissal. The game's teaching loop depends on those results. Preserve the result panel while physically returning, or make return explicit.

`Commerce.onPassResolved` sends `MatchStateChanged{phase='hub',notice=...}` if rewards were granted. The ownership request can yield until after the player started a match. That notification must not put the client into hub mode while server combat remains live. Use a notice-only event or include the current authoritative activity state.

Some failure reasons are discarded: `Hub.onCourseEntered` ignores `requestMatch`'s return; the Horde dialogue action does too. A busy/failed request can silently close dialogue. In addition, `returnTokens[player]` increments before validating a requested mode, so a rejected replay request can invalidate the pending automatic return without starting another activity.

**Acceptance:** read and dismiss results after ten seconds; handle replay/shop actions; deliver a delayed commerce completion during live play; exercise every rejected gate request and verify visible feedback without unrelated phase changes.

### 12 — Course, Gauntlet and leaderboard records leak into each other [P2; reproduced/source-confirmed]

Locations: `Profile.luau:343-351,384-393`; `MatchService.luau:1056-1092`; `Leaderboard.luau:239-247,293-296`; `World/NoticeBoard.luau:168`; Bootstrap RequestSessionState; client session-state consumer.

- `Profile.recordMatch` excludes CTF from `bestClears` but not Shoothouse. `hasUnlocked` reads bestClears, so a course clear opens the next map without the corresponding Gauntlet chapter. The audit reproduced this. Campaign correctly uses separate `gauntletClears`, leaving two progression authorities with different answers. Decide the intended unlock rule explicitly and align the gates/chapter messaging.
- Ordered time stores distinguish course from Gauntlet, but metadata keys are just `{map}_{userId}`. One mode overwrites the other's tier/marker/outs.
- `handle.data.bestTimes[mapName]` is overwritten when either mode posts its own PB. It stores raw live time even when the course board ranks death-penalized final time. The shared notice board labels that page “ALL 5 ROUNDS.”
- `RequestSessionState` includes `courses`, but client startup does not consume it. Course previous-best/medal appears at match finish, but a returning player has no full course record browser. `NoticeBoard.top(pageId)` always uses default Gauntlet mode, so course global boards have no in-game browsing route.
- The “YOUR BEST TIMES” board is a shared server SurfaceGui with one `personalName/personalBests` closure. The latest player to refresh it replaces the page for everyone. It is not per-viewer UI.

**Acceptance:** submit Gauntlet and course PBs with different equipment/deaths on one map, reload and view both; preserve mode-specific metadata and final time. Verify two users' personal records independently. Test map unlock and chapter state after each mode.

### 13 — Audio victory cue is stopped immediately [P2; source-confirmed]

`Client/init.client.luau` MatchSummary handler calls `Audio.play('matchCleared')` and then `Audio.clear()` in the same callback. Clear destroys the audio folder and clears its voice tables, including the cue just started. Clear old voices before starting the results cue, or scope the clear to activity voices. Confirm audibly and add a sequence assertion using the audio seam; a sound-ID validity check cannot detect this.

## Explicit deferrals and known constraints

- **Consumables are not live:** keep `liveEnabled=false` until carry selection, activation intent, stock deduction, effect simulation/presentation and drops are implemented. `ConsumableUsed` is declared without a working use pipeline.
- **Co-op is not live:** course maxPlayers/rules do not supply a second player entity to combat/telemetry/shared checkpoint logic. The existing second seat is particularly unsafe because of world ownership. Do not describe it as co-op or build an unrelated lobby.
- **Lag compensation is not live:** target history is captured and latency reported, but rewind is not consumed by projectile resolution. A future travelling-projectile policy needs explicit clock/authority semantics and high-latency testing.
- **Free launch is intentional:** `freeMode=true`, `paidEnabled=false`, `shopFree=true`; do not “fix” it by enabling paid prompts or economy prices. Currency/payout still compute, but money is not currently required for the supported shop inventory.
- **Development flags are on in the actual build:** `Data/dev.json` enables infinite currency, invulnerability and unlockEverything. Harness.build deliberately disables dev overrides for ordinary gates; passing combat checks therefore do not mean the generated playtest has release behavior. Ship-check is the proper blocker. Keep development convenience separate from a verified release artifact.
- **Dev isolation is incomplete:** leaderboard keys are quarantined, but Profile's store name is not selected by dev state. A mistakenly published dev build could retain accelerated currency/camos/chapter progress in the ordinary profile store. Studio Mock limits this in normal local testing; do not characterize local Studio testing as corrupting live data.
- **Rendered validation remains open:** actual mesh/textures/audio permissions and playback, first-person sight picture, input at different frame rates, UI safe areas, network loss/latency, target-device frame time and real datastore persistence were not observed.

## Why the current checks miss this

`check-client-ui` compiles the entry script and executes individual UI modules with hand-made inputs; it does not execute `init.client.luau` as a full dispatcher connected to production service outputs. `check-range` drives only Pop-Up, stubs LoadCharacterAsync to do nothing, and does not execute Bootstrap's CharacterAdded behavior. Its “perfect shooter” solves shots against the erroneous target coordinates and only requires positive hits/score. This audit's normal gate reproduction produced 22/74 hits for 48 targets and still passed.

`run-live-checks` exercises MatchService but mocks world builder, bot/avatar and projectile boundaries. Its signal Disconnect functions are no-ops. This is valuable service logic coverage, but it cannot prove real listener teardown, rendering or Bootstrap coordination. Dedicated CTF navigation/lifecycle checks add meaningful coverage; preserve them and connect their output to the actual client/world lifecycle.

`check-static` searches calls across src/tools/tests, so a rules function called only by specs is “reachable.” `check-config-read` concatenates source, tests and tools, uses textual key presence and stops its config traversal after shallow levels. These are heuristics, not proof that each tunable or exported feature affects gameplay. Compile checks do not perform full Roblox type analysis. The undeclared-scope `DEFAULT_TIER` use in the earlier dialogue closure and `previousPhase` reference in the startup session branch illustrate blind spots; neither is presented here as a confirmed crash (tier falls back, and the latter comparison can evaluate against nil).

Several records are stale: README still says Horde/CTF are not playable and gives old gate/spec counts. CHANGE_REPORT's later limitations still say fixed-step catch-up is uncapped, but MatchService already caps at `maxStepsPerFrame=5` and drops surplus. Do not reimplement an existing cap. Reconcile documentation only after establishing the final code behavior.

## Five additional performance/quality improvements

These are secondary to the failures above. The user made them conditional on a clean audit; this audit is not clean, but these five are provided as a separate optional backlog, not substitutes for repairs.

1. **Use one authoritative clock policy for competitive time and display.** MatchService drops simulation surplus after its step cap while the course HUD accumulates render dt and respawn delay uses task timing. Under a hitch, displayed elapsed time and judged time diverge. Keep bounded physics work, but define elapsed-time/timer semantics explicitly and send periodic server timing anchors. Validate using injected 100 ms/500 ms stalls; do not remove the cap to make clocks agree.
2. **Measure and reduce round/wave avatar churn.** `clearSquad/buildSquad` rebuild outfits and models per wave; CTF repeatedly replaces individual bots. Instrument transition CPU, allocation and replication separately from steady-state frames. Pool/reset bounded avatars if measurement justifies it, carefully resetting paint, pose, flags and event connections. Budget the combined active scene, not only isolated map builders.
3. **Stop replicating server pose changes at simulation frequency where unnecessary.** Bot avatar transforms follow fixed-step logic; decouple authoritative positions from presentation, sending bounded updates and interpolating client visuals if profiling shows replication cost. Keep hitboxes/server trajectories authoritative and validate visual error under packet delay. This is a measured optimization, not a reason to replace the existing bot architecture wholesale.
4. **Give predicted shots an identity and authoritative reconciliation.** Current proximity matching can retire a neighboring tracer, and spread is independently sampled. Add session/shot IDs with server acceptance/rejection and finite visual lifetimes. Include exact impact normals for surface-aligned splats. Test crossing friendly/self/enemy tracer paths, reordering, respawn, and rejected fire without adding extra round-trip latency before rendering.
5. **Cache leaderboard reads and resolve viewer-specific presentation locally.** Board cycling performs sorted reads and per-row metadata lookups, including empty/unreachable mode/map pages. Cache per board/mode with bounded expiry, invalidate on known PB updates, and render personal data per viewer. Track request counts over an idle session and verify failure recovery/stale data behavior. Do not confuse mode-separated caching with the required key correctness fix above.

## Implementation sequence and acceptance contract

1. Add an integration harness that can run Bootstrap plus client dispatch, queue/yield character loads, deliver delayed callbacks and truly disconnect signals. Reproduce the failures before changing production behavior. Keep narrow pure tests as well; they are not the problem.
2. Fix the activity/world lifecycle and character recovery first (01/02/10). These invalidate ordinary manual playtests and can make unrelated components look broken.
3. Repair Range coordinates/shapes, firing payload, start/end state, bounded scheduling and result delivery (03–05). Verify all five authored drills, not just Pop-Up.
4. Fix entitlement/entry authorization and mode-separated rewards/records (07/08/12), then connect or explicitly defer the gear systems (06). Preserve the free launch and earned-only Aurum/camo constraints.
5. Fix stance/aim coherence and objective movement checks (09); results/notice/audio sequencing (11/13). Run the existing gates and new boundary tests.
6. Resolve balance acceptance with actual measured behavior, not weakened assertions. Then perform the Studio/private-published matrix below and record actual observations, hardware, latency, errors and outcomes.

Minimum rendered/service matrix:

- Fresh profile and progressed profile, with **dev disabled**; no inferred success from the invulnerable local build.
- Each map's permitted mode and every gate/NPC/counter; deliberately denied map/mode requests; all five drills selected directly.
- Gauntlet full clear/failure/replay/shop/return; Shoothouse all stages/checkpoints/death/medal/PB; Horde reinforcement/breather/boss/depth/exit; CTF pickup/drop/recovery/score/timeout and both sides' respawns.
- Both users present: join during every phase, remaining in hub, disconnect host, attempt another activity, reset/fall, delayed character load and stale callbacks.
- Fire/reload/melee, crouch/slide/lean near cover; marker and supported gear changes; chapter unlock and Aurum; headshot camo; free season claim after marks already earned.
- Results stay readable; diagnostics reach the coach and practice results are visible; both leaderboard modes and per-viewer records remain correct after rejoin.
- Keyboard/mouse and controller, focus loss and input switching, 30/60/120 FPS, narrow/safe-area layouts. Touch either receives complete controls or is not offered as supported.
- Private published profile save/shutdown/rejoin/session loss, free claims and reward idempotency; no real paid testing without the existing owner decision to enable it.

A feature is complete only when its **entry, validation, authoritative state change, visible feedback, persistence where promised, and teardown/re-entry** are all demonstrated. Rules-only tests and catalogue ownership satisfy only part of that chain.
