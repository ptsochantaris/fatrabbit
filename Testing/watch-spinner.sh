#!/bin/sh
# Runs fatrabbit on the spinning drive, at the pace real hardware actually works at.
#
#   Testing/watch-spinner.sh            # the whole thing
#   Testing/watch-spinner.sh --plain    # the line output instead, for comparison
#   Testing/watch-spinner.sh -n         # dry run: reads everything, writes nothing
#
# SPINTEST is a 2 GiB FAT32 volume on a 320 GB USB drive: 42,149 files in 2,116 directories, two
# thirds full, thoroughly fragmented. Same geometry and profile as the disk-image volume, so the two
# are directly comparable — this one just takes minutes rather than seconds, which is much closer to
# what a card does.
#
# Nothing this script needs lives in /tmp except the binary and the scratch listing, both of which it
# makes. That is deliberate: /tmp went away in an OS upgrade and took the script and the 2 GiB snapshot
# with it, and a rebuilt snapshot is not the same volume — see "The filesystem driver writes the test
# volume" in README.md. Losing it invalidates every absolute figure and leaves an A/B with nothing to
# compare against, so it lives outside /tmp and the script says so loudly if it is missing.
#
# The scratch directory is created rather than assumed, which is not a formality: /tmp is emptied on
# some upgrades and by some reboots, and without the mkdir the *first* run afterwards died at the link
# step with "no such file or directory" for the binary — the one run where you are least expecting the
# harness itself to be the thing that broke.
#
# The device is looked up by volume name, and that is not fastidiousness. This script used to say
# /dev/rdisk14, which was true for as long as one session lasted; after an OS upgrade and reboot
# disk14 was a *simulator runtime volume*, and the restore below would have written two gigabytes of
# FAT32 over an APFS image. Numbers are assigned in attach order and mean nothing across a reboot or
# a replug. The name is the only stable thing about the drive, so it is what gets asked for, and the
# answer is checked before anything is written to it.
#
# Everything around a run has to use the same node — restore through /dev/diskN and the buffered
# cache answers a later read with blocks the run never wrote — so the raw node is resolved once here
# and used throughout. The tool would redirect a buffered node itself, but the script says which it
# means.
#
# Built from the working tree each time, so what is on screen is what is in the editor. That is the
# whole point of watching it, and a stale binary quietly showing yesterday's behaviour has wasted an
# afternoon before.
#
# Restoring takes about a minute: it writes the whole 2 GiB back, because the fragmented data is
# scattered across all of it and a partial restore would leave a stale tail.
#
# If it stops with a permissions error, the device nodes are root-owned — they revert on replug and
# on reboot. The script prints the exact command for whichever node it resolved.
#
# To check the volume afterwards:
#
#   fsck_msdos -n /dev/rdiskN
#   python3 ~/Documents/fatrabbit/Testing/fatread.py /dev/rdiskN > /tmp/fp/spin-after.txt
#   diff ~/Documents/fatrabbit-snapshots/spin-before.txt /tmp/fp/spin-after.txt
#                                                          # silence means every file is intact
#
# The "before" listing belongs beside the snapshot it describes, not in /tmp — it is only as
# reproducible as the volume is, which is to say not at all once that volume is gone.

set -e
SOURCE="$HOME/Documents/fatrabbit"
SNAPSHOTS="$HOME/Documents/fatrabbit-snapshots"
SCRATCH=/tmp/fp
BINARY="$SCRATCH/fatrabbit-current"
SNAPSHOT="$SNAPSHOTS/spin-fragmented.img"
VOLUME=SPINTEST

mkdir -p "$SCRATCH"

# --- Find the drive, and be sure it is the drive ---------------------------------------------------

MATCHES=$(diskutil list external physical | awk -v name="$VOLUME" \
    '$0 ~ "[[:space:]]" name "[[:space:]]" { print $NF }')
COUNT=$(printf '%s\n' "$MATCHES" | grep -c . || true)

if [ "$COUNT" -eq 0 ]; then
    echo "No external volume named $VOLUME is attached. Plug the spinner in." >&2
    exit 1
fi
if [ "$COUNT" -gt 1 ]; then
    echo "More than one external volume is named $VOLUME:" >&2
    printf '  %s\n' $MATCHES >&2
    echo "Detach whichever is not the spinner rather than guessing." >&2
    exit 1
fi

DISK="/dev/$MATCHES"
DEVICE="/dev/r$MATCHES"

# The name matching alone could be fooled, so the answer is checked against what the spinner is: a
# FAT32 superfloppy of about 320 GB. Anything else and we stop rather than write to it.
INFO=$(diskutil info "$DISK")
echo "$INFO" | grep -q "FAT32" || {
    echo "$DISK is named $VOLUME but is not FAT32 — refusing to write to it." >&2
    echo "$INFO" | grep -E "Device / Media Name|File System|Disk Size" >&2
    exit 1
}
echo "$VOLUME is $DEVICE ($(echo "$INFO" | awk -F': *' '/Device \/ Media Name/ {print $2}'))"

if [ ! -w "$DEVICE" ]; then
    echo "Cannot write $DEVICE. The nodes are root-owned after a reboot or replug:" >&2
    echo "    sudo chown \$(whoami) $DISK $DEVICE" >&2
    exit 1
fi

if [ ! -f "$SNAPSHOT" ]; then
    echo "Missing $SNAPSHOT." >&2
    echo "Rebuilding it does not restore it — the driver lays the same file set out differently, so" >&2
    echo "every absolute figure recorded against the old one stops being comparable. Read \"The" >&2
    echo "filesystem driver writes the test volume\" in Testing/README.md before running this:" >&2
    echo "    mkdir -p $SNAPSHOTS" >&2
    echo "    diskutil unmountDisk $DISK" >&2
    echo "    newfs_msdos -F 32 -c 32 -s 4194304 -v $VOLUME $DEVICE" >&2
    echo "    diskutil mount $DISK" >&2
    echo "    python3 $SOURCE/Testing/make-test-volume.py /Volumes/$VOLUME small 7" >&2
    echo "    diskutil unmount $DISK" >&2
    echo "    dd if=$DEVICE of=$SNAPSHOT bs=1m count=2048" >&2
    exit 1
fi

# --- Build from the working tree -------------------------------------------------------------------

NEEDED=no
[ -x "$BINARY" ] || NEEDED=yes
if [ "$NEEDED" = no ]; then
    for f in "$SOURCE"/*.swift; do
        [ "$f" -nt "$BINARY" ] && NEEDED=yes && break
    done
fi
if [ "$NEEDED" = yes ]; then
    echo "Building from $SOURCE…"
    swiftc -O "$SOURCE"/*.swift -o "$BINARY"
fi

# --- Restore and run -------------------------------------------------------------------------------

diskutil unmount force "$DISK" >/dev/null 2>&1 || true
echo "Restoring the fragmented volume (about a minute)…"
dd if="$SNAPSHOT" of="$DEVICE" bs=4m 2>/dev/null
exec "$BINARY" "$DEVICE" "$@"
