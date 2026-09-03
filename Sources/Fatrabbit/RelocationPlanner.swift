import Foundation

/// One data movement: an object's clusters copied to a destination.
struct Relocation {
    let objectIndex: Int
    /// Usually a contiguous run, and held as one. Staging destinations may be fragmented, which is
    /// harmless — only an object's final home has to be in one piece.
    let destination: ClusterSet
    let isTemporary: Bool
}

/// The whole defragmentation worked out in memory before anything is written.
///
/// The moves are grouped into generations with one rule: every destination in a generation is
/// already clear when the generation begins. That makes a generation's moves independent of each
/// other, so the entire generation needs a single pair of durability barriers rather than a pair
/// per object. Clusters vacated by a generation only become available to the *next* one, which is
/// exactly the ordering the on-disk format requires.
struct RelocationSchedule {
    let generations: [[Relocation]]
    /// Objects that cannot be relocated at all: there is nowhere for them to go.
    let unplaceable: [Int]
    let totalClusters: UInt32
    let temporaryHops: Int
    /// Objects this schedule would leave sitting on a parking spot when it finished — parked to break
    /// a deadlock for somebody else's benefit, and never brought home.
    ///
    /// Known here, before anything is written, because that is where it is knowable: the schedule is
    /// built whole in memory, so an object still on a temporary destination at the end of the build
    /// will still be there at the end of the run. Discovering it afterwards, from the map, is what
    /// happened once.
    let abandoned: [Int]
    /// Where every object would sit once this schedule had been carried out, indexed as `objects` was.
    ///
    /// So that a schedule can be planned *on top of* another without either being performed. What
    /// that answers is the question worth asking when a plan comes back with abandoned objects: would
    /// a pass that parks nothing leave a volume this one could then finish cleanly? On a 2 GiB volume
    /// 92% full it does — a `--fast` pass frees 1,872 clusters above the layout where there had been
    /// none, which is exactly the room parking needs and could not find.
    let finalLayout: [ClusterSet]
    /// Clusters that were free *and* above the compacted layout when this was planned — the only space
    /// a deadlock can be broken with, and so the number that says whether one can be broken at all.
    let spareAboveLayout: Int

    var moveCount: Int { generations.reduce(0) { $0 + $1.count } }
}

/// Works out the ideal layout and the order to realise it in, entirely in memory.
///
/// Nothing here touches the disk, so it is free of the constraint that makes the on-disk work
/// awkward: it can treat a cluster as available the moment its previous occupant is scheduled to
/// leave. That is what lets the layout be decided once, correctly, instead of being discovered
/// incrementally and repeatedly revised.
///
/// Everything is kept in flat arrays indexed by cluster or object number. The obvious shapes —
/// an array of cluster arrays, a set of pending clusters — cost an allocation per object and a
/// hash per lookup, which on a volume with hundreds of thousands of each is most of the runtime.
enum RelocationPlanner {
    /// Sentinels for `owner`, which otherwise holds an object index.
    private static let unusable: Int32 = -2
    private static let free: Int32 = -1
    /// How often one object may be shifted aside before the schedule gives up on it. Each hop costs
    /// an extra copy, so this is deliberately small.
    private static let maxStagesPerObject: UInt8 = 3
    /// Ceiling on clusters parked in spare space to break a single deadlock. Enough to clear a knot,
    /// small enough that a volume with room to spare cannot park half of itself; see where it is used
    /// for the measurements. Smaller is not better — at 64 the schedule cannot clear a knot in one go
    /// and re-parks objects it has already moved, ending up with more staged, not less.
    private static let maxStagedPerStall = 256
    /// Largest number of clusters one generation may copy before it has to commit what it holds.
    ///
    /// A ceiling on clusters rather than on moves, and one knob rather than two: every move copies at
    /// least one cluster, so this bounds the move count along with it, and clusters are what the wait
    /// is actually made of.
    ///
    /// It exists for feedback rather than for throughput, and the distinction matters because the
    /// figures below look like a cost and are not. The first generation takes every object whose home
    /// is already clear, and on a volume whose free space sits below its data that is nearly all of
    /// them: measured on the `hollow` recipe, 33,509 of 37,264 moves in generation one and 3,345 in
    /// the next. That generation is not slow — it holds nearly all the work, so it ought to take
    /// nearly all the time — but nothing commits until it ends, which is most of the run showing a
    /// map full of data picked up and put down and none of it settled.
    ///
    /// Splitting one is free of the thing that would make it expensive. Every destination in a
    /// generation was free before the generation began and exactly one object claims each, so holding
    /// an object back moves it later to the same place: the same objects, the same destinations, the
    /// same count. Nothing is copied twice and nothing is staged that was not staged before.
    ///
    /// What it does add is a commit per split, and the reason the number can be this small is that
    /// homes are assigned walking up the volume in object order and a generation is built in that
    /// same order — so truncating one yields chunks that are contiguous in destination order. The
    /// layout puts a directory immediately before its own files, so two chunks rarely share a parent
    /// directory block, which is the duplication that would otherwise be paid twice. Measured against
    /// the uncapped schedule, see `Testing/README.md`.
    private static let maxClustersPerGeneration: UInt32 = 4096

    /// - Parameter allowStaging: when false, no object is ever parked in spare space to break a
    ///   deadlock, so nothing is copied twice. Whatever cannot reach its home directly is either
    ///   made contiguous elsewhere or left alone — the bargain `--fast` offers.
    /// - Parameter startingAt: where each object sits at the start, when that is not where it sits on
    ///   the volume right now. Only a schedule built by this type can supply it — see
    ///   `RelocationSchedule.finalLayout` — and it is how one plan is costed on top of another without
    ///   either of them being carried out.
    static func schedule(objects: [FSObject],
                         bad: Set<UInt32>,
                         lastCluster: UInt32,
                         allowStaging: Bool,
                         report: Reporter,
                         startingAt: [ClusterSet]? = nil,
                         placingIn placementOrder: [Int]? = nil) throws(FATError) -> RelocationSchedule {
        let clusterCount = Int(lastCluster) + 1
        let objectCount = objects.count

        var owner = [Int32](repeating: free, count: clusterCount)
        for cluster in bad where Int(cluster) < clusterCount { owner[Int(cluster)] = unusable }

        let starting = startingAt ?? objects.map(\.chain)
        var length = [Int32](repeating: 0, count: objectCount)
        for index in 0 ..< objectCount {
            let chain = starting[index]
            length[index] = Int32(chain.count)
            for cluster in chain where Int(cluster) < clusterCount {
                owner[Int(cluster)] = Int32(index)
            }
        }

        // 1. The ideal layout: everything packed in order from the first usable cluster, each object
        //    in one piece, stepping over anything marked bad. A home is always a contiguous run, so
        //    only its start needs storing — an array of arrays here would be one allocation per
        //    object and would make "is it home?" an element-by-element comparison.
        var homeStart = [UInt32](repeating: 0, count: objectCount)
        /// Which object's home covers each cluster, so that releasing a cluster can wake exactly
        /// the object waiting on it instead of re-testing every object every generation.
        var homeOwnerAt = [Int32](repeating: -1, count: clusterCount)
        var frontier: UInt32 = 2
        var totalClusters: UInt32 = 0
        // Whose home is assigned first gets the lowest clusters, so this order *is* the layout. It is
        // a parameter rather than the order of `objects` because the numbering has to stay put: every
        // relocation, owner and generation below names an object by its index, and a run that plans in
        // one order and performs in another moves the wrong data.
        for index in placementOrder ?? Array(0 ..< objectCount) {
            let count = UInt32(length[index])
            guard let start = runSkippingBad(count: count, from: frontier,
                                             owner: owner.span, lastCluster: lastCluster) else {
                throw FATError.capacity("no room to place \(objects[index].label) contiguously; "
                    + "the volume is too full for a compacted layout")
            }
            homeStart[index] = start
            for cluster in start ..< start + count { homeOwnerAt[Int(cluster)] = Int32(index) }
            frontier = start + count
            totalClusters += count
        }

        // The closest a parked object can sit to the layout without ever standing in its way.
        //
        // Staging used to be taken from the top of the volume downwards, and the reason given was that
        // homes fill from the bottom, so a parked object is never in anybody's way. That is the right
        // property and the wrong way to secure it: `homeOwnerAt` states it exactly — a cluster no home
        // covers is one no object will ever wait for — so the guarantee holds at *any* distance, and
        // the whole free region above the layout is available at whichever end of it we like.
        //
        // Which matters because the far end can be very far. On a 31.2 GiB volume 58% full, staging sat
        // some 850,000 clusters — 13 GiB — from the content it was being taken from and handed back to,
        // and on a spindle that is a full stroke out and another back on every stall. It is also why
        // the fetch-back cannot be assumed free at scale: it is served from memory on a 2 GiB volume
        // and will not fit the cache on a volume ten times that.
        //
        // Derived from `homeOwnerAt` rather than from `frontier`, though on most volumes they are the
        // same cluster. `runSkippingBad` steps over bad clusters, so the home region has gaps in it,
        // and the exact test picks up any usable cluster in one for free where `>= frontier` would step
        // past it. It also puts the invariant at the point of use rather than leaving it an argument
        // about where homes happened to be packed.
        var spareFloor: UInt32 = 2
        while spareFloor <= lastCluster, homeOwnerAt[Int(spareFloor)] >= 0 { spareFloor += 1 }

        // How much room a shuffle actually has, which is not the same as how much space is free and is
        // the figure that explains a schedule stalling. Free space below the layout's reach belongs to
        // whoever is on their way to it, so parking cannot touch it; only what is free at or above the
        // floor can be borrowed. Measured on a 2 GiB volume 92% full: 9,534 clusters free and **none**
        // of them up here, so no deadlock on that volume could be broken at all. A pass that parks
        // nothing leaves 1,872 of them, which is why one has to come first.
        var spareAboveLayout = 0
        if spareFloor <= lastCluster {
            for cluster in spareFloor ... lastCluster where owner[Int(cluster)] == free {
                spareAboveLayout += 1
            }
        }

        // 2. Peel the work into generations.
        var current: [ClusterSet] = starting
        var atHome = [Bool](repeating: false, count: objectCount)
        var remaining: [Int] = []
        for index in 0 ..< objectCount {
            if isRun(current[index], startingAt: homeStart[index]) {
                atHome[index] = true
            } else {
                remaining.append(index)
            }
        }

        var freeCount = owner[2...].count { $0 == free }

        var generations: [[Relocation]] = []
        var unplaceable: [Int] = []
        var temporaryHops = 0
        var stageCount = [UInt8](repeating: 0, count: objectCount)
        /// Whether an object is currently sitting on a parking spot rather than somewhere it is meant
        /// to stay. Set when it is parked, cleared by whichever placement gives it a real destination
        /// — its home, or a salvaged run — so whatever is still set when the build ends is what the
        /// run would abandon.
        var parked = [Bool](repeating: false, count: objectCount)
        /// Ascending hint for the staging search. Reset whenever clusters are released, so it
        /// never hides space; without it every stage rescans the whole volume.
        var spareCursor = spareFloor
        /// Objects worth testing this generation. Anything else is waiting on a cluster that has
        /// not moved, so re-testing it would be wasted work.
        var wake = remaining
        /// Scratch, reused across generations to avoid reallocating per pass.
        var vacated: [(cluster: UInt32, formerOwner: Int32)] = []
        /// Objects the ceiling turned away this generation. They could have moved and were not asked
        /// to, so nothing releases anything on their behalf and they have to be woken by hand.
        var deferred: [Int] = []
        var wakeMark = [Int32](repeating: -1, count: objectCount)

        while !remaining.isEmpty {
            var generation: [Relocation] = []
            var generationClusters: UInt32 = 0
            vacated.removeAll(keepingCapacity: true)
            deferred.removeAll(keepingCapacity: true)

            for index in wake where !atHome[index] {
                let start = homeStart[index]
                let count = UInt32(length[index])
                // Tested before the run is checked rather than after, so that an object turned away
                // is left exactly as it was found — untouched, unclaimed, and still owning its
                // current clusters. Its destination cannot be taken in the meantime, because the only
                // thing that could claim it is this object.
                //
                // Checked against the ceiling rather than against the ceiling minus this object, so a
                // generation overshoots by at most one object. The alternative is a generation of
                // nothing whenever the next object is larger than the whole allowance.
                if generationClusters >= Self.maxClustersPerGeneration {
                    deferred.append(index)
                    continue
                }
                guard clearRun(start: start, count: count, owner: owner.span) else { continue }
                generation.append(Relocation(objectIndex: index,
                                             destination: .run(from: start, count: count),
                                             isTemporary: false))
                claim(start: start, count: count, by: Int32(index), owner: &owner, freeCount: &freeCount)
                generationClusters += count
                for cluster in current[index] { vacated.append((cluster, Int32(index))) }
                current[index] = .run(from: start, count: count)
                atHome[index] = true
                parked[index] = false
            }

            // Only when nothing could move at all. Staging alongside the placements above is equally
            // safe — both claim only clusters that were free before the generation began — and it
            // would halve the number of generations, but every staged cluster is a cluster copied
            // twice: measured, it traded 8% more data movement and twice the leftover fragmentation
            // for barriers that are cheap on real media and now cost 5ms for a whole run. Wait for
            // the stall.
            if generation.isEmpty, allowStaging {
                // Park as little as will break the deadlock. This was a fraction of the *free* room,
                // which is unrelated to how much needs parking: on a volume with space to spare it
                // granted an enormous allowance and parked objects that would have reached their homes
                // unaided a generation or two later. A 44%-full card staged 628 objects and read 25 MiB
                // back; capped, it stages 60 and reads back 4 MiB, moves 21,497 objects rather than
                // 22,065, and shifts 43,634 clusters against 43,378 actually in use — within one
                // budget of the floor. Fuller volumes are unaffected, having little spare room to be
                // over-generous with.
                //
                // It costs generations, 38 becoming 78, which used to be the reason not to do it and
                // is now nearly free: a barrier is 0.02s buffered and unmeasurable on a raw node, so
                // fifty more of them are worth about a second. And parking is dearer than its cluster
                // count suggests — a directory dragged aside takes a scattered metadata write per
                // subdirectory child with it, which is how the root came to cost 15s of a run.
                var spareBudget = max(min(freeCount / 8, Self.maxStagedPerStall), 1)
                var blockers: [Int] = []
                let mark = Int32(generations.count)
                for waiting in remaining where !atHome[waiting] {
                    let start = homeStart[waiting]
                    for cluster in start ..< start + UInt32(length[waiting]) {
                        let holder = owner[Int(cluster)]
                        guard holder >= 0, Int(holder) != waiting else { continue }
                        if wakeMark[Int(holder)] != mark {
                            wakeMark[Int(holder)] = mark
                            blockers.append(Int(holder))
                        }
                    }
                }


                for index in blockers where stageCount[index] < Self.maxStagesPerObject {
                    guard !atHome[index], Int(length[index]) <= spareBudget else { continue }
                    guard let staging = parkingSpace(count: Int(length[index]),
                                                     extents: current[index].extentCount,
                                                     owner: owner.span,
                                                     homeOwnerAt: homeOwnerAt.span,
                                                     cursor: &spareCursor,
                                                     lastCluster: lastCluster) else { continue }
                    stageCount[index] += 1
                    generation.append(Relocation(objectIndex: index,
                                                 destination: staging,
                                                 isTemporary: true))
                    for cluster in staging {
                        owner[Int(cluster)] = Int32(index)
                        freeCount -= 1
                    }
                    for cluster in current[index] { vacated.append((cluster, Int32(index))) }
                    spareBudget -= staging.count
                    current[index] = staging
                    parked[index] = true
                    temporaryHops += 1
                }

                if generation.isEmpty {
                    // The budget allowed nothing through. Force one object aside so the schedule
                    // always advances, and only give up when even that is impossible.
                    for index in remaining where stageCount[index] < Self.maxStagesPerObject && !atHome[index] {
                        guard let staging = parkingSpace(count: Int(length[index]),
                                                        extents: current[index].extentCount,
                                                        owner: owner.span,
                                                        homeOwnerAt: homeOwnerAt.span,
                                                        cursor: &spareCursor,
                                                        lastCluster: lastCluster) else { continue }
                        stageCount[index] += 1
                        generation.append(Relocation(objectIndex: index,
                                                     destination: staging,
                                                     isTemporary: true))
                        for cluster in staging {
                            owner[Int(cluster)] = Int32(index)
                            freeCount -= 1
                        }
                        for cluster in current[index] { vacated.append((cluster, Int32(index))) }
                        current[index] = staging
                        parked[index] = true
                        temporaryHops += 1
                        break
                    }
                }
            }

            if generation.isEmpty {
                // Nothing can move: either there is no usable spare room, or staging is off and
                // everything left is waiting on something else.
                unplaceable = remaining.filter { !atHome[$0] }
                break
            }

            // Release what was vacated, and wake exactly the objects whose homes those clusters
            // belong to. Freeing is a single comparison per cluster rather than a search through
            // the former occupant's chain.
            var nextWake: [Int] = []
            let mark = Int32(generations.count) + 1_000_000
            // The ceiling's leftovers lead, and in the order they were turned away, so that the
            // chunks of a split generation stay contiguous in destination order. That is what keeps
            // two of them from landing in the same parent directory block and paying for it twice.
            for index in deferred {
                wakeMark[index] = mark
                nextWake.append(index)
            }
            for entry in vacated {
                let slot = Int(entry.cluster)
                guard owner[slot] == entry.formerOwner else { continue }
                owner[slot] = free
                freeCount += 1
                let waiting = homeOwnerAt[slot]
                if waiting >= 0, !atHome[Int(waiting)], wakeMark[Int(waiting)] != mark {
                    wakeMark[Int(waiting)] = mark
                    nextWake.append(Int(waiting))
                }
            }
            spareCursor = spareFloor

            generations.append(generation)
            remaining.removeAll { atHome[$0] }
            wake = nextWake

            // Counted every time, and mentioned never: how often a run of thousands of generations is
            // worth a word about is a question for whoever is drawing.
            report.update {
                $0.generations = generations.count
                $0.objectsToSchedule = remaining.count
            }
        }

        // 3. Anything that could not reach its ideal home is still worth putting in one piece: a
        //    contiguous file that is not compacted loads just as fast as one that is.
        //
        //    Placed from the spare floor upwards, and unlike staging this decides where the object
        //    *lives* rather than where it waits. Taken from the top, a salvaged object left permanent
        //    data at the far end of the volume and so guaranteed the free space was not one run —
        //    which is half of what this tool claims and what `Testing/contiguity.py` checks. From the
        //    floor it extends the compacted region instead, and the tail stays a single run.
        var stranded = unplaceable.filter { !current[$0].isContiguous }
        var salvageCursor = spareFloor
        while !stranded.isEmpty {
            var generation: [Relocation] = []
            vacated.removeAll(keepingCapacity: true)
            var stillStranded: [Int] = []
            for index in stranded {
                guard let run = freeRun(count: UInt32(length[index]), owner: owner.span,
                                        homeOwnerAt: homeOwnerAt.span,
                                        cursor: &salvageCursor, lastCluster: lastCluster) else {
                    stillStranded.append(index)
                    continue
                }
                generation.append(Relocation(objectIndex: index, destination: run, isTemporary: false))
                for cluster in run {
                    owner[Int(cluster)] = Int32(index)
                    freeCount -= 1
                }
                for cluster in current[index] { vacated.append((cluster, Int32(index))) }
                current[index] = run
                // Salvage is a permanent address, not a parking spot: it is where the object lives
                // from now on, so it settles the debt that parking incurred.
                parked[index] = false
            }
            if generation.isEmpty { break }
            for entry in vacated where owner[Int(entry.cluster)] == entry.formerOwner {
                owner[Int(entry.cluster)] = free
                freeCount += 1
            }
            salvageCursor = spareFloor
            generations.append(generation)
            stranded = stillStranded
        }
        unplaceable = stranded

        return RelocationSchedule(generations: generations,
                                  unplaceable: unplaceable,
                                  totalClusters: totalClusters,
                                  temporaryHops: temporaryHops,
                                  abandoned: (0 ..< objectCount).filter { parked[$0] },
                                  finalLayout: current,
                                  spareAboveLayout: spareAboveLayout)
    }

    // MARK: - Cluster helpers

    /// The searches below take a `Span` rather than an `[Int32]`, and that is a statement about them
    /// rather than a tuning choice. Every one is a pure reader of the ownership table: it looks at a
    /// window of it and answers a question. An array parameter cannot say that — it hands over
    /// something the callee could store, count as its own, or outlive the call with — whereas a span
    /// is a borrow the compiler will not let escape the call it was passed to. The table itself stays
    /// an array, mutated by the caller in the loop that owns it, and each of these borrows it for
    /// exactly as long as it takes to answer.
    private static func clearRun(start: UInt32, count: UInt32, owner: Span<Int32>) -> Bool {
        for cluster in start ..< start + count where owner[Int(cluster)] != free { return false }
        return true
    }

    private static func claim(start: UInt32, count: UInt32, by index: Int32,
                              owner: inout [Int32], freeCount: inout Int) {
        for cluster in start ..< start + count {
            owner[Int(cluster)] = index
            freeCount -= 1
        }
    }

    /// True if `chain` is exactly the contiguous run of its own length beginning at `start`.
    ///
    /// A run answers this by looking at where it starts, which is the whole reason to hold one as a run:
    /// this is asked of every object once per generation, and for anything already laid out the answer
    /// used to cost a walk of the chain to reach a conclusion its shape had already settled.
    private static func isRun(_ chain: ClusterSet, startingAt start: UInt32) -> Bool {
        guard !chain.isEmpty else { return false }
        if case .run(let range) = chain { return range.lowerBound == start }
        for offset in 0 ..< chain.count where chain[offset] != start + UInt32(offset) { return false }
        return true
    }

    /// Start of the next run of `count` clusters at or after `from` holding no unusable cluster.
    private static func runSkippingBad(count: UInt32, from: UInt32,
                                       owner: Span<Int32>, lastCluster: UInt32) -> UInt32? {
        guard count > 0 else { return nil }
        var start = from
        while start <= lastCluster, lastCluster - start + 1 >= count {
            var obstruction: UInt32?
            for cluster in start ..< start + count where owner[Int(cluster)] == unusable {
                obstruction = cluster
                break
            }
            guard let blocked = obstruction else { return start }
            start = blocked + 1
        }
        return nil
    }

    /// The lowest `count` clusters that are free and that no object's home covers — so, the closest
    /// somewhere-to-wait that cannot be somewhere another object is waiting for.
    ///
    /// Two conditions rather than one, and the second is the whole of the safety argument. A free
    /// cluster below the layout's reach is a cluster some object is on its way to, and parking there
    /// would deadlock exactly the object whose home it is; a free cluster no home covers can never be
    /// wanted by anybody, whatever else the schedule does. Searching upwards is then a matter of
    /// distance alone, which is what it should have been all along.
    ///
    /// Contiguity is not required — this is somewhere to wait, not somewhere to live — but the number
    /// of pieces is capped, because "somewhere to wait" is a promise the schedule cannot always keep.
    /// See `parkingSpace`, which is what callers use and which explains the cap.
    ///
    /// `cursor` carries the search position between calls, which is what stops each stage from
    /// rescanning the volume; it is reset by the caller whenever clusters are released, so it can
    /// never hide space.
    private static func spareClusters(count: Int, extents: Int, owner: Span<Int32>,
                                      homeOwnerAt: Span<Int32>,
                                      cursor: inout UInt32, lastCluster: UInt32) -> ClusterSet? {
        guard count > 0, extents > 0 else { return nil }
        var picked: [UInt32] = []
        picked.reserveCapacity(count)
        var pieces = 0
        var cluster = cursor
        while cluster <= lastCluster {
            if owner[Int(cluster)] == free, homeOwnerAt[Int(cluster)] < 0 {
                if picked.last != cluster - 1 {
                    pieces += 1
                    // Lowest-first and give up rather than carry on looking further out. A caller has
                    // already asked for one piece and been refused, so what is left up here is small
                    // change; declining leaves the object where it is, which is the outcome this whole
                    // change exists to prefer over parking it badly.
                    guard pieces <= extents else { return nil }
                }
                picked.append(cluster)
                if picked.count == count {
                    cursor = cluster + 1
                    return .list(picked)
                }
            }
            cluster += 1
        }
        return nil
    }

    /// Somewhere for a blocker to wait that costs the blocker nothing.
    ///
    /// Parking is a favour done for somebody else: an object is dragged out of a home it is sitting on
    /// so that the object whose home it is can have it. The object doing the favour used to pay for it.
    /// `spareClusters` took the lowest free clusters it could find in any arrangement, so a file of
    /// three contiguous clusters could be parked as two extents 269 apart — and if the schedule then
    /// gave up, it stayed that way. Measured on a 2 GiB volume 92% full: 44 of 46 parked objects were
    /// never brought home, one of them a contiguous file left in two pieces, and the run reported
    /// success.
    ///
    /// So: one piece if the volume can manage it, and otherwise no more pieces than the object is
    /// already in. Never more. An object that cannot be parked without being broken up is left where
    /// it is, which may stall the schedule earlier — and a schedule that stops early is a great deal
    /// better than one that carries on by damaging the thing it moved.
    ///
    /// One piece is preferred even for an object that arrives fragmented, because a detour that also
    /// defragments is free to prefer: the copy is happening either way.
    private static func parkingSpace(count: Int, extents: Int, owner: Span<Int32>,
                                     homeOwnerAt: Span<Int32>,
                                     cursor: inout UInt32, lastCluster: UInt32) -> ClusterSet? {
        // Both of these advance the cursor only when they succeed, so a refused search costs the next
        // caller nothing.
        if let run = freeRun(count: UInt32(count), owner: owner, homeOwnerAt: homeOwnerAt,
                             cursor: &cursor, lastCluster: lastCluster) {
            return run
        }
        guard extents > 1 else { return nil }
        return spareClusters(count: count, extents: extents, owner: owner, homeOwnerAt: homeOwnerAt,
                             cursor: &cursor, lastCluster: lastCluster)
    }

    /// Lowest free run of `count` clusters holding no cluster any home covers, with an ascending
    /// cursor for the same reason.
    ///
    /// The same shape as `runSkippingBad` above, which is the helper this most resembles now: walk
    /// from the cursor and, on an obstruction, restart past it. Homes are excluded here as well as in
    /// `spareClusters`, and it is worth saying why, because unlike there it is not forced. At this
    /// point every object still away from home is one this schedule gave up on, so handing a salvaged
    /// object the home of another stranded one would deadlock nothing. What it would do is drop that
    /// object into the middle of the compacted region, out of the tree order the layout is built in,
    /// for no gain — so one invariant serves both.
    private static func freeRun(count: UInt32, owner: Span<Int32>, homeOwnerAt: Span<Int32>,
                                cursor: inout UInt32, lastCluster: UInt32) -> ClusterSet? {
        guard count > 0 else { return nil }
        var start = cursor
        while start <= lastCluster, lastCluster - start + 1 >= count {
            var obstruction: UInt32?
            for cluster in start ..< start + count
                where owner[Int(cluster)] != free || homeOwnerAt[Int(cluster)] >= 0 {
                obstruction = cluster
                break
            }
            guard let blocked = obstruction else {
                cursor = start + count
                return .run(start ..< start + count)
            }
            start = blocked + 1
        }
        return nil
    }
}
