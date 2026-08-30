#if os(Linux)

import Foundation
#if canImport(Glibc)
import Glibc
#endif

// The Linux half of the seam declared in Platform.swift.
//
// Three of these are renames of the Darwin call. Three are not, and those are the ones worth
// reading: `claims`, because Linux has no single partition-naming rule to match against;
// `isUncached`, because Linux has no raw node to recognise; and `synchronize`, because on Linux one
// call already does what Darwin needs two for.

extension System {

    // MARK: Mount table

    /// Parsed out of `/proc/self/mountinfo` rather than `/proc/mounts`, because mountinfo is the
    /// one the kernel guarantees for this purpose and it distinguishes bind mounts, which the older
    /// file cannot.
    ///
    /// The format is positional up to a `-` separator and positional again after it, with a
    /// variable-length field in between that has to be skipped by finding the separator rather than
    /// by counting:
    ///
    ///     36 35 98:0 /mnt1 /mnt2 rw,noatime master:1 - ext3 /dev/root rw
    ///                     ^mount point                      ^source
    static func mountedFilesystems() -> [(device: String, mountPoint: String)] {
        guard let contents = try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8)
        else { return [] }

        var mounts: [(device: String, mountPoint: String)] = []
        for line in contents.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            // Mount point is the fifth field; the source is the second field after the separator.
            guard fields.count > 4, let dash = fields.firstIndex(of: "-"),
                  fields.index(dash, offsetBy: 2, limitedBy: fields.endIndex) != nil
            else { continue }
            let mountPoint = unescape(String(fields[4]))
            let device = unescape(String(fields[fields.index(dash, offsetBy: 2)]))
            mounts.append((device, mountPoint))
        }
        return mounts
    }

    /// mountinfo escapes the four characters that would otherwise break the field split, as octal.
    /// A path containing a space is not exotic on a removable volume, so this is not decoration.
    private static func unescape(_ field: String) -> String {
        guard field.contains("\\") else { return field }
        var out = ""
        var rest = Substring(field)
        while let slash = rest.firstIndex(of: "\\") {
            out += rest[rest.startIndex ..< slash]
            let digits = rest.index(slash, offsetBy: 4, limitedBy: rest.endIndex)
            if let digits, let code = UInt8(rest[rest.index(after: slash) ..< digits], radix: 8) {
                out.append(Character(UnicodeScalar(code)))
                rest = rest[digits...]
            } else {
                out.append("\\")
                rest = rest[rest.index(after: slash)...]
            }
        }
        return out + rest
    }

    // MARK: Device naming

    /// Whether a mounted `device` would be damaged by writing to `target`: the same node, or a
    /// partition of it when `target` is the whole disk.
    ///
    /// Darwin can do the second half by appending `s` to a name. Linux cannot, because it has no
    /// one rule — `sdb` takes `sdb1`, `nvme0n1` takes `nvme0n1p1`, `mmcblk0` takes `mmcblk0p1`,
    /// and a suffix test that covers all three also matches names that are nothing of the kind.
    /// So the question goes to sysfs, which knows the answer outright: a partition's entry under
    /// `/sys/class/block` is a symlink into the device tree, and its parent directory is the disk
    /// it belongs to. No naming rule to be wrong about, and new device classes come for free.
    static func claims(_ target: String, _ device: String) -> Bool {
        if canonicalDevice(device) == target { return true }
        guard let parent = wholeDisk(ofPartition: device) else { return false }
        return parent == deviceName(target)
    }

    /// Linux has one node per disk, so there is nothing to fold.
    static func canonicalDevice(_ path: String) -> String { path }

    /// Linux has no raw counterpart to open instead, so the path is used as given.
    ///
    /// This is where Darwin's raw node buys observability that Linux does not hand over for free:
    /// with the page cache underneath, writes are deferred and the access pattern cannot be seen.
    /// `O_DIRECT` is the counterpart, and adopting it is a decision about `rawRead`/`rawWrite`
    /// buffer alignment rather than about this function, so it is not made here.
    static func rawNode(for path: String) -> String { path }

    private static func deviceName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// The disk a partition belongs to, or nil if the node is not a partition at all.
    private static func wholeDisk(ofPartition device: String) -> String? {
        let name = deviceName(device)
        let entry = "/sys/class/block/\(name)"
        // A partition has this file; a whole disk does not, which is the cheapest way to tell.
        guard access("\(entry)/partition", F_OK) == 0 else { return nil }
        let resolved = URL(fileURLWithPath: entry).resolvingSymlinksInPath()
        return resolved.deletingLastPathComponent().lastPathComponent
    }

    // MARK: Loop devices

    /// Device nodes of every loop device reading through `path`, whole disk first.
    ///
    /// The counterpart of Darwin's IORegistry walk, and a considerably shorter one: the kernel
    /// publishes the association as a file per loop device, so this is a directory listing and a
    /// string compare. Partitions of a matching loop device are included, since a mounted
    /// `loop0p1` is exactly as fatal as a mounted `loop0`.
    static func imageDevices(backing path: String) -> [String] {
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: "/sys/class/block") else { return [] }

        var devices: [String] = []
        for name in names where name.hasPrefix("loop") {
            let file = "/sys/class/block/\(name)/loop/backing_file"
            guard let raw = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            // The kernel appends " (deleted)" when the backing file has been unlinked under it.
            var backing = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if backing.hasSuffix(" (deleted)") { backing = String(backing.dropLast(10)) }
            guard backing == path else { continue }
            devices.append("/dev/" + name)
            for other in names where wholeDisk(ofPartition: other) == name {
                devices.append("/dev/" + other)
            }
        }
        // Shortest name first, so the whole device leads — the same ordering Darwin returns, and
        // the one `mountState` relies on to name a device worth detaching.
        return devices.sorted { ($0.count, $0) < ($1.count, $1) }
    }

    // MARK: What is attached

    /// Every medium that could hold a filesystem, with what sysfs knows about it.
    ///
    /// The same two rules as the Darwin implementation, reached differently. A whole disk that has
    /// been carved up is a container and its partitions are the candidates, so it is dropped — asked
    /// as "does anything here call me its parent" rather than by reading a partition table, which is
    /// the question sysfs can answer. A whole disk with no partitions is kept, because that is how
    /// most cards are formatted and the filesystem is right there at sector zero.
    ///
    /// Pseudo devices are skipped by name, which is the one place a name is the only witness
    /// available: `zram0` is a compressed swap device and `dm-0` a mapper target, and neither is
    /// something this tool should offer to defragment. Loop devices are kept only when they are
    /// reading through a file, which is the same test `imageDevices` makes.
    ///
    /// Where this is weaker than Darwin, and knowingly: there is no property that says whether a
    /// device is internal. `removable` covers USB sticks and card readers but reads 0 for the SD
    /// cards this tool is most often pointed at, so the bus is consulted as well, and MMC devices are
    /// taken as removable on the strength of what they are. It is a heuristic, it will occasionally
    /// put an external disk in the wrong group, and `--all-devices` is the answer to that rather than
    /// a longer list of special cases here.
    static func blockDevices() -> [BlockDevice] {
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: "/sys/class/block") else { return [] }

        var devices: [BlockDevice] = []
        for name in names {
            guard !isPseudo(name) else { continue }

            // A partition carries almost nothing of its own: the model, the removable flag and the
            // file behind a loop device all belong to the disk, so the parent is established first
            // and everything below asks `disk` rather than `name`. Getting this the other way round
            // is what dropped `loop1p1` — a partition has no `loop/` directory, so a loop device's
            // one partition looked exactly like an unused loop slot.
            let parent = wholeDisk(ofPartition: name)
            let disk = parent ?? name
            let backing = sysfsText("\(disk)/loop/backing_file")

            // Every loop slot the kernel has ever handed out stays in here afterwards with nothing
            // behind it. There are usually eight of them and they are not devices in any sense.
            if disk.hasPrefix("loop"), backing == nil { continue }
            // A whole disk with partitions is a container; its partitions are already in `names`.
            if parent == nil, names.contains(where: { wholeDisk(ofPartition: $0) == name }) {
                continue
            }

            // Sector counts in sysfs are always in units of 512 bytes, whatever the device's own
            // block size — the one number in here that does not mean what its name suggests.
            let sectors = UInt64(sysfsText("\(name)/size") ?? "") ?? 0

            let attachment: BlockDevice.Attachment
            if backing != nil {
                attachment = .image
            } else if sysfsText("\(disk)/removable") == "1" || isRemovableBus(disk) {
                attachment = .external
            } else {
                attachment = .fixed
            }

            devices.append(BlockDevice(node: "/dev/" + name,
                                       attachment: attachment,
                                       bytes: sectors * 512,
                                       model: model(of: disk),
                                       // Always false, and not an oversight. Darwin fills this in
                                       // from the partition type its scheme driver publishes; sysfs
                                       // publishes a partition's number, start and size and not its
                                       // type, so the EFI type GUID is simply not available without
                                       // parsing the partition table here — which would mean
                                       // teaching this tool GPT and MBR to hide one row. The case it
                                       // would catch barely arises: a UEFI machine's system
                                       // partition lives on the disk it boots from, which is already
                                       // `.fixed` and already out of the default list.
                                       firmwareReserved: false))
        }
        return devices
    }

    /// Devices that are not media in any sense this tool means: memory-backed disks (`ram`, `zram`),
    /// mapper targets (`dm-`), software RAID sets (`md`), optical drives (`sr`) and network block
    /// devices (`nbd`). Each can be named on the command line if somebody really means it; none
    /// belongs in a list of cards to defragment.
    ///
    /// `fd` is deliberately absent. A floppy drive is the one thing here that genuinely is removable
    /// media holding FAT12, which is a variant this tool went to some trouble to support, so it would
    /// be a strange thing to hide.
    private static func isPseudo(_ name: String) -> Bool {
        ["ram", "zram", "dm-", "md", "sr", "nbd"].contains { name.hasPrefix($0) }
    }

    /// Whether the disk hangs off a bus that only carries removable media in practice.
    ///
    /// The sysfs entry for a block device is a symlink into the device tree, so the bus it is
    /// attached through is written into its resolved path — the same property `wholeDisk` relies on
    /// to find a partition's parent, read for a different purpose.
    private static func isRemovableBus(_ disk: String) -> Bool {
        if disk.hasPrefix("mmcblk") { return true }   // an SD or MMC card, which reports removable=0
        let resolved = URL(fileURLWithPath: "/sys/class/block/\(disk)").resolvingSymlinksInPath().path
        return resolved.contains("/usb")
    }

    /// What the hardware calls itself. SCSI and USB disks publish `model`; MMC cards publish `name`,
    /// and neither has the other, so both are tried.
    private static func model(of disk: String) -> String {
        sysfsText("\(disk)/device/model") ?? sysfsText("\(disk)/device/name") ?? ""
    }

    /// A sysfs attribute as a trimmed string, or nil where there is no such file. Everything in here
    /// is a short text file with a trailing newline, so there is nothing else to parsing it.
    private static func sysfsText(_ path: String) -> String? {
        guard let raw = try? String(contentsOfFile: "/sys/class/block/\(path)", encoding: .utf8)
        else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: What to tell the user to type

    /// `losetup -d`, not `hdiutil detach`. A loop device is what Linux offers in place of an
    /// attached image, and detaching one is its own verb.
    static func detachCommand(for device: String) -> String { "losetup -d \(device)" }
    /// Plain `umount`. There is no `diskutil`, and nothing else to route this through.
    static func unmountCommand(for device: String) -> String { "umount \(device)" }
    /// Linux has one node per partition, so both examples are the same name. `sdb1` rather than
    /// `nvme0n1p1` because the tool is aimed at removable media, which is where `sd*` lives.
    static var exampleDeviceNames: (slice: String, whole: String) { ("/dev/sdb1", "/dev/sdb1") }

    /// Linux has no raw node to redirect to, so this says what is true here instead of repeating
    /// Darwin's claim. Understating it deliberately: the page cache genuinely is in the way, and
    /// promising otherwise would be the kind of thing this tool exists not to do.
    ///
    /// One paragraph on one line, deliberately: the help formatter wraps it to the terminal, so any
    /// line breaks written in here would survive the wrap and land as breaks in the middle of it.
    static let nodeAdvice = "A device node is opened as given; Linux has no separate raw node, so "
        + "the kernel's page cache sits underneath and may defer writes past the point this tool "
        + "reports them."

    // MARK: The device itself

    /// Whether nothing underneath us is already caching what we read.
    ///
    /// Block devices count here, which is where Linux departs from Darwin and does so knowingly.
    /// Strictly the kernel *does* buffer a block device, so by Darwin's reasoning the answer would
    /// be no. But Darwin excludes block devices because it has a character device to prefer
    /// instead, and Linux has nothing to prefer: this is the only node a disk gets. Refusing the
    /// cache here would not avoid a redundant copy, it would simply give up the cache on every
    /// Linux run — worth about 45 seconds of re-read per run where it was measured on macOS.
    ///
    /// Character devices are still accepted, so a raw node reached through some other mechanism
    /// behaves as it would on Darwin.
    static func isUncached(_ descriptor: Int32) -> Bool {
        guard let kind = nodeKind(descriptor) else { return false }
        return kind == mode_t(S_IFBLK) || kind == mode_t(S_IFCHR)
    }

    /// Pushes writes all the way to the medium, which here takes one call rather than two.
    ///
    /// Darwin needs `F_FULLFSYNC` for files and `DKIOCSYNCHRONIZECACHE` for devices because plain
    /// `fsync` stops at the drive's own volatile cache. Linux does not have that gap to close:
    /// `fsync` on a block device issues a cache flush to the drive, and on a regular file it
    /// forwards one to the underlying device. So the barrier this tool's safety argument depends on
    /// is `fsync` here, in full, and not a weaker version of the Darwin one.
    ///
    /// Deliberately *not* carried over: the Darwin ioctl number. `DKIOCSYNCHRONIZECACHE` is
    /// `0x2000_6416`, an encoding Linux does not share, and the old code tolerated `ENOTTY` from
    /// it — so leaving it in place would have compiled, run, quietly done nothing, and still looked
    /// like a barrier. It happens that `fsync` alone is correct here, which means that arrangement
    /// would have been right by luck. `BLKFLSBUF` is not the counterpart either: it discards the
    /// buffer cache rather than committing it.
    ///
    /// - Returns: nil on success, or the `errno` that explains the failure.
    static func synchronize(_ descriptor: Int32) -> Int32? {
        fsync(descriptor) == 0 ? nil : errno
    }
}

#endif
