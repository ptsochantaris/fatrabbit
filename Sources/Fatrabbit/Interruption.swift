import Foundation
import Synchronization

/// Tidy handling of Ctrl-C.
///
/// The engine is already safe to lose at any instant — that is the whole point of copying before
/// repointing, and an interruption costs at most some unreferenced clusters, which the next run
/// reclaims. So this is not about safety. It is about where a run stops: rather than vanishing
/// mid-batch with the volume still flagged as being modified and a free-cluster tally that no
/// longer matches the FAT, the request is noted, the batch in flight is committed, the boot
/// record and FSInfo are brought up to date and the flag is cleared. What is left behind is a
/// consistent, partly defragmented volume that a later run carries on from, and an `fsck` that
/// has nothing to say about it.
///
/// Nothing here is Darwin-specific: SIGINT and Dispatch signal sources both exist on Linux.
enum Interruption {
    /// Written by the signal source's thread, read by the thread doing the work.
    ///
    /// An `Atomic`, which is what this was always describing. It was a `sig_atomic_t` behind
    /// `nonisolated(unsafe)`, with a comment explaining that a naturally aligned word can be handed
    /// between threads without a lock — a correct argument, made by hand, that the compiler had to be
    /// told to stop checking. `Atomic` makes the same guarantee something the type system knows: the
    /// unsafe opt-out goes, the ordering is stated rather than assumed, and it is a plain `Bool`
    /// again because nothing about the word size was ever the point.
    ///
    /// Relaxed ordering is enough, and deliberately so. This flag guards nothing — it is read at the
    /// top of long loops, and the answer being one iteration stale is the same as the signal having
    /// arrived a moment later. Every ordering guarantee the run actually depends on comes from the
    /// durability barriers.
    private static let flag = Atomic<Bool>(false)

    /// Held only so the source outlives `listen`; a released source stops delivering. Written once,
    /// from `listen`, and never read — a mutex rather than an unsafe opt-out because "assigned once
    /// and only ever kept alive" is not something a reader of the declaration can otherwise check.
    private static let source = Mutex<DispatchSourceSignal?>(nil)

    /// Whether a stop has been asked for. Long loops check this and stop at their next safe point,
    /// which is between moves rather than during one.
    static var requested: Bool { flag.load(ordering: .relaxed) }

    /// Starts listening for SIGINT.
    ///
    /// Delivery goes through a Dispatch source rather than a `signal` handler, so what runs below
    /// is ordinary code instead of the short list of calls that are safe inside a real handler,
    /// and the thread doing the writing is never interrupted part way through one.
    ///
    /// - Parameter stopNow: what to do about a second press. It has to leave — the point of asking
    ///   twice is not to wait — but it must not simply call `exit`: the acknowledgement posted just
    ///   above is on its way to another task, and leaving before that has landed means the run
    ///   vanishes without ever saying why. Whoever supplies this drains the stream first.
    static func listen(stream: EventStream, stopNow: @escaping @Sendable () -> Never) {
        // The source decides what happens, so the default action — which is to die on the spot —
        // has to be out of the way first.
        signal(SIGINT, SIG_IGN)

        // Assembled inside the lock; see the note in Terminal.onResize for why.
        source.withLock { stored in
            let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            signalSource.setEventHandler {
            if requested {
                // Asked twice. Losing a run outright is what a power cut does, and the volume
                // survives that, so there is no case for arguing about it.
                stream.post(.interrupted(immediate: true))
                stopNow()
            }
            flag.store(true, ordering: .relaxed)
            stream.post(.interrupted(immediate: false))
        }
            signalSource.resume()
            stored = signalSource
        }
    }
}
