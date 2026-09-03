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

        Run with no volume named, every attached FAT volume is listed and one is asked for. The list is \
        shown and the question asked even when only one was found: a run only ever starts unprompted on \
        a device named on the command line.

        Ctrl-C stops after the batch in flight, which leaves a consistent, partly defragmented volume \
        that a later run carries on from. Press it twice to stop immediately: the design survives that \
        — it is what a power cut does — but the volume is left flagged as modified until the next run.
        """,
        // Buys `--version` from the formatter, which is the whole reason it is here: a tool installed
        // from a tarball rather than built from a checkout has no other way to say which one it is.
        // This string is the release number written by hand, and the one thing here that has to move
        // in step with the git tag — Homebrew's own test asserts the two agree.
        version: "1.0.3"
    )

    @Argument(help: ArgumentHelp(
        "Unmounted FAT device node (e.g. \(System.exampleDevice)) or image file. Left out, the "
            + "attached FAT volumes are listed and one is asked for.",
        discussion: """
        Which variant it is follows from the volume's own cluster count and is worked out on opening; \
        exFAT is a different filesystem and is not supported. On FAT12 and FAT16 the root directory \
        lives in a fixed region outside the cluster space, so it is never relocated — and it cannot \
        hold more entries than it was formatted for.

        \(System.nodeAdvice)
        """,
        valueName: "volume"))
    var volumePath: String?

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
        map on screen until a key is pressed, unless told not to by --no-pause; --plain exits as soon \
        as it is done.
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

    // The name is the negative because the behaviour it turns off is the default, and `inversion:`
    // was not used for it: that would add a `--pause` nobody needs alongside the `--no-pause`
    // everybody asking for this wants, to say the thing that happens anyway.
    @Flag(help: ArgumentHelp(
        "Do not hold the finished block map on screen waiting for a key.",
        discussion: "The map otherwise stays up when a run completes, so its last state can be "
            + "looked at, which is no use to a run nobody is watching: a scheduled or scripted one "
            + "would wait for a key that is never coming. Affects nothing else — the transcript "
            + "written out on the way out is the same either way, and --plain already exits as soon "
            + "as it is done. A run stopped by Ctrl-C or an error has never paused."))
    var noPause = false

    // Named for what it does to the list rather than for the media it lets in, because what it lets
    // in is two unlike things — fixed disks and firmware partitions — with no one word between them.
    @Flag(name: .customLong("all-devices"), help: ArgumentHelp(
        "List every attached FAT volume, holding nothing back.",
        discussion: "Only removable, external and image-backed media are listed otherwise, and EFI "
            + "system partitions are left out of even those: they are FAT32, they turn up on "
            + "external enclosures as readily as on the disk a machine boots from, and 200 MB of "
            + "firmware payload is the last thing anybody reaching for this tool meant. Both "
            + "exclusions are about what gets offered unasked and nothing else — a device named on "
            + "the command line has always been accepted whatever it is or wherever it lives, and "
            + "under this flag the list makes no judgement either."))
    var allDevices = false

    @Flag(name: .shortAndLong, help: "Emit per-object and per-cluster relocation detail.")
    var verbose = false


    @Flag(name: .customLong("verify-copies"), help: ArgumentHelp(
        "Check every span against the medium in both directions as it is copied, and stop if the "
            + "medium contradicts itself. For media you have reason to distrust.",
        discussion: """
        A defragmenter can only be as truthful as the reads it is given. Every byte it moves it \
        first reads, and if a device answers a read with the wrong bytes there is nothing in the \
        layout, the FAT or the directory tree to say so afterwards: the copy is faithfully written \
        to the right place, the lengths agree, fsck is content, and the contents are simply wrong. \
        Worse for a file than for a directory, since a directory at least has a shape to be broken.

        So this reads every span twice, by two different routes, and stops the run if they disagree. \
        A disagreement means the medium returned different answers to the same question, and no \
        amount of care in this tool can make that safe — which is why it stops rather than retrying.

        The other direction is checked too, and for a reason found the hard way. A reader measured \
        here was handed a 131,072-byte write of the size it advertises, performed a single \
        65,536-byte write of the payload's second half, placed it at the first half's address, and \
        returned success. Nothing about the read path could have seen that. So every span is also \
        read back off the medium after it is written and compared with what was sent.

        That check sits where a failure is free. The copy phase is the one moment when nothing on \
        the volume refers to the new data — the FAT entries that allocate it and the pointers that \
        name it are both written afterwards — so stopping there leaves the original live and the \
        volume exactly as it was found. The transfer probe at startup catches the one misbehaviour \
        that has been characterised and measured; this catches whatever has not been.

        Not needed on hardware you trust, and off by default for that reason: it roughly doubles the \
        traffic of the copy phase, which measured +23% of wall clock against an image and costs more \
        against a card, where every extra read is a real transfer. Worth switching on for a card that has produced unexplained \
        corruption, a reader you are unsure of, or a volume whose contents matter more than the \
        hour it costs. A run that completes with this on has had every copied byte confirmed in \
        both directions.
        """))
    var verifyCopies = false


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
    /// Which volume to work on, or nil where the answer was to do nothing.
    ///
    /// The argument is the answer wherever it was given, and no scan happens at all in that case:
    /// enumerating devices to confirm a path the caller typed would be work done to second-guess
    /// them, and would make a run fail on a device the scan happened not to recognise.
    func resolvedVolume() throws(DevicePicker.Unresolved) -> String? {
        if let volumePath { return volumePath }
        return try DevicePicker.choose(unfiltered: allDevices)
    }

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
        return Display(verbose: verbose, holdsWhenDone: !noPause)
    }
}

// MARK: - The run

extension Fatrabbit {
    /// Everything between opening the volume and putting it back in order. Returns whether it stopped
    /// early because a stop was asked for.
    ///
    /// The volume arrives as a parameter rather than being read off `volumePath`, because by here it
    /// has been settled: either it was given on the command line or it was picked from a list, and
    /// nothing below has any business knowing which.
    func defragment(report: Reporter, volume requested: String) throws(FATError) -> Bool {
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

        // Put the number the device published to the test before trusting a gigabyte of somebody's
        // data to it. A reader measured here states 131,072 twice over, consistently, and mishandles
        // it — writing 65,536 bytes of the wrong half to the wrong address, returning success, and
        // costing 177 files. Asking is cheap; being wrong is not.
        //
        // Skipped where it cannot apply. A dry run must not write. A plain image has no controller
        // to misbehave, and answers no transfer-limit ioctl at all, which is the signal used. And a
        // volume with no spare run to write into is left alone rather than squeezed.
        let probe: TransferProbe.Result
        if dryRun {
            // A dry run cannot write, but it can still ask the medium whether it reads consistently
            // — and it must, because the whole run is reads, and reading at a size the medium
            // mishandles produces a report about the ruler rather than about the volume.
            let stated = FATVolume.maxTransfer
            if volume.deviceMaxTransfer != nil,
               let region = TransferProbe.spareRegion(
                   in: volume,
                   wanting: TransferProbe.spaceRequired(forStated: stated),
                   atLeast: TransferProbe.spaceRequired(forStated: stated)).region {
                let outcome = try TransferProbe.measureReadsOnly(volume: volume, region: region)
                FATVolume.maxTransfer = outcome.chosen
                probe = .readsOnly(outcome)
            } else {
                probe = .dryRun
            }
        } else if volume.deviceMaxTransfer == nil {
            probe = .notADevice
        } else {
            let stated = FATVolume.maxTransfer
            let found = TransferProbe.spareRegion(
                in: volume,
                wanting: TransferProbe.spacePreferred(forStated: stated),
                atLeast: TransferProbe.spaceRequired(forStated: stated))
            if let region = found.region {
                let outcome = try TransferProbe.measure(volume: volume, region: region)
                FATVolume.maxTransfer = outcome.chosen
                probe = .measured(outcome)
            } else {
                // Nowhere to test in, so the size the device published would have to be taken on
                // trust. It used to be, with a line saying so — which is the same mistake that cost
                // 177 files, made politely: the reader that destroyed them published 131,072 twice
                // over and consistently, and a run that believes the number has no way to find out
                // otherwise. It fails silently, it fails inside data the volume still points at, and
                // the first sign of it is an error an hour later.
                //
                // So the run stops instead, unless the caller has asked for every span to be checked
                // as it is copied. That is not a formality: `--verify-copies` reads each destination
                // straight back off the medium and stops on the first disagreement, which is exactly
                // the fault the probe exists to find, caught one span at a time instead of once at
                // the start. Slower, and sound.
                guard verifyCopies else {
                    throw FATError.capacity("""
                    not enough free space in one piece to find out what this device does with a \
                    \(FATVolume.maxTransfer / 1024) KiB transfer — it needs \
                    \(TransferProbe.spaceRequired(forStated: stated) / 1024) KiB in one run and the \
                    largest here is \(found.largest / 1024) KiB.

                    That test is not a formality. A card reader measured during this tool's \
                    development states a 128 KiB limit, twice over and consistently, and mishandles \
                    it: one write lands half its payload at the wrong address, reports success, and \
                    destroys data the volume still refers to. Untested, the published figure is the \
                    one number in a run whose being wrong is both silent and unrecoverable, so it is \
                    not taken on trust.

                    Free enough space for the test and run it again, or pass --verify-copies to run \
                    now — that reads every span straight back off the medium as it is copied and \
                    stops on the first disagreement, which catches the same fault a span at a time.

                    Nothing has been written.
                    """)
                }
                probe = .noRoom(largestFreeRun: found.largest,
                                needed: TransferProbe.spaceRequired(forStated: stated))
            }
        }

        report.post(.opened(RunEvent.Geometry(label: volume.label,
                                              flavour: volume.flavour.name,
                                              clusterSize: volume.clusterSize,
                                              clusterCount: volume.countOfClusters,
                                              bytesPerSector: volume.bpb.bytesPerSector,
                                              sectorsPerCluster: volume.bpb.sectorsPerCluster,
                                              fixedRootEntries: volume.flavour.hasRelocatableRoot
                                                  ? nil : volume.bpb.rootEntCnt,
                                              deviceMaxTransfer: volume.deviceMaxTransfer,
                                              transferSize: FATVolume.maxTransfer,
                                              probe: probe)))
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
                                            fast: fast,
                                            verifyCopies: verifyCopies)
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
        // Before anything else, and before any of the machinery below exists. The picker writes to
        // stderr and reads stdin, so it has to be finished with the terminal before a consumer takes
        // the alternate screen — and it runs before `Interruption` is armed on purpose: at this point
        // nothing is open and nothing has been written, so Ctrl-C being fatal is the right ending.
        guard let volume = try resolvedVolume() else { throw ExitCode.success }

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
            let interrupted = try defragment(report: report, volume: volume)
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
