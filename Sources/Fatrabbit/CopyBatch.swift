import Foundation

/// Gathers a generation's data copies so that they leave as one pass of reads followed by one pass
/// of writes, rather than hopping between two distant parts of the medium for every span. A card
/// has no head to move, but a cheap controller has one write buffer, and a read from somewhere else
/// forces it out; sequential reads also get whatever read-ahead the card offers. On a spinning disk
/// the same batching earns the ordinary elevator win instead.
///
/// This is safe for exactly the reason a generation's moves are independent of one another: every
/// destination in a generation is a cluster that was free before the generation began, so nothing a
/// queued write will land on is something a queued read depends on. Nor does it move any of the
/// ordering the safety argument rests on — the batch is emptied at the start of every commit, so the
/// data is on the medium before the FAT entries that allocate it, which are in turn on the medium
/// before anything points at them. An interruption part way through a batch leaves clusters holding
/// data that nothing references, which is the same orphan a later run reclaims.
///
/// Corrections to copied bytes are applied to the buffer rather than to the medium, so a directory's
/// `.` entry costs nothing to fix instead of costing a read-modify-write per directory moved.
final class CopyBatch {
    private struct Span {
        let source: UInt64
        let destination: UInt64
        /// Grows when `fuseAdjacent` absorbs the span that begins exactly where this one ends.
        var count: Int
        /// Why these bytes might be worth keeping once written — parked in spare space, or a
        /// directory that is about to be read again. The volume decides what to do with that.
        let retention: FATVolume.Retention
        var data: Data?
    }

    /// A directory-entry pointer to be repointed within bytes that are still in the buffer, applied
    /// between the read pass and the write pass so that it reaches the medium as part of the copy
    /// rather than as a write of its own.
    ///
    /// A value rather than the closure this used to carry. The closure was a generalisation with
    /// exactly one instantiation — every edit the batch has ever been handed is a first-cluster
    /// pointer, which is what the `pointerFixes…` figures it reports have always called them — and
    /// the cost of keeping it was that an edit could only be applied to bytes lifted out into an
    /// array of their own first.
    private struct PointerFix {
        /// Absolute offset on the volume of the eight-byte pointer field.
        let destination: UInt64
        /// What that field should name.
        let cluster: UInt32
    }

    /// One span going out, as it happens.
    struct Activity {
        let writing: Bool
        let index: Int
        let total: Int
        /// Where on the volume: the source of a read, the destination of a write.
        let offset: UInt64
        let count: Int
        /// False as the transfer starts, true once it has returned. Anything describing what the
        /// volume now holds belongs on the second one — before that, the bytes are not in hand and
        /// saying otherwise is describing an intention.
        let done: Bool
    }

    /// Called for each span as the batch goes out.
    ///
    /// Worth having because this is where a generation's time is actually spent: the moves before it
    /// only queue work, and on a slow medium they all complete in a few milliseconds while the flush
    /// they queued takes seconds. Without this, both the progress line and the block map sit
    /// perfectly still through the slowest part of every generation, which is exactly when someone
    /// is most likely to wonder whether anything is happening.
    var report: ((Activity) -> Void)?

    private let volume: FATVolume
    /// How much may be held before the batch has to go out. Bounded, because a run relocates
    /// gigabytes; large enough that a generation of small scattered objects is usually one pass.
    private let budget: Int

    private var spans: [Span] = []
    private var fixes: [PointerFix] = []
    private var buffered = 0

    /// Figures worth watching on slow media. Spans against passes says how much of the alternation
    /// was actually avoided, and folded edits are read-modify-writes that never happened.
    /// Time spent moving data, counted here rather than by the caller: a batch goes out both when a
    /// commit asks for it and, part way through a generation, whenever it fills up. Timing only the
    /// first leaves a third of a run's copying missing from the accounts.
    private(set) var elapsed = Duration.zero

    private(set) var passes = 0
    private(set) var spansCopied = 0
    private(set) var spansFused = 0
    private(set) var spansSentDirect = 0
    private(set) var editsFolded = 0
    private(set) var editsWritten = 0

    /// When set, every span's read is performed a second time straight off the medium and the two
    /// answers compared.
    ///
    /// This is aimed at one measured fault and nothing else. On a 33 GB card, a group of spans in a
    /// single generation read their source data from an offset exactly 65,536 bytes — four 16 KB
    /// clusters — below where they should have, and wrote those wrong bytes to the right
    /// destinations. The write path is already exonerated: the destinations were correct, the
    /// lengths were correct, and nothing else in the run touched them. What is left is the read,
    /// and the only thing in the read path that could answer differently on two consecutive calls
    /// is the cache.
    ///
    /// So this asks the cache and the medium the same question and compares. A disagreement is
    /// reported with the offset it swept back to find the bytes actually returned, which names the
    /// discrepancy outright rather than leaving it to be inferred from the wreckage afterwards.
    ///
    /// It doubles the read traffic of the copy phase, so it is for a run somebody is deliberately
    /// watching.
    private let verifyReads: Bool

    init(volume: FATVolume, budget: Int, verifyReads: Bool = false) {
        self.volume = volume
        self.budget = budget
        self.verifyReads = verifyReads
    }

    /// Queues a copy of `count` bytes. A span as large as the whole budget is already a sequential
    /// pass in its own right, so it goes straight out rather than displacing everything else.
    func copy(from source: UInt64, to destination: UInt64, count: Int,
              retaining retention: FATVolume.Retention = .fileData) throws(FATError) {
        guard count < budget, volume.isAligned(source, count), volume.isAligned(destination, count) else {
            spansSentDirect += 1
            report?(Activity(writing: true, index: 0, total: 1, offset: destination,
                             count: count, done: false))
            let started = ContinuousClock.now
            try volume.copyBytes(from: source, to: destination, count: count,
                                 retaining: retention)
            elapsed += started.duration(to: .now)
            report?(Activity(writing: true, index: 0, total: 1, offset: destination,
                             count: count, done: true))
            return
        }
        if buffered + count > budget { try flush() }
        spans.append(Span(source: source, destination: destination, count: count,
                          retention: retention))
        buffered += count
    }

    /// Points the directory entry whose pointer field sits at `destination` at `cluster`. Queued as a
    /// patch to memory where the copy carrying those bytes is still in hand, and otherwise applied to
    /// the medium, which is what happens when the copy has already gone out.
    func setFirstCluster(at destination: UInt64, to cluster: UInt32) throws(FATError) {
        if spans.contains(where: { holds($0, destination, DirectoryEntry.pointerFieldSize) }) {
            fixes.append(PointerFix(destination: destination, cluster: cluster))
        } else {
            editsWritten += 1
            try volume.setFirstCluster(at: destination, to: cluster)
        }
    }

    /// Fuses each span into the one that begins exactly where it ends — in the source *and* in the
    /// destination, both, or not at all.
    ///
    /// A pair like that is barely a merge. The fused transfer is one read of a contiguous range and
    /// one write of a contiguous range: byte for byte what moving a single object of the combined size
    /// already does, through the same two calls. Nothing is read that is not wanted, and nothing is
    /// written from a slice of something larger.
    ///
    /// That restriction is the whole design. An earlier version gathered spans that merely touched on
    /// one side, which means reading across a gap and writing back only parts of what was read — and
    /// it correlated with silent, repeatable corruption on a card that was never explained. This form
    /// has neither a gather nor a mask, so the mechanism such a bug would need is not present to go
    /// wrong. It is still checked on hardware with `ab-verify.py` rather than reasoned about.
    ///
    /// Sorting by source is enough to find every pair: if one span ends where another begins, no third
    /// span can lie between them, because two objects never share a cluster.
    ///
    /// Retention has to match, and that costs something worth recording. The layout puts a directory
    /// immediately before its own files, so a directory span and a file span are adjacent on both sides
    /// constantly, and refusing to fuse them costs 1,006 transfers on a 42,000-file volume — 3.5%.
    /// Allowing it, and keeping the fused span, recovers every one of those and takes the cache from
    /// 45 MiB to 107 MiB, because the file content riding along with each directory is kept too. That
    /// does not scale: metadata grows with the file count, the ceiling does not, and nothing is evicted,
    /// so on a card several times this size it would stop admitting partway through and the cache would
    /// go cold for the rest of the run. The 1,006 transfers are the cheaper half of that trade, and
    /// are bought back several times over anyway: caching directories removes 2,971 metadata reads.
    ///
    /// Worth about 40% of the transfers on a test volume for no extra bytes read. Worth having only
    /// because the raw node hands the drive a transfer at the size it was issued — measured on the
    /// buffered path, where the block layer re-split everything into 16 KB requests, the same change
    /// was worth nothing at all, which is why it was once removed as earning nothing.
    private func fuseAdjacent() {
        guard spans.count > 1 else { return }
        var fused: [Span] = []
        fused.reserveCapacity(spans.count)
        for span in spans {
            if var last = fused.last,
               last.source + UInt64(last.count) == span.source,
               last.destination + UInt64(last.count) == span.destination,
               last.retention == span.retention {    // one transfer cannot be half kept in memory
                last.count += span.count
                fused[fused.count - 1] = last
                spansFused += 1
                continue
            }
            fused.append(span)
        }
        spans = fused
    }

    /// Reads everything queued in source order, applies the edits in memory, then writes it all out
    /// in destination order — which is the order the new layout is being built in.
    func flush() throws(FATError) {
        guard !spans.isEmpty || !fixes.isEmpty else { return }
        let started = ContinuousClock.now
        defer { elapsed += started.duration(to: .now) }
        passes += 1

        spans.sort { $0.source < $1.source }
        fuseAdjacent()
        for index in spans.indices {
            report?(Activity(writing: false, index: index, total: spans.count,
                             offset: spans[index].source, count: spans[index].count, done: false))
            spans[index].data = try volume.readRaw(at: spans[index].source, count: spans[index].count)
            if verifyReads { try checkRead(spans[index]) }
            report?(Activity(writing: false, index: index, total: spans.count,
                             offset: spans[index].source, count: spans[index].count, done: true))
        }

        // Applied through a mutable window straight onto the bytes the read pass left in the buffer.
        //
        // Lifting them out and putting them back — `var data = spans[i].data`, patch a copy of the
        // eight bytes, `replaceSubrange`, store it again — reads as equivalent and is not. That local
        // `data` shares its buffer with the one still held in `spans`, so the buffer is no longer
        // uniquely referenced and `replaceSubrange` duly copies the whole of it: a fresh allocation
        // and a full memcpy of the span, up to the batch's entire 64 MB budget, to change eight bytes.
        // A fused directory span pays it once per subdirectory it carries.
        //
        // A span cannot make that mistake, because it does not own anything to copy — it borrows the
        // buffer in place, which is the only thing this ever wanted to do.
        //
        // A fix whose span is not here can only be one queued against a batch already written, so it
        // goes to the medium — after the write pass below, or the copy would overwrite it.
        var strays: [PointerFix] = []
        for fix in fixes {
            let size = DirectoryEntry.pointerFieldSize
            guard let index = spans.firstIndex(where: { holds($0, fix.destination, size) }),
                  spans[index].data != nil else {
                strays.append(fix)
                continue
            }
            let local = Int(fix.destination - spans[index].destination)
            // Unwrapped rather than bound, because the write has to reach the stored buffer itself: a
            // binding would be the very copy described above. The nil case is the guard above.
            var window = spans[index].data!.mutableBytes
            DirectoryEntry.setFirstCluster(fix.cluster, in: &window, at: local)
            editsFolded += 1
        }
        fixes.removeAll(keepingCapacity: true)

        spans.sort { $0.destination < $1.destination }
        for (index, span) in spans.enumerated() {
            // Every span was read above, so this cannot be nil — and if it ever is, the copy is
            // being dropped on the floor. That is not a condition to skip past: the FAT entries
            // allocating this destination go out at the next commit regardless, so the volume ends
            // up naming a cluster that was never written, which reads back as a directory or a file
            // full of whatever the previous occupant left. Silence here would make that indetectable
            // from the outside, which is exactly what a run leaving four destroyed directories
            // behind and reporting success looks like.
            guard let data = span.data else {
                throw FATError.io("internal error: queued copy of \(span.count) bytes to offset "
                    + "\(span.destination) was never read, so it cannot be written; "
                    + "refusing to allocate a destination holding stale data")
            }
            guard data.count == span.count else {
                throw FATError.io("internal error: read \(data.count) bytes for a \(span.count)-byte "
                    + "copy to offset \(span.destination); refusing to write a short or overlong span")
            }
            report?(Activity(writing: true, index: index, total: spans.count,
                             offset: span.destination, count: span.count, done: false))
            try volume.writeRaw(data, at: span.destination, retaining: span.retention)
            report?(Activity(writing: true, index: index, total: spans.count,
                             offset: span.destination, count: span.count, done: true))
            spansCopied += 1
        }
        spans.removeAll(keepingCapacity: true)
        buffered = 0

        for fix in strays {
            editsWritten += 1
            try volume.setFirstCluster(at: fix.destination, to: fix.cluster)
        }
    }

    /// Asks the medium the same question the read just asked, and compares the answers.
    ///
    /// On a disagreement it goes looking for where the returned bytes actually live, sweeping
    /// cluster by cluster either side of the span's source. That sweep is the whole point: knowing
    /// a read was wrong is worth little, and knowing it came from exactly four clusters below is
    /// worth everything. The window is deliberately wide enough to catch a much larger slip than
    /// the one measured, so a different offset does not go unnamed.
    private func checkRead(_ span: Span) throws(FATError) {
        guard let held = span.data else { return }
        let fresh = try volume.readUncached(at: span.source, count: span.count)
        let agrees = held.withUnsafeBytes { buffer in buffer.elementsEqual(fresh) }
        if agrees { return }

        // Where the two first part company, which bounds how much of the span is wrong.
        var firstDifference = -1
        held.withUnsafeBytes { buffer in
            for index in 0 ..< min(buffer.count, fresh.count) where buffer[index] != fresh[index] {
                firstDifference = index
                break
            }
        }

        // Sweep for the bytes that actually came back. Compared over one cluster, which is enough
        // to identify an offset and cheap enough to try sixty-four of them.
        let clusterSize = volume.clusterSize
        let probeSize = min(span.count, clusterSize)
        var landedAt: String = "not found within 64 clusters either side"
        for step in 1 ... 64 {
            for direction in [-step, step] {
                let shift = Int64(direction) * Int64(clusterSize)
                let candidate = Int64(span.source) + shift
                guard candidate >= 0 else { continue }
                guard let bytes = try? volume.readUncached(at: UInt64(candidate), count: probeSize)
                else { continue }
                let same = held.withUnsafeBytes { buffer in
                    buffer.prefix(probeSize).elementsEqual(bytes)
                }
                if same {
                    landedAt = "the bytes returned are those at offset \(candidate) — "
                        + "\(direction) cluster(s), \(shift) bytes, from where they were asked for"
                    break
                }
            }
            if !landedAt.hasPrefix("not found") { break }
        }

        throw FATError.io("""
            The medium contradicted itself. \(span.count) bytes read at offset \(span.source) came \
            back differing from the same range read again by another route, first at byte \
            \(firstDifference). \(landedAt). This copy was bound for offset \(span.destination), so \
            writing it would have put the wrong data there with nothing afterwards to show it.

            Nothing this tool does can make that safe, so the run has stopped rather than carry the \
            bytes forward. Two reads of one unchanging range disagreed, which is the device, its \
            reader, or the connection between them — not the layout, the filesystem, or this \
            volume's contents. Everything written before this point was verified the same way. The \
            volume is left marked dirty, and the detail below is what to send to whoever asks.
            Span: source \(span.source), count \(span.count), retention \(span.retention), \
            \(spans.count) spans in this batch, \(spansFused) fused so far, pass \(passes).
            """)
    }

    /// Whether `span` covers the whole of the `count` bytes at `destination`.
    private func holds(_ span: Span, _ destination: UInt64, _ count: Int) -> Bool {
        destination >= span.destination
            && destination + UInt64(count) <= span.destination + UInt64(span.count)
    }
}
