# paintball-insanity — Debug & Vulnerability Report
**Scope:** `main` @ `a61fe64` ("not working update 0.2"), diffed against the prior commit `89efc37`.
**Note on the push:** despite the "Everything up-to-date" message you saw, this commit *is* on GitHub `main` — I cloned it fresh and confirmed the head matches. So the push worked; the confusion was purely the branch-name mismatch from the earlier message.

---

## TL;DR

Cursor didn't just do "2x enemies + smaller map." It quietly built an entire second game mode (a two-player co-op "Shoothouse" timed course) on top of that, touched the project's core architecture doc, rewrote geometry for 5 of 6 maps, and reformatted every JSON file it touched into one-value-per-line — which is why `git status` looked like a bomb went off. Two real problems fell out of that scope creep:

1. **The map isn't actually 90% smaller.** It's 88% of its *original* size — i.e. only ~12% smaller, not ~90% smaller. That's the literal ask not being met, by a wide margin.
2. **The new Shoothouse mode is dead code.** ~600 lines and 3 new modules exist, have their own passing unit tests, and are completely unreachable from an actual match — nothing in `Bootstrap`, `MatchService`, or `RoundState` ever starts it. That's almost certainly why Cursor called this commit "not working."

The enemy-doubling itself (6 → 12 bots) looks solid and consistent everywhere it needed to change. That part you can trust.

---

## 1. HIGH — "90% smaller map" was implemented as "88% of original size"

Every rescaled map carries this note verbatim in `Data/maps/*.json`:

> *"Field rescaled to 88% of its footprint on 2026-09-07... Scaling positions without sizes was tried first and was wrong... Scaling both preserves every gap, every clearance and every ratio exactly, and only the world gets smaller."*

Measured directly:

| Map | Old bounds (W×L m) | New bounds (W×L m) | Actual shrink |
|---|---|---|---|
| Dustline | 84 × 96 | 73.9 × 84.5 | 12% |
| Woods | 100 × 120 | 88.0 × 105.6 | 12% |
| Urban | 70 × 80 | 61.6 × 70.4 | 12% |
| Holdfast | 150 × 200 | 132.0 × 176.0 | 12% |
| Speedball | 34 × 55 | **unchanged** | 0% |

Reading "90% smaller" as "scale to 90%" vs. "reduce area by 90%" is an understandable ambiguity, but 88% doesn't match *either* reading of what you asked for. It's a small, cosmetic tightening, not the drastic arena you described.

**Why it stopped at 88%, per Cursor's own notes:** they ran `tools/probe-trading` on Speedball at squad size 12 and found that below ~88% scale, the map's core design property (trading is punished harder than holding an angle) inverts — at 95% scale trading gets *safer*, and at 88% the effect disappears entirely. They then appear to have applied that one number to all four other maps without re-running the same balance probe on each of them individually — the note only documents the Speedball measurement, not Dustline/Woods/Urban/Holdfast.

**My read:** this is very likely *why* Cursor was struggling — a genuinely ~90%-smaller map with double the bots probably does break line-of-sight balance and nav-graph connectivity (their own note admits naive position-only scaling already disconnected the nav graph on Dustline and Holdfast at a much gentler 88%). Rather than surface that as a hard constraint and negotiate a different number with you, it looks like the shrink got quietly capped at "the number that didn't break the one map it was tested on" and shipped everywhere.

**Recommendation:** decide what you actually want given the real tradeoff — a small, safe shrink (what you have now) or a large one that will require retuning bot aim/sightline tuning per map to keep it fair. If you want the aggressive version, that's a real, bounded piece of work, not a one-line JSON edit — worth scoping separately.

---

## 2. HIGH — The new "Shoothouse" co-op mode is entirely disconnected from the live game

This commit adds:
- `src/ReplicatedStorage/Shared/Courses.luau` (132 lines)
- `src/ServerScriptService/Match/Course.luau` (254 lines)
- `src/ServerScriptService/Progression/CourseProgress.luau` (129 lines)
- `Data/course.json` (116 lines)
- `tools/course-report.luau`
- A `"shoothouse"` entry in `Data/gamemodes.json` with `"rules": "course"`, `"maxPlayers": 2`
- A rewrite of the "Solo PvE" section of `CLAUDE.md` to carve out a two-player exception
- 307 lines of new tests in `tests/Course.spec.luau`

I traced every reference to these modules across `src/`. Result:

- `CourseProgress.luau` is the **only** file that requires `Course.luau` or `Courses.luau`.
- **Nothing requires `CourseProgress.luau`.** Not `Bootstrap.server.luau`, not `MatchService.luau`, not `RoundState.luau` — zero references to "Course" anywhere in the match-start or round-flow code.
- `gamemodes.json` declares `"rules": "course"` for Shoothouse, but nothing in the codebase branches on that value — the string that's supposed to route to the new mode is never checked against.
- `WorldBuilder.luau` only changed by 6 lines this commit, and none of them relate to Course — it wasn't touched to support the new mode at all.

The one place this new system *is* live-connected is `Camos.luau` (see #3 below).

**Why the tests pass anyway:** `tests/Course.spec.luau` calls `Course.all(...)`/`CourseProgress.record(...)` directly as a pure unit — it never goes through `MatchService` or an actual match start. So you can have 307 green assertions and a mode that a player can never reach in Studio. That mismatch (green tests, broken game) is exactly the gap `docs/DEBUG_REVIEW.md` already flagged in this repo as a standing risk: *"Passing headless tests does not establish that the game works in Studio."*

**Recommendation:** either (a) finish wiring Shoothouse into `Bootstrap`/`MatchService` (real work — new mode dispatch, the two-player match slot, checkpoint/clock sync), or (b) revert the Shoothouse-related files out of this commit entirely and re-request it as its own task later. Shipping it half-wired is worse than not having it — see #3.

---

## 3. MEDIUM — Unreachable content gate: some camo unlocks can never be earned

`Camos.luau` was changed to let a finish's unlock condition be `Courses.meets(data, entry.requires)` instead of the usual headshot count — used for gold-medal-gated cosmetics (the note in the diff calls out the Aurum Kompressor tier specifically). This path *is* wired into the live wardrobe/shop code (`Camos.catalogue`, used by `ShopUi`/`Wardrobe`).

The good news: `Courses.luau` is written defensively — every read type-checks its input and falls back to `0`/`false` on missing data, so this will **not crash** the shop or wardrobe UI for existing or new profiles.

The bad news: because Shoothouse (#2) can never actually be played, `data.courseRecords` will never be populated for anyone, so `Courses.meets(...)` will always return `false`. Any cosmetic gated behind a `requires` block is **permanently unobtainable** in the current build — not broken, just silently impossible. If a player opens the wardrobe and sees a locked item counting down "3 more gold medals on the Shoothouse," that mode doesn't exist for them to go earn it in.

**Recommendation:** don't ship `camos.json` entries with `requires` set until Shoothouse is actually reachable, or gate the whole camo behind a feature flag (the repo already has `Data/dev.json` for this pattern).

---

## 4. LOW/PROCESS — Diff hygiene made this much harder to review than it needed to be

All five map JSON files and `maps_index.json` were reformatted from compact arrays (`[96, 128, 82]`) to one-value-per-line, inflating the diff by roughly 10x on files that mostly didn't change in substance. Combined with the scope creep in #2, the commit touches 24 files and +4289/-1583 lines for what was framed to you as "double enemies, shrink the map." That's the proximate reason `git status` looked alarming and the reason it's hard to tell, at a glance, what's actually new vs. reformatted.

**Recommendation:** ask for (or configure) a stable JSON formatter setting so future diffs on `Data/*.json` reflect only real changes, and ask Cursor to commit per logical change (enemy count, map scale, new mode) rather than one lump — `HANDOFF_worldpass_01.md` in this same repo already states that convention ("Commit per task, not one lump") for a different pass, so it's not being followed consistently.

---

## 5. Things that *do* look solid

- **Bot count doubling (6 → 12)** is consistent and correctly threaded through: `CLAUDE.md`, `Data/match.json` (`squadSize: 12`, with a note explaining why every map now has exactly 12 authored spawns so `MatchService`'s modulo spawn-cycling doesn't stack bots on top of each other), and `Data/endless.json` (wave base bot count doubled 3 → 6 to match).
- **The map-scaling method itself is technically correct**, even though the target number is wrong: scaling both position *and* footprint size (not just position) preserving gaps/clearances/ratios is the right way to shrink a level without breaking cover geometry or nav graphs. If you do want a bigger shrink later, this is the right mechanism to reuse — it just needs to go further and be re-validated per map.
- **Unrelated legitimate bugfix bundled in:** `brush`, `stone`, and `containerRust` materials were used by Woods/Holdfast/Dustline scatter but never declared in the surface-material table, so treelines/outcrops were rendering as flat grey concrete boxes instead of their intended material. That's now fixed in `WorldBuilder.luau`. Good catch, just oddly scoped into this same commit.

---

## Suggested next step

Given the size of what's actually in this commit, I'd treat it as two separate asks going forward:
1. A small, targeted fix for the map-scale number (either accept 88% or decide how far you actually want to push it, knowing it'll require real balance retuning).
2. A decision on Shoothouse: finish wiring it in as a real task, or strip it out of `main` until it's ready so you're not carrying ~600 lines of unreachable code and unearnable cosmetics.
