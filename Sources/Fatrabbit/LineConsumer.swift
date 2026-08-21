import Foundation

/// How much a logged line wants noticing. Only a few lines in a run are anything other than normal: an
/// interrupt landing, which someone has just asked for and needs to see acknowledged, an error, and the
/// line saying the whole thing finished.
enum Emphasis {
    case normal
    case alert
    case success

    var ink: String? {
        switch self {
        case .normal: return nil
        case .alert: return "\u{1B}[1;38;5;196m"
        case .success: return "\u{1B}[1;38;5;46m"
        }
    }
}

/// A run turned into words, before anything has decided where to put them.
///
/// The split between the two carrying cases is the whole reason this is not just a `String`. A discrete
/// line is the record of the run: stderr ends it with a newline, and the block map files it in its
/// transcript. The live line is not a record at all — it is overwritten several times a second and only
/// its latest value means anything, so stderr rewrites it in place and the map puts it beside its
/// progress bar. Handing both to a sink as plain text would force whoever receives them to guess.
///
/// `fraction` and `eta` ride along with the live line rather than being written into it, because where
/// they belong depends on who is drawing. The map has a fixed place for each beside the bar, which is
/// easy to glance at; stderr has no bar, so the estimate goes into the prose. Written into the text they
/// would appear twice on the map, once in a fixed place and once in a spot that shifts about as the
/// words either side of it change length.
enum Output {
    case line(String, emphasis: Emphasis)
    /// A nil fraction means the stage has no honest denominator — the scan cannot know how many
    /// directories it will find — so a bar should sweep rather than pretend to a percentage.
    case status(String, fraction: Double?, eta: String?)
    /// The live line is finished with, and its last value was worth keeping.
    ///
    /// Only stderr has anything to decide here, and that is the point of it being separate: the live
    /// line and the record share one row there, so ending the row is the only way to keep what is on
    /// it. Anything with a place of its own for the live line — a map, beside its bar — keeps it
    /// simply by not overwriting it, and filing a copy in its transcript would leave a watched run
    /// with one more line in it than a plain one.
    case endStatus
    /// The live line is finished with and not worth keeping. stderr erases it.
    case clearStatus
}

/// Renders `Output` to stderr, which is what `--plain` and every redirected run leave behind.
///
/// Deliberately unbuffered. Buffering was tried and removed: a write(2) per line costs a fraction of a
/// second even across hundreds of thousands of lines, whereas holding lines back means a quiet stretch
/// shows nothing at all, and anything still buffered when the process is killed is lost exactly when it
/// would have been most useful.
///
/// Output goes to stderr so that stdout stays reserved for machine-readable results.
final class LineWriter {
    /// Whether anyone is watching. Colour and the in-place line both rely on escape sequences, which
    /// redirected into a file are litter, so they are dropped rather than written where nothing will
    /// interpret them. Discrete lines are the record of the run and always go out.
    private let interactive: Bool
    /// True while an in-place line is on screen and would otherwise be run into.
    private var statusPending = false

    init(interactive: Bool = isatty(STDERR_FILENO) != 0) {
        self.interactive = interactive
    }

    func write(_ output: Output) {
        switch output {
        case .line(let text, let emphasis):
            clearStatus()
            if interactive, let ink = emphasis.ink {
                emit(ink + text + "\u{1B}[0m\n")
            } else {
                emit(text + "\n")
            }

        case .status(let text, _, let eta):
            guard interactive else { return }
            emit("\r\(text)\(eta.map { ", \($0)" } ?? "")…\u{1B}[K")
            statusPending = true

        case .endStatus:
            guard statusPending else { return }
            emit("\n")
            statusPending = false

        case .clearStatus:
            clearStatus()
        }
    }

    private func clearStatus() {
        guard statusPending else { return }
        emit("\r\u{1B}[K")
        statusPending = false
    }

    private func emit(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// Turns a run into words: which figures are worth mentioning, when, and how they are put.
///
/// Everything here is a presentation decision, and stating that is the point of the file existing. The
/// engine says "the scan read 2,120 directory clusters" and "the scanning phase took 17.1s"; whether
/// that becomes a line at the time, a column in a table, or nothing at all is decided here and nowhere
/// else. Three consequences worth noticing:
///
/// - **`verbose` lives here.** The engine posts a `.relocated` for every object in the plan, always.
///   This decides whether to print them. That is why the engine no longer has a `verbose` flag, and why
///   it no longer asks whether composing a string would be wasted — nothing is composed until something
///   has decided to show it.
/// - **Wording is chosen against the telemetry, not accumulated.** Telemetry arrives whole, so a line
///   about totals is written from the value in hand rather than from a tally kept here. A consumer that
///   starts late still says the right thing.
/// - **The live line is composed once per batch, not once per event.** A generation posts thousands of
///   events; only the last state of the line was ever going to be seen, so only that one is worded.
///
/// The block map owns one of these too, with a sink that files the lines in its transcript, so the
/// wording of a run lives in one place rather than two. A map that reworded things would be a second
/// dialect to keep in step.
final class LineConsumer: EventConsumer {
    /// Whether to print the per-object detail the engine posts unconditionally.
    private let verbose: Bool
    /// Whether the live line is worth wording at all. Composing tens of thousands of strings for a sink
    /// that discards them was measurable, which is the one thing the consumer does need to know about
    /// where its words are going.
    private let showsStatus: Bool
    private let sink: (Output) -> Void

    /// The plain run: words to stderr, coloured and rewritten in place only where someone is watching.
    /// Under `--verbose` the live line is dropped even on a terminal, because the per-object commentary
    /// is the point and the two would fight for the same row.
    static func toStandardError(verbose: Bool) -> LineConsumer {
        let writer = LineWriter()
        return LineConsumer(verbose: verbose,
                            showsStatus: isatty(STDERR_FILENO) != 0 && !verbose,
                            sink: writer.write)
    }

    init(verbose: Bool, showsStatus: Bool, sink: @escaping (Output) -> Void) {
        self.verbose = verbose
        self.showsStatus = showsStatus
        self.sink = sink
    }

    // MARK: - What the run has said so far

    private var setup: RunEvent.Setup?
    private var geometry: RunEvent.Geometry?
    /// The last telemetry seen, so a line about a total can be written whenever one is wanted.
    private var latest = RunEvent.Telemetry()
    private var phase: RunEvent.Phase?
    /// When the current phase started, which is what estimates are extrapolated from. Per phase rather
    /// than per run: the phases cost wildly different amounts and predicting one from another is worse
    /// than not predicting at all.
    private var phaseStarted = ContinuousClock.now
    private var commit: (number: Int, allocations: Int, flips: Int, releases: Int)?
    private var interrupted = false

    /// What the live line is currently about.
    ///
    /// Telemetry refreshes the figures of whatever is showing; an operation event replaces it outright.
    /// That distinction is what keeps a commit's naming of itself on screen while the accounting behind
    /// it ticks over — otherwise "Flushing the pointers to the drive", which is the longest silence in a
    /// generation, would be overwritten by a move counter that has not moved.
    private enum Live {
        case scanning
        case clearingHiddenAttributes
        case move
        case transfer(RunEvent.Transfer)
        case work(RunEvent.Work)
        case barrier(RunEvent.Barrier.Kind)
        case verifying
    }

    private var live: Live?
    private var statusStale = false

    // MARK: - EventConsumer

    func apply(_ batch: [RunEvent]) async {
        for event in batch { show(event) }
        if statusStale {
            statusStale = false
            writeStatus()
        }
    }

    func finish() async {
        sink(.clearStatus)
    }

    // MARK: - Events

    private func show(_ event: RunEvent) {
        switch event {
        case .started(let setup):
            self.setup = setup
            if let attached = setup.attachedAs {
                line("Note: this image is attached as \(attached) with nothing mounted from it. "
                    + "That device reads through the file, so detach it (\(System.detachCommand(for: attached))) "
                    + "if anything looks wrong afterwards.")
            }
            if setup.node != setup.requested {
                line("Using the raw node \(setup.node) rather than \(setup.requested), so every "
                    + "transfer reaches the drive when this says it does.")
            }
            line(setup.dryRun
                ? "Dry run: opening \(setup.node) read-only — nothing will be written."
                : "Opening \(setup.node) for in-place defragmentation…")

        case .opened(let geometry):
            self.geometry = geometry
            line("FAT32: \(geometry.bytesPerSector)-byte sectors, "
                + "\(geometry.sectorsPerCluster) sectors/cluster (\(geometry.clusterSize) bytes), "
                + "\(geometry.clusterCount) clusters.")

        case .labelled:
            // Only something with a title to put it in has any use for this.
            break

        case .phase(let phase):
            began(phase)

        case .phaseCompleted(let phase, let elapsed):
            completed(phase, elapsed)

        case .telemetry(let telemetry):
            report(telemetry)
            latest = telemetry

        case .layout, .clusters:
            // Only something drawing a picture of the volume has any use for these.
            break

        case .transfer(let transfer):
            guard !transfer.done else { return }
            liven(.transfer(transfer))

        case .working(let work):
            // Only the copy phase words its bookkeeping, because only there is it the long silence
            // worth naming. The cleanup passes post the same events and have something better to say
            // about themselves — how far through their own list they are.
            //
            // The near edge only, as with a transfer: the live line names what is being waited on, and
            // a step that has answered is no longer that.
            guard !work.done, phase == .defragmenting else { return }
            liven(.work(work))

        case .barrier(let barrier, let done):
            guard !done, phase == .defragmenting else { return }
            liven(.barrier(barrier.kind))

        case .generationCompleted(let number, let of, let moves, let clusters, let elapsed):
            // The figures before the dash are this generation's; the percentage after it is the whole
            // run's, and says so, because a generation of one cluster sitting next to a bare "0%" reads
            // as a bug rather than as an honest fraction of a percent.
            line("  Generation \(number)/\(of): \(moves.counted("move")), "
                + "\(clusters.counted("cluster")), "
                + "1 barrier pair — \(elapsed.readable) "
                + "(\(rate(clusters: clusters, of: clusterSize, over: elapsed))), "
                + "\(percentage(latest.clustersDone, of: latest.clustersScheduled)) of the run copied")

        case .commit(let number, let allocations, let flips, let releases):
            commit = (number, allocations, flips, releases)
            guard verbose else { return }
            line("      commit \(number): \(allocations) chain "
                + "\(allocations.word("entry", "entries")), "
                + "\(flips.counted("pointer flip")), \(releases.counted("release"))")

        case .relocated(let object, let from, let to, let staged):
            guard verbose else { return }
            let destination = to.count > 1 ? "\(to[0])…\(to[to.count - 1])" : "\(to.first ?? 0)"
            line("  \(object): \(describe(from)) → \(destination)\(staged ? " (staged)" : "")")
            // The spans the copy was actually made of, paired off the two chains. A source in one piece
            // becomes a single read and a single write however many clusters it is, and this is where
            // that shows.
            for span in spans(from: from, to: to) { line("        \(span)") }

        case .removed(let object):
            line("  Removing \(object)")

        case .interrupted(let immediate):
            interrupted = true
            announce(immediate
                ? "Interrupted again — stopping now. The volume stays flagged as modified; the next "
                    + "run tidies up whatever was in flight."
                : "Interrupt received — finishing the batch in flight, then stopping tidily. "
                    + "Press Ctrl-C again to stop immediately.",
                .alert)

        case .ended(let outcome, let elapsed):
            switch outcome {
            case .completed:
                announce("Done in \(elapsed.readable).", .success)
            case .stopped(let untouched):
                line(untouched
                    ? "Stopped before anything was written — the volume is untouched."
                    : "Stopped after \(elapsed.readable).")
            case .failed(let why):
                announce("Error: \(why)", .alert)
            }
        }
    }

    // MARK: - Phases

    private func began(_ phase: RunEvent.Phase) {
        self.phase = phase
        phaseStarted = .now
        live = nil

        switch phase {
        case .scanning:
            line("Scanning directory tree…")
            live = .scanning

        case .planning:
            let fast = setup?.fast == true
            line("Planning contiguous layout\(fast ? " (--fast: keeping existing order)" : "")…")

        case .removingMetadata:
            let kib = UInt64(latest.metadataClustersRemoved) * UInt64(clusterSize) / 1024
            line("Removing macOS metadata: \(latest.metadataFilesRemoved.counted("file")), "
                + "\(latest.metadataDirectoriesRemoved.counted("directory", "directories")), "
                + "\(kib) KiB.")

        case .clearingHiddenAttributes:
            let found = latest.hiddenAttributesFound
            let directories = latest.hiddenAttributeDirectories
            line("Clearing the hidden attribute from \(found) \".\"/\"..\" "
                + "\(found.word("entry", "entries")) in \(directories) "
                + "\(directories.word("directory", "directories"))…")
            live = .clearingHiddenAttributes

        case .scheduling:
            line("Working out the relocation plan…")

        case .defragmenting:
            line("Plan: \(latest.plannedMoves.counted("move")) / "
                + "\(latest.plannedClusters.counted("cluster")) "
                + "in \(latest.generations.counted("generation"))"
                + (latest.stagedHops > 0 ? ", \(latest.stagedHops) staged via spare space" : "")
                + ".")

        case .verifying:
            let count = latest.directoriesToVerify
            line("Verifying \"./..\" entries of \(count) relocated "
                + "\(count.word("directory", "directories"))…")
            live = .verifying

        case .finishing:
            line("Updating boot record and FSInfo…")
        }
    }

    private func completed(_ phase: RunEvent.Phase, _ elapsed: Duration) {
        switch phase {
        case .scanning:
            // The running totals are left where they are rather than erased, which is what they were
            // worth watching for. Whether that costs a row is not decided here.
            sink(.endStatus)
            // A line of its own, because on slow media the scan is minutes of the run and belongs in
            // the record whether or not anyone was watching it happen.
            line("Scan took \(elapsed.readable).")

        case .scheduling:
            // Only worth a line when it was long enough to have been wondered about; on a small volume
            // this is milliseconds and saying so is just noise.
            if elapsed.totalSeconds > 1 { line("Plan settled in \(elapsed.readable).") }

        case .clearingHiddenAttributes:
            let cleared = latest.hiddenAttributesCleared
            line("Cleared \(cleared) \".\"/\"..\" \(cleared.word("entry", "entries")) "
                + "in \(elapsed.readable).")

        case .defragmenting:
            guard latest.clustersDone > 0 else { return }
            line("Copying \(interrupted ? "stopped after" : "finished in") \(elapsed.readable), "
                + "averaging \(rate(clusters: latest.clustersDone, of: clusterSize, over: elapsed)).")

        case .verifying:
            let fixed = latest.staleDotEntriesFixed
            if fixed > 0 {
                // On a dry run the moves never landed, so these were read back from clusters still
                // holding whatever was there before: nearly every relocated directory looks stale. Say
                // so rather than presenting a count that means nothing.
                line("Corrected \(fixed) stale \".\"/\"..\" \(fixed.word("entry", "entries"))."
                    + (setup?.dryRun == true
                        ? " (Dry run: read from clusters the moves never updated, so this count is"
                            + " not meaningful.)"
                        : ""))
            } else {
                line("  All correct (\(elapsed.readable)).")
            }

        case .finishing:
            summarise()

        case .planning, .removingMetadata:
            break
        }
        live = nil
    }

    // MARK: - Figures

    /// Which figures are worth a line as they change, and how they are put. Only differences are
    /// announced, because telemetry arrives whole and repeatedly — the engine has no idea how often it
    /// is sent, and should not.
    private func report(_ new: RunEvent.Telemetry) {
        /// Whether a figure moved since the last set arrived, which is the whole test for whether it is
        /// worth a line. Named rather than restated: eight of the conditions below opened by comparing
        /// the same field of two values, which reads as arithmetic when it is really one question.
        func changed<Figure: Equatable>(_ figure: KeyPath<RunEvent.Telemetry, Figure>) -> Bool {
            new[keyPath: figure] != latest[keyPath: figure]
        }

        if changed(\.badClusters), new.badClusters > 0 {
            // Reworded from "…; they will be preserved…" so that one bad cluster does not read as
            // "they": with the pronoun gone the sentence agrees with either count.
            line("\(new.badClusters.counted("cluster")) marked bad, and will be preserved "
                + "and laid out around.")
        }

        if changed(\.clustersInUse), new.clustersInUse > 0 {
            let full = new.clusterCount == 0
                ? 0 : Int((UInt64(new.clustersInUse) * 100) / UInt64(new.clusterCount))
            line("Found \(new.filesFound.counted("file")) and "
                + "\(new.directoriesFound.counted("directory", "directories")); "
                + "\(new.clustersInUse) of \(new.clusterCount) clusters in use (\(full)% full).")
            if !new.placedFirst.isEmpty {
                line("Placed first: \(new.placedFirst.joined(separator: ", "))")
            }
            if !new.placedLast.isEmpty {
                line("Placed last:  \(new.placedLast.joined(separator: ", "))")
            }
            for name in new.unmatchedNames {
                line("Warning: no root-level entry named '\(name)' — ignored.")
            }
        }

        if changed(\.orphansReclaimed), new.orphansReclaimed > 0 {
            let kib = UInt64(new.orphansReclaimed) * UInt64(clusterSize) / 1024
            line("Reclaiming \(new.orphansReclaimed.counted("orphaned cluster")) "
                + "(\(kib) KiB) marked in use "
                + "but reachable from no directory entry.")
        }

        // Scheduling a large volume runs for thousands of generations, so it says where it has got to
        // every so often. How often is decided here: the engine counts, and counting is all it does.
        if changed(\.generations), phase == .scheduling,
           new.objectsToSchedule > 0, new.generations % 200 == 0 {
            line("  Planned \(new.generations.counted("generation")), "
                + "\(new.objectsToSchedule.counted("object")) still to schedule")
        }

        if changed(\.preexistingDotEntriesFixed), new.preexistingDotEntriesFixed > 0 {
            let count = new.preexistingDotEntriesFixed
            line("Corrected \(count) \".\"/\"..\" \(count.word("entry", "entries")) "
                + "that were already wrong before this run.")
        }

        // The running tally is only an optimisation, but if it ever disagrees with the FAT then
        // allocation decisions were made on bad information. Say so rather than hiding it.
        if changed(\.freeCountActual),
           let actual = new.freeCountActual, let recorded = new.freeCountRecorded, actual != recorded {
            line("Note: free-cluster tally was \(recorded) but the FAT holds \(actual); using the FAT.")
        }

        // Which figure moved says what the live line should now be about. A move counter advancing is
        // the run getting on with the copying; the accounting that follows a commit is not.
        if changed(\.directoryBytesRead) { live = .scanning }
        if changed(\.hiddenAttributesCleared) { live = .clearingHiddenAttributes }
        // Only ever a move that has happened. The counter is reset to zero at the head of every
        // generation, and a line reading "Move 0 of 0" while the phase is still opening its eyes is
        // worse than no line at all.
        if changed(\.moveInGeneration), new.moveInGeneration > 0 { live = .move }
        if changed(\.directoriesVerified) { live = .verifying }
        statusStale = true
    }

    /// Everything worth saying once, said once, at the end. A tally kept as the run went would have to
    /// be right about which figures are cumulative; reading them off the last telemetry cannot be wrong.
    private func summarise() {
        let t = latest
        if setup?.dryRun == true {
            line("Dry run: nothing was written. Everything below is what would have happened.")
        }
        line("\(setup?.dryRun == true ? "Would move" : "Moved") "
            + "\(t.objectsMoved.counted("object")) / \(t.clustersMoved.counted("cluster")).")

        // The figures to compare between runs on the same medium: how much of the read/write
        // alternation the batching actually removed, how many transfers the drive was spared because
        // one span carried on where the last ended, and how many pointer fixes rode along for free.
        if t.transfers > 0 || t.spansSentDirect > 0 {
            line("Copying: \(t.transfers.counted("transfer")) in "
                + "\(t.passes.counted("read/write pass", "read/write passes"))"
                + (t.spansFused > 0
                    ? ", \(t.spansFused.counted("adjacent span")) fused in" : "")
                + (t.spansSentDirect > 0 ? ", \(t.spansSentDirect) sent straight out" : "")
                + ", \(t.pointerFixesFolded.counted("pointer fix", "pointer fixes")) folded in"
                + (t.pointerFixesWritten > 0
                    ? " and \(t.pointerFixesWritten) written separately" : "")
                + ".")
        }

        if !t.unplaceable.isEmpty {
            line("Could not defragment \(t.unplaceable.count.counted("object")) "
                + "— no free run large enough:")
            // Always listed. These are the ones still in pieces once every pass is done, which is the
            // part of the report worth acting on.
            for object in t.unplaceable.prefix(10) {
                line("  \(object.object) (\(object.clusters) clusters, \(object.extents) extents)")
            }
            if t.unplaceable.count > 10 { line("  …and \(t.unplaceable.count - 10) more") }
        }

        line("\(t.stillFragmented.counted("object")) still fragmented.")

        let total = t.copying + t.barriers + t.repointing + t.allocating + t.releasing
        if total.totalSeconds > 1 {
            // The one figure that says where a slow run went, and the only way to tell whether the
            // barriers or the data movement are the thing to attack on a given medium.
            let whole = Int(total.totalSeconds * 1000)
            func share(_ part: Duration) -> String {
                "\(part.readable) (\(percentage(Int(part.totalSeconds * 1000), of: whole)))"
            }
            line("Time: copying \(share(t.copying)), "
                + "\(t.barrierCount.counted("barrier")) \(share(t.barriers)), "
                + "repointing \(share(t.repointing)), "
                + "FAT \(share(t.allocating + t.releasing)).")
        }

        if verbose {
            line("Commits: \(t.commits), 2 barriers each.")
            line("FAT writes: \(t.fatWrites) covering \(t.fatBlocksTouched.counted("block")).")
            if t.entryPointerEdits > 0 {
                line("Directory pointer edits: \(t.entryPointerEdits) folded into "
                    + "\(t.entryBlockWrites.counted("block write")).")
            }
            reportCache(t)
        }

        if t.forcedFlushes > 0 {
            // Should be unreachable: a generation's destinations are all clear before it starts, so no
            // move in it can want a cluster the same generation released. If this ever fires, the
            // schedule is wrong rather than merely slow.
            line("Note: \(t.forcedFlushes.counted("extra flush", "extra flushes")) "
                + "\(t.forcedFlushes.word("was", "were")) needed because a move claimed a "
                + "cluster released in the same generation — the schedule should have ruled that out.")
        }
    }

    /// What the device cache did. Only under `--verbose`, and only where there was one: against an
    /// image file the kernel is already doing this, so the tool does not, and a row of zeroes would read
    /// as a broken cache rather than an absent one.
    ///
    /// The two figures worth reading are the staged line and the declined count. Staged data is the one
    /// kind of file content certain to be wanted twice, so a run that parks objects and does not serve
    /// them back from memory is paying for staging twice over. And nothing is ever evicted, so a single
    /// declined admission means the cache stopped taking anything for the rest of the run.
    private func reportCache(_ t: RunEvent.Telemetry) {
        let metadata = t.cacheMetadataHits + t.cacheMetadataMisses
        let bulk = t.cacheBulkHits + t.cacheBulkMisses
        guard metadata + bulk > 0 else { return }
        line("Cache: \(readableBytes(UInt64(t.cacheBytesServed))) served, "
            + "\(readableBytes(UInt64(t.cachePeakBytes))) peak across "
            + "\(t.cacheBlocksAtPeak.counted("block")).")
        line("  Metadata: \(t.cacheMetadataHits.counted("hit")) of \(metadata) "
            + "(\(percentage(t.cacheMetadataHits, of: metadata))) — the figure that matters.")
        line("  Bulk: \(t.cacheBulkHits.counted("hit")) of \(bulk) "
            + "(\(percentage(t.cacheBulkHits, of: bulk))), which is meant to be near nothing: file "
            + "content is read once and never stored.")
        if t.cacheBytesEvicted > 0 {
            line("  Released on free: \(readableBytes(UInt64(t.cacheBytesEvicted))) of answered "
                + "questions let go rather than held to the end of the run.")
        }
        if t.cacheStagedHits > 0 {
            line("  Of staged data: \(t.cacheStagedHits.counted("hit")), "
                + "\(readableBytes(UInt64(t.cacheStagedBytesServed))) never re-read from the medium.")
        }
        if t.cacheAdmissionsDeclined > 0 {
            line("  Note: \(t.cacheAdmissionsDeclined.counted("transfer")) refused because the cache "
                + "was full — nothing is evicted, so it held nothing new after that.")
        }
    }

    // MARK: - The live line

    private func liven(_ what: Live) {
        guard showsStatus else { return }
        live = what
        statusStale = true
    }

    private func writeStatus() {
        guard showsStatus, let text = statusText() else { return }
        let figures = statusFigures()
        sink(.status(text, fraction: figures.fraction, eta: figures.eta))
    }

    private func statusText() -> String? {
        guard let live else { return nil }
        switch live {
        case .scanning:
            let directories = latest.directoriesFound
            return "  Scanned \(directories) \(directories.word("directory", "directories")), "
                + "\(latest.filesFound.counted("file")), "
                + "\(readableBytes(latest.directoryBytesRead)) read"

        case .clearingHiddenAttributes:
            return "  Cleared \(latest.hiddenAttributesCleared) of \(latest.hiddenAttributesFound)"

        case .move:
            return generation + "Move \(latest.moveInGeneration) of \(latest.movesInGeneration), "
                + "\(percentage(latest.clustersDone, of: latest.clustersScheduled)) of the run copied"

        case .transfer(let transfer):
            return generation + "\(transfer.kind == .read ? "Reading" : "Writing") "
                + "\(transfer.index + 1) of \(transfer.of)"

        case .work(let work):
            switch work.activity {
            case .allocating:
                let count = commit?.allocations ?? work.clusters.count
                return generation + "Allocating \(count.counted("cluster")) in the FAT"
            case .gathering:
                let flips = commit?.flips ?? 0
                return generation + "Gathering the blocks holding \(flips) "
                    + "\(flips.word("entry", "entries")), block \(work.step + 1) of \(work.steps)"
            case .repointing:
                let flips = commit?.flips ?? 0
                return generation + "Pointing \(flips) \(flips.word("entry", "entries")) at the new "
                    + "copies, block \(work.step + 1) of \(work.steps)"
            case .clearing:
                let releases = commit?.releases ?? 0
                return generation + "Releasing \(releases.counted("old cluster")), "
                    + "block \(work.step + 1) of \(work.steps)"
            }

        case .barrier(let kind):
            return generation + (kind == .allocations
                ? "Flushing the new copies to the drive"
                : "Flushing the pointers to the drive")

        case .verifying:
            return "  Verified \(latest.directoriesVerified) of \(latest.directoriesToVerify)"
        }
    }

    /// The bar and the estimate, which stay with the run rather than with whatever step is on screen:
    /// a commit's five steps are not five percent of anything, and a bar that jumped to them and back
    /// would be worse than one that sat still.
    private func statusFigures() -> (fraction: Double?, eta: String?) {
        switch live {
        case .move, .transfer, .work, .barrier:
            return (fraction(latest.clustersDone, of: latest.clustersScheduled),
                    estimate(latest.clustersDone, of: latest.clustersScheduled, since: phaseStarted))
        case .clearingHiddenAttributes:
            return (fraction(latest.hiddenAttributesCleared, of: latest.hiddenAttributesFound),
                    estimate(latest.hiddenAttributesCleared, of: latest.hiddenAttributesFound,
                             since: phaseStarted))
        case .verifying:
            return (fraction(latest.directoriesVerified, of: latest.directoriesToVerify),
                    estimate(latest.directoriesVerified, of: latest.directoriesToVerify,
                             since: phaseStarted))
        case .scanning, nil:
            return (nil, nil)
        }
    }

    private var generation: String {
        "  Generation \(latest.generation)/\(latest.generationCount): "
    }

    // MARK: - Writing

    private var clusterSize: Int { geometry?.clusterSize ?? 0 }

    private func line(_ text: String) {
        sink(.line(text, emphasis: .normal))
    }

    private func announce(_ text: String, _ emphasis: Emphasis) {
        sink(.line(text, emphasis: emphasis))
    }

    /// A chain as its extents, which is how a reader judges whether something was in pieces. Truncated,
    /// because a badly fragmented file has hundreds and the first few make the point.
    private func describe(_ chain: ClusterSet) -> String {
        guard let first = chain.first else { return "-" }
        if chain.count == 1 { return "\(first)" }
        let extents = chain.reduce(into: [ClosedRange<UInt32>]()) { runs, cluster in
            if let last = runs.last, last.upperBound + 1 == cluster {
                runs[runs.count - 1] = last.lowerBound ... cluster
            } else {
                runs.append(cluster ... cluster)
            }
        }
        let shown = extents.prefix(3).map {
            $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)…\($0.upperBound)"
        }
        return shown.joined(separator: ",") + (extents.count > 3 ? ",+\(extents.count - 3) more" : "")
    }

    /// The two chains paired off into the largest stretches where source and destination are both
    /// unbroken — which is exactly the shape the copy took, one read and one write per stretch.
    private func spans(from old: ClusterSet, to new: ClusterSet) -> [String] {
        guard old.count == new.count else { return [] }
        var result: [String] = []
        var i = 0
        while i < old.count {
            var span = 1
            while i + span < old.count,
                  old[i + span] == old[i + span - 1] + 1,
                  new[i + span] == new[i + span - 1] + 1 {
                span += 1
            }
            result.append("\(old[i])…\(old[i + span - 1]) → \(new[i])…\(new[i + span - 1])")
            i += span
        }
        return result
    }
}
