#!/usr/bin/env python3
"""Checks the claim: every object one extent, and free space one run at the end.

    python3 contiguity.py /dev/rdisk14s1
    python3 contiguity.py before.img            # for a contrast, on the pristine copy

`fatread.py` proves the *data* survived a run; this proves the run did what it was for. They are
different questions and a run can pass one while failing the other — a tool that copied everything
faithfully and laid it out no better would produce an identical fatread comparison.

Reports, per volume: how many objects there are, how many occupy more than one extent, how many runs
the free space falls into, and the highest cluster still in use. On a finished volume the last three
should be 0, 1, and roughly the number of clusters actually occupied.

Reuses `fatread.Volume` rather than decoding the table again — that part is already an independent
implementation of the format, and having two of it in this directory would only mean two places to
get FAT12's packed entries wrong.
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fatread import Volume, short_name, long_name, SKIP


def extents(chain):
    """How many separate runs a chain occupies. 1 is the goal; 0 means it is empty."""
    if not chain:
        return 0
    return 1 + sum(1 for i in range(1, len(chain)) if chain[i] != chain[i - 1] + 1)


def walk(volume, start, path, found):
    # `start` is None for a FAT12/16 root, which lives outside the cluster space and has no
    # first cluster — and, being fixed, is not something a run could have laid out anyway.
    blob = volume.root_bytes() if start is None else \
        b''.join(volume.cluster_bytes(c) for c in volume.chain(start))
    pending = []
    for i in range(0, len(blob) - 31, 32):
        entry = blob[i:i + 32]
        if entry[0] == 0x00:
            break
        if entry[0] == 0xE5:
            pending = []
            continue
        if entry[11] == 0x0F:
            pending.append(entry)
            continue
        if entry[11] & 0x08:
            pending = []
            continue

        name = long_name(pending) or short_name(entry)
        pending = []
        if name in ('.', '..') or name in SKIP:
            continue

        first = int.from_bytes(entry[20:22], 'little') << 16 | \
            int.from_bytes(entry[26:28], 'little')
        if first < 2:
            continue
        chain = volume.chain(first)
        runs = extents(chain)
        found['objects'] += 1
        if runs > 1:
            found['fragmented'].append((path + '/' + name, runs, len(chain)))
        if entry[11] & 0x10:
            walk(volume, first, path + '/' + name, found)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    volume = Volume(sys.argv[1])
    found = {'objects': 0, 'fragmented': []}
    walk(volume, volume.root, '', found)

    free = [c for c in range(2, len(volume.fat)) if volume.fat[c] == 0]
    used = [c for c in range(2, len(volume.fat)) if volume.fat[c] != 0]
    print(f'FAT{volume.bits}: {found["objects"]} objects, '
          f'{len(found["fragmented"])} fragmented, '
          f'free space in {extents(free)} run(s), '
          f'highest cluster in use {max(used) if used else 0} of {len(volume.fat) - 2}')
    for name, runs, clusters in found['fragmented'][:20]:
        print(f'    {runs} extents over {clusters} clusters: {name}')
    if len(found['fragmented']) > 20:
        print(f'    … and {len(found["fragmented"]) - 20} more')

    # Exit status, so this can gate something: a finished volume has no fragmented objects and its
    # free space in a single run.
    return 0 if not found['fragmented'] and extents(free) <= 1 else 1


if __name__ == '__main__':
    raise SystemExit(main())
