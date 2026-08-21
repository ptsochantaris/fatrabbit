import Foundation
import Synchronization

/// Carries events from the engine to whoever is displaying them, in batches.
///
/// Two properties matter, and they pull in opposite directions.
///
/// **Posting must never suspend.** The engine calls it from inside the scan and the copy loop, over a
/// hundred thousand times a run, on a thread that is otherwise busy with the medium. An `await` there —
/// or a lock held across anything a consumer does — is the coupling this type exists to remove. `post`
/// takes one uncontended lock, appends, and returns.
///
/// **Consuming must arrive in batches.** A renderer draws a few times a second; between two frames
/// thousands of events accumulate, and waking once per event to do a frame's worth of work is the same
/// mistake in a different place. A consumer is handed everything posted since the last time it looked,
/// in one array, however many that turned out to be.
///
/// It was an `AsyncStream` with an unbounded buffer first, and that is worth recording because it looked
/// obviously right and was not. A stream hands over one element per `await`, so a producer in a tight
/// loop and a consumer awaiting element by element contend on the stream's own lock for every single
/// event — and a scan over an image, where the engine is not waiting for anything, went from 279ms to
/// 4.2s. Swapping the whole backlog out under one lock is the fix: the batch boundary falls out of "what
/// is here now" rather than out of a count of what is outstanding, and the consumer suspends once per
/// batch instead of once per event.
final class EventStream: Sendable {
    private struct State {
        var pending: [RunEvent] = []
        /// A consumer parked because there was nothing to give it.
        var waiter: CheckedContinuation<Void, Never>?
        var closed = false
    }

    /// Unbounded, which is safe because applying an event is a few array operations while drawing is
    /// what costs: the consumer drains far faster than the engine can produce, so the backlog stays
    /// short even though nothing bounds it.
    private let state = Mutex(State())

    /// Records an event. Callable from any thread, never suspends, never blocks on a consumer.
    func post(_ event: RunEvent) {
        let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.closed else { return nil }
            state.pending.append(event)
            let waiting = state.waiter
            state.waiter = nil
            return waiting
        }
        // Outside the lock: resuming a task must not happen holding a lock the resumed task will want.
        waiting?.resume()
    }

    /// Starts `consumer` on its own task, and hands back the thing that waits for it.
    ///
    /// The consumer is handed over outright rather than shared, which is why it needs no locks of its
    /// own however much mutable state it keeps — a transcript, a running tally, a frame. It displays;
    /// nothing comes back. That is also what makes the single-consumer rule structural: the loop below
    /// is the only thing that ever takes the backlog, and there is one of it.
    func start(_ consumer: sending any EventConsumer) -> Drain {
        let drain = Drain(self)
        Task.detached { [self] in
            while true {
                let batch = await nextBatch()
                if batch.isEmpty { break }
                await consumer.apply(batch)
            }
            await consumer.finish()
            drain.consumerReturned()
        }
        return drain
    }

    /// Everything posted since the last time, waiting if there is nothing yet. Empty means the run is
    /// over and drained, and only then.
    private func nextBatch() async -> [RunEvent] {
        while true {
            // Swapped rather than copied: a batch can be tens of thousands of events, and handing it
            // over should not mean moving it.
            if let batch = state.withLock({ state -> [RunEvent]? in
                if !state.pending.isEmpty {
                    var batch: [RunEvent] = []
                    swap(&batch, &state.pending)
                    return batch
                }
                return state.closed ? [] : nil
            }) {
                return batch
            }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Checked again under the lock, because something may have arrived since the look
                // above. Parking on a stale answer is the one way this could hang.
                let ready = state.withLock { state in
                    if !state.pending.isEmpty || state.closed { return true }
                    state.waiter = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        }
    }

    /// No more events will be posted. Only `Drain` should call this: closing without waiting is the
    /// mistake it exists to prevent.
    fileprivate func close() {
        let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.closed = true
            let waiting = state.waiter
            state.waiter = nil
            return waiting
        }
        waiting?.resume()
    }
}

/// The one piece of ordering this design adds, in the one place it can be got wrong.
///
/// `post` hands an event to another task, so a run that exits straight after its last event races the
/// line explaining why it exited — and on a full-screen display it races the terminal being handed back
/// as well, which is how you end up with no cursor. Every way out goes through `drain()` first: the end
/// of a run, an error, and both Ctrl-C paths.
/// `Sendable` outright rather than `@unchecked`: every stored property is either immutable or a
/// `Mutex`, so the guarantee is checked rather than asserted. The one flag this keeps used to sit
/// beside an `NSLock` with a comment about which one covered it.
final class Drain: Sendable {
    private let stream: EventStream
    private let done = DispatchSemaphore(value: 0)
    private let drained = Mutex(false)

    fileprivate init(_ stream: EventStream) {
        self.stream = stream
    }

    fileprivate func consumerReturned() {
        done.signal()
    }

    /// Closes the stream and blocks until the consumer has applied everything and finished up.
    ///
    /// Idempotent, and callable from anywhere — including a signal source's queue, which is where the
    /// immediate stop comes from. The wait deliberately happens *inside* the lock, so a second caller
    /// blocks until the first is genuinely done rather than sailing past on a flag that was set before
    /// the work it stands for had finished.
    func drain() {
        drained.withLock { alreadyDrained in
            guard !alreadyDrained else { return }
            alreadyDrained = true
            stream.close()
            done.wait()
        }
    }
}

/// Something that displays a run. Given batches in order, then told when there will be no more.
///
/// Everything about presentation lives here: when to say a thing, how to word it, what to draw, what to
/// ignore. The engine's events carry facts and no schedule, so a consumer showing a line per change, a
/// table refreshed eight times a second, a summary at the end, or nothing at all are all equally
/// faithful readings of the same run.
protocol EventConsumer: AnyObject {
    /// A batch, in the order the engine produced it. Called from one task only.
    func apply(_ batch: [RunEvent]) async
    /// The run is over and drained. Last chance to write a summary or hand the terminal back.
    func finish() async
}
