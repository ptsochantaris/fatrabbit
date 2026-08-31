#!/usr/bin/env python3
"""Reads every file out of a FAT12, FAT16 or FAT32 volume by following the FAT directly.

Prints one "md5  path  size" line per file, sorted, so two volumes can be compared with
diff(1) without mounting either. That matters: the point is to check what fatrabbit wrote,
and going through the OS driver means checking fatrabbit and the driver together, against a
cache that may still hold what was there before. This reads the bytes.

    python3 fatread.py /dev/rdisk14s1 > after
    python3 fatread.py pristine.img   > before
    diff before after

Works on a device node or on an image file, including one truncated by dd to just the
region in use, as long as every file lives inside the part that was copied.

Reads are positioned (`os.pread`), looped until complete, and kept under whatever maximum the
device advertises. That is not fussiness: the previous one-line reader accepted a short read
without complaint, which truncated a directory parse and reported a directory of fifty files as
missing when it was present the whole time. A verifier that under-reports is worse than none.

**This is deliberately a second implementation of the format, and deliberately not in Swift.**
Its whole value is being independent of the tool it checks: a misunderstanding of FAT that
fatrabbit and this script shared would pass both, and sharing a language — never mind sharing
the actual types — is how that happens. So the decode below is written from the format rather
than from the Swift, and the variant detection is arrived at the same way for the same reason.

Directories macOS rewrites on every mount are skipped, or the comparison fails for reasons
that have nothing to do with the volume: .fseventsd gets a fresh UUID and new log files
each time, and Spotlight rebuilds its index.
"""

import os
import sys
import hashlib

SKIP = ('.fseventsd', '.Spotlight-V100', '.Spotlight-V200', '.Trashes', '.TemporaryItems')

# Byte offsets of the 13 UCS-2 characters carried by one long-name entry.
LFN_OFFSETS = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]


def device_limit(fd):
    """The largest transfer this device says it will accept, or None where it will not say.

    The same question fatrabbit asks, for the same reason, and this file has to ask it
    independently or it is not an independent check. A USB card reader measured during
    development advertises 131,072 bytes and answers a larger request with the right *length* of
    the wrong bytes; a verifier that exceeded that would report corruption that is not there, or
    miss corruption that is.
    """
    try:
        import fcntl
        import struct
        if sys.platform == 'darwin':
            # DKIOCGETMAXBYTECOUNTREAD, _IOR('d', 70, uint64_t), written out because it is a macro.
            request = 0x40000000 | ((8 & 0x1FFF) << 16) | (ord('d') << 8) | 70
            buf = bytearray(8)
            fcntl.ioctl(fd, request, buf, True)
            value = struct.unpack('<Q', bytes(buf))[0]
        else:
            # BLKSECTGET, in 512-byte sectors, and a short on older kernels.
            buf = bytearray(4)
            fcntl.ioctl(fd, 0x1267, buf, True)
            value = struct.unpack('<I', bytes(buf))[0] * 512
        return value or None
    except Exception:
        return None


class Volume:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDONLY)
        # A ceiling of a megabyte, lowered to whatever the device asks for. A plain image file
        # declines to answer and keeps the ceiling.
        stated = device_limit(self.fd)
        self.chunk = min(stated, 1 << 20) if stated else 1 << 20
        boot = self.read_at(0, 512)
        self.bps = int.from_bytes(boot[11:13], 'little')
        spc = boot[13]
        reserved = int.from_bytes(boot[14:16], 'little')
        fats = boot[16]

        # Only the fields common to all three variants, because which variant this is has to be
        # settled before anything past offset 36 can be read as geometry: on FAT12/16 those bytes
        # are the drive number, the boot signature and the volume ID.
        root_entries = int.from_bytes(boot[17:19], 'little')
        fat16_size = int.from_bytes(boot[22:24], 'little')
        sectors_per_fat = fat16_size or int.from_bytes(boot[36:40], 'little')
        total16 = int.from_bytes(boot[19:21], 'little')
        total = total16 or int.from_bytes(boot[32:36], 'little')
        if self.bps == 0 or spc == 0 or sectors_per_fat == 0 or total == 0:
            raise SystemExit(f'{path}: does not look like a FAT volume')

        self.cluster_size = spc * self.bps
        # The fixed root sits between the last table and the first data cluster, and is zero-length
        # on FAT32 where the root is a chain.
        root_sectors = (root_entries * 32 + self.bps - 1) // self.bps
        first_data = reserved + fats * sectors_per_fat + root_sectors
        clusters = (total - first_data) // spc

        # The definition: the variant follows from the cluster count and from nothing else. Not from
        # the filesystem-type string in the boot record, which is a comment and is often wrong.
        self.bits = 12 if clusters < 4085 else (16 if clusters < 65525 else 32)
        self.data = first_data * self.bps

        raw = self.read_at(reserved * self.bps, sectors_per_fat * self.bps)
        self.fat = [self.decode(raw, c) for c in range(clusters + 2)]

        if self.bits == 32:
            self.root = int.from_bytes(boot[44:48], 'little')
            self.root_region = None
        else:
            # No cluster to start from: the root is a flat run at a known offset.
            self.root = None
            self.root_region = ((reserved + fats * sectors_per_fat) * self.bps, root_entries * 32)

    def decode(self, raw, cluster):
        """One table entry, at whichever of the three widths this volume uses."""
        if self.bits == 12:
            at = cluster + cluster // 2          # three halves of a byte each
            pair = int.from_bytes(raw[at:at + 2], 'little')
            # An even cluster takes the low twelve bits of the pair, an odd one the high twelve.
            return (pair if cluster % 2 == 0 else pair >> 4) & 0xFFF
        if self.bits == 16:
            return int.from_bytes(raw[cluster * 2:cluster * 2 + 2], 'little')
        return int.from_bytes(raw[cluster * 4:cluster * 4 + 4], 'little') & 0x0FFFFFFF

    @property
    def bad(self):
        """The lowest reserved value, which is where a chain stops being cluster numbers."""
        return {12: 0xFF7, 16: 0xFFF7, 32: 0x0FFFFFF7}[self.bits]

    def read_at(self, offset, count):
        """Exactly `count` bytes at `offset`, or an error saying why not.

        Three things this deliberately does, each of which the previous one-line version did not,
        and each of which produced a wrong answer on a real card:

        **A short read is not silently accepted.** `file.read(n)` on a raw device may hand back
        fewer than `n` bytes, and returning that truncated buffer made a directory parse simply
        stop early — every entry past the truncation point vanished, and the volume looked as
        though it had lost a directory of fifty files that was in fact there the whole time. A
        verifier that under-reports files is worse than no verifier.

        **`os.pread` rather than seek-and-read.** A positioned read carries its own offset, so
        there is no shared file position to be wrong about. A buffered handle seeking around a
        33 GB device across hundreds of thousands of reads was separately observed returning wrong
        bytes, which is how a confident report of 1,396 broken directories came to be written about
        a volume that had none.

        **Requests are kept under what the device accepts.** See `device_limit`.
        """
        out = bytearray(count)
        done = 0
        while done < count:
            want = min(self.chunk, count - done)
            got = os.preadv(self.fd, [memoryview(out)[done:done + want]], offset + done)
            if not got:
                raise SystemExit(f'short read at offset {offset}: wanted {count} bytes, '
                                 f'got {done} before the device stopped answering')
            done += got
        return bytes(out)

    def chain(self, start):
        out, cluster, seen = [], start, set()
        while 2 <= cluster < self.bad and cluster < len(self.fat):
            if cluster in seen:                      # a loop, on a damaged volume
                break
            seen.add(cluster)
            out.append(cluster)
            cluster = self.fat[cluster]
        return out

    def root_bytes(self):
        """The root directory's entries, however this volume happens to keep them."""
        if self.root_region:
            return self.read_at(*self.root_region)
        return b''.join(self.cluster_bytes(c) for c in self.chain(self.root))

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
    # `start` is None for a FAT12/16 root, which has no first cluster to follow.
    blob = volume.root_bytes() if start is None else \
        b''.join(volume.cluster_bytes(c) for c in volume.chain(start))
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
    print(f'# FAT{volume.bits}, {len(files)} files', file=sys.stderr)


# Guarded so the decode above can be imported and reused — a contiguity check wants the same
# `Volume`, and should not have to re-derive the format to get it.
if __name__ == '__main__':
    main()
