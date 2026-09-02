#!/bin/bash
#
# Captures a paired trail of images and traces across a sequence of runs on a physical card.
#
# Why a trail rather than a single run. A card produced 177 damaged files twice over, while every
# other test came back clean: the reader put 190,000 large transfers exactly where it was told, and
# an image matching the card in extent, cluster size, fill level and contents moved 388,624 objects
# with all 273,092 files byte-identical. So the difference is somewhere in the sequence — a fresh
# copy, a first shuffle, then the root deletions that force a cascade — and the only way to find
# which step introduces it is to hold every step's before and after side by side.
#
# Each run is traced beneath the tool by pwrite-trace.c, which records the offset handed to every
# pwrite with a hash of each cluster it carries. Paired with the image taken afterwards, that is
# write verification performed from outside: the log says where the bytes were sent, the image says
# where they landed, and any disagreement names the call. Nothing in the tool changes, so the
# configuration under test stays exactly the binary that failed.
#
#   ./card-session.sh build
#   ./card-session.sh image  <dir> 00-fresh          # after formatting and copying the contents in
#   ./card-session.sh run    <dir> 01-first-shuffle  # a traced defragment
#   ./card-session.sh image  <dir> 01-first-shuffle  # the paired after-image
#   ...delete a couple of root directories, then run/image again...
#
# Four things this enforces, each of which has already cost a day of somebody's time:
#
#   Never mount the card after a run. macOS mounts FAT32 through FSKit and runs its check in
#   process, with no fsck to see in Activity Monitor; on a damaged volume it repairs, and a repair
#   destroys the evidence. Images are taken from the unmounted raw node. Mount only to build the
#   fresh copy in the first place.
#
#   Never read the card in transfers larger than it accepts. `dd bs=1m` against a reader that states
#   131,072 returns the right length of the wrong bytes with no error at any level — the fault that
#   started all of this. The block size here is taken from the device and halved.
#
#   Never run under sudo. DYLD_INSERT_LIBRARIES is stripped for root and setuid processes, so the
#   trace would be silently empty and the hour wasted. Chmod the node once and run as yourself.
#
#   Never write anything to the card that is not the run itself. Images and logs go to <dir>.
#
set -euo pipefail

DEV=${FR_DEV:-}
HERE=$(cd "$(dirname "$0")" && pwd)
DYLIB="$HERE/libpwrite-trace.dylib"

die() { echo "error: $*" >&2; exit 1; }

# The device's stated maximum, halved, as the imaging block size. Asked of the device rather than
# assumed, which is the whole lesson of the fault this exists to chase.
block_size() {
    python3 - "$1" <<'PY'
import fcntl, os, struct, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
best = 65536
for number in (70, 71):                        # DKIOCGETMAXBYTECOUNT{READ,WRITE}
    buf = bytearray(8)
    try:
        fcntl.ioctl(fd, 0x40000000 | (8 << 16) | (ord('d') << 8) | number, buf)
        value = struct.unpack('<Q', buf)[0]
        if value:
            best = min(best, value // 2)
    except OSError:
        pass
os.close(fd)
print(max(4096, (best // 512) * 512))
PY
}

resolve_device() {
    [ -n "$DEV" ] || die "set FR_DEV to the partition node, e.g. FR_DEV=/dev/rdisk33s1"
    case "$DEV" in
        /dev/rdisk*) ;;
        *) die "FR_DEV must be a raw node (/dev/rdiskNsM), not '$DEV'" ;;
    esac
    [ -c "$DEV" ] || die "$DEV is not a character device"
    local buffered=${DEV/rdisk/disk}
    if mount | grep -q "^$buffered "; then
        die "$buffered is mounted. Unmount it first: diskutil unmount $buffered"
    fi
}

case "${1:-}" in

build)
    clang -O2 -dynamiclib -o "$DYLIB" "$HERE/pwrite-trace.c"
    echo "built $DYLIB"
    ;;

image)
    dir=${2:?usage: card-session.sh image <dir> <label>}
    label=${3:?usage: card-session.sh image <dir> <label>}
    resolve_device
    mkdir -p "$dir"
    bs=$(block_size "$DEV")
    out="$dir/$label.img"
    [ -e "$out" ] && die "$out already exists; pick another label or move it aside"
    echo "imaging $DEV at bs=$bs (the device's stated maximum, halved) -> $out"
    echo "this reads the whole partition and takes a while; leave the card alone until it finishes"
    dd if="$DEV" of="$out" bs="$bs" 2>&1 | tail -3
    sync
    ls -lh "$out"
    # A digest of the image, so a later question about whether two stages differ at all costs
    # nothing to answer, and so a truncated or short-read image is caught here rather than in
    # analysis three hours later.
    shasum -a 256 "$out" | tee "$dir/$label.img.sha256"
    ;;

run)
    dir=${2:?usage: card-session.sh run <dir> <label>}
    label=${3:?usage: card-session.sh run <dir> <label>}
    resolve_device
    [ -f "$DYLIB" ] || die "no $DYLIB — run: ./card-session.sh build"
    [ "$(id -u)" != "0" ] || die "do not run this under sudo: the trace would be stripped and empty"
    [ -w "$DEV" ] || die "$DEV is not writable by you. Run once: sudo chmod o+rw $DEV"
    mkdir -p "$dir"
    trace="$dir/$label.trace"
    log="$dir/$label.log"
    [ -e "$trace" ] && die "$trace already exists; pick another label"
    # Which binary, recorded rather than remembered. The version under investigation is the one that
    # is installed, not the one the working tree would build: a tree with other work in it is a
    # different tool, and a clean result from it would say nothing about the version that failed.
    binary=$(command -v fatrabbit) || die "no fatrabbit on PATH"
    {
        echo "binary:  $binary"
        echo "version: $(fatrabbit --version)"
        echo "sha256:  $(shasum -a 256 "$binary" | cut -d' ' -f1)"
        echo "device:  $DEV"
    } | tee "$dir/$label.binary"
    echo "traced -> $trace"
    # --verbose because the per-move report is what correlates the trace back to objects: a record
    # saying 131,072 bytes went to some offset means little until the log says which object was
    # being moved where at that moment.
    FR_TRACE="$trace" DYLD_INSERT_LIBRARIES="$DYLIB" \
        fatrabbit "$DEV" --deMac --first QXL.WIN --last home --verbose 2>&1 | tee "$log" | tail -20
    echo
    if [ ! -s "$trace" ]; then
        die "the trace is empty: the library was not inserted. Not under sudo, is it?"
    fi
    echo "trace: $(wc -l < "$trace" | tr -d ' ') records, $(du -h "$trace" | cut -f1)"
    echo "largest write issued: $(awk '$1=="W" && $4>m {m=$4} END {print m+0}' "$trace") bytes"
    echo "short or failed transfers: $(awk '($1=="W"||$1=="R") && $5!=$4' "$trace" | wc -l | tr -d ' ')"
    ;;

*)
    sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
