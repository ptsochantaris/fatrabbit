#!/usr/bin/env python3
"""Runs two builds over the same volume on real hardware and proves they agree, byte for byte.

    python3 ab-verify.py <snapshot.img> <device> <build-a> [build-b] [-- args...]

    python3 ab-verify.py spin.img /dev/rdisk14 ./fatrabbit-before ./fatrabbit-after

A buffered node given here is redirected to the raw one, because the tool redirects itself the same
way and everything has to go through one node — see `raw_node`.

For each build it restores the snapshot, checks the starting state really is the snapshot, runs the
build, captures the result, and compares. Then it compares the two results against each other. Any
difference is reported as byte ranges and as the clusters they fall in.

Why on a device rather than on an image, which would be minutes instead of an hour: the one real
corruption this project has seen did not reproduce on an image. Identical input, identical plan,
identical transfer log for the first fifteen thousand transfers — clean as a file, wrong on a card.
An image A/B would have passed it, twice, and did. If a change touches how bytes reach the medium,
the medium has to be in the loop.

It also answers a question a single run cannot: a build that is wrong in the same way every time
still verifies against itself. Two builds disagreeing is evidence; one build agreeing with its own
previous output is not.

Nothing here writes to anything except the device given, and it refuses to start if that device is
mounted.
"""

import hashlib
import os
import subprocess
import sys
import time


def run(*command, **kwargs):
    return subprocess.run(command, capture_output=True, text=True, **kwargs)


def raw_node(path):
    """The raw node for a device path. Everything here goes through it, because the tool does.

    Mix the two and the buffered node's cache answers with blocks the run never wrote, so the device
    is right and the reads are wrong. That produced four files of plausible-looking garbage and a very
    convincing false report of corruption in a change that turned out to be fine.
    """
    if path.startswith('/dev/disk'):
        return '/dev/rdisk' + path[len('/dev/disk'):]
    return path


def buffered_node(path):
    """The buffered name, which is the only one the mount table ever uses."""
    if path.startswith('/dev/rdisk'):
        return '/dev/disk' + path[len('/dev/rdisk'):]
    return path


def device_chunk(fd, ceiling=1 << 22):
    """The largest transfer to hand this device, which is not ours to choose.

    Both platforms publish a maximum and a USB card reader measured during development advertises
    131,072 bytes — a thirty-second of the four megabytes this file used to ask for. Exceeding it
    on that reader returns the right *length* of the wrong bytes, silently, which in a harness whose
    entire job is deciding whether two volumes agree is the worst possible failure: it would restore
    a snapshot wrongly, capture a volume wrongly, and then report with confidence.
    """
    try:
        import fcntl
        import struct
        if sys.platform == 'darwin':
            # DKIOCGETMAXBYTECOUNTREAD, _IOR('d', 70, uint64_t).
            request = 0x40000000 | ((8 & 0x1FFF) << 16) | (ord('d') << 8) | 70
            buf = bytearray(8)
            fcntl.ioctl(fd, request, buf, True)
            value = struct.unpack('<Q', bytes(buf))[0]
        else:
            buf = bytearray(4)                          # BLKSECTGET, in 512-byte sectors
            fcntl.ioctl(fd, 0x1267, buf, True)
            value = struct.unpack('<I', bytes(buf))[0] * 512
        return min(value, ceiling) if value else ceiling
    except Exception:
        return ceiling


def restore(snapshot, device):
    print(f'  restoring {snapshot} -> {device}…', flush=True)
    started = time.time()
    with open(snapshot, 'rb') as source, open(device, 'r+b') as target:
        step = device_chunk(target.fileno())
        while chunk := source.read(step):
            target.write(chunk)
        target.flush()
        os.fsync(target.fileno())
        try:
            import fcntl
            fcntl.ioctl(target.fileno(), 0x20006416)   # DKIOCSYNCHRONIZECACHE, _IO('d', 22)
        except OSError:
            pass
    print(f'    {time.time() - started:.0f}s', flush=True)


def capture(device, size, path):
    with open(device, 'rb') as source, open(path, 'wb') as target:
        step = device_chunk(source.fileno())
        left = size
        while left > 0:
            chunk = source.read(min(step, left))
            if not chunk:
                break
            target.write(chunk)
            left -= len(chunk)


def digest(path, size):
    total = hashlib.md5()
    with open(path, 'rb') as handle:
        left = size
        while left > 0 and (chunk := handle.read(min(1 << 22, left))):
            total.update(chunk)
            left -= len(chunk)
    return total.hexdigest()


def differences(a, b, cluster, data_start):
    """Byte ranges where two images disagree, and the clusters they land in."""
    runs = []
    with open(a, 'rb') as fa, open(b, 'rb') as fb:
        offset = 0
        while True:
            ca, cb = fa.read(1 << 22), fb.read(1 << 22)
            if not ca:
                break
            if ca != cb:
                for i in range(0, len(ca), 512):
                    if ca[i:i + 512] != cb[i:i + 512]:
                        start = offset + i
                        if runs and runs[-1][1] == start:
                            runs[-1][1] = start + 512
                        else:
                            runs.append([start, start + 512])
            offset += len(ca)
    return [(s, e, (s - data_start) // cluster + 2 if s >= data_start else None) for s, e in runs]


def geometry(snapshot):
    with open(snapshot, 'rb') as handle:
        boot = handle.read(512)
    bps = int.from_bytes(boot[11:13], 'little')
    spc = boot[13]
    reserved = int.from_bytes(boot[14:16], 'little')
    fats = boot[16]
    per_fat = int.from_bytes(boot[36:40], 'little')
    return spc * bps, (reserved + fats * per_fat) * bps


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    args = sys.argv[1:]
    extra = []
    if '--' in args:
        cut = args.index('--')
        args, extra = args[:cut], args[cut + 1:]
    snapshot, requested, builds = args[0], args[1], args[2:]
    device = raw_node(requested)
    if device != requested:
        print(f'using the raw node {device} rather than {requested}')

    mounted = run('diskutil', 'info', buffered_node(device)).stdout
    if 'Mounted:                   Yes' in mounted:
        raise SystemExit(f'{device} is mounted; unmount it first')

    size = os.path.getsize(snapshot)
    cluster, data_start = geometry(snapshot)
    reference = digest(snapshot, size)
    here = os.path.dirname(os.path.abspath(__file__))
    print(f'{snapshot}: {size >> 20} MB, {cluster >> 10} KB clusters, data at {data_start}')
    print(f'{len(builds)} build(s) over {device}\n')

    results = []
    for build in builds:
        print(f'{build}:')
        restore(snapshot, device)

        check = f'/tmp/ab-start-{os.getpid()}.img'
        capture(device, size, check)
        if digest(check, size) != reference:
            raise SystemExit('  the restore did not land — the starting states would differ')
        os.remove(check)
        print('    starting state verified identical to the snapshot', flush=True)

        started = time.time()
        finished = run(build, '--plain', device, *extra)
        print(f'    ran in {time.time() - started:.0f}s, exit {finished.returncode}', flush=True)
        if finished.returncode != 0:
            print(finished.stderr[-400:])

        out = f'/tmp/ab-{os.path.basename(build)}-{os.getpid()}.img'
        capture(device, size, out)
        listing = run(sys.executable, os.path.join(here, 'fatread.py'), device)
        checked = run('fsck_msdos', '-n', device)
        print(f'    {len(listing.stdout.splitlines())} files read back, '
              f'fsck {"clean" if checked.returncode == 0 else "COMPLAINS"}', flush=True)
        results.append((build, out, listing.stdout))

    print()
    first = results[0]
    for build, out, listing in results[1:]:
        same_bytes = digest(out, size) == digest(first[1], size)
        same_files = listing == first[2]
        print(f'{first[0]} vs {build}: bytes {"identical" if same_bytes else "DIFFER"}, '
              f'files {"identical" if same_files else "DIFFER"}')
        if not same_bytes:
            for start, end, cl in differences(first[1], out, cluster, data_start)[:20]:
                where = f'cluster {cl}' if cl else 'metadata'
                print(f'    {start:>12} .. {end:>12}  {(end - start) // 1024:>4} KB  {where}')


main()
