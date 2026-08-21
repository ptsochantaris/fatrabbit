#!/usr/bin/env python3
"""How much of each directory cluster the scan actually needs, and what a smaller read costs.

    python3 dir-density.py /dev/rdisk33s1 [sample-reads]

Read-only throughout — os.open(O_RDONLY) and os.pread, nothing else — so it is safe to point at
a device holding data you care about.

This exists because the scan's cost was assumed to be its *seeks* and turned out to be its
*bytes*. A directory's entries are packed from the front and closed by an entry whose first byte
is 0x00; the parser stops there, so everything past that byte is transferred and discarded. On a
32 GB card of 273,035 files the discarded share was 93.4%.

Two phases, and they answer different halves of the question:

  phase A   walks the tree exactly as the scan does — depth first, following the FAT — and
            records where each directory's terminator falls. That gives the share of every read
            that is live, and how many directories a probe of a given size would finish.

  phase B   replays the scan's real offsets in the scan's real order at a range of read sizes.
            This is the half that cannot be modelled: it finds the per-command floor, below
            which a smaller read costs exactly the same and there is nothing left to win. The
            16 KiB trial runs first and last, so drift or a warm cache in the device shows up
            as the two disagreeing rather than as a fake speedup.

Read phase B before believing phase A. A medium whose floor is at the cluster size gains nothing
here however sparse its directories are, and that is the spinning drive: 4.5% of its reads were
live, and its curve is flat to within 1% from 512 B to 16 KiB because a read is a rotation and the
payload is lost inside it. The card, whose floor is at 4 KiB, gave 1.82x on the same change. Phase
A finds the waste; only phase B says whether anyone is charging for it.
"""

import os
import struct
import sys
import time

if len(sys.argv) < 2:
    raise SystemExit(__doc__)

path = sys.argv[1]
SAMPLE = int(sys.argv[2]) if len(sys.argv) > 2 else 8000

fd = os.open(path, os.O_RDONLY)
boot = os.pread(fd, 512, 0)
bytes_per_sector = struct.unpack_from('<H', boot, 11)[0]
sectors_per_cluster = boot[13]
reserved = struct.unpack_from('<H', boot, 14)[0]
fats = boot[16]
sectors_per_fat = struct.unpack_from('<I', boot, 36)[0]
root = struct.unpack_from('<I', boot, 44)[0]
if not (bytes_per_sector and sectors_per_cluster and sectors_per_fat):
    raise SystemExit(f'{path}: does not look like FAT32')

cluster_size = sectors_per_cluster * bytes_per_sector
data = (reserved + fats * sectors_per_fat) * bytes_per_sector

raw = os.pread(fd, sectors_per_fat * bytes_per_sector, reserved * bytes_per_sector)
fat = [int.from_bytes(raw[i:i + 4], 'little') & 0x0FFFFFFF for i in range(0, len(raw), 4)]
print(f'{path}: {cluster_size // 1024} KiB clusters, {len(fat):,} FAT entries')

ENTRY = 32


def chain(start):
    out, cluster, seen = [], start, set()
    while 2 <= cluster < 0x0FFFFFF7 and cluster < len(fat) and cluster not in seen:
        seen.add(cluster)
        out.append(cluster)
        cluster = fat[cluster]
    return out


def offset_of(cluster):
    return data + (cluster - 2) * cluster_size


# ---- Phase A: what the scan reads, and how much of it is live ------------------------------

dirs = []          # (clusters in chain, live bytes)
order = []         # every directory cluster offset, in the order the scan asks for it
stack = [root]
walked = 0

while stack:
    clusters = chain(stack.pop())
    if not clusters:
        continue
    blob = b''.join(os.pread(fd, cluster_size, offset_of(c)) for c in clusters)
    order.extend(offset_of(c) for c in clusters)

    live = len(blob)
    children = []
    for i in range(0, len(blob) - ENTRY + 1, ENTRY):
        first = blob[i]
        if first == 0x00:                       # end of directory: the parser stops here
            live = i
            break
        if first == 0xE5:                       # deleted
            continue
        attr = blob[i + 11]
        if attr == 0x0F or attr & 0x08:         # long-name component, or the volume label
            continue
        if first == 0x2E:                       # "." and ".."
            continue
        if attr & 0x10:
            child = (struct.unpack_from('<H', blob, i + 20)[0] << 16) \
                | struct.unpack_from('<H', blob, i + 26)[0]
            if child >= 2:
                children.append(child)

    dirs.append((len(clusters), live))
    stack.extend(reversed(children))
    walked += 1
    if walked % 5000 == 0:
        print(f'  {walked:,} directories…', flush=True)

read_bytes_now = len(order) * cluster_size
live_total = sum(live for _, live in dirs)
print(f'\n{len(dirs):,} directories, {len(order):,} directory clusters read '
      f'({read_bytes_now / 2**20:,.0f} MiB)')
print(f'live entry bytes: {live_total / 2**20:,.1f} MiB '
      f'({live_total * 100 / read_bytes_now:.1f}% of what is read)')

print(f'\n{"probe":>8}  {"dirs it finishes":>17}  {"bytes read":>12}  {"second reads":>13}')
for probe in (512, 1024, 2048, 4096, 8192, cluster_size):
    if probe > cluster_size:
        break
    # A directory whose terminator falls outside the probe needs the rest of its chain, which
    # the scan takes in one further transfer.
    covered = sum(1 for _, live in dirs if live < probe)
    total = sum(probe if live < probe else clusters * cluster_size
                for clusters, live in dirs)
    print(f'{probe:>7}B  {covered * 100 / len(dirs):>16.1f}%  '
          f'{total / 2**20:>9,.0f} MiB  {len(dirs) - covered:>13,}')

# ---- Phase B: what the medium charges for those reads --------------------------------------

sample = order[:SAMPLE]
sizes = [s for s in (cluster_size, 8192, 4096, 2048, 1024, 512) if s <= cluster_size]
print(f'\nreplaying the first {len(sample):,} directory reads at each size')
print(f'{"read size":>10}  {"elapsed":>9}  {"per read":>10}  {"vs cluster":>11}')

baseline = None
for size in sizes + [cluster_size]:
    started = time.monotonic()
    for at in sample:
        os.pread(fd, size, at)
    took = time.monotonic() - started
    if baseline is None:
        baseline = took
    label = f'{size // 1024} KiB' if size >= 1024 else f'{size} B'
    print(f'{label:>10}  {took:>7.2f}s  {took * 1000 / len(sample):>8.3f}ms  '
          f'{baseline / took:>10.2f}x', flush=True)

os.close(fd)
