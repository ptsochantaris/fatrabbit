import Foundation

/// Finds out what a device will actually do with a transfer, instead of taking its word for it.
///
/// ## Why this exists
///
/// A USB card reader measured here states a maximum transfer of 131,072 bytes, twice over and
/// consistently: `DKIOCGETMAXBYTECOUNTWRITE` says 131,072 and `DKIOCGETMAXBLOCKCOUNTWRITE` says 256
/// against a 512-byte block. Both are wrong. Handed a 131,072-byte write in a particular pattern,
/// that reader performs a single 65,536-byte write instead, carrying the *second* half of the
/// payload and placing it at the *first* half's address. The first half is never written anywhere,
/// the second half's own destination is never touched, `pwrite` returns 131,072, and no error is
/// reported at any level. A run of 727,778 writes lost 338 clusters that way — well over a hundred
/// files and one directory quietly destroyed, with a single error at the very end of an hour. The
/// cluster count is exact, taken by comparing a trace of every transfer the run issued against the
/// image of the volume afterwards. The file count is not, because the only way to count files was to
/// hash the card, and hashing the card meant reading it at the size it mishandles.
///
/// The pattern that provokes it, measured from scratch and reproducible in under a second:
///
/// - two or more back-to-back transfers of the maximum size, contiguous on the medium, then
/// - a discontiguity of exactly half that size, then
/// - one more transfer of the maximum size — which is the one that goes astray.
///
/// Reads are haunted by the same pattern, and worse. A 131,072-byte read after that run-up disagreed
/// with the same range read in 4 KiB pieces at 361 of 400 positions tried, against roughly three bad
/// writes in 107,801 for the write fault. That is why a bulk pass over a freshly restored card
/// hashed four files of 273,050 wrongly and hashed them correctly on a second attempt: a bulk pass
/// reads long sequential runs across a volume that has holes in it. One ceiling governs both
/// directions, so backing off fixes both — but a device haunted only on reads would sail through a
/// probe that only writes, so both are tested.
///
/// Every other gap is fine. Every smaller transfer size is fine at every gap. Shaving blocks off
/// the top does not help: 130,560 fails exactly as 131,072 does, and only at 65,536 does it become
/// clean. So the boundary is a hard 2¹⁶ somewhere in the chain of card, controller, bridge and bus
/// — a 64 KiB buffer or a 16-bit counter — and not an overflow of the stated figure by a few bytes
/// of command overhead.
///
/// Nothing else on the machine asks for that pattern. A file copy through the filesystem writes
/// 131,072-byte transfers to the same reader all day without losing a byte, because it never lays
/// its writes out as a long contiguous run punctuated by a half-size hole. `CopyBatch.flush` does,
/// necessarily: it sorts a generation's spans by destination and writes them ascending, which is
/// precisely long contiguous runs with occasional gaps. The defragmenter asks this device for the
/// one thing it cannot do.
///
/// ## Why a probe, and why this one
///
/// The obvious objection to probing is that the fault is rare — three bad transfers in 107,801. But
/// that is the rate of the *pattern* in a run, not the reliability of the device: given the pattern
/// it fails every single time, at the same addresses, unaffected by buffer alignment. So a probe
/// that merely writes and reads back would pass and prove nothing, while a probe that deliberately
/// provokes the pattern catches this device on every attempt, in a few hundred kilobytes.
///
/// The other half of the answer is the stopwatch. On the reader above, throughput climbs
/// monotonically to 65,536 and then falls off a cliff — 18.9 MB/s of writes at 64 KiB against
/// 13.6 MB/s at 128 KiB. The fastest size and the largest safe size turn out to be the same size,
/// so the ceiling costs nothing, and a size that is anomalously slow is itself a warning. Choosing
/// on measured throughput also makes the question of *how far* to back off answer itself: if some
/// other card is fastest at 16 KiB, that is what gets used and where the cliff sits stops mattering.
///
/// ## What it costs
///
/// A few hundred kilobytes of writes for the safety sweep and a handful of megabytes for the timing,
/// into spare clusters, once per run. Skipped where it cannot apply: a dry run must not write, and a
/// plain file has no controller to misbehave — an image answers no transfer-limit ioctl at all, which
/// is the signal used here.
struct TransferProbe {
    /// One candidate size, and what the medium did with it.
    struct Attempt: Sendable {
        let size: Int
        /// Nil where the size was not timed — the sweep only times sizes that passed.
        let bytesPerSecond: Double?
        /// The gap that broke it, where one did.
        let failingGap: Int?
        /// How far the bytes were from where they were sent, where they could be located at all.
        let displacement: Int?
        /// Which directions it failed in. Both are tested for every gap rather than stopping at the
        /// first, because a size broken both ways should say so: this reader is, and reporting only
        /// the write half would understate what the medium is doing.
        let directions: [Direction]

        var isSafe: Bool { failingGap == nil }
    }

    /// What the probe concluded, in enough detail to be reported rather than merely obeyed.
    struct Outcome: Sendable {
        /// What the device claimed before any of this.
        let stated: Int
        /// What will actually be used.
        let chosen: Int
        /// Every candidate tried, largest first.
        let attempts: [Attempt]

        /// Whether a size the device advertised was found to mishandle data.
        var caughtLying: Bool { attempts.contains { !$0.isSafe } }
        /// Whether the choice was made on speed rather than forced by safety.
        var narrowedForSpeed: Bool {
            !caughtLying && chosen < stated
        }
    }

    /// Whether the probe ran, and if not, why not — which matters as much as the answer. A run that
    /// skipped the probe is a run trusting a number no one checked, and that is precisely the
    /// situation that cost 177 files on the card this exists for. Silence there would be the same
    /// mistake in a new place.
    enum Result: Sendable {
        case measured(Outcome)
        /// A dry run cannot write, so only the read half of the sweep ran. Worth having rather than
        /// skipping: the read fault on the reader this exists for is the more reproducible of the
        /// two, and a dry run that read at the unsafe size would report corruption that is not
        /// there — which is exactly the false alarm that cost an afternoon here, raised by a
        /// verification pass reading a card with a ruler the card corrupts.
        case readsOnly(Outcome)
        /// A dry run on a medium with no spare room even to read a pattern in.
        case dryRun
        /// A plain file has no controller to misbehave; it answers no transfer-limit ioctl at all,
        /// which is the signal used.
        case notADevice
        /// Not enough free space in one piece to provoke the pattern at the size about to be used.
        /// Testing only sizes far below that would prove nothing about the size in question.
        case noRoom(largestFreeRun: Int, needed: Int)
    }

    /// Smallest size worth considering. Below this the per-transfer overhead dominates so heavily
    /// that a volume would take all day, and a device this broken is not one to defragment.
    static let floor = 4096

    /// How many contiguous spare bytes the probe would like: enough for the safety sweep, plus a few
    /// megabytes to time each surviving size over. Asked for as one run because the pattern under
    /// test *is* contiguity.
    static func spacePreferred(forStated stated: Int) -> Int {
        patternSpace(for: stated) + (16 << 20)
    }

    /// The least it can do anything useful with: enough to provoke the pattern at the size actually
    /// about to be used. Below this the probe is skipped rather than run on sizes nobody will use —
    /// proving that 8 KiB transfers are safe says nothing about the 128 KiB ones the run will issue.
    static func spaceRequired(forStated stated: Int) -> Int {
        patternSpace(for: stated)
    }

    /// The longest free run to work in, capped at `wanting`, along with how much was actually found.
    /// The region is nil where the best run falls short of `atLeast`.
    ///
    /// Searched from the top of the volume downwards on purpose. The compacted layout fills from
    /// cluster 2 upwards, so the far end is both the part least likely to be wanted by this run and
    /// the part whose contents nothing refers to. Writing there leaves the region the compaction is
    /// about to fill exactly as it was found, which matters because the probe runs before the scan
    /// and must not disturb what the scan is about to read.
    ///
    /// A nearly full volume is the case this has to get right. A defragment needs very little free
    /// space to make progress — it can park an object aside and work in the gap — so "there was room
    /// to shuffle" does not imply "there was room in one piece to provoke a pattern in". Where the
    /// room is not there, the caller says so rather than the probe quietly not happening.
    static func spareRegion(in volume: FATVolume, wanting: Int,
                            atLeast minimum: Int) -> (region: ClusterSet?, largest: Int) {
        let cap = (wanting + volume.clusterSize - 1) / volume.clusterSize
        let floor = (minimum + volume.clusterSize - 1) / volume.clusterSize
        guard volume.countOfClusters >= 2 else { return (nil, 0) }
        var best = 0
        var bestStart = 0
        var top: Int?
        var cluster = Int(volume.countOfClusters) + 1
        while cluster >= 2 {
            guard cluster < volume.fat.count else { cluster -= 1; continue }
            let free = volume.fat[cluster] == 0 && !volume.badClusters.contains(UInt32(cluster))
            if free {
                if top == nil { top = cluster }
                let length = top! - cluster + 1
                if length > best { best = length; bestStart = cluster }
                if best >= cap { break }
            } else {
                top = nil
            }
            cluster -= 1
        }
        let bytes = best * volume.clusterSize
        guard best >= floor else { return (nil, bytes) }
        return (.run(from: UInt32(bestStart), count: UInt32(min(best, cap))), bytes)
    }

    /// The read half alone, for a dry run: no writes, so nothing to restore and nothing at risk.
    ///
    /// It asks the medium to contradict itself — each candidate size read once at that size after the
    /// run-up that provokes the fault, and once in small pieces — which needs no known content and
    /// therefore no writes. Less thorough than the full sweep, since a device that only mishandles
    /// writes will pass. But a dry run's whole job is to read the volume and report on it, and doing
    /// that at a size the medium mishandles produces a report about the ruler rather than the volume.
    static func measureReadsOnly(volume: FATVolume, region: ClusterSet) throws(FATError) -> Outcome {
        let stated = FATVolume.maxTransfer
        let start = volume.offset(ofCluster: region[0])
        let available = region.count * volume.clusterSize

        var attempts: [Attempt] = []
        var safe: [Int] = []
        var size = stated
        while size >= floor {
            defer { size /= 2 }
            guard size % volume.blockSize == 0, patternSpace(for: size) <= available else { continue }
            var failed: Int?
            for gap in Set([size / 2, size / 4, size, volume.blockSize])
                .filter({ $0 > 0 && $0 % volume.blockSize == 0 }).sorted(by: >) {
                let target = start + UInt64(size * 3 + gap)
                guard target + UInt64(size) <= start + UInt64(patternSpace(for: size)) else { continue }
                if try readsDisagree(volume: volume, start: start, target: target, size: size) {
                    failed = gap
                    break
                }
            }
            attempts.append(Attempt(size: size, bytesPerSecond: nil, failingGap: failed,
                                    displacement: nil, directions: failed == nil ? [] : [.reading]))
            if failed == nil { safe.append(size) }
        }
        return Outcome(stated: stated, chosen: safe.first ?? stated, attempts: attempts)
    }

    /// Runs the sweep and returns what should be used.
    ///
    /// - Parameter region: a run of clusters that is free on the medium. Everything written here is
    ///   written to space the filesystem does not refer to, so there is nothing to restore
    ///   afterwards and an interruption part way through costs nothing.
    static func measure(volume: FATVolume, region: ClusterSet) throws(FATError) -> Outcome {
        let stated = FATVolume.maxTransfer
        let start = volume.offset(ofCluster: region[0])
        let available = region.count * volume.clusterSize

        // Largest first, halving. The boundary measured on real hardware sits on a power of two, so
        // halving finds it in one step; a finer search would spend time to arrive at the same place.
        var candidates: [Int] = []
        var size = stated
        while size >= floor {
            if size % volume.blockSize == 0 { candidates.append(size) }
            size /= 2
        }

        var attempts: [Attempt] = []
        var safeSizes: [Int] = []
        for candidate in candidates {
            guard patternSpace(for: candidate) <= available else { continue }
            if let failure = try haunt(volume: volume, at: start, size: candidate) {
                attempts.append(Attempt(size: candidate, bytesPerSecond: nil,
                                        failingGap: failure.gap,
                                        displacement: failure.displacement,
                                        directions: failure.directions))
                // Keep going rather than stopping at the first failure: the report is more use for
                // saying "128 KiB is broken and 64 KiB is not" than for saying only the latter.
                continue
            }
            safeSizes.append(candidate)
            attempts.append(Attempt(size: candidate, bytesPerSecond: nil,
                                    failingGap: nil, displacement: nil, directions: []))
        }

        guard let largestSafe = safeSizes.first else {
            // Nothing the device advertised can be trusted at any size this is willing to use. That
            // is not a volume to shuffle a quarter of a million files around on.
            throw FATError.io("""
                This device mishandles writes at every transfer size from \(stated) bytes down to \
                \(TransferProbe.floor). Each one was written to spare space and read straight back, \
                and the bytes that came back were not the bytes sent. Nothing this tool does can \
                make that safe, so the run has stopped before touching anything that matters.

                Nothing was written outside free space, so the volume is exactly as it was found.
                """)
        }

        // Time the safe sizes and take the fastest. On the reader this was written for the fastest is
        // also the largest safe one, which is the happy case; where it is not, throughput is the
        // better guide, and it makes the size of the back-off a measurement rather than a choice.
        var timed: [Int: Double] = [:]
        let timingRoom = available - patternSpace(for: stated)
        if timingRoom >= (4 << 20) {
            let pass = min(8 << 20, timingRoom)
            let base = start + UInt64(patternSpace(for: stated))
            for candidate in safeSizes where candidate >= 16384 || safeSizes.count == 1 {
                timed[candidate] = try time(volume: volume, at: base, size: candidate, bytes: pass)
            }
        }

        // The largest safe size wins unless a smaller one is faster by a margin that cannot be
        // timing noise. Without that requirement this backs off on nothing: a run against an image
        // at 200 MB/s measured 512 KiB a hair above 1 MiB and duly halved the transfer size for no
        // reason at all. The margin measured on the reader this exists for is 39% — 18.9 MB/s at
        // 64 KiB against 13.6 at 128 — so a real cliff clears this bar easily and jitter does not.
        let margin = 1.20
        var chosen = largestSafe
        if let baseline = timed[largestSafe],
           let (fastest, rate) = timed.max(by: { $0.value < $1.value }),
           rate > baseline * margin {
            chosen = fastest
        }
        let annotated = attempts.map {
            Attempt(size: $0.size, bytesPerSecond: timed[$0.size],
                    failingGap: $0.failingGap, displacement: $0.displacement,
                    directions: $0.directions)
        }
        return Outcome(stated: stated, chosen: chosen, attempts: annotated)
    }

    /// Bytes the safety sweep needs for one candidate: three writes, a half-size gap, one more, and
    /// a size of slack so the poison ahead of the target cannot be mistaken for a result.
    private static func patternSpace(for size: Int) -> Int { size * 5 }

    /// Which direction a size failed in. Both are tested because both are haunted: on the reader
    /// this exists for, the same pattern in reads makes a 131,072-byte read disagree with the same
    /// range read in 4 KiB pieces, at 361 of 400 positions tried — far more reproducible than the
    /// write fault, and invisible to a probe that only writes. One ceiling governs both directions,
    /// so either finding is enough to back off; but a device haunted on reads alone would sail
    /// through a write-only probe, and that is not a hole worth leaving.
    enum Direction: String, Sendable {
        case writing
        case reading
    }

    private struct Failure {
        let gap: Int
        let displacement: Int?
        let directions: [Direction]
    }

    /// The haunting. Returns nil where the device did what it was told.
    ///
    /// Every 512-byte block written names the offset it belongs at, so a block that turns up
    /// somewhere else reports its own displacement instead of leaving it to be inferred. The target
    /// is filled first with blocks naming a quite different address, so a pass cannot be a leftover
    /// from an earlier attempt: the only way to read the right answer is for the write to have
    /// actually landed.
    private static func haunt(volume: FATVolume, at start: UInt64,
                              size: Int) throws(FATError) -> Failure? {
        // The gaps worth trying. Half the size is the one that breaks the reader this was written
        // for; the others cost a few hundred kilobytes each and cover a device that is broken
        // differently. A gap has to be a whole number of blocks to be addressable at all.
        let gaps = [size / 2, size / 4, size, volume.blockSize]
            .filter { $0 > 0 && $0 % volume.blockSize == 0 }
        for gap in Set(gaps).sorted(by: >) {
            let target = start + UInt64(size * 3 + gap)
            guard target + UInt64(size) <= start + UInt64(patternSpace(for: size)) else { continue }

            try write(volume: volume, at: target, size: size, naming: target &+ 0x4000_0000)
            try volume.synchronize()

            for index in 0 ..< 3 {
                let at = start + UInt64(size * index)
                try write(volume: volume, at: at, size: size, naming: at)
            }
            try write(volume: volume, at: target, size: size, naming: target)
            try volume.synchronize()

            // Read back at a size small enough not to be under suspicion itself, and off the medium
            // rather than out of the cache — the whole question is what the medium holds.
            let back = try volume.readUncached(at: target, count: size)
            var directions: [Direction] = []
            let displacement = firstDisagreement(in: back, expecting: target,
                                                 blockSize: volume.blockSize)
            if displacement != nil { directions.append(.writing) }

            // The same pattern in the other direction, over the bytes the write phase just laid
            // down — convenient rather than incidental: the range is known, so a disagreement can
            // only be the reading of it. Asked as "does the medium contradict itself": once at the
            // size under test, once in small pieces that every sweep has found clean.
            //
            // Asked even where the write already failed, so that a size broken both ways is reported
            // as broken both ways. On this reader it is, and the read half is by far the more
            // reproducible: 361 of 400 positions against roughly three writes in 107,801.
            if try readsDisagree(volume: volume, start: start, target: target, size: size) {
                directions.append(.reading)
            }
            if !directions.isEmpty {
                return Failure(gap: gap, displacement: displacement, directions: directions)
            }
        }
        return nil
    }

    /// Whether reading a range at `size` disagrees with reading it in small pieces, after the same
    /// run-up that provokes the write fault.
    private static func readsDisagree(volume: FATVolume, start: UInt64, target: UInt64,
                                      size: Int) throws(FATError) -> Bool {
        let ceiling = FATVolume.maxTransfer
        defer { FATVolume.maxTransfer = ceiling }

        FATVolume.maxTransfer = size
        for index in 0 ..< 3 {
            _ = try volume.readUncached(at: start + UInt64(size * index), count: size)
        }
        let whole = try volume.readUncached(at: target, count: size)

        // Small enough not to be under suspicion itself. A device broken at this size as well would
        // fail the write check first, which is the direction that loses data outright.
        FATVolume.maxTransfer = min(4096, size)
        let piecemeal = try volume.readUncached(at: target, count: size)
        return whole != piecemeal
    }

    /// Writes `size` bytes of blocks that each name `naming` plus their own position, as one
    /// transfer of exactly `size`.
    ///
    /// The transfer size is imposed by setting the ceiling around the call, because that is the one
    /// thing under test: `rawWrite` chunks at `FATVolume.maxTransfer`, so the ceiling is what decides
    /// whether the device sees one 131,072-byte command or two of 65,536.
    private static func write(volume: FATVolume, at offset: UInt64, size: Int,
                              naming base: UInt64) throws(FATError) {
        var bytes = [UInt8](repeating: 0, count: size)
        let block = volume.blockSize
        for position in stride(from: 0, to: size, by: block) {
            let stamp = Array("fatrabbit-probe-\(base &+ UInt64(position))-".utf8)
            for index in 0 ..< block {
                bytes[position + index] = stamp[index % stamp.count]
            }
        }
        let ceiling = FATVolume.maxTransfer
        FATVolume.maxTransfer = size
        defer { FATVolume.maxTransfer = ceiling }
        // `.fileData` so the cache drops these blocks and stores nothing: a probe that seeded the
        // cache with its own writes would then verify them against itself.
        try volume.writeRaw(Data(bytes), at: offset, retaining: .fileData)
    }

    /// The offset a block claims minus the offset it was found at, for the first block that
    /// disagrees. Nil where every block is where it belongs.
    private static func firstDisagreement(in bytes: [UInt8], expecting base: UInt64,
                                          blockSize: Int) -> Int? {
        for position in stride(from: 0, to: bytes.count, by: blockSize) {
            let expected = Array("fatrabbit-probe-\(base &+ UInt64(position))-".utf8)
            let holds = (0 ..< min(expected.count, blockSize)).allSatisfy {
                bytes[position + $0] == expected[$0]
            }
            if holds { continue }
            // Where did it come from? Read the number the block does carry, which names its home.
            let window = Array(bytes[position ..< min(position + 64, bytes.count)])
            let text = String(decoding: window, as: UTF8.self)
            if let claimed = Self.claimedOffset(in: text) {
                return Int(bitPattern: UInt(claimed &- (base &+ UInt64(position))))
            }
            return nil
        }
        return nil
    }

    private static func claimedOffset(in text: String) -> UInt64? {
        guard let range = text.range(of: "fatrabbit-probe-") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "-") else { return nil }
        return UInt64(rest[rest.startIndex ..< end])
    }

    /// Bytes per second for sequential writes of `size`, over `bytes` of spare space.
    ///
    /// Short on purpose. This is a comparison between sizes on the same medium moments apart, not an
    /// absolute figure, so a few megabytes is enough to separate 13 MB/s from 19 MB/s and keeps the
    /// whole probe inside a second or two.
    private static func time(volume: FATVolume, at offset: UInt64, size: Int,
                             bytes: Int) throws(FATError) -> Double {
        let payload = Data(repeating: 0xA5, count: size)
        let ceiling = FATVolume.maxTransfer
        FATVolume.maxTransfer = size
        defer { FATVolume.maxTransfer = ceiling }
        let started = ContinuousClock.now
        var done = 0
        while done < bytes {
            try volume.writeRaw(payload, at: offset + UInt64(done), retaining: .fileData)
            done += size
        }
        try volume.synchronize()
        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        return seconds > 0 ? Double(done) / seconds : 0
    }
}
