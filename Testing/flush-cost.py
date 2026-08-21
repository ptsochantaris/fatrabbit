#!/usr/bin/env python3
"""Is a durability barrier priced per call, or per dirty byte?

Writes a fixed amount, then commits it either in one barrier or in several, timing only the
barriers. A flat per-barrier column means barrier count is not a lever; a falling one would mean
it is.

    python3 flush-cost.py /dev/rdisk14

On the raw node the answer is 0.00s at every size and every split: the writes reached the platter as
they were issued, so a barrier has nothing left to ask for. Buffered it reads 0.02s per call, also
flat — which is how a phase table's "barriers 1m 3s (13%)" was shown to be write-back charged to the
flush rather than any cost of flushing.

DESTROYS the contents of the device given. Point it at a disposable one.
"""

import fcntl
import os
import sys
import time

# DKIOCSYNCHRONIZECACHE, _IO('d', 22) from <sys/disk.h>. fsync alone gets the data out of the
# kernel; this is what makes the drive commit its own cache. Both are needed for a real barrier.
DKIOCSYNCHRONIZECACHE = 0x20006416

BASE = 64 << 20      # clear of the boot record and both FATs
CHUNK = 64 << 10

device = sys.argv[1] if len(sys.argv) > 1 else sys.exit(__doc__)
fd = os.open(device, os.O_RDWR)
payload = b"\xa5" * CHUNK


def barrier():
    os.fsync(fd)
    fcntl.ioctl(fd, DKIOCSYNCHRONIZECACHE)


def trial(megabytes, splits):
    """Write `megabytes` scattered, committing in `splits` barriers. Returns seconds in barriers."""
    per = megabytes * (1 << 20) // CHUNK // splits
    barrier()
    spent = 0.0
    for split in range(splits):
        for i in range(per):
            # Strided rather than sequential, so the dirty pages are as scattered as a run's are.
            os.pwrite(fd, payload, BASE + (split * per + i) * 3 * CHUNK)
        started = time.monotonic()
        barrier()
        spent += time.monotonic() - started
    return spent


print(f"{device}: barriers timed in isolation, writes excluded\n")
print(f"{'dirty data':>12}{'barriers':>10}{'total':>10}{'per barrier':>14}")
for megabytes, splits in [(32, 1), (32, 2), (32, 4), (32, 8), (32, 16), (64, 1), (128, 1)]:
    spent = trial(megabytes, splits)
    print(f"{megabytes:>9} MB{splits:>10}{spent:>9.2f}s{spent / splits:>13.2f}s")
os.close(fd)

print("\nFlat per-barrier column, and a total that scales with the split count rather than with\n"
      "the data, means the call itself is all you are measuring. Multiply it by the barrier count\n"
      "a run reports: that product is the entire prize for reducing generations.")
