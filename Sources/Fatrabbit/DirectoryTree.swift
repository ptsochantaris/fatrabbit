import Foundation

/// One relocatable object in the filesystem: a file or directory identified by its cluster
/// chain, together with enough context to repoint everything that refers to it once it moves.
/// A file or directory is referenced from exactly two kinds of place: the short entry in its
/// parent directory, and — for a directory — the `..` entry of each of its subdirectories.
final class FSObject {
    let name: String            // 8.3 short name, used for --first/--last matching
    let isDirectory: Bool
    let isRoot: Bool
    /// Byte offset of this object's short entry within its parent's directory data. The
    /// parent's own clusters may move, so this is resolved against the parent's current chain
    /// at the moment of the write rather than baked into an absolute position.
    let entryOffset: Int
    /// Owning directory; nil for the root. Parents retain their children, so this is weak.
    weak var parent: FSObject?
    /// The object's current cluster chain, updated in place as it is relocated.
    ///
    /// A `ClusterSet` rather than an array, which matters most for what a run *produces*: every object
    /// the layout places lands in one piece, so its chain afterwards is a run and is held as one. The
    /// scan still reads scattered chains into lists, because that is what they are.
    var chain: ClusterSet
    var children: [FSObject] = []
    /// Byte offsets of this directory's own `.` and `..` entries within its data. `.` names the
    /// directory itself and `..` names its parent, so both have to be corrected when the
    /// directory or its parent is relocated.
    var dotOffset: Int?
    var dotDotOffset: Int?
    /// The cluster numbers those entries named when the tree was scanned. Valid wherever the
    /// matching offset is set. For a directory this run never moved, and whose parent it never
    /// moved, nothing has been written over them — so these are still what is on the disk, and an
    /// end-of-run check against them needs no read at all.
    var dotStart: UInt32 = 0
    var dotDotStart: UInt32 = 0
    /// Where this object's chain began before anything was relocated. `.` names the directory's
    /// own first cluster and `..` names its parent's, so this is what says whether either entry
    /// could possibly have needed writing.
    let originalStart: UInt32

    init(name: String, isDirectory: Bool, isRoot: Bool = false, entryOffset: Int = 0,
         parent: FSObject? = nil, chain: ClusterSet) {
        self.name = name
        self.isDirectory = isDirectory
        self.isRoot = isRoot
        self.entryOffset = entryOffset
        self.parent = parent
        self.chain = chain
        self.originalStart = chain.first ?? 0
    }

    var start: UInt32 { chain[0] }

    /// Number of separate runs the chain occupies; 1 means contiguous.
    var extentCount: Int { chain.extentCount }

    var isContiguous: Bool { chain.isContiguous }

    var label: String {
        if isRoot { return "root" }
        return "\(isDirectory ? "dir " : "file") \(name)"
    }
}

/// Walks the FAT32 directory tree, following cluster chains, and returns the root object with
/// the tree of non-empty files and directories beneath it.
///
/// With `deMac` enabled, macOS metadata is pruned as the tree is walked: the objects never
/// reach the planner, and their directory entries and clusters are recorded so the caller can
/// erase and release them.
final class DirectoryWalker {
    let volume: FAT32Volume
    let deMac: Bool
    /// Optional, only so the walk can say how far it has got. On a card the scan is minutes of
    /// silence otherwise, since every directory costs a real read.
    private let report: Reporter?

    private var removals: [UInt32: [Int]] = [:]
    private var removedNames: [String] = []
    private var removedFiles = 0
    private var removedDirectories = 0
    private var removedClusters: [UInt32] = []
    private var hiddenDots: [(cluster: UInt32, offset: Int)] = []

    private var directoriesSeen = 0
    private var filesSeen = 0
    private var bytesRead: UInt64 = 0

    init(volume: FAT32Volume, deMac: Bool = false, report: Reporter? = nil) {
        self.volume = volume
        self.deMac = deMac
        self.report = report
    }

    func walk() throws(FATError) -> (root: FSObject, cleanup: MacCleanup) {
        let started = ContinuousClock.now
        let rootChain = try volume.chain(startingAt: volume.bpb.rootCluster)
        let root = FSObject(name: "", isDirectory: true, isRoot: true, chain: .list(rootChain))
        try populate(root)
        // A last set of totals, then the phase closing with what it cost. What either is worth saying
        // about is decided on the far side of the stream.
        reportScan()
        report?.post(.phaseCompleted(.scanning, elapsed: started.duration(to: .now)))
        let cleanup = MacCleanup(removals: removals,
                                 removedNames: removedNames,
                                 removedFiles: removedFiles,
                                 removedDirectories: removedDirectories,
                                 removedClusters: removedClusters,
                                 hiddenDots: hiddenDots)
        return (root, cleanup)
    }

    /// Where the scan has got to. Sent often, because on a card this is minutes of the run and a
    /// consumer that wants to say so should not have to guess at the pace.
    private func reportScan() {
        report?.update {
            $0.directoriesFound = directoriesSeen
            $0.filesFound = filesSeen
            $0.directoryBytesRead = bytesRead
        }
    }

    /// Parses the concatenated clusters of `directory` and attaches its children.
    private func populate(_ directory: FSObject) throws(FATError) {
        // Checked per directory, which is the granularity of the reads below. Nothing has been
        // written at this stage, so unwinding out of the scan leaves the volume untouched.
        if Interruption.requested { throw FATError.interrupted }

        let chain = directory.chain
        let bytes = try directoryBytes(of: chain)
        // Reported once per directory, which is exactly the pace of the reads above: the rest of
        // the parse is in memory, so this ticks along with the work actually being waited on. The
        // buffer's length is what was fetched, since a directory is read up to its end and no
        // further.
        bytesRead += UInt64(bytes.count)
        reportScan()

        // One borrowed window over the whole directory, sliced per entry rather than copied out of.
        // The parse used to lift every 32-byte entry into an array of its own, and every long-name
        // run into an array of those: on a volume of forty thousand files that is a hundred thousand
        // allocations to reach bytes already in hand. A span costs nothing to take and nothing to
        // slice, and the compiler will not let one outlive the buffer it borrows.
        let entries = bytes.span

        /// Where the long-name entries preceding a short entry sit, in the order they lie on disk.
        /// Offsets rather than copies of their bytes — which also retires the separate run-start
        /// variable this used to carry, because the first offset in the run *is* where the run starts.
        var pendingLFN: [Int] = []
        var i = 0
        while i + DirectoryEntry.size <= entries.count {
            let entryOffset = i
            let entry = entries.extracting(i ..< i + DirectoryEntry.size)
            i += DirectoryEntry.size

            let first = entry[0]
            if first == 0x00 { break }        // end of directory
            if first == 0xE5 {                // deleted: abandons any long name before it
                pendingLFN.removeAll(keepingCapacity: true)
                continue
            }
            let attr = entry[DirectoryEntry.attributesOffset]
            if attr == 0x0F {                 // long-name (LFN) component
                pendingLFN.append(entryOffset)
                continue
            }

            // A short entry closes any long-name run preceding it. `runStart` is the first
            // 32-byte slot the name occupies, which is what has to be erased to remove it.
            let runStart = pendingLFN.first ?? entryOffset
            let longName = Self.longName(from: pendingLFN, in: entries)
            pendingLFN.removeAll(keepingCapacity: true)

            if (attr & 0x08) != 0 {
                // The volume label is an entry in the root directory holding no clusters. It is the
                // name the system shows, and often better than the copy in the boot sector, so it is
                // worth saying that it was found.
                if directory.isRoot {
                    let label = Self.volumeLabel(entry)
                    if !label.isEmpty { report?.post(.labelled(label)) }
                }
                continue
            }

            let shortName = Self.shortName(entry)
            let entryStart = DirectoryEntry.firstCluster(in: entry,
                                                        at: DirectoryEntry.pointerFieldOffset)

            if shortName == ".." {
                directory.dotDotOffset = entryOffset
                directory.dotDotStart = entryStart
                recordHiddenDot(attr, chain: chain, at: entryOffset)
                continue
            }
            if shortName == "." {
                directory.dotOffset = entryOffset
                directory.dotStart = entryStart
                recordHiddenDot(attr, chain: chain, at: entryOffset)
                continue
            }

            let start = entryStart
            let isDir = (attr & 0x10) != 0

            // Match on the long name where there is one: `.DS_Store` and `._name` are not
            // legal 8.3 names, so on disk they carry a mangled short name plus LFN entries.
            let displayName = longName ?? shortName
            if deMac, MacCruft.matches(displayName, isRoot: directory.isRoot) {
                recordRemoval(chain: chain, from: runStart, through: entryOffset)
                removedNames.append(displayName)
                if isDir { removedDirectories += 1 } else { removedFiles += 1 }
                if start >= 2 {
                    removedClusters += try subtreeClusters(start: start, isDirectory: isDir)
                }
                continue
            }

            if start < 2 { continue }         // empty file: no clusters to relocate

            let objChain = ClusterSet.list(try volume.chain(startingAt: start))
            let object = FSObject(name: shortName,
                                  isDirectory: isDir,
                                  entryOffset: entryOffset,
                                  parent: directory,
                                  chain: objChain)
            if isDir { directoriesSeen += 1 } else { filesSeen += 1 }
            // Anything in pieces is certainly going to be moved, so it starts out marked as such;
            // the rest is left alone until the schedule says which of it has to shift, which is not
            // known until the planner has run.
            report?.post(.clusters(objChain, became: object.isContiguous ? .file : .displaced))
            // Also every so often within one directory, so a single huge one still shows movement.
            if (directoriesSeen + filesSeen) % 512 == 0 { reportScan() }

            if isDir {
                try populate(object)
            }
            directory.children.append(object)
        }
    }

    /// Notes a `.` or `..` entry that carries the hidden attribute, so `--deMac` can clear exactly
    /// those and no others. Collected here because the scan is already holding the bytes: the pass
    /// that applies it reads nothing, and on the usual volume — where none are hidden — there is
    /// nothing for it to do at all. Only gathered under `--deMac`, which is the only thing that
    /// acts on it.
    private func recordHiddenDot(_ attr: UInt8, chain: ClusterSet, at offset: Int) {
        guard deMac, (attr & 0x02) != 0 else { return }
        let index = offset / volume.clusterSize
        guard index < chain.count else { return }
        hiddenDots.append((cluster: chain[index], offset: offset % volume.clusterSize))
    }

    /// Marks every 32-byte slot from `from` through `through` for deletion, translating
    /// directory-relative offsets into the clusters that hold them. Entries never straddle a
    /// cluster boundary, since cluster sizes are multiples of 32.
    private func recordRemoval(chain: ClusterSet, from: Int, through: Int) {
        let clusterSize = volume.clusterSize
        var offset = from
        while offset <= through {
            let index = offset / clusterSize
            guard index < chain.count else { break }
            removals[chain[index], default: []].append(offset % clusterSize)
            offset += 32
        }
    }

    /// How much of a directory to fetch before looking for its end.
    ///
    /// A directory's entries are packed from the front and closed by an entry whose first byte is
    /// 0x00, and the parse stops there — so everything past that byte is transferred and discarded.
    /// It is nearly all of it. On a 32 GB card of 273,035 files in 41,651 directories the scan read
    /// 662 MiB of directory clusters to reach **43.9 MiB of live entries, 6.6%**: at 6.6 files each,
    /// a directory fills some 700 bytes of its 16 KiB cluster.
    ///
    /// 4096 rather than less, because it is the largest read the medium does not charge extra for.
    /// Measured on that card, replaying the scan's own offsets in its own order, a read costs
    /// 0.951 ms at 512 B and holds flat to 0.973 ms at 4 KiB — the per-command floor — then 1.401 ms
    /// at 8 KiB and 1.868 ms at 16 KiB. The 12 KiB a full cluster adds moves at 17.8 MB/s, which is
    /// the card's sequential rate, so those bytes are simply paid for. Coverage is what the extra
    /// room buys: 4 KiB ends 96.6% of directories against 91.6% at 2 KiB, and the 3.4% that need a
    /// second read cost nothing that the smaller probe would have saved.
    ///
    /// This is the mirror of the coalescing result in `Testing/README.md`, which merged nearby reads
    /// and lost: both follow from bytes being expensive next to commands on these controllers. That
    /// one offered more bytes for fewer commands; this one takes fewer bytes for the same commands.
    /// Worth little on the spinning drive, where a read is a 9.42 ms rotation and 16 KiB of payload
    /// is 0.4 ms of it — but the card is where this phase is 41,651 reads.
    private static let entryProbe = 4096

    /// Every cluster of a directory, concatenated, which is the shape its entries are parsed in: an
    /// entry never straddles a cluster boundary, but a long name's run of them can.
    ///
    /// Truncated at the first end-of-directory marker, so the usual small directory costs one short
    /// read rather than a whole cluster. Stopping is only safe *because* that marker is the stop
    /// condition: finding it means the entries genuinely end inside what was read, so no entry and
    /// no long-name run is ever cut in half. Where it does not appear the rest follows, and the
    /// result is byte-for-byte what reading the whole chain up front produced.
    private func directoryBytes(of chain: ClusterSet) throws(FATError) -> [UInt8] {
        guard let first = chain.first else { return [] }

        let clusterSize = volume.clusterSize
        let start = volume.offset(ofCluster: first)
        let probe = min(Self.entryProbe, clusterSize)

        var bytes = try volume.readBytes(at: start, count: probe)
        if Self.endOfDirectory(in: bytes) { return bytes }

        // No marker in the probe, so this is one of the large directories: take the remainder of its
        // first cluster and then the rest of the chain, leaving a buffer identical to the old one.
        bytes.reserveCapacity(chain.count * clusterSize)
        if probe < clusterSize {
            bytes += try volume.readBytes(at: start + UInt64(probe), count: clusterSize - probe)
        }
        for cluster in chain.dropFirst() {
            bytes += try volume.readCluster(cluster)
        }
        return bytes
    }

    /// Whether the end-of-directory marker falls inside `bytes` — an entry whose first byte is 0x00,
    /// which is what the parse breaks on. Entries sit on 32-byte boundaries and every read here is a
    /// multiple of that, so the stride never drifts out of step with them.
    private static func endOfDirectory(in bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset + DirectoryEntry.size <= bytes.count {
            if bytes[offset] == 0x00 { return true }
            offset += DirectoryEntry.size
        }
        return false
    }

    /// Clusters freed by removing an object: its own chain plus, for a directory, everything
    /// beneath it.
    private func subtreeClusters(start: UInt32, isDirectory: Bool) throws(FATError) -> [UInt32] {
        let chain = try volume.chain(startingAt: start)
        var total = chain
        guard isDirectory else { return total }

        let bytes = try directoryBytes(of: .list(chain))
        let entries = bytes.span
        var i = 0
        while i + DirectoryEntry.size <= entries.count {
            let entry = entries.extracting(i ..< i + DirectoryEntry.size)
            i += DirectoryEntry.size
            let first = entry[0]
            if first == 0x00 { break }
            if first == 0xE5 { continue }
            let attr = entry[DirectoryEntry.attributesOffset]
            if attr == 0x0F || (attr & 0x08) != 0 { continue }
            let name = Self.shortName(entry)
            if name == "." || name == ".." { continue }
            let childStart = DirectoryEntry.firstCluster(in: entry,
                                                        at: DirectoryEntry.pointerFieldOffset)
            if childStart < 2 { continue }
            total += try subtreeClusters(start: childStart, isDirectory: (attr & 0x10) != 0)
        }
        return total
    }

    /// Byte offsets of the 13 UCS-2 characters carried by one long-name entry.
    ///
    /// An `InlineArray`, because the count is part of the format rather than a runtime fact: thirteen
    /// is what a long-name entry holds, and this is stored in place instead of behind a heap
    /// allocation and a reference count nobody needs.
    private static let lfnCharOffsets: [13 of Int] = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]

    /// Reassembles a long file name from the offsets of its entries within `block`.
    ///
    /// LFN entries physically precede their short entry in reverse order — the chunk holding the
    /// start of the name sits closest to it — so the run is read back-to-front. Returns nil when
    /// there are no long-name entries.
    static func longName(from offsets: [Int], in block: Span<UInt8>) -> String? {
        guard !offsets.isEmpty else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(offsets.count * lfnCharOffsets.count)
        outer: for entry in offsets.reversed() {
            for index in lfnCharOffsets.indices {
                let unit = block.littleEndian(UInt16.self, at: entry + lfnCharOffsets[index])
                if unit == 0x0000 || unit == 0xFFFF { break outer }  // terminator / padding
                units.append(unit)
            }
        }
        return units.isEmpty ? nil : String(decoding: units, as: UTF16.self)
    }

    /// Decodes an 11-byte volume label. Unlike a short name it is one field rather than a name and
    /// an extension, and it may contain spaces, so only the trailing padding comes off.
    static func volumeLabel(_ entry: Span<UInt8>) -> String {
        entry.oemText(0 ..< 11).trimmingCharacters(in: .whitespaces)
    }

    /// Decodes an 8.3 short name from a directory entry into an uppercase "NAME.EXT" string.
    static func shortName(_ entry: Span<UInt8>) -> String {
        if entry[0] == 0x2E {
            return (entry.count > 1 && entry[1] == 0x2E) ? ".." : "."
        }

        /// The name up to its first padding space, read straight out of the entry. Where the
        /// leading byte is the escaped form of 0xE5 — which would otherwise read as "deleted" — the
        /// real character is substituted without disturbing the bytes on disk, which is what copying
        /// the field into a scratch array used to be for.
        func decode(_ range: Range<Int>) -> String {
            var end = range.lowerBound
            while end < range.upperBound, entry[end] != 0x20 { end += 1 }
            let text = entry.oemText(range.lowerBound ..< end)
            guard range.lowerBound == 0, entry[0] == 0x05, !text.isEmpty else { return text }
            return "\u{00E5}" + text.dropFirst()
        }

        let base = decode(0 ..< 8)
        let ext = decode(8 ..< 11)
        return ext.isEmpty ? base : "\(base).\(ext)"
    }
}
