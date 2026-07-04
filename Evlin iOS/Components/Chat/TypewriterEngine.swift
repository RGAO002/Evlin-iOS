import Foundation

/// Injectable time source so tests never rely on real timers (CI stability).
protocol TypewriterClock { var now: TimeInterval { get } }
struct SystemClock: TypewriterClock {
    var now: TimeInterval { Date().timeIntervalSinceReferenceDate }
}

/// Display-only reveal engine (spec §5.3). REALTIME FIRST: reveal rate =
/// max(base, arrival rate); finalize() must complete within 200 ms. Never
/// buffers arrival — only presentation.
///
/// `nonisolated` opts this class out of the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default. Without it the class
/// is implicitly `@MainActor`, and its synthesized deinit routes through
/// `swift_task_deinitOnExecutorMainActorBackDeploy`, which double-frees on
/// dealloc under this toolchain (SIGABRT in every test that lets an instance
/// deallocate — see `AppLimitPlanner`/`EvlinPINStore` for the same fix).
/// `@unchecked Sendable` matches those types; a later task binds this engine
/// to a single bubble's view state on the main actor via `onChange`, so the
/// mutable state here is not shared across threads in practice.
nonisolated final class TypewriterEngine: @unchecked Sendable {
    private(set) var revealed: String = ""
    var onChange: ((String) -> Void)?
    private var buffer: String = ""
    private var finalized = false
    private let tickInterval: TimeInterval
    private let clock: TypewriterClock

    var bufferForTesting: String { buffer }

    /// The reveal is truly done: text has been `finalize`d AND every character
    /// is shown. The driving timer must stop on THIS — not on a transient
    /// `revealed == buffer`, which is momentarily true in the gaps between
    /// streamed deltas (before `finalize`), and would kill the timer early.
    var isComplete: Bool { finalized && revealed == buffer }

    init(clock: TypewriterClock = SystemClock(), tickInterval: TimeInterval = 0.03) {
        self.clock = clock
        self.tickInterval = tickInterval
    }

    func append(_ text: String) {
        guard !finalized else { return }
        buffer += text
    }

    /// Reveal one step synchronously. The timer still owns the smooth ongoing
    /// reveal; callers use this when a live delta/envelope arrives so the UI
    /// never sits on an empty bubble waiting for the next run-loop tick.
    func flushNow() {
        tick()
    }

    func finalize(with authoritative: String) {
        finalized = true
        if !authoritative.hasPrefix(revealed) {
            revealed = ""                       // mismatched prefix: envelope wins
        }
        buffer = authoritative
    }

    func tick() {
        let backlog = buffer.count - revealed.count
        guard backlog > 0 else { return }
        let step = Self.revealStep(forBacklog: backlog)
        let end = buffer.index(buffer.startIndex,
                               offsetBy: min(revealed.count + step, buffer.count))
        revealed = String(buffer[..<end])
        onChange?(revealed)
    }

    nonisolated static func revealStep(forBacklog backlog: Int) -> Int {
        guard backlog > 0 else { return 0 }
        if backlog > 240 { return 3 }
        if backlog > 120 { return 2 }
        return 1
    }
}
