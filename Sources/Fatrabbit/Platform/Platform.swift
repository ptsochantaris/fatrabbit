import Foundation

/// Everything fatrabbit needs from the operating system that the operating systems disagree about.
///
/// The whole of the platform surface is the nine members declared below, each implemented once per
/// platform in a file of its own. Nothing else in the codebase carries an `#if`: the FAT format
/// layer, the planners, the defragmenter and the display are the same code everywhere, which is
/// most of the reason this seam is worth having as a seam rather than as conditionals in place.
///
/// The members are grouped by the question they answer, and the two platforms answer several of
/// them in genuinely different ways rather than with renamed calls:
///
/// **Which volumes are mounted.** `mountedFilesystems` is `getfsstat` against
/// `/proc/self/mountinfo`. A rename, essentially.
///
/// **What is attached at all.** `blockDevices` is the newest member and the one where the two are
/// least alike. Darwin keeps a registry that knows every medium, how it is attached and what
/// hardware is behind it, so the answer is one walk over `IOMedia` and three property lookups, and
/// "is this disk internal" is a fact the system states outright. Linux publishes most of the same
/// facts as a directory of files, but not that one: nothing in sysfs says whether a device is
/// internal, so removability there is inferred from a `removable` flag, the bus the device hangs
/// off, and the naming of MMC cards. That difference is not papered over — it is why `--all-devices`
/// exists, and the Linux implementation says as much where it guesses.
///
/// Note what is deliberately *not* part of this member: whether a device holds a filesystem this
/// tool can work on. Both platforms will happily offer an opinion — a partition type byte, a content
/// GUID — and both opinions are labels somebody wrote once. `DeviceScan` reads the boot sector
/// instead, through the same `BPB` the run uses, so it is one answer arrived at one way on both.
///
/// **Whether a mounted device would be damaged by writing to ours.** `claims` is where the two
/// part company. Darwin folds `/dev/rdisk4s1` onto `/dev/disk4s1` and knows that a slice of
/// `/dev/disk4` is spelled by appending `s`. Linux has neither the raw/buffered pair nor one
/// partition-naming rule — `sdb` takes `sdb1`, `nvme0n1` takes `nvme0n1p1`, `mmcblk0` takes
/// `mmcblk0p1` — so it asks sysfs who a partition's parent is instead of guessing a suffix. That
/// is the same choice made for the device test in `isUncached`, and for the same reason: a name is
/// a worse witness than the thing itself.
///
/// **Which devices read through an image file.** `imageDevices` is the IORegistry's `image-path`
/// against a loop device's `backing_file`.
///
/// **Which node to open.** `rawNode` is Darwin's whole reason for having two device nodes per disk.
/// On Linux there is one node and the function is the identity — which is not the end of that
/// story, because the observability the raw node buys is what `O_DIRECT` would have to restore.
/// That decision is deliberately not made here.
///
/// **How large a transfer the device will accept.** `maximumTransfer` is
/// `DKIOCGETMAXBYTECOUNTREAD` against `BLKSECTGET`. This one is here because guessing it destroyed
/// data: the copy path used a hardcoded megabyte, a USB card reader that publishes 131,072 bytes
/// answered those reads with the right length of the wrong bytes and no error at any level, and an
/// image file — which publishes 2,097,152 — could never reproduce it. Both platforms will say if
/// asked; neither volunteers.
///
/// **Whether anything underneath us is already caching.** `isUncached` decides whether
/// `FATVolume` keeps its own metadata cache.
///
/// **What to tell the user to type.** `detachCommand`, `unmountCommand` and the two example
/// device names. Not cosmetic: before these were part of the seam, a Linux run refusing a mounted
/// volume told the reader to run `diskutil unmount`, and one finding an attached image told them
/// `hdiutil detach`. Both compile anywhere and neither exists off Darwin, so the tool was handing
/// out advice that could not be followed — the one class of portability bug a compiler will never
/// mention and a user meets immediately.
///
/// **How to make a write durable.** `synchronize` is `F_FULLFSYNC` plus `DKIOCSYNCHRONIZECACHE`
/// against a bare `fsync`, and the reasoning behind each is in the implementations, because the
/// whole safety argument rests on it.
enum System {}

// MARK: - Portable helpers

extension System {
    /// Reads a fixed-size C string field that Swift imports as a tuple of bytes, which is how both
    /// platforms hand back the names in their mount structures.
    static func fixedString<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The kind of node a descriptor refers to, which is the one question both platforms answer the
    /// same way even though they draw different conclusions from the answer.
    static func nodeKind(_ descriptor: Int32) -> mode_t? {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return nil }
        return status.st_mode & mode_t(S_IFMT)
    }

    /// A device path of the shape this platform actually hands out, for use in help text.
    static var exampleDevice: String { exampleDeviceNames.slice }
    /// The same disk's whole-device node, where the two differ.
    static var exampleWholeDevice: String { exampleDeviceNames.whole }

    static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
