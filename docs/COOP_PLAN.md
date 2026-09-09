# Two-player co-op — what it actually costs

**Status: not built. Nothing in this document is implemented.**

Written 2026-09-08 after tracing every place the code assumes one player, so the
decision to build it is made against evidence rather than a guess. CLAUDE.md
already says co-op is authorized and unbuilt; this says what "unbuilt" means in
lines and in risk.

The place is `MaxPlayers = 2` and a second player can join, walk the hub, use the
barn and read the board. What they cannot do is join a run:
`Bootstrap.requestMatch` refuses when `MatchService.currentHost()` is someone
else. That guard is correct and must stay until everything below is done —
without it, two matches build two maps at the world origin and park the hub out
from under whoever stayed behind.

---

## What is already fine

- **The bot AI is target-agnostic.** `BotController.canSee(self, targetPosition)`
  and `AimModel.solve(params)` take a target rather than assuming one. Nothing in
  the aim model needs to change.
- **Everything economic is per-player already.** Payout, profile, season marks,
  camo progress and course records are all keyed by a profile handle.
- **The co-op RULES exist and are specced** — defender scaling, the shared clock,
  the checkpoint that banks only when both players are past it, medals that
  record but never buy the Aurum.

## What has to change

### 1. One match, N players — not N matches

`MatchService.start(player, ...)` builds a closure per player and stores it as
`active[player]`. A shared match means one closure owning a roster, and
`active` becoming a map from player to the match they are *in* rather than the
match they *own*.

### 2. The player stops being a single capsule

`id = "player"` and `team = "player"` appear at 8 sites in `MatchService` and 6
in `SimMatch`. Every one becomes a per-player id on a shared `"players"` team, so
`ProjectileSim` can tell two friendly capsules apart, and friendly paint has to
be decided — in paintball a teammate's ball marks you, which is a design call,
not a code one.

### 3. The squad has to divide its attention

`coordinator:updateCrossfire(bots, playerPosition, t)` takes one position. Twelve
bots choosing between two targets is the whole character of co-op, and it is
where the difficulty actually lives.

### 4. Telemetry needs a player dimension — and this one is easy to miss

`ShotLog.new(map, marker, tier)` has no player field. In a shared match both
players' shots land in one log, so `Prescription.forSession` would diagnose *the
pair* and hand both of them the same advice about someone else's aim. The coach
loop would silently start lying. A log per player in the match, merged only for
the match summary.

### 5. The client has to show a second person

`MatchStateChanged` is fired at one player. Round state, the clock, the
checkpoint and the results screen all need fanning out, and the HUD needs to say
where your partner is and whether they are out.

---

## The cost nobody counts

**Every balance number in this project describes solo play.**

`SimMatch` models exactly one player — one capsule, one policy, one hopper. The
difficulty ordering, the trading probe, the engagement bands and the whole table
in `PUBLISH_READINESS.md` are all measurements of one person against twelve bots.

Two players do not make it "the same but easier". Twelve bots splitting attention
across two targets changes which angles are safe, how long a peek lasts, and
whether trading is punished — the exact properties the maps were tuned around.
**Those numbers would not transfer, and there would be no way to re-derive them
without teaching `SimMatch` to run two policies at once.**

So the real order of work is:

1. Two players in `SimMatch` first, because it is pure and cheap to verify
2. Re-derive the difficulty and trading numbers for two players
3. Then the live shared match, checked against the sim the way solo already is

Doing it the other way round produces a co-op mode nobody can say is balanced,
and the same is true of Woods and Holdfast, which do not punish trading correctly
even at one player (see `PUBLISH_READINESS.md`).

---

## Recommendation

Ship solo first. It is a complete game, it is what every number in the repository
describes, and the Shoothouse works today for one player. Build co-op as its own
piece of work with its own balance pass, starting in the simulation.

The guard in `requestMatch` is what keeps that decision honest: while it is
there, co-op cannot half-exist.
