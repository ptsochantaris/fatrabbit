import Foundation

// MARK: - What the system says

/// A block device as the operating system describes it, before anything has been read from it.
///
/// Deliberately thin. What the OS says is enough to decide whether a device is worth opening and how
/// to name it in a list, and that is all it is asked for. Whether it holds a FAT volume is *not*
/// asked here, because the answer the OS would give — an MBR type byte, a partition content GUID — is
/// a label somebody wrote once and is routinely wrong, in exactly the way the filesystem-type string
/// in a boot record is wrong. `DeviceScan` settles that question by reading the boot sector through
/// the same code `FATVolume` uses, so a list and the run that follows it cannot disagree.
struct BlockDevice {
    /// How the device is attached, which is the whole of what decides whether it is offered by
    /// default.
    enum Attachment {
        /// Removable or external media: a card, a stick, an enclosure. What this tool is for.
        case external
        /// A device reading through a file — an attached disk image on Darwin, a loop device on
        /// Linux. Also what this tool is for, since that is how it is tested.
        case image
        /// Fixed media: the disk the machine boots from, or one bolted inside it. Not offered
        /// unless asked for, because every Mac's internal disk carries a FAT32 EFI system partition
        /// and nobody reaching for this tool means that one.
        case fixed
    }

    /// The node to open, as a person would type it: `/dev/disk4s1`, not `/dev/rdisk4s1`. The
    /// redirection to the raw node is the run's business and happens where it always did.
    let node: String
    let attachment: Attachment
    /// What the OS says the device holds. Zero where it is a card reader with no card in it, which
    /// is the one value that means "skip this".
    let bytes: UInt64
    /// A human-facing name for the hardware, empty where the OS offers none. The point of it is
    /// recognition: "SanDisk Extreme" identifies a card in a way `/dev/disk6s1` does not.
    let model: String
}

// MARK: - What the volume says

/// A device that turned out to hold a FAT volume, described from its own boot sector.
struct FATCandidate {
    let device: BlockDevice
    let flavour: FATFlavour
    /// The volume label, empty where there is none.
    let name: String
    /// What the system currently thinks of it.
    let state: MountState

    /// Whether a run could actually work on it. A mounted volume cannot be, and is listed saying so
    /// rather than quietly dropped: a card that is mounted is the commonest reason one is missing
    /// from a list, and a list that answers that question before it is asked is worth the row.
    var isAvailable: Bool {
        switch state {
        case .free, .attached: true
        case .mounted: false
        }
    }
}

// MARK: - The sweep

/// Everything attached that this tool could work on.
///
/// Three steps, and the order matters. The platform says which devices exist and how they are
/// attached; that filters the list down to what is worth opening. Each survivor is then opened
/// read-only and its boot sector read, which is the only test of whether it is FAT. Finally the
/// mount table is consulted, which is what decides whether a candidate can be offered or only
/// explained.
enum DeviceScan {
    struct Findings {
        /// FAT volumes found, in the order they should be offered.
        let candidates: [FATCandidate]
        /// How many devices refused to open for lack of permission. Counted rather than discarded,
        /// because a disk device only opens as root and a short list with no explanation reads as
        /// "there is nothing here" when the truth is "you are not allowed to look".
        let unreadable: Int
    }

    static func sweep(includingFixed: Bool) -> Findings {
        var candidates: [FATCandidate] = []
        var unreadable = 0

        for device in System.blockDevices() {
            // A card reader with no card in it. Nothing to read, and on Linux the open can block.
            guard device.bytes > 0 else { continue }
            guard includingFixed || device.attachment != .fixed else { continue }

            switch probe(device) {
            case .fat(let candidate): candidates.append(candidate)
            case .notFAT: break
            case .noPermission: unreadable += 1
            }
        }

        // External media first, then images, then whatever was let in by `includingFixed`, and
        // within each group by name — sorted on length before content, since `disk10s1` sorts before
        // `disk4s1` any other way.
        let ordered = candidates.sorted {
            let (left, right) = (rank(of: $0.device.attachment), rank(of: $1.device.attachment))
            if left != right { return left < right }
            return ($0.device.node.count, $0.device.node) < ($1.device.node.count, $1.device.node)
        }
        return Findings(candidates: ordered, unreadable: unreadable)
    }

    private static func rank(of attachment: BlockDevice.Attachment) -> Int {
        switch attachment {
        case .external: 0
        case .image: 1
        case .fixed: 2
        }
    }

    // MARK: The probe

    private enum Outcome {
        case fat(FATCandidate)
        case notFAT
        case noPermission
    }

    /// Two small reads and no FAT.
    ///
    /// Opening the volume properly would answer every question this needs and several it does not:
    /// `FATVolume.init` decodes the whole table, which on a 2 TB card is half a gigabyte read to
    /// find out what the volume is called. So the geometry is parsed on its own — `BPB` needs only
    /// the boot sector, and throwing is how it says "not FAT", which is the entire eligibility test.
    private static func probe(_ device: BlockDevice) -> Outcome {
        let descriptor: Int32
        switch openForReading(device.node) {
        case .descriptor(let opened): descriptor = opened
        case .refused: return .noPermission
        case .absent: return .notFAT
        }
        defer { close(descriptor) }

        let blockSize = FATVolume.probeBlockSize(descriptor)
        guard let boot = try? FATVolume.read(descriptor, blockSize: blockSize, at: 0, count: 512),
              let bpb = try? BPB(bootSector: boot.span) else { return .notFAT }

        return .fat(FATCandidate(device: device,
                                 flavour: bpb.flavour,
                                 name: name(descriptor, blockSize: blockSize, boot: boot.span, bpb: bpb),
                                 state: mountState(ofVolumeAt: device.node)))
    }

    private enum Opened {
        case descriptor(Int32)
        /// Refused for lack of permission, which is worth telling the user about.
        case refused
        /// Refused for any other reason, which is not: it is simply not a candidate.
        case absent
    }

    /// Opens a device for reading only, through the same node a run would use.
    ///
    /// The raw node and not the buffered one, and a mounted volume is the case that decides it. A
    /// buffered node refuses a read-only open with EBUSY while the system has the volume mounted —
    /// measured, on a mounted FAT16 volume, where `/dev/rdisk33` read its boot sector happily and
    /// `/dev/disk33` returned "Resource busy". So the node the run wants anyway is also the only one
    /// that can describe the volume most worth describing: the one someone has left mounted, which
    /// is the commonest reason a card is missing from a list.
    ///
    /// Only a permission failure is reported as one. Everything else — no such device, a node that
    /// went away between the enumeration and here, a device that refuses for its own reasons — is
    /// simply not a candidate, and saying "you need sudo" about it would be a guess.
    private static func openForReading(_ node: String) -> Opened {
        let descriptor = open(System.rawNode(for: node), O_RDONLY)
        if descriptor >= 0 { return .descriptor(descriptor) }
        return (errno == EACCES || errno == EPERM) ? .refused : .absent
    }

    // MARK: The name

    /// What to call the volume, preferring what the system would call it.
    ///
    /// There are two copies of the label and they disagree in practice: the boot sector's is what a
    /// formatter wrote, while the root directory's is the one renaming a volume updates and the one
    /// the Finder shows. `FATVolume` has the same order of preference — it reports the boot sector's
    /// on opening and the scan supersedes it with `.labelled` when the walk finds the other — so
    /// reading both here is what stops a list and its run from calling one volume two things.
    private static func name(_ descriptor: Int32, blockSize: Int,
                            boot: Span<UInt8>, bpb: BPB) -> String {
        if let found = rootLabel(descriptor, blockSize: blockSize, bpb: bpb) { return found }
        // BS_VolLab, read exactly as `FATVolume.init` reads it, "NO NAME" and all.
        let label = boot.oemText(bpb.flavour.labelOffset ..< bpb.flavour.labelOffset + 11)
            .trimmingCharacters(in: .whitespaces)
        return label == "NO NAME" ? "" : label
    }

    /// The label out of the root directory, or nil where the first sector of it does not carry one.
    ///
    /// One sector rather than the whole directory. A label entry is written first by every formatter
    /// there is, and a picker is not worth walking a root directory to find one somebody buried
    /// behind a thousand files — the boot sector's copy is the fallback, and it is not usually wrong.
    private static func rootLabel(_ descriptor: Int32, blockSize: Int, bpb: BPB) -> String? {
        let fatSectors = bpb.numFATs * bpb.fatSize
        let rootRegion = UInt64(bpb.reservedSectorCount + fatSectors) * UInt64(bpb.bytesPerSector)

        let offset: UInt64
        let count: Int
        switch bpb.flavour {
        case .fat32:
            // The root is a chain like any other directory's, beginning at `rootCluster`.
            let dataStart = rootRegion + UInt64(bpb.rootDirSectors) * UInt64(bpb.bytesPerSector)
            let clusterSize = bpb.bytesPerSector * bpb.sectorsPerCluster
            offset = dataStart + UInt64(bpb.rootCluster - 2) * UInt64(clusterSize)
            count = min(bpb.bytesPerSector, clusterSize)
        case .fat12, .fat16:
            // A fixed region, which may be shorter than a sector on a volume with large ones.
            offset = rootRegion
            count = min(bpb.bytesPerSector, bpb.rootEntCnt * DirectoryEntry.size)
        }

        guard count >= DirectoryEntry.size,
              let block = try? FATVolume.read(descriptor, blockSize: blockSize,
                                              at: offset, count: count) else { return nil }
        return label(in: block.span)
    }

    /// The same walk `DirectoryWalker` does over a block of entries, cut down to the one entry this
    /// is looking for. The order of the tests is not arbitrary: a long-name component is `0x0F`,
    /// which has the volume-label bit set, so it has to be ruled out first or every long name in the
    /// root reads as the volume's.
    private static func label(in entries: Span<UInt8>) -> String? {
        var offset = 0
        while offset + DirectoryEntry.size <= entries.count {
            defer { offset += DirectoryEntry.size }
            let first = entries[offset]
            if first == 0x00 { return nil }     // end of directory
            if first == 0xE5 { continue }       // deleted
            let attributes = entries[offset + DirectoryEntry.attributesOffset]
            if attributes == 0x0F { continue }  // long-name component
            guard attributes & 0x08 != 0 else { continue }
            // The walker's decoder, not a second copy of it: an 11-byte OEM field with only its
            // trailing padding removed is a format rule, and two readings of it could differ.
            let label = DirectoryWalker
                .volumeLabel(entries.extracting(offset ..< offset + DirectoryEntry.size))
            if !label.isEmpty { return label }
        }
        return nil
    }
}
