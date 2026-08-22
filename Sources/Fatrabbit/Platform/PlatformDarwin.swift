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
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOMedia"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [String] = []
        var media = IOIteratorNext(iterator)
        while media != IO_OBJECT_NULL {
            if let name = registryString(media, "BSD Name"), backingImagePath(of: media) == path {
                devices.append("/dev/" + name)
            }
            IOObjectRelease(media)
            media = IOIteratorNext(iterator)
        }
        // A whole disk's node is a prefix of its slices', so the shortest name is the whole disk.
        return devices.sorted { ($0.count, $0) < ($1.count, $1) }
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
    static let nodeAdvice = """
                             Device nodes are always opened raw: /dev/diskN is redirected to
                             /dev/rdiskN, so the tool talks to the medium itself rather than to
                             a cache that will decide later when the work really happens.
    """

    // MARK: The device itself

    /// Whether nothing underneath us is already caching what we read.
    ///
    /// A character device is the test because that is what a raw node is, and a raw node is the
    /// only thing here with no page cache beneath it. A block device — `/dev/diskN` — is excluded
    /// deliberately rather than overlooked: the kernel buffers it, so a second copy would be the
    /// same waste it is against a file.
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
