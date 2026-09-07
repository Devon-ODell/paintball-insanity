#!/usr/bin/env python3
"""
Pushes nav nodes out of cover, and reformats map JSON.

    python3 tools/fix-nav-nodes.py              # every map
    python3 tools/fix-nav-nodes.py holdfast     # one map

A nav node buried inside a bunker is a map-authoring mistake: bots path to a
place they cannot stand, and the automatic linker refuses to connect it to
anything. tools/map-validate reports them; this fixes them, by nudging each one
out along whichever horizontal axis needs the smaller move.

Authoring assist only -- it runs at edit time, never at runtime. The result is
still hand-editable JSON that you own.
"""
import json, math, re, sys, glob, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INDEX = json.load(open(os.path.join(ROOT, 'Data/maps_index.json')))
PROBE = INDEX['assembly']['coverProbeHeightMetres']
CLEAR = 0.85  # nav agent radius plus a margin


def volumes(md):
    """Expand a map's geometry into oriented boxes, mirrors included."""
    out = []
    groups = [g for g in (md.get('terrain'), md.get('geometry')) if g]
    for group in groups:
        for p in group:
            variants = [(False, False)]
            if p.get('mirrorX'):
                variants.append((True, False))
            if p.get('mirrorZ'):
                variants.append((False, True))
            if p.get('mirrorX') and p.get('mirrorZ'):
                variants.append((True, True))
            for mx, mz in variants:
                pos = list(p['position'])
                size = list(p['size'])
                rot = math.radians(p.get('rotationY', 0))
                if mx:
                    pos[0] = -pos[0]
                    rot = -rot
                if mz:
                    pos[2] = -pos[2]
                    rot = -rot
                # A cylinder laid on its side is a log: swap its extents.
                if p.get('rotationZ', 0):
                    size = [size[1], size[0], size[2]]
                out.append(dict(
                    id=p['id'] + ('_mx' if mx else '') + ('_mz' if mz else ''),
                    c=pos, h=[s / 2 for s in size], rot=rot,
                    cover=bool(p.get('cover')), walkable=bool(p.get('walkable'))))
    return out


def to_local(v, pt):
    dx, dy, dz = pt[0] - v['c'][0], pt[1] - v['c'][1], pt[2] - v['c'][2]
    c, s = math.cos(-v['rot']), math.sin(-v['rot'])
    return [dx * c - dz * s, dy, dx * s + dz * c]


def to_world(v, lp):
    c, s = math.cos(v['rot']), math.sin(v['rot'])
    return [lp[0] * c - lp[2] * s + v['c'][0], lp[1] + v['c'][1], lp[0] * s + lp[2] * c + v['c'][2]]


def inside(v, pt):
    p = to_local(v, pt)
    return all(abs(p[i]) <= v['h'][i] for i in range(3))


def dump(o, indent=0, inline_len=6):
    """Pretty JSON that keeps short numeric arrays -- coordinates and colours --
    on one line, so the data stays hand-editable."""
    pad = "  " * indent
    if isinstance(o, dict):
        if not o:
            return "{}"
        items = [f'{pad}  {json.dumps(k)}: {dump(v, indent + 1, inline_len)}' for k, v in o.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(o, list):
        if not o:
            return "[]"
        if all(isinstance(x, (int, float)) for x in o) and len(o) <= inline_len:
            return "[" + ", ".join(json.dumps(x) for x in o) + "]"
        items = [f'{pad}  {dump(v, indent + 1, inline_len)}' for v in o]
        return "[\n" + ",\n".join(items) + "\n" + pad + "]"
    return json.dumps(o)


def fix(name):
    path = os.path.join(ROOT, f'Data/maps/{name}.json')
    md = json.load(open(path))
    blockers = [v for v in volumes(md) if v['cover'] and not v['walkable']]
    nodes = [list(n) for n in md['navNodes']]
    moved = 0

    for i, n in enumerate(nodes):
        original = list(n)
        for _ in range(8):
            probe = [n[0], n[1] + PROBE, n[2]]
            hit = next((v for v in blockers if inside(v, probe)), None)
            if not hit:
                break
            lp = to_local(hit, probe)
            penX = hit['h'][0] - abs(lp[0])
            penZ = hit['h'][2] - abs(lp[2])
            if penX <= penZ:
                lp[0] = math.copysign(hit['h'][0] + CLEAR, lp[0] if lp[0] != 0 else 1)
            else:
                lp[2] = math.copysign(hit['h'][2] + CLEAR, lp[2] if lp[2] != 0 else 1)
            w = to_world(hit, lp)
            n[0], n[2] = round(w[0], 2), round(w[2], 2)
        if [round(x, 2) for x in n] != [round(x, 2) for x in original]:
            moved += 1

    if not moved:
        print(f'{name}: nothing buried')
        return 0

    def fmt(node):
        return '[' + ', '.join(('%g' % round(x, 2)) for x in node) + ']'

    lines = ['    ' + ', '.join(fmt(node) for node in nodes[k:k + 5]) for k in range(0, len(nodes), 5)]
    block = '  "navNodes": [\n' + ',\n'.join(lines) + '\n  ],'
    src = open(path).read()
    src, count = re.subn(r'  "navNodes": \[.*?\n  \],', block, src, count=1, flags=re.S)
    assert count == 1, f'{name}: could not locate the navNodes block'
    open(path, 'w').write(src)
    json.load(open(path))
    print(f'{name}: moved {moved} node(s) out of cover')
    return moved


if __name__ == '__main__':
    targets = sys.argv[1:] or INDEX['order']
    total = sum(fix(name) for name in targets)
    print(f'total moved: {total}')
