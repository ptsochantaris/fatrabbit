import Foundation
import Synchronization

/// The full-screen view of a run: the volume drawn as a coloured grid, the phase and elapsed time,
/// a pane of the most recent log lines, and a progress bar with the current operation and estimate.
///
/// It draws on the alternate screen buffer, so the scrollback underneath is left untouched and the
/// terminal is handed back exactly as it was found. Every logged line is also kept, and replayed to
/// stderr on the way out — so a run watched on the map still leaves behind the same transcript as
/// one that was not, and nothing about the record depends on the decoration.
///
/// It is one reading of the event stream and nothing more. The engine has no idea it exists: what
/// arrives is what arrives, in batches, and everything below is this type deciding what to make of
/// them. The wording of the lines is not even its own — it keeps a `LineConsumer` whose sink files
/// lines in the transcript instead of writing them to stderr, so a watched run and a plain one say the
/// same things in the same words, and a map that reworded anything would be a second dialect to keep
/// in step.
///
/// Still `@unchecked`, and the remaining reason is worth stating exactly, because it is now a much
/// smaller one than it was. It used to stand in for twenty mutable properties and an `NSLock` taken by
/// hand at thirteen call sites. What is left is a single stored `lines`, which is a `LineConsumer` — a
/// class with unsynchronised state, safe because `EventConsumer` is documented as being called from one
/// task only, and this one is never touched from anywhere else. Everything a second thread does
/// reach — the frame, the lifecycle, the map, and the static below — is behind a mutex, so dropping
/// the conformance leaves exactly one complaint: publishing `self` to `onScreen` for the timer and
/// `atexit` to find, which is the one thing this type genuinely does share.
final class Display: EventConsumer, @unchecked Sendable {
    /// Only for the things that cannot be handed a reference: `atexit`, which takes a non-capturing
    /// closure, and the two dispatch sources. A second Ctrl-C exits from inside a signal handler, and
    /// leaving the alternate screen unclosed would hand back a terminal with no cursor.
    ///
    /// Nothing feeds the display through this. Events are the only way in.
    private static let onScreen = Mutex<Display?>(nil)

    /// Whichever display currently holds the screen, if any. The three callers that reach for it are
    /// all outside this type's own flow — a timer, a window-size signal, and `atexit` — and each of
    /// them can name a static but cannot be handed anything.
    private static func current() -> Display? { onScreen.withLock { $0 } }

    /// Below this there is not room for a grid worth looking at, so the run falls back to lines.
    private static let minimumColumns = 60
    private static let minimumRows = 20

    /// Whether drawing is worth attempting at all — a terminal, with colour, and a window big enough.
    /// Callers treat false as "carry on with line output".
    static var isAvailable: Bool {
        guard Terminal.isUsable, let size = Terminal.size() else { return false }
        return size.columns >= minimumColumns && size.rows >= minimumRows
    }

    /// Weights, so that the parts of the frame rank by how much they matter: titles carry, the live
    /// operation sits just under them, the log is quieter still, and the box itself recedes rather
    /// than drawing a bright cage around a coloured map. The tool's own two-space indent under a
    /// heading then reads as indentation rather than as the only thing separating them.
    private static let frameInk = "\u{1B}[38;5;250m"
    private static let titleInk = "\u{1B}[1;38;5;255m"
    private static let liveInk = "\u{1B}[38;5;253m"
    private static let logInk = "\u{1B}[38;5;247m"
    private static let quietInk = "\u{1B}[38;5;244m"
    private static let reset = "\u{1B}[0m"

    /// One filed line: what a run leaves behind, and what the log pane shows the tail of.
    fileprivate typealias Line = (text: String, emphasis: Emphasis)

    /// The frame as it stands: everything the drawing reads to compose one.
    ///
    /// Gathering it is the point of the type. The nine drawing helpers at the foot of this file were
    /// methods on the class that read a dozen mutable properties and depended on their caller having
    /// taken a lock first, with nothing in a name or a signature to say so — `render` takes the lock
    /// and calls seven of them. As methods on `Frame` that dependency becomes the shape of the code
    /// rather than a convention: they cannot be reached without the state, and the state cannot be
    /// reached without the mutex.
    fileprivate struct Frame {
        let unicode: Bool
        let started: ContinuousClock.Instant

        var volumeName = ""
        var device = ""
        /// Which FAT variant, as the engine named it. Worth a place in the title now that a run can
        /// be any of three: the geometry beside it reads very differently on a 1.4 MB FAT12 floppy
        /// image than on a 2 TB FAT32 volume, and nothing else on screen says which one this is.
        var flavour = ""
        var geometry = ""

        var phaseName = "Starting"
        var transcript: [Line] = []
        /// Set when the run finished properly, so the line saying so can look like it.
        var succeeded = false
        var operation = ""
        var fraction: Double?
        var eta: String?

        /// Set once the run is over, so the elapsed figure stops where the work stopped.
        var frozenElapsed: Duration?

        var size: Terminal.Size
        var resized = false
        var needsClear = true
        var frames = 0
    }

    /// The frame, and the lifecycle that decides whether there is a screen to draw it on.
    ///
    /// One mutex over both rather than one each: `render` needs the flags and the frame together, and
    /// splitting them would buy a lock-ordering rule to get right in exchange for nothing.
    private struct State {
        var frame: Frame
        /// How the run ended, which decides whether the finished frame is worth holding on screen.
        var outcome: RunEvent.Outcome?
        /// True between taking the screen and handing it back. Before it, there is nowhere to file a
        /// line, so lines go straight to stderr exactly as a plain run would have put them.
        var begun = false
        var tornDown = false
        var timer: DispatchSourceTimer?
    }

    private let state: Mutex<State>

    /// Made when the volume opens, which is the first moment its size is known.
    ///
    /// Held apart from `State` deliberately. It has a lock of its own, and the events that mark it —
    /// one per transfer, tens of thousands a run — arrive on the thread the engine is working on.
    /// Reaching the map through this type's lock would put that thread behind whatever a frame is
    /// doing, which is the coupling the event stream exists to remove.
    private let map = Mutex<BlockMap?>(nil)

    /// The wording, shared with the plain output. Set after the rest, because its sink refers back here.
    ///
    /// Still a two-phase assignment, and worth saying why the obvious tidy-up does not work: the sink
    /// only ever wants somewhere to put a line, so handing it the state directly instead of `self` would
    /// make this a plain `let` — except that `Mutex` is noncopyable, so it cannot be captured by an
    /// escaping closure at all. The state is reachable only through the instance that owns it, and an
    /// instance cannot be captured before it exists.
    private var lines: LineConsumer!

    init(verbose: Bool) {
        self.state = Mutex(State(frame: Frame(unicode: Terminal.usesUnicode,
                                              started: .now,
                                              size: Terminal.size()
                                                  ?? Terminal.Size(columns: 80, rows: 24))))
        self.lines = LineConsumer(verbose: verbose, showsStatus: true) { [weak self] output in
            guard let self else { return }
            switch output {
            case .line(let text, let emphasis):
                log(text, emphasis: emphasis)
            case .status(let text, let fraction, let eta):
                activity(text, fraction: fraction, eta: eta)
            case .endStatus, .clearStatus:
                // The live line has a place of its own here, which nothing else writes to, so there
                // is neither a row to give it nor a row to take back.
                break
            }
        }
    }

    // MARK: - Reading the run

    func apply(_ batch: [RunEvent]) async {
        // The map first, so that the volume is on screen before the line announcing it is filed: that
        // is the order a plain run wrote them in, and it is what keeps the replayed transcript matching
        // one that was never watched.
        for event in batch { absorb(event) }
        await lines.apply(batch)
    }

    func finish() async {
        await lines.finish()
        // The map is at its most interesting the moment the run ends, which is also the moment it would
        // otherwise disappear. Only on a run that finished: after a Ctrl-C or an error, someone has
        // already been told what they need to know, and asking them to press a key would be rude.
        let holdOnScreen = state.withLock { state -> Bool in
            guard state.begun,
                  case .completed = state.outcome ?? .stopped(untouched: false) else { return false }
            return true
        }
        if holdOnScreen { awaitDismissal() }
        tearDown()
    }

    /// The map, if there is one yet. Read out and released rather than used under the lock, so that
    /// marking it never nests this type's mutex inside the map's own.
    private var currentMap: BlockMap? { map.withLock { $0 } }

    private func absorb(_ event: RunEvent) {
        switch event {
        case .started(let setup):
            state.withLock { $0.frame.device = setup.node + (setup.dryRun ? " (dry run)" : "") }

        case .opened(let geometry):
            let cells = state.withLock { state -> Int in
                state.frame.volumeName = geometry.label
                state.frame.flavour = geometry.flavour
                state.frame.geometry = "\(readableBytes(geometry.byteCount)) in "
                    + "\(geometry.clusterSize / 1024) KiB clusters"
                return max(1, state.frame.size.columns - 2)
            }
            map.withLock {
                $0 = BlockMap(clusterCount: geometry.clusterCount, cellCount: cells)
            }
            begin()

        case .labelled(let name):
            state.withLock { $0.frame.volumeName = name }

        case .phase(let phase):
            // Nothing from the old phase is still in flight, and the last step of a bookkeeping pass
            // has no completion of its own to say so — without this it would sit lit through whatever
            // comes next. The same for any mark a pass left behind: the flush that would normally
            // release it is not guaranteed to happen, since a commit with nothing to free skips it.
            currentMap?.settle()
            currentMap?.untaintAll()
            state.withLock { state in
                state.frame.phaseName = Self.name(of: phase)
                state.frame.operation = ""
                state.frame.fraction = nil
                state.frame.eta = nil
            }

        case .layout(let states):
            currentMap?.replace(states)

        case .clusters(let clusters, let clusterState):
            currentMap?.set(clusters, to: clusterState)

        case .transfer(let transfer):
            // The range itself, not an array built from it. A transfer already says where it started
            // and how many clusters it covered, so this used to allocate and fill an array of up to a
            // few hundred numbers purely to walk it twice — once per transfer, and a run has tens of
            // thousands of them.
            let clusters = transfer.firstCluster
                ..< transfer.firstCluster + UInt32(max(transfer.clusters, 1))
            let map = currentMap
            guard transfer.done else {
                // Lit as the transfer is issued, and kept lit until the medium answers — rather than
                // for the fixed half second a trail lasts. Both edges were always marked; what was
                // wrong was the duration, which assumed an operation finishes inside its own trail.
                // On a card with a slow region a single write outlives it, and the light then goes
                // out while the drive is still working on it.
                map?.begin(clusters, transfer.kind == .read ? .reading : .writing)
                return
            }
            map?.settle()
            // Only once the bytes are in hand. A read leaves the data where it was, and it stays the
            // copy everything points at until the commit flips the pointers and releases it — so the
            // cell says "collected" rather than flashing and reverting to what it was. A write has
            // landed but is named by nothing until the same commit, so it says "written". The two
            // together draw the picking-up running ahead of the letting-go.
            map?.set(clusters, to: transfer.kind == .read ? .collected : .written)

        case .working(let work):
            let kind: CellActivity? = switch work.activity {
            case .gathering: .reading    // it is a read, and drawn as one — see `.gathering`
            case .repointing: .repointing
            case .clearing: .clearing
            case .allocating: nil        // FAT bookkeeping, with no cluster of its own to light
            }
            guard let kind else { return }
            let map = currentMap
            // Both edges, exactly as a transfer reports them: lit while the drive is being made to
            // work on the block, and counting down from the moment it answers. Inferring the end from
            // the next step starting is not the same thing — the gaps between these are real, since a
            // gather served from the cache never lights at all.
            guard work.done else {
                map?.begin(work.clusters, kind)
                return
            }
            map?.settle()
            // The same shape the copy pass draws, drawn around a pointer flip: the flash marks the
            // block, the mark stands while the pass carries on past it, and the whole pass gives way
            // together at the end. Marked here and not on the gather, because until the write returns
            // the medium still holds the old pointer and colouring it would be describing a volume
            // that does not exist yet — the same rule the copy pass follows in waiting for `done`.
            guard case .repointing = work.activity else { return }
            map?.taint(work.clusters, .repointed)
            // What releases them is the flush, below — a flipped pointer stops being provisional when
            // the drive says it has it, and not before. Steps of zero is the one case with no flush
            // coming: an undivided act, marked and released in the same breath, which still leaves it
            // lit for as long as a trail lasts.
            if work.steps == 0 { map?.untaintAll() }

        case .barrier(let barrier, let done):
            // The case this was built for, and now the same treatment everything else gets: one call
            // that returns when the drive has taken everything, which on a spinning disk is seconds.
            let map = currentMap
            guard done else {
                map?.begin(barrier.clusters, .flushing)
                return
            }
            map?.settle()
            // And this is where a flipped pointer stops being provisional. The blocks the pass marked
            // stand through the flush — drawn under it, since the flush is holding exactly them — and
            // give way together when the drive answers, which is the moment the flips became real.
            // Nothing marks them again until the next pass, so this is the whole life of the colour.
            if case .pointers = barrier.kind { map?.untaintAll() }

        case .interrupted:
            state.withLock { $0.frame.phaseName = "Stopping" }

        case .ended(let outcome, let elapsed):
            state.withLock { state in
                state.outcome = outcome
                state.frame.frozenElapsed = elapsed
                switch outcome {
                case .completed:
                    state.frame.succeeded = true
                    state.frame.phaseName = "Done"
                case .stopped:
                    state.frame.phaseName = "Stopped"
                case .failed:
                    state.frame.phaseName = "Failed"
                }
            }

        case .phaseCompleted, .telemetry, .generationCompleted, .commit, .relocated, .removed:
            // Figures and moments, which reach the frame as words through `lines`.
            break
        }
    }

    private static func name(of phase: RunEvent.Phase) -> String {
        switch phase {
        case .scanning: return "Scanning"
        case .planning: return "Planning"
        case .removingMetadata: return "Removing macOS metadata"
        case .clearingHiddenAttributes: return "Clearing hidden attributes"
        case .scheduling: return "Working out the moves"
        case .defragmenting: return "Defragmenting"
        case .verifying: return "Verifying directories"
        case .finishing: return "Finishing"
        }
    }

    // MARK: - Taking and handing back the screen

    private func begin() {
        let alreadyStarted = state.withLock { state -> Bool in
            guard !state.begun, !state.tornDown else { return true }
            state.begun = true
            return false
        }
        guard !alreadyStarted else { return }

        Display.onScreen.withLock { $0 = self }
        Terminal.enterFullScreen()
        Terminal.onResize { Display.current()?.noteResize() }
        // Covers every way out that does not come back here: a crash, or an exit from somewhere that
        // has not been taught to drain the stream first.
        atexit { Display.current()?.tearDown() }

        // Assembled inside the lock; see the note in Terminal.onResize for why.
        state.withLock { state in
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now(), repeating: .milliseconds(125))
            timer.setEventHandler { Display.current()?.render() }
            timer.resume()
            state.timer = timer
        }
    }

    /// Holds the finished frame on screen until a key is pressed, so that the last state of the map can
    /// actually be looked at — otherwise the run ends and the whole thing vanishes in the same instant
    /// it becomes worth seeing.
    ///
    /// The clock has already stopped by this point: the run is over, and a timer still counting would
    /// suggest otherwise. Redrawing continues, so the window can still be resized while it waits.
    private func awaitDismissal() {
        state.withLock { state in
            let elapsed = state.frame.frozenElapsed ?? .zero
            state.frame.operation = "Done in \(elapsed.readable) — press any key to exit"
            state.frame.fraction = 1
            state.frame.eta = nil
        }
        Terminal.waitForKey()
    }

    /// Puts the terminal back and replays everything logged. Idempotent, because it is reached both from
    /// the end of a run and from `atexit`.
    func tearDown() {
        // Nil where there is nothing to hand back — already torn down, or never begun — and the
        // transcript plus the timer where there is.
        let closing = state.withLock { state -> ([Line], DispatchSourceTimer?)? in
            let live = !state.tornDown && state.begun
            state.tornDown = true
            guard live else { return nil }
            let timer = state.timer
            state.timer = nil
            return (state.frame.transcript, timer)
        }
        guard let (recorded, timer) = closing else { return }

        timer?.cancel()
        Terminal.leaveFullScreen()
        if !recorded.isEmpty {
            // The transcript is what a run leaves behind, so the loud lines stay loud in it.
            let rendered = recorded.map { line in
                line.emphasis.ink.map { $0 + line.text + Self.reset } ?? line.text
            }
            Terminal.write(rendered.joined(separator: "\n") + "\n")
        }
        Display.onScreen.withLock { $0 = nil }
    }

    // MARK: - Feeding the frame

    /// Files a line in the transcript, or writes it out where there is not yet a transcript for it.
    private func log(_ text: String, emphasis: Emphasis) {
        let filed = state.withLock { state -> Bool in
            guard state.begun else { return false }
            state.frame.transcript.append((text, emphasis))
            return true
        }
        guard !filed else { return }
        // Nowhere to file it yet, so it belongs on the normal screen — exactly where a plain run would
        // have put it, and it stays there once the alternate screen is taken and given back.
        Terminal.write((emphasis.ink.map { $0 + text + Self.reset } ?? text) + "\n")
    }

    /// The current operation, and the two figures the bar is drawn from.
    private func activity(_ text: String, fraction: Double?, eta: String?) {
        state.withLock { state in
            state.frame.operation = text.trimmingCharacters(in: .whitespaces) + "…"
            state.frame.fraction = fraction
            state.frame.eta = eta
        }
    }

    private func noteResize() {
        state.withLock { $0.frame.resized = true }
    }

    // MARK: - Drawing

    /// Draws one frame, if there is a screen to draw it on.
    ///
    /// The write happens inside the lock, and that is load-bearing rather than lazy. `tearDown` takes
    /// the same lock to read the transcript, so holding it across the write is what stops a frame
    /// landing *after* the alternate screen has been given back — which would paint grid over the
    /// restored scrollback and the replayed transcript. Composing under the lock and writing outside
    /// it would shorten the critical section and reintroduce exactly that.
    private func render() {
        let map = currentMap
        state.withLock { state in
            guard state.begun, !state.tornDown, let map else { return }

            if state.frame.resized {
                state.frame.resized = false
                if let current = Terminal.size() { state.frame.size = current }
                state.frame.needsClear = true
            }

            guard state.frame.size.columns >= Self.minimumColumns,
                  state.frame.size.rows >= Self.minimumRows else {
                // Drawn once rather than every frame, so a small window is not also a busy one.
                if state.frame.needsClear {
                    state.frame.needsClear = false
                    Terminal.write("\u{1B}[2J\u{1B}[H\(state.frame.size.columns)x"
                        + "\(state.frame.size.rows) is too small for the map — "
                        + "\(Self.minimumColumns)x\(Self.minimumRows) is the least it needs.")
                }
                return
            }

            state.frame.frames += 1
            map.decay()
            map.resize(cellCount: (state.frame.size.columns - 2) * state.frame.gridRows)

            // Each row is positioned absolutely, cleared, and then written. Positioning rather than
            // newlines keeps the frame from ever scrolling, and the reset before the erase means the
            // erase does not paint the line with whatever colour the grid left behind.
            //
            // The erase has to come before the row and not after it. A row fills the window exactly, so
            // after writing its last character the cursor is still in the last column — it has nowhere
            // further to go — and erase-to-end-of-line then erases from the cursor inclusive, taking the
            // character just written with it. That deleted the right-hand border of every row.
            var frame = state.frame.needsClear ? "\u{1B}[2J" : ""
            state.frame.needsClear = false
            for (index, row) in state.frame.rows(map).enumerated() {
                frame += "\u{1B}[\(index + 1);1H\u{1B}[0m\u{1B}[K" + row + "\u{1B}[0m"
            }
            Terminal.write(frame)
        }
    }
}

// MARK: - Composing a frame

/// The drawing, as methods on the state it reads. Nothing here takes a lock or could: reaching a `Frame`
/// at all means being inside `withLock`, which is the property the old arrangement asked every one of
/// these to remember on its own behalf.
private extension Display.Frame {
    var logRows: Int { max(3, min(6, size.rows - 16)) }

    /// Everything the fixed furniture does not need: title, the key under the grid, phase bar,
    /// separator, two footer rows and the bottom border come to seven.
    var gridRows: Int { max(2, size.rows - logRows - 7) }

    func rows(_ map: BlockMap) -> [String] {
        let inner = size.columns - 2
        let edge = Display.frameInk + (unicode ? "│" : "|") + Display.reset
        var result: [String] = []

        result.append(rule(left: unicode ? "┌" : "+", right: unicode ? "┐" : "+",
                           label: " \(title()) "))

        let colours = map.colours()
        for row in 0 ..< gridRows {
            result.append(edge + gridRow(row, colours: colours, width: inner) + edge)
        }

        // The key belongs with the thing it explains, on the last row inside the map panel.
        result.append(edge + legendRow(width: inner) + edge)

        result.append(rule(left: unicode ? "├" : "+", right: unicode ? "┤" : "+",
                           label: " \(phaseName) ",
                           trailing: " \((frozenElapsed ?? started.duration(to: .now)).readable) "))

        // The tail of the log, bottom-aligned so a fresh line always appears in the same place.
        let recent = transcript.suffix(logRows)
        for _ in 0 ..< (logRows - recent.count) { result.append(edge + fit("", to: inner) + edge) }
        for line in recent {
            result.append(edge + (line.emphasis.ink ?? Display.logInk)
                + fit(" " + line.text, to: inner) + Display.reset + edge)
        }

        result.append(rule(left: unicode ? "├" : "+", right: unicode ? "┤" : "+"))
        result.append(edge + barRow(width: inner) + edge)
        let operationInk = succeeded ? (Emphasis.success.ink ?? Display.liveInk) : Display.liveInk
        result.append(edge + operationInk + fit("  " + operation, to: inner) + Display.reset + edge)
        result.append(rule(left: unicode ? "└" : "+", right: unicode ? "┘" : "+"))
        return result
    }

    func title() -> String {
        let separator = unicode ? " ─ " : " - "
        var parts = ["FATRABBIT"]
        if !volumeName.isEmpty { parts.append(volumeName) }
        parts.append(device)
        // Ahead of the geometry, since it is what the geometry has to be read in the light of, and
        // ahead of it in the truncation order a narrow window imposes for the same reason.
        if !flavour.isEmpty { parts.append(flavour) }
        parts.append(geometry)
        return parts.joined(separator: separator)
    }

    /// A horizontal rule with an optional label at each end. The label carries the weight, the line
    /// and the figure on the right stay out of the way.
    func rule(left: String, right: String, label: String = "", trailing: String = "") -> String {
        let inner = max(0, size.columns - 2)
        let dash = unicode ? "─" : "-"
        let head = String(label.prefix(inner))
        let tail = String(trailing.prefix(max(0, inner - head.count)))
        let gap = max(0, inner - head.count - tail.count)
        return Display.frameInk + left + Display.titleInk + head
            + Display.frameInk + String(repeating: dash, count: gap)
            + Display.quietInk + tail
            + Display.frameInk + right + Display.reset
    }

    /// One cell per character: a small square in the colour of what the cell holds, on a background
    /// that says whether it is being read or written.
    ///
    /// Two colours per cell rather than one, because the two facts are independent. When activity
    /// was drawn in the foreground it replaced the contents, so the busiest part of the map — the
    /// part actually worth watching — was the part that had stopped saying what was there.
    ///
    /// The small square is the same character the key uses, and one glyph per cell is the one thing
    /// a font cannot render inconsistently: the upper-half block tried before divides a cell at a
    /// boundary the font chooses, which landed at different heights on different rows.
    func gridRow(_ row: Int, colours: [BlockMap.CellColour], width: Int) -> String {
        let start = row * width
        guard start + width <= colours.count else { return fit("", to: width) }

        let square = unicode ? "▪" : "#"
        // A flush to the drive is one call that returns when it returns, so there is no progress to
        // show — but a region that sits perfectly still for several seconds reads as a hang. It is
        // alternated between two shades instead, slowly enough to look like waiting rather than
        // flickering.
        let pulse = Palette.flushing[(frames / 3) % 2]

        var out = ""
        var lastContent = -1
        var lastActivity = -2      // -1 means "no background", so the unset marker has to differ
        for column in 0 ..< width {
            let cell = colours[start + column]
            let content = Int(cell.content)
            var activity = cell.activity.map(Int.init) ?? -1
            if activity == Int(Palette.flushing[0]) { activity = Int(pulse) }
            if activity != lastActivity {
                out += activity < 0 ? "\u{1B}[49m" : "\u{1B}[48;5;\(activity)m"
                lastActivity = activity
            }
            if content != lastContent {
                out += "\u{1B}[38;5;\(content)m"
                lastContent = content
            }
            out += square
        }
        return out + "\u{1B}[0m"
    }

    func barRow(width: Int) -> String {
        // One line, vertically centred in the row, that fills with colour rather than growing in
        // height — the same glyph either side of the boundary, so nothing shifts as it advances and
        // the bar does not outweigh the grid it sits under.
        let filled = unicode ? "━" : "="
        let empty = unicode ? "━" : "-"

        var right = ""
        if let fraction {
            right = String(format: "%3.0f%%", min(max(fraction, 0), 1) * 100)
        }
        if let eta { right += right.isEmpty ? "  \(eta)" : "   \(eta)" }

        var span = max(8, width - right.count - 5)
        span = min(span, max(1, width - 4))
        var drawn = ""
        if let fraction {
            let lit = Int((min(max(fraction, 0), 1)) * Double(span))
            drawn = "\u{1B}[38;5;\(Palette.barFill)m" + String(repeating: filled, count: lit)
                + "\u{1B}[38;5;\(Palette.barEmpty)m" + String(repeating: empty, count: span - lit)
        } else {
            // Nothing to be a fraction of yet, so a sweep rather than a figure that would be made
            // up. Reflected off both ends, which reads as activity without implying progress.
            let block = min(6, span)
            let travel = max(1, span - block + 1)
            let step = frames % (travel * 2)
            let offset = step < travel ? step : travel * 2 - step - 1
            drawn = "\u{1B}[38;5;\(Palette.barEmpty)m" + String(repeating: empty, count: offset)
                + "\u{1B}[38;5;\(Palette.barFill)m" + String(repeating: filled, count: block)
                + "\u{1B}[38;5;\(Palette.barEmpty)m"
                + String(repeating: empty, count: span - block - offset)
        }

        let tail = max(0, width - span - 4)
        return " " + Display.frameInk + "[" + Display.reset + drawn + Display.reset
            + Display.frameInk + "]" + Display.reset + " "
            + Display.liveInk + fit(right, to: tail) + Display.reset
    }

    /// The key, centred under the grid it explains.
    ///
    /// The two kinds of colour are shown the way the map shows them: contents as circles, because
    /// they are drawn in the foreground, and activity as blocks of background, because that is what
    /// it is. Contents whose shade carries meaning get all three of their shades, dim to bright,
    /// which is the whole explanation of the gradient — a cell is brighter the fuller it is.
    ///
    /// Only the two categories are named. `collected`, `written` and `repointed` are deliberately
    /// absent, and that is not an omission to be tidied up later: each is a lighter member of the
    /// family of the activity it comes from, so the blue, yellow and purple squares on the right name
    /// them already, and the two ramps on the left teach the shading. Listing them said the same
    /// three things twice, in the row with the least space in the frame — and the entries it was
    /// crowding out were the ones the reader could not have worked out for themselves.
    ///
    /// The note sits between the two groups, where it doubles as the divider between what a cell
    /// holds and what is being done to it. It is still the first thing dropped when the window is
    /// too narrow, because it explains rather than identifies — so its position and its priority are
    /// decided separately, and activity colours are kept in preference to it.
    func legendRow(width: Int) -> String {
        let dot = unicode ? "●" : "*"
        let gap = 3

        struct Entry {
            let swatch: String
            let cells: Int
            let label: String
            /// The note has no swatch, so it also has no space to separate one from its label.
            var cost: Int { cells + (cells > 0 ? 1 : 0) + label.count }
            var text: String { swatch + (cells > 0 ? "\u{1B}[0m " : "") + label + "\u{1B}[0m" }
        }

        /// Generic over how many shades the ramp has, so the four content entries below can be a
        /// three-shade ramp or a single flat colour without either being padded to suit the other, and
        /// without the count travelling separately from the shades. `Free` and `Bad` really do have one
        /// shade each; the other two really do have three.
        func contents<let Shades: Int>(_ label: String, _ shades: [Shades of UInt8]) -> Entry {
            var swatch = ""
            for index in shades.indices { swatch += "\u{1B}[38;5;\(shades[index])m\(dot)" }
            return Entry(swatch: swatch, cells: Shades, label: label)
        }

        func activity(_ label: String, _ colour: UInt8) -> Entry {
            Entry(swatch: "\u{1B}[48;5;\(colour)m  ", cells: 2, label: label)
        }

        let held = [contents("In place", Palette.file),
                    contents("To move", Palette.displaced),
                    contents("Free", [Palette.free]),
                    contents("Bad", [Palette.bad])]
        let doing = [activity("Reading", Palette.reading),
                     activity("Writing", Palette.writing),
                     activity("Repointing", Palette.repointing),
                     activity("Clearing", Palette.clearing),
                     activity("Flushing", Palette.flushing[1])]
        let note = Entry(swatch: Display.quietInk, cells: 0, label: "(brighter = fuller)")

        func span(_ entries: [Entry]) -> Int {
            entries.reduce(0) { $0 + $1.cost } + max(0, entries.count - 1) * gap
        }

        // Contents drop as activity does, rather than being drawn whatever the room. They were
        // unconditional, which at the narrowest window this draws at over-ran the row by fifteen
        // characters — and one character too many is the fault that does not look like one: the
        // terminal wraps, every later row lands one low, and the frame drifts from there down.
        var shown: [Entry] = []
        for entry in held where span(shown + [entry]) <= width { shown.append(entry) }
        // Where the note goes, which is between the two groups and so has to be counted before the
        // second one is added — `held.count` is the wrong answer as soon as anything has been dropped.
        let contentsShown = shown.count
        for entry in doing where span(shown + [entry]) <= width { shown.append(entry) }
        if span(shown + [note]) <= width { shown.insert(note, at: contentsShown) }

        let used = span(shown)
        let leading = max(0, (width - used) / 2)
        return String(repeating: " ", count: leading)
            + shown.map(\.text).joined(separator: String(repeating: " ", count: gap))
            + String(repeating: " ", count: max(0, width - used - leading))
    }

    /// Truncates to `width` visible characters — with an ellipsis, so a cut line looks cut rather
    /// than merely odd — and pads out to it. Only ever given plain text: anything carrying escape
    /// sequences is measured by whatever built it.
    func fit(_ text: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        if text.count > width {
            return String(text.prefix(width - 1)) + (unicode ? "…" : ">")
        }
        return text + String(repeating: " ", count: width - text.count)
    }
}
