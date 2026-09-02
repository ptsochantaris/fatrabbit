import Foundation

/// What the engine says about itself, in its own terms.
///
/// The rule that decides what belongs here: an event carries a *fact*, never a decision about when or
/// how that fact should be shown. "Three clusters are marked bad" is a fact; "print a line about bad
/// clusters now" is a display choice, and belongs to whoever is drawing. That distinction is why there
/// is no case carrying prose — every message the engine used to compose turned out to be a counter
/// wearing a sentence, including the ones that read like editorial: "no free run large enough" is a
/// typed reason, not a phrase.
///
/// The engine therefore emits unconditionally and consumers filter. That is affordable because these
/// are small values rather than formatted strings: the cost was always the formatting, and it now
/// happens once per drawn frame in the consumer instead of tens of thousands of times in the copy loop.
/// Two flags disappear with it — `verbose` and a `showsStatus` check that existed only so the engine
/// could avoid building strings nobody would read.
enum RunEvent: Sendable {
    // MARK: Lifecycle

    /// What the run was asked to do, and what it is about to open. Always the first event, and posted
    /// before the volume is opened so that a failure to open still has its context on the record.
    case started(Setup)
    /// The volume is open and its shape known.
    case opened(Geometry)
    /// A better volume name than the boot sector carried, found in the root directory during the scan.
    /// This is the name the system shows, and it is often the better one.
    case labelled(String)
    /// Which part of the run is under way. Consumers that show a phase name use this; others ignore it.
    case phase(Phase)
    /// A phase finished, with what it cost. `.defragmenting` ending is "Copying finished in …".
    case phaseCompleted(Phase, elapsed: Duration)
    /// Ctrl-C landed. `immediate` is the second press, where the run stops without tidying up.
    case interrupted(immediate: Bool)
    /// The run is over, one way or another. Always the last event.
    case ended(Outcome, elapsed: Duration)

    // MARK: Telemetry

    /// A figure the engine keeps about itself has changed. The whole set is carried each time rather
    /// than a delta, so a consumer that starts late, redraws, or coalesces a hundred of these into one
    /// frame needs no history to be correct.
    ///
    /// Boxed, because it is much the largest thing here and an enum is as big as its largest case: left
    /// inline it would make every transfer event carry a telemetry-sized hole through the queue.
    indirect case telemetry(Telemetry)

    /// The volume as found, one cluster at a time, as a single value.
    ///
    /// A blob rather than a cluster's worth of events each, and not for speed. The starting layout is
    /// one fact about the volume, not a hundred thousand independent changes, and sending it as a change
    /// log would be modelling a state as history — the same conflation this vocabulary exists to avoid.
    /// It is also cheap: one byte per cluster is 128 KiB for a 2 GB volume and under 2 MiB for the
    /// largest card, copied once.
    ///
    /// Sent as soon as the volume is open, from the FAT alone, which is what is honestly knowable then:
    /// which clusters are in use and which are unusable. What each one actually holds, and which of it
    /// the run intends to shift, arrive later as `clusters` — the scan and then the schedule refining a
    /// picture that was true from the start.
    case layout([ClusterState])

    // MARK: Operations, as they happen

    /// A transfer to or from the medium, reported on the way in and again on the way out. `done` is
    /// what separates intent from fact: before it, the bytes are not in hand.
    case transfer(Transfer)
    /// Clusters are being worked on right now — repointed, cleared, or allocated in the FAT. Transient,
    /// unlike `clusters`.
    case working(Work)
    /// A durability barrier, reported on the way in and again on the way out. The one stretch of a run
    /// with nothing to count: a single call that returns when the drive says so, so a consumer showing
    /// activity has to hold what it is showing rather than animate it, or the longest wait in the run
    /// looks like a hang.
    case barrier(Barrier, done: Bool)
    /// Clusters changed what they hold, or what they are for. This is the whole of what a block map
    /// needs, and it says nothing about colour.
    case clusters(ClusterSet, became: ClusterState)

    /// A generation finished, with its own figures rather than the run's.
    ///
    /// A moment and not telemetry, which is the distinction worth being careful about: the interesting
    /// thing is that this generation happened and what it cost, and no cumulative total can express
    /// that. Writing a consumer against the cumulative figures alone is what showed this was missing —
    /// the per-generation line could not be reproduced, and per-generation cost is where the run's one
    /// pathological phase was eventually found.
    case generationCompleted(number: Int, of: Int, moves: Int, clusters: UInt32, elapsed: Duration)

    /// A commit is starting, and what it has to settle. Posted before the work rather than after,
    /// because these figures are the scope of what follows and a consumer naming each step as it passes
    /// needs them in hand first.
    case commit(number: Int, allocations: Int, flips: Int, releases: Int)

    /// One object was relocated, with both chains whole. Only a consumer showing per-object detail
    /// wants these, and there is one per object in the plan.
    ///
    /// Whole chains rather than a summary of them, because summarising is the consumer's job: pairing
    /// the two gives the spans the copy was actually made of, and taking the ends gives the one-line
    /// version. Either is derivable from this; neither could be recovered from the other.
    case relocated(object: String, from: ClusterSet, to: ClusterSet, staged: Bool)
    /// One object was removed rather than moved — `--deMac` clearing macOS metadata.
    case removed(object: String)

    // MARK: Payloads

    /// What the run was asked to do. Every field is something the user chose or something the path
    /// turned out to be, so it is fixed for the whole run.
    struct Setup: Sendable {
        /// The path the user gave.
        let requested: String
        /// What is actually opened. Differs from `requested` when a buffered device node was
        /// redirected to its raw counterpart, so that every transfer reaches the medium when the run
        /// says it does.
        let node: String
        /// Set when the path is an image file that is also attached as a device with nothing mounted
        /// from it. That device reads through the file, so it is a second view of the same bytes.
        let attachedAs: String?
        let dryRun: Bool
        /// Keeping the order things already sit in, and never shoving one object aside for another.
        let fast: Bool
        let deMac: Bool
    }

    /// The shape of the volume, known once it is open.
    struct Geometry: Sendable {
        /// From the boot sector. `labelled` supersedes it if the root directory carries a better one.
        let label: String
        /// Which of the three variants, as text, because nothing downstream branches on it — the
        /// engine has already decided everything that follows from the answer, and a consumer only
        /// wants to say what kind of volume this was.
        let flavour: String
        let clusterSize: Int
        let clusterCount: UInt32
        let bytesPerSector: Int
        let sectorsPerCluster: Int
        /// How many entries the fixed root holds, on the two variants that have one, and nil on
        /// FAT32 where the root is a chain that can grow. Worth reporting because it is a ceiling a
        /// FAT32 user never meets: a root formatted for 512 names cannot hold a 513th, whatever
        /// space is free.
        let fixedRootEntries: Int?
        /// Largest transfer the device said it would accept, and nil where it declined to say — a
        /// plain image file has no such limit. Reported because it is the one piece of geometry here
        /// that the medium states rather than the filesystem, and because a device asking for
        /// something unusually small is worth a reader knowing about: it used to be guessed, and the
        /// guess cost data.
        let deviceMaxTransfer: Int?
        /// What the run will actually use: the smaller of the above, this tool's own ceiling, and
        /// whatever the medium turned out to be capable of when asked to prove it.
        let transferSize: Int
        /// What the medium did when the number it published was put to the test, and nil where it
        /// was not tested — a dry run must not write, and a plain file has no controller to
        /// misbehave. Carried here rather than merely obeyed because a device caught mishandling a
        /// transfer it advertised is the single most important thing a run can discover about the
        /// hardware it is running on, and it should not be discoverable only by reading the source.
        let probe: TransferProbe.Result

        var byteCount: UInt64 { UInt64(clusterCount) * UInt64(clusterSize) }
    }

    /// The stages of a run, in the order they happen. Named after what the medium is being asked to do
    /// rather than after any wording, because the wording is the consumer's.
    enum Phase: Sendable {
        case scanning
        /// Deciding where everything should end up.
        case planning
        /// Stripping macOS metadata, under `--deMac`.
        case removingMetadata
        /// Clearing the hidden attribute from "." and ".." entries, under `--deMac`.
        case clearingHiddenAttributes
        /// Working out the order the moves have to happen in, which is a separate problem from the
        /// layout: the layout says where, this says when.
        case scheduling
        case defragmenting
        /// Checking the "." and ".." entries of every directory that moved. Named because it is a
        /// distinct wait a consumer may want to account for, not because anything must announce it.
        case verifying
        case finishing
    }

    enum Outcome: Sendable {
        case completed
        /// Stopped tidily at the user's request, leaving a consistent volume a later run continues from.
        /// `untouched` is the easy case: the stop landed in a stage that had written nothing, so there
        /// was nothing to put right.
        case stopped(untouched: Bool)
        case failed(String)
    }

    /// What a transfer is and where it is in its life. Sizes and offsets rather than percentages: a
    /// consumer wanting a fraction has the totals from `Telemetry` and can decide how to present it.
    struct Transfer: Sendable {
        enum Kind: Sendable { case read, write }
        let kind: Kind
        /// Where on the volume: the source of a read, the destination of a write.
        let offset: UInt64
        let bytes: Int
        /// The same span in clusters. Worked out by the engine because the engine is what knows how the
        /// volume is laid out, and a consumer should not have to do arithmetic on offsets to draw.
        let firstCluster: UInt32
        let clusters: Int
        /// Which transfer of how many in the pass this belongs to.
        let index: Int
        let of: Int
        /// False as it is issued, true once the medium has answered.
        let done: Bool
    }

    /// Something being done to clusters at this moment, as opposed to what they now hold. Reads and
    /// writes of data are not here: those are `transfer`, which carries far more about itself.
    enum Activity: Sendable {
        /// A block holding pointers is being read so that the edits landing in it can be applied
        /// together. Its own case rather than part of `repointing`, because a repoint pass is two
        /// sweeps up the volume and not one — gather everything, patch in memory, write it all back —
        /// and reporting both as the same thing describes a pass that wanders over the volume twice
        /// for no reason. It also spends nearly all of its calls on blocks the cache already holds,
        /// which is the other half of why the two look alike and are not.
        case gathering
        /// A pointer somewhere is being made to name a new first cluster.
        case repointing
        /// A FAT entry is being set back to free.
        case clearing
        /// A FAT entry is being claimed for a copy that has landed.
        case allocating
    }

    /// A step of bookkeeping. Divided work reports which step it is on, because the steps are what the
    /// medium takes one at a time and a phase of several seconds otherwise has nothing to show until it
    /// finishes and then changes everything at once.
    struct Work: Sendable {
        let activity: Activity
        /// The clusters this step touches.
        let clusters: ClusterSet
        /// Which step of how many. Both zero where the work is one indivisible act.
        let step: Int
        let steps: Int
        /// False as the step is issued, true once the medium has answered — the same distinction
        /// `Transfer` and `Barrier` carry, and it was the odd one out in not carrying it.
        ///
        /// It reads like a nicety and is not. A single edge says a step began and nothing about when
        /// it stopped, so anything showing activity has to infer the end from the next step starting.
        /// That is wrong in both directions: a step is shown as still running through however long the
        /// gap to the next one turns out to be — and the gaps here are real, because a cached run is
        /// reported to nobody — while the last step of a pass has no next step to end it at all.
        let done: Bool

        init(_ activity: Activity, _ clusters: ClusterSet, step: Int = 0, steps: Int = 0,
             done: Bool = false) {
            self.activity = activity
            self.clusters = clusters
            self.step = step
            self.steps = steps
            self.done = done
        }
    }

    /// A wait for the drive to make what it has been handed durable. The two kinds are the whole of the
    /// safety argument, which is why they are named rather than counted.
    struct Barrier: Sendable {
        enum Kind: Sendable {
            /// Every copy must be allocated on disk before anything names it.
            case allocations
            /// Those pointer flips must be on disk before the clusters they abandoned can be reused.
            case pointers
        }
        let kind: Kind
        /// What is being made safe. Until the barrier returns, these are only as safe as a cache.
        let clusters: ClusterSet
    }

    /// Every figure the engine keeps, sent whole so that no consumer has to accumulate.
    ///
    /// Deliberately flat and cheap to copy. What used to be twenty different log lines composed at
    /// twenty different moments is one value that changes over time, and when to say anything about it
    /// — a line per change, a table refreshed at 8 Hz, a summary at the end, or nothing — is the
    /// consumer's business entirely.
    struct Telemetry: Sendable {
        // Volume
        var badClusters = 0
        var clustersInUse: UInt32 = 0
        var clusterCount: UInt32 = 0
        /// What the run ended up believing about free space, against what the FAT actually holds. A
        /// disagreement means allocation decisions were made on bad information, so both are carried.
        var freeCountRecorded: UInt32?
        var freeCountActual: UInt32?

        // Scan
        var filesFound = 0
        var directoriesFound = 0
        /// Directory data actually fetched, in bytes rather than clusters. The scan stops reading a
        /// directory at its end-of-directory marker, so it usually takes a fraction of a cluster and
        /// a count of clusters would claim work the medium was never asked for.
        var directoryBytesRead: UInt64 = 0

        // Layout
        var plannedMoves = 0
        var plannedClusters: UInt32 = 0
        var generations = 0
        var stagedHops = 0
        var placedFirst: [String] = []
        var placedLast: [String] = []
        var unmatchedNames: [String] = []
        /// Objects the schedule has yet to find a place for. Counts down while scheduling.
        var objectsToSchedule = 0

        // Progress through the plan
        var generation = 0
        var generationCount = 0
        var moveInGeneration = 0
        var movesInGeneration = 0
        var movesDone = 0
        /// Clusters copied against clusters the schedule means to copy. The denominator counts staged
        /// hops twice, because they are copied twice — measured against anything else the figure runs
        /// past 100%.
        var clustersDone = 0
        var clustersScheduled = 0
        var commits = 0

        // What reached the medium
        var transfers = 0
        var passes = 0
        var spansFused = 0
        var spansSentDirect = 0
        var pointerFixesFolded = 0
        var pointerFixesWritten = 0
        /// Directory-entry pointer edits, and the block writes they were folded into. The ratio is the
        /// payoff of coalescing them; on slow media each block write is what actually costs.
        var entryPointerEdits = 0
        var entryBlockWrites = 0
        var fatWrites = 0
        var fatBlocksTouched = 0

        // The device cache, which is a pure optimisation and therefore the one thing here that can stop
        // working without anything failing. Counted so that "the medium got slower" and "the cache
        // stopped admitting" can be told apart.
        var cacheMetadataHits = 0
        var cacheMetadataMisses = 0
        var cacheBulkHits = 0
        var cacheBulkMisses = 0
        var cacheBytesServed = 0
        /// Hits on data parked in spare space, which is the read the staging design exists to make free.
        var cacheStagedHits = 0
        var cacheStagedBytesServed = 0
        var cachePeakBytes = 0
        var cacheBlocksAtPeak = 0
        /// Released because the clusters were freed, rather than overwritten. Almost all of it is
        /// staged data, which nothing ever writes over and would otherwise be held for the whole run.
        var cacheBytesEvicted = 0
        /// Non-zero means the ceiling was reached, and since nothing is evicted the cache stopped being
        /// useful from that point in the run onwards.
        var cacheAdmissionsDeclined = 0
        /// Commits forced part way through a generation because a move wanted a cluster the same
        /// generation had just released. Should always be zero: if it is not, the schedule is wrong
        /// rather than merely slow.
        var forcedFlushes = 0

        // Corrections and cleanup
        var hiddenAttributesFound = 0
        var hiddenAttributeDirectories = 0
        var hiddenAttributesCleared = 0
        var metadataFilesRemoved = 0
        var metadataDirectoriesRemoved = 0
        var metadataClustersRemoved = 0
        var directoriesToVerify = 0
        var directoriesVerified = 0
        var staleDotEntriesFixed = 0
        /// Wrong before this run touched anything, so corrected without reading a thing.
        var preexistingDotEntriesFixed = 0
        var orphansReclaimed = 0

        // Outcome
        var objectsMoved = 0
        var clustersMoved: UInt32 = 0
        var stillFragmented = 0
        /// Objects that could not be placed, with why. Named rather than counted because a run that
        /// leaves anything behind should be able to say what.
        var unplaceable: [Unplaceable] = []

        // Where the time went
        var copying = Duration.zero
        var barriers = Duration.zero
        var barrierCount = 0
        var repointing = Duration.zero
        var allocating = Duration.zero
        var releasing = Duration.zero
    }

    struct Unplaceable: Sendable {
        enum Reason: Sendable {
            /// No run of free clusters long enough, even after everything movable had moved.
            case noFreeRunLargeEnough
            /// Parked in spare space too many times without reaching a home.
            case shiftedAsideTooOften
        }
        let object: String
        let clusters: Int
        let extents: Int
        let reason: Reason
    }
}
