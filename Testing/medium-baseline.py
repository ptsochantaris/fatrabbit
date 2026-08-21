#!/usr/bin/env python3
"""Measures what a medium is capable of, before trying to explain a result on it.

    python3 medium-baseline.py /dev/rdisk14s1

Read-only: it never writes, so it is safe to point at anything, including a device holding
data. Use dd for the write figure, which does have to overwrite something:

    dd if=/tmp/some.img of=/dev/rdiskN bs=1m count=512

Two numbers come out, and between them they predict most of what a change to the copy path
can possibly achieve:

  sequential throughput   the ceiling. A copy that reads and writes the same bytes cannot
                          beat 1/(1/read + 1/write) one-way, and if the tool is already near
                          that, no amount of reordering will help — the medium is the limit.

  random access latency   the per-operation cost. Multiply it by the number of separate
                          transfers a run makes (fatrabbit reports its span count) and compare
                          against the run's total: that is the share of the time that is
                          waiting rather than transferring, and the most any batching or
                          sorting can win back.

For context, measured with this script: a 32 GB SD card gave 18.8 MB/s sequentially and 7.26 ms
per random access, while a 15-year-old USB 2.0 spinning drive gave 38.1 MB/s and 26.06 ms. The
drive is twice as fast sequentially and three and a half times worse per operation — which is
why the shape of the test volume, not the headline speed of the medium, decides the result.
"""

import random
import sys
import time

BLOCK = 4096
SAMPLES = 200
SEQUENTIAL_BYTES = 256 * 1024 * 1024


def device_size(handle):
    """Size in bytes.

    Seeking to the end reports 0 on a raw device node, so where that happens the end is
    probed for instead: double until a read fails, then bisect. Each probe is one block.
    """
    if handle.seek(0, 2):
        return handle.tell()

    def readable(offset):
        try:
            handle.seek(offset)
            return len(handle.read(BLOCK)) == BLOCK
        except OSError:
            return False

    low, high = 0, BLOCK
    while high < 1 << 50 and readable(high):
        low, high = high, high * 2
    while high - low > BLOCK:
        middle = (low + high) // 2 // BLOCK * BLOCK
        if readable(middle):
            low = middle
        else:
            high = middle
    return low + BLOCK


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    handle = open(path, 'rb')
    random.seed(7)

    # Sequential, from the start of the device.
    handle.seek(0)
    started = time.time()
    read = 0
    while read < SEQUENTIAL_BYTES:
        chunk = handle.read(1024 * 1024)
        if not chunk:
            break
        read += len(chunk)
    elapsed = time.time() - started
    print('sequential read:      %.1f MB/s (%d MiB in %.1fs)'
          % (read / elapsed / 1e6, read // (1024 * 1024), elapsed))

    # Random, scattered over as much of the device as it has. Spread matters: seeks within a
    # few hundred megabytes cost a fraction of a full-stroke seek, so a figure taken over a
    # small span flatters a spinning drive.
    span = device_size(handle)
    started = time.time()
    for _ in range(SAMPLES):
        handle.seek(random.randrange(span // BLOCK) * BLOCK)
        handle.read(BLOCK)
    elapsed = time.time() - started
    latency = elapsed / SAMPLES
    print('random %d KiB read:    %.2f ms each (%.0f IOPS, over %.0f GB)'
          % (BLOCK // 1024, latency * 1000, 1 / latency, span / 1e9))

    # The same reads without moving the head, to separate transfer from waiting.
    handle.seek(0)
    started = time.time()
    for _ in range(SAMPLES):
        handle.read(BLOCK)
    sequential_each = (time.time() - started) / SAMPLES
    print('same read, in order:  %.2f ms each -> seek penalty %.0fx'
          % (sequential_each * 1000, latency / sequential_each))


main()
