import Foundation

/// Carries out a relocation schedule without ever overwriting live data.
///
/// The schedule itself is worked out in memory by `RelocationPlanner`; this type only performs
/// it. Each relocation is a copy into free clusters followed by a commit:
///
///   1. copy the data into clusters the FAT says are free — nothing referenced is touched,
///   2. allocate the copy as a chain in the FAT,
///   3. flip every pointer to the object over to the copy,
///   4. release the original chain.
///
/// Steps 3 and 4 are deferred and settled by `commitPending`, which puts a durability barrier
/// before each: allocations reach the disk before anything names them, and the flips reach the
/// disk before the clusters they abandoned can be handed out. Those two barriers are the whole
/// of the safety argument. Without the first, a pointer could survive to a chain the FAT still
/// calls free, and a later allocation would give those clusters to something else. Without the
/// second, a pointer to the original could survive after the original had been released.
///
/// Because a generation's destinations are all clear before it begins, its moves cannot depend
/// on one another, so one pair of barriers covers the whole generation rather than each object.
///
/// Everything else is free to be lost. Deferred work that never lands leaves clusters allocated
/// but unreferenced, which is wasted space rather than damage, and which the next run reclaims
/// as orphans. An outstanding flip simply means the original is still the live copy — also
/// intact.
///
/// Nothing here knows anything about display. Every figure it keeps and every operation it performs
/// goes out as an event, unconditionally, and what any of that is worth saying is decided elsewhere.
final class SafeDefragmenter {
    private let volume: FATVolume
    private let plan: DefragPlan
    private let report: Reporter
    private let cleanup: MacCleanup?
    /// When set, no object is ever shoved aside to make room for another. Anything that cannot
    /// take its slot outright stays where it is, so nothing is ever copied twice.
    private let fast: Bool

    /// Working copy of the active FAT, kept in step with what has been written to disk except
    /// for `pendingFrees`, whose entries are still stale on disk.
    private var fat: [UInt32]
    /// Index into `objects` of whichever object owns each cluster; -1 for none.
    private var ownerIndex: [Int32]
    private let objects: [FSObject]
    private let lastCluster: UInt32

    /// Clusters released by a completed move whose FAT entries have not been written yet.
    ///
    /// Reusing one before its release is durable would leave the chain it came from still running
    /// through it on disk, and a crash at that point reads back as a cross-link. The schedule is
    /// built so this never arises within a generation; `move` still checks, as a backstop that
    /// would otherwise be a silent corruption.
    private var pendingFrees: Set<UInt32> = []
    /// Largest single copy held in memory at once, and so how much a generation's copies accumulate
    /// before the batch has to go out. Generous — this is not a memory-constrained tool — but
    /// bounded so a very large file does not have to be buffered whole.
    ///
    /// Every extra flush is a read pass followed by a write pass, and every turn between the two
    /// costs a seek on a spindle and a mode change on a card. A generation flushes once at its
    /// commit whatever this is, so that count is the floor and this only decides how far above it a
    /// run lands: over one 1.3 GB run in 59 generations, 8 MB gives 206 passes, 32 MB gives 87, and
    /// 64 MB gives 69 against a floor of 59. The remaining headroom is small here, but generations
    /// scale with the volume — on a 32 GB card averaging a couple of hundred megabytes each, the
    /// same doubling is worth some hundreds of turns rather than eighteen.
    private static let maxCopySpan = 64 * 1024 * 1024

    /// Holds a generation's copies so they go out as one read pass and one write pass. Emptied at
    /// the start of every commit, which is what keeps the data ahead of the FAT entries that
    /// allocate it.
    private let copies: CopyBatch

    /// Moves whose data and FAT chain are written but whose pointers have not been flipped yet.
    /// Deferring them lets one barrier cover a whole batch instead of one per object. While a
    /// flip is outstanding the volume simply still refers to the original, which is intact and
    /// identical — so an interruption loses the copy as an orphan and nothing more.
    private var pendingRepoints: [(object: FSObject, newStart: UInt32)] = []

    /// Clusters whose FAT entry has been set in memory but not yet written. Flushed at the start
    /// of a commit, before the barrier that lets anything point at them.
    private var dirtyFAT: Set<UInt32> = []

    /// Clusters currently free on disk, excluding `pendingFrees`. Lets an impossible request be
    /// rejected without scanning.
    private var freeClusters: UInt32 = 0

    /// Changes of contents held back until the data they describe is actually the live copy.
    ///
    /// A move only queues work — the copy leaves in a batch later, and until the commit flips the
    /// pointers the volume still names the original. Announcing the new contents when the move was
    /// made would be describing a volume that does not exist yet, so it waits for the commit that
    /// makes it true.
    private var pendingStateUpdates: [(clusters: ClusterSet, state: ClusterState)] = []

    /// Old clusters, held back until later still. Between the copy landing and the pointers being
    /// flipped there really are two copies on the volume, and the original really is still the live
    /// one, so it stays in use until the release is written.
    private var pendingFreed: [UInt32] = []

    private var skipped: [FSObject] = []
    /// Whether the run stopped short because a stop was asked for. The caller reports it and sets
    /// the exit status; everything written by then is committed either way.
    private(set) var wasInterrupted = false

    init(volume: FATVolume, plan: DefragPlan, report: Reporter, cleanup: MacCleanup?,
         fast: Bool = false) {
        self.volume = volume
        self.plan = plan
        self.report = report
        self.cleanup = cleanup
        self.fast = fast
        self.objects = plan.ordered
        self.fat = volume.fat
        self.lastCluster = volume.countOfClusters + 1
        self.copies = CopyBatch(volume: volume, budget: Self.maxCopySpan)

        var owners = [Int32](repeating: -1, count: Int(volume.countOfClusters) + 2)
        for (index, object) in plan.ordered.enumerated() {
            for cluster in object.chain where Int(cluster) < owners.count {
                owners[Int(cluster)] = Int32(index)
            }
        }
        self.ownerIndex = owners

        // Now that the tree is known, the run can say what each cluster actually holds rather than
        // merely that it is in use. Said here as well as during the scan so that the picture is
        // right regardless of how much of it the scan managed to paint.
        for object in plan.ordered {
            report.post(.clusters(object.chain, became: object.isContiguous ? .file : .displaced))
        }
        report.post(.clusters(.list(Array(volume.badClusters)), became: .bad))

        self.freeClusters = UInt32(fat[2 ... Int(volume.countOfClusters) + 1].count { $0 == 0 })

        copies.report = { [weak self] activity in self?.noteCopyActivity(activity) }
    }

    /// Reports a span of a batch reaching the medium. The moves that queued it all completed in
    /// milliseconds, so without this the only thing changing during the seconds a generation actually
    /// takes would be the clock.
    ///
    /// Both edges are reported — issued, then answered — because they are different facts. The bytes
    /// are not in hand until the second, and anything describing what the volume now holds belongs
    /// there. Reporting only one would make either the timing or the truth unavailable.
    private func noteCopyActivity(_ activity: CopyBatch.Activity) {
        let first = volume.cluster(atOffset: activity.offset)
        report.post(.transfer(RunEvent.Transfer(kind: activity.writing ? .write : .read,
                                               offset: activity.offset,
                                               bytes: activity.count,
                                               firstCluster: first,
                                               clusters: max(activity.count / volume.clusterSize, 1),
                                               index: activity.index,
                                               of: activity.total,
                                               done: activity.done)))
    }

    /// Records that `count` clusters became free, invalidating the largest-run bound.
    private func noteFreed(_ count: Int) {
        freeClusters += UInt32(count)
    }

    /// Which clusters a byte range falls in, for colouring the map — and none at all where it falls
    /// outside the data region.
    ///
    /// That second case is a FAT12/16 root, whose fixed region sits below the first cluster. The map
    /// draws the data area and has no cell for the region, so the honest answer is to light nothing:
    /// `cluster(atOffset:)` would clamp to cluster 2 and paint work onto a cluster the run is not
    /// touching.
    private func clusters(coveredBy offset: UInt64, count: Int) -> ClusterSet {
        guard offset >= volume.dataStartOffset else { return .list([]) }
        let first = volume.cluster(atOffset: offset)
        let last = volume.cluster(atOffset: offset + UInt64(max(count, 1) - 1))
        return .run(first ..< last + 1)
    }

    // MARK: - Top level

    func run() throws(FATError) {
        try setDirty(true)
        try applyCleanup()
        try reclaimOrphans()

        if !Interruption.requested {
            // Work the whole relocation out in memory first. With no disk in the way there is no
            // ordering constraint to trip over, so the layout is decided once and correctly, rather
            // than discovered a bit at a time and repeatedly revised.
            report.phase(.scheduling)
            let planningStarted = ContinuousClock.now
            let schedule = try RelocationPlanner.schedule(objects: objects,
                                                          bad: volume.badClusters,
                                                          lastCluster: lastCluster,
                                                          allowStaging: !fast,
                                                          report: report)
            report.post(.phaseCompleted(.scheduling,
                                        elapsed: planningStarted.duration(to: .now)))
            try execute(schedule)
        }

        if Interruption.requested {
            // The dot-entry check is skipped: relocation keeps those entries in step as it goes and
            // this pass only catches what it missed, so it is worth a pass over every directory at
            // the end of a completed run and not worth one when the answer to "are we done" is no.
            // The next run performs it in full.
            wasInterrupted = true
        } else {
            try repairDotEntries()
        }

        let finishingStarted = ContinuousClock.now
        try finalise()
        reportSummary()
        report.post(.phaseCompleted(.finishing, elapsed: finishingStarted.duration(to: .now)))
    }

    // MARK: - macOS cleanup

    private func applyCleanup() throws(FATError) {
        guard let cleanup else { return }

        if !cleanup.isEmpty {
            report.update {
                $0.metadataFilesRemoved = cleanup.removedFiles
                $0.metadataDirectoriesRemoved = cleanup.removedDirectories
                $0.metadataClustersRemoved = cleanup.removedClusters.count
            }
            report.phase(.removingMetadata)
            for name in cleanup.removedNames {
                report.post(.removed(object: name))
            }

            // Erase the directory entries first. Marking an entry deleted is a one-byte write,
            // so a name is either there or gone, never half-removed.
            //
            // Taken in device order, and covering only the span the edits actually fall in rather
            // than the whole run holding them: the same shape as `unhideDotEntries` below, and the
            // reason both can be expressed against a device offset alone. A run is usually a cluster
            // and on a FAT12/16 volume it can be the root's fixed region, which has no cluster
            // number to be read by — and it is where the root-level metadata being stripped lives.
            for (at, offsets) in cleanup.removals.sorted(by: { $0.key < $1.key }) {
                guard let low = offsets.min(), let high = offsets.max() else { continue }
                let span = high + DirectoryEntry.size - low
                let lit = clusters(coveredBy: at + UInt64(low), count: span)
                report.post(.working(RunEvent.Work(.clearing, lit)))
                try volume.updateBytes(at: at + UInt64(low), count: span) { window in
                    for offset in offsets { window[offset - low] = 0xE5 }
                }
                report.post(.working(RunEvent.Work(.clearing, lit, done: true)))
            }
            try volume.synchronize()

            // Only once the names are gone is it safe to release their clusters; losing this
            // write leaves them orphaned rather than referenced-but-free.
            var released: [UInt32] = []
            for cluster in cleanup.removedClusters where Int(cluster) < fat.count {
                fat[Int(cluster)] = 0
                ownerIndex[Int(cluster)] = -1
                released.append(cluster)
            }
            noteFreed(released.count)
            report.post(.clusters(.list(released), became: .free))
            try writeFATEntries(released)
        }

        try unhideDotEntries()
    }

    /// Clears the hidden attribute from `.` and `..`, which some writers set and which makes
    /// the directory look hidden to simple FAT readers. Attribute bytes are rewritten in place;
    /// a one-byte write cannot land half-done.
    ///
    /// The scan hands over the entries that are hidden, so this is a list of edits to apply rather
    /// than a search: nothing is read to find them, and on a volume where none are hidden — every run
    /// after the first — there is nothing here to do at all.
    private func unhideDotEntries() throws(FATError) {
        guard let cleanup, !cleanup.hiddenDots.isEmpty else { return }

        // Grouped by the run of directory data holding them, and taken in device order: `.` and `..`
        // sit side by side, so between them they cost one read-modify-write rather than one each, and
        // the writes then run up the volume rather than hopping about it.
        let byRun = Dictionary(grouping: cleanup.hiddenDots, by: \.at)
            .sorted { $0.key < $1.key }

        report.update {
            $0.hiddenAttributesFound = cleanup.hiddenDots.count
            $0.hiddenAttributeDirectories = byRun.count
        }
        report.phase(.clearingHiddenAttributes)
        let started = ContinuousClock.now
        var changed = 0
        for group in byRun {
            if Interruption.requested { break }

            let offsets = group.value.map(\.offset)
            let low = offsets.min() ?? 0
            let span = (offsets.max() ?? 0) + DirectoryEntry.size - low
            let lit = clusters(coveredBy: group.key + UInt64(low), count: span)
            report.post(.working(RunEvent.Work(.repointing, lit)))
            try volume.updateBytes(at: group.key + UInt64(low), count: span) {
                for offset in offsets {
                    $0[offset - low + DirectoryEntry.attributesOffset] &= ~UInt8(0x02)
                }
            }
            report.post(.working(RunEvent.Work(.repointing, lit, done: true)))
            changed += offsets.count
            // One update per directory, which is the pace of the write above: anything drawing from
            // this then moves whenever the thing being waited on does.
            report.update { $0.hiddenAttributesCleared = changed }
        }
        report.post(.phaseCompleted(.clearingHiddenAttributes,
                                    elapsed: started.duration(to: .now)))
        try volume.synchronize()
    }

    /// Releases clusters the FAT marks in use that no live chain reaches. They are unreferenced
    /// by definition, so freeing them cannot break anything, and it hands the layout more room.
    private func reclaimOrphans() throws(FATError) {
        var orphans: [UInt32] = []
        for cluster in 2 ... lastCluster {
            let entry = fat[Int(cluster)]
            if entry != 0, entry != volume.flavour.badCluster, ownerIndex[Int(cluster)] < 0 {
                orphans.append(cluster)
            }
        }
        guard !orphans.isEmpty else { return }

        report.update { $0.orphansReclaimed = orphans.count }
        for cluster in orphans { fat[Int(cluster)] = 0 }
        noteFreed(orphans.count)
        report.post(.clusters(.list(orphans), became: .free))
        try writeFATEntries(orphans)
        try volume.synchronize()
    }

    // MARK: - Layout

    /// Executes a schedule worked out in advance. Each generation's destinations are clear before
    /// it starts, so its moves are independent of one another and the whole generation is settled
    /// with a single pair of durability barriers.
    private func execute(_ schedule: RelocationSchedule) throws(FATError) {
        for index in schedule.unplaceable { skipped.append(objects[index]) }

        // Progress is measured in clusters copied, not moves completed: moves range from one
        // cluster to thousands, so counting them would jump about while telling you little.
        //
        // Summed from the generations rather than taken from `totalClusters`, which counts each
        // object once — an object staged through spare space is copied twice, so the denominator
        // has to be the copying actually scheduled or the figure runs past 100%.
        let scheduled = schedule.generations.reduce(0) { running, generation in
            running + generation.reduce(0) { $0 + $1.destination.count }
        }
        let total = schedule.generations.count
        report.update {
            $0.plannedMoves = schedule.moveCount
            $0.plannedClusters = UInt32(schedule.totalClusters)
            $0.generations = total
            $0.generationCount = total
            $0.stagedHops = schedule.temporaryHops
            $0.clustersScheduled = scheduled
            $0.objectsToSchedule = 0
        }
        report.phase(.defragmenting)

        // Everything the schedule intends to shift, so that the work outstanding can be told apart
        // from where the data merely happens to be. It drains to "in place" as the generations
        // complete, which is the run's actual progress laid out over the volume.
        for generation in schedule.generations {
            for relocation in generation {
                report.post(.clusters(objects[relocation.objectIndex].chain, became: .displaced))
            }
        }

        var copied = 0
        let started = ContinuousClock.now

        for (number, generation) in schedule.generations.enumerated() {
            report.update {
                $0.generation = number + 1
                $0.movesInGeneration = generation.count
                $0.moveInGeneration = 0
            }
            let generationStarted = ContinuousClock.now
            var clusters = 0
            var performed = 0
            for (index, relocation) in generation.enumerated() {
                // Between moves is the cheap place to stop: what has been copied so far is
                // committed below, and the moves not started are simply never started.
                if Interruption.requested { break }

                let object = objects[relocation.objectIndex]
                let origin = object.chain
                try move(object, index: Int32(relocation.objectIndex), to: relocation.destination,
                         temporary: relocation.isTemporary)
                clusters += relocation.destination.count
                performed += 1
                report.post(.relocated(object: object.label,
                                       from: origin,
                                       to: relocation.destination,
                                       staged: relocation.isTemporary))

                // A single generation can be most of the work, and on a card it can run for minutes,
                // so the figures move per move rather than only at the end of one.
                report.update {
                    $0.moveInGeneration = index + 1
                    $0.movesDone += 1
                    $0.clustersDone = copied + clusters
                }
            }

            // One barrier pair for the whole generation. Nothing in it depended on anything else
            // in it, which is the entire reason this is safe.
            try commitPending()
            copied += clusters
            report.update { $0.clustersDone = copied }
            report.post(.generationCompleted(number: number + 1,
                                             of: total,
                                             moves: performed,
                                             clusters: UInt32(clusters),
                                             elapsed: generationStarted.duration(to: .now)))

            // Everything this generation copied is now committed, which makes this the tidiest
            // point in the whole run to walk away from.
            if Interruption.requested { break }
        }

        report.post(.phaseCompleted(.defragmenting, elapsed: started.duration(to: .now)))
    }

    /// - Parameter temporary: whether this is a staging hop rather than the object's final home. It
    ///   counts as work still outstanding, and the volume keeps the copy in memory — data parked in
    ///   spare space is written for no reason other than to be read back, so it is the one kind of
    ///   file content certain to be wanted twice.
    private func move(_ object: FSObject, index: Int32, to run: ClusterSet,
                      temporary: Bool = false) throws(FATError) {
        let old = object.chain

        // A cluster released by an earlier move is only free in memory until the pending
        // releases are written out. Claiming one before then would leave its previous chain
        // still threaded through it on disk, so make the release real first.
        if run.contains(where: { pendingFrees.contains($0) }) {
            report.update { $0.forcedFlushes += 1 }
            try commitPending()
        }

        // 1. Copy into free clusters. Nothing that anything points at is touched, so an
        //    interruption here leaves the volume exactly as it was.
        //
        //    Copied in the largest spans where source and destination are both unbroken, rather
        //    than a cluster at a time: the destination is always one run, so a source that is in
        //    one piece becomes a single read and a single write however many clusters it is.
        // Parked in spare space rather than housed, so it still has a move to come.
        let destinationState: ClusterState = temporary ? .displaced : .file
        // Both of the things the volume cannot work out for itself. A parked copy exists only to be read
        // back; a directory's clusters are read again the moment anything is pointed at them — every
        // child's `..`, the dot-entry check at the end, and every pointer flip that lands in them.
        let retention: FATVolume.Retention = temporary ? .staged
            : (object.isDirectory ? .directory : .fileData)
        var i = 0
        while i < old.count {
            var span = 1
            while i + span < old.count,
                  old[i + span] == old[i + span - 1] + 1,
                  run[i + span] == run[i + span - 1] + 1,
                  (span + 1) * volume.clusterSize <= Self.maxCopySpan {
                span += 1
            }
            try copies.copy(from: volume.offset(ofCluster: old[i]),
                            to: volume.offset(ofCluster: run[i]),
                            count: span * volume.clusterSize,
                            retaining: retention)
            i += span
        }

        // A directory's `.` entry names its own first cluster, and the copy above reproduced
        // the old value verbatim. Correct it in the copy — against `run`, since the object's
        // own chain still refers to where it is moving from. Folded into the buffered copy while
        // it is still in memory, so it costs nothing rather than a read-modify-write per directory.
        if object.isDirectory, !object.isRoot, let dot = object.dotOffset {
            try patchEntryStart(in: run, atOffset: dot, cluster: run[0])
        }

        // 2. Allocate the copy. Until step 3 nothing references it, so the worst it can be is
        //    an orphan chain. This must reach the disk before the pointers move.
        var claimed: UInt32 = 0
        for i in 0 ..< run.count {
            if fat[Int(run[i])] == 0 { claimed += 1 }
            fat[Int(run[i])] = (i == run.count - 1) ? volume.flavour.eoc : run[i + 1]
        }
        // Count what was actually taken from the free pool rather than assuming the whole run
        // came from it, so the tally cannot drift out of step with the FAT.
        freeClusters -= min(claimed, freeClusters)
        // Held back until the commit, where all of them go out together. Until then the clusters
        // are only allocated in memory — on disk they are still free and hold data nothing points
        // at, which an interruption simply leaves as unused space.
        dirtyFAT.formUnion(run)

        // 3. Queue the pointer flip. It is applied by `commitPending`, which syncs first so the
        //    allocation above is on disk before anything can point at it.
        pendingRepoints.append((object, run[0]))

        // 4. Release the original. Also deferred, and always written after the flips are
        //    durable. Losing either only leaves clusters allocated but unreferenced.
        pendingFrees.formUnion(old)
        for cluster in old { ownerIndex[Int(cluster)] = -1 }
        for cluster in run { ownerIndex[Int(cluster)] = index }
        object.chain = run
        report.update {
            $0.objectsMoved += 1
            $0.clustersMoved += UInt32(run.count)
        }

        pendingFreed.append(contentsOf: old)
        pendingStateUpdates.append((run, destinationState))
    }

    /// Points everything that refers to `object` at its new first cluster: the short entry in
    /// its parent, and — for a directory — the `..` entry of each subdirectory it holds.
    private func collectRepoint(_ object: FSObject, to newStart: UInt32,
                               into edits: inout [(offset: UInt64, cluster: UInt32)]) throws(FATError) {
        if object.isRoot {
            // Only reachable on FAT32, whose root is named by the boot record and nothing else. A
            // FAT12/16 root cannot move, so it is never in the schedule to arrive here.
            try writeRootCluster(newStart)
        } else if let parent = object.parent,
                  let offset = pointerField(in: parent, atOffset: object.entryOffset) {
            edits.append((offset, newStart))
        }

        // A `..` that names the root is stored as 0 by convention, so where the root is what moved,
        // every child's `..` already holds the right value and there is nothing to write. This used
        // to queue an edit per child anyway, writing 0 over 0 — which on a volume whose 2,102
        // directories all sit under the root meant 2,102 scattered single-block writes, and twice,
        // because the root is one of the objects the schedule parks in spare space. Measured at 7.7s
        // a time: 15.4s of a 6m 14s run spent changing nothing. Anything that did hold a wrong `..`
        // is caught by the verification pass at the end of the run, which exists for exactly that.
        if object.isDirectory, !object.isRoot {
            for child in object.children where child.isDirectory {
                guard let dotDot = child.dotDotOffset,
                      let offset = pointerField(in: child.chain, atOffset: dotDot) else { continue }
                edits.append((offset, newStart))
            }
        }
        // The edits are gathered rather than written so that everything landing in the same block
        // becomes one read-modify-write. No barrier is needed between them: the only ordering they
        // require is to precede the release of the old chains, and `commitPending` syncs before it
        // writes any release.
    }

    /// Absolute offset of the pointer field of the 32-byte entry at `offset` within a directory's
    /// data, resolved against the chain the directory currently occupies — which may itself have moved
    /// since the tree was walked. Nil where the offset falls past the end of the chain.
    ///
    /// Every pointer flip goes through this, so the arithmetic exists once: which cluster of the
    /// directory holds the entry, where in that cluster it sits, and where within the entry the
    /// pointer field starts.
    private func pointerField(in chain: ClusterSet, atOffset offset: Int) -> UInt64? {
        let clusterSize = volume.clusterSize
        let index = offset / clusterSize
        guard index < chain.count else { return nil }
        return volume.offset(ofCluster: chain[index])
            + UInt64(offset % clusterSize)
            + UInt64(DirectoryEntry.pointerFieldOffset)
    }

    /// The same, for a directory that might have no clusters to resolve against.
    ///
    /// The one that does is a FAT12/16 root, and this is the whole of what its being a fixed region
    /// costs the engine: every root-level object's pointer flip is a write into its parent, that
    /// parent is the root, and on those two variants the root's data is at a fixed offset rather
    /// than wherever its chain currently runs. Everything else goes through the chain form above,
    /// unchanged — including the root itself on FAT32.
    private func pointerField(in directory: FSObject, atOffset offset: Int) -> UInt64? {
        guard let fixedAt = directory.fixedAt else {
            return pointerField(in: directory.chain, atOffset: offset)
        }
        guard case .region(_, let size) = volume.rootLocation, offset < size else { return nil }
        return fixedAt + UInt64(offset) + UInt64(DirectoryEntry.pointerFieldOffset)
    }

    /// As `writeEntryStart`, but for data this generation has only just copied: offered to the copy
    /// batch, which folds it into the buffered bytes where it can and writes it to the medium where
    /// it cannot — which is only when the copy has already gone out.
    private func patchEntryStart(in chain: ClusterSet, atOffset offset: Int,
                                 cluster: UInt32) throws(FATError) {
        guard let field = pointerField(in: chain, atOffset: offset) else { return }
        try copies.setFirstCluster(at: field, to: cluster)
    }

    /// Writes a first-cluster pointer into the 32-byte entry at `offset` within `directory`'s
    /// data, resolving the offset against the directory's current chain.
    ///
    /// Both halves of the pointer go out together, carrying the timestamps between them across
    /// untouched, in one read-modify-write rather than a read plus a write that reads again.
    private func writeEntryStart(in chain: ClusterSet, atOffset offset: Int,
                                 cluster: UInt32) throws(FATError) {
        guard let field = pointerField(in: chain, atOffset: offset) else { return }
        try volume.setFirstCluster(at: field, to: cluster)
    }

    private func readEntryStart(in chain: ClusterSet, atOffset offset: Int) throws(FATError) -> UInt32? {
        guard let field = pointerField(in: chain, atOffset: offset) else { return nil }
        let bytes = try volume.readBytes(at: field, count: DirectoryEntry.pointerFieldSize)
        return DirectoryEntry.firstCluster(in: bytes, at: 0)
    }

    /// What a directory's `..` should name: its parent's first cluster, or 0 when the parent is the
    /// root, which is the convention FAT32 uses. `before` asks the same question of where things
    /// stood before this run relocated anything.
    private func parentStart(of object: FSObject, before: Bool = false) -> UInt32 {
        guard let parent = object.parent, !parent.isRoot else { return 0 }
        return before ? parent.originalStart : parent.chain[0]
    }

    /// Verifies every directory's own `.` and `..` against where things actually ended up, and
    /// corrects any that disagree. Relocation keeps these in step already; this is what repairs
    /// a volume left inconsistent by an earlier tool (including older builds of this one) and
    /// catches anything the layout missed.
    ///
    /// Both entries name a cluster number — the directory's own first cluster for `.`, its parent's
    /// for `..` — so an entry can only have needed writing if the number it names changed. Where
    /// neither did, this run wrote nothing there, the values the scan read are still what is on the
    /// disk, and the check is a comparison in memory rather than a read. That makes the pass cost a
    /// read per directory actually moved rather than one per directory on the volume, and nothing at
    /// all on a volume that was already in order.
    ///
    /// Where a number did change, the entry is read back rather than taken on trust. That read is
    /// the only end-to-end evidence that the pointer writes reached the medium, and it is worth
    /// having for the part of this that would be most expensive to get wrong.
    private func repairDotEntries() throws(FATError) {
        var moved: [FSObject] = []
        var settled: [FSObject] = []
        for object in objects where object.isDirectory && !object.isRoot {
            if object.chain[0] != object.originalStart
                || parentStart(of: object) != parentStart(of: object, before: true) {
                moved.append(object)
            } else {
                settled.append(object)
            }
        }

        // Damage that predates this run: nothing wrote over these entries, so a disagreement with
        // what the scan read is one the volume arrived with. Corrected without reading anything.
        var stale = 0
        for object in settled {
            if let dot = object.dotOffset, object.dotStart != object.chain[0] {
                try writeEntryStart(in: object.chain, atOffset: dot, cluster: object.chain[0])
                stale += 1
            }
            if let dotDot = object.dotDotOffset, object.dotDotStart != parentStart(of: object) {
                try writeEntryStart(in: object.chain, atOffset: dotDot, cluster: parentStart(of: object))
                stale += 1
            }
        }
        if stale > 0 { report.update { $0.preexistingDotEntriesFixed = stale } }

        guard !moved.isEmpty else {
            if stale > 0 { try volume.synchronize() }
            return
        }

        report.update { $0.directoriesToVerify = moved.count }
        report.phase(.verifying)
        let started = ContinuousClock.now
        var fixed = 0
        for (index, object) in moved.enumerated() {
            if Interruption.requested { break }

            report.update { $0.directoriesVerified = index }

            let start = object.chain[0]
            let expectedParent = parentStart(of: object)

            // `.` and `..` are the first two entries of the first cluster, so one read covers
            // both. Checking them costs a read per directory rather than one per entry, which
            // matters when there are tens of thousands of them and almost none need correcting.
            guard let dot = object.dotOffset, let dotDot = object.dotDotOffset,
                  dot + 32 <= 64, dotDot + 32 <= 64, let first = object.chain.first else {
                if let dot = object.dotOffset,
                   let current = try readEntryStart(in: object.chain, atOffset: dot), current != start {
                    try writeEntryStart(in: object.chain, atOffset: dot, cluster: start)
                    fixed += 1
                }
                if let dotDot = object.dotDotOffset,
                   let current = try readEntryStart(in: object.chain, atOffset: dotDot),
                   current != expectedParent {
                    try writeEntryStart(in: object.chain, atOffset: dotDot, cluster: expectedParent)
                    fixed += 1
                }
                continue
            }

            let head = try volume.readBytes(at: volume.offset(ofCluster: first),
                                            count: 2 * DirectoryEntry.size)
            let field = DirectoryEntry.pointerFieldOffset
            let dotValue = DirectoryEntry.firstCluster(in: head, at: dot + field)
            let dotDotValue = DirectoryEntry.firstCluster(in: head, at: dotDot + field)
            if dotValue != start {
                try writeEntryStart(in: object.chain, atOffset: dot, cluster: start)
                fixed += 1
            }
            if dotDotValue != expectedParent {
                try writeEntryStart(in: object.chain, atOffset: dotDot, cluster: expectedParent)
                fixed += 1
            }
        }
        report.update {
            $0.directoriesVerified = moved.count
            $0.staleDotEntriesFixed = fixed
        }
        report.post(.phaseCompleted(.verifying, elapsed: started.duration(to: .now)))
        if fixed > 0 || stale > 0 { try volume.synchronize() }
    }

    private func writeRootCluster(_ cluster: UInt32) throws(FATError) {
        var buffer = [UInt8](repeating: 0, count: 4)
        buffer.setLittleEndian(cluster, at: 0)
        try volume.writeBytes(buffer, at: 44)
        if volume.bpb.backupBootSector > 0 {
            let offset = UInt64(volume.bpb.backupBootSector * volume.bpb.bytesPerSector) + 44
            try volume.writeBytes(buffer, at: offset)
        }
    }

    // MARK: - FAT writing

    /// Writes the given clusters' entries, taken from the working FAT, to every FAT copy,
    /// coalescing consecutive clusters into single writes.
    ///
    /// - Parameter showing: reports the clusters each block covers as that block goes out. The FAT is
    ///   written in ascending block order and a block describes a contiguous run of clusters, so
    ///   this sweeps up the volume in step with the writes actually happening. Without it, a phase
    ///   that takes seconds has nothing to show for itself until it finishes and then changes
    ///   everything at once.
    private func writeFATEntries(_ clusters: [UInt32],
                                showing: RunEvent.Activity? = nil) throws(FATError) {
        guard !clusters.isEmpty else { return }
        // FAT12 cannot be written this way at all, and takes the whole-table path instead. Its
        // twelve-bit entries share bytes across block boundaries, which breaks the property
        // everything below rests on — see `writeWholeFAT`.
        guard let entrySize = volume.flavour.wholeEntrySize else {
            try writeWholeFAT(clusters, showing: showing)
            return
        }
        let blockSize = volume.blockSize
        let entriesPerBlock = UInt32(blockSize / entrySize)
        let fatByteCount = volume.fatByteCount

        // Grouped by the block each entry lands in rather than by runs of consecutive clusters.
        // A 512-byte block holds 128 entries, so two runs a single cluster apart used to cost a
        // read-modify-write each while landing in the same place: on one card a run of this made
        // 14,844 writes to 3,980 distinct blocks.
        var touched: Set<UInt32> = []
        for cluster in clusters { touched.insert(cluster / entriesPerBlock) }
        let blocks = touched.count * Int(volume.bpb.numFATs)
        report.update { $0.fatBlocksTouched += blocks }

        // Blocks that touch go out as one transfer. Allocations and releases run in cluster order,
        // so their FAT entries are often neighbours and the blocks holding them usually are too:
        // one run of a hundred clusters is a single write rather than a block at a time.
        var runs: [(first: UInt32, blocks: Int)] = []
        for block in touched.sorted() {
            if var last = runs.last, block == last.first + UInt32(last.blocks) {
                last.blocks += 1
                runs[runs.count - 1] = last
            } else {
                runs.append((first: block, blocks: 1))
            }
        }

        // Only the clusters actually being written are reported, not the whole block: a block covers
        // 128 of them and most of its neighbours are simply being carried along untouched.
        let lit: Set<UInt32>? = showing == nil ? nil : Set(clusters)
        for (step, run) in runs.enumerated() {
            let first = run.first * entriesPerBlock
            let entries = UInt32(run.blocks) * entriesPerBlock

            // Worked out once and reported on both sides of the write, so that the run stays named as
            // busy for exactly as long as the drive is being made to write it. Left nil where nobody
            // asked, which is what keeps the filter off the path that reports nothing.
            let touched: ClusterSet? = lit.map { .list((first ..< first + entries).filter($0.contains)) }
            if let showing, let touched {
                report.post(.working(RunEvent.Work(showing, touched, step: step, steps: runs.count)))
            }

            // Written whole, straight from the working copy of the FAT, which is authoritative for
            // every entry in the run: the only edits deliberately held back from the disk are the
            // releases, and those are not applied in memory until the moment they are written. So
            // the neighbours carried along are the values already there, and the write needs no
            // read of its own.
            var bytes = [UInt8](repeating: 0, count: run.blocks * blockSize)
            // One mutable window for the whole run rather than one per entry: a run can be a hundred
            // clusters, and taking the span once is the difference between a borrow and a bounds check
            // per store.
            do {
                var table = bytes.mutableSpan
                for index in 0 ..< Int(entries) {
                    let cluster = Int(first) + index
                    let value = cluster < fat.count ? fat[cluster] : 0
                    // Written at the entry's own width. Both widths that reach here are whole bytes
                    // and fixed, so an entry's place in the buffer is its index times that width and
                    // nothing about its cluster number enters into it — which is exactly what is not
                    // true of FAT12, and why FAT12 is not here.
                    if entrySize == 2 {
                        table.setLittleEndian(UInt16(truncatingIfNeeded: value), at: index * 2)
                    } else {
                        table.setLittleEndian(value, at: index * 4)
                    }
                }
            }

            for copy in 0 ..< volume.bpb.numFATs {
                let offset = volume.fatStartOffset + UInt64(copy * fatByteCount)
                    + UInt64(Int(first) * entrySize)
                if run.first == 0 {
                    // The exception. The first block also holds entries 0 and 1, and entry 1 carries
                    // the "volume is being modified" flag, which `setDirty` maintains on the disk and
                    // not in this copy — writing it whole would put the stale flag back and could
                    // leave a volume marked clean while it is being rewritten. So this run is read
                    // first and only the data entries are patched into it.
                    let prepared = bytes
                    try volume.updateBytes(at: offset, count: prepared.count) { window in
                        let source = prepared.span
                        var target = window.mutableSpan
                        // Everything past the reserved pair, as one byte range: entries here are
                        // fixed-width, so "all but the first two" has a single boundary rather than
                        // needing a walk entry by entry.
                        for byte in 2 * entrySize ..< prepared.count {
                            target[byte] = source[byte]
                        }
                    }
                } else {
                    try volume.writeBytes(bytes, at: offset)
                }
                report.update { $0.fatWrites += 1 }
            }

            if let showing, let touched {
                report.post(.working(RunEvent.Work(showing, touched, step: step,
                                                   steps: runs.count, done: true)))
            }
        }
    }

    /// Writes the table entire, to every copy, which is what FAT12 does instead of the above.
    ///
    /// A twelve-bit entry shares a byte with one of its neighbours, and that shared byte can be the
    /// last of a block. So the property the block-grouped path rests on — that a block can be
    /// written straight from the working copy without reading what is already there — does not hold:
    /// the first and last entry of every block are half-owned by the block next door. Rewriting the
    /// table whole sidesteps that rather than handling it, and can afford to, because a FAT12 table
    /// is at most 4,084 entries: some 6 KiB, against the 128 KiB a full FAT16 table reaches. There is
    /// no version of a FAT12 volume where this is expensive.
    ///
    /// The reserved pair is copied from what the volume arrived carrying rather than re-encoded from
    /// the working table, which is what makes the first-block special case above unnecessary here:
    /// entry 0's media descriptor and whatever entry 1 holds go back exactly as they were, so there
    /// is no stale dirty flag to put back and nothing for `setDirty` to fight with. On FAT12 there
    /// is no clean-shutdown bit in entry 1 to begin with.
    private func writeWholeFAT(_ clusters: [UInt32],
                               showing: RunEvent.Activity?) throws(FATError) {
        let flavour = volume.flavour
        let fatByteCount = volume.fatByteCount
        var bytes = [UInt8](repeating: 0, count: fatByteCount)
        do {
            var table = bytes.mutableSpan
            for cluster in 2 ..< fat.count {
                flavour.setEntry(fat[cluster], forCluster: UInt32(cluster), in: &table)
            }
            // Verbatim, and last, so it cannot be disturbed by the entry-2 write sharing a byte with
            // it — which on FAT12 it does not, the pair filling bytes 0 to 2 exactly, but the order
            // costs nothing and does not depend on that holding.
            let reserved = volume.fatReservedBytes
            for index in 0 ..< reserved.count { table[index] = reserved[index] }
        }

        // One transfer per copy, and the whole table each time, so there is one step to report rather
        // than a sweep. What is lit is the clusters whose entries changed, not the whole table: the
        // rest is being carried along untouched, exactly as in the block-grouped path.
        let lit = ClusterSet.list(clusters.sorted())
        report.update { $0.fatBlocksTouched += (fatByteCount / volume.blockSize) * volume.bpb.numFATs }
        for copy in 0 ..< volume.bpb.numFATs {
            if let showing {
                report.post(.working(RunEvent.Work(showing, lit, step: copy,
                                                   steps: volume.bpb.numFATs)))
            }
            try volume.writeBytes(bytes, at: volume.fatStartOffset + UInt64(copy * fatByteCount))
            report.update { $0.fatWrites += 1 }
            if let showing {
                report.post(.working(RunEvent.Work(showing, lit, step: copy,
                                                   steps: volume.bpb.numFATs, done: true)))
            }
        }
    }

    /// Settles everything held back, in the only order the guarantees allow:
    ///
    ///   allocations on disk → pointers flipped → originals released
    ///
    /// Each arrow is a barrier. Batching is what makes them affordable: one pair of barriers
    /// covers a whole run of moves rather than a pair per move. Nothing in between is ever
    /// visible as an inconsistent volume — an outstanding flip just means the original is still
    /// the live copy, and an unwritten release just leaves clusters allocated but unreferenced.
    private func commitPending() throws(FATError) {
        // Before anything else: the copies this commit is about to allocate have to be on the medium
        // first. Doing it here rather than at the end of a generation covers the commits that `move`
        // forces part way through one as well.
        try copies.flush()

        let allocations = dirtyFAT.count
        let flips = pendingRepoints.count
        let releases = pendingFrees.count
        if allocations == 0, flips == 0, releases == 0 {
            pendingStateUpdates.removeAll(keepingCapacity: true)
            pendingFreed.removeAll(keepingCapacity: true)
            return
        }
        report.update { $0.commits += 1 }
        report.post(.commit(number: report.telemetry.commits,
                            allocations: allocations,
                            flips: flips,
                            releases: releases))

        // Chain entries first, coalesced into as few writes as their cluster numbers allow.
        // Writing them per move meant a handful of scattered 512-byte read-modify-writes each
        // time, which is the slowest thing a card can be asked to do.
        let allocated = Array(dirtyFAT)
        var repointed: [UInt32] = []
        if !dirtyFAT.isEmpty {
            report.post(.working(RunEvent.Work(.allocating, .list(allocated))))
            try report.timing(\.allocating) { () throws(FATError) in try writeFATEntries(allocated) }
            report.post(.working(RunEvent.Work(.allocating, .list(allocated), done: true)))
            dirtyFAT.removeAll(keepingCapacity: true)
        }

        if !pendingRepoints.isEmpty {
            // Barrier: every copy must be allocated on disk before anything names it.
            let barrier = RunEvent.Barrier(kind: .allocations, clusters: .list(allocated))
            report.post(.barrier(barrier, done: false))
            try report.timing(\.barriers) { () throws(FATError) in try volume.synchronize() }
            report.update { $0.barrierCount += 1 }
            report.post(.barrier(barrier, done: true))

            var edits: [(offset: UInt64, cluster: UInt32)] = []
            edits.reserveCapacity(pendingRepoints.count)
            for (object, newStart) in pendingRepoints {
                try collectRepoint(object, to: newStart, into: &edits)
            }
            let blocks = try report.timing(\.repointing) { () throws(FATError) in
                try volume.applyEntryPointers(edits) { [self] progress in
                    // Directory entries live in ordinary clusters, so this part of the commit is
                    // visible on the volume: the parent directories are worked over as their
                    // pointers are flipped. Which of the two sweeps this belongs to is carried
                    // through rather than inferred — they cover the same blocks in the same order.
                    report.post(.working(RunEvent.Work(progress.writing ? .repointing : .gathering,
                                                       [volume.cluster(atOffset: progress.offset)],
                                                       step: progress.step,
                                                       steps: progress.steps,
                                                       done: progress.done)))
                }
            }
            report.update {
                $0.entryBlockWrites += blocks
                $0.entryPointerEdits += edits.count
            }
            repointed = edits.map { volume.cluster(atOffset: $0.offset) }
            pendingRepoints.removeAll(keepingCapacity: true)
        }

        // The volume now names the copies, so they stop being provisional and become the live data.
        // This is the moment the run's work becomes real, and it is worth being the moment anything
        // drawing it changes: before it, an interruption would have left every one of these clusters
        // an orphan.
        for update in pendingStateUpdates {
            report.post(.clusters(update.clusters, became: update.state))
        }
        pendingStateUpdates.removeAll(keepingCapacity: true)

        guard !pendingFrees.isEmpty else { return }
        // Barrier: those flips must be on disk before the clusters they abandoned are reused.
        //
        // The longest silence in a generation, and the reason the releases that follow it appear to
        // happen instantly: those go to the page cache and return, while the drive is still catching
        // up with everything handed to it here.
        let pointerBarrier = RunEvent.Barrier(kind: .pointers, clusters: .list(repointed))
        report.post(.barrier(pointerBarrier, done: false))
        try report.timing(\.barriers) { () throws(FATError) in try volume.synchronize() }
        report.update { $0.barrierCount += 1 }
        report.post(.barrier(pointerBarrier, done: true))

        let clusters = Array(pendingFrees)
        pendingFrees.removeAll(keepingCapacity: true)
        var released = 0
        for cluster in clusters where fat[Int(cluster)] != volume.flavour.badCluster
            && ownerIndex[Int(cluster)] < 0 {
            fat[Int(cluster)] = 0
            released += 1
        }
        noteFreed(released)
        // Reported block by block as the FAT is written, so the originals are visibly given up as it
        // sweeps up the volume rather than all at once when it finishes.
        try report.timing(\.releasing) { () throws(FATError) in
                try writeFATEntries(clusters, showing: .clearing)
            }

        // Only now are the originals genuinely gone. Until this write, they were still the copy the
        // volume pointed at, and calling them free would have been describing a volume that did not
        // exist yet.
        if !pendingFreed.isEmpty { report.post(.clusters(.list(pendingFreed), became: .free)) }

        // And the same fact told to the cache, which cannot deduce it. These clusters hold data nothing
        // refers to any more, so anything kept for them is answering a question that will not be asked.
        // The reason to bother is staged data: it is written only to be read back once, and it sits in
        // the spare region at the top of the volume that the layout never writes to, so it is the one
        // kind that is never dropped incidentally and would otherwise be held until the run exited.
        volume.forget(pendingFreed)
        pendingFreed.removeAll(keepingCapacity: true)
    }

    // MARK: - Finishing up

    private func finalise() throws(FATError) {
        report.phase(.finishing)
        var free: UInt32 = 0
        var nextFree: UInt32 = 0xFFFF_FFFF
        for cluster in 2 ... lastCluster where fat[Int(cluster)] == 0 {
            free += 1
            if nextFree == 0xFFFF_FFFF { nextFree = cluster }
        }

        // The running tally is only an optimisation, but if it ever disagrees with the FAT then
        // allocation decisions were made on bad information. Both figures go out; whether the
        // disagreement is worth mentioning is not this type's business.
        report.update {
            $0.freeCountRecorded = freeClusters
            $0.freeCountActual = free
        }
        freeClusters = free

        let bpb = volume.bpb
        let bps = bpb.bytesPerSector

        // Everything below this point is FAT32's boot record: the root cluster, the mirroring flag,
        // and the FSInfo sector. FAT12/16 have none of the three — their root is at a fixed place
        // that cannot have changed, they have no mirroring flag, and they carry no free-cluster
        // count — so there is nothing in their reserved region for a completed run to bring up to
        // date, and the whole of this is skipped rather than written past.
        if volume.flavour.hasRelocatableRoot {
            let rootStart = objects.first?.chain.first ?? bpb.rootCluster

            var reserved = try volume.readBytes(at: 0, count: bpb.reservedSectorCount * bps)
            patchBootSector(&reserved, at: 0, rootStart: rootStart)
            patchFSInfo(&reserved, sector: bpb.fsInfoSector, bps: bps, free: free, next: nextFree)
            if bpb.backupBootSector > 0 {
                patchBootSector(&reserved, at: bpb.backupBootSector * bps, rootStart: rootStart)
                patchFSInfo(&reserved, sector: bpb.backupBootSector + 1, bps: bps,
                            free: free, next: nextFree)
            }
            try volume.writeBytes(reserved, at: 0)
            try volume.synchronize()
        }

        try setDirty(false)
    }

    /// Patches the boot sector at `offset`: root cluster, and mirroring forced on to match the
    /// identical FAT copies every write keeps in step. FAT32 only — both fields are its own.
    private func patchBootSector(_ buf: inout [UInt8], at offset: Int, rootStart: UInt32) {
        guard offset + 512 <= buf.count else { return }
        buf.setLittleEndian(UInt16(0), at: offset + 40)
        buf.setLittleEndian(rootStart, at: offset + 44)
    }

    private func patchFSInfo(_ buf: inout [UInt8], sector: Int, bps: Int, free: UInt32, next: UInt32) {
        guard sector > 0 else { return }
        let o = sector * bps
        guard o + 512 <= buf.count else { return }
        guard buf.littleEndian(UInt32.self, at: o) == 0x4161_5252,
              buf.littleEndian(UInt32.self, at: o + 484) == 0x6141_7272 else { return }
        buf.setLittleEndian(free, at: o + 488)
        buf.setLittleEndian(next, at: o + 492)
    }

    /// Marks the volume dirty for the duration of the run, so that an interruption is visible
    /// to the operating system and gets checked rather than silently mounted.
    ///
    /// Two flags, and not every variant has both. Table entry 1 carries the clean-shutdown bit —
    /// bit 27 on FAT32, bit 15 on FAT16 — and is read-modify-written at its own width so the
    /// reserved bits around it survive untouched. The boot record carries the flag Windows looks at,
    /// at offset 65 on FAT32 and offset 37 on the other two: the same field of each variant's
    /// extended BPB, landing in a different place only because FAT32's BPB is the longer one.
    ///
    /// **FAT12 has no clean-shutdown bit**, twelve bits leaving no room for one, so there the boot
    /// flag is the whole of the signal. That is a real reduction in this guarantee on FAT12 rather
    /// than an oversight here — a FAT12 volume interrupted mid-run is flagged in the boot record and
    /// nowhere else — and it is the reason `cleanShutdownBit` is an optional rather than a constant.
    private func setDirty(_ dirty: Bool) throws(FATError) {
        let flavour = volume.flavour
        if let bit = flavour.cleanShutdownBit {
            let field = flavour.byteRange(ofCluster: 1)
            for copy in 0 ..< volume.bpb.numFATs {
                let offset = volume.fatStartOffset + UInt64(copy * volume.fatByteCount)
                    + UInt64(field.lowerBound)
                var raw = try volume.readBytes(at: offset, count: field.count)
                // Read at the entry's own width, so the bytes either side of a 16-bit entry 1 are
                // never in the window to be disturbed in the first place.
                var value = field.count == 2 ? UInt32(raw.littleEndian(UInt16.self, at: 0))
                                             : raw.littleEndian(UInt32.self, at: 0)
                if dirty { value &= ~bit } else { value |= bit }
                if field.count == 2 {
                    raw.setLittleEndian(UInt16(truncatingIfNeeded: value), at: 0)
                } else {
                    raw.setLittleEndian(value, at: 0)
                }
                try volume.writeBytes(raw, at: offset)
            }
        }

        let flagAt = flavour.bootDirtyFlagOffset
        var flags = try volume.readBytes(at: flagAt, count: 1)
        flags[0] = dirty ? (flags[0] | 0x01) : (flags[0] & ~UInt8(0x01))
        try volume.writeBytes(flags, at: flagAt)
        try volume.synchronize()
    }

    // MARK: - Reporting

    /// The figures a run is judged on, sent once everything else is settled. Nothing here is a
    /// message: this is the last state of the counters, and the summary anyone writes from them is
    /// written on the far side of the stream.
    private func reportSummary() {
        report.update {
            $0.stillFragmented = objects.count { !$0.isContiguous }
            $0.unplaceable = skipped.map {
                RunEvent.Unplaceable(object: $0.label,
                                     clusters: $0.chain.count,
                                     extents: $0.extentCount,
                                     reason: .noFreeRunLargeEnough)
            }
            // The figures to compare between runs on the same medium: how much of the read/write
            // alternation the batching removed, how many transfers the drive was spared because one
            // span carried on where the last ended, and how many pointer fixes rode along for free.
            $0.transfers = copies.spansCopied
            $0.passes = copies.passes
            $0.spansFused = copies.spansFused
            $0.spansSentDirect = copies.spansSentDirect
            $0.pointerFixesFolded = copies.editsFolded
            $0.pointerFixesWritten = copies.editsWritten
            // Timed by the batch itself, since it also goes out part way through a generation
            // whenever it fills: timing only the commits leaves a third of a run's copying missing.
            $0.copying = copies.elapsed

            let cache = volume.cacheReport
            $0.cacheMetadataHits = cache.metadataHits
            $0.cacheMetadataMisses = cache.metadataMisses
            $0.cacheBulkHits = cache.bulkHits
            $0.cacheBulkMisses = cache.bulkMisses
            $0.cacheBytesServed = cache.bytesServed
            $0.cacheStagedHits = cache.stagedHits
            $0.cacheStagedBytesServed = cache.stagedBytesServed
            $0.cachePeakBytes = cache.peakBytes
            $0.cacheBlocksAtPeak = cache.blocksAtPeak
            $0.cacheBytesEvicted = cache.bytesEvicted
            $0.cacheAdmissionsDeclined = cache.admissionsDeclined
        }
    }
}
