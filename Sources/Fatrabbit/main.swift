import Foundation

// MARK: - Argument parsing

let usage = """
fatrabbit — relocates the cluster chains of a FAT32 volume in place so that every file
and directory occupies a single contiguous run, then rewrites the FATs and boot record
to match.

USAGE:
    fatrabbit <volume> [options]

ARGUMENTS:
    <volume>             Unmounted FAT32 device node (e.g. \(System.exampleDevice)) or image file.
\(System.nodeAdvice)
                         The volume is modified in place, but never destructively: data is
                         only ever copied into free clusters before anything is repointed,
                         so an interruption costs at most some unreferenced clusters, which
                         the next run reclaims. A mounted volume is refused outright, dry run
                         or not: the system's own cached copy of the FAT would be written back
                         over ours, and it holds the device open besides. Unmount it but leave
                         it attached — \(System.unmountCommand(for: System.exampleWholeDevice)) —
                         and note that a disk device only opens as root, so this needs sudo.

OPTIONS:
    --first A,B,...      Root-level entry names to place ahead of everything else,
                         laid out in the order given.
    --last  X,Y,...      Root-level entry names to place after everything else,
                         laid out in the order given.
    --deMac              Strip macOS metadata while defragmenting: AppleDouble sidecars
                         (._name) and .DS_Store anywhere, plus root-level volume metadata
                         (.Spotlight-V100, .fseventsd, .Trashes, .TemporaryItems,
                         .DocumentRevisions-V100, .VolumeIcon.icns, and similar). Also
                         clears the hidden attribute from every "." and ".." entry.
    --fast               Keep the order things already sit in, and never shove one object
                         aside to make room for another, so nothing is ever copied twice.
                         Every file still ends up in one piece and free space is still drawn
                         toward the end, but compaction is opportunistic: an object that
                         cannot claim its slot outright is left alone, so some gaps survive.
                         Much less work than the default on a volume that has drifted.
    --plain              Report as plain lines rather than drawing the block map. The map is
                         used automatically when stderr is an interactive colour terminal with
                         room for it, and skipped otherwise — redirected output, --verbose, a
                         window under 60x20, NO_COLOR, or a terminal that says it is dumb.
    --dry-run, -n        Go through the entire run without writing anything: the volume is
                         opened read-only and every write is dropped, so the reported figures
                         are what would have happened. Source data is still read, which proves
                         every cluster the plan wants to move can actually be read. The volume
                         still has to be unmounted, as above.
    --verbose            Emit per-object and per-cluster relocation detail.
    --help               Show this help.

NOTES:
    Names match 8.3 short names, case-insensitively. Directories are placed together
    with their entire subtree.

    Ctrl-C stops after the batch in flight, which leaves a consistent, partly defragmented
    volume that a later run carries on from. Press it twice to stop immediately: the design
    survives that — it is what a power cut does — but the volume is left flagged as modified
    until the next run.

    The block map draws on the alternate screen, so the scrollback behind it is untouched and
    every line it showed is written out to stderr when it closes. A run watched on the map
    therefore leaves behind the same transcript as one run with --plain. A completed run holds
    the finished map on screen until a key is pressed; --plain exits as soon as it is done.
"""

struct Options {
    var volume: String?
    var first: [String] = []
    var last: [String] = []
    var verbose = false
    var deMac = false
    var fast = false
    var dryRun = false
    var plain = false
}

func splitList(_ value: String) -> [String] {
    value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

func parseArguments(_ args: [String]) throws(FATError) -> Options {
    var options = Options()
    var positionals: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--help", "-h":
            print(usage)
            exit(0)
        case "--verbose", "-v":
            options.verbose = true
        case "--deMac", "--demac":
            options.deMac = true
        case "--fast":
            options.fast = true
        case "--dry-run", "--dryrun", "-n":
            options.dryRun = true
        case "--plain":
            options.plain = true
        case "--first", "--last":
            guard i + 1 < args.count else { throw FATError.io("\(arg) requires a value") }
            let list = splitList(args[i + 1])
            if arg == "--first" { options.first += list } else { options.last += list }
            i += 1
        default:
            if arg.hasPrefix("--first=") {
                options.first += splitList(String(arg.dropFirst("--first=".count)))
            } else if arg.hasPrefix("--last=") {
                options.last += splitList(String(arg.dropFirst("--last=".count)))
            } else if arg.hasPrefix("-") {
                throw FATError.io("unknown option '\(arg)'")
            } else {
                positionals.append(arg)
            }
        }
        i += 1
    }

    guard positionals.count == 1 else {
        throw FATError.io("expected a single <volume> argument; see --help")
    }
    options.volume = positionals[0]
    return options
}

// MARK: - Setting up

/// Which reading of the run to show.
///
/// The map is used where it will work and skipped otherwise, which is the only decision made here —
/// both are consumers of the same stream, and the engine is built without either in mind. Not under
/// `--verbose`, where the per-object commentary is the point and a display would only fight it for the
/// same rows.
func consumer(for options: Options) -> any EventConsumer {
    guard !options.plain, !options.verbose, Display.isAvailable else {
        return LineConsumer.toStandardError(verbose: options.verbose)
    }
    return Display(verbose: options.verbose)
}

// MARK: - The run

/// Everything between opening the volume and putting it back in order. Returns whether it stopped
/// early because a stop was asked for.
func defragment(_ options: Options, report: Reporter) throws(FATError) -> Bool {
    guard let requested = options.volume else { return false }
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
                                        dryRun: options.dryRun,
                                        fast: options.fast,
                                        deMac: options.deMac)))

    let volume = try FAT32Volume(path: source, dryRun: options.dryRun)
    report.post(.opened(RunEvent.Geometry(label: volume.label,
                                          clusterSize: volume.clusterSize,
                                          clusterCount: volume.countOfClusters,
                                          bytesPerSector: volume.bpb.bytesPerSector,
                                          sectorsPerCluster: volume.bpb.sectorsPerCluster)))
    report.post(.layout(ClusterState.layout(of: volume.fat, clusterCount: volume.countOfClusters)))
    report.update { $0.badClusters = volume.badClusters.count }

    report.phase(.scanning)
    let walker = DirectoryWalker(volume: volume, deMac: options.deMac, report: report)
    let (root, cleanup) = try walker.walk()

    report.phase(.planning)
    let plan = try DefragPlanner.plan(root: root,
                                      first: options.first,
                                      last: options.last,
                                      capacity: volume.countOfClusters,
                                      fast: options.fast)
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
                                        cleanup: options.deMac ? cleanup : nil,
                                        fast: options.fast)
    try defragmenter.run()
    return defragmenter.wasInterrupted
}

/// Starts the consumer, runs the engine, and — whatever happens — drains before leaving.
///
/// The order at the end is the one thing here that has to be right. `post` hands an event to another
/// task, so the last lines of a run are still in flight when the engine returns: draining is what waits
/// for them to be applied, and only then may anything hand the terminal back or call `exit`. Get it the
/// wrong way round and the run ends by silently discarding the very lines that say how it went.
func fatrabbit() -> Int32 {
    // One catch rather than two. Everything below declares `throws(FATError)`, so `error` arrives
    // already typed and the "and if it is something else" arm — which could only ever have reported a
    // `localizedDescription` nothing here produces — is not merely unused but impossible to reach.
    let options: Options
    do {
        options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.description)\n".utf8))
        return 1
    }

    // Monotonic, so the total is unaffected by the clock being adjusted under a run that may last
    // hours, and continuous rather than suspending, so time asleep counts as the wait it was.
    let started = ContinuousClock.now
    let events = EventStream()
    let drain = events.start(consumer(for: options))
    let report = Reporter(events)

    // A second Ctrl-C leaves at once, but not before what has been said about it has been shown.
    Interruption.listen(stream: events) {
        events.post(.ended(.stopped(untouched: false), elapsed: started.duration(to: .now)))
        drain.drain()
        exit(130)
    }

    var status: Int32 = 0
    do {
        let interrupted = try defragment(options, report: report)
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
    return status
}

exit(fatrabbit())
