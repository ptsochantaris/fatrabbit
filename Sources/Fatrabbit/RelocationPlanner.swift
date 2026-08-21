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
    static func schedule(objects: [FSObject],
                         bad: Set<UInt32>,
                         lastCluster: UInt32,
                         allowStaging: Bool,
                         report: Reporter) throws(FATError) -> RelocationSchedule {
        let clusterCount = Int(lastCluster) + 1
        let objectCount = objects.count

        var owner = [Int32](repeating: free, count: clusterCount)
        for cluster in bad where Int(cluster) < clusterCount { owner[Int(cluster)] = unusable }

        var length = [Int32](repeating: 0, count: objectCount)
        for index in 0 ..< objectCount {
            let chain = objects[index].chain
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
        for index in 0 ..< objectCount {
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

        // 2. Peel the work into generations.
        var current: [ClusterSet] = objects.map { $0.chain }
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
        /// Descending hint for the staging search. Reset whenever clusters are released, so it
        /// never hides space; without it every stage rescans the whole volume.
        var spareCursor = lastCluster
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
                    guard let staging = spareClusters(count: Int(length[index]), owner: owner.span,
                                                      cursor: &spareCursor) else { continue }
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
                    temporaryHops += 1
                }

                if generation.isEmpty {
                    // The budget allowed nothing through. Force one object aside so the schedule
                    // always advances, and only give up when even that is impossible.
                    for index in remaining where stageCount[index] < Self.maxStagesPerObject && !atHome[index] {
                        guard let staging = spareClusters(count: Int(length[index]), owner: owner.span,
                                                          cursor: &spareCursor) else { continue }
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
            spareCursor = lastCluster

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
        var stranded = unplaceable.filter { !current[$0].isContiguous }
        var salvageCursor = lastCluster
        while !stranded.isEmpty {
            var generation: [Relocation] = []
            vacated.removeAll(keepingCapacity: true)
            var stillStranded: [Int] = []
            for index in stranded {
                guard let run = freeRun(count: UInt32(length[index]), owner: owner.span,
                                        cursor: &salvageCursor) else {
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
            }
            if generation.isEmpty { break }
            for entry in vacated where owner[Int(entry.cluster)] == entry.formerOwner {
                owner[Int(entry.cluster)] = free
                freeCount += 1
            }
            salvageCursor = lastCluster
            generations.append(generation)
            stranded = stillStranded
        }
        unplaceable = stranded

        return RelocationSchedule(generations: generations,
                                  unplaceable: unplaceable,
                                  totalClusters: totalClusters,
                                  temporaryHops: temporaryHops)
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

    /// Any `count` spare clusters, taken from the top downwards so staged data stays clear of the
    /// low clusters the layout is filling. Contiguity is not required — this is somewhere to wait,
    /// not somewhere to live. `cursor` carries the search position between calls, which is what
    /// stops each stage from rescanning the volume.
    private static func spareClusters(count: Int, owner: Span<Int32>,
                                      cursor: inout UInt32) -> ClusterSet? {
        guard count > 0 else { return nil }
        var picked: [UInt32] = []
        picked.reserveCapacity(count)
        var cluster = cursor
        while cluster >= 2 {
            if owner[Int(cluster)] == free {
                picked.append(cluster)
                if picked.count == count {
                    cursor = cluster > 2 ? cluster - 1 : 2
                    return .list(picked.reversed())
                }
            }
            cluster -= 1
        }
        return nil
    }

    /// Highest free run of `count` clusters, with a descending cursor for the same reason.
    private static func freeRun(count: UInt32, owner: Span<Int32>,
                                cursor: inout UInt32) -> ClusterSet? {
        guard count > 0, cursor >= count + 1 else { return nil }
        var end = cursor
        while end >= count + 1 {
            let start = end - count + 1
            var blocked: UInt32?
            var cluster = end
            while cluster >= start {
                if owner[Int(cluster)] != free { blocked = cluster; break }
                if cluster == start { break }
                cluster -= 1
            }
            guard let obstruction = blocked else {
                cursor = start > 2 ? start - 1 : 2
                return .run(start ..< end + 1)
            }
            guard obstruction > 2 else { return nil }
            end = obstruction - 1
        }
        return nil
    }
}
