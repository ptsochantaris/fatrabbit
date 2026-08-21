#!/usr/bin/env python3
"""Does this device overlap concurrent reads, or does it serve them one at a time?

Worth knowing before writing any concurrency into the tool. A drive with a command queue
answers several outstanding requests per rotation; a USB mass-storage bridge speaking BOT
carries exactly one command at a time, so threads buy nothing at all and the only lever left
is issuing fewer, larger requests.

The pattern is the one a directory scan makes: single-cluster reads, ascending, evenly spaced,
which is what a FAT32 tree walk looks like once its natural order is left alone. Read-only.

    python3 queue-depth.py /dev/rdisk14
    python3 queue-depth.py /dev/rdisk22s1 --reads 4000 --stride 43
"""

import argparse
import os
import struct
import time
from concurrent.futures import ThreadPoolExecutor

parser = argparse.ArgumentParser()
parser.add_argument("device", help="FAT32 device node or image, opened read-only")
parser.add_argument("--reads", type=int, default=2000, help="how many reads per trial")
parser.add_argument("--stride", type=int, default=43,
                    help="clusters between reads; 43 is the median a scan sees on a test volume")
parser.add_argument("--depths", default="1,2,4,8,16,32", help="queue depths to try")
args = parser.parse_args()

fd = os.open(args.device, os.O_RDONLY)
boot = os.pread(fd, 512, 0)
bytes_per_sector = struct.unpack_from("<H", boot, 11)[0]
reserved = struct.unpack_from("<H", boot, 14)[0]
sectors_per_fat = struct.unpack_from("<I", boot, 36)[0]
first_data = (reserved + boot[16] * sectors_per_fat) * bytes_per_sector
cluster = bytes_per_sector * boot[13]

offsets = [first_data + c * args.stride * cluster for c in range(args.reads)]
span = (offsets[-1] - offsets[0]) / 2 ** 20
print(f"{args.device}: {len(offsets):,} reads of {cluster // 1024} KiB, "
      f"{args.stride} clusters apart, across {span:,.0f} MiB\n")
print(f"{'queue depth':>12}{'elapsed':>10}{'per read':>11}{'speedup':>10}")

read = lambda offset: os.pread(fd, cluster, offset)
baseline = None
for depth in [int(d) for d in args.depths.split(",")]:
    started = time.monotonic()
    if depth == 1:
        for offset in offsets:
            read(offset)
    else:
        with ThreadPoolExecutor(depth) as pool:
            list(pool.map(read, offsets))
    elapsed = time.monotonic() - started
    baseline = baseline or elapsed
    print(f"{depth:>12}{elapsed:>9.2f}s{elapsed * 1000 / len(offsets):>9.2f}ms"
          f"{baseline / elapsed:>9.2f}x")
os.close(fd)

print("\nFlat to within noise means the device serialises: no amount of concurrency above it "
      "will help.\nA rising column means outstanding requests are worth having, and the depth "
      "it stops rising at\nis the queue the device actually keeps.")
