#!/usr/bin/env python3
"""Measures what a gap costs, which is what decides whether merging nearby transfers is worth it.

    python3 gap-cost.py /dev/rdisk14

A run moves tens of thousands of small pieces scattered over a volume. Two pieces separated by a
gap can be fetched either as two transfers, seeking over the gap, or as one transfer that reads
the gap and throws it away. Which is cheaper depends on the size of the gap and on the medium, and
guessing has already been wrong once here.

For each gap size this fetches the same wanted bytes both ways and reports both times, so the
crossover — the gap size at which reading through beats seeking over — comes out of the drive
rather than out of an estimate.

Read-only, and it uses a fresh region of the device for every measurement so that nothing is
answered out of a cache that the previous measurement filled.

Run it against the raw node, which is the only path a device run takes. There used to be a point in
running it against the buffered one too — if the two disagreed, the kernel was already merging and
there was nothing here to win, which is exactly what it reported. That is no longer a question worth
asking: nothing merges under us any more, so this curve is the whole story.

Discard the first row of a cold run. It pays for positioning and reads about twice what it settles
at; every row after that repeats to within a few percent.
"""

import os
import sys
import time

PIECE = 32 * 1024              # about the average span a run moves
PIECES = 200                   # per measurement
GAPS = [0, 16, 64, 128, 256, 512, 1024]


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    handle = open(path, 'rb', buffering=0)

    print(f'{path}: fetching {PIECES} pieces of {PIECE // 1024} KB, separately and merged')
    print(f'{"gap":>8}  {"separate":>10}  {"merged":>10}  {"per piece":>10}  verdict')

    cursor = 0
    for gap_kb in GAPS:
        gap = gap_kb * 1024
        stride = PIECE + gap
        span = PIECES * stride

        # Separate: one transfer per piece, seeking over each gap.
        base = cursor
        cursor += span
        started = time.monotonic()
        for index in range(PIECES):
            handle.seek(base + index * stride)
            handle.read(PIECE)
        separate = time.monotonic() - started

        # Merged: one transfer covering the lot, gaps read and discarded.
        base = cursor
        cursor += span
        started = time.monotonic()
        handle.seek(base)
        remaining = span
        while remaining > 0:
            chunk = handle.read(min(remaining, 1 << 20))
            if not chunk:
                break
            remaining -= len(chunk)
        merged = time.monotonic() - started

        better = 'merge' if merged < separate else 'seek'
        margin = abs(separate - merged) / max(separate, merged) * 100
        print(f'{gap_kb:>6} KB  {separate * 1000:>8.0f} ms  {merged * 1000:>8.0f} ms  '
              f'{separate / PIECES * 1000:>8.2f} ms  {better} wins by {margin:.0f}%')


main()
