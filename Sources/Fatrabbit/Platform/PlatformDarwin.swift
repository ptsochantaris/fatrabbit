#if canImport(Darwin)

import Foundation
import IOKit

// The Darwin half of the seam declared in Platform.swift. Every line here was in MountCheck.swift,
// FATVolume.swift or main.swift before the split, and behaves as it did — the move is what makes
// a second platform possible, not a change to this one.

extension System {

    // MARK: Mount table

    /// `statfs` names both a struct and a function in Darwin, and the function wins wherever the
    /// two could be meant, so the struct is reached through an alias.
    private typealias FSStat = statfs

    static func mountedFilesystems() -> [(device: String, mountPoint: String)] {
        // Sized from a first, counting call. A mount appearing between the two calls is only ever a
        // mount we fail to notice, never a buffer overrun — the second call is bounded by the buffer.
        let capacity = getfsstat(nil, 0, MNT_NOWAIT)
        guard capacity > 0 else { return [] }
        var buffer = [FSStat](repeating: FSStat(), count: Int(capacity))
        let count = getfsstat(&buffer, Int32(MemoryLayout<FSStat>.stride * Int(capacity)), MNT_NOWAIT)
        guard count > 0 else { return [] }
        return buffer.prefix(Int(count)).map {
            (fixedString($0.f_mntfromname), fixedString($0.f_mntonname))
        }
    }

    // MARK: Device naming

    /// Whether a mounted `device` would be damaged by writing to `target`: the same node, or a
    /// slice of it when `target` is the whole disk (`/dev/disk4` against a mounted `/dev/disk4s1`).
    static func claims(_ target: String, _ device: String) -> Bool {
        let mounted = canonicalDevice(device)
        return mounted == target || mounted.hasPrefix(target + "s")
    }

    /// `/dev/rdisk4s1` and `/dev/disk4s1` are the same slice reached two ways; the mount table only
    /// ever names the buffered one, so raw nodes are folded onto it before comparing.
    static func canonicalDevice(_ path: String) -> String {
        guard path.hasPrefix("/dev/rdisk") else { return path }
        return "/dev/disk" + path.dropFirst("/dev/rdisk".count)
    }

    /// The raw node for a device path — the only way this tool talks to a device.
    ///
    /// A buffered node defers writes and then charges them to whichever flush comes next, so the
    /// work is reported in the wrong place at the wrong time, and the access pattern — the thing
    /// worth tuning — cannot be seen at all. It also caps every device request at 16 KB, so
    /// transfer shapes chosen here would never reach the medium. Going direct costs about five
    /// seconds in nine minutes, given the metadata blocks held in `FATVolume` to stand in for the
    /// page cache.
    ///
    /// Image files have no raw counterpart and are passed through untouched.
    static func rawNode(for path: String) -> String {
        guard path.hasPrefix("/dev/disk") else { return path }
        return "/dev/rdisk" + path.dropFirst("/dev/disk".count)
    }

    // MARK: Disk images

    /// Device nodes of every attached disk image that reads through `path`, whole disk first —
    /// which is the one worth naming, since it is what `hdiutil detach` takes.
    ///
    /// An attached image is a stack of IORegistry objects: the media objects the rest of the system
    /// sees, provided by a driver that holds the path of the file behind them. So the association
    /// we want is already in the registry, and finding it is a walk rather than a question for
    /// `hdiutil`.
    static func imageDevices(backing path: String) -> [String] {
        var devices: [String] = []
        forEachMedium { media in
            if let name = registryString(media, "BSD Name"), backingImagePath(of: media) == path {
                devices.append("/dev/" + name)
            }
        }
        // A whole disk's node is a prefix of its slices', so the shortest name is the whole disk.
        return devices.sorted { ($0.count, $0) < ($1.count, $1) }
    }

    /// Every `IOMedia` object in turn, released as it is done with.
    ///
    /// One walk shared by the two callers that need it. Not merely to save the six lines: an
    /// iteration that leaks an object is a bug that shows up as a device node the kernel will not
    /// let go of afterwards, and there is now one place where that could be got wrong instead of
    /// two.
    private static func forEachMedium(_ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOMedia"),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var media = IOIteratorNext(iterator)
        while media != IO_OBJECT_NULL {
            body(media)
            IOObjectRelease(media)
            media = IOIteratorNext(iterator)
        }
    }

    // MARK: What is attached

    /// Every medium that could hold a filesystem, with what the registry knows about it.
    ///
    /// The filter is one rule: a medium whose content is a partition map is a container, not a
    /// volume. Its children are the candidates and it is not one itself, so it is dropped and
    /// everything else — every partition, and every whole disk formatted without a map, which is how
    /// most cards arrive — is kept and left for the boot-sector probe to judge. `Leaf` looks like the
    /// property for this and is not: an APFS container is not a leaf either, and a whole disk with a
    /// filesystem written straight onto it stops being one the moment anything mounts from it.
    ///
    /// Attachment is three questions asked in order of how much they settle. An image is decided by
    /// the `image-path` walk rather than by the interconnect string, which reads "File" for most
    /// attached images and is missing on some. Otherwise `Removable` or `Ejectable` — both of which
    /// partition media inherit from their whole disk, so there is nothing to walk — or an
    /// interconnect location the system itself calls External. Everything left is fixed.
    static func blockDevices() -> [BlockDevice] {
        var devices: [BlockDevice] = []
        forEachMedium { media in
            guard let name = registryString(media, "BSD Name") else { return }
            let content = registryString(media, "Content") ?? ""
            guard !content.hasSuffix("partition_scheme") else { return }

            let attachment: BlockDevice.Attachment
            if backingImagePath(of: media) != nil {
                attachment = .image
            } else if registryFlag(media, "Removable") || registryFlag(media, "Ejectable")
                || inherited(media, "Protocol Characteristics",
                             "Physical Interconnect Location") == "External" {
                attachment = .external
            } else {
                attachment = .fixed
            }

            devices.append(BlockDevice(
                node: "/dev/" + name,
                attachment: attachment,
                bytes: registryCount(media, "Size"),
                model: inherited(media, "Device Characteristics", "Product Name") ?? "",
                firmwareReserved: isSystemPartition(content)))
        }
        return devices
    }

    /// Whether a partition's declared type hands it to the firmware.
    ///
    /// Worth filtering rather than leaving to the person reading the list, because an EFI system
    /// partition is FAT32, is often on external media — every one of the three USB and NVMe
    /// enclosures this was developed against carries one, so they are not a rare sight in the
    /// list — and is 200 MB of firmware payload that would be a strange thing to defragment.
    ///
    /// Both spellings are needed because the two partition schemes state the same fact differently.
    /// GPT names types by GUID and `IOGUIDPartitionScheme` passes the GUID through verbatim, so the
    /// EFI type arrives as the well-known constant below. MBR names them by a byte, and
    /// `IOFDiskPartitionScheme` renders the ones it has no friendly name for as hex — type 0xEF is
    /// the EFI system partition there, and has no friendly name.
    ///
    /// A partition claimed by the firmware is not *refused* anywhere: naming one on the command line
    /// works exactly as it always did, and `--all-devices` puts them back in the list. This is about
    /// what gets offered unasked.
    private static func isSystemPartition(_ content: String) -> Bool {
        let efi = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
        return content.caseInsensitiveCompare(efi) == .orderedSame
            || content.caseInsensitiveCompare("0xEF") == .orderedSame
    }

    private static func registryFlag(_ object: io_object_t, _ key: String) -> Bool {
        IORegistryEntryCreateCFProperty(object, key as CFString,
                                        kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }

    private static func registryCount(_ object: io_object_t, _ key: String) -> UInt64 {
        let value = IORegistryEntryCreateCFProperty(object, key as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue()
        guard let number = value as? NSNumber else { return 0 }
        return number.uint64Value
    }

    /// A string out of a dictionary property that belongs to the hardware rather than to the medium.
    ///
    /// Which object holds it is not ours to know: how a device is attached and what it is called are
    /// declared by whichever driver in the stack knows, several objects above a partition. So the
    /// search goes up the provider chain — the same direction `backingImagePath` walks by hand, done
    /// here in one call because there is no per-object decision to make on the way.
    private static func inherited(_ object: io_object_t, _ dictionary: String,
                                  _ key: String) -> String? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let found = IORegistryEntrySearchCFProperty(object, kIOServicePlane,
                                                          dictionary as CFString,
                                                          kCFAllocatorDefault, options),
              let characteristics = found as? [String: Any] else { return nil }
        return characteristics[key] as? String
    }

    /// Walks up the provider chain from a media object to the disk-image driver above it, which
    /// carries the path of the file the whole stack reads through. Walked rather than reached
    /// directly, because how many objects sit in between is not ours to assume.
    private static func backingImagePath(of media: io_object_t) -> String? {
        var object = media
        IOObjectRetain(object)
        while object != IO_OBJECT_NULL {
            if let path = registryString(object, "image-path") {
                IOObjectRelease(object)
                return path
            }
            var parent: io_object_t = IO_OBJECT_NULL
            let status = IORegistryEntryGetParentEntry(object, kIOServicePlane, &parent)
            IOObjectRelease(object)
            guard status == KERN_SUCCESS else { return nil }
            object = parent
        }
        return nil
    }

    /// Reads a registry property that may be held either as a string or as raw path bytes:
    /// `BSD Name` is a string, while `image-path` is data, and a trailing NUL is not guaranteed
    /// either way.
    private static func registryString(_ object: io_object_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(object, key as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        if let string = value as? String { return string }
        if let data = value as? Data {
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        }
        return nil
    }

    // MARK: What to tell the user to type

    static func detachCommand(for device: String) -> String { "hdiutil detach \(device)" }
    static func unmountCommand(for device: String) -> String { "diskutil unmount \(device)" }
    static var exampleDeviceNames: (slice: String, whole: String) {
        ("/dev/rdisk4s1", "/dev/disk4s1")
    }

    /// The help text's paragraph about which node gets opened. Platform-specific in substance and
    /// not merely in spelling, which is why it is here rather than interpolated from parts.
    ///
    /// One paragraph on one line, deliberately: the help formatter wraps it to the terminal, so any
    /// line breaks written in here would survive the wrap and land as breaks in the middle of it.
    static let nodeAdvice = "Device nodes are always opened raw: /dev/diskN is redirected to "
        + "/dev/rdiskN, so the tool talks to the medium itself rather than to a cache that will "
        + "decide later when the work really happens."

    // MARK: The device itself

    /// Whether nothing underneath us is already caching what we read.
    ///
    /// A character device is the test because that is what a raw node is, and a raw node is the
    /// only thing here with no page cache beneath it. A block device — `/dev/diskN` — is excluded
    /// deliberately rather than overlooked: the kernel buffers it, so a second copy would be the
    /// same waste it is against a file.
    /// `DKIOCGETMAXBYTECOUNTREAD` and its write twin, from `<sys/disk.h>`. Written out because
    /// `_IOR` is a macro and macros of this shape do not come across into Swift.
    private static let maxByteCountRead: UInt = 0x4008_6446
    private static let maxByteCountWrite: UInt = 0x4008_6447

    /// The largest transfer this device says it will accept, or nil where it will not say.
    ///
    /// Worth having because the alternative was a guess, and the guess was wrong in a way that
    /// destroyed data. A megabyte was chosen as "a multiple of every plausible block size", which
    /// conflated two unrelated things: how a transfer must be *aligned*, and how large it may be.
    /// A USB card reader measured here advertises 131,072 bytes, so every megabyte-sized read the
    /// copy path issued was eight times over a published limit — and on that reader an oversized
    /// read comes back holding the right length of the wrong bytes, from 65,536 bytes away, with no
    /// error anywhere. An `hdiutil` image on the same machine advertises 2,097,152, which is why
    /// none of this was ever visible against an image.
    ///
    /// The smaller of the two directions is taken, since one number governs both paths here, and
    /// zero is treated as no answer rather than as a limit of nothing. Nil for anything that is not
    /// a disk — a plain file has no such limit and the ioctl fails — and the caller keeps its own
    /// ceiling for that case.
    static func maximumTransfer(_ descriptor: Int32) -> Int? {
        var limits: [UInt64] = []
        for request in [maxByteCountRead, maxByteCountWrite] {
            var value: UInt64 = 0
            guard ioctl(descriptor, request, &value) == 0, value > 0 else { continue }
            limits.append(value)
        }
        guard let smallest = limits.min(), smallest > 0 else { return nil }
        return Int(smallest)
    }

    static func isUncached(_ descriptor: Int32) -> Bool {
        nodeKind(descriptor) == mode_t(S_IFCHR)
    }

    /// `_IO('d', 22)` from `<sys/disk.h>`. Written out because it is a macro and macros of this
    /// shape do not come across into Swift.
    private static let synchronizeCache: UInt = 0x2000_6416

    /// Pushes writes all the way to the medium, which takes two calls and not one.
    ///
    /// fsync(2) hands what the page cache holds to the drive and stops there; the drive may still
    /// be sitting on it in a volatile cache of its own. On a file, F_FULLFSYNC closes that gap. On
    /// a device it does not: every device node refuses it with ENOTTY — card and spinning drive,
    /// raw node and buffered — which is to say on precisely the media this tool is written for.
    ///
    /// DKIOCSYNCHRONIZECACHE is the device-level equivalent and is accepted by all of them. Both
    /// calls are made: fsync to get the data out of the kernel, then the ioctl to get the drive to
    /// commit it. The whole safety argument — copies durable before anything names them, names
    /// durable before the space they abandoned is reused — rests on this actually happening.
    ///
    /// - Returns: nil on success, or the `errno` that explains the failure.
    static func synchronize(_ descriptor: Int32) -> Int32? {
        // Files take F_FULLFSYNC, and for a file that is the whole job.
        if fcntl(descriptor, F_FULLFSYNC) != -1 { return nil }
        guard fsync(descriptor) == 0 else { return errno }
        if ioctl(descriptor, synchronizeCache) == -1, errno != ENOTTY { return errno }
        return nil
    }
}

#endif
