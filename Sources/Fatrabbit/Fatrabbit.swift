import ArgumentParser
import Foundation

// MARK: - The command

/// The whole command-line surface, and the run it kicks off.
///
/// Every option is declared once here and the help text is generated from those declarations, which
/// is the reason for the dependency: what this used to be was a `while` loop over
/// `CommandLine.arguments` next to a 67-line string describing it, and the two had to be kept in
/// step by hand. They are now the same thing said once.
///
/// The prose that used to sit under a trailing NOTES heading has been moved to whichever declaration
/// it is about — the 8.3 name matching to `--first` and `--last`, the transcript behaviour to
/// `--plain` — because the formatter has no trailing section to put it in, and because next to the
/// flag is where a reader looking for it would go anyway. What is left in `discussion` is what has
/// to be read before the first run rather than while choosing a flag.
@main
struct Fatrabbit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fatrabbit",
        abstract: "Relocate the cluster chains of a FAT12, FAT16 or FAT32 volume in place so that "
            + "every file and directory occupies a single contiguous run, then rewrite the FATs and "
            + "boot record to match.",
        discussion: """
        The volume is modified in place, but never destructively: data is only ever copied into free \
        clusters before anything is repointed, so an interruption costs at most some unreferenced \
        clusters, which the next run reclaims.

        A mounted volume is refused outright, dry run or not: the system's own cached copy of the FAT \
        would be written back over ours, and it holds the device open besides. Unmount it but leave it \
        attached — \(System.unmountCommand(for: System.exampleWholeDevice)) — and note that a disk \
        device only opens as root, so this needs sudo.

        Ctrl-C stops after the batch in flight, which leaves a consistent, partly defragmented volume \
        that a later run carries on from. Press it twice to stop immediately: the design survives that \
        — it is what a power cut does — but the volume is left flagged as modified until the next run.
        """
    )

    @Argument(help: ArgumentHelp(
        "Unmounted FAT device node (e.g. \(System.exampleDevice)) or image file.",
        discussion: """
        Which variant it is follows from the volume's own cluster count and is worked out on opening; \
        exFAT is a different filesystem and is not supported. On FAT12 and FAT16 the root directory \
        lives in a fixed region outside the cluster space, so it is never relocated — and it cannot \
        hold more entries than it was formatted for.

        \(System.nodeAdvice)
        """,
        valueName: "volume"))
    var volumePath: String

    // Comma-separated and repeatable, both of which the old parser also allowed. The raw values are
    // kept as given and split below rather than through a `transform:`, because a transform runs per
    // value and would have to return a list, leaving a list of lists to flatten anyway.
    @Option(name: .customLong("first"), help: ArgumentHelp(
        "Root-level entry names to place ahead of everything else, laid out in the order given.",
        discussion: "Names match 8.3 short names, case-insensitively. Directories are placed "
            + "together with their entire subtree. May be given more than once, and each occurrence "
            + "may list several names.",
        valueName: "A,B,..."))
    var firstNames: [String] = []

    @Option(name: .customLong("last"), help: ArgumentHelp(
        "Root-level entry names to place after everything else, laid out in the order given.",
        discussion: "Matched and accumulated on the same terms as --first.",
        valueName: "X,Y,..."))
    var lastNames: [String] = []

    // `deMac` would derive as `--de-mac`, so the name is spelled out. The all-lowercase spelling is
    // carried as a second name rather than left to the formatter's "did you mean" suggestion: it is
    // not a typo but the obvious guess, and it worked before.
    @Flag(name: [.customLong("deMac"), .customLong("demac")], help: ArgumentHelp(
        "Strip macOS metadata while defragmenting.",
        discussion: "AppleDouble sidecars (._name) and .DS_Store anywhere, plus root-level volume "
            + "metadata (.Spotlight-V100, .fseventsd, .Trashes, .TemporaryItems, "
            + ".DocumentRevisions-V100, .VolumeIcon.icns, and similar). Also clears the hidden "
            + "attribute from every \".\" and \"..\" entry."))
    var deMac = false

    @Flag(help: ArgumentHelp(
        "Keep the order things already sit in, and never shove one object aside to make room for "
            + "another, so nothing is ever copied twice.",
        discussion: "Every file still ends up in one piece and free space is still drawn toward the "
            + "end, but compaction is opportunistic: an object that cannot claim its slot outright "
            + "is left alone, so some gaps survive. Much less work than the default on a volume "
            + "that has drifted."))
    var fast = false

    @Flag(help: ArgumentHelp(
        "Report as plain lines rather than drawing the block map.",
        discussion: """
        The map is used automatically when stderr is an interactive colour terminal with room for it, \
        and skipped otherwise — redirected output, --verbose, a window under 60x20, NO_COLOR, or a \
        terminal that says it is dumb.

        The block map draws on the alternate screen, so the scrollback behind it is untouched and every \
        line it showed is written out to stderr when it closes. A run watched on the map therefore \
        leaves behind the same transcript as one run with --plain. A completed run holds the finished \
        map on screen until a key is pressed; --plain exits as soon as it is done.
        """))
    var plain = false

    @Flag(name: [.customShort("n"), .customLong("dry-run"), .customLong("dryrun")],
          help: ArgumentHelp(
              "Go through the entire run without writing anything.",
              discussion: "The volume is opened read-only and every write is dropped, so the "
                  + "reported figures are what would have happened. Source data is still read, "
                  + "which proves every cluster the plan wants to move can actually be read. The "
                  + "volume still has to be unmounted, as above."))
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Emit per-object and per-cluster relocation detail.")
    var verbose = false

    /// The names to place first, with every occurrence and every comma-separated list flattened into
    /// one ordered run.
    var first: [String] { firstNames.flatMap(Self.splitList) }
    /// The names to place last, on the same terms as ``first``.
    var last: [String] { lastNames.flatMap(Self.splitList) }

    private static func splitList(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Setting up

extension Fatrabbit {
    /// Which reading of the run to show.
    ///
    /// The map is used where it will work and skipped otherwise, which is the only decision made here —
    /// both are consumers of the same stream, and the engine is built without either in mind. Not under
    /// `--verbose`, where the per-object commentary is the point and a display would only fight it for the
    /// same rows.
    var consumer: any EventConsumer {
        guard !plain, !verbose, Display.isAvailable else {
            return LineConsumer.toStandardError(verbose: verbose)
        }
        return Display(verbose: verbose)
    }
}

// MARK: - The run

extension Fatrabbit {
    /// Everything between opening the volume and putting it back in order. Returns whether it stopped
    /// early because a stop was asked for.
    func defragment(report: Reporter) throws(FATError) -> Bool {
        // `volumePath` rather than `volume`, because the opened volume below wants that name and a
        // local cannot shadow a property it is used alongside. The help still says `<volume>`.
        let requested = volumePath
        let source = System.rawNode(for: requested)

        // The one hazard the copy-then-repoint design cannot cover: a mounted volume has the system
        // holding its own copy of the FAT and directory blocks, and it will write those back over
        // whatever we do.
        //
        // A dry run is refused too, rather than allowed on the grounds that it writes nothing. The
        // system keeps the device of a mounted volume open for itself — an FSKit-backed msdos mount
        // refuses a read-only open outright with EBUSY — so the run cannot get at the volume anyway,
        // and where it can, what it reads is changing underneath it. Better to say so here than to
        // let it fail obscurely two steps later or report a plan drawn from a moving target.
        var attachedAs: String?
        switch mountState(ofVolumeAt: source) {
        case .mounted(let device, let locations):
            let places = locations.joined(separator: ", ")
            throw FATError.io("\(device) is mounted at \(places) — refusing to touch a live "
                + "filesystem, dry run or not. Unmount it first, keeping the device attached: "
                + System.unmountCommand(for: device))
        case .attached(let device):
            attachedAs = device
        case .free:
            break
        }

        report.post(.started(RunEvent.Setup(requested: requested,
                                            node: source,
                                            attachedAs: attachedAs,
                                            dryRun: dryRun,
                                            fast: fast,
                                            deMac: deMac)))

        let volume = try FATVolume(path: source, dryRun: dryRun)
        report.post(.opened(RunEvent.Geometry(label: volume.label,
                                              flavour: volume.flavour.name,
                                              clusterSize: volume.clusterSize,
                                              clusterCount: volume.countOfClusters,
                                              bytesPerSector: volume.bpb.bytesPerSector,
                                              sectorsPerCluster: volume.bpb.sectorsPerCluster,
                                              fixedRootEntries: volume.flavour.hasRelocatableRoot
                                                  ? nil : volume.bpb.rootEntCnt)))
        report.post(.layout(ClusterState.layout(of: volume.fat,
                                                clusterCount: volume.countOfClusters,
                                                badMarker: volume.flavour.badCluster)))
        report.update { $0.badClusters = volume.badClusters.count }

        report.phase(.scanning)
        let walker = DirectoryWalker(volume: volume, deMac: deMac, report: report)
        let (root, cleanup) = try walker.walk()

        report.phase(.planning)
        let plan = try DefragPlanner.plan(root: root,
                                          first: first,
                                          last: last,
                                          capacity: volume.countOfClusters,
                                          fast: fast,
                                          movableRoot: volume.flavour.hasRelocatableRoot)
        report.update {
            $0.filesFound = plan.fileCount
            $0.directoriesFound = plan.directoryCount
            $0.clustersInUse = plan.usedClusters
            $0.clusterCount = volume.countOfClusters
            $0.placedFirst = plan.orderedFirst
            $0.placedLast = plan.orderedLast
            $0.unmatchedNames = plan.unmatchedNames
        }

        let defragmenter = SafeDefragmenter(volume: volume,
                                            plan: plan,
                                            report: report,
                                            cleanup: deMac ? cleanup : nil,
                                            fast: fast)
        try defragmenter.run()
        return defragmenter.wasInterrupted
    }

    /// Starts the consumer, runs the engine, and — whatever happens — drains before leaving.
    ///
    /// The order at the end is the one thing here that has to be right. `post` hands an event to another
    /// task, so the last lines of a run are still in flight when the engine returns: draining is what waits
    /// for them to be applied, and only then may anything hand the terminal back or call `exit`. Get it the
    /// wrong way round and the run ends by silently discarding the very lines that say how it went. That
    /// is also why the non-zero status is thrown as an `ExitCode` at the very end rather than anywhere
    /// nearer to where it was decided.
    func run() throws {
        // Monotonic, so the total is unaffected by the clock being adjusted under a run that may last
        // hours, and continuous rather than suspending, so time asleep counts as the wait it was.
        let started = ContinuousClock.now
        let events = EventStream()
        let drain = events.start(consumer)
        let report = Reporter(events)

        // A second Ctrl-C leaves at once, but not before what has been said about it has been shown.
        //
        // `Foundation.exit` spelled out: `ParsableCommand` has a static `exit(withError:)` of its own,
        // which is the closer match by name and turns a bare `exit(130)` into a compile error rather
        // than the wrong call, but only because 130 is not an `Error`.
        Interruption.listen(stream: events) {
            events.post(.ended(.stopped(untouched: false), elapsed: started.duration(to: .now)))
            drain.drain()
            Foundation.exit(130)
        }

        // One catch rather than two. Everything below declares `throws(FATError)`, so `error` arrives
        // already typed and the "and if it is something else" arm — which could only ever have reported a
        // `localizedDescription` nothing here produces — is not merely unused but impossible to reach.
        var status: Int32 = 0
        do {
            let interrupted = try defragment(report: report)
            let elapsed = started.duration(to: .now)
            if interrupted {
                report.post(.ended(.stopped(untouched: false), elapsed: elapsed))
                status = 130
            } else {
                report.post(.ended(.completed, elapsed: elapsed))
            }
        } catch FATError.interrupted {
            // Only reachable from a stage that had written nothing, so there is nothing to put right.
            report.post(.ended(.stopped(untouched: true), elapsed: started.duration(to: .now)))
            status = 130
        } catch {
            report.post(.ended(.failed(error.description), elapsed: started.duration(to: .now)))
            status = 1
        }

        drain.drain()
        if status != 0 { throw ExitCode(status) }
    }
}
