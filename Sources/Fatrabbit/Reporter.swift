import Foundation

/// The engine's side of the stream: the figures it keeps about itself, and the way it says anything.
///
/// One value passed around rather than a counter per type. The engine has no idea which figures anyone
/// cares about, so it keeps all of them and sends the set whole; that only works if there is one set,
/// and this is it. What used to be twenty log lines composed at twenty moments is now one struct that
/// changes over time, and every decision about when to mention it lives on the far side of the stream.
///
/// Not thread-safe, and does not need to be: everything that touches the telemetry runs on the thread
/// doing the work. The interrupt handler is the one thing that reports from elsewhere, and it is handed
/// the stream directly — it posts two events and touches no figures.
final class Reporter {
    private let stream: EventStream

    /// The whole set as it stands. Read as well as written, because a figure is often derived from the
    /// ones already counted.
    private(set) var telemetry = RunEvent.Telemetry()

    init(_ stream: EventStream) {
        self.stream = stream
    }

    /// Says something happened.
    func post(_ event: RunEvent) {
        stream.post(event)
    }

    /// Changes one or more figures and sends the set.
    ///
    /// Sent on every change rather than at moments the engine judges interesting, because judging that
    /// is exactly what the engine must not do. Coalescing in the consumer is what makes it affordable:
    /// a hundred of these between two frames become one frame's worth of work.
    func update(_ change: (inout RunEvent.Telemetry) -> Void) {
        change(&telemetry)
        stream.post(.telemetry(telemetry))
    }

    /// Names the stage of the run.
    func phase(_ phase: RunEvent.Phase) {
        stream.post(.phase(phase))
    }

    /// Times `body` and adds what it took to one of the figures, which is how the run can say where its
    /// time actually went. The answer is not obvious and changes completely with the medium: the copies
    /// dominate on anything fast, while on a spinning drive the two flushes per generation can cost more
    /// than the data movement they protect.
    ///
    /// Typed rather than `rethrows`, so the engine's one error domain survives the trip through here.
    /// `rethrows` promises only "throws if the closure does", which arrives at the call site as
    /// `any Error` and would force `commitPending` — and then everything above it — back off
    /// `throws(FATError)`. Naming the type is what keeps the single `catch` in `main` provable.
    ///
    /// Callers have to write `{ () throws(FATError) in … }` rather than just `{ … }`, which is worth
    /// knowing before wondering whether they need to: a closure literal's throw type is not inferred
    /// from its body, so an unannotated one is `throws` and will not convert to this. Concrete rather
    /// than generic over the closure's error for that reason — the generic form compiles and is the
    /// more reusable signature, but it needs the same annotation at every call site and then says
    /// nothing this does not.
    func timing<T>(_ figure: WritableKeyPath<RunEvent.Telemetry, Duration>,
                   _ body: () throws(FATError) -> T) throws(FATError) -> T {
        let started = ContinuousClock.now
        defer {
            let taken = started.duration(to: .now)
            update { $0[keyPath: figure] += taken }
        }
        return try body()
    }
}
