import Foundation
import Synchronization

/// What a cluster holds, as far as the map cares.
///
/// `displaced` is the interesting one: data that is not where the run intends to leave it, which is
/// what drains away as the work proceeds. Colouring by fragmentation instead was tried and is nearly
/// blind on the volumes this tool exists for — a file of one cluster cannot be in pieces, and a card
/// full of small files is scattered rather than fragmented, so the map showed almost nothing to fix
/// on a volume with everything to fix.
/// Directories are not distinguished from files. They were, and it earned nothing: a cell covers
/// tens or hundreds of clusters and takes the colour of whatever fills most of it, while directory
/// data is a couple of percent of a volume — 2.5% of one measured here — and the layout packs each
/// directory in among its own files rather than gathering them. So a cell held one directory cluster
/// among thirty and the colour never won a single cell in a whole run. No threshold fixes that: high
/// enough to mean anything and it never fires, low enough to fire and it paints the entire map.
enum ClusterState: UInt8, CaseIterable {
    case free = 0
    case file = 1
    case displaced = 2
    /// Read, and its copy is elsewhere, but the volume still points here and will until the commit
    /// flips the pointers and releases it. Both copies genuinely exist for that stretch, which on a
    /// slow medium is most of a generation, and this is the half that is about to stop being used.
    case collected = 3
    /// The other half: written, correct, and named by nothing. Until the commit flips the pointers
    /// this data is not the live copy, and an interruption here leaves it as an orphan for the next
    /// run to reclaim. The two states bracket the same window from either end, and the commit is
    /// what turns one into the live copy and the other into free space.
    case written = 4
    case bad = 5
    /// A directory block whose pointers a repoint pass has flipped, drawn until the pass it belongs
    /// to is over. What `written` is to a copy, this is to the flip that makes that copy the live one:
    /// the moment where the change is on the medium and the run has not yet finished making it so.
    ///
    /// Marked on the way out and not on the way in, which is the half that is true. The gather sweep
    /// reads a block and patches it in memory, and the medium is untouched by that — claiming
    /// otherwise would colour a volume for something that had not happened. The write sweep is where
    /// the block changes.
    ///
    /// Unlike `collected` and `written` it is not a state anything settles into — the block was
    /// ordinary directory data before and is ordinary directory data after — so nothing ever announces
    /// what it becomes. The map puts back what it found; see `BlockMap.taint`.
    case repointed = 6
    /// Live data, in a place the run never meant it to be. A stalled generation parks whatever is in
    /// the way in spare space so that something else can take its slot, and the copy is committed like
    /// any other — the volume points at it, it is the only copy, and it is exactly as safe. It simply
    /// has another move still to come.
    ///
    /// `displaced` before now, which is true as far as it goes: both mean the data is not where the
    /// run intends to leave it. But `displaced` is where the volume *found* the data, and this is
    /// somewhere the run put it on purpose and intends to take it away from again, which is the one
    /// thing on the map that is the tool's own doing rather than the volume's. Told apart, a stall
    /// reads as what it is; together, the map shows work appearing in the middle of spare space with
    /// nothing to say where it came from.
    case staged = 7

    /// How many kinds there are, which is the stride of the per-cell tallies. Derived from the cases
    /// rather than written down beside them, so adding a state cannot silently leave every cell's
    /// tally one slot short.
    static let count = allCases.count

    /// The volume as the FAT alone describes it: what is in use, and what is unusable.
    ///
    /// Everything in use starts as plain file data, because before the scan there is nothing else it
    /// could honestly be said to be. What each cluster actually holds, and which of it the run intends
    /// to shift, arrive later as the tree is walked and the schedule is settled.
    ///
    /// - Parameter badMarker: the entry value meaning "the medium failed here", which differs by
    ///   variant. Passed in rather than reached for, because this is a static with no volume in
    ///   scope and the alternative is a global that would be right for one variant out of three.
    static func layout(of fat: [UInt32], clusterCount: UInt32,
                       badMarker: UInt32) -> [ClusterState] {
        var states = [ClusterState](repeating: .free, count: Int(clusterCount))
        for index in 0 ..< states.count {
            let cluster = index + 2
            guard cluster < fat.count else { break }
            let entry = fat[cluster]
            states[index] = entry == 0 ? .free : (entry == badMarker ? .bad : .file)
        }
        return states
    }
}

/// Colour indices from the 256-colour palette rather than 24-bit, which costs nothing here and is
/// understood by every terminal worth drawing on. Three shades per category, picked by how full a
/// cell is, so the grid has texture rather than flat bands of colour.
///
/// Contents are drawn as a small square in the foreground, so the dim end of each hue is lifted:
/// a shade that reads as a tint when it fills a whole cell disappears when it is a small glyph.
///
/// Reading and writing are backgrounds rather than foregrounds, which is what lets a cell say what
/// it holds and what is happening to it at the same time — before, activity replaced the contents
/// and the busiest part of the map was the part that stopped telling you anything.
/// The shade ramps are `InlineArray`s, because three is part of what a ramp *is* here rather than a
/// runtime fact: `colour(of:)` picks one of exactly three by how full a cell is, and the legend draws
/// exactly three swatches. Written as `[3 of UInt8]` the count is in the type, the compiler checks the
/// literal against it, and the bytes sit in the constant itself instead of behind a heap allocation
/// and a reference count that never changes.
enum Palette {
    static let free: UInt8 = 238
    static let file: [3 of UInt8] = [28, 34, 46]
    static let displaced: [3 of UInt8] = [130, 172, 214]
    /// The same blue family as reading, since that is what it means, but lighter — a cell that has
    /// just been read is drawn on the reading background for the half second the trail lasts, and
    /// the same blue twice over is one blue rectangle.
    static let collected: [3 of UInt8] = [25, 32, 39]
    /// As collected is to reading, this is to writing: the same family, lighter, so that a cell
    /// drawn on the writing background while the trail lasts is still two colours and not one.
    ///
    /// A shallow ramp, and never redder than it is green. It started at #5f5f00, which is a muddy
    /// dark olive and sits right beside the darkest of the oranges above — the same green channel,
    /// both dim, and at the size of one character they read as the same thing. Keeping green at or
    /// above red means it cannot drift towards orange however dark it gets, and starting high means
    /// it does not get dark.
    static let written: [3 of UInt8] = [148, 184, 226]
    /// As collected is to reading, this is to repointing: the same family, lighter, so a block drawn
    /// on the repointing background while its write is in flight is still two colours and not one.
    static let repointed: [3 of UInt8] = [133, 170, 213]
    /// Grey, because parked data is the one thing on the map that is passing through: every other hue
    /// names something the volume holds, and this names somewhere the run is borrowing.
    ///
    /// Grey is also what free space is drawn in, which is the whole difficulty — staging takes its
    /// room from just above the layout, so this colour appears among free cells by definition and had
    /// to be told apart from them there or it would be invisible exactly where it happens. Hence the
    /// light half of the ramp against free's 238, which is near black: the dimmest of these is still
    /// twice its brightness. It stays above the two flushing shades for the same reason the lighter
    /// families above do — a grey square on a grey background is one grey rectangle.
    ///
    /// A shallow ramp, and deliberately so. The shade says how much of a cell is parked, but a cell
    /// with any parked data in it is worth seeing whatever the proportion, so the dim end is a shade
    /// rather than a hiding place. In practice the dim end is the common one: staging borrows spare
    /// room from just above the layout, and on a volume full enough to stall at all that room is
    /// single clusters between files rather than an empty stretch.
    ///
    /// Which is also why none of the three is one of the greys `Display` writes text in. They were,
    /// and the dimmest was the frame's own ink: harmless on screen, since a border is a line and a
    /// cell is a square, but it made the colour census in `screenshot.py` unable to tell a parked
    /// cell from a length of box — and the census is the one tool that can find a state drawn in a
    /// handful of frames out of hundreds.
    static let staged: [3 of UInt8] = [249, 251, 254]
    static let bad: UInt8 = 196
    static let reading: UInt8 = 27
    /// Yellow rather than white: white is what a terminal uses for text, so a write trail in it read
    /// as something written *on* the map rather than as part of it. Softened from a pure yellow,
    /// which as a background was brighter than anything it sat behind and buried the contents it is
    /// supposed to sit behind — the point of putting activity in the background is that the square
    /// in front of it stays readable.
    static let writing: UInt8 = 142
    /// Bookkeeping rather than payload: the pointer flips that make a copy the live one, and the
    /// releases that give the originals back. They are writes, but they are a different phase of the
    /// work and take a different part of the run's time, so they get their own colours.
    static let repointing: UInt8 = 127
    static let clearing: UInt8 = 88
    /// Waiting on the drive to make what has been handed to it durable. Two shades, alternated by
    /// the display, because this is the one phase with no progress to report — it is a single call
    /// that returns when the drive says so — and a still picture during it looks like a hang.
    static let flushing: [2 of UInt8] = [239, 245]
    static let barFill: UInt8 = 40
    static let barEmpty: UInt8 = 238

    static func colour(of activity: CellActivity) -> UInt8? {
        switch activity {
        case .none: return nil
        case .reading: return reading
        case .writing: return writing
        case .repointing: return repointing
        case .clearing: return clearing
        case .flushing: return flushing[0]
        }
    }
}

/// What is being done to a cell right now, drawn as a background behind its contents.
enum CellActivity: UInt8 {
    case none = 0
    case reading
    case writing
    case repointing
    case clearing
    case flushing
}

/// The volume as a grid: what every cluster holds, aggregated into as many cells as the window has
/// room for, plus a fading trail behind whatever is being read and written.
///
/// The shape of this is decided by one requirement — drawing a frame must not get in the run's way.
/// A card holds two million clusters and a window holds a few thousand cells, so summing the
/// clusters per cell on every frame would mean either doing that work while holding a lock the run
/// needs, or reading arrays the run is mutating. Instead the per-cell tallies are maintained as
/// marks arrive: a move of n clusters costs 2n counter updates, which is nothing beside copying the
/// data, and a frame is then proportional to the cells on screen. The full sum only happens when
/// the window is resized and the cells all change meaning.
/// `Sendable` outright, and with no lock of its own to remember.
///
/// Everything mutable lives in `Storage` behind one `Mutex`, which is the whole change: before, five
/// mutable properties sat beside an `NSLock`, and the connection between them was carried by a naming
/// convention — every private method suffixed `Locked` to record that its caller had already taken the
/// lock, and every public method opening with `lock.lock()` and a matching `defer`. That works exactly
/// as long as everybody remembers. Behind a `Mutex` the state is unreachable except through
/// `withLock`, so a method that forgets fails to compile rather than racing, and the suffix has
/// nothing left to record.
final class BlockMap: Sendable {
    /// Everything the map keeps, gathered so that the lock and what it covers are one declaration.
    ///
    /// The cell arithmetic lives here too rather than on the class, because it reads both counts and
    /// there is then no way to ask it a question without holding the lock.
    private struct Storage {
        /// One `ClusterState` byte per data cluster, indexed from cluster 2. Authoritative: the
        /// tallies are derived from this, never the other way round.
        var state: [UInt8]
        let clusterCount: Int

        /// Per cell, one count per state, flattened.
        var counts: [UInt32] = []
        /// The same tallies for the volume as a whole, so a question about all of it — is there any
        /// of this on the volume at all? — is answered without summing a few thousand cells. Kept
        /// alongside `counts` rather than derived from it because it survives a resize unchanged:
        /// how the clusters are grouped has nothing to do with what they hold.
        var totals: [UInt32] = []
        /// What each cell is busy with, and how many frames of flash it has left. One pair rather than
        /// an array per kind: a cell is doing one thing at a time, and the latest touch is the
        /// interesting one — a destination being written was read from somewhere else, not here.
        var activity: [UInt8] = []
        var heat: [UInt8] = []
        /// The cells lit for the operation currently in flight, so that handing over to the next one
        /// costs a walk of those cells rather than a sweep of the whole grid. That distinction is
        /// worth a list: this happens twice per transfer and tens of thousands of times a run, while
        /// the grid is a few thousand cells wide.
        var inFlight: [Int] = []
        /// Clusters showing a state that is not their own: what they held, and how many frames are
        /// left before they get it back. `held` there means the taint is standing rather than
        /// counting down, exactly as it does for `heat`.
        ///
        /// Every other state on the map is announced: the commit says what a cluster became, and the
        /// map is only asked to believe it. A repoint taint has nobody to announce its end, because
        /// there is no end to announce — a directory block is ordinary directory data before the sweep
        /// reads it and ordinary directory data after the sweep writes it, and the interesting part is
        /// only the gap in between. So the map remembers what to put back rather than making the
        /// engine describe an unchanged cluster twice.
        ///
        /// Empty for all but a few moments of a run, which is what makes the check in `set` free.
        var tainted: [UInt32: (held: UInt8, frames: UInt8)] = [:]
        var cellCount: Int

        init(clusterCount: Int, cellCount: Int) {
            self.clusterCount = clusterCount
            self.cellCount = cellCount
            state = [UInt8](repeating: ClusterState.free.rawValue, count: clusterCount)
            totals = [UInt32](repeating: 0, count: ClusterState.count)
            totals[Int(ClusterState.free.rawValue)] = UInt32(clusterCount)
            rebuild()
        }

        mutating func rebuild() {
            counts = [UInt32](repeating: 0, count: cellCount * ClusterState.count)
            activity = [UInt8](repeating: CellActivity.none.rawValue, count: cellCount)
            heat = [UInt8](repeating: 0, count: cellCount)
            // Dropped rather than remapped, and it has to be dropped rather than merely stale: after a
            // resize these indices name cells that may no longer exist.
            inFlight.removeAll(keepingCapacity: true)
            for index in 0 ..< clusterCount {
                counts[cell(ofIndex: index) * ClusterState.count + Int(state[index])] += 1
            }
        }

        mutating func assign(_ cluster: UInt32, _ newState: ClusterState) {
            guard let index = index(ofCluster: cluster) else { return }
            let old = state[index]
            guard old != newState.rawValue else { return }
            state[index] = newState.rawValue
            let base = cell(ofIndex: index) * ClusterState.count
            counts[base + Int(old)] -= 1
            counts[base + Int(newState.rawValue)] += 1
            totals[Int(old)] -= 1
            totals[Int(newState.rawValue)] += 1
        }

        /// Lights the cell holding `cluster` for as long as the operation lasts.
        mutating func light(_ cluster: UInt32, _ kind: CellActivity) {
            guard let index = index(ofCluster: cluster) else { return }
            let target = cell(ofIndex: index)
            activity[target] = kind.rawValue
            heat[target] = BlockMap.held
            // Clusters arrive in ascending order and a cell covers a great many of them, so comparing
            // against the last one collapses a transfer of hundreds of clusters into the handful of
            // cells it actually lights. Anything that slips through is a repeated assignment later,
            // which is harmless — this is a coalescer, not an invariant.
            if inFlight.last != target { inFlight.append(target) }
        }

        /// Shows `cluster` as `newState`, remembering what it held so it can be given back.
        mutating func taint(_ cluster: UInt32, _ newState: ClusterState) {
            guard let index = index(ofCluster: cluster) else { return }
            // First taint wins, so a block reported twice in one sweep is not recorded as having held
            // the taint before it held anything. A re-taint also stops any countdown under way.
            tainted[cluster] = (tainted[cluster]?.held ?? state[index], BlockMap.held)
            assign(cluster, newState)
        }

        /// Starts `cluster` on its way back to what it held, over the same few frames a trail lasts.
        ///
        /// Not an immediate restore, and the difference is the whole visibility of the thing. A
        /// repoint pass on a warm cache is tens of milliseconds — less than one frame — so a taint
        /// taken off at the instant the write returns is put back before anything is ever drawn, and
        /// all that survives to be seen is the activity trail sitting over unchanged contents. Fading
        /// it on the same schedule as that trail is what "cleared once the write has settled" has to
        /// mean if it is to mean anything on a medium faster than the eye.
        ///
        /// Silent about clusters that were never tainted, which costs nothing and saves the caller
        /// from tracking which of them it marked.
        mutating func untaint(_ cluster: UInt32) {
            guard let entry = tainted[cluster], entry.frames == BlockMap.held else { return }
            tainted[cluster] = (entry.held, BlockMap.heatFrames)
        }

        /// Starts every standing taint fading at once, which is what the end of a pass looks like:
        /// the marks put down as it swept the volume all give way together.
        mutating func untaintAll() {
            for cluster in tainted.keys where tainted[cluster]?.frames == BlockMap.held {
                untaint(cluster)
            }
        }

        /// Ages every fading taint by a frame, giving back what was held when it runs out.
        mutating func fadeTaints() {
            guard !tainted.isEmpty else { return }
            var finished: [UInt32] = []
            for (cluster, entry) in tainted where entry.frames != BlockMap.held {
                if entry.frames > 1 {
                    tainted[cluster] = (entry.held, entry.frames - 1)
                    continue
                }
                if let held = ClusterState(rawValue: entry.held) { assign(cluster, held) }
                finished.append(cluster)
            }
            for cluster in finished { tainted.removeValue(forKey: cluster) }
        }

        /// Turns whatever is in flight into an ordinary fading trail.
        mutating func fade() {
            for target in inFlight where heat[target] == BlockMap.held {
                heat[target] = BlockMap.heatFrames
            }
            inFlight.removeAll(keepingCapacity: true)
        }

        func index(ofCluster cluster: UInt32) -> Int? {
            let index = Int(cluster) - 2
            guard index >= 0, index < clusterCount else { return nil }
            return index
        }

        func cell(ofIndex index: Int) -> Int {
            guard clusterCount > 0 else { return 0 }
            return Int(UInt64(index) * UInt64(cellCount) / UInt64(clusterCount))
        }

        /// The contents of a cell alone. Activity is a background and is decided in `colours`.
        func colour(_ index: Int) -> UInt8 {
            let base = index * ClusterState.count
            // A bad cluster anywhere in the cell wins outright: there are usually none, and where
            // there are any they are the most interesting thing on the volume.
            if counts[base + Int(ClusterState.bad.rawValue)] > 0 { return Palette.bad }

            let free = counts[base + Int(ClusterState.free.rawValue)]
            let file = counts[base + Int(ClusterState.file.rawValue)]
            let displaced = counts[base + Int(ClusterState.displaced.rawValue)]
            let collected = counts[base + Int(ClusterState.collected.rawValue)]
            let written = counts[base + Int(ClusterState.written.rawValue)]
            let repointed = counts[base + Int(ClusterState.repointed.rawValue)]
            let staged = counts[base + Int(ClusterState.staged.rawValue)]
            let used = file + displaced + collected + written + repointed + staged
            guard used > 0 else { return Palette.free }

            // Brightness by how full the cell is, hue by what dominates it — except that work still
            // to do is given more than its share, because a cell a quarter unfinished is not finished.
            let capacity = used + free
            let shade = used * 4 >= capacity * 3 ? 2 : (used * 4 >= capacity ? 1 : 0)

            // Gathered is the sparsest thing the map ever draws — a repoint pass touches one directory
            // cluster in a cell of a hundred — so it takes the hue on presence alone, which is the rule
            // collected already follows and for the same reason. It can afford to win outright over
            // the two below it because it is also the briefest: one sweep of one commit, and the block
            // is back to being ordinary directory data.
            if repointed > 0 { return Palette.repointed[shade] }

            // Collected is a stage rather than a category, so it is judged differently. A generation
            // reads about a tenth of the clusters in play, which in a cell covering tens or hundreds
            // of them never approaches a majority — asking it to dominate meant it appeared in under
            // 2% of cells and the picking-up was invisible. It takes the hue as soon as any of the
            // cell has been collected, and the shade then says how much of the cell's outstanding
            // work that is. Both halves of a copy in flight are stages rather than categories, and
            // are read the same way: the hue as soon as any of the cell is at that stage, the shade
            // for how much of it.
            if written > 0 {
                return Palette.written[min(Int(written * 3 / max(written + file, 1)), 2)]
            }
            let moving = displaced + collected
            if collected > 0 {
                return Palette.collected[min(Int(collected * 3 / max(moving, 1)), 2)]
            }
            // Read on presence, like the stages above it, and for the same arithmetic reason rather
            // than because it is one: staging is capped at a couple of hundred objects of a few
            // clusters each, so in a cell covering tens or hundreds of clusters it is never a
            // majority of anything and asking it to dominate would mean it never appeared. It is
            // also the only colour that says the run put data somewhere it means to take it away
            // from again, which is worth more than the difference between the two hues it covers —
            // both of which mean "not final", so nothing about the outstanding work is lost by
            // showing this instead.
            if staged > 0 { return Palette.staged[min(Int(staged * 3 / used), 2)] }
            if displaced * 4 >= used { return Palette.displaced[shade] }
            return Palette.file[shade]
        }
    }

    private let storage: Mutex<Storage>

    /// How long the trail behind a finished operation lasts. Four frames at eight a second is half a
    /// second, which is long enough to follow and short enough to keep up with a fast medium. It says
    /// nothing about how long the operation itself took — that is `held`, which is what an operation
    /// in flight is marked with.
    private static let heatFrames: UInt8 = 4
    /// Lit until told otherwise, rather than for a count of frames.
    private static let held = UInt8.max

    init(clusterCount: UInt32, cellCount: Int = 1) {
        storage = Mutex(Storage(clusterCount: Int(clusterCount), cellCount: max(1, cellCount)))
    }

    // MARK: - Marking

    /// The volume as it arrived, all of it at once: one state per data cluster, indexed from cluster 2.
    ///
    /// Set wholesale rather than cluster by cluster, because that is the shape it arrives in — the
    /// starting layout is one fact about the volume, not a hundred thousand separate changes. Anything
    /// shorter than the volume leaves the rest as it was, which is free.
    func replace(_ states: [ClusterState]) {
        storage.withLock { storage in
            for index in 0 ..< min(storage.clusterCount, states.count) {
                storage.assign(UInt32(index + 2), states[index])
            }
        }
    }

    /// Any sequence of cluster numbers, rather than an array of them.
    ///
    /// The three marking calls below are what the engine's busiest events turn into, and the caller
    /// almost always has a range in hand: a transfer already carries its first cluster and how many it
    /// covered, so building an array of that range only to walk it once was work to no end. Generic,
    /// so a `Range`, a `ClusterSet` and a plain array all arrive without anyone converting anything.
    func set(_ clusters: some Sequence<UInt32>, to newState: ClusterState) {
        storage.withLock { storage in
            for cluster in clusters {
                // The engine has said something new, so anything stashed for this cluster describes a
                // volume that no longer exists and a later restore would put back a lie. Guarded on
                // the dictionary being empty, which it is for all but a few moments of a run.
                if !storage.tainted.isEmpty { storage.tainted.removeValue(forKey: cluster) }
                storage.assign(cluster, newState)
            }
        }
    }

    /// Shows `clusters` as `newState` until `restore` gives them back what they held.
    ///
    /// For a stage that nothing settles into. A data copy is bracketed by `collected` and `written`,
    /// and each end is announced by the commit that makes it true; a pointer flip has the same two
    /// ends and no such announcement, because the block is unremarkable directory data on both sides
    /// of it. What is worth drawing is only the gap between the sweep reading a block and the sweep
    /// writing it back — the stretch where the medium still names the old location.
    func taint(_ clusters: some Sequence<UInt32>, _ newState: ClusterState) {
        storage.withLock { storage in
            for cluster in clusters { storage.taint(cluster, newState) }
        }
    }

    /// Starts everything currently marked fading back to what it held, over the same few frames as an
    /// activity trail. What the end of a pass looks like: the marks it left all give way together.
    func untaintAll() {
        storage.withLock { $0.untaintAll() }
    }

    /// Lights the cells holding `clusters` with what is being done to them, and keeps them lit for as
    /// long as it takes — until `settle`, or until the next operation takes the light.
    ///
    /// Held rather than flashed for a fixed count of frames, and the difference is the whole of what a
    /// slow medium needs from this. A fixed trail is a claim about how long an operation takes: at
    /// four frames it says half a second, which was true of everything measured against an image and
    /// is not true of a card with a slow region, where one write runs to a second or more. The trail
    /// then expires while the drive is still working, so the cell that was lit goes quiet and the next
    /// one has not started — the map sits still in the middle of the very operation it exists to show,
    /// which is indistinguishable from a tool that has stopped.
    ///
    /// Taking over is unconditional, and can be, because only one thing is ever in flight: the engine
    /// reaches the medium from one thread through one call, so anything still lit is by definition
    /// finished, and it begins fading as this is lit. That is a backstop rather than the mechanism —
    /// every operation reports its own end, and this should find nothing to hand over from. It is kept
    /// because the alternative to a backstop here is a cell lit for the rest of the run.
    func begin(_ clusters: some Sequence<UInt32>, _ kind: CellActivity) {
        storage.withLock { storage in
            storage.fade()
            for cluster in clusters { storage.light(cluster, kind) }
        }
    }

    /// The medium has answered, so what was in flight becomes a fading trail rather than going dark.
    func settle() {
        storage.withLock { $0.fade() }
    }

    // MARK: - Drawing

    /// Ages every trail by one frame. Called once per frame by whatever is drawing.
    func decay() {
        storage.withLock { storage in
            for index in 0 ..< storage.cellCount
            where storage.heat[index] > 0 && storage.heat[index] != Self.held {
                storage.heat[index] -= 1
                if storage.heat[index] == 0 {
                    storage.activity[index] = CellActivity.none.rawValue
                }
            }
            storage.fadeTaints()
        }
    }

    /// What a cell is holding, and what is being done to it — the two are independent, so both are
    /// reported and the display draws one over the other.
    struct CellColour {
        /// The contents, as a foreground colour.
        let content: UInt8
        /// What is being done to it, as a background colour. Nil where the cell is quiet.
        let activity: UInt8?
    }

    /// One entry per cell, in cluster order.
    func colours() -> [CellColour] {
        storage.withLock { storage in
            var result = [CellColour](repeating: CellColour(content: Palette.free, activity: nil),
                                      count: storage.cellCount)
            for index in 0 ..< storage.cellCount {
                let kind = storage.heat[index] > 0
                    ? (CellActivity(rawValue: storage.activity[index]) ?? .none)
                    : .none
                result[index] = CellColour(content: storage.colour(index),
                                           activity: Palette.colour(of: kind))
            }
            return result
        }
    }

    /// Whether any of the volume is in `state` at present.
    ///
    /// For the key, which has less room than anything else in the frame: a colour that is on the map
    /// needs explaining, and one that is not is a line of explanation crowding out the entries that
    /// identify something. Only `staged` asks — the rest are either always present or, like `bad`,
    /// worth naming precisely because they are usually absent.
    func holds(_ state: ClusterState) -> Bool {
        storage.withLock { $0.totals[Int(state.rawValue)] > 0 }
    }

    /// Re-aggregates into a different number of cells, which is what a resized window needs. The
    /// trails are dropped rather than remapped — they are half a second of decoration.
    func resize(cellCount newCount: Int) {
        storage.withLock { storage in
            guard newCount > 0, newCount != storage.cellCount else { return }
            storage.cellCount = newCount
            storage.rebuild()
        }
    }
}
