#!/usr/bin/env python3
"""Asks a device whether it is haunted, and how fast it is at each transfer size.

    sudo chmod o+rw /dev/rdiskNsM
    python3 haunt.py /dev/rdiskNsM [--speed]

DESTRUCTIVE. It writes over the region it tests.

By default it will only write to clusters the FAT says are free, and refuses outright if it cannot
find enough of them in one piece. That guard exists because the author of this file ran it against a
freshly restored 33 GB card to check its output formatting, and it wrote its test pattern over 400
live directories a third of the way into the volume. The docstring said DESTRUCTIVE at the time. A
warning that has to be read at the right moment is not a safeguard.

--anywhere disables the guard and writes wherever it likes, which is what you want on a scratch
device with no filesystem worth reading. There is no default that covers both cases, so the safe one
is the default.

## What it looks for

A USB card reader measured here states a maximum transfer of 131,072 bytes, twice over and
consistently: DKIOCGETMAXBYTECOUNTWRITE says 131,072 and DKIOCGETMAXBLOCKCOUNTWRITE says 256 against
a 512-byte block. Both are wrong. Given a particular pattern it performs a single 65,536-byte write
instead, carrying the *second* half of the payload and placing it at the *first* half's address. The
first half is never written anywhere, the second half's own destination is never touched, pwrite
returns 131,072, and no error appears at any level. A defragmenting run of 727,778 writes lost 338
clusters that way — well over a hundred files and one directory destroyed in silence, with a single
error an hour in.

The pattern, which is the whole discovery:

    two or more back-to-back transfers at the maximum size, contiguous on the medium
    a discontiguity of exactly half that size
    one more transfer at the maximum size    <- this is the one that goes astray

Reads are haunted by the same pattern, and worse. A 131,072-byte read after that run-up disagreed
with the same range read in 4 KiB pieces at 361 of 400 positions tried, against roughly three bad
writes in 107,801 for the write fault. That is why a bulk pass over a freshly restored card hashed
four files of 273,050 wrongly and hashed them correctly on a second attempt — and why a tool
verifying a card at 128 KiB is checking its own work with a broken ruler. One ceiling governs both
directions, so backing off fixes both, but they are reported separately because a device haunted only
on reads would pass a write-only test.

Every other gap is fine. Every smaller size is fine at every gap. Shaving blocks off the top does not
help: 130,560 fails exactly as 131,072 does, and only at 65,536 does it come good. So the boundary is
a hard 2**16 somewhere in the chain of card, controller, bridge and bus, and not an overflow of the
stated figure by a few bytes of command overhead.

Nothing else on the machine asks for that shape. A file copy through the filesystem writes
131,072-byte transfers to the same reader all day without losing a byte, because it never lays its
writes out as a long contiguous run punctuated by a half-size hole. A defragmenter does, necessarily:
it sorts a generation's spans by destination and writes them ascending. Which is why this took days
to find, and why it now takes a second.

## Why it works when random probing does not

The fault looks rare — three bad transfers in 107,801 of a real run — and a probe that merely writes
and reads back would pass and prove nothing. But that is the rate of the *pattern*, not the
reliability of the device: given the pattern it fails every single time, at the same addresses,
unaffected by buffer alignment. Provoke it deliberately and it is deterministic.

## --speed

Also times each size. On the reader above, throughput climbs monotonically to 65,536 and then falls
off a cliff — 18.9 MB/s of writes at 64 KiB against 13.6 at 128 — so the fastest size and the largest
safe size are the same size and the safe ceiling costs nothing. A size that is anomalously slow is
worth treating as a warning in its own right.
"""

import fcntl
import os
import struct
import sys
import time

BS = 512
MAGIC = b'fatrabbit-haunt-'
SYNCHRONIZE_CACHE = 0x2000_6416          # _IO('d', 22) from <sys/disk.h>
PRECEDING = 3                            # two is enough; three is what the original trace had
FLOOR = 4096


def stated_maximum(fd):
    """The transfer maxima the device publishes, smaller of the two directions."""
    best = None
    for number in (70, 71):              # DKIOCGETMAXBYTECOUNT{READ,WRITE}
        buf = bytearray(8)
        try:
            fcntl.ioctl(fd, 0x40000000 | (8 << 16) | (ord('d') << 8) | number, buf)
            value = struct.unpack('<Q', buf)[0]
            if value:
                best = value if best is None else min(best, value)
        except OSError:
            pass
    return best


def block(offset):
    """A 512-byte block that names the offset it belongs at, so a stray one reports itself."""
    tag = MAGIC + str(offset).encode().rjust(14, b'0') + b'-'
    return (tag * (BS // len(tag) + 1))[:BS]


def named_by(buf):
    if not buf.startswith(MAGIC):
        return None
    try:
        return int(buf[len(MAGIC):len(MAGIC) + 14])
    except ValueError:
        return None


def payload(offset, count):
    return b''.join(block(offset + i * BS) for i in range(count // BS))


def free_region(fd, wanted):
    """The longest run of free clusters, as (byte offset, byte length), or None if too small.

    Reads the FAT rather than trusting a guess. Only FAT32 is parsed here; anything else declines,
    which is the right answer for a tool that will otherwise overwrite whatever it lands on.
    """
    boot = os.pread(fd, 512, 0)
    sector = int.from_bytes(boot[11:13], 'little')
    per_cluster = boot[13]
    reserved = int.from_bytes(boot[14:16], 'little')
    copies = boot[16]
    spf = int.from_bytes(boot[36:40], 'little')
    total = int.from_bytes(boot[32:36], 'little')
    if not (sector and per_cluster and spf and total):
        return None
    cluster_bytes = sector * per_cluster
    data = (reserved + copies * spf) * sector
    count = (total - (reserved + copies * spf)) // per_cluster
    raw = b''
    while len(raw) < spf * sector:
        raw += os.pread(fd, min(65536, spf * sector - len(raw)), reserved * sector + len(raw))
    need = (wanted + cluster_bytes - 1) // cluster_bytes
    best = best_start = 0
    run = 0
    for cluster in range(2, count + 2):
        entry = int.from_bytes(raw[cluster * 4:cluster * 4 + 4], 'little') & 0x0FFFFFFF
        if entry == 0:
            run += 1
            if run > best:
                best, best_start = run, cluster - run + 1
        else:
            run = 0
    if best < need:
        return None
    return data + (best_start - 2) * cluster_bytes, best * cluster_bytes


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    device = sys.argv[1]
    speed = '--speed' in sys.argv
    anywhere = '--anywhere' in sys.argv

    fd = os.open(device, os.O_RDWR)
    boot = os.pread(fd, 512, 0)
    sector = int.from_bytes(boot[11:13], 'little') or 512
    total = int.from_bytes(boot[19:21], 'little') or int.from_bytes(boot[32:36], 'little')
    extent = sector * total if total else None
    stated = stated_maximum(fd) or (1 << 20)
    print(f'{device}: states a maximum transfer of {stated} bytes'
          + (f', extent {extent:,} bytes' if extent else ''))

    # Candidates: the stated maximum, halving. The boundary measured on real hardware sits on a power
    # of two, so halving finds it in one step and a finer search buys nothing.
    sizes = []
    size = stated
    while size >= FLOOR:
        if size % BS == 0:
            sizes.append(size)
        size //= 2

    # Somewhere to work. Free clusters only unless told otherwise, and enough of them in one piece
    # that every case fits without spilling into anything the filesystem refers to.
    #
    # The whole sweep needs about five times the largest candidate per case, times the number of
    # cases, plus the timing passes. Asked for generously and checked against the FAT, because the
    # alternative is what happened the first time: a pattern written across 400 live directories.
    wanted = len(sizes) * 5 * 6 * stated + (7 * (32 << 20) if speed else 0)
    if anywhere:
        cursor = (extent // 3) if extent else (1 << 30)
        print('  --anywhere: writing without regard for what the FAT says is in use')
    else:
        region = free_region(fd, wanted)
        if region is None:
            raise SystemExit(
                f'refusing to write: could not find {wanted:,} bytes of free clusters in one piece.\n'
                'This volume has no room to test in without destroying data. Either free some space,\n'
                'or pass --anywhere if the contents are expendable.')
        cursor, room = region
        print(f'  working in free space at offset {cursor:,} ({room:,} bytes, FAT says unused)')

    def haunt(size, gap):
        nonlocal cursor
        start = ((cursor + (1 << 20)) // size) * size
        cursor = start + (PRECEDING + 2) * size + gap + (1 << 20)
        target = start + PRECEDING * size + gap
        if extent and target + size > extent:
            return None
        # Poison first: a pass can then only mean the write actually landed, never a leftover.
        for at in range(0, size, min(65536, size)):
            os.pwrite(fd, payload(target + at + (8 << 30), min(65536, size - at)), target + at)
        os.fsync(fd)
        fcntl.ioctl(fd, SYNCHRONIZE_CACHE)
        for index in range(PRECEDING):
            os.pwrite(fd, payload(start + index * size, size), start + index * size)
        os.pwrite(fd, payload(target, size), target)
        os.fsync(fd)
        fcntl.ioctl(fd, SYNCHRONIZE_CACHE)
        got = b''
        while len(got) < size:
            got += os.pread(fd, min(65536, size - len(got)), target + len(got))
        wrong = []
        for i in range(0, size, BS):
            claimed = named_by(got[i:i + BS])
            if claimed != target + i:
                wrong.append((i, claimed, target + i))
        return wrong

    def reads_disagree(size, gap):
        """The same pattern in reads: does the medium answer one question two ways?

        No ground truth needed, which is the point — the range can hold anything. It is read once at
        the size under test after the same run-up, and once in small pieces that every sweep finds
        clean. A disagreement is the medium contradicting itself.
        """
        nonlocal cursor
        start = ((cursor + (1 << 20)) // size) * size
        cursor = start + (PRECEDING + 2) * size + gap + (1 << 20)
        target = start + PRECEDING * size + gap
        if extent and target + size > extent:
            return False
        for index in range(PRECEDING):
            os.pread(fd, size, start + index * size)
        whole = os.pread(fd, size, target)
        piecemeal = b''
        while len(piecemeal) < size:
            piecemeal += os.pread(fd, min(4096, size - len(piecemeal)), target + len(piecemeal))
        return whole != piecemeal[:len(whole)]

    print(f'\n{PRECEDING} contiguous transfers, a gap, then one more; every gap that matters\n')
    print(f'{"size":>9}  {"gaps":>5}  outcome')
    print('-' * 64)
    safe = {}
    for size in sizes:
        gaps = sorted({g for g in (size // 2, size // 4, size, size * 2, BS)
                       if g and g % BS == 0})
        failures = []
        for gap in gaps:
            wrong = haunt(size, gap)
            if wrong:
                i, claimed, expected = wrong[0]
                delta = None if claimed is None else claimed - expected
                failures.append((gap, f'{len(wrong)} blocks written wrong'
                                 + (f', displaced {delta:+d}' if delta is not None
                                    else ', content foreign')))
            # Both directions, independently. Reporting only the first to fail would hide half the
            # fault on a device broken in both, and this reader is broken in both — the read half
            # far more reproducibly than the write half.
            if reads_disagree(size, gap):
                failures.append((gap, 'read disagrees with the same range in 4096-byte pieces'))
        safe[size] = not failures
        if not failures:
            print(f'{size:>9}  {len(gaps):>5}  clean')
        else:
            detail = '; '.join(f'gap {gap}: {note}' for gap, note in failures)
            print(f'{size:>9}  {len(gaps):>5}  HAUNTED — {detail}')

    largest = next((s for s in sizes if safe[s]), None)
    print()
    if largest == sizes[0]:
        print(f'This medium handles its stated {stated} bytes correctly.')
    elif largest:
        print(f'Largest size this medium handles correctly: {largest} bytes '
              f'({largest * 100 // stated}% of what it claims).')
    else:
        print(f'This medium mishandles every size down to {FLOOR}. Do not write to it.')

    if speed:
        print(f'\nthroughput, 32 MiB per pass')
        print(f'{"size":>9}  {"write MB/s":>11}  {"read MB/s":>10}  safe')
        print('-' * 48)
        chunk = b'\xa5' * max(sizes)
        room = 32 << 20
        base = cursor + (1 << 20)
        for index, size in enumerate(sizes):
            at = base + index * room
            if extent and at + room > extent:
                print(f'{size:>9}  {"—":>11}  {"—":>10}  no room left')
                continue
            done = 0
            started = time.monotonic()
            while done < room:
                os.pwrite(fd, chunk[:size], at + done)
                done += size
            os.fsync(fd)
            fcntl.ioctl(fd, SYNCHRONIZE_CACHE)
            write = room / (time.monotonic() - started) / 1e6
            buf = bytearray(size)
            done = 0
            started = time.monotonic()
            while done < room:
                os.preadv(fd, [memoryview(buf)], at + done)
                done += size
            read = room / (time.monotonic() - started) / 1e6
            print(f'{size:>9}  {write:>11.1f}  {read:>10.1f}  '
                  f'{"yes" if safe[size] else "NO"}')

    os.close(fd)


if __name__ == '__main__':
    main()
