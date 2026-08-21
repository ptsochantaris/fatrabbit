#!/usr/bin/env python3
"""Reads every file out of a FAT32 volume by following the FAT directly.

Prints one "md5  path  size" line per file, sorted, so two volumes can be compared with
diff(1) without mounting either. That matters: the point is to check what fatrabbit wrote,
and going through the OS driver means checking fatrabbit and the driver together, against a
cache that may still hold what was there before. This reads the bytes.

    python3 fatread.py /dev/rdisk14s1 > after
    python3 fatread.py pristine.img   > before
    diff before after

Works on a device node or on an image file, including one truncated by dd to just the
region in use, as long as every file lives inside the part that was copied.

Directories macOS rewrites on every mount are skipped, or the comparison fails for reasons
that have nothing to do with the volume: .fseventsd gets a fresh UUID and new log files
each time, and Spotlight rebuilds its index.
"""

import sys
import hashlib

SKIP = ('.fseventsd', '.Spotlight-V100', '.Spotlight-V200', '.Trashes', '.TemporaryItems')

# Byte offsets of the 13 UCS-2 characters carried by one long-name entry.
LFN_OFFSETS = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]


class Volume:
    def __init__(self, path):
        self.f = open(path, 'rb')
        boot = self.read_at(0, 512)
        self.bps = int.from_bytes(boot[11:13], 'little')
        spc = boot[13]
        reserved = int.from_bytes(boot[14:16], 'little')
        fats = boot[16]
        sectors_per_fat = int.from_bytes(boot[36:40], 'little')
        self.root = int.from_bytes(boot[44:48], 'little')
        if self.bps == 0 or spc == 0 or sectors_per_fat == 0:
            raise SystemExit(f'{path}: does not look like FAT32')

        self.cluster_size = spc * self.bps
        self.data = (reserved + fats * sectors_per_fat) * self.bps
        raw = self.read_at(reserved * self.bps, sectors_per_fat * self.bps)
        self.fat = [int.from_bytes(raw[i:i + 4], 'little') & 0x0FFFFFFF
                    for i in range(0, len(raw), 4)]

    def read_at(self, offset, count):
        self.f.seek(offset)
        return self.f.read(count)

    def chain(self, start):
        out, cluster, seen = [], start, set()
        while 2 <= cluster < 0x0FFFFFF7 and cluster < len(self.fat):
            if cluster in seen:                      # a loop, on a damaged volume
                break
            seen.add(cluster)
            out.append(cluster)
            cluster = self.fat[cluster]
        return out

    def cluster_bytes(self, number):
        return self.read_at(self.data + (number - 2) * self.cluster_size, self.cluster_size)

    def contents(self, start, size):
        out = b''
        for cluster in self.chain(start):
            out += self.cluster_bytes(cluster)
            if len(out) >= size:
                break
        return out[:size]


def short_name(entry):
    base = entry[0:8].decode('latin-1').rstrip()
    ext = entry[8:11].decode('latin-1').rstrip()
    return base + ('.' + ext if ext else '')


def decode(units):
    """UTF-16 code units to text, surviving whatever is actually on the disk.

    A damaged volume has names that are not names, and this has to report them rather than die on
    them: a comparison tool that stops at the first bad entry cannot tell you how much is bad.
    """
    raw = b''.join(unit.to_bytes(2, 'little') for unit in units)
    return raw.decode('utf-16-le', errors='replace')


def long_name(entries):
    """Reassembles a long name. The chunks precede their short entry in reverse order."""
    units = []
    for entry in reversed(entries):
        for offset in LFN_OFFSETS:
            unit = int.from_bytes(entry[offset:offset + 2], 'little')
            if unit in (0x0000, 0xFFFF):
                return decode(units)
            units.append(unit)
    return decode(units)


def walk(volume, start, path, out):
    blob = b''.join(volume.cluster_bytes(c) for c in volume.chain(start))
    pending = []
    for i in range(0, len(blob) - 31, 32):
        entry = blob[i:i + 32]
        if entry[0] == 0x00:                          # end of directory
            break
        if entry[0] == 0xE5:                          # deleted
            pending = []
            continue
        if entry[11] == 0x0F:                         # long-name component
            pending.append(entry)
            continue
        if entry[11] & 0x08:                          # volume label
            pending = []
            continue

        name = long_name(pending) or short_name(entry)
        pending = []
        if name in ('.', '..') or name in SKIP:
            continue

        first = int.from_bytes(entry[20:22], 'little') << 16 | int.from_bytes(entry[26:28], 'little')
        size = int.from_bytes(entry[28:32], 'little')
        if entry[11] & 0x10:
            if first >= 2:
                walk(volume, first, path + '/' + name, out)
        else:
            digest = hashlib.md5(volume.contents(first, size)).hexdigest() if first >= 2 else 'empty'
            out.append(f'{digest}  {path}/{name}  {size}')


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    volume = Volume(sys.argv[1])
    files = []
    walk(volume, volume.root, '', files)
    files.sort()
    print('\n'.join(files))
    print(f'# {len(files)} files', file=sys.stderr)


main()
