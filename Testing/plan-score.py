#!/usr/bin/env python3
"""Scores a plan without touching a device, so planner changes can be compared in seconds.

    fatrabbit -n --plain --verbose <volume> 2> plan.txt
    python3 plan-score.py plan.txt <label>

Reports moves, clusters, generations, staged hops, the transfer count after CopyBatch's both-sides
fusion, and a predicted seek cost. A dry run reads but never writes, so this is safe against a real
volume as well as an image.

Predicted cost ranks reliably and overstates magnitudes: it called the sibling-order change 36%
better where the drive delivered 14%. Use it to choose between candidates, not to promise a figure.

Optimise the predicted cost, not the move count. Move count varies by a quarter of a percent across
every ordering rule tried, because the layout fixes it — every object whose home differs from where it
sits has to move, and on a fragmented volume that is nearly all of them.

Cost curve measured with gap-cost.py on /dev/rdisk14 (raw), ms per transfer by preceding gap.
"""
import re, sys

COST_MS = [(0, 1.08), (16, 1.35), (64, 1.40), (128, 2.25), (256, 4.27), (512, 7.95)]
CLUSTER = 16384


def cost_of(gap_bytes):
    gap = gap_bytes / 1024
    if gap <= 0: return COST_MS[0][1]
    for (lo, lc), (hi, hc) in zip(COST_MS, COST_MS[1:]):
        if gap <= hi:
            return lc + (hc - lc) * (gap - lo) / (hi - lo)
    return COST_MS[-1][1]


span = re.compile(r'^\s+(\d+)…(\d+) → (\d+)…(\d+)\s*$')
single = re.compile(r'^\s+(\d+) → (\d+)\s*$')

# The report says "168 generations" and "45295 objects" now, and said "generation(s)" and "object(s)"
# before it learned to count. Both spellings are accepted so that captures taken either side of that
# change still score — several figures quoted in README.md come from the older ones.
gen, gens, stats = None, {}, {}
for line in open(sys.argv[1]):
    m = re.search(r'in (\d+) generations?(?:\(s\))?, (\d+) staged', line)
    if m: stats['generations'], stats['staged'] = int(m.group(1)), int(m.group(2))
    # "Plan: 44164 moves / 85105 clusters" now, "Would move 44164 objects / 85105 clusters" before.
    # Both spellings are accepted for the same reason the generation line's are, one line below: this
    # printed 0 for both figures against a current build, silently, which is the one failure mode a
    # scorer must not have — the columns it exists to compare read as though nothing was planned.
    m = re.search(r'(?:Would move|Plan:) (\d+) (?:objects?(?:\(s\))?|moves) / (\d+) cluster', line)
    if m: stats['moves'], stats['clusters'] = int(m.group(1)), int(m.group(2))
    g = re.match(r'\s*Generation (\d+)/', line)
    if g: gen = int(g.group(1)); gens.setdefault(gen, [])
    m = span.match(line)
    if m: s0, s1, d0, d1 = map(int, m.groups())
    else:
        m = single.match(line)
        if not m or gen is None: continue
        s0 = s1 = int(m.group(1)); d0 = d1 = int(m.group(2))
    if gen is not None: gens[gen].append((s0, s1, d0, d1))

transfers, predicted = 0, 0.0
for g in gens:
    items = sorted(gens[g])
    fused, i = [], 0
    while i < len(items):                       # both-sides adjacency, as CopyBatch does
        s0, s1, d0, d1 = items[i]
        j = i + 1
        while j < len(items) and items[j][0] == s1 + 1 and items[j][2] == d1 + 1:
            s1, d1 = items[j][1], items[j][3]; j += 1
        fused.append((s0, s1, d0, d1)); i = j
    transfers += len(fused)
    for key, gapper in ((0, lambda a, b: b[0] - a[1] - 1), (2, lambda a, b: b[2] - a[3] - 1)):
        seq = sorted(fused, key=lambda r: r[key])
        predicted += cost_of(0)
        for a, b in zip(seq, seq[1:]):
            predicted += cost_of(max(0, gapper(a, b)) * CLUSTER)

print(f"{sys.argv[2]:<12}{stats.get('moves',0):>9,}{stats.get('clusters',0):>11,}"
      f"{stats.get('generations',0):>7}{stats.get('staged',0):>8}"
      f"{transfers:>10,}{predicted/1000:>10.0f}s")
