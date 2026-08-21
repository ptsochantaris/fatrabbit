#!/usr/bin/env python3
"""Works out whether merging nearby transfers would pay, before any of it is written.

    fatrabbit -n --plain --verbose <volume> 2> spans.txt
    python3 span-gaps.py spans.txt [cluster-bytes] [budget-MB]

A run moves tens of thousands of small pieces, and on a spinning drive the positioning between
them costs far more than the data. Two pieces that are close together could be fetched in one
transfer, reading the gap between them rather than seeking over it — worth it whenever the gap is
smaller than what the drive could have transferred in the time a seek takes.

This reads the per-span detail the tool already emits, reconstructs the batches it would form and
the order it would issue them in, and reports how many separate transfers survive at a range of
merge thresholds. It does not touch a drive: the answer is in the layout, and the layout is in
the plan.

Reads and writes are reported separately because they are not alike. Sources are scattered over
wherever the volume happens to hold things; destinations are the compacted layout being built, and
are packed. If that shows up here, then merging is a read-side change and the write side needs
nothing.
"""

import re
import sys

SPAN = re.compile(r'^\s+(\d+)…(\d+) → (\d+)…(\d+)\s*$')
GENERATION = re.compile(r'^\s*Generation \d+/\d+: \d+ move')


def batches(path, cluster, budget):
    """The spans as the tool would group them: in order, closed when the batch fills or the
    generation ends, since a commit flushes whatever is held."""
    out, current, held = [], [], 0
    for line in open(path, errors='replace'):
        if GENERATION.match(line):
            if current:
                out.append(current)
            current, held = [], 0
            continue
        found = SPAN.match(line)
        if not found:
            continue
        source, source_end, destination, destination_end = (int(n) for n in found.groups())
        size = (source_end - source + 1) * cluster
        if held + size > budget and current:
            out.append(current)
            current, held = [], 0
        current.append((source, destination, size))
        held += size
    if current:
        out.append(current)
    return out


def transfers(groups, key, cluster, thresholds):
    """How many separate transfers survive at each merge threshold, and what extra gets read."""
    counts = {gap: [0, 0] for gap in thresholds}          # transfers, wasted bytes
    total = 0
    for group in groups:
        ordered = sorted(group, key=key)
        total += len(ordered)
        for gap in thresholds:
            runs, waste = 1, 0
            end = ordered[0][key_index(key)] * cluster + ordered[0][2]
            for span in ordered[1:]:
                start = span[key_index(key)] * cluster
                if 0 <= start - end <= gap:
                    waste += start - end
                else:
                    runs += 1
                end = start + span[2]
            counts[gap][0] += runs
            counts[gap][1] += waste
    return total, counts


def key_index(key):
    return 0 if key is source_of else 1


def source_of(span):
    return span[0]


def destination_of(span):
    return span[1]


# What one transfer costs on a given medium, by the distance from the end of the previous one.
# Measured with gap-cost.py on /dev/rdisk14, which is the path every device run now takes. Take the
# second reading and later: the first row of a cold run pays for positioning and reads about twice
# what it settles at.
#
# gap-cost.py also reports a 1024 KB gap at 4.45 ms, reproducibly cheaper than 512 KB at 7.95. That
# is rotational aliasing at that particular stride, not large gaps becoming cheap, so the curve stops
# at the last point that behaves and `cost_of` holds it flat beyond — which errs toward seeking, the
# conservative direction.
COST_MS = [(0, 1.08), (16, 1.35), (64, 1.40), (128, 2.25), (256, 4.27), (512, 7.95)]


def cost_of(gap_bytes):
    """Interpolated from the measured curve, held flat past the last point measured."""
    gap = gap_bytes / 1024
    if gap <= COST_MS[0][0]:
        return COST_MS[0][1]
    for (low, low_cost), (high, high_cost) in zip(COST_MS, COST_MS[1:]):
        if gap <= high:
            return low_cost + (high_cost - low_cost) * (gap - low) / (high - low)
    return COST_MS[-1][1]


def predict(groups, cluster):
    """Total seconds the passes would take, from each transfer's distance to the one before it."""
    total = 0.0
    for key, index in ((source_of, 0), (destination_of, 1)):
        for group in groups:
            ordered = sorted(group, key=key)
            end = None
            for span in ordered:
                start = span[index] * cluster
                total += cost_of(0 if end is None else max(0, start - end))
                end = start + span[2]
    return total / 1000


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    numbers = [a for a in sys.argv[2:] if not a.startswith('--')]
    cluster = int(numbers[0]) if numbers else 16384
    budget = (int(numbers[1]) if len(numbers) > 1 else 64) * 1024 * 1024

    if '--budgets' in sys.argv:
        # How much a batch holds decides how densely its spans are spread once sorted: the same
        # spans over the same range, gathered into fewer sweeps, hop shorter distances.
        print(f'{"budget":>9}  {"batches":>8}  {"spans/batch":>12}  {"median gap":>11}  {"predicted":>10}')
        for mb in (16, 32, 64, 128, 256, 512, 1024):
            groups = batches(path, cluster, mb * 1024 * 1024)
            gaps = []
            for group in groups:
                ordered = sorted(group, key=source_of)
                end = None
                for span in ordered:
                    start = span[0] * cluster
                    if end is not None:
                        gaps.append(max(0, start - end))
                    end = start + span[2]
            gaps.sort()
            spans = sum(len(g) for g in groups)
            print(f'{mb:>6} MB  {len(groups):>8}  {spans // max(len(groups), 1):>12}  '
                  f'{gaps[len(gaps) // 2] / 1024:>8.0f} KB  {predict(groups, cluster):>8.0f} s')
        return

    groups = batches(path, cluster, budget)
    spans = sum(len(g) for g in groups)
    moved = sum(s[2] for g in groups for s in g)
    print(f'{spans} spans, {moved / 2**20:.0f} MB, in {len(groups)} batches '
          f'({spans / max(len(groups), 1):.0f} spans each)')

    thresholds = [0, 16 * 1024, 64 * 1024, 128 * 1024, 256 * 1024, 1024 * 1024]
    for name, key in (('reads (by source)', source_of), ('writes (by destination)', destination_of)):
        total, counts = transfers(groups, key, cluster, thresholds)
        print(f'\n  {name}: {total} transfers unmerged')
        print(f'    {"merge gaps up to":>18}  {"transfers":>10}  {"saved":>7}  {"extra read":>10}')
        for gap in thresholds:
            runs, waste = counts[gap]
            print(f'    {gap // 1024:>15} KB  {runs:>10}  {100 - runs * 100 // total:>6}%  '
                  f'{waste / 2**20:>7.0f} MB')


main()
