#!/usr/bin/env python3
"""Builds a fragmented FAT32 volume to measure against.

    python3 make-test-volume.py /Volumes/CARDTEST [small|mixed|hollow] [scale]

The profile is the whole point, and getting it wrong invalidates the measurement:

  small   thousands of files of one to three clusters, and nothing else. This is the shape
          of the volumes this tool exists for — a Spectrum Next card holds a quarter of a
          million files averaging 66 KiB — and it is the shape in which per-operation costs
          dominate. Anything to do with seeks, cache flushes, read/write alternation or
          block read-modify-writes shows up here and nowhere else.

  mixed   a few files of tens of megabytes alongside the small ones. Copy throughput here
          is bandwidth-bound, so it measures the medium rather than the tool, and reports
          "no difference" for changes that are in fact worth 13% on a real card. Useful
          only as a control, or for exercising the paths that large spans take.

  hollow  the same small files, filled to the brim and then emptied out from the bottom.
          This is the only profile here aimed at the *schedule* rather than at the copy
          path, and it produces the one shape the other two cannot: a first generation
          holding nearly all the work. The compacted layout packs from cluster 2 upwards,
          so a volume whose free space sits below its data has almost every home clear
          before anything moves — measured at 33,509 of 37,264 moves in generation one and
          3,345 in the next. `small` peels gently by comparison, 12% in the first and a
          long taper, and will report "no difference" for anything to do with generation
          size. Every tenth of the emptied directories is left behind, because a volume
          with no blockers at all schedules as a single generation and has no tail to be
          wrong about.

`scale` multiplies the file counts; 1 gives roughly 190 MB, which is a couple of minutes
of defragmenting on a slow card. `hollow` ignores it and fills whatever it is given.

Writes through the mounted filesystem, so it needs no privileges — the volume it targets
should be mounted, and unmounted again before fatrabbit is pointed at the device.
"""

import os
import random
import shutil
import sys

CLUSTER = 16 * 1024


def build_hollow(root):
    """Fill heavily, then free the low region, so almost every home is clear from the start."""
    random.seed(1)
    blob = bytes(random.getrandbits(8) for _ in range(3 * CLUSTER))
    dirs, per, keep_every, emptied = 3000, 26, 10, 0.6

    print(f'wave 1: {dirs * per} files across {dirs} directories, filling the volume')
    for d in range(dirs):
        os.makedirs(f'{root}/t{d}', exist_ok=True)
        for i in range(per):
            with open(f'{root}/t{d}/f{i}.bin', 'wb') as f:
                f.write(blob[:random.choice([1, 1, 2]) * CLUSTER - random.randint(0, 4000)])

    # The earliest directories were allocated the lowest clusters, so removing them frees the
    # bottom of the volume — which is exactly where the compacted layout wants to put
    # everything. What survives sits above where it is going to end up.
    gone = int(dirs * emptied)
    print(f'wave 2: empty the low {gone} directories, keeping every {keep_every}th as a blocker')
    for d in range(gone):
        if d % keep_every:
            shutil.rmtree(f'{root}/t{d}')
    print(f'{sum(len(files) for _, _, files in os.walk(root))} files remain')


def build(root, profile, scale):
    random.seed(1)                        # the same volume every time, for comparable runs
    blob = bytes(random.getrandbits(8) for _ in range(3 * CLUSTER))

    def write(path, clusters):
        # Not a whole number of clusters: real files end mid-cluster, and a size that always
        # landed on a boundary would hide any off-by-one in the last one.
        with open(path, 'wb') as f:
            f.write(blob[:clusters * CLUSTER - random.randint(0, 4000)])

    dirs = 200 * scale
    print(f'wave 1: {dirs * 20} small files across {dirs} directories')
    for d in range(dirs):
        os.makedirs(f'{root}/t{d}', exist_ok=True)
        for i in range(20):
            write(f'{root}/t{d}/f{i}.bin', random.choice([1, 1, 2, 3]))

    if profile == 'mixed':
        print('wave 1b: large files')
        os.makedirs(f'{root}/large', exist_ok=True)
        for i in range(12 * scale):
            with open(f'{root}/large/l{i}.bin', 'wb') as f:
                for _ in range(40):
                    f.write(blob[:CLUSTER * 3])

    # Deleting every other file and writing new ones over the holes is what leaves the
    # survivors in pieces; a volume written once is contiguous and has nothing to defragment.
    print('wave 2: punch holes')
    for d in range(dirs):
        for i in range(0, 20, 2):
            os.remove(f'{root}/t{d}/f{i}.bin')
    if profile == 'mixed':
        for i in range(0, 12 * scale, 3):
            os.remove(f'{root}/large/l{i}.bin')

    print('wave 3: refill')
    for d in range(dirs):
        for i in range(0, 20, 2):
            write(f'{root}/t{d}/f{i}.bin', random.choice([2, 3, 3]))

    print('wave 4: a second layer over the top')
    for d in range(dirs, dirs + 100 * scale):
        os.makedirs(f'{root}/t{d}', exist_ok=True)
        for i in range(20):
            write(f'{root}/t{d}/f{i}.bin', random.choice([1, 2]))

    total = sum(len(files) for _, _, files in os.walk(root))
    print(f'{total} files')


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    root = sys.argv[1]
    profile = sys.argv[2] if len(sys.argv) > 2 else 'small'
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    if profile not in ('small', 'mixed', 'hollow'):
        raise SystemExit(__doc__)
    if not os.path.isdir(root):
        raise SystemExit(f'{root}: not a mounted volume')
    if profile == 'hollow':
        build_hollow(root)
    else:
        build(root, profile, scale)


main()
