import Foundation

// MARK: - Little-endian byte access

/// A FAT volume is little-endian integers at fixed offsets, and this is the one place that knows
/// how to reach them.
///
/// Defined over `Span` rather than over `Array`, which is the whole of the difference. A span is a
/// borrowed window onto bytes somebody else owns, so a directory entry, a boot sector and a block of
/// FAT are all one thing to these accessors: a range inside a buffer that was read as a piece. The
/// array-based helpers this replaces could only be reached by *having* an array, which forced a
/// decision at every one of those points about whether to copy the enclosing bytes into one first —
/// and the directory parse used to answer yes once per entry, tens of thousands of times a scan.
/// The `Array` overloads at the end are the same accessors reached through the array's own span,
/// for the places that really do own their buffer.
///
/// The width is a type parameter rather than two hand-written functions per direction, which takes
/// the shift-and-mask ladders with it: `T(littleEndian:)` is what these were always spelling out.
extension Span where Element == UInt8 {
    /// The little-endian `T` at `offset`.
    ///
    /// Unaligned by construction. Nothing on a FAT volume promises a 32-bit field sits on a
    /// four-byte boundary, and some of them promise the opposite — a directory entry's first-cluster
    /// number is two 16-bit halves with the timestamps in between.
    func littleEndian<T: FixedWidthInteger & BitwiseCopyable>(_: T.Type, at offset: Int) -> T {
        T(littleEndian: bytes.unsafeLoadUnaligned(fromByteOffset: offset, as: T.self))
    }

    /// A fixed-width name field, as text.
    ///
    /// FAT holds names in an OEM code page, and every byte becomes the Unicode scalar of the same
    /// value — which is Latin-1, and is exactly what the three separate copies of this loop did
    /// before. Kept deliberately rather than improved upon: guessing at a code page would rename
    /// files, and these names are only ever reported, never written back.
    func oemText(_ range: Range<Int>) -> String {
        var text = ""
        text.reserveCapacity(range.count)
        for offset in range { text.append(Character(UnicodeScalar(self[offset]))) }
        return text
    }
}

extension MutableSpan where Element == UInt8 {
    /// Writes `value` little-endian at `offset`.
    mutating func setLittleEndian<T: FixedWidthInteger & BitwiseCopyable>(_ value: T, at offset: Int) {
        var raw = mutableBytes
        raw.setLittleEndian(value, at: offset)
    }
}

extension MutableRawSpan {
    /// Writes `value` little-endian at `offset`. For bytes held as raw memory rather than as a typed
    /// array — the copy buffer, whose whole point is never to become one.
    mutating func setLittleEndian<T: FixedWidthInteger & BitwiseCopyable>(_ value: T, at offset: Int) {
        storeBytes(of: value.littleEndian, toByteOffset: offset, as: T.self)
    }
}

extension Array where Element == UInt8 {
    func littleEndian<T: FixedWidthInteger & BitwiseCopyable>(_ type: T.Type, at offset: Int) -> T {
        span.littleEndian(type, at: offset)
    }

    mutating func setLittleEndian<T: FixedWidthInteger & BitwiseCopyable>(_ value: T, at offset: Int) {
        var window = mutableSpan
        window.setLittleEndian(value, at: offset)
    }
}

// MARK: - Errors

enum FATError: Error, CustomStringConvertible {
    case notFAT(String)
    case io(String)
    case corruption(String)
    case capacity(String)
    /// Ctrl-C during a stage that has not written anything, where unwinding is the tidy ending in
    /// itself. Once writing has begun the run stops through `Interruption` instead, so that it can
    /// still bring the volume up to date on the way out.
    case interrupted

    var description: String {
        switch self {
        case .notFAT(let m): return "Not a FAT volume: \(m)"
        case .io(let m): return "I/O error: \(m)"
        case .corruption(let m): return "Filesystem corruption: \(m)"
        case .capacity(let m): return "Capacity error: \(m)"
        case .interrupted: return "Interrupted."
        }
    }
}

// MARK: - Which of the three

/// Which FAT variant a volume is, and everything that follows from it.
///
/// Exactly two things differ between the three, and this carries the first: how wide a table entry
/// is, and therefore which values at the top of its range mean end-of-chain and bad. The second is
/// whether the root directory is a relocatable chain or a fixed region outside the cluster space —
/// `hasRelocatableRoot` here, and `FATVolume.RootLocation` in full.
///
/// Nothing above the format layer is touched by either. The planners, the copy batching and the
/// staging work on cluster numbers held as `UInt32` and on `ClusterSet`, and a cluster number is a
/// cluster number whatever it took to read one off the medium. The safety argument is likewise
/// untouched, because it is about the order writes reach the disk and not about their encoding.
enum FATFlavour: Sendable {
    case fat12, fat16, fat32

    /// The bits of a table entry that carry a cluster number. FAT32 spends 28 of its 32 on it; the
    /// other two spend all of theirs.
    var entryMask: UInt32 {
        switch self {
        case .fat12: 0x0000_0FFF
        case .fat16: 0x0000_FFFF
        case .fat32: 0x0FFF_FFFF
        }
    }

    /// The end-of-chain marker this tool writes — all ones, which is what formatters use and what
    /// the reserved range at the top is defined downwards from.
    var eoc: UInt32 { entryMask }

    /// Entries at or above this end a chain. A range and not a single value, because the marker a
    /// volume arrives carrying need not be the one we would have written.
    var eocThreshold: UInt32 { entryMask & ~UInt32(7) }

    /// The marker for a cluster the medium has failed on. Never read, written or allocated: the
    /// layout goes around these and the rebuilt table re-marks them.
    var badCluster: UInt32 { entryMask - 8 }

    /// The three derive from `entryMask` rather than being written out per case, which is the fact
    /// they express: the reserved values are the top eight of whatever range the entry width gives.
    /// Their own definition also guarantees they cannot collide with a real cluster number, since
    /// each variant's cluster-count ceiling sits below its reserved range — FAT16 stops at 65,524
    /// clusters, so the highest cluster number it can name is 0xFFF5.

    var name: String {
        switch self {
        case .fat12: "FAT12"
        case .fat16: "FAT16"
        case .fat32: "FAT32"
        }
    }

    /// Whether the root directory is an ordinary relocatable chain.
    ///
    /// FAT32's root is a file like any other directory's, which is what lets this tool place it on
    /// the first usable cluster. FAT12 and FAT16 keep theirs in a fixed region between the last
    /// table and the first data cluster — outside the cluster space, so there is no chain to
    /// relocate, nothing anywhere pointing at it, and a hard ceiling on how many entries it holds.
    var hasRelocatableRoot: Bool { self == .fat32 }

    /// Bytes per entry, where an entry occupies a whole number of them.
    ///
    /// Nil for FAT12, whose twelve-bit entries share a byte with a neighbour. That is not a detail
    /// that can be papered over: it is why the block-grouped FAT write path cannot express FAT12 and
    /// why `SafeDefragmenter.writeFATEntries` sends it down a different one.
    var wholeEntrySize: Int? {
        switch self {
        case .fat12: nil
        case .fat16: 2
        case .fat32: 4
        }
    }

    /// Where cluster `cluster`'s entry begins in the table, and how much has to be touched to change
    /// it. Two bytes for FAT12, because twelve bits cannot be addressed on their own.
    func byteRange(ofCluster cluster: UInt32) -> Range<Int> {
        switch self {
        case .fat12:
            // Three halves of a byte each, which is `cluster + cluster / 2` — the same value as
            // 3 * cluster / 2 and with no doubling on the way to it.
            let at = Int(cluster) + Int(cluster) / 2
            return at ..< at + 2
        case .fat16:
            return Int(cluster) * 2 ..< Int(cluster) * 2 + 2
        case .fat32:
            return Int(cluster) * 4 ..< Int(cluster) * 4 + 4
        }
    }

    /// The entry for `cluster`, out of a table held as raw bytes.
    func entry(forCluster cluster: UInt32, in table: Span<UInt8>) -> UInt32 {
        let at = byteRange(ofCluster: cluster).lowerBound
        switch self {
        case .fat12:
            // The pair of bytes holds this entry and half of a neighbour's. An even cluster takes
            // the low twelve bits, an odd one the high twelve.
            let pair = UInt32(table.littleEndian(UInt16.self, at: at))
            return (cluster.isMultiple(of: 2) ? pair : pair >> 4) & entryMask
        case .fat16:
            return UInt32(table.littleEndian(UInt16.self, at: at))
        case .fat32:
            return table.littleEndian(UInt32.self, at: at) & entryMask
        }
    }

    /// Writes `value` as `cluster`'s entry.
    ///
    /// FAT12 reads before it writes, because the half of the byte pair belonging to the neighbouring
    /// entry has to be carried through untouched. The other two overwrite their whole width — which
    /// for FAT32 means the top four bits go out as zero, exactly as they always have.
    func setEntry(_ value: UInt32, forCluster cluster: UInt32, in table: inout MutableSpan<UInt8>) {
        let at = byteRange(ofCluster: cluster).lowerBound
        switch self {
        case .fat12:
            let pair = UInt16(table[at]) | (UInt16(table[at + 1]) << 8)
            let twelve = UInt16(value & 0x0FFF)
            let merged = cluster.isMultiple(of: 2) ? (pair & 0xF000) | twelve
                                                   : (pair & 0x000F) | (twelve << 4)
            table[at] = UInt8(truncatingIfNeeded: merged)
            table[at + 1] = UInt8(truncatingIfNeeded: merged >> 8)
        case .fat16:
            table.setLittleEndian(UInt16(truncatingIfNeeded: value), at: at)
        case .fat32:
            table.setLittleEndian(value, at: at)
        }
    }

    /// The clean-shutdown bit within table entry 1, or nil where there is nowhere to put one.
    ///
    /// FAT12 is the nil. Twelve bits leave no room for it, so on a FAT12 volume the boot record's
    /// flag is the whole of the "this volume was being modified" signal — a real reduction in what
    /// an interruption leaves behind for the operating system to notice, and not an omission here.
    var cleanShutdownBit: UInt32? {
        switch self {
        case .fat12: nil
        case .fat16: 0x0000_8000
        case .fat32: 0x0800_0000
        }
    }

    /// Offset of the boot record's dirty flag, and of its 11-byte volume label. Both are the same
    /// field of each variant's extended BPB; they land in different places only because FAT32's BPB
    /// is the longer one.
    var bootDirtyFlagOffset: UInt64 { self == .fat32 ? 65 : 37 }
    var labelOffset: Int { self == .fat32 ? 71 : 43 }
}

// MARK: - BIOS Parameter Block

/// The subset of boot-sector (BPB) fields this tool needs, across all three variants.
///
/// The order things are worked out in is the order the format itself requires, and it is the whole
/// reason this is one initialiser rather than a list of assignments. Offsets 36 and upwards mean
/// different things in different variants — on FAT12/16 they are the drive number, the boot
/// signature and the volume ID, which read as geometry would be nonsense — so the variant has to be
/// settled before any of them is touched. It can be: classifying a volume needs only the fields
/// common to all three, and the cluster count they yield.
struct BPB {
    let bytesPerSector: Int      // offset 11, u16
    let sectorsPerCluster: Int   // offset 13, u8
    let reservedSectorCount: Int // offset 14, u16
    let numFATs: Int             // offset 16, u8
    let rootEntCnt: Int          // offset 17, u16 (0 for FAT32)
    /// Sectors per FAT: offset 22 where that is non-zero, offset 36 otherwise. The two are
    /// exclusive by construction — a FAT32 volume writes 0 to the 16-bit field precisely so that a
    /// reader is forced to come to the 32-bit one.
    let fatSize: Int
    let totalSectors: UInt32     // offset 19 (u16) or offset 32 (u32)
    /// Sectors the fixed root directory occupies; 0 on FAT32, whose root is a chain in the data area
    /// like any other directory's. It sits between the last table and the first data cluster, so it
    /// displaces the whole data region — the one piece of geometry FAT32 never has to account for.
    let rootDirSectors: Int
    let countOfClusters: UInt32
    let flavour: FATFlavour

    // FAT32 only, and zero elsewhere, because on FAT12/16 these offsets carry other fields entirely.
    let extFlags: UInt16         // offset 40, u16
    let rootCluster: UInt32      // offset 44, u32
    let fsInfoSector: Int        // offset 48, u16
    let backupBootSector: Int    // offset 50, u16

    init(bootSector boot: Span<UInt8>) throws(FATError) {
        bytesPerSector = Int(boot.littleEndian(UInt16.self, at: 11))
        sectorsPerCluster = Int(boot[13])
        reservedSectorCount = Int(boot.littleEndian(UInt16.self, at: 14))
        numFATs = Int(boot[16])
        rootEntCnt = Int(boot.littleEndian(UInt16.self, at: 17))

        guard bytesPerSector == 512 || bytesPerSector == 1024
            || bytesPerSector == 2048 || bytesPerSector == 4096 else {
            throw FATError.notFAT("unexpected bytes-per-sector \(bytesPerSector)")
        }

        let fatSize16 = Int(boot.littleEndian(UInt16.self, at: 22))
        fatSize = fatSize16 != 0 ? fatSize16 : Int(boot.littleEndian(UInt32.self, at: 36))
        let totSec16 = boot.littleEndian(UInt16.self, at: 19)
        totalSectors = totSec16 != 0 ? UInt32(totSec16) : boot.littleEndian(UInt32.self, at: 32)

        guard sectorsPerCluster > 0, numFATs > 0, fatSize > 0, totalSectors > 0 else {
            throw FATError.notFAT("invalid BPB geometry")
        }

        // Rounded up: a root of 512 entries is 16 KiB, which need not be a whole number of sectors
        // on a volume with large ones. Zero on FAT32, where `rootEntCnt` is zero — which is what
        // makes every line below a strict generalisation of the FAT32-only arithmetic it replaces
        // rather than a change to it, and so what lets a FAT32 run come out byte-identical.
        rootDirSectors = ((rootEntCnt * DirectoryEntry.size) + bytesPerSector - 1) / bytesPerSector

        let firstDataSector = reservedSectorCount + numFATs * fatSize + rootDirSectors
        guard Int(totalSectors) > firstDataSector else { throw FATError.notFAT("no data region") }
        countOfClusters = UInt32((Int(totalSectors) - firstDataSector) / sectorsPerCluster)

        // The definition, and the only one there is: which variant a volume is follows from how many
        // data clusters it has and from nothing else. Not from the filesystem-type string in the
        // boot record, which is a comment and is routinely wrong, and not from the size of the
        // medium.
        flavour = switch countOfClusters {
        case 0 ..< 4085: .fat12
        case 4085 ..< 65525: .fat16
        default: .fat32
        }

        guard countOfClusters >= 1 else { throw FATError.notFAT("no clusters") }

        if flavour == .fat32 {
            extFlags = boot.littleEndian(UInt16.self, at: 40)
            rootCluster = boot.littleEndian(UInt32.self, at: 44)
            fsInfoSector = Int(boot.littleEndian(UInt16.self, at: 48))
            backupBootSector = Int(boot.littleEndian(UInt16.self, at: 50))
            // A cluster count in FAT32 territory but a FAT12/16 root or table size is not a variant
            // this can classify — it is a damaged or hand-built boot record, and guessing which half
            // to believe would mean reading the volume through the wrong geometry.
            guard rootEntCnt == 0, fatSize16 == 0 else {
                throw FATError.notFAT("\(countOfClusters) clusters is FAT32, but the boot record "
                    + "also claims a \(rootEntCnt)-entry fixed root and a 16-bit FAT size")
            }
            guard rootCluster >= 2, rootCluster <= countOfClusters + 1 else {
                throw FATError.notFAT("root cluster \(rootCluster) is outside the data region")
            }
        } else {
            extFlags = 0
            rootCluster = 0
            fsInfoSector = 0
            backupBootSector = 0
            // The fixed root is the only way in to a FAT12/16 volume, so a volume claiming none of
            // it has nothing this tool can walk.
            guard rootEntCnt > 0 else {
                throw FATError.notFAT("\(flavour.name) volume with no root directory entries")
            }
        }
    }
}

// MARK: - Sets of clusters

/// Some clusters, held as whatever shape they actually are.
///
/// Nearly everything this tool names is contiguous by construction — an object's home, the span a
/// transfer covered, a chain that has just been laid out in one piece — and all of it used to be
/// spelled `Array(start ..< start + count)`: an allocation and a fill to state what two numbers had
/// already stated, once per relocation and once per transfer, tens of thousands of times a run. What is
/// not contiguous genuinely is not — a fragmented chain, clusters staged wherever there was room, the
/// bad list — so both shapes are cases here rather than one being made to imitate the other.
///
/// One type with two representations, and not two event cases: the vocabulary the engine speaks is
/// meant to stay small, and "which clusters" is one fact however they happen to be laid out. Being a
/// `RandomAccessCollection` is what makes that affordable — counting them, walking them, indexing
/// them, pairing two off against each other all read exactly as they did when this was an array.
enum ClusterSet: RandomAccessCollection, Sendable, Equatable {
    /// A contiguous run, which is the common case and costs nothing to describe.
    case run(Range<UInt32>)
    /// Clusters with gaps in them, which have to be listed.
    case list([UInt32])

    var startIndex: Int { 0 }

    var endIndex: Int {
        switch self {
        case .run(let range): Int(range.count)
        case .list(let list): list.count
        }
    }

    subscript(position: Int) -> UInt32 {
        switch self {
        case .run(let range): range.lowerBound + UInt32(position)
        case .list(let list): list[position]
        }
    }

    /// The `count` clusters from `start`.
    static func run(from start: UInt32, count: UInt32) -> ClusterSet {
        .run(start ..< start + count)
    }

    /// Number of separate runs these clusters occupy; 1 means contiguous, 0 means there are none.
    ///
    /// Free for a run, which is most of what a finished layout is made of — the whole point of a
    /// compacted volume is that the answer is one, and it no longer takes a walk to find that out.
    var extentCount: Int {
        switch self {
        case .run(let range):
            range.isEmpty ? 0 : 1
        case .list(let list):
            list.isEmpty ? 0 : 1 + list.indices.dropFirst().count { list[$0] != list[$0 - 1] + 1 }
        }
    }

    var isContiguous: Bool { extentCount <= 1 }
}

extension ClusterSet: ExpressibleByArrayLiteral {
    /// So that the handful of one- and two-cluster literals the engine reports read as they always did.
    init(arrayLiteral elements: UInt32...) {
        self = .list(elements)
    }
}

// MARK: - Directory entries

/// The layout of a 32-byte directory entry, as far as anything here needs it.
///
/// This exists for one field. A file's first-cluster number is stored as two 16-bit halves at +20 and
/// +26, with the entry's creation and access timestamps sitting between them, and that split used to
/// be written out by hand at the five places that read it and the three that write it — each of them
/// repeating the same `(hi << 16) | lo` and the same pair of magic offsets. Stating it once is the
/// difference between a fact about the format and a habit.
///
/// The offset naming a *pointer field* is the offset of its high half, and the eight bytes from there
/// are treated as one unit throughout: it is the smallest window a pointer update can
/// read-modify-write, which is why the halves are never touched separately.
enum DirectoryEntry {
    static let size = 32
    /// Where the pointer field starts within an entry.
    static let pointerFieldOffset = 20
    /// Its width, timestamps included.
    static let pointerFieldSize = 8
    /// The attribute byte.
    static let attributesOffset = 11

    /// The first-cluster number named by the pointer field at `offset`.
    static func firstCluster(in bytes: Span<UInt8>, at offset: Int) -> UInt32 {
        (UInt32(bytes.littleEndian(UInt16.self, at: offset)) << 16)
            | UInt32(bytes.littleEndian(UInt16.self, at: offset + 6))
    }

    static func firstCluster(in bytes: [UInt8], at offset: Int) -> UInt32 {
        firstCluster(in: bytes.span, at: offset)
    }

    /// Points the pointer field at `offset` at `cluster`.
    ///
    /// The high half is a checked conversion, which is the assertion it looks like: a cluster number
    /// is 28 bits, so anything that does not fit in the twelve bits above the low half is not a
    /// cluster number and should not be quietly written as one.
    static func setFirstCluster(_ cluster: UInt32, in bytes: inout MutableSpan<UInt8>, at offset: Int) {
        bytes.setLittleEndian(UInt16(cluster >> 16), at: offset)
        bytes.setLittleEndian(UInt16(truncatingIfNeeded: cluster), at: offset + 6)
    }

    static func setFirstCluster(_ cluster: UInt32, in bytes: inout MutableRawSpan, at offset: Int) {
        bytes.setLittleEndian(UInt16(cluster >> 16), at: offset)
        bytes.setLittleEndian(UInt16(truncatingIfNeeded: cluster), at: offset + 6)
    }

    static func setFirstCluster(_ cluster: UInt32, in bytes: inout [UInt8], at offset: Int) {
        var window = bytes.mutableSpan
        setFirstCluster(cluster, in: &window, at: offset)
    }
}

// MARK: - Volume (read-write)

/// Owns an open file descriptor and closes it exactly once.
///
/// Noncopyable, which makes the compiler enforce what a comment would otherwise have to ask for:
/// there is exactly one owner, the descriptor cannot be copied somewhere that would close it a second
/// time, and it cannot outlive the volume holding it. A double close is not a harmless mistake on a
/// tool that writes to raw devices — the number could have been reused by then.
///
/// The `deinit` also covers the path this exists for. `FATVolume.init` has half a dozen ways to
/// throw after the volume is open, and a class deinitialiser does not run for an object whose
/// initialisation never completed, so a `deinit` on the volume itself would leak the descriptor on
/// every one of them. A stored noncopyable property is destroyed on that path regardless. Verified
/// rather than assumed: a class initialiser made to throw immediately after storing one of these
/// still runs this.
private struct OpenDescriptor: ~Copyable {
    let raw: Int32
    init(_ raw: Int32) { self.raw = raw }
    deinit { close(raw) }
}

/// A read-write view over a FAT12, FAT16 or FAT32 partition (device node or image file). The volume
/// is opened for updating so the defragmenter can relocate clusters in place; callers are
/// responsible for ensuring the volume is unmounted before mutating it.
final class FATVolume {
    /// Where the root directory's entries live.
    ///
    /// On FAT32 the root is a file like any other directory, so this is a first cluster and the
    /// defragmenter treats the root as one more object to place — on the lowest cluster, in fact.
    /// On FAT12 and FAT16 it is a fixed region between the last table and the first data cluster:
    /// outside the cluster space, so nothing anywhere points at it, nothing can relocate it, and it
    /// holds exactly as many entries as it was formatted with, for ever.
    ///
    /// A case each rather than one being made to imitate the other. Representing the fixed region as
    /// a pretend chain would put numbers in `ClusterSet`s that are not cluster numbers, and every
    /// piece of arithmetic downstream would be one mistake away from writing over the data area.
    enum RootLocation: Sendable, Equatable {
        case chain(UInt32)
        case region(offset: UInt64, size: Int)
    }

    private let file: OpenDescriptor
    /// The descriptor every transfer goes through. `pread`/`pwrite` carry their own offset, so there
    /// is no shared seek position and nothing to keep in step.
    private var descriptor: Int32 { file.raw }
    /// Granularity the device demands of every read and write. Raw character devices
    /// (/dev/rdiskN) reject anything that is not a whole number of blocks at a block-aligned
    /// offset; buffered nodes (/dev/diskN) and plain image files do not care. All byte-level
    /// access below is widened to this and sliced back down.
    let blockSize: Int
    let bpb: BPB
    let clusterSize: Int
    let countOfClusters: UInt32
    let fatStartOffset: UInt64
    let dataStartOffset: UInt64
    let activeFatIndex: Int
    /// Which of the three this is. Everything width-dependent goes through it.
    let flavour: FATFlavour
    let rootLocation: RootLocation
    /// Bytes one copy of the table occupies, which is where the next copy begins.
    let fatByteCount: Int

    /// The active FAT decoded into one entry per cluster, widened to `UInt32` whatever its on-disk
    /// width, and indexed by cluster number.
    let fat: [UInt32]
    /// The raw bytes of reserved entries 0 and 1, preserved verbatim — three on FAT12, four on
    /// FAT16, eight on FAT32. Entry 0 holds a copy of the media descriptor and entry 1 the
    /// clean-shutdown flag, neither of which this tool has any business deciding, so where a write
    /// path has to reproduce the head of the table it reproduces these rather than re-encoding them.
    let fatReservedBytes: [UInt8]
    /// Clusters the FAT marks as bad. These are never read, written, or allocated: the
    /// defragmenter lays out around them and re-marks them in the rebuilt FAT.
    let badClusters: Set<UInt32>
    /// The volume label as the boot sector carries it, empty where there is none. Only used to name
    /// the volume in reports — the copy in the root directory is the one the system shows, and the
    /// scan picks that up if it finds it.
    let label: String

    /// When set, nothing reaches the medium: the volume is opened read-only and every write is
    /// discarded, while reads happen as usual so a run still walks the tree, works out the whole
    /// schedule, and reports what it would have done. Every mutation funnels through the five
    /// entry points below, so gating them here is the whole of it — and opening read-only means
    /// a missed one cannot write anyway, it fails.
    let dryRun: Bool

    init(path: String, dryRun: Bool = false) throws(FATError) {
        self.dryRun = dryRun
        // Opened through open(2) rather than one of FileHandle's path initialisers so that the
        // reason for a failure survives. A disk device refuses for a handful of very different
        // reasons, each wanting a different response from whoever ran this, and FileHandle
        // reports all of them as nil.
        let opened = open(path, dryRun ? O_RDONLY : O_RDWR)
        guard opened >= 0 else {
            throw FATError.io(FATVolume.openFailure(path: path, code: errno, dryRun: dryRun))
        }
        self.file = OpenDescriptor(opened)
        self.caches = System.isUncached(opened)

        let blockSize = FATVolume.probeBlockSize(opened)
        self.blockSize = blockSize

        // Boot sector lives at offset 0. Read a generous 512 bytes first to learn the
        // sector size, which is enough for every BPB field we touch.
        let boot = try FATVolume.read(opened, blockSize: blockSize, at: 0, count: 512)
        // Geometry, and which of the three this is, are settled together: the classification follows
        // from the cluster count and the cluster count follows from the geometry, so neither can be
        // had without the other. Everything that used to be checked out here is checked in there.
        let bpb = try BPB(bootSector: boot.span)
        self.bpb = bpb
        let flavour = bpb.flavour
        self.flavour = flavour

        clusterSize = bpb.bytesPerSector * bpb.sectorsPerCluster
        countOfClusters = bpb.countOfClusters

        // BS_VolLab: 11 bytes, space-padded, and unlike a short name it may contain spaces, so only
        // the trailing padding comes off. "NO NAME" is what a formatter writes when asked for
        // nothing, and is no more use than an empty string.
        let rawLabel = boot.span.oemText(flavour.labelOffset ..< flavour.labelOffset + 11)
            .trimmingCharacters(in: .whitespaces)
        label = rawLabel == "NO NAME" ? "" : rawLabel

        let fatSectors = bpb.numFATs * bpb.fatSize
        fatStartOffset = UInt64(bpb.reservedSectorCount) * UInt64(bpb.bytesPerSector)
        // The fixed root sits between the last table and the first data cluster, so it pushes the
        // data region down by its own length. On FAT32 `rootDirSectors` is zero and this is the same
        // arithmetic it always was.
        let rootRegionStart = UInt64(bpb.reservedSectorCount + fatSectors) * UInt64(bpb.bytesPerSector)
        dataStartOffset = rootRegionStart + UInt64(bpb.rootDirSectors) * UInt64(bpb.bytesPerSector)

        rootLocation = switch flavour {
        case .fat32: .chain(bpb.rootCluster)
        case .fat12, .fat16: .region(offset: rootRegionStart,
                                     size: bpb.rootEntCnt * DirectoryEntry.size)
        }

        // Respect mirroring flags to pick which physical FAT is authoritative. FAT32 only: the other
        // two have no such flag, always keep every copy in step, and so are read from the first.
        let mirroringDisabled = flavour == .fat32 && (bpb.extFlags & 0x0080) != 0
        activeFatIndex = mirroringDisabled ? Int(bpb.extFlags & 0x000F) : 0

        let fatByteCount = bpb.fatSize * bpb.bytesPerSector
        self.fatByteCount = fatByteCount
        let entriesNeeded = Int(bpb.countOfClusters) + 2
        // A table too small to hold the entries its own geometry implies cannot be read at all —
        // and reading it anyway would run off the end of the buffer, which under `-Ounchecked` is
        // not a trap but a wrong answer.
        let bytesNeeded = flavour.byteRange(ofCluster: UInt32(entriesNeeded - 1)).upperBound
        guard bytesNeeded <= fatByteCount else {
            throw FATError.notFAT("\(flavour.name) table of \(fatByteCount) bytes is too small "
                + "for the \(entriesNeeded) entries \(bpb.countOfClusters) clusters need")
        }

        let fatRaw = try FATVolume.read(opened,
                                          blockSize: blockSize,
                                          at: fatStartOffset + UInt64(activeFatIndex * fatByteCount),
                                          count: fatByteCount)
        // Decoded through one borrowed window over the bytes just read, rather than a bounds-checked
        // array subscript per byte: a 32 GB card's FAT is two million entries, and this is the first
        // thing a run does.
        var decoded = [UInt32](repeating: 0, count: entriesNeeded)
        do {
            let table = fatRaw.span
            var entries = decoded.mutableSpan
            for index in 0 ..< entriesNeeded {
                entries[index] = flavour.entry(forCluster: UInt32(index), in: table)
            }
        }
        fat = decoded
        fatReservedBytes = Array(fatRaw[0 ..< flavour.byteRange(ofCluster: 2).lowerBound])

        var bad = Set<UInt32>()
        for c in 2 ..< entriesNeeded where decoded[c] == flavour.badCluster {
            bad.insert(UInt32(c))
        }
        badClusters = bad
    }

    /// Explains why a device would not open, and what to do about it.
    ///
    /// Worth the detail because the honest answer to the commonest failure is "you cannot do this
    /// from here at all": disk devices are `root:operator` mode 0640, so an ordinary user cannot
    /// open one, and nothing this process can call will change that — the privilege has to come
    /// from outside it. Read access is the lesser ask, and the `operator` group carries it, which
    /// is enough for a dry run.
    private static func openFailure(path: String, code: Int32, dryRun: Bool) -> String {
        let reason = strerror(code).map { String(cString: $0) } ?? "error \(code)"
        var message = "cannot open volume '\(path)' for "
            + (dryRun ? "reading" : "reading and writing") + ": \(reason)"
        switch code {
        case EACCES, EPERM:
            // Already root and still refused: sudo is not the answer, so do not suggest it.
            if geteuid() != 0 {
                message += ". Disk devices belong to root, so re-run this under sudo"
                if dryRun {
                    message += " — or, for read-only access, add yourself to the 'operator' group "
                        + "(sudo dseditgroup -o edit -a $USER -t user operator), which is enough "
                        + "for a dry run"
                }
                message += "."
            }
        case EBUSY:
            message += ". Something else holds the device — most likely a volume still mounted "
                + "from it, which the mount check reports in detail."
        case ENOENT:
            message += ". Check the device node is still there; it changes when the card is "
                + "reinserted."
        default:
            break
        }
        return message
    }

    // MARK: Geometry

    func offset(ofCluster cluster: UInt32) -> UInt64 {
        dataStartOffset + UInt64(cluster - 2) * UInt64(clusterSize)
    }

    /// The inverse, for reporting: which cluster an offset in the data region belongs to.
    func cluster(atOffset offset: UInt64) -> UInt32 {
        guard offset >= dataStartOffset else { return 2 }
        return UInt32((offset - dataStartOffset) / UInt64(clusterSize)) + 2
    }

    // MARK: - The device cache

    /// What a transfer is for, which is the only thing that decides whether it is worth remembering.
    private enum Traffic {
        /// Directory blocks, FAT entries, the boot record. Small, and revisited constantly: the same
        /// parent directories are patched generation after generation, and the scan has already read
        /// every one of them before the first patch lands.
        case metadata
        /// Data parked in spare space to break a deadlock. Bulk by size and metadata by behaviour:
        /// it is written for no reason other than to be read back and written again, so it is the one
        /// kind of file content certain to be wanted twice. On a volume with room to spare that is
        /// not a rare case — a 44%-full card parks 628 objects, and reads back 25 MiB.
        case staged
        /// A directory's own data, on its way to its final home. Bulk by size and metadata by
        /// behaviour, for the same reason `staged` is: once it lands, every child's `..` patch, every
        /// dot-entry check and every later pointer flip reads it again. Measured, the scan's copy of a
        /// directory served 1,438 hits to the copy phase *before* it moved, and then the copy that
        /// put it in its new home was not kept, so every one of those reads missed afterwards.
        case directory
        /// File contents on the way to a final home: read once, written once, more than a gigabyte of
        /// it in a run. Never stored, or it would evict the metadata many times over to serve a hit
        /// that is not coming. Writes still invalidate, because a data cluster can land where a
        /// directory block used to be — and reads still *consult* what is stored, which costs one
        /// failed lookup and is what lets a staged object be served from memory on the way back
        /// without the read side having to know anything about staging.
        case bulk

        /// Whether what passes through is worth keeping.
        var isRetained: Bool { self != .bulk }
    }

    /// Why a bulk transfer might be worth remembering once it has gone out.
    ///
    /// The caller knows things the volume cannot see: that these bytes are only being parked, or that
    /// they are a directory and will be read again within the minute. Both are file content by size and
    /// neither behaves like it.
    enum Retention: Sendable, Equatable {
        /// Read once, written once. The gigabyte.
        case fileData
        /// Parked in spare space, which is the only reason it was written at all.
        case staged
        /// A directory's own clusters.
        case directory
    }

    private func traffic(for retention: Retention) -> Traffic {
        switch retention {
        case .fileData: .bulk
        case .staged: .staged
        case .directory: .directory
        }
    }

    /// Block-aligned device content, keyed by offset, so a read the run has already paid for is not
    /// paid for again.
    ///
    /// This is where going direct to the medium earns its cost back. With no page cache underneath,
    /// every re-read is a real transfer: repointing alone asked the drive for 4,858 runs of directory
    /// blocks the scan had read minutes earlier, around 45 seconds of a seven-minute run.
    ///
    /// Correctness rests on a single property, which `deviceRead` and `deviceWrite` make structural
    /// rather than a matter of remembering: **every** transfer to or from the medium goes through those
    /// two, and a write always drops what is cached for the blocks it lands on before optionally
    /// putting back what it wrote. A block kept past the point where its cluster stopped belonging to
    /// a directory would otherwise be handed to a later reader as though it were still live. The
    /// previous arrangement kept the same invariant by hand across four call sites and said so, with a
    /// note warning about the fifth.
    ///
    /// Devices only. Against an image file the kernel is already doing this and doing it better, and
    /// the second copy is not free — measured at 8m 2s with it against 7m 56s without.
    private let caches: Bool

    /// One block, and what it was kept for.
    ///
    /// The flag is not bookkeeping for its own sake. Staged data is the one kind of file content that is
    /// certain to be wanted twice, and the read that wants it arrives as ordinary bulk traffic with
    /// nothing to say about where it came from — so without this the design's central claim, that a
    /// parked object is fetched back out of memory, cannot be checked at all.
    private struct CacheEntry {
        let bytes: [UInt8]
        let staged: Bool
    }

    private var cache: [UInt64: CacheEntry] = [:]
    private var cachedBytes = 0

    /// What the cache actually did.
    ///
    /// It is a pure optimisation, which is exactly why it needs counting: nothing fails when it stops
    /// working, and nothing says so either. A cache that quietly stopped admitting halfway through a run
    /// would look like a slow medium.
    struct Report: Sendable {
        /// Looks and hits, split by what the read was for, because one overall hit rate is not a
        /// meaningful number here. Bulk reads consult the cache and are meant to miss — a gigabyte of
        /// file content is read once — so counting them alongside metadata buries the figure that
        /// matters. Metadata is where a hit is the difference between memory and a rotation.
        var metadataHits = 0
        var metadataMisses = 0
        var bulkHits = 0
        var bulkMisses = 0
        var bytesServed = 0
        /// Hits on data parked in spare space — the one read the staging design exists to make free.
        var stagedHits = 0
        var stagedBytesServed = 0
        var blocksAdmitted = 0
        /// Transfers the cache refused because it was full. Should be zero; if it is not, the ceiling is
        /// being reached, and the no-eviction policy has stopped the cache working for the rest of it.
        var admissionsDeclined = 0
        var blocksDropped = 0
        /// Released by the engine rather than overwritten — see `forget`. Almost all of it is staged
        /// data, which nothing ever writes over and which would otherwise be held for the whole run
        /// after its single read.
        var bytesEvicted = 0
        var peakBytes = 0
        /// Blocks held at the moment `peakBytes` was reached, not at the end of the run — the two are
        /// different times, and reporting the pair from different moments invites dividing one by the
        /// other and getting a block size that never existed.
        var blocksAtPeak = 0

        var hits: Int { metadataHits + bulkHits }
        var misses: Int { metadataMisses + bulkMisses }
    }

    private(set) var cacheReport = Report()
    /// A ceiling rather than a reservation: only what a run actually touches is held, which on a 2 GiB
    /// volume of 42,000 files peaks at 45 MiB. It needs no minimum of the volume's size, because the
    /// cache is keyed by offset and so can never hold more than the volume it is caching.
    ///
    /// Raised from 256 MiB, which was too small for the medium this tool is actually aimed at, and
    /// silently so. Directory data measures about 2.5% of a volume, so the 32 GB card of 273,296 files
    /// in the notes wants some 800 MiB of it, and scaling the 45 MiB measured here by volume agrees,
    /// at around 700 MiB. Under the old ceiling that run would have stopped admitting a third of the
    /// way in and, since nothing is evicted, gone cold for the rest of it: every directory read after
    /// that point a real transfer, and nothing anywhere saying so.
    ///
    /// Measured since, on that card: 661.8 MiB, so the estimate was sound and the headroom was thinner
    /// than it reads. The scan now stops at each directory's end-of-directory marker rather than taking
    /// whole clusters — see `DirectoryWalker.entryProbe` — which brings the same run to 190.1 MiB and
    /// puts the ceiling out of reach instead of just beyond the horizon.
    ///
    /// Once full it stops admitting rather than evicting, which keeps what the scan gathered first: the
    /// directories nearest the front, which are also the ones repointing revisits most. That policy is
    /// only defensible while the ceiling is out of reach, so `Report.admissionsDeclined` counts the
    /// first refusal and `--verbose` reports it. It should always be zero; if it is not, this number
    /// is wrong rather than the run being unlucky.
    private static let cacheLimit = 1024 * 1024 * 1024

    /// Drops every cached block the range touches.
    private func drop(from offset: UInt64, count: Int) {
        guard !cache.isEmpty else { return }
        let block = UInt64(blockSize)
        let first = (offset / block) * block
        let end = ((offset + UInt64(count) + block - 1) / block) * block
        let blocks = Int((end - first) / block)

        // Walking the range is the obvious way and is wrong for a 64 MB copy, which would step
        // through a hundred thousand keys that are almost certainly not there. Whichever side is
        // smaller decides how this is done.
        if blocks > cache.count {
            cache = cache.filter { at, entry in
                let keep = at < first || at >= end
                if !keep {
                    cachedBytes -= entry.bytes.count
                    cacheReport.blocksDropped += 1
                }
                return keep
            }
        } else {
            var at = first
            while at < end {
                if let gone = cache.removeValue(forKey: at) {
                    cachedBytes -= gone.bytes.count
                    cacheReport.blocksDropped += 1
                }
                at += block
            }
        }
    }

    /// Forgets whatever is cached for `clusters`, which the caller has just released.
    ///
    /// The cache cannot work this out for itself. A released cluster's blocks are not *wrong* —
    /// nothing is served stale by keeping them, since a write to that cluster drops them anyway — they
    /// are simply never going to be asked for again, and only the engine knows a release happened.
    ///
    /// Staged data is where this matters. It is written for the sole purpose of being read back once, so
    /// the moment its object reaches a home the parked copy is provably dead; and it is the one kind
    /// that never leaves on its own, because the layout fills from the bottom and parks at the top, so
    /// nothing ever writes over it. Everything else released tends to be overwritten before long by
    /// whatever the layout puts there, which drops it incidentally. Measured, this releases 33.4 MiB
    /// over a run and costs not one hit — which is the evidence it wanted, since letting go of
    /// anything still live would show up at once as a lower metadata hit rate.
    func forget(_ clusters: some Sequence<UInt32>) {
        guard caches, !cache.isEmpty else { return }
        let before = cachedBytes
        for cluster in clusters {
            drop(from: offset(ofCluster: cluster), count: clusterSize)
        }
        cacheReport.bytesEvicted += before - cachedBytes
    }

    private func admit(_ data: Data, at offset: UInt64, staged: Bool) {
        guard caches else { return }
        guard cachedBytes + data.count <= Self.cacheLimit else {
            cacheReport.admissionsDeclined += 1
            return
        }
        var index = data.startIndex
        var at = offset
        while index + blockSize <= data.endIndex {
            let piece = CacheEntry(bytes: [UInt8](data[index ..< index + blockSize]), staged: staged)
            if let old = cache.updateValue(piece, forKey: at) { cachedBytes -= old.bytes.count }
            cachedBytes += blockSize
            cacheReport.blocksAdmitted += 1
            index += blockSize
            at += UInt64(blockSize)
        }
        if cachedBytes > cacheReport.peakBytes {
            cacheReport.peakBytes = cachedBytes
            cacheReport.blocksAtPeak = cache.count
        }
    }

    /// The blocks covering a range, if every one of them is cached, and whether any of them was parked
    /// in spare space. All or nothing: a partial answer would mean reading the gaps, and a run of blocks
    /// is one transfer either way.
    private func cached(at offset: UInt64, count: Int) -> (data: Data, staged: Bool)? {
        guard caches, !cache.isEmpty else { return nil }
        var out = Data()
        out.reserveCapacity(count)
        var at = offset
        let end = offset + UInt64(count)
        var staged = false
        while at < end {
            guard let entry = cache[at] else { return nil }
            out += entry.bytes
            staged = staged || entry.staged
            at += UInt64(blockSize)
        }
        return (out, staged)
    }

    /// Whether a range can be served without troubling the medium. Asked by callers that report
    /// device activity, so the progress line and the block map stay honest about what the drive is
    /// actually being made to do rather than what was requested of this type.
    ///
    /// A presence test rather than `cached(...) != nil`, which built the whole window as `Data` and
    /// threw it away — and since the caller then goes on to read it for real, every cached run of
    /// directory blocks was assembled twice.
    private func holdsAll(at offset: UInt64, count: Int) -> Bool {
        guard caches, !cache.isEmpty else { return false }
        var at = offset
        let end = offset + UInt64(count)
        while at < end {
            guard cache[at] != nil else { return false }
            at += UInt64(blockSize)
        }
        return true
    }

    // MARK: - The only two ways to reach the medium

    /// Reads `count` bytes at a block-aligned `offset`.
    ///
    /// Every read consults the cache, whatever it is for: a hit is a hit, and a miss costs one failed
    /// dictionary lookup because `cached` gives up on the first block it does not hold. Only retained
    /// traffic is stored on the way back.
    private func deviceRead(at offset: UInt64, count: Int, _ traffic: Traffic) throws(FATError) -> Data {
        if let hit = cached(at: offset, count: count) {
            if traffic == .metadata { cacheReport.metadataHits += 1 } else { cacheReport.bulkHits += 1 }
            cacheReport.bytesServed += count
            if hit.staged {
                cacheReport.stagedHits += 1
                cacheReport.stagedBytesServed += count
            }
            return hit.data
        }
        if traffic == .metadata { cacheReport.metadataMisses += 1 } else { cacheReport.bulkMisses += 1 }
        let data = try FATVolume.rawRead(descriptor, at: offset, count: count)
        if traffic.isRetained { admit(data, at: offset, staged: traffic == .staged) }
        return data
    }

    /// Writes `data` at a block-aligned `offset`.
    ///
    /// Dropping before admitting rather than relying on replacement: `admit` declines once the cache
    /// is full, and declining to store what was just written while leaving the previous contents in
    /// place would serve a later reader bytes the medium no longer holds.
    private func deviceWrite(_ data: Data, at offset: UInt64, _ traffic: Traffic) throws(FATError) {
        guard !dryRun else { return }
        try FATVolume.rawWrite(descriptor, data, at: offset)
        drop(from: offset, count: data.count)
        if traffic.isRetained { admit(data, at: offset, staged: traffic == .staged) }
    }

    // MARK: Reading

    func readBytes(at offset: UInt64, count: Int) throws(FATError) -> [UInt8] {
        let block = UInt64(blockSize)
        let start = (offset / block) * block
        let end = ((offset + UInt64(count) + block - 1) / block) * block
        let window = try deviceRead(at: start, count: Int(end - start), .metadata)
        let lower = window.startIndex + Int(offset - start)
        return [UInt8](window[lower ..< lower + count])
    }

    func readCluster(_ cluster: UInt32) throws(FATError) -> [UInt8] {
        try readBytes(at: offset(ofCluster: cluster), count: clusterSize)
    }

    // MARK: Writing

    /// Writes `bytes` at `offset`. Sub-block or unaligned writes become a read-modify-write of
    /// the blocks they touch, since the device may not accept them as-is.
    func writeBytes(_ bytes: [UInt8], at offset: UInt64) throws(FATError) {
        guard !dryRun else { return }
        let block = UInt64(blockSize)
        if offset % block == 0, bytes.count % blockSize == 0 {
            try deviceWrite(Data(bytes), at: offset, .metadata)
            return
        }
        let start = (offset / block) * block
        let end = ((offset + UInt64(bytes.count) + block - 1) / block) * block
        var window = [UInt8](try deviceRead(at: start, count: Int(end - start), .metadata))
        window.replaceSubrange(Int(offset - start) ..< Int(offset - start) + bytes.count, with: bytes)
        try deviceWrite(Data(window), at: start, .metadata)
    }

    func writeCluster(_ cluster: UInt32, _ bytes: [UInt8]) throws(FATError) {
        try writeBytes(bytes, at: offset(ofCluster: cluster))
    }

    /// Whether a transfer can go out as it stands, rather than becoming a read-modify-write of the
    /// blocks it straddles.
    func isAligned(_ offset: UInt64, _ count: Int) -> Bool {
        offset % UInt64(blockSize) == 0 && count % blockSize == 0
    }

    /// Reads `count` bytes at a block-aligned `offset`, as `Data`.
    ///
    /// Kept apart from `readBytes` for the same reason `copyBytes` is: the payload never has to
    /// become a Swift array. Those conversions cost several extra passes over the data, which is
    /// most of the CPU time when tens of megabytes are being relocated.
    func readRaw(at offset: UInt64, count: Int) throws(FATError) -> Data {
        try deviceRead(at: offset, count: count, .bulk)
    }

    /// Writes `data` at a block-aligned `offset`, in the same chunks as every other transfer here.
    ///
    /// - Parameter retention: why these bytes might be worth keeping in memory once written. Staged data
    ///   is written for no reason other than to be read back; a directory is read again as soon as
    ///   anything points at it.
    func writeRaw(_ data: Data, at offset: UInt64,
                  retaining retention: Retention = .fileData) throws(FATError) {
        try deviceWrite(data, at: offset, traffic(for: retention))
    }

    /// Copies `count` bytes from one offset to another without the payload ever becoming a Swift
    /// array. Going through `[UInt8]` costs several extra passes over the data — Data to array,
    /// a slice, then array back to Data — which is most of the CPU time when tens of megabytes
    /// are being relocated. Cluster-aligned copies, which is all the defragmenter asks for, stay
    /// on this path; anything else falls back to the general read/write.
    func copyBytes(from source: UInt64, to destination: UInt64, count: Int,
                   retaining retention: Retention = .fileData) throws(FATError) {
        let block = UInt64(blockSize)
        guard source % block == 0, destination % block == 0, count % blockSize == 0 else {
            // Not a shape the defragmenter asks for — it copies whole clusters — so this takes the
            // careful route rather than the fast one.
            try writeBytes(try readBytes(at: source, count: count), at: destination)
            return
        }

        var done = 0
        while done < count {
            let chunk = min(FATVolume.maxTransfer, count - done)
            // The read still happens on a dry run — only the write is dropped. It costs no more than
            // skipping the pair would save, and it proves every source cluster the plan wants to move
            // is actually readable.
            let data = try deviceRead(at: source + UInt64(done), count: chunk, .bulk)
            try deviceWrite(data, at: destination + UInt64(done), traffic(for: retention))
            done += chunk
        }
    }

    /// Applies a batch of directory-entry first-cluster pointers.
    ///
    /// Every edit landing in the same block is folded into one visit, and blocks that touch are
    /// handled together — siblings share a directory cluster, so a whole directory's worth of edits
    /// usually collapses into a single pair of transfers. Entries are 32 bytes on a 32-byte boundary
    /// and blocks are a multiple of that, so no edit ever straddles two blocks.
    ///
    /// The order matters more than the count. This reads everything it needs in one sweep up the
    /// volume, patches it in memory, and writes it back in a second sweep. Reading a block and then
    /// immediately writing that same block is the obvious way to do it and the worst: the head has
    /// just passed the sector, so the write waits nearly a full rotation. Against a page cache that
    /// costs nothing and the difference is invisible, but on a raw device it was eleven milliseconds
    /// a block and turned this phase into half the run — 6m 39s of a 13m 58s run, against 1m 18s for
    /// the same work buffered.
    ///
    /// - Parameter report: called on either side of each transfer, with how many have gone, how many
    ///   there are across both sweeps, and where this one lands. These are scattered across every
    ///   parent directory on the volume, so on slow media they are a large part of the wait between
    ///   one generation and the next — long enough to be worth showing rather than sitting through.
    /// - Returns: how many blocks were written, which is the figure worth watching on slow media: it
    ///   should be far below the number of edits.
    /// One transfer of a divided pass, as it happens.
    ///
    /// A value rather than a handful of positional arguments, because the pass has two sweeps and the
    /// caller has to be able to tell them apart: they visit the same blocks in the same order, and a
    /// consumer told only "block 9 of 24" can do nothing but guess which half it is in.
    struct PassProgress: Sendable {
        /// Which transfer of how many, counted across both sweeps.
        let step: Int
        let steps: Int
        /// Where on the volume this one lands.
        let offset: UInt64
        /// False while gathering the blocks, true on the write-back.
        let writing: Bool
        /// False as the transfer is issued, true once the medium has answered.
        let done: Bool
    }

    typealias TransferProgress = (PassProgress) -> Void

    @discardableResult
    func applyEntryPointers(_ edits: [(offset: UInt64, cluster: UInt32)],
                            report: TransferProgress? = nil) throws(FATError) -> Int {
        guard !edits.isEmpty else { return 0 }
        let block = UInt64(blockSize)
        let sorted = edits.sorted { $0.offset < $1.offset }

        // The distinct blocks the edits fall in, with neighbours gathered into one transfer.
        var runs: [(start: UInt64, blocks: Int)] = []
        for edit in sorted {
            let start = (edit.offset / block) * block
            if var last = runs.last {
                let end = last.start + UInt64(last.blocks) * block
                if start < end { continue }               // already inside the run being built
                if start == end {
                    last.blocks += 1
                    runs[runs.count - 1] = last
                    continue
                }
            }
            runs.append((start: start, blocks: 1))
        }

        let total = runs.count * 2
        var windows: [[UInt8]] = []
        windows.reserveCapacity(runs.count)
        for (index, run) in runs.enumerated() {
            // Served from the cache where it can be, which after the first pass over a volume is most
            // of it — and, thanks to the scan having read every directory cluster already, a good deal
            // of the first pass too.
            //
            // Reported only where the drive is really being asked, which is the standing rule that
            // activity means the device and not the caller's intent — and both edges or neither, so
            // that a run served from memory passes without a trace rather than leaving a light on.
            let count = run.blocks * blockSize
            let reachesMedium = !holdsAll(at: run.start, count: count)
            if reachesMedium {
                report?(PassProgress(step: index, steps: total, offset: run.start,
                                     writing: false, done: false))
            }
            windows.append([UInt8](try deviceRead(at: run.start, count: count, .metadata)))
            if reachesMedium {
                report?(PassProgress(step: index, steps: total, offset: run.start,
                                     writing: false, done: true))
            }
        }

        // Both lists are in offset order, so one walk places every edit.
        var index = 0
        for edit in sorted {
            while index < runs.count,
                  edit.offset >= runs[index].start + UInt64(runs[index].blocks) * block {
                index += 1
            }
            guard index < runs.count else { break }
            let local = Int(edit.offset - runs[index].start)
            DirectoryEntry.setFirstCluster(edit.cluster, in: &windows[index], at: local)
        }

        var blocksWritten = 0
        for (index, run) in runs.enumerated() {
            report?(PassProgress(step: runs.count + index, steps: total, offset: run.start,
                                 writing: true, done: false))
            // `deviceWrite` caches what it wrote, and only once the write has returned, so a failed
            // write leaves nothing behind claiming to be the truth.
            try deviceWrite(Data(windows[index]), at: run.start, .metadata)
            report?(PassProgress(step: runs.count + index, steps: total, offset: run.start,
                                 writing: true, done: true))
            blocksWritten += run.blocks
        }
        return blocksWritten
    }

    /// Reads the `count` bytes at `offset`, hands them to `patch`, and writes them back. Doing
    /// it in one step costs a single read-modify-write, where reading and then writing separately
    /// pays for the enclosing block twice over — which adds up when patching one directory entry
    /// per relocated object.
    func updateBytes(at offset: UInt64, count: Int, _ patch: (inout [UInt8]) -> Void) throws(FATError) {
        let block = UInt64(blockSize)
        let start = (offset / block) * block
        let end = ((offset + UInt64(count) + block - 1) / block) * block
        var window = [UInt8](try deviceRead(at: start, count: Int(end - start), .metadata))
        let lower = Int(offset - start)
        var slice = Array(window[lower ..< lower + count])
        patch(&slice)
        window.replaceSubrange(lower ..< lower + count, with: slice)
        try deviceWrite(Data(window), at: start, .metadata)
    }

    /// Points the directory entry whose pointer field is at `offset` at `cluster`, in a single
    /// read-modify-write of the block it lands in.
    ///
    /// The last resort of the two paths a pointer flip can take: the batched one folds the change into
    /// a copy that is still in memory and costs nothing, and this is what happens when there is no
    /// such copy to fold it into.
    func setFirstCluster(at offset: UInt64, to cluster: UInt32) throws(FATError) {
        try updateBytes(at: offset, count: DirectoryEntry.pointerFieldSize) {
            DirectoryEntry.setFirstCluster(cluster, in: &$0, at: 0)
        }
    }

    /// Pushes writes all the way to the medium.
    ///
    /// What that takes differs by platform enough that it is one of the seven members of `System`,
    /// and the reasoning for each is documented beside its implementation. The whole safety
    /// argument — copies durable before anything names them, names durable before the space they
    /// abandoned is reused — rests on whichever one runs actually being a barrier.
    func synchronize() throws(FATError) {
        guard !dryRun else { return }
        if let code = System.synchronize(descriptor) {
            throw FATError.io("flush failed: " + String(cString: strerror(code)))
        }
    }

    /// Follows a cluster chain starting at `start`, returning the ordered clusters.
    /// Throws on loops, bad clusters, or clusters that fall outside the data region.
    func chain(startingAt start: UInt32) throws(FATError) -> [UInt32] {
        var result: [UInt32] = []
        var visited = Set<UInt32>()
        var c = start & flavour.entryMask
        while true {
            if c < 2 || c > countOfClusters + 1 {
                if c >= flavour.eocThreshold { return result }   // proper end-of-chain
                if c == 0 { throw FATError.corruption("free cluster inside chain from \(start)") }
                throw FATError.corruption("invalid cluster \(c) inside chain from \(start)")
            }
            guard visited.insert(c).inserted else {
                throw FATError.corruption("cluster loop detected in chain from \(start)")
            }
            result.append(c)
            let next = fat[Int(c)] & flavour.entryMask
            if next == flavour.badCluster { throw FATError.corruption("bad cluster \(c) in chain") }
            c = next
        }
    }

    // MARK: Low-level, block-aligned I/O

    /// Largest single transfer. Raw devices cap how much they will move in one call, and this
    /// is a multiple of every plausible block size.
    private static let maxTransfer = 1 << 20

    /// Establishes what the device will accept. A raw node backed by 4096-byte blocks refuses
    /// a 512-byte read outright, so the smaller size is simply tried first.
    static func probeBlockSize(_ descriptor: Int32) -> Int {
        for candidate in [512, 4096] {
            var probe = [UInt8](repeating: 0, count: candidate)
            let got = probe.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, candidate, 0)
            }
            if got == candidate { return candidate }
        }
        return 512
    }

    /// Reads `count` bytes at `offset` by widening to block boundaries and slicing the result.
    ///
    /// For the two readers that have no volume to read through. `init` is one, running before there
    /// is a `self` to cache into; `DeviceScan` is the other, which wants a boot sector off a device
    /// it has not decided is a volume at all. Everything after `init` goes through `deviceRead`.
    ///
    /// The widening is the reason this is shared rather than reimplemented: a raw node with 4096-byte
    /// blocks refuses a 512-byte read, and a probe that got that wrong would report every card with
    /// large sectors as not being FAT.
    static func read(_ descriptor: Int32, blockSize: Int,
                     at offset: UInt64, count: Int) throws(FATError) -> [UInt8] {
        let block = UInt64(blockSize)
        let start = (offset / block) * block
        let end = ((offset + UInt64(count) + block - 1) / block) * block
        let window = try rawRead(descriptor, at: start, count: Int(end - start))
        let lower = window.startIndex + Int(offset - start)
        return [UInt8](window[lower ..< lower + count])
    }

    /// The one read that reaches the medium once the volume is open, which is what lets `deviceRead`
    /// be certain it sees every transfer. The single exception is `probeBlockSize`, which runs during
    /// `init` before there is a cache to be wrong about and only ever reads.
    ///
    /// `pread` rather than `FileHandle`, for three reasons and only one of them speed. It returns no
    /// object, so there is nothing to autorelease and no pool to forget — `FileHandle.read` is
    /// `-[NSConcreteFileHandle readDataOfLength:]` underneath, handing back autoreleased `NSData`
    /// that a command-line tool never drains, which cost 1.4 GiB of resident memory on a 2 GB volume
    /// until it was found. It carries its own offset, so one call does what a seek and a read did. And
    /// it reads straight into storage we already own, so a transfer costs no allocation and no copy.
    ///
    /// A short read is legal and not an error: the loop advances by what arrived. Zero is the end of
    /// the volume, which for a fixed-size request is a genuine fault.
    ///
    /// The failure is carried back out of the closure rather than thrown through it. `withUnsafeBytes`
    /// and its mutable twin are `rethrows`, which is untyped: a `throw` inside one arrives outside as
    /// `any Error`, and that is the single thing in this file that would stop the engine declaring the
    /// one error it actually has. Returning the error is a two-line difference and keeps the whole
    /// call graph typed.
    private static func rawRead(_ descriptor: Int32, at offset: UInt64,
                                count: Int) throws(FATError) -> Data {
        var result = Data(count: count)
        let failure: FATError? = result.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            var done = 0
            while done < count {
                let chunk = min(maxTransfer, count - done)
                let at = off_t(offset) + off_t(done)
                let got = pread(descriptor, base + done, chunk, at)
                if got < 0 {
                    if errno == EINTR { continue }
                    return .io("read of \(chunk) bytes at \(at) failed: "
                        + String(cString: strerror(errno)))
                }
                if got == 0 {
                    return .io("unexpected end of volume \(chunk) bytes into offset \(at)")
                }
                done += got
            }
            return nil
        }
        if let failure { throw failure }
        return result
    }

    /// The one write that reaches the medium, for the same reasons.
    private static func rawWrite(_ descriptor: Int32, _ data: Data,
                                 at offset: UInt64) throws(FATError) {
        let failure: FATError? = data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            var done = 0
            while done < buffer.count {
                let chunk = min(maxTransfer, buffer.count - done)
                let at = off_t(offset) + off_t(done)
                let put = pwrite(descriptor, base + done, chunk, at)
                if put < 0 {
                    if errno == EINTR { continue }
                    return .io("write of \(chunk) bytes at \(at) failed: "
                        + String(cString: strerror(errno)))
                }
                if put == 0 {
                    return .io("write of \(chunk) bytes at \(at) made no progress")
                }
                done += put
            }
            return nil
        }
        if let failure { throw failure }
    }
}
