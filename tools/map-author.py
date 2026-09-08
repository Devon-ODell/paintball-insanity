#!/usr/bin/env python3
"""Map authoring: rescale a field, and (re)generate its spawns and Shoothouse course.

    python3 tools/map-author.py rescale <map> <factor>   # 0.88 = shrink to 88%
    python3 tools/map-author.py author  <map>            # spawns + course, in place
    python3 tools/map-author.py author  all

This lives in the repo on purpose. The first version of it was a throwaway in a
temp directory, which meant the only record of HOW the fields were rescaled and
how every checkpoint was chosen was a paragraph of prose in the JSON. Regenerating
a course then meant reconstructing the generator from its own output.

Nothing here is run by the game. It edits Data/maps/*.json and the results are
verified by `lune run tools/course-report` and `lune run tools/map-validate`,
which read what shipped rather than trusting this script.
"""

import json
import math
import re
import sys
import collections
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAPS = ["speedball", "dustline", "urban", "woods", "holdfast"]

# Anchors per stage. Fourteen anchors on every field, dealt out so each stage is
# harder than the last; wavesPerStage in Data/course.json refills each stage.
SPLIT = [2, 3, 4, 5]
TIER_OFFSET = [0, 0, 1, 1]
TARGET_SPAWNS = 12

# Inside a cover box by more than this on BOTH axes counts as blocked. It is a
# tolerance, not a player radius: ground nav nodes are authored flush against
# cover faces, so padding by a full 0.6 m rejects every node beside a car.
INSIDE_TOLERANCE = 0.35
MIN_STANDOFF = 6.0
MIN_ADVANCE = 4.0

STAGE_NAMES = {
    "speedball": [("offTheBreak", "Off the Break"), ("theFifty", "The Fifty"),
                  ("theirHalf", "Their Half"), ("backCorners", "The Back Corners")],
    "dustline": [("theNearYard", "The Near Yard"), ("containerRow", "Container Row"),
                 ("theTrailers", "The Trailers"), ("theTower", "The Tower")],
    "urban": [("theApproach", "The Approach"), ("theMarket", "The Market"),
              ("theSquare", "The Square"), ("theRoofs", "The Roofs")],
    "woods": [("theTreeline", "The Treeline"), ("theDraw", "The Draw"),
              ("theClearing", "The Clearing"), ("theHighGround", "The High Ground")],
    "holdfast": [("theLowRoad", "The Low Road"), ("theBridge", "The Bridge"),
                 ("theRuins", "The Ruins"), ("theKeep", "The Keep")],
}

STAGE_NOTES = {
    "speedball": [
        "Two of them on the near bunkers -- the same pair you would meet off a break. The only stage on this field where nobody is outnumbered and you should still win it.",
        "The centre and both wires. Whoever owns the fifty owns the approach to the next stage, and they know it.",
        "Both cans and both doritos, four across. There is no flank here: the field is thirty-four metres wide and all of it is covered.",
        "Five, from the snake's far end to both back corners. Every angle you have been advancing through is now being watched from behind it."],
    "dustline": [
        "Two buses at the bottom of the yard. Nothing about this stage is subtle and nothing about it needs to be.",
        "A trailer, the office and the first container. This is where the lanes start disagreeing with each other about which way forward is.",
        "Four across the jackknifed trailers and the depot roof -- the stage that teaches you the yard is not square to anything.",
        "The far trailer, the bus, both roofs and the tower. The tower sees the entire approach and it has been watching you clear the other three."],
    "urban": [
        "A roof and a dead car, both looking down the road you have to walk up.",
        "Second car, second roof, and the south end of the market. The cover here is chest-high and continuous, which is worse than it sounds.",
        "Planters, the barrier and the left alley. Four, and two of them can rotate behind the stalls without ever showing you a silhouette.",
        "The right alley, the north market, a car and both high roofs. Everything you know about lead on the flat is wrong again the moment they are above you."],
    "woods": [
        "The south shack and a rock, at range, in trees. You will hear this stage before you see it.",
        "Two rocks and a log across the draw. The ground starts working against your holdover here.",
        "The east ridge, both shacks and a treeline -- four defenders spread across a field a hundred metres wide.",
        "The east tower, a log, a rock, the north hill and the north tower. They are above you and they got there first."],
    "holdfast": [
        "The east outpost and a ruin, across open ground. Fifty-six metres of approach before the first shot: this field opens by asking whether you can walk.",
        "Both ridges and a boulder, covering the crossing. There is one bridge and all three of them can see it.",
        "The bridge itself, a boulder, the west outpost and the north ruins. The squad has to split here and punishing the thinner half is the entire stage.",
        "The far ruin, both keep towers, the gate and the wall. Five in a fortification, at fifty metres, after a hundred and forty metres of field."],
}


def load(name):
    return json.load(open(ROOT / "Data" / "maps" / f"{name}.json"),
                     object_pairs_hook=collections.OrderedDict)


def dumps_compact(obj):
    """indent=2, but arrays of plain numbers stay on one line."""
    s = json.dumps(obj, indent=2, ensure_ascii=False)
    return re.sub(r"\[\s+((?:-?\d+(?:\.\d+)?,\s*)*-?\d+(?:\.\d+)?)\s+\]",
                  lambda m: "[" + ", ".join(t.strip().rstrip(",") for t in m.group(1).split()) + "]",
                  s)


def save(name, data, compact=False):
    path = ROOT / "Data" / "maps" / f"{name}.json"
    text = dumps_compact(data) if compact else json.dumps(data, indent=2, ensure_ascii=False)
    path.write_text(text + "\n")
    json.loads(path.read_text())  # never leave invalid JSON behind


def blocked(point, geometry):
    """Is a standing player at `point` inside a cover volume?"""
    for g in geometry:
        if not g.get("cover"):
            continue
        p, s = g["position"], g["size"]
        # An overhead walkway or a kerb does not block anyone standing.
        if p[1] - s[1] / 2 > 1.4 or p[1] + s[1] / 2 < 0.25:
            continue
        dx, dz = point[0] - p[0], point[2] - p[2]
        t = math.radians(g.get("rotationY", 0))
        c, sn = math.cos(-t), math.sin(-t)
        if (s[0] / 2 - abs(dx * c - dz * sn) > INSIDE_TOLERANCE
                and s[2] / 2 - abs(dx * sn + dz * c) > INSIDE_TOLERANCE):
            return True
    return False


# ---------------------------------------------------------------- rescale ----

def rescale(name, k):
    """Scale a field's footprint. Positions AND plan sizes; Y is never touched.

    Scaling positions without sizes leaves cover at full size in a smaller
    field, which pushes nav nodes into buildings and disconnects nav graphs.
    Y is left alone because heights carry tuned see-over relationships.
    navLinkRadiusMetres is deliberately NOT scaled: it is a 3D reach and this
    rescale is horizontal only.
    """
    text = subprocess.run(["git", "show", f"89efc37:Data/maps/{name}.json"],
                          capture_output=True, text=True, cwd=ROOT).stdout
    d = json.loads(text, object_pairs_hook=collections.OrderedDict)

    def sxz(v):
        v[0] = round(v[0] * k, 2)
        v[2] = round(v[2] * k, 2)
        return v

    b = d["bounds"]
    b["widthMetres"] = round(b["widthMetres"] * k, 2)
    b["lengthMetres"] = round(b["lengthMetres"] * k, 2)
    for g in d["geometry"]:
        sxz(g["position"]); sxz(g["size"])
    for t in d.get("terrain", []):
        sxz(t["position"]); sxz(t["size"])
    sxz(d["playerSpawn"]["position"]); sxz(d["playerSpawn"]["lookAt"])
    for key in ("playerRespawns", "botSpawns"):
        for e in d[key]:
            sxz(e["position"]); sxz(e["lookAt"])
    for a in d["anchors"]:
        sxz(a["position"])
    for n in d["navNodes"]:
        n[0] = round(n[0] * k, 2); n[2] = round(n[2] * k, 2)
    for s in d["sightlines"]:
        s["lengthMetres"] = round(s["lengthMetres"] * k, 2)
    for e in d.get("prePlacementAngles", []):
        sxz(e["watch"])
    band = d["engagementBand"]
    for key in ("minMetres", "targetMedianMetres", "maxMetres"):
        band[key] = round(band[key] * k, 2)
    for gd in d.get("presentation", {}).get("groundDetails", []):
        for point in gd["points"]:
            sxz(point)
        if "widthMetres" in gd:
            gd["widthMetres"] = round(gd["widthMetres"] * k, 2)
    ctf = d.get("captureTheFlag")
    if ctf:
        for key in ("enemyFlag", "playerFlag", "enemyGate", "playerGate"):
            sxz(ctf[key]["position"])
            if "widthMetres" in ctf[key]:
                ctf[key]["widthMetres"] = round(ctf[key]["widthMetres"] * k, 2)
        for w in ctf.get("wallClimbs", []):
            sxz(w["position"])
    save(name, d)
    print(f"{name}: rescaled to {int(k * 100)}%  {b['widthMetres']} x {b['lengthMetres']}  band {band['targetMedianMetres']} m")


# ----------------------------------------------------------------- spawns ----

def author_spawns(d):
    """Top the bot spawns up to TARGET_SPAWNS from the field's own nav nodes.

    Crowd them before you advance them: extras squeeze into the defenders' own
    end at tighter spacing FIRST, and only fall back to their wider half if the
    back cannot hold twelve. Relaxing depth first put Speedball's reinforcements
    at midfield, which inverted the map -- probe-trading went +3.33 to -0.83.
    """
    d["botSpawns"] = d["botSpawns"][:6]
    geometry, nodes = d["geometry"], d["navNodes"]
    existing = [s["position"] for s in d["botSpawns"]]
    start = d["playerSpawn"]["position"]

    # The defenders' end, then a little more of it -- never their half at large.
    # A 2 m band behind the authored line is too tight to hold six more on a
    # small field, and falling all the way back to "their half" put a Speedball
    # spawn at midfield, which is the thing that inverted the map.
    deepest = min(z[2] for z in existing)
    length = d["bounds"]["lengthMetres"]
    back = deepest - 0.12 * length
    half = max(0.0, deepest - 0.20 * length)

    chosen = []
    for zmin in (back, half):
        sep = 6.0
        while len(existing) + len(chosen) < TARGET_SPAWNS and sep >= 1.5:
            best = None
            for n in nodes:
                if n[1] > 1.0 or n[2] < zmin:
                    continue
                c = [n[0], 0, n[2]]
                if blocked(c, geometry):
                    continue
                if any(math.dist((c[0], c[2]), (e[0], e[2])) < sep for e in existing + chosen):
                    continue
                score = min(math.dist((c[0], c[2]), (e[0], e[2])) for e in existing + chosen)
                if best is None or score > best[0]:
                    best = (score, c)
            if best is None:
                sep -= 0.25
                continue
            chosen.append(best[1])
        if len(existing) + len(chosen) >= TARGET_SPAWNS:
            break

    for c in chosen:
        d["botSpawns"].append(collections.OrderedDict([
            ("position", [round(c[0], 2), 0, round(c[2], 2)]),
            ("lookAt", [round(start[0], 2), 0, round(start[2], 2)]),
        ]))
    return len(chosen)


# ----------------------------------------------------------------- course ----

def pick_checkpoint(nodes, geometry, desired, zmax, zmin):
    best, cost = None, 1e18
    for n in nodes:
        if n[1] > 1.0 or n[2] > zmax or n[2] < zmin:
            continue
        if blocked(n, geometry):
            continue
        c = abs(n[2] - desired) + 0.5 * abs(n[0])
        if c < cost:
            best, cost = n, c
    return best


def author_course(name, d):
    geometry, nodes = d["geometry"], d["navNodes"]
    anchors = sorted(d["anchors"], key=lambda a: a["position"][2])
    if len(anchors) != sum(SPLIT):
        raise SystemExit(f"{name}: {len(anchors)} anchors, course expects {sum(SPLIT)}")
    by_id = {a["id"]: a["position"] for a in d["anchors"]}
    length = d["bounds"]["lengthMetres"]
    standoff = min(max(length * 0.12, 8.0), 16.0)
    start = d["playerSpawn"]["position"]
    span = round(max(a["position"][2] for a in anchors) - start[2], 1)

    rules = json.load(open(ROOT / "Data" / "course.json"))
    waves = rules["wavesPerStage"]
    defenders = sum(SPLIT) * waves
    band = d["engagementBand"]["targetMedianMetres"]
    # Gold = the walk plus the fights. Per-defender seconds scale with the
    # field's own engagement band: a 52 m fight is not a 16 m fight.
    per_bot = 4.5 * (1 + (band - 16) / 60.0)
    r5 = lambda x: int(round(x / 5.0) * 5)
    gold = r5(span / 2.4 + defenders * per_bot)
    silver, bronze = r5(gold * 1.35), r5(gold * 1.85)

    stages, i, prev = [], 0, start[2]
    for si, (count, (sid, sname)) in enumerate(zip(SPLIT, STAGE_NAMES[name])):
        group = anchors[i:i + count]
        i += count
        front = min(a["position"][2] for a in group)
        if si == 0:
            cp = list(start)
        else:
            zmax = front - MIN_STANDOFF
            zmin = min(prev + MIN_ADVANCE, zmax)
            desired = max(zmin, min(front - standoff, zmax))
            # Relax the advance, never the direction: a checkpoint that repeats
            # or retreats means clearing a stage moved you backwards.
            cp = (pick_checkpoint(nodes, geometry, desired, zmax, zmin)
                  or pick_checkpoint(nodes, geometry, desired, zmax, prev + 0.5)
                  or pick_checkpoint(nodes, geometry, desired, front - 3.0, prev + 0.5))
            if cp is None:
                cp = [0, 0, round(max(prev + 2.0, min(desired, front - 3.0)), 2)]
                if blocked(cp, geometry):
                    raise SystemExit(f"{name}/{sid}: no clear checkpoint")
        prev = cp[2]
        ids = [a["id"] for a in group]
        mid_x = round(sum(by_id[x][0] for x in ids) / len(ids), 2)
        stages.append(collections.OrderedDict([
            ("id", sid), ("displayName", sname), ("_note", STAGE_NOTES[name][si]),
            ("tierOffset", TIER_OFFSET[si]),
            ("checkpoint", collections.OrderedDict([
                ("position", [round(v, 2) for v in cp]),
                ("lookAt", [mid_x, 0, round(front, 2)])])),
            ("anchors", ids)]))

    d["course"] = collections.OrderedDict([
        ("_comment", f"The Shoothouse route through {d['displayName']}. Four stages, fought from the near end to the far. Rules live in Data/course.json; regenerate with tools/map-author.py."),
        ("_stagesAreAnchors", "Every stage is a slice of this map's own anchors list, sorted by depth. No cover moved and no positions were invented for this mode -- the field plays as itself, met in order."),
        ("spanMetres", span),
        ("defenders", defenders),
        ("parSeconds", collections.OrderedDict([("gold", gold), ("silver", silver), ("bronze", bronze)])),
        ("_parSeconds", f"Derived, not hand-picked: gold = {span} m span / 2.4 m/s + {defenders} defenders x {round(per_bot, 2)} s, where the per-defender figure scales with this map's {band} m engagement band. Silver is gold x 1.35, bronze x 1.85. A first-pass estimate from geometry that no human has yet run; retune against real times and keep the derivation, not the number."),
        ("stages", stages)])
    return gold, silver, bronze, span


def author(name):
    d = load(name)
    added = author_spawns(d)
    gold, silver, bronze, span = author_course(name, d)
    save(name, d)
    print(f"{name:10s} spawns={len(d['botSpawns'])} (+{added})  span={span:6.1f} m  par {gold}/{silver}/{bronze}")


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("rescale", "author"):
        print(__doc__)
        raise SystemExit(2)
    command, target = sys.argv[1], sys.argv[2]
    names = MAPS if target == "all" else [target]
    if command == "rescale":
        for n in names:
            rescale(n, float(sys.argv[3]))
    else:
        for n in names:
            author(n)


if __name__ == "__main__":
    main()
