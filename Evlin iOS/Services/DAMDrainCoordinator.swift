import Foundation

/// Process-local, single-flight, non-blocking drain kick for the
/// DeviceActivity extension.
///
/// Why this exists (2026-08-16/18 trace, three devices): the extension used
/// to block its synchronous callback on a `DispatchSemaphore` for up to six
/// seconds while it uploaded. When Apple's daemon had ANOTHER callback queued
/// for the same extension, it terminated the blocked instance and relaunched
/// it — the killed callback was re-delivered later with growing backoff
/// (1s → 6min → 30min+), which is what a parent saw as "the bar freezes and
/// then jumps". A share of those deaths were also genuine `per-process-limit`
/// jetsams inside the drain's memory spike. Blocking was the death, not the
/// number of rungs.
///
/// The contract now: a callback does
///     validate → account → durable journal → local shield → requestDrain() → return
/// and NOTHING in that path waits. `requestDrain()` is a kick: it records
/// interest, and if no drain worker is running it starts one; while a worker
/// is running, further kicks only coalesce into "run one more round". Each
/// round is capped by `MeteringDrainBudget.extensionDefault()`.
///
/// This is a performance optimisation, not the correctness boundary. The
/// worker is opportunistic — the process may be suspended or killed at any
/// time after the callback returns — and it is process-local, so a fresh PID
/// starts its own. Correctness stays where it already was: the durable
/// callback journal (cross-process lock), deterministic client sample IDs,
/// backend idempotency, and transport receipts. A sample uploaded twice by
/// two PIDs is absorbed as a duplicate, never credited twice.
nonisolated final class DAMDrainCoordinator: @unchecked Sendable {
    typealias Work = @Sendable (MeteringDrainBudget) async -> Void
    typealias RoundFinished = @Sendable ([DAMMemoryTrace.Context]) -> Void

    static let shared = DAMDrainCoordinator(
        work: { budget in
            await DAMMeteringEntry.shared.deliverPendingCallbacksIfConfigured(
                budget: budget
            )
        },
        onRoundFinished: { contexts in
            // `asyncCompleted` on `afterDrainWait` already means "the
            // background drain finished after the callback returned" in the
            // trace vocabulary; keep using it so the viewer/decoder need no
            // change. A callback whose trace never gains this record simply
            // had its opportunistic drain die with the process — the journal
            // still holds the sample.
            for context in contexts {
                DAMMemoryTrace.shared.mark(
                    context,
                    stage: .afterDrainWait,
                    flags: .asyncCompleted
                )
            }
        }
    )

    private let work: Work
    private let onRoundFinished: RoundFinished
    private let makeBudget: @Sendable () -> MeteringDrainBudget

    private let lock = NSLock()
    private var running = false
    private var pendingKick = false
    private var waitingContexts: [DAMMemoryTrace.Context] = []
    private var roundsStarted = 0

    init(
        work: @escaping Work,
        onRoundFinished: @escaping RoundFinished = { _ in },
        makeBudget: @escaping @Sendable () -> MeteringDrainBudget = {
            MeteringDrainBudget.extensionDefault()
        }
    ) {
        self.work = work
        self.onRoundFinished = onRoundFinished
        self.makeBudget = makeBudget
    }

    /// Non-blocking. Returns `true` when this kick started a worker, `false`
    /// when it coalesced into an already-running worker's next round.
    @discardableResult
    func requestDrain(traceContext: DAMMemoryTrace.Context? = nil) -> Bool {
        lock.lock()
        if let traceContext {
            waitingContexts.append(traceContext)
        }
        if running {
            pendingKick = true
            lock.unlock()
            return false
        }
        running = true
        lock.unlock()
        Task.detached(priority: .utility) { [self] in
            await runRounds()
        }
        return true
    }

    /// Rounds started so far (tests/diagnostics).
    var roundCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return roundsStarted
    }

    private func runRounds() async {
        while true {
            lock.lock()
            let contexts = waitingContexts
            waitingContexts = []
            pendingKick = false
            roundsStarted += 1
            lock.unlock()

            await work(makeBudget())
            onRoundFinished(contexts)

            lock.lock()
            let again = pendingKick
            if !again {
                running = false
            }
            lock.unlock()
            if !again {
                return
            }
        }
    }
}
