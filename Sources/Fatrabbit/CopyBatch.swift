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

    /// When set, every span is checked in both directions: its read is performed a second time
    /// straight off the medium and the two answers compared, and after it is written the destination
    /// is read back and compared against the bytes that were sent.
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
    /// The write half was added after a reader was caught doing something the read half could never
    /// have seen: handed a 131,072-byte write it advertised, it performed a single 65,536-byte write
    /// of the payload's *second* half, placed it at the *first* half's address, left the rest
    /// untouched, and returned 131,072 with no error anywhere. `TransferProbe` now catches that
    /// particular shape at startup, but a probe can only provoke the patterns it knows about. This
    /// checks what actually landed, every span, which needs to know nothing about the fault.
    ///
    /// It is also the only check placed where a failure is free. The copy phase is the one moment
    /// when nothing on the volume refers to the new data — the FAT entries that allocate it and the
    /// pointers that name it are both written later, by `commitPending` — so stopping here leaves
    /// the original still live and the volume exactly as it was found.
    ///
    /// It adds two reads per span to the one read and one write the copy already costs, so the
    /// traffic of the copy phase roughly doubles. What that costs in wall clock depends entirely on
    /// the medium: measured at +23% against an image, where the page cache absorbs the re-reads, and
    /// considerably more against a card, where every one of them is a real transfer. Either way it
    /// is for a run somebody is deliberately watching.
    private let verifies: Bool

    init(volume: FATVolume, budget: Int, verifyCopies: Bool = false) {
        self.volume = volume
        self.budget = budget
        self.verifies = verifyCopies
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
            if verifies { try checkRead(spans[index]) }
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
            if verifies { try checkWrite(span, data) }
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
        if CopyBatch.same(held, fresh) { return }

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
                    bytes.withUnsafeBytes { other in
                        memcmp(buffer.baseAddress!, other.baseAddress!, probeSize) == 0
                    }
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

    /// Reads back what was just written and compares it with what was sent.
    ///
    /// Straight off the medium rather than through the cache, which is the whole point: the write
    /// admitted its own bytes on the way past, so a cached read would be this process agreeing with
    /// itself. On a disagreement it sweeps for where the payload actually landed, because knowing a
    /// write went astray is worth little and knowing it went 65,536 bytes low is worth everything —
    /// that offset is what turned an unexplained card into a one-line startup check.
    private func checkWrite(_ span: Span, _ sent: Data) throws(FATError) {
        let back = try volume.readUncached(at: span.destination, count: span.count)
        if CopyBatch.same(sent, back) { return }

        var firstDifference = -1
        sent.withUnsafeBytes { buffer in
            for index in 0 ..< min(buffer.count, back.count) where buffer[index] != back[index] {
                firstDifference = index
                break
            }
        }

        // Where did the bytes go? Sweep either side a cluster at a time, looking for the payload's
        // opening bytes. Wide enough to catch a much larger slip than the one measured, so a
        // different offset is named rather than going unreported.
        let clusterSize = volume.clusterSize
        let probeSize = min(span.count, clusterSize)
        var landedAt = "not found within 64 clusters either side"
        let opening = sent.prefix(probeSize)
        for step in 1 ... 64 {
            for direction in [-step, step] {
                let shift = Int64(direction) * Int64(clusterSize)
                let candidate = Int64(span.destination) + shift
                guard candidate >= 0 else { continue }
                guard let bytes = try? volume.readUncached(at: UInt64(candidate), count: probeSize)
                else { continue }
                if CopyBatch.same(Data(opening), bytes) {
                    landedAt = "the bytes sent are at offset \(candidate) instead — "
                        + "\(shift) bytes, \(direction) cluster(s), from where they were written"
                    break
                }
            }
            if !landedAt.hasPrefix("not found") { break }
        }

        throw FATError.io("""
            The medium did not keep what it was given. \(span.count) bytes were written to offset \
            \(span.destination), the write returned success, and reading the same range straight \
            back off the medium returned different bytes, first differing at byte \
            \(firstDifference). \(landedAt).

            A device that acknowledges a write it did not perform cannot be defragmented safely, so \
            the run has stopped rather than carry on. This was caught in the copy phase, which is \
            the one place it costs nothing: no FAT entry allocates these clusters yet and nothing \
            points at them, so the volume is exactly as it was found and the original data is still \
            live where it always was.

            Span: destination \(span.destination), source \(span.source), count \(span.count), \
            retention \(span.retention), transfer size \(FATVolume.maxTransfer), pass \(passes).
            """)
    }

    /// Whether two buffers hold the same bytes, compared a word at a time rather than an element at
    /// a time.
    ///
    /// `elementsEqual` on an `UnsafeRawBufferPointer` against an array goes through `Sequence`, which
    /// is a byte-at-a-time loop with a witness-table call per byte. Verifying a run compares a
    /// gigabyte twice over, and doing that generically took a two-minute volume to two and a half
    /// minutes of comparison alone — most of the cost of `--verify-copies` was not the extra reads it
    /// exists for.
    private static func same(_ left: Data, _ right: [UInt8]) -> Bool {
        guard left.count == right.count else { return false }
        if left.isEmpty { return true }
        return left.withUnsafeBytes { a in
            right.withUnsafeBytes { b in
                memcmp(a.baseAddress!, b.baseAddress!, left.count) == 0
            }
        }
    }

    /// Whether `span` covers the whole of the `count` bytes at `destination`.
    private func holds(_ span: Span, _ destination: UInt64, _ count: Int) -> Bool {
        destination >= span.destination
            && destination + UInt64(count) <= span.destination + UInt64(span.count)
    }
}
